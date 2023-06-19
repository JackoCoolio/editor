const std = @import("std");

pub fn Config(
    comptime K: type,
) type {
    return struct {
        to_bytes: fn (K) [@sizeOf(K)]u8,
    };
}

pub fn Trie(comptime K: type, comptime V: type, comptime config: Config(K)) type {
    return struct {
        const Self = @This();

        root: Node,
        allocator: std.mem.Allocator,

        pub fn init(allocator: std.mem.Allocator) Self {
            return .{
                .root = Node.init(allocator, null),
                .allocator = allocator,
            };
        }

        pub fn deinit(self: *const Self) void {
            self.root.deinit();
        }

        pub fn insert_sequence(self: *Self, seq: []const K, value: V) std.mem.Allocator.Error!void {
            if (seq.len == 0) {
                // redundant check. terminfo shouldn't give us empty strings
                return;
            }

            var curr = &self.root;
            var i: usize = 0;
            while (i < seq.len) : (i += 1) {
                const char = seq[i];
                const bytes = config.to_bytes(char);
                for (bytes) |byte| {
                    curr = try curr.get_next_or_insert(byte, null);
                }
            }
            curr.value = value;
        }

        pub fn lookup_node_exact(self: *const Self, seq: []const K) ?*const Node {
            var curr = &self.root;
            var i: usize = 0;
            while (i < seq.len) : (i += 1) {
                const char = seq[i];
                const bytes = config.to_bytes(char);
                for (bytes) |byte| {
                    curr = curr.get_next(byte) orelse return null;
                }
            }
            return curr;
        }

        pub fn remove_sequence(self: *Self, seq: []const K) bool {
            const node = self.lookup_node_exact(seq) orelse return false;
            node.value = null;
            // TODO: actually clean up the trie to remove dead branches
        }

        /// Looks up the given sequence in the trie, returning null if it doesn't exist.
        pub fn lookup_exact(self: *const Self, seq: []const K) ?V {
            if (self.lookup_node_exact(seq)) |node| {
                return node.value;
            } else {
                return null;
            }
        }

        const Longest = struct {
            /// The parsed value.
            value: V,
            /// The number of bytes that were eaten.
            eaten: usize,
        };

        /// Looks up the given sequence in the trie, returning the longest match.
        pub fn lookup_longest(self: *const Self, seq: []const K) ?Longest {
            var curr = &self.root;
            var i: usize = 0;
            var last_value: ?Longest = null;

            chars: while (i < seq.len) : (i += 1) {
                if (i == 0) {
                    std.debug.assert(curr.value == null);
                }

                if (curr.value) |value| {
                    last_value = .{ .value = value, .eaten = i };
                }

                const char = seq[i];
                const bytes = config.to_bytes(char);
                for (bytes) |byte| {
                    const next_curr_n = curr.get_next(byte);
                    if (next_curr_n) |next_curr| {
                        curr = next_curr;
                        continue;
                    }

                    break :chars;
                }
            }

            if (curr.value) |value| {
                std.debug.assert(i != 0);
                last_value = .{ .value = value, .eaten = i };
            }

            return last_value;
        }

        pub const Node = struct {
            value: ?V,
            branches: [256]?*Node,
            allocator: std.mem.Allocator,

            pub fn init(allocator: std.mem.Allocator, value: ?V) Node {
                return .{
                    .value = value,
                    .branches = std.mem.zeroes([256]?*Node),
                    .allocator = allocator,
                };
            }

            pub fn deinit(self: *const Node) void {
                for (self.branches) |branch_n| {
                    if (branch_n) |branch| {
                        branch.deinit();
                        self.allocator.destroy(branch);
                    }
                }
            }

            pub fn get_next(self: *const Node, byte: u8) ?*const Node {
                return self.branches[byte];
            }

            pub fn get_next_mut(self: *Node, byte: u8) ?*Node {
                return self.branches[byte];
            }

            pub fn get_next_or_insert(self: *Node, byte: u8, value: ?V) std.mem.Allocator.Error!*Node {
                if (self.get_next_mut(byte)) |next_node| {
                    return next_node;
                } else {
                    const index = byte;
                    const next_node_ptr = ptr: {
                        if (self.branches[index]) |branch| {
                            branch.value = value orelse branch.value;
                            break :ptr branch;
                        } else {
                            const next_node_ptr = try self.allocator.create(Node);
                            const next_node = Node.init(self.allocator, value);
                            next_node_ptr.* = next_node;
                            self.branches[index] = next_node_ptr;
                            break :ptr next_node_ptr;
                        }
                    };
                    return next_node_ptr;
                }
            }
        };
    };
}

fn u8_to_arr(val: u8) [1]u8 {
    return [1]u8{val};
}

pub fn ByteTrie(comptime V: type) type {
    return Trie(u8, V, .{ .to_bytes = u8_to_arr });
}

test "lookup_exact" {
    var trie = ByteTrie(
        u8,
    ).init(std.testing.allocator);
    defer trie.deinit();

    try trie.insert_sequence("foo", 42);

    try std.testing.expect(trie.lookup_exact("foo") == @as(?u8, 42));
}

test "lookup_longest" {
    var trie = ByteTrie(u8).init(std.testing.allocator);
    defer trie.deinit();

    try trie.insert_sequence("foo", 42);
    try trie.insert_sequence("fo", 13);
    try trie.insert_sequence("foob", 58);

    try std.testing.expect(trie.lookup_longest("foo").?.value == 42);
    var longest = trie.lookup_longest("foobar").?;
    try std.testing.expect(longest.value == 58);
    try std.testing.expect(longest.eaten == 4);
}
