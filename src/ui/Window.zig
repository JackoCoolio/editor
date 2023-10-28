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
const Position = @import("../Position.zig");
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

const Direction = enum { up, down, left, right };
fn move_cursor(self: *Window, buffer: ?*Buffer, comptime dir: Direction, n: u32) void {
    const scope = std.log.scoped(.move_cursor);

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
            const max_cursor_pos: u32 = @intCast(buffer_u.data.get_line_count() -| 1);
            self.cursor_pos.row = @min(self.cursor_pos.row +| n, max_cursor_pos);
        },
    }

    const line_len = buffer_u.data.get_line_length(self.cursor_pos.row) orelse unreachable;
    self.cursor_pos.col = @min(self.desired_col, @as(u32, @intCast(line_len)));

    var grid = &(self.grid orelse return);
    if (self.cursor_pos.row < self.scroll_offset) {
        // screen needs to scroll up
        self.set_scroll(self.cursor_pos.row);
    } else if (self.cursor_pos.row >= self.scroll_offset + grid.height) {
        // screen needs to scroll down
        self.set_scroll(self.cursor_pos.row - @as(u32, @intCast(grid.height)) + 1);
    }

    scope.info("current cursor location: ({}, {}), desired col: {}, scroll: {}", .{ self.cursor_pos.row, self.cursor_pos.col, self.desired_col, self.scroll_offset });
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
            if (buffer) |buffer_u| {
                const cursor_pos = self._get_cursor_pos();

                std.log.info("inserting at ({}, {})", .{ cursor_pos.row, cursor_pos.col });
                try buffer_u.data.dump_with_depth(0);

                try buffer_u.insert_bytes_at_position(cursor_pos, &bytes);
                self.move_cursor(buffer, .right, 1);
            }
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

fn _get_cursor_pos(self: *const Window) Position {
    return .{
        .row = self.cursor_pos.row - self.scroll_offset,
        .col = self.cursor_pos.col,
    };
}

fn get_cursor_pos(dyn: *anyopaque, ctx: Compositor.RenderContext) !?Position {
    _ = ctx;
    const self: *Window = @ptrCast(@alignCast(dyn));

    return self._get_cursor_pos();
}

fn get_grid(self: *const Window) ?*const Grid {
    return &(self.grid orelse return null);
}

fn get_visible_lines(self: *const Window, buffer: *const Buffer) [][]const u8 {
    const grid = &(self.grid orelse return null);
    return buffer.lines[self.scroll_offset..@min(self.scroll_offset + grid.height, buffer.lines.len)];
}

fn render(dyn: *anyopaque, ctx: Compositor.RenderContext) !?*const Grid {
    const self: *Window = @ptrCast(@alignCast(dyn));
    const grid = if (self.grid) |*grid| grid else return null;

    const buffer = ctx.editor.get_buffer(self.buffer) orelse return null;

    std.log.info("lines[{}..{}] (len {})", .{ self.scroll_offset, self.scroll_offset + grid.height, buffer.data.get_line_count() });
    var lines = try buffer.data.lines(self.alloc);
    defer lines.deinit();

    // TODO: make this more efficient
    // you should be able to start LineIter at line i, instead of just skipping
    // i lines
    for (0..self.scroll_offset) |_| {
        self.alloc.free(try lines.next() orelse break);
    }

    for (self.scroll_offset..@min(self.scroll_offset + grid.height, buffer.data.get_line_count())) |line_num| {
        // the parentheses probably aren't necessary here, but i think it makes
        // more sense with them
        const line = (try lines.next()) orelse break;
        defer self.alloc.free(line);

        var graphemes = Graphemes.from(line);
        const slice = try graphemes.into_slice(self.alloc);
        grid.set_row_clear_after(line_num - self.scroll_offset, slice);
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
