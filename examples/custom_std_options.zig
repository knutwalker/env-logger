// SPDX-License-Identifier: MIT

const std = @import("std");
const env_logger = @import("env-logger");

pub const std_options = env_logger.setupWith(
    .{},
    // The second argument is the std.Options that will be set.
    .{
        .fmt_max_depth = 64,
    },
);

pub fn main() !void {
    env_logger.init(.{});

    if (!env_logger.defaultLevelEnabled(.debug)) {
        std.debug.print("To see all log messages, run with `env ZIG_LOG=debug ...`\n", .{});
    }

    std.log.debug("debug message", .{});
    std.log.info("info message", .{});
    std.log.warn("warn message", .{});
    std.log.err("error message", .{});
}
