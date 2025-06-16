const std = @import("std");
const Allocator = std.mem.Allocator;
const posix = std.posix;
const TermInfo = @import("terminfo").TermInfo;
const Parameter = @import("terminfo").Strings.Parameter;
const input = @import("input.zig");
const Trie = @import("trie.zig").Trie;
const Capability = @import("terminfo").Strings.Capability;

pub const Terminal = struct {
    termios: Termios,

    tty: posix.fd_t,
    winsize: posix.winsize,

    terminfo: TermInfo,

    pub const Termios = struct {
        tty: posix.fd_t,
        cooked: posix.termios,
        raw: posix.termios,
        is_cooked: bool,

        pub const Error = posix.TermiosSetError || posix.TermiosGetError;

        pub fn init(tty: posix.fd_t) posix.TermiosGetError!Termios {
            const log = std.log.scoped(.termios_init);

            log.info("fetching current termios", .{});
            // get the current termios
            const old_termios = try posix.tcgetattr(tty);

            // save old (cooked) termios
            const cooked = old_termios;

            var new_termios = old_termios;

            // source for flag descriptions: https://www.gnu.org/software/libc/manual/html_node/Terminal-Modes.html

            // don't ignore break condition on input (a break condition is a sequence of >8 zero bits)
            new_termios.iflag.IGNBRK = false;
            // on break condition, pass it to application
            new_termios.iflag.BRKINT = false;
            // break condition is passed to application as '\0'
            new_termios.iflag.PARMRK = false;
            // don't strip input bytes to 7 bits
            new_termios.iflag.ISTRIP = false;
            // don't send LF as CR
            new_termios.iflag.INLCR = false;
            // don't discard CR
            new_termios.iflag.IGNCR = false;
            // don't send CR as NL
            new_termios.iflag.ICRNL = false;
            // disable C-S and C-Q as START and STOP characters
            new_termios.iflag.IXON = false;

            // send characters as-is
            new_termios.oflag.OPOST = false;

            // set byte size to 8 bits
            new_termios.cflag.CSIZE = .CS8;
            // don't generate parity bit
            new_termios.cflag.PARENB = false;

            // ECHO:   don't echo input back to terminal
            new_termios.lflag.ECHO = false;
            // ECHONL: don't echo NL if ICANON is set (redundant)
            new_termios.lflag.ECHONL = false;
            // ICANON: don't wait for LF to read input
            new_termios.lflag.ICANON = false;
            // ISIG:   ignore C-C, C-Z, C-\ (https://www.gnu.org/software/libc/manual/html_node/Signal-Characters.html)
            new_termios.lflag.ISIG = false;
            // IEXTEN: disable C-V on some systems (BSD, GNU/Linux, GNU/Herd)
            new_termios.lflag.IEXTEN = false;

            // timeout after 0 seconds so we don't block
            new_termios.cc[@intFromEnum(posix.V.TIME)] = 0;

            // just return 0 if no input was detected
            new_termios.cc[@intFromEnum(posix.V.MIN)] = 0;

            const raw = new_termios;

            return Termios{
                .tty = tty,
                .raw = raw,
                .cooked = cooked,
                .is_cooked = true,
            };
        }

        /// Restore the old termios.
        pub fn deinit(self: *Termios) posix.TermiosSetError!void {
            try self.makeCooked();
        }

        /// Enter raw mode.
        pub fn makeRaw(self: *Termios) posix.TermiosSetError!void {
            const log = std.log.scoped(.termios_makeRaw);

            // don't bother making raw terminal raw again
            if (!self.is_cooked) {
                log.debug("terminal is already raw", .{});
                return;
            }

            log.debug("make terminal raw", .{});
            try posix.tcsetattr(self.tty, posix.TCSA.FLUSH, self.raw);
            log.debug("success", .{});

            self.is_cooked = false;
        }

        // Enter cooked mode.
        pub fn makeCooked(self: *Termios) posix.TermiosSetError!void {
            const log = std.log.scoped(.termios_makeCooked);

            // don't bother making cooked terminal cooked again
            if (self.is_cooked) {
                log.debug("terminal is already cooked", .{});
                return;
            }

            log.debug("make terminal cooked", .{});
            try posix.tcsetattr(self.tty, posix.TCSA.FLUSH, self.cooked);
            log.debug("success", .{});

            self.is_cooked = true;
        }
    };

    pub const InitError = error{
        InvalidTerm,
    } || std.fs.File.OpenError || std.fs.File.WriteError || Termios.Error || FetchTermDimensionsError || TermInfo.InitFromEnvError;

    /// Create a new terminal.
    pub fn init(allocator: std.mem.Allocator) InitError!Terminal {
        const log = std.log.scoped(.terminal_init);

        var terminal: Terminal = undefined;

        log.info("loading terminfo", .{});
        terminal.terminfo = try TermInfo.initFromEnv(allocator);
        errdefer terminal.terminfo.deinit(allocator);
        log.info("done", .{});

        // open the TTY file
        log.info("opening /dev/tty", .{});
        const tty = try posix.open("/dev/tty", .{ .ACCMODE = .RDWR }, 0);
        terminal.tty = tty;
        log.info("done", .{});

        // close it on err
        errdefer posix.close(terminal.tty);

        // initialize termios
        log.info("init'ing termios", .{});
        terminal.termios = try Termios.init(tty);
        log.info("done", .{});

        // update terminal dimensions
        try terminal.fetchTermDimensions();

        terminal.exec(.keypad_xmit, true) catch {};

        return terminal;
    }

    pub const FetchTermDimensionsError = error{
        /// Check `errno` for more information.
        IoctlError,
    };
    /// Update the terminal dimensions.
    fn fetchTermDimensions(self: *Terminal) FetchTermDimensionsError!void {
        var winsize: posix.winsize = undefined;
        // this is not ideal, but I can't find this constant anywhere in the Zig
        // standard library and I'd rather not link against libc if I don't have
        // to
        const TIOCGWINSZ: u16 = 0x5413;
        if (std.os.linux.ioctl(self.tty, TIOCGWINSZ, @intFromPtr(&winsize)) < 0 or winsize.ws_col == 0) {
            return FetchTermDimensionsError.IoctlError;
        }
        self.winsize = winsize;
    }

    /// Returns the number of columns in this Terminal.
    pub fn getWidth(self: *const Terminal) u16 {
        return self.winsize.ws_col;
    }

    /// Returns the number of rows in this Terminal.
    pub fn getHeight(self: *const Terminal) u16 {
        return self.winsize.ws_row;
    }

    /// Reads input from the terminal into the given buffer.
    /// Returns a slice to the written data.
    pub fn getInput(self: *const Terminal, buf: []u8) std.fs.File.ReadError![]u8 {
        const len = try std.os.read(self.tty, buf);
        return buf[0..len];
    }

    /// Writes a sequence of bytes to TTY.
    pub fn write(self: *const Terminal, seq: []const u8) std.fs.File.WriteError!usize {
        return posix.write(self.tty, seq);
    }

    pub fn write_fmt(self: *const Terminal, comptime fmt: []const u8, args: anytype) std.fs.File.WriteError!void {
        const S = struct {
            pub fn write_fn(context: *const Terminal, bytes: []const u8) std.fs.File.WriteError!usize {
                return context.write(bytes);
            }
        };
        const writer = std.io.Writer(*const Terminal, std.fs.File.WriteError, S.write_fn){
            .context = self,
        };
        return try std.fmt.format(writer, fmt, args);
    }

    /// Deinitialize this terminal.
    /// This restores the previous termios.
    pub fn deinit(self: *Terminal, alloc: Allocator) void {
        self.termios.deinit() catch {
            std.log.warn("unable to restore cooked termios", .{});
        };

        self.exec(.keypad_local, true) catch {};

        self.terminfo.deinit(alloc);

        posix.close(self.tty);
    }

    pub const ExecError = error{FnUnavailableError} || std.fs.File.WriteError;

    /// Executes the given capability. Returns an error if the capability is
    /// unavailable or the TTY could not be written to.
    pub fn exec(self: *const Terminal, cap: Capability, comptime should_log: bool) ExecError!void {
        const log = std.log.scoped(.terminal_exec);

        if (should_log) {
            log.debug("exec({s})", .{@tagName(cap)});
        }

        const cap_val = self.terminfo.strings.get_value(cap) orelse return error.FnUnavailableError;

        if (cap == .clear_screen) {
            std.debug.assert(std.mem.eql(u8, cap_val, "\u{1b}[H\u{1b}[2J"));
        }

        _ = try self.write(cap_val);
    }

    pub const ExecWithArgsError = ExecError || std.mem.Allocator.Error || error{ InvalidFormat, InvalidArguments };
    pub fn exec_with_args(self: *const Terminal, alloc: std.mem.Allocator, cap: Capability, args: []const Parameter, comptime should_log: bool) ExecWithArgsError!void {
        const log = std.log.scoped(.terminal_exec_with_args);

        if (should_log) {
            log.debug("exec_with_args({s})", .{@tagName(cap)});
        }

        const seq = try self.terminfo.strings.get_value_with_args(alloc, cap, args) orelse return error.FnUnavailableError;
        defer alloc.free(seq);
        _ = try self.write(seq);
    }
};
