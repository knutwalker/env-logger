// SPDX-License-Identifier: MIT

pub const Builder = @import("Builder.zig");
pub const Filter = @import("Filter.zig");
pub const Level = Filter.Level;
pub const ScopeLevel = Filter.ScopeLevel;
const Logger = @import("Logger.zig");
pub const defaultLevelEnabled = Logger.defaultLevelEnabled;
pub const levelEnabled = Logger.levelEnabled;
pub const defaultLogEnabled = Logger.defaultLogEnabled;
pub const logEnabled = Logger.logEnabled;
pub const SetupOptions = Logger.SetupOptions;
pub const setup = Logger.setup;
pub const setupWith = Logger.setupWith;
pub const loggerFn = Logger.loggerFn;
pub const InitOptions = Logger.InitOptions;
pub const init = Logger.init;
pub const initMin = Logger.initMin;
pub const initRaw = Logger.initRaw;
pub const tryInit = Logger.tryInit;
pub const tryInitMin = Logger.tryInitMin;
pub const tryInitRaw = Logger.tryInitRaw;
pub const deinit = Logger.deinit;

test "force analysis" {
    comptime {
        @import("std").testing.refAllDecls(@This());
        _ = Logger;
    }
}

test "quick example" {
    const std = @import("std");

    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();

    initRaw(.{
        .filter = .{ .level = .trace },
        .output = .{ .writer = &output.writer },
    });
    const logger = loggerFn(.{ .enable_trace_level = true });

    logger(.debug, .default, "TRACE: trace_message", .{});
    logger(.debug, .default, "message 1", .{});
    logger(.info, .scope, "message {}", .{1 + 1});
    logger(.warn, .default, "{f}", .{std.zig.fmtId("message 3")});
    logger(.err, .longer_scope, "message 4", .{});

    const out = try output.toOwnedSlice();
    defer std.testing.allocator.free(out);

    try std.testing.expectEqualStrings(
        \\TRACE trace_message
        \\DEBUG message 1
        \\INFO  (scope) message 2
        \\WARN          @"message 3"
        \\ERROR (longer_scope) message 4
        \\
    , out);
}
