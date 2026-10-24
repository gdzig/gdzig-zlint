//! ## What This Rule Does
//! Enforces gdzig's import placement and grouping.
//!
//! Imports and aliases derived from imports go at the bottom of the file,
//! after all other declarations. They are grouped in this order, with a blank
//! line between groups:
//!
//! 1. Zig standard library
//! 2. Third-party packages
//! 3. Project files and packages
//!
//! Packages in `project_packages` are treated as project imports. Relative
//! paths and paths ending in `.zig` are always project imports. The generated
//! `build_options` module is grouped with std.
//!
//! Generated `*.mixin.zig` and `*.replace.zig` fragments are skipped.

pub const meta: Rule.Meta = .{
    .name = "gdzig-imports-last",
    .category = .style,
    .default = .warning,
};

/// Skip generated mixin and replace fragments.
skip_fragments: bool = true,

/// Require the std, third-party, project group order.
check_group_order: bool = true,

/// Require a blank line between import groups.
check_blank_lines: bool = true,

/// Package names that are part of this project rather than third-party.
project_packages: []const []const u8 = &.{},

const ImportsLast = @This();

pub fn runOnce(self: *const ImportsLast, ctx: *LinterContext) void {
    if (self.skip_fragments and helpers.isFragment(ctx.source.pathname)) return;

    var collected = helpers.collectImports(ctx, self.project_packages);
    defer collected.deinit();
    if (collected.imports.items.len == 0) return;

    const roots = ctx.ast().rootDecls();

    var last_non_import: ?usize = null;
    for (roots, 0..) |decl, i| {
        if (!helpers.isImportDecl(collected.imports.items, decl)) last_non_import = i;
    }

    if (last_non_import) |last| {
        for (collected.imports.items) |imp| {
            const index = std.mem.indexOfScalar(Node.Index, roots, imp.decl) orelse continue;
            if (index < last) {
                ctx.report(ctx.diagnostic(
                    "imports and import-derived aliases must be placed after all other declarations",
                    .{ ctx.spanN(imp.decl), ctx.spanN(roots[last]) },
                ));
                break;
            }
        }
    }

    if (self.check_group_order) {
        var previous: ?helpers.Group = null;
        for (collected.imports.items) |imp| {
            if (previous) |prev| {
                if (@intFromEnum(imp.group) < @intFromEnum(prev)) {
                    ctx.report(ctx.diagnosticf(
                        "import group '{s}' must come before '{s}'",
                        .{ helpers.groupName(imp.group), helpers.groupName(prev) },
                        .{ctx.spanN(imp.decl)},
                    ));
                }
            }
            previous = imp.group;
        }
    }

    if (self.check_blank_lines) {
        var i: usize = 1;
        while (i < collected.imports.items.len) : (i += 1) {
            const prev = collected.imports.items[i - 1];
            const curr = collected.imports.items[i];
            if (prev.group == curr.group) continue;

            const prev_end = ctx.semantic.nodeSpan(prev.decl).end;
            const curr_start = ctx.semantic.nodeSpan(curr.decl).start;
            if (helpers.newlineCount(ctx.source.text(), prev_end, curr_start) < 2) {
                ctx.report(ctx.diagnostic(
                    "separate import groups with a blank line",
                    .{ctx.spanN(curr.decl)},
                ));
            }
        }
    }
}

pub fn rule(self: *ImportsLast) Rule {
    return Rule.init(self);
}

