const std = @import("std");
const TermInfo = @import("terminfo").TermInfo;
const Parameter = @import("terminfo").Strings.Parameter;
const input = @import("input.zig");
const Trie = @import("trie.zig").Trie;
const Capability = @import("terminfo").Strings.Capability;

pub const Terminal = struct {
    const Self = @This();

    termios: Termios,

    tty: std.os.fd_t,
    winsize: std.os.linux.winsize,

    terminfo: TermInfo,

    pub const Termios = struct {
        tty: std.os.fd_t,
        cooked: std.os.termios,
        raw: std.os.termios,
        is_cooked: bool,

        pub const Error = std.os.TermiosSetError || std.os.TermiosGetError;

        pub fn init(tty: std.os.fd_t) std.os.TermiosGetError!Termios {
            // get the current termios
            const old_termios = try std.os.tcgetattr(tty);

            // save old (cooked) termios
            const cooked = old_termios;

            var new_termios = old_termios;

            const flags = std.os.linux;

            // source for flag descriptions: https://www.gnu.org/software/libc/manual/html_node/Terminal-Modes.html

            // IGNBRK: don't ignore break condition on input (a break condition is a sequence of >8 zero bits)
            // BRKINT: on break condition, pass it to application
            // PARMRK: break condition is passed to application as '\0'
            // ISTRIP: don't strip input bytes to 7 bits
            // INLCR:  don't send LF as CR
            // IGNCR:  don't discard CR
            // ICRNL:  don't send CR as NL
            // IXON:   disable C-S and C-Q as START and STOP characters
            new_termios.iflag &= ~(flags.IGNBRK | flags.BRKINT | flags.PARMRK | flags.ISTRIP | flags.INLCR | flags.IGNCR | flags.ICRNL | flags.IXON);

            // OPOST:  send characters as-is
            new_termios.oflag &= ~(flags.OPOST);

            // CSIZE:  reset size bits to zero (https://stackoverflow.com/a/31999982)
            // PARENB: don't generate parity bit
            new_termios.cflag &= ~(flags.CSIZE | flags.PARENB);
            // CS8:    set byte size to 8 bits
            new_termios.cflag |= flags.CS8;

            // ECHO:   don't echo input back to terminal
            // ECHONL: don't echo NL if ICANON is set (redundant)
            // ICANON: don't wait for LF to read input
            // ISIG:   ignore C-C, C-Z, C-\ (https://www.gnu.org/software/libc/manual/html_node/Signal-Characters.html)
            // IEXTEN: disable C-V on some systems (BSD, GNU/Linux, GNU/Herd)
            new_termios.lflag &= ~(flags.ECHO | flags.ECHONL | flags.ICANON | flags.ISIG | flags.IEXTEN);

            // timeout after 0 seconds so we don't block
            new_termios.cc[flags.V.TIME] = 0;

            // just return 0 if no input was detected
            new_termios.cc[flags.V.MIN] = 0;

            const raw = new_termios;

            return Termios{
                .tty = tty,
                .raw = raw,
                .cooked = cooked,
                .is_cooked = true,
            };
        }

        /// Restore the old termios.
        pub fn deinit(self: *Termios) std.os.TermiosSetError!void {
            try self.makeCooked();
        }

        /// Enter raw mode.
        pub fn makeRaw(self: *Termios) std.os.TermiosSetError!void {
            // don't bother making raw terminal raw again
            if (!self.is_cooked) {
                return;
            }

            try std.os.tcsetattr(self.tty, std.os.linux.TCSA.FLUSH, self.raw);

            self.is_cooked = false;
        }

        // Enter cooked mode.
        pub fn makeCooked(self: *Termios) std.os.TermiosSetError!void {
            // don't bother making cooked terminal cooked again
            if (self.is_cooked) {
                return;
            }

            try std.os.tcsetattr(self.tty, std.os.linux.TCSA.FLUSH, self.cooked);

            self.is_cooked = true;
        }
    };

    pub const InitError = error{
        InvalidTerm,
    } || std.os.OpenError || std.os.WriteError || Termios.Error || FetchTermDimensionsError || TermInfo.InitFromEnvError;

    /// Create a new terminal.
    pub fn init(allocator: std.mem.Allocator) InitError!Self {
        var terminal: Self = undefined;

        terminal.terminfo = try TermInfo.initFromEnv(allocator);
        errdefer terminal.terminfo.deinit();

        // open the TTY file
        const tty = try std.os.open("/dev/tty", std.os.linux.O.RDWR, 0);
        terminal.tty = tty;

        // close it on err
        errdefer std.os.close(terminal.tty);

        // initialize termios
        terminal.termios = try Termios.init(tty);

        // update terminal dimensions
        try terminal.fetchTermDimensions();

        terminal.exec(.keypad_xmit) catch {};

        return terminal;
    }

    pub const FetchTermDimensionsError = error{
        /// Check `errno` for more information.
        IoctlError,
    };
    /// Update the terminal dimensions.
    fn fetchTermDimensions(self: *Self) FetchTermDimensionsError!void {
        var winsize: std.os.linux.winsize = undefined;
        // this is not ideal, but I can't find this constant anywhere in the Zig
        // standard library and I'd rather not link against libc if I don't have
        // to
        const TIOCGWINSZ: u16 = 0x5413;
        if (std.os.linux.ioctl(self.tty, TIOCGWINSZ, @ptrToInt(&winsize)) < 0 or winsize.ws_col == 0) {
            return FetchTermDimensionsError.IoctlError;
        }
        self.winsize = winsize;
    }

    /// Returns the number of columns in this Terminal.
    pub fn getWidth(self: *const Self) u16 {
        return self.winsize.ws_col;
    }

    /// Returns the number of rows in this Terminal.
    pub fn getHeight(self: *const Self) u16 {
        return self.winsize.ws_row;
    }

    /// Reads input from the terminal into the given buffer.
    /// Returns a slice to the written data.
    pub fn getInput(self: *const Self, buf: []u8) std.os.ReadError![]u8 {
        const len = try std.os.read(self.tty, buf);
        return buf[0..len];
    }

    /// Writes a sequence of bytes to TTY.
    pub fn write(self: *const Self, seq: []const u8) std.os.WriteError!usize {
        // TODO: check if correct number of bytes were written, and retry until successful?
        return std.os.write(self.tty, seq);
    }

    pub fn write_fmt(self: *const Self, comptime fmt: []const u8, args: anytype) std.os.WriteError!void {
        const S = struct {
            pub fn write_fn(context: *const Self, bytes: []const u8) std.os.WriteError!usize {
                return context.write(bytes);
            }
        };
        const writer = std.io.Writer(*const Self, std.os.WriteError, S.write_fn){
            .context = self,
        };
        return try std.fmt.format(writer, fmt, args);
    }

    /// Deinitialize this terminal.
    /// This restores the previous termios.
    pub fn deinit(self: *Self) void {
        self.termios.deinit() catch {
            std.log.warn("unable to restore cooked termios", .{});
        };

        self.exec(.keypad_local) catch {};

        self.terminfo.deinit();

        std.os.close(self.tty);
    }

    pub const ExecError = error{FnUnavailableError} || std.os.WriteError;

    /// Executes the given capability. Returns an error if the capability is
    /// unavailable or the TTY could not be written to.
    pub fn exec(self: *const Self, cap: Capability) ExecError!void {
        const cap_val = self.terminfo.strings.get_value(cap) orelse return error.FnUnavailableError;
        _ = try self.write(cap_val);
    }

    pub const ExecWithArgsError = ExecError || std.mem.Allocator.Error || error{ InvalidFormat, InvalidArguments };
    pub fn exec_with_args(self: *const Self, alloc: std.mem.Allocator, cap: Capability, args: []const Parameter) ExecWithArgsError!void {
        const seq = try self.terminfo.strings.get_value_with_args(alloc, cap, args) orelse return error.FnUnavailableError;
        // std.log.info("cap: {s}, seq: {s}", .{ @tagName(cap), std.fmt.fmtSliceEscapeLower(seq) });
        defer alloc.free(seq);
        _ = try self.write(seq);
    }
};
