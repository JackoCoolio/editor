const std = @import("std");
const Terminal = @import("terminal.zig").Terminal;

pub const Compositor = struct {
    const List = std.ArrayList(Element);

    elements: List,
    area: Rect,

    allocator: std.mem.Allocator,
    terminal: Terminal,

    pub fn init(alloc: std.mem.Allocator, terminal: Terminal) Compositor {
        return Compositor{
            .elements = List.init(alloc),
            .terminal = terminal,
            .area = Rect.from_terminal(&terminal),
        };
    }

    /// Adds a new element to the compositor.
    pub fn add_element(self: *Compositor, element: Element) std.mem.Allocator.Error!void {
        self.elements.append(element);
    }

    pub fn render(self: *Compositor) void {
        const items: []const Element = self.elements.items;
        for (items) |elt| {
            elt.render();
        }
    }
};

pub const Rect = struct {
    x: u16,
    y: u16,
    width: u16,
    height: u16,

    pub fn from_terminal(terminal: *const Terminal) Rect {
        return .{
            .x = 0,
            .y = 0,
            .width = terminal.getWidth(),
            .height = terminal.getHeight(),
        };
    }

    /// Returns the left-most extent of the Rect.
    pub inline fn left(self: Rect) u16 {
        return self.x;
    }

    /// Returns the right-most extent of the Rect.
    pub inline fn right(self: Rect) u16 {
        return self.x + self.width;
    }

    /// Returns the top-most extent of the Rect.
    pub inline fn top(self: Rect) u16 {
        return self.y;
    }

    /// Returns the bottom-most extent of the Rect.
    pub inline fn bottom(self: Rect) u16 {
        return self.y + self.height;
    }

    /// Returns the area of the Rect.
    pub inline fn area(self: Rect) u32 {
        // it's very unlikely that the width and height will be large enough
        // that their product overflows a u16, but we'll handle that edge case
        // anyway. as per zig zen, "edge cases matter!"
        return @as(u32, self.width) * @as(u32, self.height);
    }
};

/// An interface for elements that can be composited.
pub const Element = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    const VTable = struct {
        handle_event: *const fn ()
    };
};

const Position = struct {
    row: u16,
    col: u16,
};

pub const Text = struct {
    /// The buffer that will be written to the terminal.
    /// This memory must be managed by `allocator`.
    buf: []const u8,
    /// The allocator that allocated the memory for `buf`.
    allocator: std.mem.Allocator,

    visible: bool,
    dead: bool = false,

    pub fn element(self: *Text) Element {
        return .{
            .ptr = self,
            .vtable = &.{
                .is_visible = is_visible,
                .is_dead = is_dead,
            },
        };
    }

    fn deinit(ctx: *const anyopaque) void {
        const self = @ptrCast(*const Text, @alignCast(@alignOf(Text), ctx));
        self.allocator.free(self.buf);
    }

    fn is_visible(ctx: *anyopaque) bool {
        const self = @ptrCast(*Text, @alignCast(@alignOf(Text), ctx));
        return self.is_visible;
    }

    fn is_dead(ctx: *anyopaque) bool {
        const self = @ptrCast(*Text, @alignCast(@alignOf(Text), ctx));
        return self.is_dead;
    }
};
