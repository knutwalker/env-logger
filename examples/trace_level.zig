// SPDX-License-Identifier: MIT

const std = @import("std");
const env_logger = @import("env-logger");

pub const std_options = env_logger.setup(.{
    .enable_trace_level = true,
});

pub fn main() !void {
    env_logger.init(.{});

    if (!env_logger.level_enabled(.trace)) {
        std.debug.print("To see all log messages, run with `env ZIG_LOG=trace ...`\n", .{});
    }

    std.log.debug("TRACE: debug message", .{});
    std.log.debug("debug message", .{});
    std.log.info("info message", .{});
    std.log.warn("warn message", .{});
    std.log.err("error message", .{});
}
