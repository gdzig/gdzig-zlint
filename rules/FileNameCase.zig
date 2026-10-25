//! ## What This Rule Does
//! Enforces gdzig's file naming convention.
//!
//! A file that declares top-level container fields is a type and uses
//! TitleCase. A file without top-level fields is a namespace of declarations
//! and uses snake_case.
//!
//! Generated `*.mixin.zig` and `*.replace.zig` fragments are skipped.

pub const meta: Rule.Meta = .{
    .name = "gdzig-file-name-case",
    .category = .style,
    .default = .warning,
};

/// Skip generated mixin and replace fragments.
skip_fragments: bool = true,

const FileNameCase = @This();

/// Checks the file's name against the type or namespace convention.
pub fn runOnce(self: *const FileNameCase, ctx: *LinterContext) void {
    const pathname = ctx.source.pathname orelse return;
    if (self.skip_fragments and helpers.isFragment(pathname)) return;

    const base = helpers.basenameWithoutExtension(pathname);
    if (base.len == 0) return;

    const ast = ctx.ast();
    var has_fields = false;
    for (ast.rootDecls()) |decl| {
        if (helpers.isContainerField(ast, decl)) {
            has_fields = true;
            break;
        }
    }

    if (has_fields) {
        if (!helpers.isTitleCase(base)) {
            ctx.report(ctx.diagnosticf(
                "file '{s}' declares top-level fields, so it is a type and must use TitleCase",
                .{base},
                .{},
            ));
        }
    } else {
        if (!helpers.isSnakeCase(base)) {
            ctx.report(ctx.diagnosticf(
                "file '{s}' declares no top-level fields, so it is a namespace and must use snake_case",
                .{base},
                .{},
            ));
        }
    }
}

/// Returns the rule descriptor.
pub fn rule(self: *FileNameCase) Rule {
    return .init(self);
}

const helpers = struct {
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

    fn isContainerField(ast: *const Ast, decl: Node.Index) bool {
        return switch (ast.nodeTag(decl)) {
            .container_field, .container_field_init, .container_field_align => true,
            else => false,
        };
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
};

test FileNameCase {
    @setEvalBranchQuota(100_000);
    const type_source =
        \\const Thing = @This();
        \\field: u32,
    ;
    const namespace_source =
        \\pub fn foo() void {}
    ;
    const var_source =
        \\var counter: u32 = 0;
    ;

    var type_impl = FileNameCase{};
    var type_runner = RuleTester.init(testing.allocator, type_impl.rule());
    defer type_runner.deinit();
    type_runner.setFileName("Thing.zig");
    try type_runner.withPass(&.{type_source}).withFail(&.{ namespace_source, var_source }).run();

    var namespace_impl = FileNameCase{};
    var namespace_runner = RuleTester.init(testing.allocator, namespace_impl.rule());
    defer namespace_runner.deinit();
    namespace_runner.setFileName("thing.zig");
    try namespace_runner.withPass(&.{ namespace_source, var_source }).withFail(&.{type_source}).run();

    var fragment_impl = FileNameCase{ .skip_fragments = false };
    var fragment_runner = RuleTester.init(testing.allocator, fragment_impl.rule());
    defer fragment_runner.deinit();
    fragment_runner.setFileName("Aabb.mixin.zig");
    try fragment_runner.withPass(&.{type_source}).run();
}

const std = @import("std");
const testing = std.testing;

const zlint = @import("zlint");
const Ast = zlint.Semantic.Ast;
const Node = Ast.Node;
const Rule = zlint.linter.rule.Rule;
const RuleTester = zlint.linter.tester;
const LinterContext = zlint.linter.lint_context;
