//! ## What This Rule Does
//! Requires inferred initializers when the destination type is already known.
//!
//! ```zig
//! const config: Config = Config{ .enabled = true };
//! var writer: Writer.Allocating = Writer.Allocating.init(allocator);
//! ```
//!
//! becomes:
//!
//! ```zig
//! const config: Config = .{ .enabled = true };
//! var writer: Writer.Allocating = .init(allocator);
//! ```
//!
//! The same applies to `return T{...}` and `return T.init(...)` when the
//! enclosing function's return type is `T` (or `!T`).
//!
//! A declaration with no type annotation is flagged when its initializer names
//! the type:
//!
//! ```zig
//! const receiver_kind = ReceiverKind.fromParams(Class, Args);
//! ```
//!
//! becomes:
//!
//! ```zig
//! const receiver_kind: ReceiverKind = .fromParams(Class, Args);
//! ```
//!
//! Initializers that already carry a type expression (`Config{...}`,
//! `[2]u8{...}`) are reported exactly. A local `Type.fn(...)` or `Type.member`
//! is checked against the local symbol table: the member must be an exported
//! function returning the type, or an enum/error member. Imported and
//! cross-file paths fall back to Zig's naming contract: the rightmost type name
//! must be TitleCase and the selected member must start lowercase. The fallback
//! can misread an imported TitleCase factory that returns a value, and an
//! imported fallible `fn init() !T` used without `try`. `Foo.Bar` and
//! `std.ArrayList(u8)` are not reported because they name types, not values.
//! An unannotated `[_]T{...}` is not reported because no annotation can spell
//! the inferred length.
//!
//! Hand-written `*.mixin.zig` and `*.replace.zig` fragments are linted. Set
//! `skip_fragments` to exclude them.

pub const meta: Rule.Meta = .{
    .name = "gdzig-inferred-initializers",
    .category = .style,
    .default = .warning,
    .fix = .safe_fix,
};

/// Skip hand-written mixin and replace fragments.
skip_fragments: bool = false,

/// Check `return T{...}` and `return T.init(...)`.
check_returns: bool = true,

const InferredInitializers = @This();

/// Checks variable and return initializers for a redundant explicit type.
pub fn runOnNode(self: *const InferredInitializers, wrapper: NodeWrapper, ctx: *LinterContext) void {
    if (self.skip_fragments and helpers.isFragment(ctx.source.pathname)) return;

    const ast = ctx.ast();
    switch (wrapper.node.tag) {
        .global_var_decl,
        .local_var_decl,
        .aligned_var_decl,
        .simple_var_decl,
        => {
            const decl = ast.fullVarDecl(wrapper.idx) orelse return;
            const init_node = decl.ast.init_node.unwrap() orelse return;
            if (decl.ast.type_node.unwrap()) |type_node| {
                check(ctx, helpers.unwrapResultType(ast, type_node), init_node);
            } else {
                checkUnannotated(ctx, decl, init_node);
            }
        },
        .@"return" => {
            if (!self.check_returns) return;
            const expr = ast.nodeData(wrapper.idx).opt_node.unwrap() orelse return;
            const return_type = helpers.enclosingReturnType(ctx, wrapper.idx) orelse return;
            check(ctx, helpers.unwrapResultType(ast, return_type), expr);
        },
        else => {},
    }
}

/// Checks a declaration without a type annotation for an initializer that
/// names a type.
fn checkUnannotated(ctx: *LinterContext, decl: Ast.full.VarDecl, init_node: Node.Index) void {
    const inferred = inferTypeFromInitializer(ctx, init_node) orelse return;
    const type_source = helpers.sourceOf(ctx, inferred.type_node);
    const name_token = decl.ast.mut_token + 1;
    const span: Span = .new(
        ctx.semantic.tokenSpan(name_token).end,
        ctx.semantic.nodeSpan(inferred.type_node).end,
    );
    const diagnostic = ctx.diagnosticf(
        "declare '{s}: {s}' and use an inferred initializer",
        .{ ctx.semantic.tokenSlice(name_token), type_source },
        .{ctx.labelN(inferred.type_node, "move this type to the left", .{})},
    );

    if (!helpers.hasLayoutModifiers(decl) and !helpers.spanHasComment(ctx, span)) {
        ctx.reportWithFix(
            InitFix{
                .span = span,
                .kind = if (inferred.use_dot) .annotate_dot else .annotate_drop,
                .type_source = type_source,
            },
            diagnostic,
            &applyFix,
        );
    } else {
        ctx.report(diagnostic);
    }
}

