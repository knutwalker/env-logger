// SPDX-License-Identifier: MIT

const std = @import("std");
const env_logger = @import("env-logger");

pub const std_options = env_logger.setup(.{});

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{ .verbose_log = true }) = .init;
    defer if (gpa.deinit() == .leak) @panic("memory leak");

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    env_logger.init(.{ .allocator = .{ .split = .{
        .parse_gpa = gpa.allocator(),
        .filter_arena = arena.allocator(),
    } } });

    if (!env_logger.defaultLevelEnabled(.debug)) {
        std.debug.print("To see all log messages, run with `env ZIG_LOG=debug ...`\n", .{});
    }

    std.log.debug("debug message", .{});
    std.log.info("info message", .{});
    std.log.warn("warn message", .{});
    std.log.err("error message", .{});
}
