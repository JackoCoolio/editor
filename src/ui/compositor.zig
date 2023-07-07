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
                if (row < self.grid.height - 1) {
                    try terminal.exec(.cursor_down);
                    try terminal.exec_with_args(self.alloc, .column_address, &[_]Parameter{.{ .integer = 0 }});
                }
            }
        }

        if (try self.get_cursor_pos(ctx)) |pos| {
            try terminal.exec_with_args(self.alloc, .cursor_address, &[_]Parameter{ .{ .integer = @intCast(i32, pos.row) }, .{ .integer = @intCast(i32, pos.col) } });
            try terminal.exec(.cursor_visible);
        }
    }
};

pub const EventContext = struct {
    should_exit: bool,
};

pub const Window = struct {
    alloc: Allocator,
    buffer: Buffer.Id,
    focused: bool,
    cursor_pos: struct {
        row: u32,
        col: u32,
    } = .{ .row = 0, .col = 0 },
    desired_col: u32 = 0,
    action_ctx: ActionContext,
    grid: ?Grid,

    pub fn element(self: *Window) Element {
        return Element{
            .ptr = self,
            .vtable = .{
                .handle_event = handle_event,
                .handle_action = handle_action,
                .should_render = should_render,
                .render = render,
                .get_cursor_pos = get_cursor_pos,
            },
            .action_ctx = &self.action_ctx,
            .x = 0,
            .y = 0,
        };
    }

    const Direction = enum { up, down, left, right };
    fn move_cursor(self: *Window, buffer: ?*Buffer, comptime dir: Direction, n: u32) void {
        const buffer_u = buffer orelse return;
        switch (dir) {
            .left => {
                self.desired_col = self.cursor_pos.col -| 1;
            },
            .right => {
                self.desired_col = self.cursor_pos.col +| 1;
            },
            .up => {
                self.cursor_pos.row -|= n;
            },
            .down => {
                self.cursor_pos.row = @min(self.cursor_pos.row +| n, @intCast(u32, buffer_u.lines.len - 1));
            },
        }
        const line_len = buffer_u.lines[self.cursor_pos.row].len;
        self.cursor_pos.col = @min(self.desired_col, @intCast(u32, line_len));
    }

    fn handle_action(dyn: *anyopaque, contextual_action: ContextualAction, editor: *Editor) anyerror!void {
        const log = std.log.scoped(.window_handle_action);

        const self = @ptrCast(*Window, @alignCast(@alignOf(Window), dyn));

        var buffer = editor.get_buffer(self.buffer);

        const action = contextual_action.action;
        const mode = contextual_action.mode;
        switch (action) {
            .up => {
                self.move_cursor(buffer, .up, 1);
                log.info("moving cursor up", .{});
            },
            .down => {
                self.move_cursor(buffer, .down, 1);
                log.info("moving cursor down", .{});
            },
            .left => {
                self.move_cursor(buffer, .left, 1);
                log.info("moving cursor left", .{});
            },
            .right => {
                self.move_cursor(buffer, .right, 1);
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
            .resize => |change| {
                if (self.grid) |*grid| {
                    grid.deinit();
                }

                self.grid = try Grid.init(self.alloc, change.new.width, change.new.height);
            },
        }

        return .consumed;
    }

    fn should_render(dyn: *anyopaque, ctx: Compositor.RenderContext) !bool {
        const self = @ptrCast(*Window, @alignCast(@alignOf(Window), dyn));
        const buffer = ctx.editor.get_buffer(self.buffer) orelse return false;

        return buffer.dirty;
    }

    fn get_cursor_pos(dyn: *anyopaque, ctx: Compositor.RenderContext) !?Position {
        _ = ctx;
        const self = @ptrCast(*Window, @alignCast(@alignOf(Window), dyn));

        return .{
            .row = self.cursor_pos.row,
            .col = self.cursor_pos.col,
        };
    }

    fn render(dyn: *anyopaque, ctx: Compositor.RenderContext) !?*const Grid {
        const self = @ptrCast(*Window, @alignCast(@alignOf(Window), dyn));
        const grid = if (self.grid) |*grid| grid else return null;

        const buffer = ctx.editor.get_buffer(self.buffer) orelse return null;

        var lines = buffer.lines;

        for (lines, 0..) |line, line_num| {
            var graphemes = Graphemes.from(line);
            const slice = try graphemes.into_slice(self.alloc);
            // FIXME: this slice will overflow if line is too long
            grid.set_row_clear_after(line_num, slice);
        }

        return grid;
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
