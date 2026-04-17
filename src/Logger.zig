const std = @import("std");

const Builder = @import("Builder.zig");
const Filter = @import("Filter.zig");

/// Options for `setup` functions.
pub const SetupOptions = struct {
    /// Whether to look for the TRACE message tag
    enable_trace_level: bool = false,

    /// Statically restrict the log_level to this level.
    /// All messages below this level will be discarded, regardless of the level configured in `init`.
    /// Configuring lower levels in `init` will not fail.
    min_log_level: std.log.Level = .debug,
};

/// Setup the logger using the given options.
/// Returns the standard options that needs to be set as
/// `pub const std_options: std.Options` in the root of your application.
///
/// If you want to set custom std_options as well, use [`setupWith`].
pub fn setup(comptime opts: SetupOptions) std.Options {
    return setupWith(opts, .{});
}

/// Setup the logger using the given options and merge it with the given std_options.
/// Returns the standard options that needs to be set as
/// `pub const std_options: std.Options` in the root of your application.
///
/// For even more control over the std_options, use [`setupFn`].
pub fn setupWith(comptime opts: SetupOptions, std_opts: std.Options) std.Options {
    var opts_copy = std_opts;
    opts_copy.log_level = opts.min_log_level;
    opts_copy.logFn = loggerFn(opts);
    return opts_copy;
}

/// Returns the function that needs to be set as the `log_fn` field to the
/// [`std.Options`] in your root of the application.
pub fn loggerFn(comptime opts: SetupOptions) fn (
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
    /// When using [`init`] or [`tryInit`], the allocators from the juicy-main
    /// init will be used.
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

    /// Use this [`std.Io`] instance for IO operations.
    ///
    /// When using [`init`] or [`tryInit`], the `Io` instance from the
    /// juicy-main init will be used.
    ///
    /// If `null`, the `debug_io` from std_options is used.
    io: ?std.Io = null,

    /// Use this environment to check for the env var.
    ///
    /// When using [`init`] or [`tryInit`], the `map` from the juicy-main
    /// init will be used.
    ///
    /// If `null`, an env based filter will use its fallback configuration.
    environ: ?union(enum) {
        map: *const std.process.Environ.Map,
        minimal: std.process.Environ,
    } = null,

    /// Where to log to. See [`Output`].
    output: Output = .stderr,

    /// Use this write buffer for any writing operations.
    /// If a [`std.Io.Writer`] is passed to `output`, this field is ignored.
    ///  If `null`, a heap allocated page-size buffer will be used.
    write_buffer: ?[]u8 = null,

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
            filter_arena: std.mem.Allocator,
            map: *const std.process.Environ.Map,
        ) TryInitError!Filter {
            var builder = Builder.init(gpa);
            defer builder.deinit();

            if (try builder.parseEnvLogErrors(opts.name, map) == false) {
                return envFallback(opts, gpa, filter_arena, builder);
            }

            return try builder.buildWithAllocator(filter_arena);
        }

        fn envFallback(
            opts: EnvVarOpts,
            gpa: std.mem.Allocator,
            filter_arena: std.mem.Allocator,
            builder: ?Builder,
        ) TryInitError!Filter {
            var b = builder orelse Builder.init(gpa);
            defer if (builder == null) b.deinit();

            if (opts.fallback) |fallback| {
                try b.addLevel(fallback);
            } else {
                try b.addScopeLevel(.default);
            }

            return try b.buildWithAllocator(filter_arena);
        }

        pub fn parseConfig(
            config: []const u8,
            gpa: std.mem.Allocator,
            filter_arena: std.mem.Allocator,
        ) TryInitError!Filter {
            var builder = Builder.init(gpa);
            defer builder.deinit();

            try builder.parseLogErrors(config);

            return try builder.buildWithAllocator(filter_arena);
        }

        pub fn wrapLevel(level: Filter.Level, arena: std.mem.Allocator) TryInitError!Filter {
            return try Builder.fromLevel(arena, level);
        }

        fn intoFilter(
            self: FilterOpts,
            parse_gpa: std.mem.Allocator,
            filter_arena: std.mem.Allocator,
            environ: @FieldType(InitOptions, "environ"),
        ) TryInitError!Filter {
            return switch (self) {
                .env => |env| if (environ) |envs| switch (envs) {
                    .map => |map| parseEnv(env, parse_gpa, filter_arena, map),
                    .minimal => |m| filter: {
                        var map = try m.createMap(parse_gpa);
                        defer map.deinit();

                        break :filter parseEnv(env, parse_gpa, filter_arena, &map);
                    },
                } else envFallback(env, parse_gpa, filter_arena, null),
                .parse => |spec| parseConfig(spec, parse_gpa, filter_arena),
                .level => |level| wrapLevel(level, filter_arena),
                .filter => |filter| filter,
            };
        }
    };

    pub const Output = union(enum) {
        /// Write logs to stderr.
        stderr,

        /// Write logs to stdout.
        stdout,

        /// Append logs to a file.
        /// Will seek to the end of the file before writing.
        /// File must be opened with read permissions as well to read the
        /// end of the file
        file: std.Io.File,

        /// Wrtie logs to a file.
        /// Will always start writing at the beginning of the file.
        /// File can be opened without read permissions.
        file_start: std.Io.File,

        /// Write logs to a writer.
        writer: *std.Io.Writer,
    };

    fn set_from_init(this: InitOptions, main_init: std.process.Init) InitOptions {
        var self = this;
        self.io = main_init.io;
        self.allocator = .{ .split = .{ .filter_arena = main_init.arena.allocator(), .parse_gpa = main_init.gpa } };
        self.environ = .{ .map = main_init.environ_map };

        return self;
    }

    fn set_from_minimal(this: InitOptions, main_minimal: std.process.Init.Minimal) InitOptions {
        var self = this;
        self.environ = .{ .minimal = main_minimal.environ };
        return self;
    }
};

