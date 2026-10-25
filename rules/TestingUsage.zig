//! ## What This Rule Does
//! Restricts use of a `testing` namespace to test code.
//!
//! Test-only helpers live in a `const testing = struct { ... }` namespace.
//! References such as `testing.helper()` or `module.testing.helper()` are only
//! allowed inside a `test` block, or inside the `testing` namespace itself.
//!
//! This rule is syntactic. It cannot see whether a `testing` namespace in
//! another file is `pub` for external callers, so it reports cross-file member
//! access outside tests too.
//!
//! Generated `*.mixin.zig` and `*.replace.zig` fragments are skipped.

pub const meta: Rule.Meta = .{
    .name = "gdzig-testing-usage",
    .category = .style,
    .default = .warning,
};

/// Skip generated mixin and replace fragments.
skip_fragments: bool = true,

/// Namespace name reserved for test-only helpers.
namespace: []const u8 = "testing",

const TestingUsage = @This();

/// Checks `testing` namespace references for a test-block ancestor.
pub fn runOnNode(self: *const TestingUsage, wrapper: NodeWrapper, ctx: *LinterContext) void {
    if (self.skip_fragments and helpers.isFragment(ctx.source.pathname)) return;
    if (wrapper.node.tag != .field_access) return;

    const ast = ctx.ast();
    const data = ast.nodeData(wrapper.idx).node_and_token;
    const base = data[0];
    const field_token = data[1];

    const base_is_namespace = ast.nodeTag(base) == .identifier and
        std.mem.eql(u8, ast.tokenSlice(ast.nodeMainToken(base)), self.namespace);
    const field_is_namespace = std.mem.eql(u8, ast.tokenSlice(field_token), self.namespace);
    if (!base_is_namespace and !field_is_namespace) return;
    if (field_is_namespace and helpers.isIgnoredBase(ast, base)) return;

    if (helpers.isAllowed(ctx, wrapper.idx, self.namespace)) return;

    ctx.report(ctx.diagnosticf(
        "the '{s}' namespace is only for test code; move this reference into a test block",
        .{self.namespace},
        .{ctx.spanN(wrapper.idx)},
    ));
}

/// Returns the rule descriptor.
pub fn rule(self: *TestingUsage) Rule {
    return .init(self);
}

const helpers = struct {
    fn isFragment(path: ?[]const u8) bool {
        const p = path orelse return false;
        return std.mem.endsWith(u8, p, ".mixin.zig") or std.mem.endsWith(u8, p, ".replace.zig");
    }

    fn isAllowed(ctx: *LinterContext, node: Node.Index, namespace: []const u8) bool {
        const ast = ctx.ast();
        var current = node;
        while (ctx.links().getParent(current)) |parent| {
            switch (ast.nodeTag(parent)) {
                .test_decl => return true,
                .container_decl,
                .container_decl_two,
                .container_decl_arg,
                .tagged_union,
                .tagged_union_two,
                .tagged_union_enum_tag,
                => if (isNamespaceContainer(ctx, parent, namespace)) return true,
                else => {},
            }
            current = parent;
        }
        return false;
    }

    fn isNamespaceContainer(ctx: *LinterContext, container: Node.Index, namespace: []const u8) bool {
        const ast = ctx.ast();
        const parent = ctx.links().getParent(container) orelse return false;
        const decl = ast.fullVarDecl(parent) orelse return false;
        const name_token = decl.ast.mut_token + 1;
        if (name_token >= ast.tokens.len) return false;
        if (ast.tokenTag(name_token) != .identifier) return false;
        return std.mem.eql(u8, ast.tokenSlice(name_token), namespace);
    }

    fn isIgnoredBase(ast: *const Ast, base: Node.Index) bool {
        if (ast.nodeTag(base) != .identifier) return false;
        const base_name = ast.tokenSlice(ast.nodeMainToken(base));
        return std.mem.eql(u8, base_name, "std") or std.mem.eql(u8, base_name, "builtin");
    }
};

test TestingUsage {
    @setEvalBranchQuota(100_000);

    var impl = TestingUsage{};
    var runner = RuleTester.init(testing.allocator, impl.rule());
    defer runner.deinit();
    try runner
        .withPass(&.{
            "test \"helper\" {\n    testing.helper();\n}",
            "test \"value\" {\n    _ = Codegen.testing.value;\n}",
            "const testing = struct {\n    pub fn helper() void {}\n};",
            "const testing = std.testing;",
            "const testing = struct {\n" ++
                "    fn call() void {\n" ++
                "        testing.helper();\n" ++
                "    }\n" ++
                "    fn helper() void {}\n" ++
                "};",
        })
        .withFail(&.{
            "fn run() void {\n    testing.helper();\n}",
            "const value = Codegen.testing.value;",
            "const value = testing.value;",
        })
        .run();

    var fragment_impl = TestingUsage{ .skip_fragments = false };
    var fragment_runner = RuleTester.init(testing.allocator, fragment_impl.rule());
    defer fragment_runner.deinit();
    fragment_runner.setFileName("Thing.mixin.zig");
    try fragment_runner.withFail(&.{"fn run() void {\n    testing.helper();\n}"}).run();
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
