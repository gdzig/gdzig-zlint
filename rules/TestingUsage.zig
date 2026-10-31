//! ## What This Rule Does
//! Restricts use of a `testing` namespace to test code.
//!
//! Test-only helpers live in a `const testing = struct { ... }` namespace.
//! Direct references to the local `testing` namespace are only allowed inside a
//! `test` block, inside the namespace itself, or under a `test`/`tests`
//! directory. Member access such as `module.testing.helper()` is checked only
//! when `report_member_access` is enabled.
//!
//! This rule is syntactic. It cannot see whether a `testing` namespace in
//! another file is `pub` for external callers, so it reports cross-file member
//! access outside tests too.
//!
//! Hand-written `*.mixin.zig` and `*.replace.zig` fragments are linted. Set
//! `skip_fragments` to exclude them.

pub const meta: Rule.Meta = .{
    .name = "gdzig-testing-usage",
    .category = .style,
    .default = .warning,
};

/// Skip hand-written mixin and replace fragments.
skip_fragments: bool = false,

/// Namespace name reserved for test-only helpers.
namespace: []const u8 = "testing",

/// Report direct references such as `const t = testing;`.
check_identifier_references: bool = true,

/// Report `module.testing.member` outside test blocks.
report_member_access: bool = false,

/// Treat paths under a `test` or `tests` directory as test code.
allow_test_paths: bool = true,

const TestingUsage = @This();

/// Checks direct identifier references to the namespace.
pub fn runOnce(self: *const TestingUsage, ctx: *LinterContext) void {
    if (self.skip_fragments and helpers.isFragment(ctx.source.pathname)) return;
    if (self.allow_test_paths and helpers.isTestPath(ctx.source.pathname)) return;
    if (!self.check_identifier_references) return;

    const ast = ctx.ast();
    const table = ctx.symbols();
    const names = table.symbols.items(.name);
    const decls = table.symbols.items(.decl);
    for (names, 0..) |name, index| {
        if (!helpers.identifierEquals(ctx, name, self.namespace)) continue;
        if (helpers.isStdTestingAlias(ctx, decls[index])) continue;

        const symbol_id: Symbol.Id = .from(index);
        for (table.getReferences(symbol_id)) |reference_id| {
            const reference = table.getReference(reference_id);
            if (!(reference.flags.isSelfRead() or reference.flags.type or reference.flags.call)) continue;
            if (ast.nodeTag(reference.node) != .identifier) continue;
            if (helpers.insideFieldAccess(ctx, reference.node)) continue;
            if (helpers.isAllowed(ctx, reference.node, self.namespace)) continue;
            report(ctx, reference.node, self.namespace);
        }
    }
}

/// Checks `testing` namespace references for a test-block ancestor.
pub fn runOnNode(self: *const TestingUsage, wrapper: NodeWrapper, ctx: *LinterContext) void {
    if (self.skip_fragments and helpers.isFragment(ctx.source.pathname)) return;
    if (self.allow_test_paths and helpers.isTestPath(ctx.source.pathname)) return;
    if (wrapper.node.tag != .field_access) return;

    const ast = ctx.ast();
    const data = ast.nodeData(wrapper.idx).node_and_token;
    const base = helpers.unwrapGrouped(ast, data[0]);
    const field_token = data[1];

    const base_is_namespace = ast.nodeTag(base) == .identifier and
        helpers.identifierEquals(ctx, ast.tokenSlice(ast.nodeMainToken(base)), self.namespace);
    const field_is_namespace = helpers.identifierEquals(ctx, ast.tokenSlice(field_token), self.namespace);
    if (!base_is_namespace and !(self.report_member_access and field_is_namespace)) return;
    if (!base_is_namespace and helpers.isIgnoredBase(ctx, base)) return;
    if (base_is_namespace and helpers.isStdTestingReference(ctx, wrapper.idx, self.namespace)) return;

    if (helpers.isAllowed(ctx, wrapper.idx, self.namespace)) return;

    report(ctx, wrapper.idx, self.namespace);
}

/// Returns the rule descriptor.
pub fn rule(self: *TestingUsage) Rule {
    return .init(self);
}

fn report(ctx: *LinterContext, node: Node.Index, namespace: []const u8) void {
    ctx.report(ctx.diagnosticf(
        "the '{s}' namespace is only for test code; move this reference into a test block",
        .{namespace},
        .{ctx.spanN(node)},
    ));
}

