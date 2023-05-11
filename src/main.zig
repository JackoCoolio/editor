const std = @import("std");

const terminal = @import("terminal.zig");
const erase = @import("ansi/erase.zig");
const cursor = @import("ansi/cursor.zig");

pub fn main() !void {
    var term = try terminal.Terminal.init();
    defer term.deinit();

    // test
    try cursor.move_cursor(&term, 0, 0);

    var buf: [8]u8 = undefined;
    @memset(&buf, 0);
    const read_len: usize = try term.get_input(&buf);
    var i: u8 = 0;
    while (i < read_len) : (i += 1) {
        std.log.info("{d} bytes", .{read_len});
        std.log.info("0x{x}", .{buf[i]});
    }
}
