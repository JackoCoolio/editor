const std = @import("std");
const Allocator = std.mem.Allocator;
const keymap = @import("keymap.zig");
const ActionContext = keymap.ActionContext;
const ContextualAction = keymap.ContextualAction;
const Mode = keymap.Mode;
const Buffer = @import("Buffer.zig");
const input = @import("input.zig");
const InputEvent = input.InputEvent;
const Terminal = @import("terminal.zig").Terminal;

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

    pub const Event = union(enum) {
        resize: struct {
            old: Rect,
            new: Rect,
        },
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

    pub fn handle_input(self: *Compositor, event: InputEvent) Allocator.Error!?Mode {
        // iterate thru the elements, top-down, propagating the input event
        var i = self.elements.items.len;
        while (i > 0) {
            i -= 1;

            const elt: *Element = &self.elements.items[i];
            const action_ctx = elt.action_ctx orelse continue;

            switch (event) {
                .key => |key| {
                    try action_ctx.handle_key(key);
                },
                .mouse => unreachable,
            }

            if (elt.handle_queued_actions()) {
                const new_mode = elt.action_ctx.?.get_curr_mode();
                self.clear_all_input_queues(new_mode);
                return new_mode;
            }
        }

        return null;
    }

    pub fn check_timeouts(self: *Compositor) Allocator.Error!void {
        for (self.elements.items) |elt| {
            const action_ctx = elt.action_ctx orelse continue;
            try action_ctx.check_timeout();
        }
    }

    fn clear_all_input_queues(self: *Compositor, mode: Mode) void {
        for (self.elements.items) |elt| {
            const action_ctx: *keymap.ActionContext = elt.action_ctx orelse continue;
            action_ctx.reset(mode);
        }
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
    should_exit: bool,
};

pub const Window = struct {
    buffer: Buffer.Id,
    focused: bool,
    cursor_pos: struct {
        row: u32,
        col: u32,
    } = .{ .row = 0, .col = 0 },
    action_ctx: ActionContext,

    pub fn element(self: *Window) Element {
        return Element{
            .ptr = self,
            .action_ctx = &self.action_ctx,
            .vtable = .{
                .handle_event = handle_event,
                .handle_action = handle_action,
            },
        };
    }

    fn handle_action(dyn: *anyopaque, contextual_action: ContextualAction) anyerror!void {
        const log = std.log.scoped(.window_handle_action);

        const self = @ptrCast(*Window, @alignCast(@alignOf(Window), dyn));

        const action = contextual_action.action;
        const mode = contextual_action.mode;
        switch (action) {
            .up => {
                self.cursor_pos.row -|= 1;
                log.info("moving cursor up", .{});
            },
            .down => {
                self.cursor_pos.row +|= 1;
                log.info("moving cursor down", .{});
            },
            .left => {
                self.cursor_pos.col -|= 1;
                log.info("moving cursor left", .{});
            },
            .right => {
                self.cursor_pos.col +|= 1;
                log.info("moving cursor right", .{});
            },
            .tab => {
                switch (mode) {
                    .insert => log.info("inserting tab character", .{}),
                    else => log.info("ignoring tab", .{}),
                }
            },
            .backspace => {
                switch (mode) {
                    .insert => log.info("backspacing a character", .{}),
                    else => log.info("ignoring BS", .{}),
                }
            },
            .delete => {
                switch (mode) {
                    .insert => log.info("deleting a character", .{}),
                    else => log.info("ignoring DEL", .{}),
                }
            },
            .quit => {
                log.info("quitting", .{});
                std.process.exit(0);
            },
            .change_mode => |new_mode| {
                log.info("changing mode to {s}", .{@tagName(new_mode)});
            },
            .insert_bytes => |bytes| {
                log.info("inserting character '{s}'", .{@import("utf8.zig").recognize(&bytes)});
            },
        }
    }

    fn handle_event(dyn: *anyopaque, event: Compositor.Event, _: *EventContext) anyerror!Compositor.Event.Response {
        const self = @ptrCast(*Window, @alignCast(@alignOf(Window), dyn));

        switch (event) {
            .focus_gained => self.focused = true,
            .focus_lost => self.focused = false,
            else => unreachable,
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
    action_ctx: ?*keymap.ActionContext,
    vtable: VTable,

    const VTable = struct {
        /// Handles the given input, returning `true` if an action is enqueued.
        handle_action: *const fn (*anyopaque, keymap.ContextualAction) anyerror!void,
        handle_event: *const fn (*anyopaque, Compositor.Event, *EventContext) anyerror!Compositor.Event.Response,
        // render: *const fn (*anyopaque, *const Terminal) void,
    };

    pub fn handle_action(self: *const Element, action: keymap.ContextualAction) !void {
        return try self.vtable.handle_action(self.ptr, action);
    }

    pub fn handle_event(self: *const Element, event: Compositor.Event, event_ctx: *EventContext) !Compositor.Event.Response {
        return try self.vtable.handle_event(self.ptr, event, event_ctx);
    }

    // pub fn render(self: *const Element, terminal: *const Terminal) void {
    //     return self.vtable.render(self.ptr, terminal);
    // }

    /// Checks if the element has any queued actions. If so, tells the
    /// element to handle the actions, and then returns true.
    ///
    /// Otherwise, returns false.
    ///
    /// Assumes that the element has an ActionContext.
    pub fn handle_queued_actions(self: *Element) bool {
        const action_ctx = self.action_ctx orelse unreachable;
        const log = std.log.scoped(.element_handle_queued_actions);
        var handled = false;
        while (action_ctx.action_queue.get()) |action| {
            handled = true;

            self.handle_action(action) catch |err| {
                log.err("UI element encountered error while handling action: {}", .{err});
            };
        }

        return handled;
    }
};
