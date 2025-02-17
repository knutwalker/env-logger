// SPDX-License-Identifier: MIT

const std = @import("std");
const env_logger = @import("env-logger");

pub const std_options = env_logger.setup(.{});

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var args = try std.process.argsWithAllocator(allocator);
    defer args.deinit();

    _ = args.next() orelse return; // skip the executable name

    const output_filename = args.next() orelse {
        std.debug.print("Usage: log_to_file $FILENAME\n", .{});
        std.process.exit(1);
    };

    var output: env_logger.InitOptions.Output = .stderr;
    var buf: ?std.ArrayList(u8) = null;
    defer if (buf) |b| b.deinit();

    if (std.mem.eql(u8, output_filename, "-")) {
        output = .stdout;
    } else if (std.mem.eql(u8, output_filename, "+")) {
        buf = .init(allocator);
        output = .{ .writer = buf.?.writer().any() };
    } else {
        const output_file = try std.fs.cwd().createFile(
            output_filename,
            // Set `truncate` to false to append to the file.
            .{ .truncate = false },
        );
        output = .{ .file = output_file };
    }

    env_logger.init(.{ .output = output });

    if (!env_logger.defaultLevelEnabled(.debug)) {
        std.debug.print("To see all log messages, run with `env ZIG_LOG=debug ...`\n", .{});
    }

    std.log.debug("debug message", .{});
    std.log.info("info message", .{});
    std.log.warn("warn message", .{});
    std.log.err("error message", .{});

    if (buf) |b| {
        std.debug.print("Contents of buffer:\n{s}\n", .{b.items});
    }
}
