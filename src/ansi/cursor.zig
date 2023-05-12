const Terminal = @import("../terminal.zig").Terminal;
const std = @import("std");

/// Move the cursor to the top left.
pub fn moveCursorHome(term: *const Terminal) !void {
    _ = try term.write("\x1b[H");
}

/// Move the cursor to the given line and column.
pub fn moveCursor(term: *const Terminal, line: usize, column: usize) !void {
    var buf: [12]u8 = undefined;
    const slice = try std.fmt.bufPrint(&buf, "\x1b[{d};{d}H", .{ line, column });
    _ = try term.write(slice);
}
