// SPDX-License-Identifier: MIT

const std = @import("std");
const env_logger = @import("env-logger");

pub const std_options = env_logger.setup(.{});

pub fn main() !void {
    env_logger.init(.{
        .render_level = false,
        .render_logger = false,
    });

    if (!env_logger.defaultLevelEnabled(.debug)) {
        std.debug.print("To see all log messages, run with `env ZIG_LOG=debug ...`\n", .{});
    }

    const log = std.log.scoped(.scope);

    log.debug("debug message", .{});
    log.info("info message", .{});
    log.warn("warn message", .{});
    log.err("error message", .{});
}
