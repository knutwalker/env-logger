// SPDX-License-Identifier: MIT

const std = @import("std");
const env_logger = @import("env-logger");

pub const std_options = env_logger.setup(.{});

pub fn main() !void {
    env_logger.init(.{
        .filter = .{ .env_var = "MY_LOG_ENV" },
    });

    if (!env_logger.defaultLevelEnabled(.debug)) {
        std.debug.print("To see all log messages, run with `env MY_LOG_ENV=debug ...`\n", .{});
    }

    std.log.debug("debug message", .{});
    std.log.info("info message", .{});
    std.log.warn("warn message", .{});
    std.log.err("error message", .{});
}
