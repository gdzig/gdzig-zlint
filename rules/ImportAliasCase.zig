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
//! Generated `*.mixin.zig` and `*.replace.zig` fragments are skipped.

pub const meta: Rule.Meta = .{
    .name = "gdzig-import-alias-case",
    .category = .style,
    .default = .warning,
};

/// Skip generated mixin and replace fragments.
skip_fragments: bool = true,

const ImportAliasCase = @This();

pub fn runOnce(self: *const ImportAliasCase, ctx: *LinterContext) void {
    const pathname = ctx.source.pathname orelse return;
    if (self.skip_fragments and helpers.isFragment(pathname)) return;

    const ast = ctx.ast();
    for (ast.rootDecls()) |decl| {
        const info = helpers.importInfoFromDecl(ast, decl) orelse continue;
        if (!std.mem.endsWith(u8, info.path, ".zig")) continue;

        const base = helpers.basenameWithoutExtension(info.path);
        if (!helpers.isTitleCase(base) and !helpers.isSnakeCase(base)) continue;

        const alias = helpers.declName(ast, decl) orelse continue;
        const expected = info.member orelse base;
        if (!std.mem.eql(u8, alias, expected)) {
            ctx.report(ctx.diagnosticf(
                "import alias '{s}' must be '{s}' for '{s}'",
                .{ alias, expected, info.path },
                .{ctx.spanN(decl)},
            ));
        }
    }
}

pub fn rule(self: *ImportAliasCase) Rule {
    return Rule.init(self);
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
        switch (ast.nodeTag(node)) {
            .builtin_call_two, .builtin_call_two_comma, .builtin_call, .builtin_call_comma => {
                const path = importPathFromCall(ast, node) orelse return null;
                return .{ .path = path, .member = null };
            },
            .field_access => {
                const data = ast.nodeData(node).node_and_token;
                const base = importInfoFromExpr(ast, data[0]) orelse return null;
                return .{ .path = base.path, .member = ast.tokenSlice(data[1]) };
            },
            else => return null,
        }
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

    var implementation = ImportAliasCase{};
    var runner = RuleTester.init(testing.allocator, implementation.rule());
    defer runner.deinit();
    runner.setFileName("Test.zig");
    try runner
        .withPass(&.{passing})
        .withFail(&.{ wrong_type_alias, wrong_namespace_alias, wrong_member_alias })
        .run();

    var fragment_impl = ImportAliasCase{};
    var fragment_runner = RuleTester.init(testing.allocator, fragment_impl.rule());
    defer fragment_runner.deinit();
    fragment_runner.setFileName("Aabb.mixin.zig");
    try fragment_runner.withPass(&.{wrong_type_alias}).run();
}

const std = @import("std");
const testing = std.testing;

const zlint = @import("zlint");
const Ast = zlint.Semantic.Ast;
const Node = Ast.Node;
const Rule = zlint.linter.rule.Rule;
const RuleTester = zlint.linter.tester;
const LinterContext = zlint.linter.lint_context;
