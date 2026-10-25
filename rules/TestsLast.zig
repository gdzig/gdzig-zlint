//! ## What This Rule Does
//! Enforces gdzig's test placement.
//!
//! Handwritten test declarations belong at file scope, grouped after all
//! production declarations and immediately before the final imports and
//! aliases.
//!
//! When a `testing` namespace is present, it goes directly above the first
//! test block, after all production declarations.
//!
//! Hand-written `*.mixin.zig` and `*.replace.zig` fragments are linted. Set
//! `skip_fragments` to exclude them.

pub const meta: Rule.Meta = .{
    .name = "gdzig-tests-last",
    .category = .style,
    .default = .warning,
};

/// Skip hand-written mixin and replace fragments.
skip_fragments: bool = false,

/// Require the `testing` namespace to sit directly above the first test.
check_testing_namespace: bool = true,

const TestsLast = @This();

/// Checks that tests are grouped after production declarations.
pub fn runOnce(self: *const TestsLast, ctx: *LinterContext) void {
    if (self.skip_fragments and helpers.isFragment(ctx.source.pathname)) return;

    const ast = ctx.ast();
    const roots = ast.rootDecls();

    var first_test: ?usize = null;
    for (roots, 0..) |decl, i| {
        if (helpers.isTest(ast, decl)) {
            first_test = i;
            break;
        }
    }
    const first = first_test orelse return;

    var import_names = helpers.collectImportNames(ctx);
    defer import_names.deinit(ctx.gpa);

    if (self.check_testing_namespace) {
        for (roots, 0..) |decl, i| {
            if (!helpers.isTestingNamespace(ast, decl)) continue;
            if (i + 1 != first) {
                ctx.report(ctx.diagnostic(
                    "place the `testing` namespace directly above the first test block",
                    .{ ctx.spanN(decl), ctx.spanN(roots[first]) },
                ));
            }
            break;
        }
    }

    var last_test = first;
    var reported_production = false;
    for (roots[first..], first..) |decl, i| {
        if (helpers.isTest(ast, decl)) {
            last_test = i;
            continue;
        }
        if (helpers.isImportDecl(ast, decl, import_names.items)) continue;
        if (self.check_testing_namespace and helpers.isTestingNamespace(ast, decl)) continue;

        if (!reported_production) {
            ctx.report(ctx.diagnostic(
                "production declarations must come before test declarations",
                .{ ctx.spanN(decl), ctx.spanN(roots[first]) },
            ));
            reported_production = true;
        }
    }

    for (roots, 0..) |decl, i| {
        if (i >= last_test) break;
        if (!helpers.isImportDecl(ast, decl, import_names.items)) continue;
        ctx.report(ctx.diagnostic(
            "tests must be grouped before the final imports",
            .{ ctx.spanN(roots[last_test]), ctx.spanN(decl) },
        ));
        break;
    }
}

/// Checks that test declarations are at file scope.
pub fn runOnNode(self: *const TestsLast, wrapper: NodeWrapper, ctx: *LinterContext) void {
    if (self.skip_fragments and helpers.isFragment(ctx.source.pathname)) return;
    if (wrapper.node.tag != .test_decl) return;

    const parent = ctx.links().getParent(wrapper.idx) orelse return;
    if (parent != .root) {
        ctx.report(ctx.diagnostic(
            "test declarations must be at file scope",
            .{ctx.spanN(wrapper.idx)},
        ));
    }
}

/// Returns the rule descriptor.
pub fn rule(self: *TestsLast) Rule {
    return .init(self);
}

