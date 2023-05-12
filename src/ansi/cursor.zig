const Terminal = @import("../terminal.zig").Terminal;
const std = @import("std");

pub fn moveCursorHome(term: *const Terminal) !void {
    _ = try term.write("\x1b[H");
}

fn formatBuf(buf: []u8, comptime fmt: []const u8, args: anytype) !u64 {
    var stream = std.io.FixedBufferStream([]u8){
        .buffer = buf,
        .pos = 0,
    };
    var writer = stream.writer();

    try std.fmt.format(writer, fmt, args);
    const pos = try stream.getPos();
    return pos;
}

pub fn moveCursor(term: *const Terminal, line: usize, column: usize) !void {
    var buf: [12]u8 = undefined;
    const len = try formatBuf(&buf, "\x1b[{d};{d}H", .{ line, column });
    _ = try term.write(buf[0..len]);
}
