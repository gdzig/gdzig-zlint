const rule_files = [_][]const u8{
    "rules/FileNameCase.zig",
    "rules/ImportAliasCase.zig",
    "rules/ImportsLast.zig",
    "rules/TestsLast.zig",
};

/// Rule source paths for a consumer's zlint dependency.
///
/// ```zig
/// const gdzig_zlint = @import("gdzig_zlint");
/// const rules_dep = b.dependency("gdzig_zlint", .{});
/// const zlint_dep = b.dependency("zlint", .{
///     .custom_rules = gdzig_zlint.customRulePaths(rules_dep),
/// });
/// ```
pub fn customRulePaths(dep: *std.Build.Dependency) []const std.Build.LazyPath {
    const paths = dep.builder.allocator.alloc(std.Build.LazyPath, rule_files.len) catch @panic("OOM");
    for (rule_files, 0..) |file, i| paths[i] = dep.path(file);
    return paths;
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const version = b.option([]const u8, "version", "gdzig-zlint version string") orelse "0.2.0";

    const zlint_dep = b.dependency("zlint", .{
        .target = target,
        .optimize = optimize,
        .version = version,
        .custom_rules = selfRulePaths(b),
    });

    const exe = zlint_dep.artifact("zlint");
    const install = b.addInstallArtifact(exe, .{ .dest_sub_path = "gdzig-zlint" });
    b.getInstallStep().dependOn(&install.step);

    const lint_step = b.step("lint", "Run gdzig-zlint on the current directory");
    lint_step.dependOn(&zlint.addRunLint(b, zlint_dep).step);

    const test_rules_step = b.step("test-rules", "Run custom rule tests");
    test_rules_step.dependOn(zlint.addRunCustomLintRulesTest(b, zlint_dep));

    const test_step = b.step("test", "Run all tests");
    test_step.dependOn(test_rules_step);
}

fn selfRulePaths(b: *std.Build) []const std.Build.LazyPath {
    const paths = b.allocator.alloc(std.Build.LazyPath, rule_files.len) catch @panic("OOM");
    for (rule_files, 0..) |file, i| paths[i] = b.path(file);
    return paths;
}

comptime {
    const version = builtin.zig_version;
    if (version.major != 0 or version.minor != 16) {
        @compileError("gdzig-zlint requires Zig 0.16.x, found " ++ builtin.zig_version_string);
    }
}

const std = @import("std");
const builtin = @import("builtin");

const zlint = @import("zlint");
