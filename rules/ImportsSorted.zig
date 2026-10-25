//! ## What This Rule Does
//! Enforces gdzig's import ordering.
//!
//! Imports and aliases derived from imports are ordered in three sections:
//!
//! 1. Zig standard library imports (`std`, `builtin`, and their aliases).
//! 2. Package imports: bare names such as `casez`, `common`, or `build_options`.
//! 3. File imports: relative paths and paths containing `/`.
//!
//! Sort root groups alphabetically inside each section. A root group is one
//! root import plus the aliases derived from it. Separate root groups with a
//! blank line.
//!
//! `build_options` is a package import unless it is added to `std_modules`.
//!
//! Import placement is enforced separately by `gdzig-imports-last`.
//!
//! Generated `*.mixin.zig` and `*.replace.zig` fragments are skipped.

pub const meta: Rule.Meta = .{
    .name = "gdzig-imports-sorted",
    .category = .style,
    .default = .warning,
    .fix = .safe_fix,
};

/// Skip generated mixin and replace fragments.
skip_fragments: bool = true,

/// Paths that belong in the std section.
std_modules: []const []const u8 = &.{ "std", "builtin" },

const ImportsSorted = @This();

pub fn runOnce(self: *const ImportsSorted, ctx: *LinterContext) void {
    if (self.skip_fragments and helpers.isFragment(ctx.source.pathname)) return;

    const ast = ctx.ast();
    const roots = ast.rootDecls();

    var collected = helpers.collect(ctx, self.std_modules);
    defer collected.deinit();
    if (collected.entries.items.len == 0) return;

    std.mem.sort(helpers.Entry, collected.entries.items, {}, helpers.lessThanDecl);

    const sorted = ctx.gpa.dupe(helpers.Entry, collected.entries.items) catch @panic("OOM");
    defer ctx.gpa.free(sorted);
    std.mem.sort(helpers.Entry, sorted, {}, helpers.lessThanEntry);

    const imports_last = helpers.importsAreLast(roots, collected.entries.items);
    const order_ok = helpers.sameDeclOrder(collected.entries.items, sorted);
    const missing_blank = helpers.firstMissingBlank(ctx, collected.entries.items);

    if (order_ok and missing_blank == null) return;

    var replacement: std.ArrayListUnmanaged(u8) = .empty;
    defer replacement.deinit(ctx.gpa);
    const fix: ?helpers.ReorderFix = if (imports_last and helpers.canFix(ctx, collected.entries.items))
        helpers.buildFix(ctx, collected.entries.items, sorted, &replacement)
    else
        null;

    if (!order_ok) {
        const bad = helpers.firstOrderMismatch(collected.entries.items, sorted);
        const diagnostic = ctx.diagnostic(
            "import root groups must be ordered std, package, file, then alphabetically",
            .{ctx.spanN(collected.entries.items[bad].decl)},
        );
        if (fix) |f| {
            ctx.reportWithFix(f, diagnostic, &helpers.applyReorder);
        } else {
            ctx.report(diagnostic);
        }
        return;
    }

    if (missing_blank) |bad| {
        const diagnostic = ctx.diagnostic(
            "separate import root groups with a blank line",
            .{ ctx.spanN(collected.entries.items[bad].decl), ctx.spanN(collected.entries.items[bad - 1].decl) },
        );
        if (fix) |f| {
            ctx.reportWithFix(f, diagnostic, &helpers.applyReorder);
        } else {
            ctx.report(diagnostic);
        }
    }
}

pub fn rule(self: *ImportsSorted) Rule {
    return Rule.init(self);
}

