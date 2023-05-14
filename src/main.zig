const std = @import("std");

const terminal = @import("terminal.zig");
const erase = @import("ansi/erase.zig");
const cursor = @import("ansi/cursor.zig");
const ascii = @import("ansi/ascii.zig");

pub fn main() !void {
    var term = try terminal.Terminal.init();
    defer term.deinit();

    // enter raw mode
    try term.termios.makeRaw();

    // clear screen
    try erase.eraseScreen(&term);

    // test
    try cursor.moveCursor(&term, 0, 0);

    var input_buf: [8]u8 = undefined;
    while (true) {
        const input = try term.getInput(&input_buf);

        if (input.len == 0) {
            continue;
        }

        if (input.len == 1 and input[0] == ascii.ESC) {
            // quit on ESC
            break;
        }

        try erase.eraseScreen(&term);
        try cursor.moveCursorHome(&term);

        for (input) |c| {
            var fmt_buf: [8]u8 = undefined;
            _ = try std.fmt.bufPrint(&fmt_buf, "0x{x}, ", .{c});
            _ = try term.write(&fmt_buf);
        }
    }
}
