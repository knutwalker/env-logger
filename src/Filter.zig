const std = @import("std");
const mem = std.mem;

const Builder = @import("Builder.zig");

const Filter = @This();

/// Filters need to be sorted by length of scope, descending.
/// Consider using the `Builder` to construct a filter.
filters: []const ScopeLevel,

/// The default filter only allows all error log messages.
pub const default: Filter = .{ .filters = &[_]ScopeLevel{default_filter} };

pub const default_filter: ScopeLevel = .{ .scope = "", .level = .err };

pub const ScopeLevel = struct {
    scope: []const u8,
    level: Level,
};

/// This mirrors `std.log.Level` and adds the `trace` level.
pub const Level = enum {
    err,
    warn,
    info,
    debug,
    trace,

    /// Adjust the level by a measure of verbosity.
    /// A positive value increases the level from `err` to `trace`.
    /// A negative value decreases the level from `trace` to `err`.
    pub fn adjust(self: *Level, direction: i64) void {
        var level_value: i64 = @as(i64, @intFromEnum(self.*));
        level_value +|= direction;
        self.* = fromInt(level_value);
    }

    test adjust {
        const t = std.testing;

        var level: Level = .err;

        level.adjust(2);
        try t.expectEqual(.info, level);

        level.adjust(3);
        try t.expectEqual(.trace, level);

        level.adjust(-1);
        try t.expectEqual(.debug, level);

        level.adjust(-2);
        try t.expectEqual(.warn, level);

        level.adjust(-3);
        try t.expectEqual(.err, level);

        level.adjust(std.math.minInt(i64));
        try t.expectEqual(.err, level);

        level.adjust(std.math.maxInt(i64));
        try t.expectEqual(.trace, level);
    }

    /// Convert an integer to a log level.
    /// Invalid values are clamped to the range of `Level`.
    pub fn fromInt(level: anytype) Level {
        const value = std.math.clamp(level, 0, @as(@TypeOf(level), std.meta.fields(Level).len - 1));
        return @enumFromInt(@as(std.meta.Tag(Level), @intCast(value)));
    }

    test fromInt {
        const t = std.testing;
        try t.expectEqual(.err, Level.fromInt(-1));
        try t.expectEqual(.err, Level.fromInt(0));
        try t.expectEqual(.warn, Level.fromInt(1));
        try t.expectEqual(.info, Level.fromInt(2));
        try t.expectEqual(.debug, Level.fromInt(3));
        try t.expectEqual(.trace, Level.fromInt(4));
        try t.expectEqual(.trace, Level.fromInt(5));
    }

    pub inline fn fromStd(level: std.log.Level) Level {
        return @enumFromInt(@intFromEnum(level));
    }

    test fromStd {
        const t = std.testing;
        try t.expectEqual(.err, fromStd(.err));
        try t.expectEqual(.warn, fromStd(.warn));
        try t.expectEqual(.info, fromStd(.info));
        try t.expectEqual(.debug, fromStd(.debug));
    }

    pub fn parse(str: []const u8) ?Level {
        const eql = std.ascii.eqlIgnoreCase;
        if (eql(str, "trace")) return .trace;
        if (eql(str, "debug")) return .debug;
        if (eql(str, "info")) return .info;
        if (eql(str, "warn")) return .warn;
        if (eql(str, "warning")) return .warn;
        if (eql(str, "err")) return .err;
        if (eql(str, "error")) return .err;
        return null;
    }

    test parse {
        const t = std.testing;
        try t.expectEqual(.err, parse("err"));
        try t.expectEqual(.warn, parse("warn"));
        try t.expectEqual(.info, parse("info"));
        try t.expectEqual(.debug, parse("debug"));
        try t.expectEqual(.trace, parse("trace"));
        try t.expectEqual(.err, parse("error"));
        try t.expectEqual(.warn, parse("warning"));
        try t.expectEqual(null, parse("gobbledygook"));
    }

    fn toStd(level: Level) std.log.Level {
        return switch (level) {
            .err => .err,
            .warn => .warn,
            .info => .info,
            .debug => .debug,
            .trace => .debug,
        };
    }

    test toStd {
        const t = std.testing;
        try t.expectEqual(.err, toStd(.err));
        try t.expectEqual(.warn, toStd(.warn));
        try t.expectEqual(.info, toStd(.info));
        try t.expectEqual(.debug, toStd(.debug));
        try t.expectEqual(.debug, toStd(.trace));
    }
};

pub fn deinit(self: Filter, allocator: mem.Allocator) void {
    for (self.filters) |sl| {
        if (sl.scope.len > 0) allocator.free(sl.scope);
    }
    allocator.free(self.filters);
}

/// Returns whether the given log level is enabled for the given scope.
/// Assumes the the filters are sorted by length of scope, descending.
/// If this assumption is violated, the result may be incorrect.
pub fn matches(self: *const Filter, scope: []const u8, level: Level) bool {
    for (self.filters) |filter| {
        if (std.mem.startsWith(u8, scope, filter.scope)) {
            return @intFromEnum(level) <= @intFromEnum(filter.level);
        }
    }
    return false;
}

test "matches on default filter" {
    const t = std.testing;

    try t.expectEqual(true, default.matches("", .err));
    try t.expectEqual(true, default.matches("scope", .err));
    try t.expectEqual(false, default.matches("", .info));
    try t.expectEqual(false, default.matches("scope", .info));
}

test "matches on single level filter" {
    const t = std.testing;

    const filter = Filter{ .filters = &[_]ScopeLevel{.{ .scope = "", .level = .debug }} };

    try t.expectEqual(true, filter.matches("", .info));
    try t.expectEqual(true, filter.matches("", .debug));
    try t.expectEqual(false, filter.matches("", .trace));
    try t.expectEqual(true, filter.matches("scope", .info));
    try t.expectEqual(true, filter.matches("scope", .debug));
    try t.expectEqual(false, filter.matches("scope", .trace));
}

test "matches on scoped level filter" {
    const t = std.testing;

    const filter = Filter{ .filters = &[_]ScopeLevel{.{ .scope = "scope", .level = .debug }} };

    try t.expectEqual(false, filter.matches("", .info));
    try t.expectEqual(false, filter.matches("", .debug));
    try t.expectEqual(false, filter.matches("", .trace));
    try t.expectEqual(true, filter.matches("scope", .info));
    try t.expectEqual(true, filter.matches("scope", .debug));
    try t.expectEqual(false, filter.matches("scope", .trace));
}

test "matches on multiple scoped level filters" {
    const t = std.testing;

    const filter = Filter{ .filters = &[_]ScopeLevel{
        .{ .scope = "scope2", .level = .debug },
        .{ .scope = "scope", .level = .info },
    } };

    try t.expectEqual(false, filter.matches("", .info));
    try t.expectEqual(false, filter.matches("", .debug));
    try t.expectEqual(false, filter.matches("", .trace));
    try t.expectEqual(true, filter.matches("scope", .info));
    try t.expectEqual(false, filter.matches("scope", .debug));
    try t.expectEqual(false, filter.matches("scope", .trace));
    try t.expectEqual(true, filter.matches("scope2", .info));
    try t.expectEqual(true, filter.matches("scope2", .debug));
    try t.expectEqual(false, filter.matches("scope2", .trace));
}
