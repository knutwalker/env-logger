//! A builder to crate a list of scope filters.
//! The input can be added programmatically or a string is parsed.
//! The string format is a comma-separated list of `scope=level` pairs:
//!
//!     scope_a=info,scope_b=debug
//!
//! `scope` can be anything that is a valid `.enum_literal`.
//! `level` must be a valid value for [`Level'], in particular,
//! any of the following values (case-*in*sensitive):
//!
//!     - `trace`
//!     - `debug`
//!     - `warn` or `warning`
//!     - `err` or `error`
//!
//! The `scope` part can be missing, so that a value is just a `level`,
//! in which case the scope acts as a fallback for any scope not otherwise defined.
//!
//! The order of values does not matter for scope order.
//! Scopes are matched by prefix. That is, a value of `my_scope` will match all
//! scopes beginning with that value, such as `my_scope_nested`.
//! Longer scopes, i.e. more granular ones, have precedence over shorter scopes.

test Builder {
    var builder = Builder.init(std.testing.allocator);
    defer builder.deinit();

    builder.tryParse("warn,scope=info,scope_nested=debug,scope_inner=trace,another=invalid") catch |err| switch (err) {
        error.BuilderError => {
            for (builder.diagnostics()) |diag| {
                try std.testing.expectEqualStrings("invalid", diag.invalid_filter);
            }
        },
        else => return err,
    };
    const filter = try builder.build();
    defer filter.deinit(std.testing.allocator);

    try std.testing.expect(filter.matches("scope_inner", .trace));

    try std.testing.expect(filter.matches("scope_nested", .debug));
    try std.testing.expect(filter.matches("scope_nested", .trace) == false);

    try std.testing.expect(filter.matches("scope", .info));
    try std.testing.expect(filter.matches("scope", .debug) == false);

    try std.testing.expect(filter.matches("", .warn));
    try std.testing.expect(filter.matches("", .info) == false);
}

const std = @import("std");
const mem = std.mem;

const Filter = @import("Filter.zig");
const ScopeLevel = Filter.ScopeLevel;
const Level = Filter.Level;

const Builder = @This();

gpa: mem.Allocator,
filters: std.ArrayListUnmanaged(ScopeLevel) = .empty,
diags: std.ArrayListUnmanaged(Diagnostic) = .empty,

pub fn init(gpa: mem.Allocator) Builder {
    return .{ .gpa = gpa };
}

pub fn deinit(self: *Builder) void {
    for (self.diags.items) |err| {
        switch (err) {
            .invalid_filter => |invf| {
                self.gpa.free(invf);
            },
        }
    }
    self.diags.deinit(self.gpa);

    for (self.filters.items) |sl| {
        if (sl.scope.len > 0) self.gpa.free(sl.scope);
    }
    self.filters.deinit(self.gpa);
}

pub fn parse(self: *Builder, spec: []const u8) mem.Allocator.Error!void {
    var filters = std.mem.splitScalar(u8, spec, ',');
    while (filters.next()) |env_filter| {
        var env_kvs = std.mem.splitScalar(u8, std.mem.trim(u8, env_filter, &std.ascii.whitespace), '=');
        const scope_name_or_filter = std.mem.trimRight(u8, env_kvs.first(), &std.ascii.whitespace);
        const maybe_filter = std.mem.trimLeft(u8, env_kvs.rest(), &std.ascii.whitespace);

        if (scope_name_or_filter.len == 0) {
            continue;
        }

        const scope, const level = if (maybe_filter.len == 0) blk: {
            if (Level.parse(scope_name_or_filter)) |level| {
                break :blk .{ null, level };
            } else {
                break :blk .{ scope_name_or_filter, Level.trace };
            }
        } else blk: {
            if (Level.parse(maybe_filter)) |level| {
                break :blk .{ scope_name_or_filter, level };
            } else {
                try self.invalidFilter(maybe_filter);
                continue;
            }
        };
        try self.addFilter(scope, level);
    }
}

pub fn tryParse(self: *Builder, spec: []const u8) (error{BuilderError} || mem.Allocator.Error)!void {
    try self.parse(spec);
    if (self.diags.items.len > 0) return error.BuilderError;
}

pub fn parseLogErrors(self: *Builder, spec: []const u8) mem.Allocator.Error!void {
    self.tryParse(spec) catch |err| switch (err) {
        error.BuilderError => self.logDiagnostics(),
        else => |e| return e,
    };
}

pub fn parseEnv(self: *Builder, env_var: []const u8) (mem.Allocator.Error)!bool {
    const spec = std.process.getEnvVarOwned(self.gpa, env_var) catch |err| switch (err) {
        error.EnvironmentVariableNotFound => return false,
        error.InvalidWtf8 => {
            try self.invalidFilter(env_var);
            return false;
        },
        else => |e| return e,
    };
    defer self.gpa.free(spec);
    try self.parse(spec);
    return true;
}

pub fn tryParseEnv(self: *Builder, env_var: []const u8) (error{BuilderError} || mem.Allocator.Error)!bool {
    const ret = try self.parseEnv(env_var);
    if (self.diags.items.len > 0) return error.BuilderError;
    return ret;
}

