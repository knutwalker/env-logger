// SPDX-License-Identifier: MIT

const std = @import("std");

const env_logger = @import("env_logger");

pub const std_options = env_logger.setup(.{});

pub fn main() !void {
    // the only allocation free filter is using the `filter` branch of the `filter` enum.
    // A `Filter` can be built by wrapping a static `ScopeLevel`.
    // Consider the lifetime of that reference to be static, it must not move or change.
    const level: env_logger.ScopeLevel = .of(.debug);
    const single_filter: env_logger.Filter = .single(&level);
    _ = single_filter;

    // An alternative is to wrap an non-const slice.
    // The same lifetime considerations apply.
    var filters: [2]env_logger.ScopeLevel = .{ .scoped(.scope, .debug), .of(.info) };
    const filter: env_logger.Filter = .filters(&filters);

    // avoid the default leaky allocation
    const gpa = std.mem.Allocator.failing;

    // The last allocation to avoid is the default write buffer
    var buf: [1024]u8 = undefined;

    // initRaw does require any juicy-main init instance
    env_logger.initRaw(.{
        .allocator = .{ .arena = gpa },
        .filter = .{ .filter = filter },
        .write_buffer = &buf,
    });

    std.log.debug("default debug message (not visible)", .{});

    const scoped = std.log.scoped(.scope);
    scoped.debug("scoped debug message", .{});

    std.log.info("info message", .{});
    scoped.info("scoped info message", .{});
}
