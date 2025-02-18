// SPDX-License-Identifier: MIT

const std = @import("std");

pub fn build(b: *std.Build) void {
    const check_step = b.step("check", "Check if the project compiles");
    const test_step = b.step("test", "Run unit tests");
    const docs_step = b.step("docs", "Generate docs");
    const example_step = b.step("example", "Run an example");
    var readme_step = b.step("readme", "Generate the README");

    const all_step = b.step("all", "Build everything");
    all_step.dependOn(test_step);
    all_step.dependOn(example_step);
    all_step.dependOn(readme_step);
    all_step.dependOn(docs_step);

    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const mod = b.addModule("env-logger", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    // check {{{
    const host_target = b.resolveTargetQuery(.{});
    const check = b.addStaticLibrary(.{
        .name = "env-logger-check",
        .root_source_file = b.path("src/root.zig"),
        .target = host_target,
        .optimize = .Debug,
    });

    const check_tests = b.addTest(.{
        .root_source_file = b.path("src/root.zig"),
        .target = host_target,
        .optimize = .Debug,
    });

    check_step.dependOn(&check.step);
    check_step.dependOn(&check_tests.step);
    // }}}

    // tests {{{
    const tests = b.addTest(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    const run_tests = b.addRunArtifact(tests);
    test_step.dependOn(&run_tests.step);
    // }}}

    // docs {{{
    const install_docs = b.addInstallDirectory(.{
        .source_dir = tests.getEmittedDocs(),
        .install_dir = .prefix,
        .install_subdir = "docs",
    });
    docs_step.dependOn(&install_docs.step);
    // }}}

    // examples {{{
    const Example = enum {
        quick,
        starting,
        trace_level,
        custom_env,
        scoped_log,
        dynamic_log_level,
        custom_std_options,
        only_messages,
        add_timestamps,
        log_outputs,
        colors,
        allocator,
    };
    const selected_examples = b.option([]const Example, "example", "The example to run") orelse &.{};

    for (std.enums.values(Example)) |example_tag| {
        const example_name = @tagName(example_tag);
        const example_path = b.fmt("examples/{s}.zig", .{example_name});
        const example = b.addExecutable(.{
            .name = example_name,
            .root_source_file = b.path(example_path),
            .target = target,
            .optimize = optimize,
            .single_threaded = true,
        });
        example.root_module.addImport("env-logger", mod);

        all_step.dependOn(&example.step);

        if (std.mem.indexOfScalar(Example, selected_examples, example_tag) != null) {
            const run_example = b.addRunArtifact(example);
            switch (example_tag) {
                .log_outputs => {
                    if (b.args) |args| {
                        run_example.addArgs(args);
                    }
                },
                else => {},
            }
            example_step.dependOn(&run_example.step);
        }
    }
    // }}}

    // readme {{{
    readme_step.id = .custom;
    readme_step.makeFn = struct {
        fn read(comptime file: []const u8) []const u8 {
            var content = @as([]const u8, @embedFile(file));
            if (std.mem.startsWith(u8, content, "// SPDX-License-Identifier")) {
                const line_end = std.mem.indexOfScalar(u8, content, '\n').?;
                content = content[line_end + 2 ..];
            }
            return content;
        }

        fn make(_: *std.Build.Step, _: std.Build.Step.MakeOptions) anyerror!void {
            var readme_file = try std.fs.cwd().createFile("README.md", .{});
            try readme_file.writer().print(@embedFile("README.md.template"), .{
                .name = "env-logger",
                .module_name = "env_logger",
                .repo = "https://github.com/knutwalker/env-logger",
                .quick = read("examples/quick.zig"),
                .starting = read("examples/starting.zig"),
                .trace_level = read("examples/trace_level.zig"),
                .custom_env = read("examples/custom_env.zig"),
                .scoped_log = read("examples/scoped_log.zig"),
                .dynamic_log_level = read("examples/dynamic_log_level.zig"),
                .custom_std_options = read("examples/custom_std_options.zig"),
                .only_messages = read("examples/only_messages.zig"),
                .add_timestamps = read("examples/add_timestamps.zig"),
                .log_outputs = read("examples/log_outputs.zig"),
                .colors = read("examples/colors.zig"),
                .allocator = read("examples/allocator.zig"),
            });
        }
    }.make;
    readme_step.dependOn(example_step);
    // }}}
}