const helpers = struct {
    const Group = enum(u8) {
        std = 0,
        third_party = 1,
        project = 2,
    };

    const Import = struct {
        decl: Node.Index,
        group: Group,
    };

    const NameGroup = struct {
        name: []const u8,
        group: Group,
    };

    const ImportInfo = struct {
        path: []const u8,
        member: ?[]const u8,
    };

    const Collected = struct {
        imports: std.ArrayListUnmanaged(Import) = .empty,
        names: std.ArrayListUnmanaged(NameGroup) = .empty,
        gpa: std.mem.Allocator,

        fn deinit(self: *Collected) void {
            self.imports.deinit(self.gpa);
            self.names.deinit(self.gpa);
        }
    };

    fn groupName(group: Group) []const u8 {
        return switch (group) {
            .std => "std",
            .third_party => "third-party",
            .project => "project",
        };
    }

    fn isFragment(path: ?[]const u8) bool {
        const p = path orelse return false;
        return std.mem.endsWith(u8, p, ".mixin.zig") or std.mem.endsWith(u8, p, ".replace.zig");
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

    fn classify(path: []const u8, project_packages: []const []const u8) Group {
        if (std.mem.eql(u8, path, "std") or
            std.mem.eql(u8, path, "builtin") or
            std.mem.eql(u8, path, "build_options"))
        {
            return .std;
        }
        if (path.len > 0 and path[0] == '.') return .project;
        if (std.mem.endsWith(u8, path, ".zig")) return .project;
        if (std.mem.indexOfScalar(u8, path, '/') != null) return .project;
        for (project_packages) |pkg| {
            if (std.mem.eql(u8, path, pkg)) return .project;
        }
        return .third_party;
    }

    fn importGroupFromExpr(
        ast: *const Ast,
        node: Node.Index,
        names: []const NameGroup,
        project_packages: []const []const u8,
    ) ?Group {
        switch (ast.nodeTag(node)) {
            .identifier => {
                const name = ast.tokenSlice(ast.nodeMainToken(node));
                for (names) |name_group| {
                    if (std.mem.eql(u8, name_group.name, name)) return name_group.group;
                }
                return null;
            },
            .field_access => {
                return importGroupFromExpr(ast, ast.nodeData(node).node_and_token[0], names, project_packages);
            },
            .address_of, .deref => {
                return importGroupFromExpr(ast, ast.nodeData(node).node, names, project_packages);
            },
            .unwrap_optional => {
                return importGroupFromExpr(ast, ast.nodeData(node).node_and_token[0], names, project_packages);
            },
            .builtin_call_two, .builtin_call_two_comma, .builtin_call, .builtin_call_comma => {
                if (importPathFromCall(ast, node)) |path| return classify(path, project_packages);
                return null;
            },
            else => return null,
        }
    }

    fn collectImports(ctx: *LinterContext, project_packages: []const []const u8) Collected {
        const ast = ctx.ast();
        var result = Collected{ .gpa = ctx.gpa };

        for (ast.rootDecls()) |decl| {
            const info = importInfoFromDecl(ast, decl) orelse continue;
            const name = declName(ast, decl) orelse continue;
            const group = classify(info.path, project_packages);
            result.imports.append(ctx.gpa, .{ .decl = decl, .group = group }) catch @panic("OOM");
            result.names.append(ctx.gpa, .{ .name = name, .group = group }) catch @panic("OOM");
        }

        var changed = true;
        while (changed) {
            changed = false;
            for (ast.rootDecls()) |decl| {
                if (isImportDecl(result.imports.items, decl)) continue;

                const var_decl = ast.fullVarDecl(decl) orelse continue;
                const init = var_decl.ast.init_node.unwrap() orelse continue;
                const group = importGroupFromExpr(ast, init, result.names.items, project_packages) orelse continue;
                const name = declName(ast, decl) orelse continue;

                result.imports.append(ctx.gpa, .{ .decl = decl, .group = group }) catch @panic("OOM");
                result.names.append(ctx.gpa, .{ .name = name, .group = group }) catch @panic("OOM");
                changed = true;
            }
        }

        std.mem.sort(Import, result.imports.items, {}, lessThanImport);
        return result;
    }

    fn isImportDecl(imports: []const Import, decl: Node.Index) bool {
        for (imports) |imp| {
            if (imp.decl == decl) return true;
        }
        return false;
    }

    fn newlineCount(source: []const u8, from: u32, to: u32) usize {
        var count: usize = 0;
        for (source[from..to]) |c| {
            if (c == '\n') count += 1;
        }
        return count;
    }

    fn lessThanImport(_: void, a: Import, b: Import) bool {
        return @intFromEnum(a.decl) < @intFromEnum(b.decl);
    }
};

test ImportsLast {
    @setEvalBranchQuota(100_000);
    const passing =
        \\const Thing = @This();
        \\
        \\pub fn foo() void {}
        \\
        \\const std = @import("std");
        \\const Writer = std.Io.Writer;
        \\
        \\const casez = @import("casez");
        \\
        \\const Config = @import("Config.zig");
    ;
    const passing_alias_chain =
        \\const Thing = @This();
        \\
        \\pub fn foo() void {}
        \\
        \\const std = @import("std");
        \\const Io = std.Io;
        \\const Writer = Io.Writer;
        \\
        \\const Config = @import("Config.zig");
    ;
    const passing_import_member =
        \\const Thing = @This();
        \\
        \\pub fn foo() void {}
        \\
        \\const std = @import("std");
        \\
        \\const GodotApi = @import("common").GodotApi;
        \\const Version = @import("common").Version;
    ;
    const passing_build_options =
        \\const Thing = @This();
        \\
        \\pub fn foo() void {}
        \\
        \\const std = @import("std");
        \\const build_options = @import("build_options");
        \\
        \\const Config = @import("Config.zig");
    ;
    const passing_unary_alias =
        \\const Thing = @This();
        \\
        \\pub fn foo() void {}
        \\
        \\const gdzig = @import("gdzig");
        \\const raw = &gdzig.raw;
    ;
    const import_before_declaration =
        \\const std = @import("std");
        \\
        \\pub fn foo() void {}
    ;
    const wrong_group_order =
        \\const Thing = @This();
        \\
        \\pub fn foo() void {}
        \\
        \\const Config = @import("Config.zig");
        \\
        \\const std = @import("std");
    ;
    const missing_blank_line =
        \\const Thing = @This();
        \\
        \\pub fn foo() void {}
        \\
        \\const std = @import("std");
        \\const Config = @import("Config.zig");
    ;

    var implementation = ImportsLast{};
    var runner = RuleTester.init(testing.allocator, implementation.rule());
    defer runner.deinit();
    runner.setFileName("Test.zig");
    try runner
        .withPass(&.{
            passing,
            passing_alias_chain,
            passing_import_member,
            passing_build_options,
            passing_unary_alias,
        })
        .withFail(&.{ import_before_declaration, wrong_group_order, missing_blank_line })
        .run();

    var fragment_impl = ImportsLast{};
    var fragment_runner = RuleTester.init(testing.allocator, fragment_impl.rule());
    defer fragment_runner.deinit();
    fragment_runner.setFileName("Aabb.mixin.zig");
    try fragment_runner.withPass(&.{import_before_declaration}).run();
}

const std = @import("std");
const testing = std.testing;

const zlint = @import("zlint");
const Ast = zlint.Semantic.Ast;
const Node = Ast.Node;
const Rule = zlint.linter.rule.Rule;
const RuleTester = zlint.linter.tester;
const LinterContext = zlint.linter.lint_context;
