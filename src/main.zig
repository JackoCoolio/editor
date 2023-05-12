const std = @import("std");

const terminal = @import("terminal.zig");
const erase = @import("ansi/erase.zig");
const cursor = @import("ansi/cursor.zig");
const ascii = @import("ansi/ascii.zig");

pub fn main() !void {
    var term = try terminal.Terminal.init();
    defer term.deinit();

    // enter raw mode
    try term.makeRaw();

    // clear screen
    try erase.eraseScreen(&term);

    // test
    try cursor.moveCursor(&term, 0, 0);

    var buf: [8]u8 = undefined;
    while (true) {
        const read_len: usize = try term.getInput(&buf);
        if (read_len == 0) {
            continue;
        }

        if (read_len == 1 and buf[0] == ascii.ESC) {
            // quit on ESC
            break;
        }
    }
}