const Inferred = struct {
    type_node: Node.Index,
    /// The remaining initializer text starts with `{`, so the fix adds a `.`.
    use_dot: bool,
};

/// What a resolved base path names.
const LocalBase = union(enum) {
    /// A container declared in this file.
    container: Symbol.Id,
    /// A value, so member access cannot construct a type.
    non_type,
    /// ZLint has no local symbol (imported or cross-file); use naming.
    unknown,
};

/// Infers the named type an unannotated initializer constructs.
fn inferTypeFromInitializer(ctx: *LinterContext, init_node: Node.Index) ?Inferred {
    const ast = ctx.ast();
    if (init_node_tag(ast, init_node)) |kind| {
        switch (kind) {
            .struct_init => {
                var buffer: [2]Node.Index = undefined;
                const init = ast.fullStructInit(&buffer, init_node) orelse return null;
                const explicit = init.ast.type_expr.unwrap() orelse return null;
                if (helpers.isInferredLengthArray(ast, explicit)) return null;
                return .{ .type_node = explicit, .use_dot = true };
            },
            .array_init => {
                var buffer: [2]Node.Index = undefined;
                const init = ast.fullArrayInit(&buffer, init_node) orelse return null;
                const explicit = init.ast.type_expr.unwrap() orelse return null;
                if (helpers.isInferredLengthArray(ast, explicit)) return null;
                return .{ .type_node = explicit, .use_dot = true };
            },
            .call => return inferCall(ctx, init_node),
        }
    }
    if (ast.nodeTag(init_node) == .field_access) return inferFieldAccess(ctx, init_node);
    return null;
}

/// Infers a type from `Type.fn(...)` and `Type.init(...)`.
fn inferCall(ctx: *LinterContext, call_node: Node.Index) ?Inferred {
    const ast = ctx.ast();
    var buffer: [1]Node.Index = undefined;
    const call = ast.fullCall(&buffer, call_node) orelse return null;
    const callee = helpers.unwrapGrouped(ast, call.ast.fn_expr);
    if (ast.nodeTag(callee) != .field_access) return null;

    const data = ast.nodeData(callee).node_and_token;
    const base = data[0];
    const member_name = ast.tokenSlice(data[1]);

    switch (helpers.resolveLocalBase(ctx, base)) {
        .container => |container| {
            const member = helpers.findExport(ctx, container, member_name) orelse return null;
            if (!helpers.callReturnsType(ctx, member, base)) return null;
            return .{ .type_node = base, .use_dot = false };
        },
        .non_type => return null,
        .unknown => {
            if (!helpers.isNamedType(ast, base)) return null;
            if (!helpers.isValueField(member_name)) return null;
            return .{ .type_node = base, .use_dot = false };
        },
    }
}

/// Infers a type from `Type.member`, such as an enum literal path.
fn inferFieldAccess(ctx: *LinterContext, node: Node.Index) ?Inferred {
    const ast = ctx.ast();
    const data = ast.nodeData(node).node_and_token;
    const base = data[0];
    const member_name = ast.tokenSlice(data[1]);

    switch (helpers.resolveLocalBase(ctx, base)) {
        .container => |container| {
            if (!helpers.memberIsValue(ctx, container, member_name)) return null;
            return .{ .type_node = base, .use_dot = false };
        },
        .non_type => return null,
        .unknown => {
            if (!helpers.isNamedType(ast, base)) return null;
            if (!helpers.isValueField(member_name)) return null;
            return .{ .type_node = base, .use_dot = false };
        },
    }
}

