const std = @import("std");

const terminal = @import("terminal.zig");
const erase = @import("ansi/erase.zig");
const cursor = @import("ansi/cursor.zig");
const ascii = @import("ansi/ascii.zig");
const input = @import("input.zig");
const Trie = @import("trie.zig").Trie;

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
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var term = try terminal.Terminal.init(allocator);
    defer term.deinit();

    std.debug.assert(term.terminfo.strings.getValue(.cursor_left) != null);

    var event_queue = try input.InputEventQueue.init(allocator);
    defer event_queue.deinit();

    const trie = try input.build_capabilities_trie(allocator, term.terminfo);
    defer trie.deinit();

    // enter raw mode
    try term.termios.makeRaw();
    errdefer term.termios.makeCooked() catch {};

    std.debug.assert(trie.lookup_longest(term.terminfo.strings.getValue(.cursor_left).?) != null);

    const handle = try std.Thread.spawn(.{}, input.input_thread_entry, .{ term.tty, trie, event_queue });
    handle.detach();

    var exit_message = FixedStringBuffer(1024).init();

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
                                try exit_message.append("encountered 'q'", .{});
                                break;
                            }

                            _ = try term.write(fmt_buf_s);
                        },
                        .Capability => |cap| {
                            if (cap == .key_backspace) {
                                break;
                            }

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

    // clear screen
    try erase.eraseScreen(&term);

    _ = try term.write(term.terminfo.strings.getValue(.cursor_home).?);

    // reset termios to cooked mode
    try term.termios.makeCooked();

    std.log.info("{s}", .{exit_message.get_buf()});
}

test {
    // test this file and all files that it or its children reference
    std.testing.refAllDeclsRecursive(@This());
}
