//! ## What This Rule Does
//! Requires a `///` doc comment on public functions.
//!
//! A doc comment should describe the function's purpose, its inputs, and any
//! significant return or error behavior.
//!
//! Generated `*.mixin.zig` and `*.replace.zig` fragments are skipped.

pub const meta: Rule.Meta = .{
    .name = "gdzig-public-docs",
    .category = .style,
    .default = .warning,
};

/// Skip generated mixin and replace fragments.
skip_fragments: bool = true,

const PublicDocs = @This();

/// Checks public functions for a doc comment.
pub fn runOnNode(self: *const PublicDocs, wrapper: NodeWrapper, ctx: *LinterContext) void {
    if (self.skip_fragments and helpers.isFragment(ctx.source.pathname)) return;

    switch (wrapper.node.tag) {
        .fn_decl,
        .fn_proto,
        .fn_proto_simple,
        .fn_proto_multi,
        .fn_proto_one,
        => {},
        else => return,
    }

    const ast = ctx.ast();
    var buffer: [1]Node.Index = undefined;
    const proto = ast.fullFnProto(&buffer, wrapper.idx) orelse return;
    _ = proto.visib_token orelse return;

    const first_token = proto.firstToken();
    if (first_token > 0 and ast.tokenTag(first_token - 1) == .doc_comment) return;

    const name = if (proto.name_token) |token| ast.tokenSlice(token) else "this function";
    ctx.report(ctx.diagnosticf(
        "public function '{s}' is missing a /// doc comment",
        .{name},
        .{ctx.spanT(proto.ast.fn_token)},
    ));
}

/// Returns the rule descriptor.
pub fn rule(self: *PublicDocs) Rule {
    return .init(self);
}

const helpers = struct {
    fn isFragment(path: ?[]const u8) bool {
        const p = path orelse return false;
        return std.mem.endsWith(u8, p, ".mixin.zig") or std.mem.endsWith(u8, p, ".replace.zig");
    }
};

test PublicDocs {
    @setEvalBranchQuota(100_000);

    var impl = PublicDocs{};
    var runner = RuleTester.init(testing.allocator, impl.rule());
    defer runner.deinit();
    try runner
        .withPass(&.{
            "/// Adds two numbers.\npub fn add(a: u32, b: u32) u32 { return a + b; }",
            "fn add(a: u32, b: u32) u32 { return a + b; }",
            "const Thing = struct {\n" ++
                "    /// Returns the value.\n" ++
                "    pub fn get(self: Thing) u32 { return self.value; }\n" ++
                "    value: u32,\n" ++
                "};",
        })
        .withFail(&.{
            "pub fn add(a: u32, b: u32) u32 { return a + b; }",
            "pub inline fn add(a: u32, b: u32) u32 { return a + b; }",
            "const Thing = struct {\n    pub fn get(self: Thing) u32 { return self.value; }\n    value: u32,\n};",
        })
        .run();

    var fragment_impl = PublicDocs{ .skip_fragments = false };
    var fragment_runner = RuleTester.init(testing.allocator, fragment_impl.rule());
    defer fragment_runner.deinit();
    fragment_runner.setFileName("Thing.mixin.zig");
    try fragment_runner.withFail(&.{"pub fn add(a: u32, b: u32) u32 { return a + b; }"}).run();
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
