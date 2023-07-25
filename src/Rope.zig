const Rope = @This();
const max_leaf_len: usize = 2;

const std = @import("std");
const Allocator = std.mem.Allocator;

root: Node = Node{ .leaf = "" },

pub fn init(str: []const u8) Rope {
    _ = str;

}

pub const Node = union(enum) {
    branch: struct {
        left: *Node,
        right: ?*Node,
        weight: u32,
    },
    leaf: []const u8,

    pub fn get_weight(self: *const Node) u32 {
        switch (self) {
            .leaf => |str| str.len,
            .branch => |br| {
                const left = br.weight;
                const right = if (br.right) |node| node.get_weight() else 0;
                return left + right;
            },
        }
    }

    pub fn get_left(self: *const Node) ?*Node {
        return switch (self) {
            .leaf => null,
            .branch => |node| node.left,
        };
    }

    pub fn get_right(self: *const Node) ?*Node {
        return switch (self) {
            .leaf => null,
            .branch => |node| node.right,
        };
    }
};

pub const Iter = struct {
    stack: std.ArrayList(*const Node),

    pub fn init(rope: *const Rope, alloc: Allocator) Allocator.Error!Iter {
        const stack = std.ArrayList(*const Node).init(alloc);
        var curr: *const Node = &rope.root;
        while (curr) |curr_u| {
            try stack.append(curr_u);
            curr = curr_u.get_left();
        }
        return Iter{ .stack = stack };
    }

    pub fn next(self: *Iter) Allocator.Error!?[]const u8 {
        if (self.stack.items.len == 0) {
            return null;
        }
        const result = self.stack.pop();

        if (self.stack.popOrNull()) |parent| {
            if (parent.branch.right) |right| {
                try self.stack.append(right);
                var child_left: ?*Node = right.get_left();
                while (child_left) |child_left_u| {
                    try self.stack.append(child_left_u);
                    child_left = child_left_u.get_left();
                }
            }
        }

        return result.leaf;
    }
};

pub fn iter(self: *const Rope, alloc: Allocator) Allocator.Error!Iter {
    return Iter.init(self, alloc);
}
