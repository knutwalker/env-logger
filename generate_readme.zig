const std = @import("std");
const build_vars = @import("build_vars");

pub fn main() !void {
    var bufout = std.io.bufferedWriter(std.io.getStdOut().writer());
    var bo = bufout.writer();

    const readme_tpl = @embedFile("README.md.template");

    try bo.print(readme_tpl, .{
        .name = build_vars.lib_name,
        .module_name = build_vars.module_name,
        .repo = build_vars.repo,
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

    try bufout.flush();
}

fn read(comptime file: []const u8) []const u8 {
    var content = @as([]const u8, @embedFile(file));
    if (std.mem.startsWith(u8, content, "// SPDX-License-Identifier")) {
        const line_end = std.mem.indexOfScalar(u8, content, '\n').?;
        content = content[line_end + 2 ..];
    }
    return content;
}
