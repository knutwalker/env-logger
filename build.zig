// SPDX-License-Identifier: MIT
const std = @import("std");

const Manifest = struct {
    name: @Type(.enum_literal),
    version: []const u8,
    minimum_zig_version: []const u8,
    dependencies: struct {},
    paths: []const []const u8,
    fingerprint: u64,
};

const manifest: Manifest = @import("build.zig.zon");

pub fn build(b: *std.Build) void {
    errdefer |err| switch (err) {
        error.OutOfMemory => std.process.fatal("oom", .{}),
    };

    const check_step = b.step("check", "Check if the project compiles");
    const test_step = b.step("test", "Run unit tests");
    const docs_step = b.step("docs", "Generate docs");
    const example_step = b.step("example", "Run an example");
    const readme_step = b.step("readme", "Generate the readme file");
    const fmt_step = b.step("fmt", "Run formatting checks");
    const clean_step = b.step("clean", "Clean up");

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
    const check = b.addLibrary(.{ .root_module = mod, .name = "check" });
    const check_tests = b.addTest(.{ .root_module = mod });

    check_step.dependOn(&check.step);
    check_step.dependOn(&check_tests.step);
    // }}}

    // tests {{{
    const tests = b.addTest(.{ .root_module = mod });
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

    // readme {{{
    const gen_readme_step = readme: {
        const root_path = std.fs.path.relative(b.allocator, b.install_path, b.build_root.path.?) catch break :readme @as(?*std.Build.Step.Run, null);

        // build vars {{{
        const module_name = std.mem.trimLeft(u8, @tagName(manifest.name), ".");
        const lib_name = try std.mem.replaceOwned(u8, b.allocator, module_name, "_", "-");

        const build_vars = b.addOptions();
        build_vars.addOption([]const u8, "module_name", module_name);
        build_vars.addOption([]const u8, "lib_name", lib_name);
        build_vars.addOption([]const u8, "repo", b.fmt("https://github.com/knutwalker/{s}", .{lib_name}));
        // }}}

        var gen_readme = b.addExecutable(.{
            .name = "gen_readme",
            .root_module = b.createModule(.{
                .root_source_file = b.path("generate_readme.zig"),
                .optimize = .Debug,
                .target = b.resolveTargetQuery(.{}),
            }),
        });
        gen_readme.root_module.addOptions("build_vars", build_vars);

        const run_gen_readme = b.addRunArtifact(gen_readme);
        run_gen_readme.addFileInput(b.path("README.md.template"));
        const readme_file = run_gen_readme.captureStdOut();

        readme_step.dependOn(&run_gen_readme.step);

        const install_readme_file = b.addInstallFileWithDir(readme_file, .{ .custom = root_path }, "README.md");
        readme_step.dependOn(&install_readme_file.step);

        break :readme run_gen_readme;
    };
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
        if (gen_readme_step) |readme| {
            readme.step.dependOn(&example.step);
        }

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

    // fmt {{{
    const fmt = b.addFmt(.{
        .paths = &.{ "src", "build.zig", "build.zig.zon" },
        .check = true,
    });
    fmt_step.dependOn(&fmt.step);
    // }}}

    // clean {{{
    const install_path = std.Build.LazyPath{ .cwd_relative = b.getInstallPath(.prefix, "") };
    clean_step.dependOn(&b.addRemoveDirTree(install_path).step);
    if (@import("builtin").os.tag != .windows) {
        clean_step.dependOn(&b.addRemoveDirTree(b.path(".zig-cache")).step);
    }
    // }}}
}

// zig version check {{{
comptime {
    const required_zig = manifest.minimum_zig_version;
    const min_zig = std.SemanticVersion.parse(required_zig) catch unreachable;
    const current_zig = @import("builtin").zig_version;
    if (current_zig.order(min_zig) == .lt) {
        const error_message =
            \\Your zig version is too old :/
            \\
            \\{[name]} requires zig {[zig]s}
            \\Please download a suitable version from
            \\
            \\https://ziglang.org/download/
            \\
        ;

        @compileError(std.fmt.comptimePrint(error_message, .{
            .name = manifest.name,
            .zig = required_zig,
        }));
    }
}
// }}}
