const std = @import("std");
const Allocator = std.mem.Allocator;
const input = @import("input.zig");
const InputEvent = input.InputEvent;
const keymap = @import("keymap.zig");
const Keymaps = keymap.Keymaps;
const ActionContext = keymap.ActionContext;
const Terminal = @import("terminal.zig").Terminal;
const EventQueue = @import("event_queue.zig").EventQueue;
const Buffer = @import("Buffer.zig");
const Compositor = @import("compositor.zig").Compositor;
const Window = @import("compositor.zig").Window;

pub const Editor = struct {
    alloc: Allocator,
    buffers: std.ArrayList(Buffer),
    compositor: Compositor,
    mode: keymap.Mode = .normal,
    should_exit: bool = false,
    terminal: *Terminal,

    pub fn init(alloc: Allocator, terminal: *Terminal) Editor {
        return .{
            .alloc = alloc,
            .buffers = std.ArrayList(Buffer).init(alloc),
            .compositor = Compositor.init(alloc, .{
                .x = 0,
                .y = 0,
                .width = terminal.getWidth(),
                .height = terminal.getHeight(),
            }),
            .terminal = terminal,
        };
    }

    const OpenFileError = std.fs.File.OpenError || Allocator.Error;
    pub fn open_file(self: *Editor, file_path: []const u8, read_only: bool) OpenFileError!void {
        const buffer = try Buffer.init_from_file(self.alloc, file_path, read_only);
        try self.buffers.append(buffer);

        const keymaps = try keymap.build_keymaps(self.alloc);
        const settings = keymap.Settings{
            .key_timeout = 1000 * std.time.ns_per_ms,
        };

        const window_ptr = try self.alloc.create(Window);
        window_ptr.* = Window{
            .buffer = buffer.id,
            .focused = true,
            .action_ctx = try ActionContext.init(self.alloc, keymaps, settings, .normal),
        };

        const element = window_ptr.element();

        try self.compositor.push(element);
    }

    pub fn deinit(self: Editor) void {
        self.buffers.deinit();
    }

    pub fn loop(self: *Editor, input_event_queue: *EventQueue(InputEvent)) Allocator.Error!void {
        while (true) {
            while (input_event_queue.get()) |event| {
                self.mode = try self.compositor.handle_input(event) orelse self.mode;
            }

            try self.compositor.check_timeouts();

            if (self.should_exit) {
                break;
            }
        }

        // cleanup, save buffers, etc.
    }
};
