//! ## What This Rule Does
//! Requires imports and import-derived aliases to appear at a configured
//! location: after all other declarations (`bottom`, the default) or before
//! all other declarations (`top`).
//!
//! Import ordering, grouping, and blank lines are enforced separately by
//! `gdzig-imports-sorted`. This rule only checks placement, so a file can
//! enable either check independently.
//!
//! Hand-written `*.mixin.zig` and `*.replace.zig` fragments are linted. Set
//! `skip_fragments` to exclude them.

pub const meta: Rule.Meta = .{
    .name = "gdzig-imports-placement",
    .category = .style,
    .default = .warning,
    .fix = .disabled,
};

pub const Position = enum {
    /// Imports follow all other declarations.
    bottom,
    /// Imports precede all other declarations.
    top,
};

/// Where imports belong relative to the file's other declarations.
position: Position = .bottom,

/// Skip hand-written mixin and replace fragments.
skip_fragments: bool = false,

const ImportsPlacement = @This();

/// Checks where the import block sits relative to other declarations.
pub fn runOnce(self: *const ImportsPlacement, ctx: *LinterContext) void {
    if (self.skip_fragments and isFragment(ctx.source.pathname)) return;

    const ast = ctx.ast();
    const roots = ast.rootDecls();
    if (roots.len < 2) return;

    var import_decls = collectImportDecls(ctx);
    defer import_decls.deinit(ctx.gpa);
    if (import_decls.items.len == 0) return;

    switch (self.position) {
        .bottom => {
            var last_non_import: ?usize = null;
            for (roots, 0..) |decl, i| {
                if (!isImportDecl(import_decls.items, decl)) last_non_import = i;
            }
            const last = last_non_import orelse return;

            for (roots, 0..) |decl, i| {
                if (i >= last) break;
                if (!isImportDecl(import_decls.items, decl)) continue;
                ctx.report(ctx.diagnostic(
                    "imports and import-derived aliases must be placed after all other declarations",
                    .{ ctx.spanN(decl), ctx.spanN(roots[last]) },
                ));
                return;
            }
        },
        .top => {
            var first_non_import: ?usize = null;
            for (roots, 0..) |decl, i| {
                if (!isImportDecl(import_decls.items, decl)) {
                    first_non_import = i;
                    break;
                }
            }
            const first = first_non_import orelse return;

            for (roots, 0..) |decl, i| {
                if (i <= first) continue;
                if (!isImportDecl(import_decls.items, decl)) continue;
                ctx.report(ctx.diagnostic(
                    "imports and import-derived aliases must be placed before all other declarations",
                    .{ ctx.spanN(decl), ctx.spanN(roots[first]) },
                ));
                return;
            }
        },
    }
}

/// Returns the rule descriptor.
pub fn rule(self: *ImportsPlacement) Rule {
    return .init(self);
}

fn isFragment(path: ?[]const u8) bool {
    const p = path orelse return false;
    return std.mem.endsWith(u8, p, ".mixin.zig") or std.mem.endsWith(u8, p, ".replace.zig");
}

fn collectImportDecls(ctx: *LinterContext) std.ArrayListUnmanaged(Node.Index) {
    const ast = ctx.ast();
    var decls: std.ArrayListUnmanaged(Node.Index) = .empty;
    var names: std.ArrayListUnmanaged([]const u8) = .empty;
    defer names.deinit(ctx.gpa);

    for (ast.rootDecls()) |decl| {
        if (!isDirectImportDecl(ast, decl)) continue;
        const name = declName(ast, decl) orelse continue;
        decls.append(ctx.gpa, decl) catch @panic("OOM");
        names.append(ctx.gpa, name) catch @panic("OOM");
    }

    var changed = true;
    while (changed) {
        changed = false;
        for (ast.rootDecls()) |decl| {
            if (isImportDecl(decls.items, decl)) continue;

            const var_decl = ast.fullVarDecl(decl) orelse continue;
            const init = var_decl.ast.init_node.unwrap() orelse continue;
            if (!isImportExpr(ast, init, names.items)) continue;
            const name = declName(ast, decl) orelse continue;

            decls.append(ctx.gpa, decl) catch @panic("OOM");
            names.append(ctx.gpa, name) catch @panic("OOM");
            changed = true;
        }
    }

    return decls;
}

fn isImportDecl(decls: []const Node.Index, decl: Node.Index) bool {
    for (decls) |candidate| {
        if (candidate == decl) return true;
    }
    return false;
}

fn declName(ast: *const Ast, decl: Node.Index) ?[]const u8 {
    const var_decl = ast.fullVarDecl(decl) orelse return null;
    return ast.tokenSlice(var_decl.ast.mut_token + 1);
}

fn isDirectImportDecl(ast: *const Ast, decl: Node.Index) bool {
    const var_decl = ast.fullVarDecl(decl) orelse return false;
    const init = var_decl.ast.init_node.unwrap() orelse return false;
    return isDirectImportExpr(ast, init);
}