/// Returns the rule descriptor.
pub fn rule(self: *InferredInitializers) Rule {
    return .init(self);
}

fn check(ctx: *LinterContext, type_node: Node.Index, init_node: Node.Index) void {
    const ast = ctx.ast();
    const type_source = helpers.sourceOf(ctx, type_node);

    const kind = init_node_tag(ast, init_node) orelse return;
    switch (kind) {
        .struct_init => {
            var buffer: [2]Node.Index = undefined;
            const init = ast.fullStructInit(&buffer, init_node) orelse return;
            const explicit = init.ast.type_expr.unwrap() orelse return;
            if (!std.mem.eql(u8, helpers.sourceOf(ctx, explicit), type_source)) return;

            ctx.reportWithFix(
                InitFix{
                    .span = ctx.semantic.nodeSpan(explicit),
                    .kind = .use_dot,
                },
                ctx.diagnosticf(
                    "use an inferred initializer for type '{s}'",
                    .{type_source},
                    .{ctx.spanN(explicit)},
                ),
                &applyFix,
            );
        },
        .call => {
            var buffer: [1]Node.Index = undefined;
            const call = ast.fullCall(&buffer, init_node) orelse return;
            const callee = call.ast.fn_expr;
            if (ast.nodeTag(callee) != .field_access) return;

            const data = ast.nodeData(callee).node_and_token;
            const base = data[0];
            const field_token = data[1];
            if (!std.mem.eql(u8, ast.tokenSlice(field_token), "init")) return;
            if (!std.mem.eql(u8, helpers.sourceOf(ctx, base), type_source)) return;

            ctx.reportWithFix(
                InitFix{
                    .span = ctx.semantic.nodeSpan(base),
                    .kind = .drop_type,
                },
                ctx.diagnosticf(
                    "use an inferred initializer for type '{s}'",
                    .{type_source},
                    .{ctx.spanN(base)},
                ),
                &applyFix,
            );
        },
        .array_init => {
            var buffer: [2]Node.Index = undefined;
            const init = ast.fullArrayInit(&buffer, init_node) orelse return;
            const explicit = init.ast.type_expr.unwrap() orelse return;
            if (!std.mem.eql(u8, helpers.sourceOf(ctx, explicit), type_source)) return;

            ctx.reportWithFix(
                InitFix{
                    .span = ctx.semantic.nodeSpan(explicit),
                    .kind = .use_dot,
                },
                ctx.diagnosticf(
                    "use an inferred initializer for type '{s}'",
                    .{type_source},
                    .{ctx.spanN(explicit)},
                ),
                &applyFix,
            );
        },
    }
}

const InitKind = enum {
    struct_init,
    call,
    array_init,
};

fn init_node_tag(ast: *const Ast, node: Node.Index) ?InitKind {
    return switch (ast.nodeTag(node)) {
        .struct_init_one,
        .struct_init_one_comma,
        .struct_init_dot_two,
        .struct_init_dot_two_comma,
        .struct_init_dot,
        .struct_init_dot_comma,
        .struct_init,
        .struct_init_comma,
        => .struct_init,
        .call,
        .call_comma,
        .call_one,
        .call_one_comma,
        => .call,
        .array_init_one,
        .array_init_one_comma,
        .array_init_dot_two,
        .array_init_dot_two_comma,
        .array_init_dot,
        .array_init_dot_comma,
        .array_init,
        .array_init_comma,
        => .array_init,
        else => null,
    };
}

const InitFix = struct {
    span: Span,
    kind: enum {
        use_dot,
        drop_type,
        annotate_dot,
        annotate_drop,
    },
    type_source: []const u8 = "",
};

fn applyFix(fix: InitFix, builder: Fix.Builder) anyerror!Fix {
    return switch (fix.kind) {
        .use_dot => builder.replace(fix.span, .static(".")),
        .drop_type => builder.delete(fix.span),
        .annotate_dot => builder.replacef(fix.span, ": {s} = .", .{fix.type_source}),
        .annotate_drop => builder.replacef(fix.span, ": {s} = ", .{fix.type_source}),
    };
}

