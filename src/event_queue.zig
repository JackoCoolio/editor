const std = @import("std");

pub fn EventQueue(comptime E: type) type {
    return struct {
        const Self = @This();
        allocator: std.mem.Allocator,
        inner: *std.atomic.Queue(E),

        pub fn init(allocator: std.mem.Allocator) std.mem.Allocator.Error!Self {
            const inner = blk: {
                const inner_ptr = try allocator.create(std.atomic.Queue(E));
                const inner = std.atomic.Queue(E).init();
                inner_ptr.* = inner;
                break :blk inner_ptr;
            };

            return Self{
                .allocator = allocator,
                .inner = inner,
            };
        }

        pub fn deinit(self: Self) void {
            var self_var = self;
            while (self_var.get()) |_| {}
            self.allocator.destroy(self.inner);
        }

        pub fn put(self: *Self, event: E) std.mem.Allocator.Error!void {
            const node = std.atomic.Queue(E).Node{
                .data = event,
            };

            var node_ptr = try self.allocator.create(@TypeOf(node));
            node_ptr.* = node;

            self.inner.put(node_ptr);
        }

        pub fn get(self: *Self) ?E {
            const node_ptr = self.inner.get() orelse return null;
            const data = node_ptr.data;

            // free the node
            self.allocator.destroy(node_ptr);

            return data;
        }

        pub fn tail(self: *const Self) ?E {
            const node = self.inner.tail orelse return null;
            return node.data;
        }
    };
}
