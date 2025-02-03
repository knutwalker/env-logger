const std = @import("std");

/// Setup the logger using the given options.
/// Returns the standard options that needs to be set as
/// `pub const std_options: std.Options` in the root of your application.
///
/// If you want to set custom std_options as well, use [`setupWith`].
pub fn setup(opts: SetupOptions) std.Options {
    return setupWith(opts, .{ .log_level = .debug });
}

/// Setup the logger using the given options and merge it with the given std_options.
/// Returns the standard options that needs to be set as
/// `pub const std_options: std.Options` in the root of your application.
///
/// For even more control over the std_options, use [`setupFn`].
pub fn setupWith(opts: SetupOptions, std_opts: std.Options) std.Options {
    var opts_copy = std_opts;
    opts_copy.logFn = setupFn(opts);
    return opts_copy;
}

/// Returns the function that needs to be set as the `log_fn` field to the
/// [`std.Options`] in your root of the application.
pub fn setupFn(opts: SetupOptions) fn (
    comptime message_level: std.log.Level,
    comptime scope: @TypeOf(.enum_literal),
    comptime format: []const u8,
    args: anytype,
) void {
    if (opts.enable_trace_level) {
        return traceLogFn;
    } else {
        return defaultLogFn;
    }
}

pub const SetupOptions = struct {
    /// Whether to look for the TRACE message tag
    enable_trace_level: bool = false,
};

/// Initialize the logger using the given options.
/// This method needs to be called as early as possible, before any logging is done.
///
/// Panics if called more than once.
pub fn init(opts: InitOptions) void {
    return tryInit(opts) catch @panic("Failed to initialize logger");
}

/// Initialize the logger using the given options.
/// This method needs to be called as early as possible, before any logging is done.
///
/// Returns an error if called more than once.
pub fn tryInit(opts: InitOptions) TryInitError!void {
    if (is_initialized.cmpxchgStrong(false, true, .monotonic, .monotonic) != null) {
        return error.AlreadyInitialized;
    }

    if (opts.filter) |filter| set_level: {
        const level = switch (filter) {
            .env_var => |env_var| level: {
                var buf: [16 * @sizeOf(u16)]u8 = undefined;
                var fba = std.heap.FixedBufferAllocator.init(buf[0..]);

                const env_filter = std.process.getEnvVarOwned(fba.allocator(), env_var) catch |err| switch (err) {
                    error.EnvironmentVariableNotFound => break :set_level,
                    error.InvalidWtf8, error.OutOfMemory => return TryInitError.InvalidFilter,
                };

                break :level InitOptions.LogLevel.parse(env_filter) orelse
                    return TryInitError.InvalidFilter;
            },
            .level => |level| level,
        };

        set_log_level(level);
    }

    switch (opts.output) {
        .stderr => {
            output_is_stderr = true;
            output = .{ .file = std.io.getStdErr() };
            if (opts.enable_color) {
                output_color = std.io.tty.detectConfig(output.?.file);
            }
        },
        .stdout => {
            output = .{ .file = std.io.getStdOut() };
            if (opts.enable_color) {
                output_color = std.io.tty.detectConfig(output.?.file);
            }
        },
        .file => |file| {
            const end = try file.getEndPos();
            try file.seekTo(end);

            output = .{ .file = file };
        },
        .writer => |writer| {
            output = .{ .writer = writer };
        },
    }

    if (opts.force_color) {
        output_color = .escape_codes;
    }

    impl_opts = .{
        .color = opts.enable_color,
        .level = opts.render_level,
        .timestamp = opts.render_timestamp,
        .logger = opts.render_logger,
    };
}