pub fn parseEnvLogErrors(self: *Builder, env_var: []const u8) mem.Allocator.Error!bool {
    return self.tryParseEnv(env_var) catch |err| switch (err) {
        error.BuilderError => {
            self.logDiagnostics();
            return false;
        },
        else => |e| return e,
    };
}

pub fn logDiagnostics(self: *const Builder) void {
    for (self.diagnostics()) |diag| switch (diag) {
        .invalid_filter => |f| {
            std.debug.print("Warning: Invalid filter: `{s}`, ignoring it\n", .{f});
        },
    };
}

pub fn addFilter(self: *Builder, scope: ?[]const u8, level: Level) mem.Allocator.Error!void {
    const search_scope = scope orelse "";

    for (self.filters.items) |*item| {
        if (std.mem.eql(u8, item.scope, search_scope)) {
            item.level = level;
            return;
        }
    } else {
        const filter_scope = if (scope) |t| try self.gpa.dupe(u8, t) else "";
        try self.filters.append(self.gpa, .{
            .scope = filter_scope,
            .level = level,
        });
    }
}

pub fn addLevel(self: *Builder, level: Level) mem.Allocator.Error!void {
    try self.addFilter(null, level);
}

pub fn addScopeLevel(self: *Builder, scope: ScopeLevel) mem.Allocator.Error!void {
    try self.addFilter(scope.scope, scope.level);
}

pub fn diagnostics(self: *const Builder) []const Diagnostic {
    return self.diags.items;
}

pub fn build(self: *Builder) mem.Allocator.Error!Filter {
    return self.buildAny(null);
}

/// Allocates the returned slice either with `opts.arena` or this builders allocator.
/// The filter is likely gonna be kept alive for the remainder of the program lifetime,
/// using an arena allocator is recommended to leak that memory.
pub fn buildWithAllocator(self: *Builder, arena: mem.Allocator) mem.Allocator.Error!Filter {
    return self.buildAny(arena);
}

fn buildAny(self: *Builder, arena: ?mem.Allocator) mem.Allocator.Error!Filter {
    if (self.filters.items.len == 0) {
        return .default;
    }

    const filters = if (arena) |a| blk: {
        defer self.filters.deinit(self.gpa);

        const fs = try a.alloc(ScopeLevel, self.filters.items.len);
        for (self.filters.items, fs) |filter, *duped| {
            duped.* = .{
                .scope = try a.dupe(u8, filter.scope),
                .level = filter.level,
            };
        }
        break :blk fs;
    } else try self.filters.toOwnedSlice(self.gpa);

    std.mem.sort(ScopeLevel, filters, {}, struct {
        fn lt(_: void, lhs: ScopeLevel, rhs: ScopeLevel) bool {
            return lhs.scope.len > rhs.scope.len;
        }
    }.lt);

    return .{ .filters = filters };
}

pub fn singleLevel(arena: mem.Allocator, level: Level) mem.Allocator.Error!Filter {
    const filter = try arena.create(ScopeLevel);
    filter.* = .{ .scope = "", .level = level };

    return .{ .filters = @as(*[1]ScopeLevel, filter) };
}

pub const Diagnostic = union(enum) {
    invalid_filter: []const u8,
};

fn invalidFilter(self: *Builder, filter: []const u8) mem.Allocator.Error!void {
    const invalid_filter = try self.gpa.dupe(u8, filter);
    try self.diags.append(self.gpa, .{ .invalid_filter = invalid_filter });
}

fn testParse(spec: []const u8) ![]const Filter.ScopeLevel {
    var builder = Builder.init(std.testing.allocator);
    defer builder.deinit();

    try builder.parse(spec);
    const filter = try builder.build();
    return filter.filters;
}

fn deinitFilter(filters: []const Filter.ScopeLevel) void {
    (Filter{ .filters = filters }).deinit(std.testing.allocator);
}

test "parse empty" {
    const t = std.testing;

    const filter = try testParse("");

    try t.expectEqual(@as(usize, 1), filter.len);
    try t.expectEqual("", filter[0].scope);
    try t.expectEqual(.err, filter[0].level);
}

test "parse filters" {
    const t = std.testing;

    const filter = try testParse("scope1=info,scope2=debug");
    defer deinitFilter(filter);

    try t.expectEqual(@as(usize, 2), filter.len);
    try t.expectEqualStrings("scope1", filter[0].scope);
    try t.expectEqual(.info, filter[0].level);
    try t.expectEqualStrings("scope2", filter[1].scope);
    try t.expectEqual(.debug, filter[1].level);
}

test "sort filters by scope length" {
    const t = std.testing;

    const filter = try testParse("sc=warn,scope_more=debug,scope=info");
    defer deinitFilter(filter);

    try t.expectEqual(@as(usize, 3), filter.len);
    try t.expectEqualStrings("scope_more", filter[0].scope);
    try t.expectEqual(.debug, filter[0].level);
    try t.expectEqualStrings("scope", filter[1].scope);
    try t.expectEqual(.info, filter[1].level);
    try t.expectEqualStrings("sc", filter[2].scope);
    try t.expectEqual(.warn, filter[2].level);
}
