const std = @import("std");

pub fn Trie(comptime V: type) type {
    return struct {
        root: Node,
        allocator: std.mem.Allocator,

        pub fn init(allocator: std.mem.Allocator) Trie(V) {
            return .{
                .root = Node.init(allocator, null),
                .allocator = allocator,
            };
        }

        pub fn deinit(self: *const Trie(V)) void {
            self.root.deinit();
        }

        pub fn insert_sequence(self: *Trie(V), seq: []const u8, value: V) std.mem.Allocator.Error!void {
            var curr = &self.root;
            var i: usize = 0;
            while (i < seq.len) : (i += 1) {
                curr = try curr.get_next_or_insert(seq[i], null);
            }
            curr.value = value;
        }

        /// Looks up the given sequence in the trie, returning null if it doesn't exist.
        pub fn lookup_exact(self: *const Trie(V), seq: []const u8) ?V {
            var curr = &self.root;
            var i: usize = 0;
            while (i < seq.len) : (i += 1) {
                curr = curr.get_next(seq[i]) orelse return null;
            }
            return curr.value;
        }

        const Longest = struct {
            /// The parsed value.
            value: V,
            /// The number of bytes that were eaten.
            eaten: usize,
        };

        /// Looks up the given sequence in the trie, returning the longest match.
        pub fn lookup_longest(self: *const Trie(V), seq: []const u8) ?Longest {
            var curr = &self.root;
            var i: usize = 0;
            var last_value: ?Longest = null;

            while (i < seq.len) : (i += 1) {
                if (curr.value) |value| {
                    std.debug.assert(i != 0);
                    last_value = .{ .value = value, .eaten = i };
                }

                const next_curr_n = curr.get_next(seq[i]);
                if (next_curr_n) |next_curr| {
                    curr = next_curr;
                    continue;
                }

                break;
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

            pub fn get_next(self: *const Node, char: u8) ?*const Node {
                return self.branches[char];
            }

            pub fn get_next_mut(self: *Node, char: u8) ?*Node {
                return self.branches[char];
            }

            pub fn get_next_or_insert(self: *Node, char: u8, value: ?V) std.mem.Allocator.Error!*Node {
                if (self.get_next_mut(char)) |next_node| {
                    return next_node;
                } else {
                    const next_node_dst = try self.allocator.create(Node);
                    const next_node = Node.init(self.allocator, value);
                    next_node_dst.* = next_node;

                    self.branches[char] = next_node_dst;
                    return next_node_dst;
                }
            }
        };
    };
}

test "lookup_exact" {
    var trie = Trie(u8).init(std.testing.allocator);
    defer trie.deinit();

    try trie.insert_sequence("foo", 42);

    try std.testing.expect(trie.lookup_exact("foo") == @as(?u8, 42));
}

test "lookup_longest" {
    var trie = Trie(u8).init(std.testing.allocator);
    defer trie.deinit();

    try trie.insert_sequence("foo", 42);
    try trie.insert_sequence("fo", 13);
    try trie.insert_sequence("foob", 58);

    try std.testing.expect(trie.lookup_longest("foo").?.value == 42);
    var longest = trie.lookup_longest("foobar").?;
    try std.testing.expect(longest.value == 58);
    try std.testing.expect(longest.eaten == 4);
}