/// Initialize the logger using the given options as well as the allocator and `Io`
/// instances from `main_init`.
///
/// This method needs to be called as early as possible, before any logging is done.
///
/// Calling this function should be followed by `defer` calling [`deinit`], otherwise
/// any logs at the end of main (e.g. in case of memory leaks) could segfault.
///
/// Panics if called more than once.
pub fn init(main_init: std.process.Init, opts: InitOptions) void {
    return initRaw(opts.set_from_init(main_init));
}

/// Initialize the logger using the given options as well as the environment from
/// the `main_init`.
///
/// This method needs to be called as early as possible, before any logging is done.
///
/// Calling this function should be followed by `defer` calling [`deinit`], otherwise
/// any logs at the end of main (e.g. in case of memory leaks) could segfault.
///
/// Panics if called more than once.
pub fn initMin(main_init: std.process.Init.Minimal, opts: InitOptions) void {
    return initRaw(opts.set_from_minimal(main_init));
}

/// Initialize the logger using the given options.
///
/// This method needs to be called as early as possible, before any logging is done.
///
/// Calling this function should be followed by `defer` calling [`deinit`], otherwise
/// any logs at the end of main (e.g. in case of memory leaks) could segfault.
///
/// Panics if called more than once.
pub fn initRaw(opts: InitOptions) void {
    return tryInitRaw(opts) catch @panic("Failed to initialize logger");
}

/// Initialize the logger using the given options as well as the allocator and `Io`
/// instances from `main_init`.
///
/// This method needs to be called as early as possible, before any logging is done.
///
/// Returns an error if called more than once.
pub fn tryInit(main_init: std.process.Init, opts: InitOptions) TryInitError!void {
    return tryInitRaw(opts.set_from_init(main_init));
}

/// Initialize the logger using the given options as well as the environment from
/// the `main_init`.
///
/// This method needs to be called as early as possible, before any logging is done.
///
/// Returns an error if called more than once.
pub fn tryInitMin(main_init: std.process.Init.Minimal, opts: InitOptions) TryInitError!void {
    return tryInitRaw(opts.set_from_minimal(main_init));
}

/// Initialize the logger using the given options.
///
/// This method needs to be called as early as possible, before any logging is done.
///
/// Returns an error if called more than once.
pub fn tryInitRaw(opts: InitOptions) TryInitError!void {
    const S = struct {
        var is_initialized: std.atomic.Value(bool) = .init(false);
    };

    if (S.is_initialized.cmpxchgStrong(false, true, .monotonic, .monotonic) != null) {
        return error.AlreadyInitialized;
    }

    try RtConfig.instance.init(opts);
}