const helpers = struct {
    fn isFragment(path: ?[]const u8) bool {
        const p = path orelse return false;
        return std.mem.endsWith(u8, p, ".mixin.zig") or std.mem.endsWith(u8, p, ".replace.zig");
    }

    fn hasLayoutModifiers(decl: Ast.full.VarDecl) bool {
        return decl.ast.align_node.unwrap() != null or
            decl.ast.addrspace_node.unwrap() != null or
            decl.ast.section_node.unwrap() != null;
    }

    fn spanHasComment(ctx: *LinterContext, span: Span) bool {
        const snippet = span.snippet(ctx.source.text());
        return std.mem.indexOf(u8, snippet, "//") != null or
            std.mem.indexOf(u8, snippet, "/*") != null;
    }

    fn sourceOf(ctx: *LinterContext, node: Node.Index) []const u8 {
        return ctx.semantic.nodeSpan(node).snippet(ctx.source.text());
    }

    fn unwrapGrouped(ast: *const Ast, node: Node.Index) Node.Index {
        var current = node;
        while (true) {
            switch (ast.nodeTag(current)) {
                .grouped_expression => current = ast.nodeData(current).node,
                else => return current,
            }
        }
    }

    /// `[_]T` and `[_:sentinel]T` cannot be written as a declaration
    /// annotation, because the length is only known from the initializer.
    fn isInferredLengthArray(ast: *const Ast, type_node: Node.Index) bool {
        const array = ast.fullArrayType(type_node) orelse return false;
        const count = array.ast.elem_count;
        return ast.nodeTag(count) == .identifier and
            std.mem.eql(u8, ast.tokenSlice(ast.nodeMainToken(count)), "_");
    }

    /// Resolves a base path such as `Type`, `Type.Nested`, or `module.Type`.
    fn resolveLocalBase(ctx: *LinterContext, base_node: Node.Index) LocalBase {
        const ast = ctx.ast();
        if (!isPurePath(ast, base_node)) return .unknown;

        const root = rootIdentifier(ast, base_node) orelse return .unknown;
        const scope = ctx.links().scopes.items[@intFromEnum(root)];
        const name = ast.tokenSlice(ast.nodeMainToken(root));
        const symbol_id = ctx.semantic.resolveBinding(scope, name, .decls) orelse return .unknown;
        const symbol = ctx.symbols().get(symbol_id);

        if (symbol.flags.intersects(.s_container)) {
            const container = resolvePath(ctx, base_node, symbol_id) orelse return .non_type;
            return .{ .container = container };
        }
        if (isImportAlias(ctx, symbol_id)) return .unknown;
        if (symbol.flags.s_variable) return classifyVariableBase(ctx, symbol_id);
        return .unknown;
    }

    fn isPurePath(ast: *const Ast, node: Node.Index) bool {
        const n = unwrapGrouped(ast, node);
        return switch (ast.nodeTag(n)) {
            .identifier => true,
            .field_access => isPurePath(ast, ast.nodeData(n).node_and_token[0]),
            else => false,
        };
    }

    fn rootIdentifier(ast: *const Ast, node: Node.Index) ?Node.Index {
        const n = unwrapGrouped(ast, node);
        return switch (ast.nodeTag(n)) {
            .identifier => n,
            .field_access => rootIdentifier(ast, ast.nodeData(n).node_and_token[0]),
            else => null,
        };
    }

    /// Walks the remaining path segments through a container's exports.
    fn resolvePath(ctx: *LinterContext, node: Node.Index, current: Symbol.Id) ?Symbol.Id {
        const ast = ctx.ast();
        const n = unwrapGrouped(ast, node);
        return switch (ast.nodeTag(n)) {
            .identifier => current,
            .field_access => {
                const data = ast.nodeData(n).node_and_token;
                const parent = resolvePath(ctx, data[0], current) orelse return null;
                const child = findExport(ctx, parent, ast.tokenSlice(data[1])) orelse return null;
                if (!ctx.symbols().get(child).flags.intersects(.s_container)) return null;
                return child;
            },
            else => null,
        };
    }

    fn isImportAlias(ctx: *LinterContext, symbol_id: Symbol.Id) bool {
        const ast = ctx.ast();
        const symbol = ctx.symbols().get(symbol_id);
        const decl = ast.fullVarDecl(symbol.decl) orelse return false;
        const init = decl.ast.init_node.unwrap() orelse return false;
        const n = unwrapGrouped(ast, init);
        return switch (ast.nodeTag(n)) {
            .builtin_call,
            .builtin_call_comma,
            .builtin_call_two,
            .builtin_call_two_comma,
            => std.mem.eql(u8, ast.tokenSlice(ast.nodeMainToken(n)), "@import"),
            else => false,
        };
    }

    /// Classifies a variable or constant used as a base path.
    fn classifyVariableBase(ctx: *LinterContext, symbol_id: Symbol.Id) LocalBase {
        const ast = ctx.ast();
        const symbol = ctx.symbols().get(symbol_id);
        const decl = ast.fullVarDecl(symbol.decl) orelse return .unknown;
        if (decl.ast.type_node.unwrap()) |type_node| {
            return if (std.mem.eql(u8, sourceOf(ctx, type_node), "type")) .unknown else .non_type;
        }

        const init = decl.ast.init_node.unwrap() orelse return .non_type;
        const n = unwrapGrouped(ast, init);
        switch (ast.nodeTag(n)) {
            .identifier, .field_access => return .unknown,
            .builtin_call,
            .builtin_call_comma,
            .builtin_call_two,
            .builtin_call_two_comma,
            => {
                const name = ast.tokenSlice(ast.nodeMainToken(n));
                if (std.mem.eql(u8, name, "@This") or std.mem.eql(u8, name, "@TypeOf")) return .unknown;
                return .non_type;
            },
            .call, .call_comma, .call_one, .call_one_comma => {
                return if (localCallReturnsType(ctx, n)) .unknown else .non_type;
            },
            else => return .non_type,
        }
    }

    fn localCallReturnsType(ctx: *LinterContext, call_node: Node.Index) bool {
        const ast = ctx.ast();
        var call_buffer: [1]Node.Index = undefined;
        const call = ast.fullCall(&call_buffer, call_node) orelse return false;
        const callee = unwrapGrouped(ast, call.ast.fn_expr);
        if (ast.nodeTag(callee) != .identifier) return false;

        const scope = ctx.links().scopes.items[@intFromEnum(callee)];
        const name = ast.tokenSlice(ast.nodeMainToken(callee));
        const symbol_id = ctx.semantic.resolveBinding(scope, name, .decls) orelse return false;
        const symbol = ctx.symbols().get(symbol_id);
        if (!symbol.flags.s_fn) return false;

        var proto_buffer: [1]Node.Index = undefined;
        const proto = ast.fullFnProto(&proto_buffer, symbol.decl) orelse return false;
        const return_type = proto.ast.return_type.unwrap() orelse return false;
        if (!returnTypeIsPlain(ast, return_type)) return false;
        return std.mem.eql(u8, sourceOf(ctx, return_type), "type");
    }

    fn findExport(ctx: *LinterContext, container: Symbol.Id, name: []const u8) ?Symbol.Id {
        const table = ctx.symbols();
        for (table.getExports(container).items) |id| {
            if (std.mem.eql(u8, table.get(id).name, name)) return id;
        }
        return null;
    }

    fn findMember(ctx: *LinterContext, container: Symbol.Id, name: []const u8) ?Symbol.Id {
        const table = ctx.symbols();
        for (table.getMembers(container).items) |id| {
            if (std.mem.eql(u8, table.get(id).name, name)) return id;
        }
        return null;
    }

    /// A call to a local function constructs `base` only when it returns that
    /// exact type (or `Self` / `@This()`).
    fn callReturnsType(ctx: *LinterContext, member: Symbol.Id, base_node: Node.Index) bool {
        const ast = ctx.ast();
        const symbol = ctx.symbols().get(member);
        if (!symbol.flags.s_fn) return false;

        var buffer: [1]Node.Index = undefined;
        const proto = ast.fullFnProto(&buffer, symbol.decl) orelse return false;
        const return_type = proto.ast.return_type.unwrap() orelse return false;
        if (!returnTypeIsPlain(ast, return_type)) return false;
        const return_source = sourceOf(ctx, return_type);
        if (std.mem.eql(u8, return_source, "Self") or
            std.mem.eql(u8, return_source, "@This()")) return true;
        return std.mem.eql(u8, return_source, sourceOf(ctx, base_node));
    }

    /// The AST drops the `!`/`?` wrapper from a function prototype's return
    /// type, so inspect the token that precedes it.
    fn returnTypeIsPlain(ast: *const Ast, return_type: Node.Index) bool {
        const first = ast.firstToken(return_type);
        if (first == 0) return true;
        const tag = ast.tokens.items(.tag)[first - 1];
        return tag != .bang and tag != .question_mark;
    }

    /// A bare member is a value only for an enum or error set.
    fn memberIsValue(ctx: *LinterContext, container: Symbol.Id, name: []const u8) bool {
        const flags = ctx.symbols().get(container).flags;
        if (!(flags.s_enum or flags.s_error)) return false;
        return findMember(ctx, container, name) != null;
    }

    /// Layer 3: the rightmost identifier of a base path follows Zig's
    /// TitleCase contract for types.
    fn isNamedType(ast: *const Ast, node: Node.Index) bool {
        const name = rightmostName(ast, node) orelse return false;
        return name.len > 0 and std.ascii.isUpper(name[0]);
    }

    fn rightmostName(ast: *const Ast, node: Node.Index) ?[]const u8 {
        const n = unwrapGrouped(ast, node);
        return switch (ast.nodeTag(n)) {
            .identifier => ast.tokenSlice(ast.nodeMainToken(n)),
            .field_access => ast.tokenSlice(ast.nodeData(n).node_and_token[1]),
            .call,
            .call_comma,
            .call_one,
            .call_one_comma,
            => blk: {
                var buffer: [1]Node.Index = undefined;
                const call = ast.fullCall(&buffer, n) orelse break :blk null;
                break :blk rightmostName(ast, call.ast.fn_expr);
            },
            else => null,
        };
    }

    /// A value member (function or value) starts lowercase.
    fn isValueField(name: []const u8) bool {
        if (name.len == 0) return false;
        return std.ascii.isLower(name[0]) or name[0] == '_';
    }

    fn enclosingReturnType(ctx: *LinterContext, node: Node.Index) ?Node.Index {
        const ast = ctx.ast();
        var current = node;
        while (ctx.links().getParent(current)) |parent| {
            if (ast.nodeTag(parent) == .fn_decl) {
                var buffer: [1]Node.Index = undefined;
                const proto = ast.fullFnProto(&buffer, parent) orelse return null;
                return proto.ast.return_type.unwrap();
            }
            current = parent;
        }
        return null;
    }

    fn unwrapResultType(ast: *const Ast, node: Node.Index) Node.Index {
        var current = node;
        while (true) {
            switch (ast.nodeTag(current)) {
                .error_union => current = ast.nodeData(current).node_and_node[1],
                .optional_type => current = ast.nodeData(current).node,
                else => return current,
            }
        }
    }
};

