const Terminal = @import("../terminal.zig").Terminal;
const ascii = @import("./ascii.zig");

/// Erases the entire screen.
pub fn eraseScreen(terminal: *const Terminal) !void {
    // we don't care about how many bytes were written
    _ = try terminal.write(&[_]u8{ ascii.ESC, '[', '2', 'J' });
}

pub fn eraseLine(terminal: *const Terminal) !void {
    _ = try terminal.write([]u8{ ascii.ESC, '[', '2', 'K' });
}
