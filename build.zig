const std = @import("std");
const builtin = @import("builtin");
const Build = std.Build;

pub fn build(b: *Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const build_options = b.addOptions();
    const build_options_module = build_options.createModule();
    const enable_tracy = b.option(bool, "tracy", "Enable tracy") orelse false;
    const enable_tracy_callstack = b.option(bool, "tracy_callstack", "Enable tracy callstack") orelse enable_tracy;
    build_options.addOption(bool, "enable_tracy", enable_tracy);
    build_options.addOption(bool, "enable_tracy_callstack", enable_tracy_callstack);

    const stb_dep = b.dependency("stb", .{});
    const tracy_dep = b.dependency("tracy", .{});

    // STB Image Translate-C
    const stb_image_translate_c = b.addTranslateC(.{
        .root_source_file = stb_dep.path("stb_image.h"),
        .target = target,
        .optimize = optimize,
    });

    // Module
    const module = b.addModule("gltf", .{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    module.addImport("build_options", build_options_module);
    module.addImport("stb_image", stb_image_translate_c.createModule());

    // Benchmark
    const benchmark = b.addExecutable(.{
        .name = "benchmark",
        .root_source_file = b.path("src/benchmark.zig"),
        .target = target,
        .optimize = optimize,
    });
    benchmark.root_module.addImport("gltf", module);
    benchmark.root_module.addImport("build_options", build_options_module);
    benchmark.linkLibCpp();
    benchmark.addIncludePath(stb_dep.path(""));
    benchmark.addCSourceFile(.{ .file = b.path("src/stb_image.c") });
    if (enable_tracy) {
        benchmark.addCSourceFile(.{
            .file = tracy_dep.path("public/TracyClient.cpp"),
            .flags = &.{ "-DTRACY_ENABLE", "-fno-sanitize=undefined" },
        });
    }

    const install_benchmark_exe_cmd = b.addInstallArtifact(benchmark, .{});
    const run_benchmark = b.addRunArtifact(benchmark);
    const test_gltf_step = b.step("benchmark", "Run Benchmark");
    test_gltf_step.dependOn(&install_benchmark_exe_cmd.step);
    test_gltf_step.dependOn(&run_benchmark.step);
}
