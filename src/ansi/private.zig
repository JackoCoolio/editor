const Terminal = @import("../terminal.zig").Terminal;
const ascii = @import("ascii.zig");
const std = @import("std");

// Note: these are not part of the ANSI standard, and as a result, some of them
// might not be supported.

pub fn save_screen(term: *const Terminal) !void {
    _ = try term.write([_]u8{ascii.ESC} ++ "[?47h");
}

pub fn restore_screen(term: *const Terminal) !void {
    _ = try term.write([_]u8{ascii.ESC} ++ "[?47l");
}
