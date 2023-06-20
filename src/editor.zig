const std = @import("std");
const Allocator = std.mem.Allocator;
const input = @import("input.zig");
const InputEvent = input.InputEvent;
const keymap = @import("keymap.zig");
const Keymaps = keymap.Keymaps;
const Terminal = @import("terminal.zig").Terminal;
const EventQueue = @import("event_queue.zig").EventQueue;

pub const Editor = struct {
    alloc: Allocator,
    buffers: std.ArrayList(Buffer),
    compositor: Compositor,
    mode: keymap.Mode = .normal,
    should_exit: bool = false,
    action_ctx: keymap.ActionContext,

    pub fn init(alloc: Allocator) Editor {
        return .{
            .alloc = alloc,
            .buffers = std.ArrayList(Buffer).init(alloc),
            .compositor = Compositor.init(alloc),
        };
    }

    pub fn deinit(self: Editor) void {
        self.buffers.deinit();
    }

    pub fn loop(self: *Editor, input_event_queue: EventQueue(InputEvent)) void {
        _ = self;
        while (true) {
            while (input_event_queue.get()) |event| {
                _ = event;

            }
        }
    }

    pub fn handle_input(self: *Editor, input_event: InputEvent) void {
        var ctx = EventContext{
            .mode = self.mode,
            .should_exit = false,
            .action_ctx = &self.action_ctx,
        };
        self.compositor.handle_event(Compositor.Event{
            .input = input_event,
        }, &ctx);

        self.should_exit |= ctx.should_exit;
    }
};

pub const Rect = struct {
    x: u32,
    y: u32,
    width: u32,
    height: u32,
};

pub const Compositor = struct {
    alloc: Allocator,
    elements: std.ArrayList(Element),
    dimensions: Rect,

    pub const Event = union(enum(u8)) {
        resize = struct {
            old: Rect,
            new: Rect,
        },
        input: input.InputEvent,
        focus_gained,
        focus_lost,

        pub const Response = enum(u1) {
            /// The event was consumed here and should not propagate down any
            /// farther.
            consumed,
            /// The event is allowed to continue propagating down.
            passed,
        };
    };

    pub fn init(alloc: Allocator, dimensions: Rect) Compositor {
        return .{
            .alloc = alloc,
            .elements = std.ArrayList(Element).init(alloc),
            .dimensions = dimensions,
        };
    }

    pub fn push(self: *Compositor, element: Element) Allocator.Error!void {
        try self.elements.append(element);
    }

    pub fn pop(self: *Compositor) ?Element {
        if (self.elements.items.len == 0) {
            return null;
        }
        return self.elements.pop();
    }

    pub fn handle_event(self: *Compositor, event: Event, event_ctx: *EventContext) void {
        // traverse the elements backwards, from front to back
        var i = self.elements.items.len;
        while (i > 0) {
            i -= 1;
            const elt = self.elements.items[i];

            switch (elt.handle_event(event, event_ctx)) {
                .consumed => break,
                else => {},
            }
        }
    }

    pub fn render(self: *Compositor, terminal: *const Terminal) void {
        _ = terminal;
        const elements: []const Element = self.elements.items;
        for (elements) |elt| {
            _ = elt;
            // elt.render(terminal);
        }
    }
};

pub const EventContext = struct {
    mode: keymap.Mode,
    should_exit: bool,
    action_ctx: *const keymap.ActionContext,
};