const helpers = struct {
    const Section = enum(u8) {
        std = 0,
        package = 1,
        file = 2,
    };

    const Entry = struct {
        decl: Node.Index,
        section: Section,
        module_name: []const u8,
        std_rank: usize,
        is_derived: bool,
    };

    const RootInfo = struct {
        section: Section,
        module_name: []const u8,
        std_rank: usize,
    };

    const NameInfo = struct {
        name: []const u8,
        root: RootInfo,
    };

    const Collected = struct {
        entries: std.ArrayListUnmanaged(Entry) = .empty,
        names: std.ArrayListUnmanaged(NameInfo) = .empty,
        gpa: std.mem.Allocator,

        fn deinit(self: *Collected) void {
            self.entries.deinit(self.gpa);
            self.names.deinit(self.gpa);
        }
    };

    const ReorderFix = struct {
        span: Span,
        replacement: []const u8,
    };

    fn isFragment(path: ?[]const u8) bool {
        const p = path orelse return false;
        return std.mem.endsWith(u8, p, ".mixin.zig") or std.mem.endsWith(u8, p, ".replace.zig");
    }

    fn isFilePath(path: []const u8) bool {
        if (path.len == 0) return false;
        if (path[0] == '.') return true;
        if (std.mem.endsWith(u8, path, ".zig")) return true;
        return std.mem.indexOfScalar(u8, path, '/') != null;
    }

    fn sectionOf(path: []const u8, std_modules: []const []const u8) Section {
        for (std_modules) |module| {
            if (std.mem.eql(u8, path, module)) return .std;
        }
        if (isFilePath(path)) return .file;
        return .package;
    }

    fn stdRank(module_name: []const u8, std_modules: []const []const u8) ?usize {
        for (std_modules, 0..) |module, i| {
            if (std.mem.eql(u8, module_name, module)) return i;
        }
        return null;
    }

    fn moduleName(path: []const u8) []const u8 {
        var p = path;
        while (std.mem.startsWith(u8, p, "../")) p = p[3..];
        if (std.mem.startsWith(u8, p, "./")) p = p[2..];
        if (isFilePath(path)) {
            if (std.mem.lastIndexOfScalar(u8, p, '.')) |dot| {
                if (dot > 0) p = p[0..dot];
            }
        }
        return p;
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

    fn rootFromExpr(
        ast: *const Ast,
        node: Node.Index,
        names: []const NameInfo,
        std_modules: []const []const u8,
    ) ?RootInfo {
        switch (ast.nodeTag(node)) {
            .identifier => {
                const name = ast.tokenSlice(ast.nodeMainToken(node));
                for (names) |info| {
                    if (std.mem.eql(u8, info.name, name)) return info.root;
                }
                return null;
            },
            .field_access => return rootFromExpr(ast, ast.nodeData(node).node_and_token[0], names, std_modules),
            .address_of, .deref => return rootFromExpr(ast, ast.nodeData(node).node, names, std_modules),
            .unwrap_optional => return rootFromExpr(ast, ast.nodeData(node).node_and_token[0], names, std_modules),
            .builtin_call_two, .builtin_call_two_comma, .builtin_call, .builtin_call_comma => {
                const path = importPathFromCall(ast, node) orelse return null;
                const module_name = moduleName(path);
                const section = sectionOf(path, std_modules);
                return .{
                    .section = section,
                    .module_name = module_name,
                    .std_rank = if (section == .std) (stdRank(module_name, std_modules) orelse 0) else 0,
                };
            },
            else => return null,
        }
    }

    fn collect(ctx: *LinterContext, std_modules: []const []const u8) Collected {
        const ast = ctx.ast();
        var result = Collected{ .gpa = ctx.gpa };

        for (ast.rootDecls()) |decl| {
            const info = importInfoFromDecl(ast, decl) orelse continue;
            const name = declName(ast, decl) orelse continue;
            const section = sectionOf(info.path, std_modules);
            const module_name = moduleName(info.path);
            const root = RootInfo{
                .section = section,
                .module_name = module_name,
                .std_rank = if (section == .std) (stdRank(module_name, std_modules) orelse 0) else 0,
            };

            result.entries.append(ctx.gpa, .{
                .decl = decl,
                .section = section,
                .module_name = module_name,
                .std_rank = root.std_rank,
                .is_derived = info.member != null,
            }) catch @panic("OOM");
            result.names.append(ctx.gpa, .{ .name = name, .root = root }) catch @panic("OOM");
        }

        var changed = true;
        while (changed) {
            changed = false;
            for (ast.rootDecls()) |decl| {
                if (isEntryDecl(result.entries.items, decl)) continue;

                const var_decl = ast.fullVarDecl(decl) orelse continue;
                const init = var_decl.ast.init_node.unwrap() orelse continue;
                const root = rootFromExpr(ast, init, result.names.items, std_modules) orelse continue;
                const name = declName(ast, decl) orelse continue;

                result.entries.append(ctx.gpa, .{
                    .decl = decl,
                    .section = root.section,
                    .module_name = root.module_name,
                    .std_rank = root.std_rank,
                    .is_derived = true,
                }) catch @panic("OOM");
                result.names.append(ctx.gpa, .{ .name = name, .root = root }) catch @panic("OOM");
                changed = true;
            }
        }

        return result;
    }

    fn isEntryDecl(entries: []const Entry, decl: Node.Index) bool {
        for (entries) |entry| {
            if (entry.decl == decl) return true;
        }
        return false;
    }

    fn lessThanDecl(_: void, a: Entry, b: Entry) bool {
        return @intFromEnum(a.decl) < @intFromEnum(b.decl);
    }

    fn compareCaseInsensitive(a: []const u8, b: []const u8) std.math.Order {
        const len = @min(a.len, b.len);
        var i: usize = 0;
        while (i < len) : (i += 1) {
            const ca = std.ascii.toLower(a[i]);
            const cb = std.ascii.toLower(b[i]);
            if (ca < cb) return .lt;
            if (ca > cb) return .gt;
        }
        if (a.len < b.len) return .lt;
        if (a.len > b.len) return .gt;
        return .eq;
    }

    fn lessThanEntry(_: void, a: Entry, b: Entry) bool {
        if (@intFromEnum(a.section) != @intFromEnum(b.section)) {
            return @intFromEnum(a.section) < @intFromEnum(b.section);
        }
        if (a.section == .std and a.std_rank != b.std_rank) {
            return a.std_rank < b.std_rank;
        }
        switch (compareCaseInsensitive(a.module_name, b.module_name)) {
            .lt => return true,
            .gt => return false,
            .eq => {},
        }
        if (a.is_derived != b.is_derived) return !a.is_derived;
        return @intFromEnum(a.decl) < @intFromEnum(b.decl);
    }

    fn sameGroup(a: Entry, b: Entry) bool {
        if (a.section == .std and b.section == .std) return true;
        return a.section == b.section and std.mem.eql(u8, a.module_name, b.module_name);
    }

    fn sameDeclOrder(a: []const Entry, b: []const Entry) bool {
        if (a.len != b.len) return false;
        for (a, b) |x, y| {
            if (x.decl != y.decl) return false;
        }
        return true;
    }

    fn firstOrderMismatch(a: []const Entry, b: []const Entry) usize {
        const len = @min(a.len, b.len);
        var i: usize = 0;
        while (i < len) : (i += 1) {
            if (a[i].decl != b[i].decl) return i;
        }
        return if (a.len < b.len) a.len else 0;
    }

    fn newlineCount(source: []const u8, from: u32, to: u32) usize {
        var count: usize = 0;
        for (source[from..to]) |c| {
            if (c == '\n') count += 1;
        }
        return count;
    }

    fn firstMissingBlank(ctx: *LinterContext, entries: []const Entry) ?usize {
        if (entries.len < 2) return null;
        var i: usize = 1;
        while (i < entries.len) : (i += 1) {
            const prev = entries[i - 1];
            const curr = entries[i];
            if (sameGroup(prev, curr)) continue;

            const prev_end = ctx.semantic.nodeSpan(prev.decl).end;
            const curr_start = ctx.semantic.nodeSpan(curr.decl).start;
            if (newlineCount(ctx.source.text(), prev_end, curr_start) < 2) return i;
        }
        return null;
    }

    fn importsAreLast(roots: []const Node.Index, entries: []const Entry) bool {
        const last = lastNonImport(roots, entries) orelse return true;
        for (entries) |entry| {
            const index = std.mem.indexOfScalar(Node.Index, roots, entry.decl) orelse continue;
            if (index < last) return false;
        }
        return true;
    }

    fn lastNonImport(roots: []const Node.Index, entries: []const Entry) ?usize {
        var last: ?usize = null;
        for (roots, 0..) |decl, i| {
            if (!isEntryDecl(entries, decl)) last = i;
        }
        return last;
    }

    fn declSpan(ctx: *LinterContext, decl: Node.Index) Span {
        var span = ctx.semantic.nodeSpan(decl);
        const ast = ctx.ast();
        const next = ast.lastToken(decl) + 1;
        const tokens = ctx.tokens();
        if (next < tokens.len and tokens.items(.tag)[next] == .semicolon) {
            span.end = ctx.semantic.tokenSpan(next).end;
        }
        return span;
    }

    fn canFix(ctx: *LinterContext, entries: []const Entry) bool {
        if (entries.len < 2) return false;
        const span = Span.new(
            ctx.semantic.nodeSpan(entries[0].decl).start,
            declSpan(ctx, entries[entries.len - 1].decl).end,
        );
        const block = span.snippet(ctx.source.text());
        if (std.mem.indexOf(u8, block, "//") != null) return false;
        if (std.mem.indexOf(u8, block, "/*") != null) return false;
        return true;
    }

    fn buildFix(
        ctx: *LinterContext,
        source_entries: []const Entry,
        sorted: []const Entry,
        buffer: *std.ArrayListUnmanaged(u8),
    ) ?ReorderFix {
        if (source_entries.len == 0 or sorted.len == 0) return null;

        const span = Span.new(
            ctx.semantic.nodeSpan(source_entries[0].decl).start,
            declSpan(ctx, source_entries[source_entries.len - 1].decl).end,
        );

        for (sorted, 0..) |entry, i| {
            if (i != 0) {
                if (sameGroup(sorted[i - 1], entry)) {
                    buffer.append(ctx.gpa, '\n') catch @panic("OOM");
                } else {
                    buffer.appendSlice(ctx.gpa, "\n\n") catch @panic("OOM");
                }
            }
            const snippet = ctx.semantic.nodeSpan(entry.decl).snippet(ctx.source.text());
            buffer.appendSlice(ctx.gpa, snippet) catch @panic("OOM");
            if (!std.mem.endsWith(u8, snippet, ";")) {
                buffer.append(ctx.gpa, ';') catch @panic("OOM");
            }
        }

        return .{ .span = span, .replacement = buffer.items };
    }

    fn applyReorder(fix: ReorderFix, builder: Fix.Builder) anyerror!Fix {
        return builder.replacef(fix.span, "{s}", .{fix.replacement});
    }

    const ImportInfo = struct {
        path: []const u8,
        member: ?[]const u8,
    };
};

test ImportsSorted {
    @setEvalBranchQuota(100_000);
    const passing =
        \\const Thing = @This();
        \\
        \\pub fn foo() void {}
        \\
        \\const std = @import("std");
        \\const Allocator = std.mem.Allocator;
        \\
        \\const build_options = @import("build_options");
        \\
        \\const casez = @import("casez");
        \\
        \\const common = @import("common");
        \\const gdzig_case = common.gdzig_case;
        \\const GodotApi = @import("common").GodotApi;
        \\
        \\const Context = @import("../Context.zig");
        \\const Builtin = Context.Builtin;
        \\const Type = Context.Type;
        \\
        \\const docs = @import("docs.zig");
        \\
        \\const Value = @import("value.zig").Value;
    ;
    const passing_alias_chain =
        \\const Thing = @This();
        \\
        \\const std = @import("std");
        \\const Io = std.Io;
        \\const Writer = Io.Writer;
        \\
        \\const casez = @import("casez");
    ;
    const passing_unary_alias =
        \\const Thing = @This();
        \\
        \\const gdzig = @import("gdzig");
        \\const raw = &gdzig.raw;
    ;
    const passing_interleaved =
        \\const Thing = @This();
        \\
        \\const std = @import("std");
        \\
        \\pub fn foo() void {}
        \\
        \\const casez = @import("casez");
    ;
    const package_before_std =
        \\const Thing = @This();
        \\
        \\const casez = @import("casez");
        \\
        \\const std = @import("std");
    ;
    const file_before_package =
        \\const Thing = @This();
        \\
        \\const Context = @import("../Context.zig");
        \\
        \\const casez = @import("casez");
    ;
    const wrong_alphabetical =
        \\const Thing = @This();
        \\
        \\const casez = @import("casez");
        \\
        \\const build_options = @import("build_options");
    ;
    const missing_blank_line =
        \\const Thing = @This();
        \\
        \\const std = @import("std");
        \\const casez = @import("casez");
    ;
    const split_alias =
        \\const Thing = @This();
        \\
        \\const common = @import("common");
        \\
        \\const casez = @import("casez");
        \\
        \\const gdzig_case = common.gdzig_case;
    ;
    const fix_source =
        \\const Thing = @This();
        \\
        \\const casez = @import("casez");
        \\const std = @import("std");
        \\const Context = @import("../Context.zig");
    ;
    const fix_expected =
        \\const Thing = @This();
        \\
        \\const std = @import("std");
        \\
        \\const casez = @import("casez");
        \\
        \\const Context = @import("../Context.zig");
    ;

    var implementation = ImportsSorted{};
    var runner = RuleTester.init(testing.allocator, implementation.rule());
    defer runner.deinit();
    runner.setFileName("Test.zig");
    try runner
        .withPass(&.{ passing, passing_alias_chain, passing_unary_alias, passing_interleaved })
        .withFail(&.{
            package_before_std,
            file_before_package,
            wrong_alphabetical,
            missing_blank_line,
            split_alias,
        })
        .withFix(&.{.{ .src = fix_source, .expected = fix_expected }})
        .run();

    const build_options_with_std =
        \\const Thing = @This();
        \\
        \\const std = @import("std");
        \\const build_options = @import("build_options");
        \\
        \\const casez = @import("casez");
    ;
    var with_std_impl = ImportsSorted{ .std_modules = &.{ "std", "builtin", "build_options" } };
    var with_std_runner = RuleTester.init(testing.allocator, with_std_impl.rule());
    defer with_std_runner.deinit();
    with_std_runner.setFileName("Test.zig");
    try with_std_runner.withPass(&.{build_options_with_std}).run();

    var default_impl = ImportsSorted{};
    var default_runner = RuleTester.init(testing.allocator, default_impl.rule());
    defer default_runner.deinit();
    default_runner.setFileName("Test.zig");
    try default_runner.withFail(&.{build_options_with_std}).run();

    var fragment_impl = ImportsSorted{};
    var fragment_runner = RuleTester.init(testing.allocator, fragment_impl.rule());
    defer fragment_runner.deinit();
    fragment_runner.setFileName("Aabb.mixin.zig");
    try fragment_runner.withPass(&.{package_before_std}).run();
}

const std = @import("std");
const testing = std.testing;

const zlint = @import("zlint");
const Ast = zlint.Semantic.Ast;
const Node = Ast.Node;
const Rule = zlint.linter.rule.Rule;
const RuleTester = zlint.linter.tester;
const LinterContext = zlint.linter.lint_context;
const Span = zlint.linter.span.Span;
const Fix = zlint.linter.fix.Fix;