const helpers = struct {
    fn isFragment(path: ?[]const u8) bool {
        const p = path orelse return false;
        return std.mem.endsWith(u8, p, ".mixin.zig") or std.mem.endsWith(u8, p, ".replace.zig");
    }

    fn isTestPath(path: ?[]const u8) bool {
        const p = path orelse return false;
        var segments = std.mem.tokenizeAny(u8, p, "/\\");
        while (segments.next()) |segment| {
            if (std.mem.eql(u8, segment, "test") or std.mem.eql(u8, segment, "tests")) return true;
        }
        return false;
    }

    fn isStdTestingAlias(ctx: *LinterContext, decl_node: Node.Index) bool {
        const ast = ctx.ast();
        const decl = ast.fullVarDecl(decl_node) orelse return false;
        const init = unwrapGrouped(ast, decl.ast.init_node.unwrap() orelse return false);
        if (ast.nodeTag(init) != .field_access) return false;

        const data = ast.nodeData(init).node_and_token;
        if (!identifierEquals(ctx, ast.tokenSlice(data[1]), "testing")) return false;
        return isStdImport(ctx, data[0], 0);
    }

    fn isStdTestingReference(ctx: *LinterContext, node: Node.Index, namespace: []const u8) bool {
        const scope = ctx.links().scopes.items[@intFromEnum(node)];
        const symbol_id = ctx.semantic.resolveBinding(scope, namespace, .decls) orelse return false;
        return isStdTestingAlias(ctx, ctx.symbols().get(symbol_id).decl);
    }

    fn isAllowed(ctx: *LinterContext, node: Node.Index, namespace: []const u8) bool {
        const ast = ctx.ast();
        var current = node;
        while (ctx.links().getParent(current)) |parent| {
            if (ast.nodeTag(parent) == .test_decl) return true;
            var buffer: [2]Node.Index = undefined;
            if (ast.fullContainerDecl(&buffer, parent) != null and
                isNamespaceContainer(ctx, parent, namespace)) return true;
            current = parent;
        }
        return false;
    }

    fn isNamespaceContainer(ctx: *LinterContext, container: Node.Index, namespace: []const u8) bool {
        const ast = ctx.ast();
        const parent = parentSkippingGrouped(ctx, container) orelse return false;
        const decl = ast.fullVarDecl(parent) orelse return false;
        const name_token = decl.ast.mut_token + 1;
        if (name_token >= ast.tokens.len) return false;
        if (ast.tokenTag(name_token) != .identifier) return false;
        return identifierEquals(ctx, ast.tokenSlice(name_token), namespace);
    }

    fn isIgnoredBase(ctx: *LinterContext, base: Node.Index) bool {
        const ast = ctx.ast();
        if (ast.nodeTag(base) != .identifier) return false;
        const base_name = ast.tokenSlice(ast.nodeMainToken(base));
        return identifierEquals(ctx, base_name, "std") or identifierEquals(ctx, base_name, "builtin");
    }

    fn isStdImport(ctx: *LinterContext, node: Node.Index, depth: u8) bool {
        if (depth > 4) return false;
        const ast = ctx.ast();
        const expr = unwrapGrouped(ast, node);
        switch (ast.nodeTag(expr)) {
            .builtin_call, .builtin_call_comma, .builtin_call_two, .builtin_call_two_comma => {
                const source = ctx.semantic.nodeSpan(expr).snippet(ctx.source.text());
                return std.mem.eql(u8, source, "@import(\"std\")") or
                    std.mem.eql(u8, source, "@import(\"builtin\")");
            },
            .identifier => {
                var owned: ?[]u8 = null;
                defer if (owned) |decoded| ctx.gpa.free(decoded);

                const raw_name = ast.tokenSlice(ast.nodeMainToken(expr));
                const name = if (std.mem.startsWith(u8, raw_name, "@\"") and raw_name.len >= 3) blk: {
                    owned = std.zig.string_literal.parseAlloc(ctx.gpa, raw_name[1..]) catch return false;
                    break :blk owned.?;
                } else raw_name;
                const scope = ctx.links().scopes.items[@intFromEnum(expr)];
                const symbol_id = ctx.semantic.resolveBinding(scope, name, .decls) orelse
                    return std.mem.eql(u8, name, "std") or std.mem.eql(u8, name, "builtin");
                const decl = ctx.symbols().get(symbol_id).decl;
                const var_decl = ast.fullVarDecl(decl) orelse return false;
                const init = var_decl.ast.init_node.unwrap() orelse return false;
                return isStdImport(ctx, init, depth + 1);
            },
            else => return false,
        }
    }

    fn unwrapGrouped(ast: *const Ast, node: Node.Index) Node.Index {
        var current = node;
        while (ast.nodeTag(current) == .grouped_expression) {
            current = ast.nodeData(current).node_and_token[0];
        }
        return current;
    }

    fn parentSkippingGrouped(ctx: *LinterContext, node: Node.Index) ?Node.Index {
        const ast = ctx.ast();
        var current = node;
        while (ctx.links().getParent(current)) |parent| {
            if (ast.nodeTag(parent) != .grouped_expression) return parent;
            current = parent;
        }
        return null;
    }

    fn insideFieldAccess(ctx: *LinterContext, node: Node.Index) bool {
        const ast = ctx.ast();
        var current = node;
        while (ctx.links().getParent(current)) |parent| {
            if (ast.nodeTag(parent) == .field_access) return true;
            if (ast.nodeTag(parent) != .grouped_expression) return false;
            current = parent;
        }
        return false;
    }

    fn identifierEquals(ctx: *LinterContext, raw: []const u8, expected: []const u8) bool {
        if (std.mem.eql(u8, raw, expected)) return true;
        if (!std.mem.startsWith(u8, raw, "@\"") or raw.len < 3 or !std.mem.endsWith(u8, raw, "\"")) return false;
        const decoded = std.zig.string_literal.parseAlloc(ctx.gpa, raw[1..]) catch return false;
        defer ctx.gpa.free(decoded);
        return std.mem.eql(u8, decoded, expected);
    }
};

