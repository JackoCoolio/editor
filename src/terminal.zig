const std = @import("std");

pub const Terminal = struct {
    const Self = @This();

    initialized: bool,
    old_termios: std.os.termios,
    new_termios: std.os.termios,
    tty: std.os.fd_t,

    /// Initialize an undefined Terminal.
    pub fn init_undefined(terminal: *Self) !void {
        // ensure that we don't double initialize
        std.debug.assert(!terminal.initialized);

        terminal.initialized = false;

        // open the TTY file
        const tty = try std.os.open("/dev/tty", std.os.linux.O.RDWR, 0);
        terminal.tty = tty;

        // close it on err
        errdefer std.os.close(terminal.tty);

        // get the current termios
        const old_termios = try std.os.tcgetattr(terminal.tty);
        terminal.old_termios = old_termios;
        // zig copies this
        var new_termios = old_termios;

        const flags = std.os.linux;
        // disable LF buffer and input echo
        new_termios.lflag &= ~(flags.ICANON | flags.ECHO);

        try std.os.tcsetattr(tty, flags.TCSA.NOW, new_termios);
        terminal.new_termios = new_termios;

        // mark as initialized, so we don't accidentally init again
        terminal.initialized = true;
    }

    /// Create a new terminal.
    pub fn init() !Self {
        var term: Self = undefined;
        try term.init_undefined();
        return term;
    }

    /// Create a new terminal with the given Allocator.
    pub fn initAlloc(alloc: std.mem.Allocator) !*Self {
        var term: *Self = alloc.create(Self);
        try term.init_undefined();
        return term;
    }

    pub fn get_input(self: *const Self, buf: []u8) std.os.ReadError!usize {
        std.log.info("tty is: {}", .{self.tty});
        return std.os.read(self.tty, buf);
    }

    /// Writes a sequence of bytes to TTY.
    pub fn write(self: *const Self, seq: []const u8) std.os.WriteError!usize {
        // TODO: check if correct number of bytes were written, and retry until successful?
        return std.os.write(self.tty, seq);
    }

    /// Deinitialize this terminal.
    /// This restores the previous termios.
    pub fn deinit(self: *Self) void {
        // restore old termios
        std.os.tcsetattr(self.tty, std.os.linux.TCSA.NOW, self.old_termios) catch {
            std.log.warn("unable to restore old termios", .{});
        };

        std.os.close(self.tty);

        self.initialized = false;
    }
};