pub const Window = struct {
    buffer: Buffer.Id,
    focused: bool,
    cursor_pos: struct {
        row: u32,
        col: u32,
    } = .{ .row = 0, .col = 0 },

    pub fn element(self: *Window) Element {
        return Element{
            .ptr = self,
            .vtable = .{
                .handle_event = handle_event,
                // .render = render,
            },
        };
    }

    fn handle_event(dyn: *anyopaque, event: Compositor.Event, ctx: *EventContext) anyerror!Compositor.Event.Response {
        const self = @ptrCast(*Window, @alignCast(@alignOf(Window), dyn));

        switch (event) {
            .focus_gained => self.focused = true,
            .focus_lost => self.focused = false,
            .input => |input_ev| switch (input_ev) {
                .key => |key| {
                    ctx.mode = try self.action_ctx.handle_key(key, &ctx.mode);
                },
                .mouse => unreachable,
            },
        }

        while (self.action_ctx.action_queue.get()) |contextual_action| {
            const action = contextual_action[0];
            const mode = contextual_action[1];
            switch (action) {
                .up => self.cursor_pos.row -|= 1,
                .down => self.cursor_pos.row +|= 1,
                .left => self.cursor_pos.col -|= 1,
                .right => self.cursor_pos.col +|= 1,
                .tab => {
                    switch (mode) {
                        .insert => std.log.info("inserting tab character", .{}),
                        else => std.log.info("ignoring tab", .{}),
                    }
                },
                .backspace => {
                    switch (mode) {
                        .insert => std.log.info("backspacing a character", .{}),
                        else => std.log.info("ignoring BS", .{}),
                    }
                },
                .delete => {
                    switch (mode) {
                        .insert => std.log.info("deleting a character", .{}),
                        else => std.log.info("ignoring DEL", .{}),
                    }
                },
                .quit => {
                    ctx.should_exit = true;
                },
                .change_mode => unreachable,
                .insert_character => |bytes| {
                    std.log.info("inserting character '{s}'", .{@import("utf8.zig").recognize(bytes)});
                },
            }
        }

        return .consumed;
    }
};

pub const Split = union(enum(u8)) {
    vertical: struct {
        left: *Split,
        right: *Split,
    },
    horizontal: struct {
        top: *Split,
        bottom: *Split,
    },
    full: *Window,
};

pub const RootElement = struct {};

pub const Element = struct {
    ptr: *anyopaque,
    vtable: VTable,

    const VTable = struct {
        handle_event: *const fn (*anyopaque, Compositor.Event, *EventContext) anyerror!Compositor.Event.Response,
        render: *const fn (*anyopaque, *const Terminal) void,
    };

    pub fn handle_event(self: *const Element, event: Compositor.Event, event_ctx: *EventContext) !Compositor.Event.Response {
        return try self.vtable.handle_event(self.ptr, event, event_ctx);
    }

    pub fn render(self: *const Element, terminal: *const Terminal) void {
        return self.vtable.render(self.ptr, terminal);
    }
};

pub const Buffer = struct {
    alloc: std.mem.Allocator,
    data: []u8,
    save_location: ?[]const u8,
    id: Id,
    dirty: bool,

    pub const Id = u32;

    var next_id: Id = 0;

    fn get_id() Id {
        defer next_id += 1;
        return next_id;
    }

    pub const SaveError = std.fs.File.OpenError || std.fs.File.WriteError;
    /// Saves the buffer if not read-only. Returns the number of bytes that were
    /// written if write-enabled.
    pub fn save(self: *const Buffer, force: bool) SaveError!?usize {
        if (!self.dirty and !force) {
            return null;
        }
        const save_location = self.save_location orelse return null;
        return self.save_to(save_location);
    }

    /// Saves the buffer to the given location. Returns the number of bytes that were
    /// written if write-enabled.
    pub fn save_to(self: *const Buffer, save_location: []const u8) SaveError!usize {
        const flags = std.fs.File.OpenFlags{
            .mode = std.fs.File.OpenMode.write_only,
        };

        const file = try std.fs.openFileAbsolute(save_location, flags);
        defer {
            file.sync() catch {};
            file.close();
        }

        return try file.write(self.data);
    }

    /// Initializes a Buffer from the given file path.
    pub fn init_from_file(alloc: Allocator, file_path: []const u8, read_only: bool) std.fs.File.OpenError!Buffer {
        const flags = .{
            .mode = .read_only,
        };

        const file = try std.fs.openFileAbsolute(file_path, flags);

        const data = file.readToEndAlloc(alloc, std.math.maxInt(usize)) catch unreachable;
        return Buffer.init_from_data(alloc, data, if (read_only) null else file_path);
    }

    /// Initializes a Buffer from `data`. The data must be managed by the given
    /// allocator.
    pub fn init_from_data(alloc: Allocator, data: []const u8, save_location: ?[]const u8) Buffer {
        return .{
            .alloc = alloc,
            .data = data,
            .save_location = save_location,
            .id = get_id(),
            .dirty = false,
        };
    }
};
