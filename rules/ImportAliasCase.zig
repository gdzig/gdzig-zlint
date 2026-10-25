//! ## What This Rule Does
//! Requires an import alias to match the imported file's name.
//!
//! `const Config = @import("Config.zig");` and
//! `const version = @import("version.zig");` are correct.
//! `const config = @import("Config.zig");` is not.
//!
//! When a namespace file exposes a single named type, the alias may name that
//! member instead: `const Version = @import("version.zig").Version;`.
//!
//! Hand-written `*.mixin.zig` and `*.replace.zig` fragments are linted. Set
//! `skip_fragments` to exclude them.

pub const meta: Rule.Meta = .{
    .name = "gdzig-import-alias-case",
    .category = .style,
    .default = .warning,
};

/// Skip hand-written mixin and replace fragments.
skip_fragments: bool = false,

const ImportAliasCase = @This();

/// Checks import aliases against the imported file's name.
pub fn runOnNode(self: *const ImportAliasCase, wrapper: NodeWrapper, ctx: *LinterContext) void {
    if (self.skip_fragments and helpers.isFragment(ctx.source.pathname)) return;

    switch (wrapper.node.tag) {
        .global_var_decl,
        .local_var_decl,
        .aligned_var_decl,
        .simple_var_decl,
        => {},
        else => return,
    }

    const ast = ctx.ast();
    const decl = wrapper.idx;
    const info = helpers.importInfoFromDecl(ast, decl) orelse return;
    if (!std.mem.endsWith(u8, info.path, ".zig")) return;

    const base = helpers.basenameWithoutExtension(info.path);
    if (!helpers.isTitleCase(base) and !helpers.isSnakeCase(base)) return;

    const alias = helpers.declName(ast, decl) orelse return;
    const expected = info.member orelse base;
    if (!std.mem.eql(u8, alias, expected)) {
        ctx.report(ctx.diagnosticf(
            "import alias '{s}' must be '{s}' for '{s}'",
            .{ alias, expected, info.path },
            .{ctx.spanN(decl)},
        ));
    }
}

/// Returns the rule descriptor.
pub fn rule(self: *ImportAliasCase) Rule {
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

    fn basenameWithoutExtension(path: []const u8) []const u8 {
        var base = std.fs.path.basename(path);
        if (std.mem.endsWith(u8, base, ".zig")) base = base[0 .. base.len - 4];
        if (std.mem.endsWith(u8, base, ".mixin")) base = base[0 .. base.len - 6];
        if (std.mem.endsWith(u8, base, ".replace")) base = base[0 .. base.len - 8];
        return base;
    }

    fn isTitleCase(name: []const u8) bool {
        var saw_alpha = false;
        for (name) |c| {
            if (std.ascii.isAlphabetic(c)) {
                if (!saw_alpha) {
                    if (!std.ascii.isUpper(c)) return false;
                    saw_alpha = true;
                }
            } else if (!std.ascii.isDigit(c)) {
                return false;
            }
        }
        return saw_alpha;
    }

    fn isSnakeCase(name: []const u8) bool {
        var saw_alpha = false;
        for (name) |c| {
            if (std.ascii.isAlphabetic(c)) {
                if (std.ascii.isUpper(c)) return false;
                saw_alpha = true;
            } else if (!std.ascii.isDigit(c) and c != '_') {
                return false;
            }
        }
        return saw_alpha;
    }

    fn declName(ast: *const Ast, decl: Node.Index) ?[]const u8 {
        const var_decl = ast.fullVarDecl(decl) orelse return null;
        return ast.tokenSlice(var_decl.ast.mut_token + 1);
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
        const expr = unwrapGrouped(ast, node);
        switch (ast.nodeTag(expr)) {
            .builtin_call_two, .builtin_call_two_comma, .builtin_call, .builtin_call_comma => {
                const path = importPathFromCall(ast, expr) orelse return null;
                return .{
                    .path = path,
                    .member = null,
                };
            },
            .field_access => {
                const data = ast.nodeData(expr).node_and_token;
                const base = importInfoFromExpr(ast, data[0]) orelse return null;
                return .{
                    .path = base.path,
                    .member = ast.tokenSlice(data[1]),
                };
            },
            else => return null,
        }
    }

    fn unwrapGrouped(ast: *const Ast, node: Node.Index) Node.Index {
        var current = node;
        while (ast.nodeTag(current) == .grouped_expression) {
            current = ast.nodeData(current).node_and_token[0];
        }
        return current;
    }

    fn importInfoFromDecl(ast: *const Ast, decl: Node.Index) ?ImportInfo {
        const var_decl = ast.fullVarDecl(decl) orelse return null;
        const init = var_decl.ast.init_node.unwrap() orelse return null;
        return importInfoFromExpr(ast, init);
    }
};

test ImportAliasCase {
    @setEvalBranchQuota(100_000);
    const passing =
        \\const std = @import("std");
        \\const Config = @import("Config.zig");
        \\const version_dispatch = @import("version_dispatch.zig");
        \\const Version = @import("version.zig").Version;
        \\const NestedConfig = @import("../NestedConfig.zig");
    ;
    const wrong_type_alias =
        \\const config = @import("Config.zig");
    ;
    const wrong_namespace_alias =
        \\const Version = @import("version.zig");
    ;
    const wrong_member_alias =
        \\const version = @import("version.zig").Version;
    ;
    const wrong_relative_alias =
        \\const nested_config = @import("../NestedConfig.zig");
    ;
    const nested_import =
        \\fn load() void {
        \\    const config = @import("Config.zig");
        \\    _ = config;
        \\}
    ;

    var implementation = ImportAliasCase{};
    var runner = RuleTester.init(testing.allocator, implementation.rule());
    defer runner.deinit();
    runner.setFileName("Test.zig");
    try runner
        .withPass(&.{passing})
        .withFail(&.{
            wrong_type_alias,
            wrong_namespace_alias,
            wrong_member_alias,
            wrong_relative_alias,
            nested_import,
        })
        .run();

    const fragment_source =
        \\const Aabb = @import("Aabb.mixin.zig");
    ;
    var fragment_impl = ImportAliasCase{};
    var fragment_runner = RuleTester.init(testing.allocator, fragment_impl.rule());
    defer fragment_runner.deinit();
    fragment_runner.setFileName("Aabb.mixin.zig");
    try fragment_runner
        .withPass(&.{fragment_source})
        .withFail(&.{"const aabb = @import(\"Aabb.mixin.zig\");"})
        .run();

    var skip_impl = ImportAliasCase{ .skip_fragments = true };
    var skip_runner = RuleTester.init(testing.allocator, skip_impl.rule());
    defer skip_runner.deinit();
    skip_runner.setFileName("Aabb.mixin.zig");
    try skip_runner.withPass(&.{"const aabb = @import(\"Aabb.mixin.zig\");"}).run();
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
