// SPDX-License-Identifier: MIT

const std = @import("std");

const env_logger = @import("env_logger");

// Setting a log_level here will always discard any message of a lower level
// even if the filter would allow them. Higher levels can still be filtered.
pub const std_options = env_logger.setup(.{ .min_log_level = .info });

pub fn main(init: std.process.Init) !void {
    // can also set the runtime level directly without parsing
    env_logger.init(init, .{ .filter = .{ .level = .debug } });

    // std.log.logEnabled returns false for debug, which will effectively
    // remove all calls to log.debug at comptime
    try std.testing.expect(std.log.logEnabled(.debug, .default) == false);

    // env_logger still reports that debug is enabled according to the filter logic
    try std.testing.expect(env_logger.levelEnabled(.default, .debug) == true);

    // struct does not have a format function, but debug calls are eliminated
    // so this is never reported by the compiler and compilation succeeds
    std.log.debug("you will never see me: {f}", .{struct {}});
    std.log.info("info message", .{});
    std.log.warn("warn message", .{});
    std.log.err("error message", .{});
}
