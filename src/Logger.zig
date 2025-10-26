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

        pub fn parseEnv(
            opts: EnvVarOpts,
            gpa: std.mem.Allocator,
            filter_arena: ?std.mem.Allocator,
        ) TryInitError!Filter {
            var builder = Builder.init(gpa);
            defer builder.deinit();

            if (!try builder.parseEnvLogErrors(opts.name)) {
                if (opts.fallback) |fallback| {
                    try builder.addLevel(fallback);
                } else {
                    try builder.addScopeLevel(.default);
                }
            }

            return try if (filter_arena) |a| builder.buildWithAllocator(a) else builder.build();
        }

        pub fn parseConfig(
            config: []const u8,
            gpa: std.mem.Allocator,
            filter_arena: ?std.mem.Allocator,
        ) TryInitError!Filter {
            var builder = Builder.init(gpa);
            defer builder.deinit();

            try builder.parseLogErrors(config);

            return try if (filter_arena) |a| builder.buildWithAllocator(a) else builder.build();
        }

        pub fn wrapLevel(level: Filter.Level, arena: std.mem.Allocator) TryInitError!Filter {
            return try Builder.singleLevel(arena, level);
        }

        fn intoFilter(
            self: FilterOpts,
            parse_gpa: std.mem.Allocator,
            filter_arena: ?std.mem.Allocator,
        ) TryInitError!Filter {
            switch (self) {
                .env => |env| return parseEnv(env, parse_gpa, filter_arena),
                .parse => |spec| return parseConfig(spec, parse_gpa, filter_arena),
                .level => |level| return try wrapLevel(level, filter_arena orelse parse_gpa),
                .filter => |filter| return filter,
            }
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
        try rt.initFilter(init_filter, opts.allocator);
    }

    try switch (opts.output) {
        .stderr => rt.for_stderr(opts.enable_color),
        .stdout => rt.for_stdout(opts.enable_color),
        .file => |file| rt.for_file(file),
        .writer => |writer| rt.for_writer(writer),
    };

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
    allocator: Alloc = .none,
    filter: Filter = .default,
    color_cfg: std.io.tty.Config = .no_color,
    output: Out = .noop,
    render_level: bool = false,
    render_timestamp: bool = false,
    render_logger: bool = false,

    const Out = union(enum) {
        noop,
        stderr: std.fs.File,
        stdout: std.fs.File,
        file: std.fs.File,
        writer: std.io.AnyWriter,
    };

    const Alloc = union(enum) {
        none,
        borrowed: std.mem.Allocator,
        owned: std.heap.ArenaAllocator,
    };

    var instance: RtConfig = .{};
    var max_width: std.atomic.Value(usize) = .init(0);

    fn deinit(self: *RtConfig) void {
        switch (self.allocator) {
            .none => {},
            .borrowed => |alloc| self.filter.deinit(alloc),
            .owned => |*arena| self.filter.deinit(arena.allocator()),
        }
        if (self.output == .file) {
            self.output.file.close();
        }
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

    fn initFilter(
        self: *RtConfig,
        init_filter: InitOptions.FilterOpts,
        allocator: @FieldType(InitOptions, "allocator"),
    ) !void {
        switch (allocator) {
            .leaky => {
                var parse_gpa: std.heap.DebugAllocator(.{}) = .init;
                defer _ = parse_gpa.deinit();

                var filter_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
                self.allocator = .{ .owned = filter_arena };

                self.filter = try init_filter.intoFilter(parse_gpa.allocator(), filter_arena.allocator());
            },
            .arena => |arena| {
                self.allocator = .{ .borrowed = arena };
                self.filter = try init_filter.intoFilter(arena, null);
            },
            .split => |split| {
                self.allocator = .{ .borrowed = split.filter_arena };
                self.filter = try init_filter.intoFilter(split.parse_gpa, split.filter_arena);
            },
        }
    }

    fn for_stderr(self: *RtConfig, enable_color: bool) !void {
        const file = std.io.getStdErr();
        self.output = .{ .stderr = file };
        if (enable_color) {
            self.color_cfg = std.io.tty.detectConfig(file);
        }
    }

    fn for_stdout(self: *RtConfig, enable_color: bool) !void {
        const file = std.io.getStdOut();
        self.output = .{ .stdout = file };
        if (enable_color) {
            self.color_cfg = std.io.tty.detectConfig(file);
        }
    }

    fn for_file(self: *RtConfig, file: std.fs.File) !void {
        const end = try file.getEndPos();
        try file.seekTo(end);
        self.output = .{ .file = file };
    }

    fn for_writer(self: *RtConfig, writer: std.io.AnyWriter) void {
        self.output = .{ .writer = writer };
    }

    inline fn logFn(
        self: *RtConfig,
        comptime message_level: Filter.Level,
        comptime scope: @TypeOf(.enum_literal),
        comptime format: []const u8,
        args: anytype,
    ) void {
        const scope_name = comptime if (scope == .default) "" else @tagName(scope);
        if (self.filter.matches(scope_name, message_level) == false) return;

        var bo: ?std.io.BufferedWriter(4096, std.fs.File.Writer) = null;
        if (self.output == .stderr) std.debug.lockStdErr();
        const writer = writer: switch (self.output) {
            .noop => return,
            .stderr, .stdout, .file => |*file| {
                bo = std.io.bufferedWriter(file.writer());
                break :writer bo.?.writer().any();
            },
            .writer => |w| w,
        };
        defer if (self.output == .stderr) std.debug.unlockStdErr();
        defer if (bo) |*b| b.flush() catch {};

        const target = comptime if (scope == .default) "" else "(" ++ @tagName(scope) ++ ")";

        self.logImpl(
            writer,
            message_level,
            target,
            format,
            args,
        ) catch return;
    }

    fn logImpl(
        self: *const RtConfig,
        writer: anytype,
        comptime message_level: Filter.Level,
        comptime target: []const u8,
        comptime format: []const u8,
        args: anytype,
    ) !void {
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

            if (width > 0) {
                try cfg.setColor(writer, .bold);
                try writer.print(
                    "{[target]s: >[width]}",
                    .{ .target = target, .width = width },
                );
                try cfg.setColor(writer, .reset);
                try writer.writeAll(" ");
            }
        }

        try writer.print(format ++ "\n", args);
    }

    inline fn targetWidth(comptime width: usize) usize {
        return @max(width, max_width.fetchMax(width, .monotonic));
    }
};
