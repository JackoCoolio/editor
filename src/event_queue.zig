const std = @import("std");

pub fn EventQueue(comptime E: type) type {
    return struct {
        const Self = @This();
        const Queue = std.DoublyLinkedList(E);
        const Node = Queue.Node;

        allocator: std.mem.Allocator,
        mutex: std.Thread.Mutex,
        inner: Queue,

        pub fn init(allocator: std.mem.Allocator) std.mem.Allocator.Error!Self {
            return Self{
                .allocator = allocator,
                .mutex = .{},
                .inner = .{},
            };
        }

        pub fn deinit(self: Self) void {
            var self_var = self;
            while (self_var.get()) |_| {}
        }

        pub fn put(self: *Self, event: E) std.mem.Allocator.Error!void {
            const node_ptr = try self.allocator.create(Node);
            node_ptr.data = event;

            self.mutex.lock();
            defer self.mutex.unlock();

            self.inner.append(node_ptr);
        }

        fn get_node(self: *Self) ?*Node {
            self.mutex.lock();
            defer self.mutex.unlock();

            return self.inner.popFirst();
        }

        pub fn get(self: *Self) ?E {
            const node_ptr = self.get_node() orelse return null;
            const data = node_ptr.data;

            // free the node
            self.allocator.destroy(node_ptr);

            return data;
        }

        pub fn tail(self: *const Self) ?E {
            const node = self.inner.last orelse return null;
            return node.data;
        }
    };
}
