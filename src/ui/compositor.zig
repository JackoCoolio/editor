const std = @import("std");
const Allocator = std.mem.Allocator;
const keymap = @import("../keymap.zig");
const ActionContext = keymap.ActionContext;
const ContextualAction = keymap.ContextualAction;
const Mode = keymap.Mode;
const Buffer = @import("../Buffer.zig");
const input = @import("../input.zig");
const InputEvent = input.InputEvent;
const Terminal = @import("../terminal.zig").Terminal;
const Editor = @import("../editor.zig").Editor;
const Grid = @import("Grid.zig");
const utf8 = @import("../utf8.zig");
const Graphemes = utf8.Graphemes;
const Parameter = @import("terminfo").Strings.Parameter;

pub const Dimensions = struct {
    width: u32,
    height: u32,
};

pub const Position = struct {
    row: u32,
    col: u32,
};

pub const Compositor = struct {
    alloc: Allocator,
    elements: std.ArrayList(Element),
    dimensions: Dimensions,
    grid: Grid,
    cursor_pos: Position,
    focused: ?usize,

    pub const Event = union(enum) {
        resize: struct {
            old: Dimensions,
            new: Dimensions,
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

    pub fn init(alloc: Allocator, dimensions: Dimensions) Allocator.Error!Compositor {
        return .{
            .alloc = alloc,
            .elements = std.ArrayList(Element).init(alloc),
            .dimensions = dimensions,
            .grid = try Grid.init(alloc, dimensions.width, dimensions.height),
            .cursor_pos = .{
                .row = 0,
                .col = 0,
            },
            .focused = null,
        };
    }

    pub fn focus(self: *Compositor, idx: usize) !void {
        var ctx = .{
            .should_exit = false,
        };
        if (self.focused) |old| {
            _ = try self.elements.items[old].handle_event(.focus_lost, &ctx);
        }
        self.focused = idx;

        _ = try self.elements.items[idx].handle_event(.focus_gained, &ctx);
    }

    pub fn push(self: *Compositor, element: Element) Allocator.Error!void {
        try self.elements.append(element);

        var event_ctx = .{ .should_exit = false };
        _ = element.handle_event(.{
            .resize = .{
                .old = .{
                    .width = self.dimensions.width,
                    .height = self.dimensions.height,
                },
                .new = .{
                    .width = self.dimensions.width,
                    .height = self.dimensions.height,
                },
            },
        }, &event_ctx) catch {
            std.log.info("element failed to handle resize event", .{});
        };

        if (self.focused == null) {
            self.focus(self.elements.items.len - 1) catch unreachable;
        }
    }

    pub fn pop(self: *Compositor) ?Element {
        if (self.elements.items.len == 0) {
            return null;
        }
        return self.elements.pop();
    }

    pub fn handle_input(self: *Compositor, event: InputEvent, editor: *Editor) Allocator.Error!?Mode {
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

            if (elt.handle_queued_actions(editor)) {
                const new_mode = elt.action_ctx.?.get_curr_mode();
                self.clear_all_input_queues(new_mode);
                return new_mode;
            }
        }

        return null;
    }

    fn get_cursor_pos(self: *const Compositor, ctx: RenderContext) !?Position {
        const focused = self.focused orelse return null;
        return try self.elements.items[focused].get_cursor_pos(ctx);
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

    pub const RenderContext = struct {
        editor: *const Editor,
    };

    fn compose(self: *Compositor, ctx: RenderContext) !bool {
        const elements: []Element = self.elements.items;
        const dirty = for (elements) |elt| {
            if (!elt.has_rendered or try elt.should_render(ctx)) {
                break true;
            }
        } else false;

        if (!dirty) {
            return false;
        }

        for (elements) |*elt| {
            if (try elt.render(ctx)) |grid| {
                elt.has_rendered = true;
                self.grid.compose(grid, elt.x, elt.y);
            }
        }

        return true;
    }

    pub fn render(self: *Compositor, terminal: *const Terminal, ctx: RenderContext) !void {
        const should_redraw = try self.compose(ctx);

        if (should_redraw) {
            // std.time.sleep(33 * std.time.ns_per_ms);
            try terminal.exec(.cursor_home);
            try terminal.exec(.cursor_invisible);
            for (0..self.grid.height) |row| {
                const bytes = self.grid.get_row_bytes(row);
                _ = try terminal.write(bytes);
                try terminal.exec(.clr_eol);
                if (row < self.grid.height - 1) {
                    try terminal.exec(.cursor_down);
                    try terminal.exec_with_args(self.alloc, .column_address, &[_]Parameter{.{ .integer = 0 }});
                }
            }
        }

        if (try self.get_cursor_pos(ctx)) |pos| {
            try terminal.exec_with_args(self.alloc, .cursor_address, &[_]Parameter{ .{ .integer = @intCast(pos.row) }, .{ .integer = @intCast(pos.col) } });
            try terminal.exec(.cursor_visible);
        }
    }
};

pub const EventContext = struct {
    should_exit: bool,
};

pub const Element = struct {
    ptr: *anyopaque,
    vtable: VTable,
    action_ctx: ?*keymap.ActionContext,
    x: i32,
    y: i32,
    has_rendered: bool = false,

    const VTable = struct {
        /// Handles the given input, returning `true` if an action is enqueued.
        handle_action: *const fn (*anyopaque, keymap.ContextualAction, *Editor) anyerror!void,
        handle_event: *const fn (*anyopaque, Compositor.Event, *EventContext) anyerror!Compositor.Event.Response,
        render: *const fn (*anyopaque, Compositor.RenderContext) anyerror!?*const Grid,
        should_render: *const fn (*anyopaque, Compositor.RenderContext) anyerror!bool,
        get_cursor_pos: *const fn (*anyopaque, Compositor.RenderContext) anyerror!?Position,
    };

    pub fn handle_action(self: *const Element, action: keymap.ContextualAction, editor: *Editor) !void {
        return try self.vtable.handle_action(self.ptr, action, editor);
    }

    pub fn handle_event(self: *const Element, event: Compositor.Event, event_ctx: *EventContext) !Compositor.Event.Response {
        return try self.vtable.handle_event(self.ptr, event, event_ctx);
    }

    pub fn render(self: *const Element, ctx: Compositor.RenderContext) !?*const Grid {
        return try self.vtable.render(self.ptr, ctx);
    }

    pub fn should_render(self: *const Element, ctx: Compositor.RenderContext) !bool {
        return try self.vtable.should_render(self.ptr, ctx);
    }

    pub fn get_cursor_pos(self: *const Element, ctx: Compositor.RenderContext) !?Position {
        return try self.vtable.get_cursor_pos(self.ptr, ctx);
    }

    /// Checks if the element has any queued actions. If so, tells the
    /// element to handle the actions, and then returns true.
    ///
    /// Otherwise, returns false.
    ///
    /// Assumes that the element has an ActionContext.
    pub fn handle_queued_actions(self: *Element, editor: *Editor) bool {
        const action_ctx = self.action_ctx orelse unreachable;
        const log = std.log.scoped(.element_handle_queued_actions);
        var handled = false;
        while (action_ctx.action_queue.get()) |action| {
            handled = true;

            self.handle_action(action, editor) catch |err| {
                log.err("UI element encountered error while handling action: {}", .{err});
            };
        }

        return handled;
    }
};
