const std = @import("std");
const posix = std.posix;

const config = @import("config.zig");

var log_file_m: ?std.fs.File = null;
pub var highest_log_severity: u2 = level_to_severity(.debug);

pub fn level_to_severity(level: std.log.Level) u2 {
    return switch (level) {
        .debug => 0,
        .info => 1,
        .warn => 2,
        .err => 3,
    };
}

/// Opens a temporary log file.
fn open_tmp_file() ?std.fs.File {
    return std.fs.cwd().openFile("editor.log", std.fs.File.OpenFlags{ .mode = .read_write }) catch null;
}

/// Gets or opens the log file.
fn get_log_file() ?std.fs.File {
    if (log_file_m == null) {
        log_file_m = open_log_file();
    }
    return log_file_m;
}

/// Opens the log file for reading and writing.
fn open_cache_log_file() ?std.fs.File {
    var dir: std.fs.Dir = config.get_config_dir() orelse return null;
    defer posix.close(dir.fd);

    return dir.createFile("log", .{
        .read = true,
        .truncate = true,
    }) catch null;
}

fn open_log_file() ?std.fs.File {
    // try .cache file
    if (open_cache_log_file()) |file| {
        return file;
    }

    // try cwd tmp file
    if (open_tmp_file()) |file| {
        return file;
    }

    return null;
}

pub fn log_fn(comptime message_level: std.log.Level, comptime scope: @TypeOf(.EnumLiteral), comptime format: []const u8, args: anytype) void {
    const log_file = get_log_file() orelse std.debug.panic("no log file", .{});

    // keep track of highest log severity to inform user to check logs if needed
    highest_log_severity = @max(highest_log_severity, level_to_severity(message_level));

    const scope_str = @tagName(scope);

    var msg_buf: [1024]u8 = undefined;
    const msg_buf_s = std.fmt.bufPrint(&msg_buf, format, args) catch unreachable;

    var log_buf: [2048]u8 = undefined;
    const log_buf_s = std.fmt.bufPrint(&log_buf, "{s}:\t({s}): {s}\n", .{ message_level.asText(), scope_str, msg_buf_s }) catch unreachable;

    const writer = log_file.writer();
    _ = writer.write(log_buf_s) catch {};
}

pub fn close_log_file() void {
    if (log_file_m) |log_file| {
        log_file.sync() catch {};
        log_file.close();
    }
}