test TestingUsage {
    @setEvalBranchQuota(100_000);

    var impl: TestingUsage = .{};
    var runner: RuleTester = .init(testing.allocator, impl.rule());
    defer runner.deinit();
    try runner
        .withPass(&.{
            "test \"helper\" {\n    testing.helper();\n}",
            "test \"value\" {\n    _ = Codegen.testing.value;\n}",
            "const testing = struct {};\ntest \"alias\" {\n    const t = testing;\n    _ = t;\n}",
            "const testing = struct {\n    pub fn helper() void {}\n};",
            "const testing = std.testing;",
            "const testing = std.testing;\nfn helper() void { testing.expect(true); }",
            "const std = @import(\"std\");\nconst testing = std.testing;\nconst expect = testing.expect;",
            "const testing = @import(\"std\").testing;\nfn helper() void { testing.expect(true); }",
            "const value = Codegen.testing.value;",
            "const testing = (struct {\n" ++
                "    pub const value = 1;\n" ++
                "    pub fn helper() u8 { return testing.value; }\n" ++
                "});",
            "const testing = struct {\n" ++
                "    fn call() void {\n" ++
                "        testing.helper();\n" ++
                "    }\n" ++
                "    fn helper() void {}\n" ++
                "};",
        })
        .withFail(&.{
            "fn run() void {\n    testing.helper();\n}",
            "const testing = struct {};\nconst t = testing;",
            "const testing = struct {\n    pub fn helper() void {}\n};\nfn run() void { (testing).helper(); }",
            "const testing = struct {};\nvar value: testing = .{};",
            "const @\"testing\" = struct {\n    pub fn helper() void {}\n};\nfn run() void { @\"testing\".helper(); }",
            "const std = struct {\n" ++
                "    pub const testing = struct {\n" ++
                "        pub fn helper() void {}\n" ++
                "    };\n" ++
                "};\n" ++
                "const testing = std.testing;\n" ++
                "fn run() void { testing.helper(); }",
            "const value = testing.value;",
        })
        .run();

    var member_impl: TestingUsage = .{ .report_member_access = true };
    var member_runner: RuleTester = .init(testing.allocator, member_impl.rule());
    defer member_runner.deinit();
    try member_runner.withFail(&.{"const value = Codegen.testing.value;"}).run();

    var test_path_impl: TestingUsage = .{};
    var test_path_runner: RuleTester = .init(testing.allocator, test_path_impl.rule());
    defer test_path_runner.deinit();
    test_path_runner.setFileName("test/root.zig");
    try test_path_runner.withPass(&.{"fn run() void {\n    testing.helper();\n}"}).run();

    var strict_path_impl: TestingUsage = .{ .allow_test_paths = false };
    var strict_path_runner: RuleTester = .init(testing.allocator, strict_path_impl.rule());
    defer strict_path_runner.deinit();
    strict_path_runner.setFileName("test/root.zig");
    try strict_path_runner.withFail(&.{"fn run() void {\n    testing.helper();\n}"}).run();

    var fragment_impl: TestingUsage = .{};
    var fragment_runner: RuleTester = .init(testing.allocator, fragment_impl.rule());
    defer fragment_runner.deinit();
    fragment_runner.setFileName("Thing.mixin.zig");
    try fragment_runner.withFail(&.{"fn run() void {\n    testing.helper();\n}"}).run();

    var skip_impl: TestingUsage = .{ .skip_fragments = true };
    var skip_runner: RuleTester = .init(testing.allocator, skip_impl.rule());
    defer skip_runner.deinit();
    skip_runner.setFileName("Thing.mixin.zig");
    try skip_runner.withPass(&.{"fn run() void {\n    testing.helper();\n}"}).run();
}

const std = @import("std");
const testing = std.testing;

const zlint = @import("zlint");
const Ast = zlint.Semantic.Ast;
const Node = Ast.Node;
const Symbol = zlint.Semantic.Symbol;
const NodeWrapper = zlint.linter.rule.NodeWrapper;
const Rule = zlint.linter.rule.Rule;
const RuleTester = zlint.linter.tester;
const LinterContext = zlint.linter.lint_context;
