const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});

    const mod = b.addModule("cryoz", .{
        .root_source_file = b.path("src/cryoz.zig"),
        .target = target,
    });

    const test_filters = b.option(
        []const []const u8,
        "test-filter",
        "Only run particular tests (e.g. whose names contain this substring)",
    ) orelse &[_][]const u8{};

    const mod_tests = b.addTest(.{
        .root_module = mod,
        .filters = test_filters,
    });

    const run_mod_tests = b.addRunArtifact(mod_tests);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_mod_tests.step);
}
