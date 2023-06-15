const std = @import("std");

const terminal = @import("terminal.zig");
const input = @import("input.zig");
const Trie = @import("trie.zig").Trie;
const log = @import("log.zig");

pub const std_options = struct {
    pub const logFn = log.log_fn;
};

fn FixedStringBuffer(comptime N: usize) type {
    return struct {
        const Self = @This();

        buf: [N]u8,
        size: usize,

        pub fn init() Self {
            return Self{
                .buf = undefined,
                .size = 0,
            };
        }

        pub fn append(self: *Self, comptime fmt: []const u8, args: anytype) !void {
            var written = try std.fmt.bufPrint(self.buf[self.size..], fmt, args);
            self.size += written.len;
        }

        pub fn get_buf(self: *const Self) []const u8 {
            return self.buf[0..self.size];
        }
    };
}

pub fn main() !void {
    defer log.close_log_file();

    const init_log = std.log.scoped(.init);

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    init_log.info("initializing terminal", .{});
    var term = try terminal.Terminal.init(allocator);
    defer term.deinit();

    std.debug.assert(term.terminfo.strings.getValue(.cursor_left) != null);

    init_log.info("creating input event queue", .{});
    var event_queue = try input.InputEventQueue.init(allocator);
    defer event_queue.deinit();

    init_log.info("building capabilities trie", .{});
    const trie = try input.build_capabilities_trie(allocator, term.terminfo);
    defer trie.deinit();

    std.debug.assert(trie.lookup_longest(term.terminfo.strings.getValue(.cursor_left).?) != null);

    init_log.info("spawning input thread", .{});
    const handle = try std.Thread.spawn(.{}, input.input_thread_entry, .{ term.tty, trie, event_queue });
    handle.detach();

    var exit_message = FixedStringBuffer(1024).init();

    // enter raw mode
    init_log.info("entering raw mode", .{});
    try term.termios.makeRaw();
    errdefer term.termios.makeCooked() catch {};

    init_log.info("clearing screen", .{});
    try term.exec(.clear_screen);

    const input_log = std.log.scoped(.input_handling);
    // spinloop
    while (true) {
        if (event_queue.get()) |event| {
            switch (event) {
                .Key => |key_event| {
                    switch (key_event.key) {
                        .Regular => |reg| {
                            // bytes is 8 bytes max
                            var fmt_buf: [@sizeOf(@TypeOf(reg.bytes)) * 4]u8 = undefined;
                            const fmt_buf_s = try std.fmt.bufPrint(&fmt_buf, "{s}", .{std.fmt.fmtSliceEscapeLower(reg.bytes[0..reg.size])});

                            if (std.mem.eql(u8, fmt_buf_s, "q")) {
                                input_log.info("encountered 'q'. exiting editor", .{});
                                break;
                            }

                            if (std.mem.eql(u8, fmt_buf_s, "j")) {
                                try term.exec(.cursor_down);
                            } else if (std.mem.eql(u8, fmt_buf_s, "k")) {
                                try term.exec(.cursor_up);
                            } else if (std.mem.eql(u8, fmt_buf_s, "l")) {
                                try term.exec(.cursor_right);
                            } else if (std.mem.eql(u8, fmt_buf_s, "h")) {
                                try term.exec(.cursor_left);
                            } else {
                                _ = try term.write(fmt_buf_s);
                            }
                        },
                        .Capability => |cap| {
                            var fmt_buf: [64]u8 = undefined;
                            const fmt_buf_s = try std.fmt.bufPrint(&fmt_buf, "{s}", .{@tagName(cap)});
                            _ = try term.write(fmt_buf_s);
                        },
                    }
                },
                // unimplemented for now
                .Mouse => unreachable,
            }
        }
    }

    const cleanup_log = std.log.scoped(.cleanup);

    cleanup_log.info("resetting terminal and cursor position", .{});
    try term.exec(.clear_screen);
    try term.exec(.cursor_home);

    // reset termios to cooked mode
    try term.termios.makeCooked();

    if (exit_message.size > 0) {
        cleanup_log.info("logging exit message to stdout", .{});
        try exit_message.append("\n", .{});
        std.log.info("{s}", .{exit_message.get_buf()});
    }

    if (log.highest_log_severity >= comptime log.level_to_severity(.err)) {
        try exit_message.append("errors were logged while editor was running. check log file for more info.\n", .{});
    }

    _ = try std.io.getStdOut().writer().write(exit_message.get_buf());
}

test {
    // test this file and all files that it or its children reference
    std.testing.refAllDeclsRecursive(@This());
}
