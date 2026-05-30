const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const openai_module = b.addModule("openai", .{
        .root_source_file = b.path("src/openai.zig"),
        .target = target,
        .optimize = optimize,
    });

    const main_example = b.createModule(.{
        .root_source_file = b.path("examples/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    main_example.addImport("openai", openai_module);

    const main_exe = b.addExecutable(.{
        .name = "openai-example",
        .root_module = main_example,
    });
    b.installArtifact(main_exe);

    const vision_example = b.createModule(.{
        .root_source_file = b.path("examples/vision.zig"),
        .target = target,
        .optimize = optimize,
    });
    vision_example.addImport("openai", openai_module);
    b.installArtifact(b.addExecutable(.{
        .name = "openai-vision-example",
        .root_module = vision_example,
    }));

    const files_example = b.createModule(.{
        .root_source_file = b.path("examples/files.zig"),
        .target = target,
        .optimize = optimize,
    });
    files_example.addImport("openai", openai_module);
    b.installArtifact(b.addExecutable(.{
        .name = "openai-files-example",
        .root_module = files_example,
    }));

    const docs = b.addObject(.{
        .name = "openai",
        .root_module = openai_module,
    });
    const build_docs = b.addInstallDirectory(.{
        .source_dir = docs.getEmittedDocs(),
        .install_dir = .prefix,
        .install_subdir = "docs",
    });
    const build_docs_step = b.step("docs", "Build the openai-zig docs");
    build_docs_step.dependOn(&build_docs.step);

    const run_cmd = b.addRunArtifact(main_exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);
    const lib_unit_tests = b.addTest(.{
        .root_module = openai_module,
    });
    const run_lib_unit_tests = b.addRunArtifact(lib_unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_lib_unit_tests.step);
}