pub const InitOptions = struct {
    /// How to configure the initial log level.
    /// Set to `null` to keep the default (only errors are logged).
    filter: ?Filter = .{ .env_var = "ZIG_LOG" },

    /// Whether to attempt to render colors
    /// Rendering still goes through [`std.io.tty.detectConfig`].
    enable_color: bool = true,

    /// Whether to force the use of color against all other indications not to.
    force_color: bool = false,

    /// Whether the loglevel should be rendered
    render_level: bool = true,

    /// Whether the current timestamp should be rendered
    render_timestamp: bool = false,

    /// WHether the logger name should be rendered
    render_logger: bool = true,

    /// Where to log to. See [`Output`].
    output: Output = .stderr,

    pub const Filter = union(enum) {
        /// The env variable to check for logging configuration.
        env_var: []const u8,

        /// The log level to use.
        level: LogLevel,
    };

    pub const Output = union(enum) {
        /// Write logs to stderr
        stderr,

        /// Write logs to stdout
        stdout,

        /// Append logs to a file
        /// Will seek to the end of the file before writing
        file: std.fs.File,

        /// Write logs to a writer
        writer: std.io.AnyWriter,
    };

    /// This mirrors `std.log.Level` and adds the `trace` level.
    pub const LogLevel = enum {
        err,
        warn,
        info,
        debug,
        trace,

        pub fn more(level: *LogLevel) void {
            LogLevel.move(level, 1);
        }

        pub fn less(level: *LogLevel) void {
            LogLevel.move(level, -1);
        }

        pub fn move(level: *LogLevel, dir: i64) void {
            var level_value: i64 = @as(i64, @intFromEnum(level.*));
            level_value +|= dir;
            level_value = std.math.clamp(level_value, 0, @as(i64, std.meta.fields(LogLevel).len - 1));
            level.* = @enumFromInt(@as(std.meta.Tag(LogLevel), @intCast(level_value)));
        }

        pub inline fn fromStd(level: std.log.Level) LogLevel {
            return @enumFromInt(@intFromEnum(level));
        }

        pub fn parse(str: []const u8) ?LogLevel {
            const matches = std.ascii.eqlIgnoreCase;
            if (matches(str, "trace")) return .trace;
            if (matches(str, "debug")) return .debug;
            if (matches(str, "info")) return .info;
            if (matches(str, "warn")) return .warn;
            if (matches(str, "warning")) return .warn;
            if (matches(str, "err")) return .err;
            if (matches(str, "error")) return .err;
            return null;
        }

        fn toStd(level: LogLevel) std.log.Level {
            return switch (level) {
                .err => .err,
                .warn => .warn,
                .info => .info,
                .debug => .debug,
                .trace => .debug,
            };
        }

        test more {
            const t = std.testing;

            var level: LogLevel = .err;
            level.more();
            try t.expectEqual(.warn, level);
            level.more();
            try t.expectEqual(.info, level);
            level.more();
            try t.expectEqual(.debug, level);
            level.more();
            try t.expectEqual(.trace, level);
            level.more();
            try t.expectEqual(.trace, level);
        }

        test less {
            const t = std.testing;

            var level: LogLevel = .trace;
            level.less();
            try t.expectEqual(.debug, level);
            level.less();
            try t.expectEqual(.info, level);
            level.less();
            try t.expectEqual(.warn, level);
            level.less();
            try t.expectEqual(.err, level);
            level.less();
            try t.expectEqual(.err, level);
        }

        test move {
            const t = std.testing;

            var level: LogLevel = .err;

            level.move(2);
            try t.expectEqual(.info, level);

            level.move(3);
            try t.expectEqual(.trace, level);

            level.move(-1);
            try t.expectEqual(.debug, level);

            level.move(-2);
            try t.expectEqual(.warn, level);

            level.move(-3);
            try t.expectEqual(.err, level);

            level.move(std.math.minInt(i64));
            try t.expectEqual(.err, level);

            level.move(std.math.maxInt(i64));
            try t.expectEqual(.trace, level);
        }
    };
};

pub const TryInitError = error{
    AlreadyInitialized,
    InvalidFilter,
} || std.fs.File.GetSeekPosError;

/// Returns whether the given log level is enabled.
pub fn level_enabled(level: InitOptions.LogLevel) bool {
    return @intFromEnum(level) <= level_filter.load(.monotonic);
}

/// Changes the current log level filter.
pub fn set_log_level(level: InitOptions.LogLevel) void {
    level_filter.store(@intFromEnum(level), .monotonic);
}

var is_initialized: std.atomic.Value(bool) = .init(false);
var level_filter: std.atomic.Value(u8) = .init(@intFromEnum(std.log.Level.err));

const Opts = struct {
    color: bool = false,
    level: bool = false,
    timestamp: bool = false,
    logger: bool = false,
};