test InferredInitializers {
    @setEvalBranchQuota(100_000);

    const failing_literal =
        \\const config: Config = Config{ .enabled = true };
    ;
    const fixed_literal =
        \\const config: Config = .{ .enabled = true };
    ;
    const failing_call =
        \\var writer: Writer.Allocating = Writer.Allocating.init(allocator);
    ;
    const fixed_call =
        \\var writer: Writer.Allocating = .init(allocator);
    ;
    const failing_return =
        \\fn make() Config { return Config{ .enabled = true }; }
    ;
    const fixed_return =
        \\fn make() Config { return .{ .enabled = true }; }
    ;
    const failing_optional =
        \\const config: ?Config = Config{ .enabled = true };
    ;
    const fixed_optional =
        \\const config: ?Config = .{ .enabled = true };
    ;
    const failing_error_union =
        \\const config: anyerror!Config = Config{ .enabled = true };
    ;
    const fixed_error_union =
        \\const config: anyerror!Config = .{ .enabled = true };
    ;
    const failing_optional_return =
        \\fn make() ?Config { return Config{ .enabled = true }; }
    ;
    const fixed_optional_return =
        \\fn make() ?Config { return .{ .enabled = true }; }
    ;
    const failing_array =
        \\const pair: [2]u8 = [2]u8{ 1, 2 };
    ;
    const fixed_array =
        \\const pair: [2]u8 = .{ 1, 2 };
    ;
    const failing_unannotated_call =
        \\const receiver_kind = ReceiverKind.fromParams(Class, Args);
    ;
    const fixed_unannotated_call =
        \\const receiver_kind: ReceiverKind = .fromParams(Class, Args);
    ;
    const failing_unannotated_literal =
        \\const config = Config{ .enabled = true };
    ;
    const fixed_unannotated_literal =
        \\const config: Config = .{ .enabled = true };
    ;
    const failing_unannotated_member =
        \\const default = Config.default;
    ;
    const fixed_unannotated_member =
        \\const default: Config = .default;
    ;
    const failing_unannotated_nested =
        \\var writer = Writer.Allocating.init(allocator);
    ;
    const fixed_unannotated_nested =
        \\var writer: Writer.Allocating = .init(allocator);
    ;
    const failing_unannotated_std =
        \\const value = std.ArrayList(u8).init(allocator);
    ;
    const fixed_unannotated_std =
        \\const value: std.ArrayList(u8) = .init(allocator);
    ;
    const failing_unannotated_godot =
        \\const value = godot.Object.init();
    ;
    const fixed_unannotated_godot =
        \\const value: godot.Object = .init();
    ;
    const failing_unannotated_array =
        \\const bytes = [2]u8{ 1, 2 };
    ;
    const fixed_unannotated_array =
        \\const bytes: [2]u8 = .{ 1, 2 };
    ;
    const failing_local_enum =
        \\const ReceiverKind = enum {
        \\    instance,
        \\    none,
        \\
        \\    fn fromParams() ReceiverKind {
        \\        return .none;
        \\    }
        \\};
        \\const receiver_kind = ReceiverKind.fromParams();
    ;
    const fixed_local_enum =
        \\const ReceiverKind = enum {
        \\    instance,
        \\    none,
        \\
        \\    fn fromParams() ReceiverKind {
        \\        return .none;
        \\    }
        \\};
        \\const receiver_kind: ReceiverKind = .fromParams();
    ;
    const pass_local_factory_other_type =
        \\const Counter = struct {
        \\    fn count() usize {
        \\        return 0;
        \\    }
        \\};
        \\const count = Counter.count();
    ;
    const pass_local_fallible_factory =
        \\const Foo = struct {
        \\    fn init() !Foo {
        \\        return .{};
        \\    }
        \\};
        \\const foo = Foo.init();
    ;
    const pass_local_struct_const =
        \\const Config = struct {
        \\    pub const default: usize = 1;
        \\};
        \\const value = Config.default;
    ;
    const pass_variable_base =
        \\const Holder = make_holder();
        \\const value = Holder.Thing;
    ;
    const fail_local_enum_member =
        \\const Color = enum { red, green };
        \\const color = Color.red;
    ;

    var impl: InferredInitializers = .{};
    var runner: RuleTester = .init(testing.allocator, impl.rule());
    defer runner.deinit();
    try runner
        .withPass(&.{
            "const config: Config = .{ .enabled = true };",
            "var writer: Writer.Allocating = .init(allocator);",
            "const config: Config = Other{ .enabled = true };",
            "fn make() Config { return .{ .enabled = true }; }",
            "const config: ?Config = .{ .enabled = true };",
            "fn make() ?Config { return .{ .enabled = true }; }",
            "const pair: [2]u8 = .{ 1, 2 };",
            "const config: Config = Config.default();",
            "const value = compute();",
            "const value = 42;",
            "const value = some_name;",
            "const value = .{ .enabled = true };",
            "const value = std.mem.zeroes(Config);",
            "const value = std.fs.cwd();",
            "const value = std.ArrayList(u8);",
            "const value = builtin.os.tag;",
            "const value = codegen.testing.value;",
            "const value = Foo.bar.baz();",
            "const value = Foo.Bar;",
            "const rule_files = [_][]const u8{ \"a\", \"b\" };",
            "const bytes = [_:0]u8{ 'a', 0 };",
            pass_local_factory_other_type,
            pass_local_fallible_factory,
            pass_local_struct_const,
            pass_variable_base,
        })
        .withFail(&.{
            failing_literal,
            failing_call,
            failing_return,
            "fn make() !Config { return Config{ .enabled = true }; }",
            failing_optional,
            failing_error_union,
            failing_optional_return,
            failing_array,
            failing_unannotated_call,
            failing_unannotated_literal,
            failing_unannotated_member,
            failing_unannotated_nested,
            "const pair = Pair{ 1, 2 };",
            "const value = Foo.Bar{};",
            failing_unannotated_std,
            failing_unannotated_godot,
            failing_unannotated_array,
            failing_local_enum,
            fail_local_enum_member,
        })
        .withFix(&.{
            .{
                .src = failing_literal,
                .expected = fixed_literal,
            },
            .{
                .src = failing_call,
                .expected = fixed_call,
            },
            .{
                .src = failing_return,
                .expected = fixed_return,
            },
            .{
                .src = failing_optional,
                .expected = fixed_optional,
            },
            .{
                .src = failing_error_union,
                .expected = fixed_error_union,
            },
            .{
                .src = failing_optional_return,
                .expected = fixed_optional_return,
            },
            .{
                .src = failing_array,
                .expected = fixed_array,
            },
            .{
                .src = failing_unannotated_call,
                .expected = fixed_unannotated_call,
            },
            .{
                .src = failing_unannotated_literal,
                .expected = fixed_unannotated_literal,
            },
            .{
                .src = failing_unannotated_member,
                .expected = fixed_unannotated_member,
            },
            .{
                .src = failing_unannotated_nested,
                .expected = fixed_unannotated_nested,
            },
            .{
                .src = failing_unannotated_std,
                .expected = fixed_unannotated_std,
            },
            .{
                .src = failing_unannotated_godot,
                .expected = fixed_unannotated_godot,
            },
            .{
                .src = failing_unannotated_array,
                .expected = fixed_unannotated_array,
            },
            .{
                .src = failing_local_enum,
                .expected = fixed_local_enum,
            },
        })
        .run();

    var no_returns_impl: InferredInitializers = .{ .check_returns = false };
    var no_returns_runner: RuleTester = .init(testing.allocator, no_returns_impl.rule());
    defer no_returns_runner.deinit();
    try no_returns_runner.withPass(&.{failing_return}).run();

    var fragment_impl: InferredInitializers = .{};
    var fragment_runner: RuleTester = .init(testing.allocator, fragment_impl.rule());
    defer fragment_runner.deinit();
    fragment_runner.setFileName("Config.mixin.zig");
    try fragment_runner.withFail(&.{failing_literal}).run();

    var skip_impl: InferredInitializers = .{ .skip_fragments = true };
    var skip_runner: RuleTester = .init(testing.allocator, skip_impl.rule());
    defer skip_runner.deinit();
    skip_runner.setFileName("Config.mixin.zig");
    try skip_runner.withPass(&.{failing_literal}).run();
}

const std = @import("std");
const testing = std.testing;

const zlint = @import("zlint");
const Ast = zlint.Semantic.Ast;
const Node = Ast.Node;
const NodeWrapper = zlint.linter.rule.NodeWrapper;
const Rule = zlint.linter.rule.Rule;
const RuleTester = zlint.linter.tester;
const LinterContext = zlint.linter.lint_context;
const Fix = zlint.linter.fix.Fix;
const Span = zlint.span.Span;
const Symbol = zlint.Semantic.Symbol;