fn isDirectImportExpr(ast: *const Ast, node: Node.Index) bool {
    const expr = unwrapGrouped(ast, node);
    switch (ast.nodeTag(expr)) {
        .builtin_call_two, .builtin_call_two_comma, .builtin_call, .builtin_call_comma => {
            return importPathFromCall(ast, expr) != null;
        },
        .field_access => return isDirectImportExpr(ast, ast.nodeData(expr).node_and_token[0]),
        else => return false,
    }
}

fn isImportExpr(ast: *const Ast, node: Node.Index, names: []const []const u8) bool {
    const expr = unwrapGrouped(ast, node);
    switch (ast.nodeTag(expr)) {
        .identifier => {
            const name = ast.tokenSlice(ast.nodeMainToken(expr));
            for (names) |candidate| {
                if (std.mem.eql(u8, candidate, name)) return true;
            }
            return false;
        },
        .field_access => return isImportExpr(ast, ast.nodeData(expr).node_and_token[0], names),
        .address_of, .deref => return isImportExpr(ast, ast.nodeData(expr).node, names),
        .unwrap_optional => return isImportExpr(ast, ast.nodeData(expr).node_and_token[0], names),
        .builtin_call_two, .builtin_call_two_comma, .builtin_call, .builtin_call_comma => {
            return importPathFromCall(ast, expr) != null;
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

test ImportsPlacement {
    @setEvalBranchQuota(100_000);
    const bottom_passing =
        \\const Thing = @This();
        \\
        \\pub fn foo() void {}
        \\
        \\const casez = @import("casez");
        \\const std = @import("std");
    ;
    const bottom_passing_aliases =
        \\const Thing = @This();
        \\
        \\pub fn foo() void {}
        \\
        \\const std = @import("std");
        \\const Io = std.Io;
        \\const Writer = Io.Writer;
        \\
        \\const casez = @import("casez");
    ;
    const top_passing =
        \\const std = @import("std");
        \\const casez = @import("casez");
        \\
        \\const Thing = @This();
        \\
        \\pub fn foo() void {}
    ;
    const top_passing_aliases =
        \\const std = @import("std");
        \\const Io = std.Io;
        \\const Writer = Io.Writer;
        \\
        \\const casez = @import("casez");
        \\
        \\const Thing = @This();
        \\
        \\pub fn foo() void {}
    ;
    const only_imports =
        \\const std = @import("std");
        \\const casez = @import("casez");
    ;
    const import_at_top =
        \\const std = @import("std");
        \\
        \\const Thing = @This();
        \\
        \\pub fn foo() void {}
    ;
    const import_at_bottom =
        \\const Thing = @This();
        \\
        \\pub fn foo() void {}
        \\
        \\const std = @import("std");
    ;
    const mixed =
        \\const std = @import("std");
        \\
        \\pub fn foo() void {}
        \\
        \\const casez = @import("casez");
    ;
    const derived_alias_at_top =
        \\const std = @import("std");
        \\const Writer = std.Io.Writer;
        \\
        \\pub fn foo() void {}
    ;
    const derived_alias_at_bottom =
        \\pub fn foo() void {}
        \\
        \\const std = @import("std");
        \\const Writer = std.Io.Writer;
    ;

    var bottom_impl = ImportsPlacement{};
    var bottom_runner = RuleTester.init(testing.allocator, bottom_impl.rule());
    defer bottom_runner.deinit();
    bottom_runner.setFileName("Test.zig");
    try bottom_runner
        .withPass(&.{ bottom_passing, bottom_passing_aliases, only_imports })
        .withFail(&.{ import_at_top, mixed, derived_alias_at_top })
        .run();

    var top_impl = ImportsPlacement{ .position = .top };
    var top_runner = RuleTester.init(testing.allocator, top_impl.rule());
    defer top_runner.deinit();
    top_runner.setFileName("Test.zig");
    try top_runner
        .withPass(&.{ top_passing, top_passing_aliases, import_at_top, only_imports })
        .withFail(&.{ import_at_bottom, mixed, derived_alias_at_bottom })
        .run();

    var fragment_impl = ImportsPlacement{ .skip_fragments = true };
    var fragment_runner = RuleTester.init(testing.allocator, fragment_impl.rule());
    defer fragment_runner.deinit();
    fragment_runner.setFileName("Aabb.mixin.zig");
    try fragment_runner.withPass(&.{import_at_top}).run();

    var fragment_check = ImportsPlacement{};
    var fragment_check_runner = RuleTester.init(testing.allocator, fragment_check.rule());
    defer fragment_check_runner.deinit();
    fragment_check_runner.setFileName("Aabb.mixin.zig");
    try fragment_check_runner.withFail(&.{import_at_top}).run();
}

const std = @import("std");
const testing = std.testing;

const zlint = @import("zlint");
const Ast = zlint.Semantic.Ast;
const Node = Ast.Node;
const Rule = zlint.linter.rule.Rule;
const RuleTester = zlint.linter.tester;
const LinterContext = zlint.linter.lint_context;
