const std = @import("std");

const Terminal = @import("terminal.zig").Terminal;
const input = @import("input.zig");
const InputEvent = input.InputEvent;
const log = @import("log.zig");
const utf8 = @import("utf8.zig");
const EventQueue = @import("event_queue.zig").EventQueue;
const keymap = @import("keymap.zig");
const Editor = @import("editor.zig").Editor;

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
            const written = try std.fmt.bufPrint(self.buf[self.size..], fmt, args);
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

    const args = try std.process.argsAlloc(allocator);
    if (args.len < 2) {
        const stderr_file = std.io.getStdErr().writer();
        var bw = std.io.bufferedWriter(stderr_file);
        const stderr = bw.writer();
        try stderr.print("usage: editor <filename>\n", .{});
        try bw.flush();
        return;
    }

    const filename: [:0]u8 = args[1];

    init_log.info("initializing terminal", .{});
    var terminal = try Terminal.init(allocator);
    defer terminal.deinit();

    init_log.info("creating input event queue", .{});
    var input_event_queue = try EventQueue(InputEvent).init(allocator);
    defer input_event_queue.deinit();

    init_log.info("building capabilities trie", .{});
    const trie = try input.build_capabilities_trie(allocator, terminal.terminfo);
    defer trie.deinit();

    init_log.info("spawning input thread", .{});
    const handle = try std.Thread.spawn(.{}, input.input_thread_entry, .{ terminal.tty, trie, input_event_queue });
    handle.detach();

    init_log.info("creating editor and starting compositor", .{});
    var editor = try Editor.init(allocator, &terminal);
    try editor.open_file(filename, true);

    var exit_message = FixedStringBuffer(1024).init();

    // enter raw mode
    init_log.info("entering raw mode", .{});
    try terminal.termios.makeRaw();
    errdefer terminal.termios.makeCooked() catch {};

    init_log.info("clearing screen", .{});
    try terminal.exec(.clear_screen);

    {
        // main loop
        try editor.loop(&input_event_queue);
        // after this point, the editor is exiting
    }

    const cleanup_log = std.log.scoped(.cleanup);

    cleanup_log.info("resetting terminal and cursor position", .{});
    try terminal.exec(.clear_screen);
    try terminal.exec(.cursor_home);

    // reset termios to cooked mode
    try terminal.termios.makeCooked();

    if (exit_message.size > 0) {
        cleanup_log.info("logging exit message to stdout", .{});
        try exit_message.append("\n", .{});
        std.log.info("{s}", .{exit_message.get_buf()});
    }

    cleanup_log.info("done", .{});

    if (log.highest_log_severity >= comptime log.level_to_severity(.err)) {
        try exit_message.append("errors were logged while editor was running. check log file for more info.\n", .{});
    }

    _ = try std.io.getStdOut().writer().write(exit_message.get_buf());
}

test {
    // test this file and all files that it or its children reference
    std.testing.refAllDeclsRecursive(@This());
}
