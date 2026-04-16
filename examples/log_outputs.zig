// SPDX-License-Identifier: MIT

const std = @import("std");

const env_logger = @import("env_logger");

pub const std_options = env_logger.setup(.{});

pub fn main(init: std.process.Init) !void {
    var args = try init.minimal.args.iterateAllocator(init.gpa);
    defer args.deinit();

    _ = args.next() orelse return; // skip the executable name

    var output: env_logger.InitOptions.Output = .stderr;
    var buf: ?std.Io.Writer.Allocating = null;
    defer if (buf) |*b| b.deinit();

    if (args.next()) |output_filename| {
        if (std.mem.eql(u8, output_filename, "-")) {
            output = .stdout;
        } else if (std.mem.eql(u8, output_filename, "+")) {
            buf = .init(init.gpa);
            output = .{ .writer = &buf.?.writer };
        } else {
            const output_file = try std.Io.Dir.cwd().createFile(
                init.io,
                output_filename,
                // To append to the log, set `truncate` to false and `read` to true.
                // Alternatively, use `file_start` to always write from the start
                //  and not require read permissions.
                .{ .read = true, .truncate = false },
            );
            output = .{ .file = output_file };
        }
    }

    env_logger.init(init, .{ .output = output });
    // deinit will close any eventual file handles
    defer env_logger.deinit();

    if (!env_logger.defaultLevelEnabled(.debug)) {
        std.debug.print("To see all log messages, run with `env ZIG_LOG=debug ...`\n", .{});
    }

    std.log.debug("debug message", .{});
    std.log.info("info message", .{});
    std.log.warn("warn message", .{});
    std.log.err("error message", .{});

    if (buf) |*b| {
        std.debug.print("Contents of buffer:\n{s}\n", .{b.written()});
    }
}