const helpers = struct {
    const ImportInfo = struct {
        path: []const u8,
        member: ?[]const u8,
    };

    fn isFragment(path: ?[]const u8) bool {
        const p = path orelse return false;
        return std.mem.endsWith(u8, p, ".mixin.zig") or std.mem.endsWith(u8, p, ".replace.zig");
    }

    fn declName(ast: *const Ast, decl: Node.Index) ?[]const u8 {
        const var_decl = ast.fullVarDecl(decl) orelse return null;
        return ast.tokenSlice(var_decl.ast.mut_token + 1);
    }

    fn isTest(ast: *const Ast, decl: Node.Index) bool {
        return ast.nodeTag(decl) == .test_decl;
    }

    fn isTestingNamespace(ast: *const Ast, decl: Node.Index) bool {
        const name = declName(ast, decl) orelse return false;
        if (!std.mem.eql(u8, name, "testing")) return false;

        const var_decl = ast.fullVarDecl(decl) orelse return false;
        const init = var_decl.ast.init_node.unwrap() orelse return false;
        return switch (ast.nodeTag(init)) {
            .container_decl,
            .container_decl_trailing,
            .container_decl_two,
            .container_decl_two_trailing,
            .container_decl_arg,
            .container_decl_arg_trailing,
            => true,
            else => false,
        };
    }

    fn importPathFromCall(ast: *const Ast, call: Node.Index) ?[]const u8 {
        if (!std.mem.eql(u8, ast.tokenSlice(ast.nodeMainToken(call)), "@import")) return null;
        var buf: [2]Node.Index = undefined;
        const params = ast.builtinCallParams(&buf, call) orelse return null;
        if (params.len != 1) return null;

        const tok = ast.nodeMainToken(params[0]);
        if (ast.tokenTag(tok) != .string_literal) return null;

        const raw = ast.tokenSlice(tok);
        return raw[1 .. raw.len - 1];
    }

    fn importInfoFromExpr(ast: *const Ast, node: Node.Index) ?ImportInfo {
        switch (ast.nodeTag(node)) {
            .builtin_call_two, .builtin_call_two_comma, .builtin_call, .builtin_call_comma => {
                const path = importPathFromCall(ast, node) orelse return null;
                return .{
                    .path = path,
                    .member = null,
                };
            },
            .field_access => {
                const data = ast.nodeData(node).node_and_token;
                const base = importInfoFromExpr(ast, data[0]) orelse return null;
                return .{
                    .path = base.path,
                    .member = ast.tokenSlice(data[1]),
                };
            },
            else => return null,
        }
    }

    fn importInfoFromDecl(ast: *const Ast, decl: Node.Index) ?ImportInfo {
        const var_decl = ast.fullVarDecl(decl) orelse return null;
        const init = var_decl.ast.init_node.unwrap() orelse return null;
        return importInfoFromExpr(ast, init);
    }

    fn leftmostIdentifier(ast: *const Ast, node: Node.Index) ?Node.Index {
        return switch (ast.nodeTag(node)) {
            .identifier => node,
            .field_access, .unwrap_optional => leftmostIdentifier(ast, ast.nodeData(node).node_and_token[0]),
            .address_of, .deref => leftmostIdentifier(ast, ast.nodeData(node).node),
            else => null,
        };
    }

    fn isImportDecl(ast: *const Ast, decl: Node.Index, names: []const []const u8) bool {
        if (importInfoFromDecl(ast, decl) != null) return true;

        const var_decl = ast.fullVarDecl(decl) orelse return false;
        const init = var_decl.ast.init_node.unwrap() orelse return false;
        const identifier = leftmostIdentifier(ast, init) orelse return false;
        const root_name = ast.tokenSlice(ast.nodeMainToken(identifier));

        for (names) |name| {
            if (std.mem.eql(u8, name, root_name)) return true;
        }
        return false;
    }

    fn containsName(names: []const []const u8, name: []const u8) bool {
        for (names) |known| {
            if (std.mem.eql(u8, known, name)) return true;
        }
        return false;
    }

    fn collectImportNames(ctx: *LinterContext) std.ArrayListUnmanaged([]const u8) {
        const ast = ctx.ast();
        var names: std.ArrayListUnmanaged([]const u8) = .empty;

        for (ast.rootDecls()) |decl| {
            if (importInfoFromDecl(ast, decl) == null) continue;
            const name = declName(ast, decl) orelse continue;
            names.append(ctx.gpa, name) catch @panic("OOM");
        }

        var changed = true;
        while (changed) {
            changed = false;
            for (ast.rootDecls()) |decl| {
                const decl_name = declName(ast, decl) orelse continue;
                if (containsName(names.items, decl_name)) continue;

                const var_decl = ast.fullVarDecl(decl) orelse continue;
                const init = var_decl.ast.init_node.unwrap() orelse continue;
                const identifier = leftmostIdentifier(ast, init) orelse continue;
                const root_name = ast.tokenSlice(ast.nodeMainToken(identifier));

                var name_index: usize = 0;
                while (name_index < names.items.len) : (name_index += 1) {
                    if (!std.mem.eql(u8, names.items[name_index], root_name)) continue;
                    names.append(ctx.gpa, decl_name) catch @panic("OOM");
                    changed = true;
                    break;
                }
            }
        }

        return names;
    }
};

