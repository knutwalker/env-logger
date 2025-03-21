const std = @import("std");

const Filter = @import("Filter.zig");
const Builder = @import("Builder.zig");

/// Options for `setup` functions.
pub const SetupOptions = struct {
    /// Whether to look for the TRACE message tag
    enable_trace_level: bool = false,
};

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
        return RtConfig.traceLogFn;
    } else {
        return RtConfig.defaultLogFn;
    }
}

/// Options for `init` functions.
pub const InitOptions = struct {
    /// How to configure the initial log level.
    /// Set to `null` to keep the default (only errors are logged).
    filter: ?FilterOpts = .{ .env = .{} },

    /// The allocator which is used for initializing the filter.
    ///
    /// The allocator is used for reading and parsing the `filter` env var
    /// (if set to `.env_var`), parsing the resulting filter string,
    /// and allocating the resulting filter config.
    ///
    /// Since the filter is supposed to be kept for the remainder
    /// of the program's lifetime, you can set two different allocators, one
    /// for all the parsing (e.g. a gpa, like the `DebugAllocator`), and another
    /// one for the final filter allocation (e.g. an arena allocator).
    allocator: union(enum) {
        /// Creates and leakes an `ArenaAllocator(page_allocator)`.
        leaky,

        /// Use one allocator for all allocations.
        arena: std.mem.Allocator,

        /// Use separate allocators for parsing and filter allocation.
        split: struct {
            parse_gpa: std.mem.Allocator,
            filter_arena: std.mem.Allocator,
        },
    } = .leaky,

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

    pub const FilterOpts = union(enum) {
        /// The env variable to check for logging configuration.
        env: EnvVarOpts,

        /// A filter config that will be parsed.
        parse: []const u8,

        /// A log level to use for all loggers.
        level: Filter.Level,

        /// A list of filter directives. Should be created with `Builder`.
        filter: Filter,

        pub const EnvVarOpts = struct {
            /// The name of the env variable to check and parse.
            name: []const u8 = "ZIG_LOG",
            /// If the env variable is missing, use this value as default fallback.
            /// When this is set to null, use the global default, which only logs
            /// errors.
            fallback: ?Filter.Level = null,
        };

        fn intoFilter(
            self: FilterOpts,
            parse_gpa: std.mem.Allocator,
            filter_arena: ?std.mem.Allocator,
        ) TryInitError!Filter {
            // we can delay hitting the gpa for parsing the env var as it is likely smaller
            var fba = std.heap.stackFallback(4096, parse_gpa);
            const stack_gpa = fba.get();

            // drop all at the end
            // maybe this is all overkill, dunno
            var arena_impl: std.heap.ArenaAllocator = .init(stack_gpa);
            defer arena_impl.deinit();

            const arena = arena_impl.allocator();

            sw: switch (self) {
                .env => |env| {
                    const env_filters = std.process.getEnvVarOwned(arena, env.name) catch |err| switch (err) {
                        error.EnvironmentVariableNotFound => {
                            if (env.fallback) |fallback| {
                                continue :sw .{ .level = fallback };
                            } else {
                                return .default;
                            }
                        },
                        error.InvalidWtf8 => return TryInitError.InvalidEnvValue,
                        else => |e| return e,
                    };
                    continue :sw .{ .parse = env_filters };

                },
                .parse => |filter_input| return try parseFilter(filter_input, arena, filter_arena),
                .level => |level| return try Builder.singleLevel(filter_arena orelse arena, level),
                .filter => |filter| return filter,
            }
        }

        fn parseFilter(
            filter_input: []const u8,
            parse_gpa: std.mem.Allocator,
            filter_arena: ?std.mem.Allocator,
        ) TryInitError!Filter {
            var builder = Builder.init(parse_gpa);
            defer builder.deinit();

            builder.tryParse(filter_input) catch |err| switch (err) {
                error.BuilderError => {
                    for (builder.diagnostics()) |diag| switch (diag) {
                        .invalid_filter => |f| {
                            std.debug.print("Warning: Invalid filter: `{s}`, ignoring it\n", .{f});
                        },
                    };
                },
                else => |e| return e,
            };

            return try if (filter_arena) |a| builder.buildWithAllocator(a) else builder.build();
        }
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
    const S = struct {
        var is_initialized: std.atomic.Value(bool) = .init(false);
    };

    if (S.is_initialized.cmpxchgStrong(false, true, .monotonic, .monotonic) != null) {
        return error.AlreadyInitialized;
    }

    var rt: RtConfig = .{};

    if (opts.filter) |init_filter| {
        rt.filter = try filter: switch (opts.allocator) {
            .leaky => {
                var parse_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
                defer parse_arena.deinit();

                var filter_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
                // leak the filter arena

                break :filter init_filter.intoFilter(parse_arena.allocator(), filter_arena.allocator());
            },
            .arena => |arena| {
                break :filter init_filter.intoFilter(arena, null);
            },
            .split => |split| {
                break :filter init_filter.intoFilter(split.parse_gpa, split.filter_arena);
            },
        };
    }

    switch (opts.output) {
        .stderr => {
            const file = std.io.getStdErr();
            rt.output_is_stderr = true;
            rt.output = .{ .file = file };
            if (opts.enable_color) {
                rt.color_cfg = std.io.tty.detectConfig(file);
            }
        },
        .stdout => {
            const file = std.io.getStdOut();
            rt.output = .{ .file = file };
            if (opts.enable_color) {
                rt.color_cfg = std.io.tty.detectConfig(file);
            }
        },
        .file => |file| {
            const end = try file.getEndPos();
            try file.seekTo(end);

            rt.output = .{ .file = file };
        },
        .writer => |writer| {
            rt.output = .{ .writer = writer };
        },
    }

    if (opts.force_color) {
        rt.color_cfg = .escape_codes;
    }

    rt.render_level = opts.render_level;
    rt.render_timestamp = opts.render_timestamp;
    rt.render_logger = opts.render_logger;

    RtConfig.instance = rt;
}

pub const TryInitError = error{
    AlreadyInitialized,
    InvalidEnvValue,
    InvalidFilterValue,
} || std.fs.File.GetSeekPosError || std.mem.Allocator.Error;

pub fn defaultLevelEnabled(level: Filter.Level) bool {
    return levelEnabled(.default, level);
}

pub fn levelEnabled(scope: @TypeOf(.enum_literal), level: Filter.Level) bool {
    const target = if (scope == .default) "" else @tagName(scope);
    return RtConfig.instance.filter.matches(target, level);
}

pub fn deinit() void {
    RtConfig.instance.deinit();
}

const RtConfig = struct {
    filter: Filter = .default,
    color_cfg: std.io.tty.Config = .no_color,
    output: ?Out = null,
    output_is_stderr: bool = false,
    render_level: bool = false,
    render_timestamp: bool = false,
    render_logger: bool = false,

    const Out = union(enum) {
        file: std.fs.File,
        writer: std.io.AnyWriter,
    };

    var instance: RtConfig = .{};
    var max_width: std.atomic.Value(usize) = .init(0);

    fn deinit(self: *RtConfig, allocator: std.mem.Allocator) void {
        self.filter.deinit(allocator);
        self.* = .{};
    }

    fn defaultLogFn(
        comptime message_level: std.log.Level,
        comptime scope: @TypeOf(.enum_literal),
        comptime format: []const u8,
        args: anytype,
    ) void {
        const level = comptime Filter.Level.fromStd(message_level);
        instance.logFn(level, scope, format, args);
    }

    fn traceLogFn(
        comptime message_level: std.log.Level,
        comptime scope: @TypeOf(.enum_literal),
        comptime format: []const u8,
        args: anytype,
    ) void {
        if (comptime std.mem.startsWith(u8, format, "TRACE: ")) {
            instance.logFn(.trace, scope, format["TRACE: ".len..], args);
        } else {
            const level = comptime Filter.Level.fromStd(message_level);
            instance.logFn(level, scope, format, args);
        }
    }

    inline fn logFn(
        self: *const RtConfig,
        comptime message_level: Filter.Level,
        comptime scope: @TypeOf(.enum_literal),
        comptime format: []const u8,
        args: anytype,
    ) void {
        const out = self.output orelse return;

        const scope_name = comptime if (scope == .default) "" else @tagName(scope);
        if (self.filter.matches(scope_name, message_level) == false) return;

        const target = comptime if (scope == .default) "" else "(" ++ @tagName(scope) ++ ")";

        switch (out) {
            .file => |f| {
                if (self.output_is_stderr) std.debug.lockStdErr();
                defer if (self.output_is_stderr) std.debug.unlockStdErr();

                const fw = f.writer();
                var bw = std.io.bufferedWriter(fw);
                defer bw.flush() catch {};

                const writer = bw.writer();

                self.logImpl(
                    writer,
                    message_level,
                    target,
                    format,
                    args,
                ) catch return;
            },
            .writer => |w| {
                self.logImpl(
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
        self: *const RtConfig,
        writer: anytype,
        comptime message_level: Filter.Level,
        comptime target: []const u8,
        comptime format: []const u8,
        args: anytype,
    ) !void {
        try writer.writeAll(" ");

        const cfg = self.color_cfg;

        if (self.render_timestamp) ts: {
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

        if (self.render_level) {
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

        if (self.render_logger) {
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

    inline fn targetWidth(comptime width: usize) usize {
        return @max(width, max_width.fetchMax(width, .monotonic));
    }
};
