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
//! Generated `*.mixin.zig` and `*.replace.zig` fragments are skipped.

pub const meta: Rule.Meta = .{
    .name = "gdzig-inferred-initializers",
    .category = .style,
    .default = .warning,
    .fix = .safe_fix,
};

/// Skip generated mixin and replace fragments.
skip_fragments: bool = true,

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
            const type_node = decl.ast.type_node.unwrap() orelse return;
            const init_node = decl.ast.init_node.unwrap() orelse return;
            check(ctx, type_node, init_node);
        },
        .@"return" => {
            if (!self.check_returns) return;
            const expr = ast.nodeData(wrapper.idx).opt_node.unwrap() orelse return;
            const return_type = helpers.enclosingReturnType(ctx, wrapper.idx) orelse return;
            check(ctx, helpers.unwrapErrorUnion(ast, return_type), expr);
        },
        else => {},
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
    }
}

const InitKind = enum {
    struct_init,
    call,
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
        else => null,
    };
}

const InitFix = struct {
    span: Span,
    kind: enum {
        use_dot,
        drop_type,
    },
};

fn applyFix(fix: InitFix, builder: Fix.Builder) anyerror!Fix {
    return switch (fix.kind) {
        .use_dot => builder.replace(fix.span, .static(".")),
        .drop_type => builder.delete(fix.span),
    };
}

const helpers = struct {
    fn isFragment(path: ?[]const u8) bool {
        const p = path orelse return false;
        return std.mem.endsWith(u8, p, ".mixin.zig") or std.mem.endsWith(u8, p, ".replace.zig");
    }

    fn sourceOf(ctx: *LinterContext, node: Node.Index) []const u8 {
        return ctx.semantic.nodeSpan(node).snippet(ctx.source.text());
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

    fn unwrapErrorUnion(ast: *const Ast, node: Node.Index) Node.Index {
        if (ast.nodeTag(node) != .error_union) return node;
        return ast.nodeData(node).node_and_node[1];
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

    var impl = InferredInitializers{};
    var runner = RuleTester.init(testing.allocator, impl.rule());
    defer runner.deinit();
    try runner
        .withPass(&.{
            "const config: Config = .{ .enabled = true };",
            "var writer: Writer.Allocating = .init(allocator);",
            "const config = Config{ .enabled = true };",
            "const config: Config = Other{ .enabled = true };",
            "fn make() Config { return .{ .enabled = true }; }",
            "const config: Config = Config.default();",
        })
        .withFail(&.{
            failing_literal,
            failing_call,
            failing_return,
            "fn make() !Config { return Config{ .enabled = true }; }",
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
        })
        .run();

    var no_returns_impl = InferredInitializers{ .check_returns = false };
    var no_returns_runner = RuleTester.init(testing.allocator, no_returns_impl.rule());
    defer no_returns_runner.deinit();
    try no_returns_runner.withPass(&.{failing_return}).run();

    var fragment_impl = InferredInitializers{ .skip_fragments = false };
    var fragment_runner = RuleTester.init(testing.allocator, fragment_impl.rule());
    defer fragment_runner.deinit();
    fragment_runner.setFileName("Config.mixin.zig");
    try fragment_runner.withFail(&.{failing_literal}).run();
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
