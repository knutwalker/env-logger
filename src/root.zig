// SPDX-License-Identifier: MIT

const Logger = @import("Logger.zig");
pub const Filter = @import("Filter.zig");
pub const Builder = @import("Builder.zig");
pub const Level = Filter.Level;
pub const defaultLevelEnabled = Logger.defaultLevelEnabled;
pub const levelEnabled = Logger.levelEnabled;

pub const SetupOptions = Logger.SetupOptions;
pub const setup = Logger.setup;
pub const setupWith = Logger.setupWith;
pub const setupFn = Logger.setupFn;

pub const InitOptions = Logger.InitOptions;
pub const init = Logger.init;
pub const tryInit = Logger.tryInit;
pub const deinit = Logger.deinit;

test "force analysis" {
    comptime {
        @import("std").testing.refAllDecls(@This());
        _ = Logger;
    }
}

test "quick example" {
    const std = @import("std");

    var output: std.io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();

    init(.{
        .filter = .{ .level = .debug },
        .output = .{ .writer = &output.writer },
    });
    const logger = setupFn(.{ .enable_trace_level = true });

    logger(.debug, .default, "message 1", .{});
    logger(.info, .scope, "message {}", .{1 + 1});
    logger(.warn, .default, "{f}", .{std.zig.fmtId("message 3")});
    logger(.err, .longer_scope, "message 4", .{});

    const out = try output.toOwnedSlice();
    defer std.testing.allocator.free(out);

    try std.testing.expectEqualStrings(
        \\DEBUG message 1
        \\INFO  (scope) message 2
        \\WARN          @"message 3"
        \\ERROR (longer_scope) message 4
        \\
    , out);
}
