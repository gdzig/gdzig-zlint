//! ## What This Rule Does
//! Requires a trailing comma on nonempty container declarations and on
//! multiline struct initializers. Enums are excluded.
//!
//! `zig fmt` expands a field list to one field per line when the last field has
//! a trailing comma. This rule adds that comma, so formatting takes care of the
//! layout.
//!
//! Multiline string fields are diagnostics-only. Inserting a comma at the
//! token boundary would change the string value.
//!
//! Single-line struct literals are left alone.
//!
//! Hand-written `*.mixin.zig` and `*.replace.zig` fragments are linted. Set
//! `skip_fragments` to exclude them.

pub const meta: Rule.Meta = .{
    .name = "gdzig-trailing-comma",
    .category = .style,
    .default = .warning,
    .fix = .safe_fix,
};

/// Skip hand-written mixin and replace fragments.
skip_fragments: bool = false,

const TrailingComma = @This();

/// Checks container fields and struct literal fields for a trailing comma.
pub fn runOnNode(self: *const TrailingComma, wrapper: NodeWrapper, ctx: *LinterContext) void {
    if (self.skip_fragments and helpers.isFragment(ctx.source.pathname)) return;

    const ast = ctx.ast();
    switch (wrapper.node.tag) {
        .container_decl,
        .container_decl_two,
        .container_decl_arg,
        .tagged_union,
        .tagged_union_two,
        .tagged_union_enum_tag,
        .root,
        => {
            var buffer: [2]Node.Index = undefined;
            const decl = ast.fullContainerDecl(&buffer, wrapper.idx) orelse return;
            if (wrapper.node.tag != .root and ast.tokenTag(decl.ast.main_token) == .keyword_enum) return;

            var field_count: usize = 0;
            var last_field: ?Node.Index = null;
            for (decl.ast.members) |member| {
                if (!helpers.isContainerField(ast, member)) continue;
                field_count += 1;
                last_field = member;
            }
            if (field_count == 0) return;

            const last = last_field.?;
            if (helpers.hasTrailingComma(ast, last)) return;
            report(ctx, last, "add a trailing comma so zig fmt places each field on its own line");
        },
        .struct_init_one,
        .struct_init_dot_two,
        .struct_init_dot,
        .struct_init,
        => {
            var buffer: [2]Node.Index = undefined;
            const init = ast.fullStructInit(&buffer, wrapper.idx) orelse return;
            if (init.ast.fields.len == 0) return;
            if (!helpers.isMultiline(ctx, wrapper.idx)) return;

            const last = init.ast.fields[init.ast.fields.len - 1];
            if (helpers.hasTrailingComma(ast, last)) return;
            report(ctx, last, "add a trailing comma so zig fmt places each field on its own line");
        },
        else => {},
    }
}

/// Returns the rule descriptor.
pub fn rule(self: *TrailingComma) Rule {
    return .init(self);
}

fn report(ctx: *LinterContext, last: Node.Index, comptime message: []const u8) void {
    const ast = ctx.ast();
    const last_token = ast.lastToken(last);
    const diagnostic = ctx.diagnostic(message, .{ctx.spanN(last)});
    if (ast.tokenTag(last_token) == .multiline_string_literal_line) {
        ctx.report(diagnostic);
        return;
    }
    const end = ctx.semantic.nodeSpan(last).end;
    ctx.reportWithFix(CommaFix{ .position = end }, diagnostic, &applyFix);
}

const CommaFix = struct {
    position: u32,
};

fn applyFix(fix: CommaFix, builder: Fix.Builder) anyerror!Fix {
    return builder.replace(Span.new(fix.position, fix.position), .static(","));
}

const helpers = struct {
    fn isFragment(path: ?[]const u8) bool {
        const p = path orelse return false;
        return std.mem.endsWith(u8, p, ".mixin.zig") or std.mem.endsWith(u8, p, ".replace.zig");
    }

    fn isContainerField(ast: *const Ast, node: Node.Index) bool {
        return switch (ast.nodeTag(node)) {
            .container_field, .container_field_init, .container_field_align => true,
            else => false,
        };
    }

    fn hasTrailingComma(ast: *const Ast, node: Node.Index) bool {
        const last_token = ast.lastToken(node);
        if (last_token + 1 >= ast.tokens.len) return false;
        return ast.tokenTag(last_token + 1) == .comma;
    }

    fn isMultiline(ctx: *LinterContext, node: Node.Index) bool {
        const source = ctx.semantic.nodeSpan(node).snippet(ctx.source.text());
        return std.mem.indexOfScalar(u8, source, '\n') != null;
    }
};

test TrailingComma {
    @setEvalBranchQuota(100_000);

    const failing_container =
        \\const Thing = struct { a: u8, b: u8 };
    ;
    const fixed_container =
        \\const Thing = struct { a: u8, b: u8, };
    ;
    const failing_literal =
        \\const thing = Thing{
        \\    .a = 1,
        \\    .b = 2
        \\};
    ;
    const fixed_literal =
        \\const thing = Thing{
        \\    .a = 1,
        \\    .b = 2,
        \\};
    ;
    const failing_root =
        \\a: u8, b: u8
    ;
    const fixed_root =
        \\a: u8, b: u8,
    ;
    const failing_single =
        \\const Thing = struct { a: u8 };
    ;
    const fixed_single =
        \\const Thing = struct { a: u8, };
    ;
    const failing_multiline_string =
        \\const Thing = struct {
        \\    text: []const u8 =
        \\        \\hello
        \\};
    ;
    const fixed_multiline_string =
        \\const Thing = struct {
        \\    text: []const u8 =
        \\        \\hello
        \\,
        \\};
    ;

    var impl = TrailingComma{};
    var runner = RuleTester.init(testing.allocator, impl.rule());
    defer runner.deinit();
    try runner
        .withPass(&.{
            "const Thing = struct { a: u8, b: u8, };",
            "const Thing = struct { a: u8, };",
            "const Mode = enum { quiet, verbose };",
            "const thing = Thing{ .a = 1, .b = 2 };",
            "const thing = Thing{ .a = 1 };",
            "const thing = Thing{\n    .a = 1,\n    .b = 2,\n};",
            "const Thing = struct {};",
            fixed_multiline_string,
        })
        .withFail(&.{ failing_container, failing_literal, failing_root, failing_single, failing_multiline_string })
        .withFix(&.{
            .{
                .src = failing_container,
                .expected = fixed_container,
            },
            .{
                .src = failing_literal,
                .expected = fixed_literal,
            },
            .{
                .src = failing_root,
                .expected = fixed_root,
            },
            .{
                .src = failing_single,
                .expected = fixed_single,
            },
        })
        .run();

    var fragment_impl = TrailingComma{};
    var fragment_runner = RuleTester.init(testing.allocator, fragment_impl.rule());
    defer fragment_runner.deinit();
    fragment_runner.setFileName("Thing.mixin.zig");
    try fragment_runner.withFail(&.{failing_container}).run();

    var skip_impl = TrailingComma{ .skip_fragments = true };
    var skip_runner = RuleTester.init(testing.allocator, skip_impl.rule());
    defer skip_runner.deinit();
    skip_runner.setFileName("Thing.mixin.zig");
    try skip_runner.withPass(&.{failing_container}).run();
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
