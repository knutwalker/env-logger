// SPDX-License-Identifier: MIT

const std = @import("std");
const env_logger = @import("env-logger");

pub const std_options = env_logger.setup(.{});

pub fn main() !void {
    env_logger.init(.{
        .filter = .{ .level = .info },
    });

    std.log.debug("you don't see me", .{});
    std.log.info("but I am here", .{});

    env_logger.set_log_level(.debug);

    std.log.debug("now you see me", .{});
}
