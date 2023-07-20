const Window = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;

const Buffer = @import("../Buffer.zig");
const keymap = @import("../keymap.zig");
const ActionContext = keymap.ActionContext;
const ContextualAction = keymap.ContextualAction;
const Grid = @import("Grid.zig");
const Compositor = @import("compositor.zig").Compositor;
const Element = @import("compositor.zig").Element;
const EventContext = @import("compositor.zig").EventContext;
const Position = @import("compositor.zig").Position;
const Editor = @import("../editor.zig").Editor;
const utf8 = @import("../utf8.zig");
const Graphemes = utf8.Graphemes;

alloc: Allocator,
buffer: Buffer.Id,
scroll_offset: u32 = 0,
scroll_changed: bool = false,
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

fn get_max_cursor_pos(buffer: *const Buffer) u32 {
    return @as(u32, @intCast(buffer.lines.len)) -| 1;
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
            // ensure that cursor pos doesn't exceed buffer length
            self.cursor_pos.row = @min(self.cursor_pos.row +| n, get_max_cursor_pos(buffer_u));
        },
    }

    const line_len = buffer_u.lines[self.cursor_pos.row].len;
    self.cursor_pos.col = @min(self.desired_col, @as(u32, @intCast(line_len)));

    var grid = &(self.grid orelse return);
    if (self.cursor_pos.row < self.scroll_offset) {
        // screen needs to scroll down
        self.set_scroll(self.cursor_pos.row);
    } else if (self.cursor_pos.row > self.scroll_offset + grid.height) {
        // screen needs to scroll up
        self.set_scroll(self.cursor_pos.row - @as(u32, @intCast(grid.height)));
    }
    std.log.info("scroll_offset = {}", .{self.scroll_offset});
}

fn set_scroll(self: *Window, scroll: u32) void {
    if (self.scroll_offset == scroll) {
        return;
    }

    self.scroll_offset = scroll;
    self.scroll_changed = true;
}

fn handle_action(dyn: *anyopaque, contextual_action: ContextualAction, editor: *Editor) anyerror!void {
    const log = std.log.scoped(.window_handle_action);

    const self: *Window = @ptrCast(@alignCast(dyn));

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
            log.info("inserting character '{s}'", .{utf8.recognize(&bytes)});
        },
    }
}

fn handle_event(dyn: *anyopaque, event: Compositor.Event, _: *EventContext) anyerror!Compositor.Event.Response {
    const self: *Window = @ptrCast(@alignCast(dyn));

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
    const self: *Window = @ptrCast(@alignCast(dyn));
    const buffer = ctx.editor.get_buffer(self.buffer) orelse return false;

    const should = buffer.dirty or self.scroll_changed;

    buffer.dirty = false;
    self.scroll_changed = false;

    return should;
}

fn get_cursor_pos(dyn: *anyopaque, ctx: Compositor.RenderContext) !?Position {
    _ = ctx;
    const self: *Window = @ptrCast(@alignCast(dyn));

    return .{
        .row = self.cursor_pos.row - self.scroll_offset,
        .col = self.cursor_pos.col,
    };
}

fn render(dyn: *anyopaque, ctx: Compositor.RenderContext) !?*const Grid {
    const self: *Window = @ptrCast(@alignCast(dyn));
    const grid = if (self.grid) |*grid| grid else return null;

    const buffer = ctx.editor.get_buffer(self.buffer) orelse return null;

    std.log.info("lines[{}..{}] (len {})", .{ self.scroll_offset, self.scroll_offset + grid.height, buffer.lines.len });
    var lines = buffer.lines[self.scroll_offset..@min(self.scroll_offset + grid.height, buffer.lines.len)];

    for (lines, 0..) |line, line_num| {
        var graphemes = Graphemes.from(line);
        const slice = try graphemes.into_slice(self.alloc);
        // FIXME: this slice will overflow if line is too long
        grid.set_row_clear_after(line_num, slice);
    }

    return grid;
}

pub const Group = struct {
    orientation: Orientation,
    windows: []Window,

    pub const Orientation = enum(u1) {
        vertical,
        horizontal,
    };
};