test TestsLast {
    @setEvalBranchQuota(100_000);
    const passing =
        \\const Thing = @This();
        \\
        \\pub fn foo() void {}
        \\
        \\const testing = struct {
        \\    pub fn helper() void {}
        \\};
        \\
        \\test "one" {}
        \\
        \\test "two" {}
        \\
        \\const std = @import("std");
        \\const Io = std.Io;
        \\const Writer = Io.Writer;
        \\
        \\const gdzig = @import("gdzig");
        \\const raw = &gdzig.raw;
    ;
    const passing_without_testing_namespace =
        \\const Thing = @This();
        \\
        \\pub fn foo() void {}
        \\
        \\test "one" {}
        \\
        \\const std = @import("std");
    ;
    const production_after_test =
        \\const Thing = @This();
        \\
        \\test "one" {}
        \\
        \\pub fn foo() void {}
    ;
    const testing_namespace_not_adjacent =
        \\const Thing = @This();
        \\
        \\const testing = struct {};
        \\
        \\pub fn foo() void {}
        \\
        \\test "one" {}
    ;
    const import_before_test =
        \\const std = @import("std");
        \\
        \\test "one" {}
    ;
    const nested_test =
        \\const Thing = struct {
        \\    test "nested" {}
        \\};
    ;

    var implementation = TestsLast{};
    var runner = RuleTester.init(testing.allocator, implementation.rule());
    defer runner.deinit();
    runner.setFileName("Test.zig");
    try runner
        .withPass(&.{ passing, passing_without_testing_namespace })
        .withFail(&.{ production_after_test, testing_namespace_not_adjacent, import_before_test, nested_test })
        .run();

    var no_check_impl = TestsLast{ .check_testing_namespace = false };
    var no_check_runner = RuleTester.init(testing.allocator, no_check_impl.rule());
    defer no_check_runner.deinit();
    no_check_runner.setFileName("Test.zig");
    try no_check_runner.withPass(&.{testing_namespace_not_adjacent}).run();

    var fragment_impl = TestsLast{ .skip_fragments = true };
    var fragment_runner = RuleTester.init(testing.allocator, fragment_impl.rule());
    defer fragment_runner.deinit();
    fragment_runner.setFileName("Aabb.mixin.zig");
    try fragment_runner.withPass(&.{production_after_test}).run();

    var fragment_check = TestsLast{};
    var fragment_check_runner = RuleTester.init(testing.allocator, fragment_check.rule());
    defer fragment_check_runner.deinit();
    fragment_check_runner.setFileName("Aabb.mixin.zig");
    try fragment_check_runner.withFail(&.{production_after_test}).run();
}

const std = @import("std");
const testing = std.testing;

const zlint = @import("zlint");
const Ast = zlint.Semantic.Ast;
const Node = Ast.Node;
const Rule = zlint.linter.rule.Rule;
const RuleTester = zlint.linter.tester;
const NodeWrapper = zlint.linter.rule.NodeWrapper;
const LinterContext = zlint.linter.lint_context;