var impl_opts: Opts = .{};
var output_color: std.io.tty.Config = .no_color;
var output: ?union(enum) { file: std.fs.File, writer: std.io.AnyWriter } = null;
var output_is_stderr: bool = false;

fn defaultLogFn(
    comptime message_level: std.log.Level,
    comptime scope: @TypeOf(.enum_literal),
    comptime format: []const u8,
    args: anytype,
) void {
    const level = comptime InitOptions.LogLevel.fromStd(message_level);
    logFn(level, scope, format, args);
}

fn traceLogFn(
    comptime message_level: std.log.Level,
    comptime scope: @TypeOf(.enum_literal),
    comptime format: []const u8,
    args: anytype,
) void {
    if (comptime std.mem.startsWith(u8, format, "TRACE: ")) {
        logFn(.trace, scope, format["TRACE: ".len..], args);
    } else {
        const level = comptime InitOptions.LogLevel.fromStd(message_level);
        logFn(level, scope, format, args);
    }
}

inline fn logFn(
    comptime message_level: InitOptions.LogLevel,
    comptime scope: @TypeOf(.enum_literal),
    comptime format: []const u8,
    args: anytype,
) void {
    const out = output orelse return;

    if (@intFromEnum(message_level) > level_filter.load(.monotonic)) {
        return;
    }

    const target = comptime if (scope == .default) "" else "(" ++ @tagName(scope) ++ ")";

    switch (out) {
        .file => |f| {
            if (output_is_stderr) std.debug.lockStdErr();
            defer if (output_is_stderr) std.debug.unlockStdErr();

            const fw = f.writer();
            var bw = std.io.bufferedWriter(fw);
            defer bw.flush() catch {};

            const writer = bw.writer();

            logImpl(
                impl_opts,
                writer,
                message_level,
                target,
                format,
                args,
            ) catch return;
        },
        .writer => |w| {
            logImpl(
                impl_opts,
                w,
                message_level,
                target,
                format,
                args,
            ) catch return;
        },
    }
}

fn logImpl(
    opts: Opts,
    writer: anytype,
    comptime message_level: InitOptions.LogLevel,
    comptime target: []const u8,
    comptime format: []const u8,
    args: anytype,
) !void {
    try writer.writeAll(" ");

    const cfg = output_color;

    if (opts.timestamp) ts: {
        const nows = std.math.lossyCast(u64, std.time.milliTimestamp());

        const epoch_seconds = std.time.epoch.EpochSeconds{ .secs = nows / std.time.ms_per_s };
        const epoch_day = epoch_seconds.getEpochDay();
        const day_seconds = epoch_seconds.getDaySeconds();
        const year_day = epoch_day.calculateYearDay();
        const month_day = year_day.calculateMonthDay();

        var buf: [128]u8 = undefined;
        const timestamp = std.fmt.bufPrint(
            &buf,
            "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}.{d:0>3}Z",
            .{
                year_day.year,
                month_day.month.numeric(),
                month_day.day_index + 1,
                day_seconds.getHoursIntoDay(),
                day_seconds.getMinutesIntoHour(),
                day_seconds.getSecondsIntoMinute(),
                nows % std.time.ms_per_s,
            },
        ) catch break :ts;

        try writer.writeAll(timestamp);
        try writer.writeAll(" ");
    }

    if (opts.level) {
        const color, const level = comptime switch (message_level) {
            .err => .{ .red, "ERROR" },
            .warn => .{ .yellow, "WARN " },
            .info => .{ .green, "INFO " },
            .debug => .{ .blue, "DEBUG" },
            .trace => .{ .magenta, "TRACE" },
        };

        try cfg.setColor(writer, color);
        try writer.writeAll(level);
        try cfg.setColor(writer, .reset);
        try writer.writeAll(" ");
    }

    if (opts.logger) {
        const width = targetWidth(target.len);

        try cfg.setColor(writer, .bold);
        try writer.print(
            "{[target]s: >[width]}",
            .{ .target = target, .width = width },
        );
        try cfg.setColor(writer, .reset);
        try writer.writeAll(" ");
    }

    try writer.print(format ++ "\n", args);
}

var max_width: std.atomic.Value(usize) = .init(0);

inline fn targetWidth(comptime width: usize) usize {
    return @max(width, max_width.fetchMax(width, .monotonic));
}
