const std = @import("std");

pub const Terminal = struct {
    const Self = @This();

    initialized: bool,
    old_termios: std.os.termios,
    new_termios: std.os.termios,
    tty: std.os.fd_t,
    winsize: std.os.linux.winsize,

    pub const Error = FetchTermDimensionsError || InitError;

    pub const InitError = std.os.OpenError || std.os.TermiosGetError || std.os.TermiosSetError || FetchTermDimensionsError;

    /// Initialize an undefined Terminal.
    pub fn init_undefined(terminal: *Self) InitError!void {
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

        // update terminal dimensions
        try terminal.fetch_term_dimensions();

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

    pub const FetchTermDimensionsError = error{
        /// Check `errno` for more information.
        IoctlError,
    };
    /// Updates the terminal dimensions.
    fn fetch_term_dimensions(self: *Self) FetchTermDimensionsError!void {
        var winsize: std.os.linux.winsize = undefined;
        const TIOCGWINSIZ: u16 = 0x5413;
        if (std.os.linux.ioctl(self.tty, TIOCGWINSIZ, @ptrToInt(&winsize)) < 0) {
            return error.FetchTermDimensionsError;
        }
        self.winsize = winsize;
    }

    /// Returns the number of columns in this Terminal.
    pub fn get_width(self: *const Self) u16 {
        return self.winsize.ws_col;
    }

    /// Returns the number of rows in this Terminal.
    pub fn get_height(self: *const Self) u16 {
        return self.winsize.ws_row;
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