pub const TryInitError = error{
    AlreadyInitialized,
    InvalidEnvValue,
    InvalidFilterValue,
} || std.Io.File.LengthError || std.Io.File.SeekError || std.Io.Writer.Error || std.mem.Allocator.Error;

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
    io: std.Io,
    filter_alloc: ?Alloc,
    filter: Filter,
    color_cfg: std.Io.Terminal.Mode,
    output: Out,
    render_level: bool,
    render_timestamp: bool,
    render_logger: bool,

    const Out = union(enum) {
        debug,
        stderr: std.Io.File.Writer,
        stdout: std.Io.File.Writer,
        file: std.Io.File.Writer,
        writer: *std.Io.Writer,
    };

    const Alloc = union(enum) {
        arena: std.heap.ArenaAllocator,
        alloc: std.mem.Allocator,
    };

    const minimal: RtConfig = .{
        .io = std.Options.debug_io,
        .filter_alloc = null,
        .filter = .all,
        .color_cfg = .no_color,
        .output = .debug,
        .render_level = true,
        .render_timestamp = false,
        .render_logger = true,
    };

    var instance: RtConfig = .minimal;
    var max_width: std.atomic.Value(usize) = .init(0);

    fn init(self: *RtConfig, opts: InitOptions) TryInitError!void {
        self.io = opts.io orelse std.Options.debug_io;
        const buffer = opts.write_buffer orelse try heap_buffer();

        self.filter_alloc = null;
        self.filter = .default;

        if (opts.filter) |init_filter| {
            if (init_filter == .filter) {
                self.filter = init_filter.filter;
            } else switch (opts.allocator) {
                .leaky => {
                    var parse_gpa: std.heap.DebugAllocator(.{}) = .init;
                    defer _ = parse_gpa.deinit();

                    var filter_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
                    self.filter_alloc = .{ .arena = filter_arena };
                    self.filter = try init_filter.intoFilter(parse_gpa.allocator(), filter_arena.allocator(), opts.environ);
                },
                .arena => |arena| {
                    self.filter_alloc = .{ .alloc = arena };
                    self.filter = try init_filter.intoFilter(arena, arena, opts.environ);
                },
                .split => |split| {
                    self.filter_alloc = .{ .alloc = split.filter_arena };
                    self.filter = try init_filter.intoFilter(split.parse_gpa, split.filter_arena, opts.environ);
                },
            }
        }

        self.output = switch (opts.output) {
            .stderr => for_stderr(self.io, buffer),
            .stdout => for_stdout(self.io, buffer),
            .file => |file| try for_file(self.io, buffer, file, true),
            .file_start => |file| try for_file(self.io, buffer, file, false),
            .writer => |writer| for_writer(writer),
        };

        self.color_cfg = switch (self.output) {
            .stderr, .stdout, .file => |file| try .detect(self.io, file.file, opts.enable_color == false, opts.force_color),
            .writer => .no_color,
            .debug => unreachable,
        };

        self.render_level = opts.render_level;
        self.render_timestamp = opts.render_timestamp;
        self.render_logger = opts.render_logger;
    }

    fn heap_buffer() ![]u8 {
        // using the page allocator seems fine here, since we want
        // to allocate a full page

        return std.heap.page_allocator.alloc(u8, std.heap.pageSize());
    }

    fn for_stderr(io: std.Io, buffer: []u8) Out {
        const file = std.Io.File.stderr();
        const writer = file.writer(io, buffer);
        return .{ .stderr = writer };
    }

    fn for_stdout(io: std.Io, buffer: []u8) Out {
        const file = std.Io.File.stdout();
        const writer = file.writer(io, buffer);
        return .{ .stdout = writer };
    }

    fn for_file(io: std.Io, buffer: []u8, file: std.Io.File, append: bool) !Out {
        const end = file.length(io) catch |err| switch (err) {
            error.AccessDenied => if (append) return err else 0,
            else => return err,
        };
        var writer = file.writer(io, buffer);
        try writer.seekTo(end);

        return .{ .file = writer };
    }

    fn for_writer(writer: *std.Io.Writer) Out {
        return .{ .writer = writer };
    }

    fn deinit(self: *RtConfig) void {
        if (self.filter_alloc) |*alloc| switch (alloc.*) {
            .arena => |*arena| {
                self.filter.deinit(arena.allocator());
                arena.deinit();
            },
            .alloc => |gpa| self.filter.deinit(gpa),
        };
        if (self.output == .file) {
            self.output.file.file.close(self.io);
        }
        self.* = .minimal;
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
        self: *RtConfig,
        comptime message_level: Filter.Level,
        comptime scope: @TypeOf(.enum_literal),
        comptime format: []const u8,
        args: anytype,
    ) void {
        const scope_name = comptime if (scope == .default) "" else @tagName(scope);
        if (self.filter.matches(scope_name, message_level) == false) return;

        const target = comptime if (scope == .default) "" else "(" ++ @tagName(scope) ++ ")";

        const term: std.Io.Terminal = term: switch (self.output) {
            .debug => std.debug.lockStderr(&.{}).terminal(),
            .stderr => |*file| {
                const io = self.io;
                const prev = io.swapCancelProtection(.blocked);
                defer _ = io.swapCancelProtection(prev);
                _ = io.lockStderr(&.{}, self.color_cfg) catch |err| switch (err) {
                    error.Canceled => unreachable, // Cancel protection enabled above.
                };
                break :term .{ .writer = &file.interface, .mode = self.color_cfg };
            },
            .stdout, .file => |*file| .{ .writer = &file.interface, .mode = self.color_cfg },
            .writer => |w| .{ .writer = w, .mode = self.color_cfg },
        };
        defer switch (self.output) {
            .stderr => self.io.unlockStderr(),
            .debug => std.debug.unlockStderr(),
            else => {},
        };

        self.logImpl(
            term,
            message_level,
            target,
            format,
            args,
        ) catch return;
    }

    fn logImpl(
        self: *const RtConfig,
        term: std.Io.Terminal,
        comptime message_level: Filter.Level,
        comptime target: []const u8,
        comptime format: []const u8,
        args: anytype,
    ) !void {
        if (self.render_timestamp) {
            const now = std.Io.Timestamp.now(self.io, .real);
            const nows = std.math.lossyCast(u64, now.toSeconds());

            const epoch_seconds = std.time.epoch.EpochSeconds{ .secs = nows };
            const epoch_day = epoch_seconds.getEpochDay();
            const day_seconds = epoch_seconds.getDaySeconds();
            const year_day = epoch_day.calculateYearDay();
            const month_day = year_day.calculateMonthDay();

            try term.writer.print(
                "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}.{d:0>3}Z ",
                .{
                    year_day.year,
                    month_day.month.numeric(),
                    month_day.day_index + 1,
                    day_seconds.getHoursIntoDay(),
                    day_seconds.getMinutesIntoHour(),
                    day_seconds.getSecondsIntoMinute(),
                    nows % std.time.ms_per_s,
                },
            );
        }

        if (self.render_level) {
            const color, const level = comptime switch (message_level) {
                .err => .{ .red, "ERROR" },
                .warn => .{ .yellow, "WARN " },
                .info => .{ .green, "INFO " },
                .debug => .{ .blue, "DEBUG" },
                .trace => .{ .magenta, "TRACE" },
            };

            try term.setColor(color);
            try term.writer.writeAll(level);
            try term.setColor(.reset);
            try term.writer.writeAll(" ");
        }

        if (self.render_logger) {
            const width = targetWidth(target.len);

            if (width > 0) {
                try term.setColor(.bold);
                try term.writer.print(
                    "{[target]s: >[width]}",
                    .{ .target = target, .width = width },
                );
                try term.setColor(.reset);
                try term.writer.writeAll(" ");
            }
        }

        try term.writer.print(format ++ "\n", args);
        try term.writer.flush();
    }

    inline fn targetWidth(comptime width: usize) usize {
        return @max(width, max_width.fetchMax(width, .monotonic));
    }
};
