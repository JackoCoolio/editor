const max_leaf_len: usize = 4;

const std = @import("std");
const Allocator = std.mem.Allocator;
const Position = @import("Position.zig");

pub const Rope = struct {
    alloc: Allocator,
    data: union(enum) {
        branch: struct {
            left: *Rope,
            right: *Rope,
            weight: usize,
        },
        leaf: []const u8,
    },
    stats: Stats,

    const Stats = struct {
        /// exclusive bound to cursor position
        cursor_span: Position,

        pub fn calculate(left: Stats, right: Stats) Stats {
            return Stats{
                .cursor_span = Position.add(left.cursor_span, right.cursor_span),
            };
        }
    };

    /// Create a new Rope from the given string.
    /// The string is cloned, so the caller must still free it.
    pub fn init(alloc: Allocator, str: []const u8) Allocator.Error!*Rope {
        // allocate root
        var rope_ptr = try alloc.create(Rope);
        errdefer alloc.destroy(rope_ptr);

        // if the string can fit in a leaf, the root will just be a leaf
        if (str.len <= max_leaf_len) {

            // calculate cursor_span
            var end_pos = Position.zero;
            for (str) |ch| {
                if (ch == '\n') {
                    end_pos.row += 1;
                    end_pos.col = 0;
                } else {
                    end_pos.col += 1;
                }
            }

            // duplicate the string
            const str_dup = try alloc.dupe(u8, str);
            errdefer alloc.free(str_dup);

            // initialize and return the root
            rope_ptr.* = Rope{
                .alloc = alloc,
                .data = .{ .leaf = str_dup },
                .stats = .{
                    .cursor_span = end_pos,
                },
            };
            std.log.info("init:", .{});
            try rope_ptr.dump_with_depth(0);
            return rope_ptr;
        }
        // otherwise, we have to split the rope

        // split the string
        const mid = str.len / 2;
        const a = str[0..mid];
        const b = str[mid..];

        // initialize a rope for the left half
        const left = try Rope.init(alloc, a);
        errdefer left.destroy();

        // initialize a rope for the right half
        const right = try Rope.init(alloc, b);
        errdefer right.destroy();

        // initialize and return the root
        rope_ptr.* = Rope{
            .alloc = alloc,
            .data = .{
                .branch = .{
                    .left = left,
                    .right = right,
                    .weight = a.len,
                },
            },
            .stats = Stats.calculate(left.stats, right.stats),
        };
        std.log.info("init:", .{});
        try rope_ptr.dump_with_depth(0);
        return rope_ptr;
    }

    /// Destroy and free the Rope.
    pub fn destroy(self: *const Rope) void {
        switch (self.data) {
            .leaf => |str| {
                // leaves only need to free their internal strings
                self.alloc.free(str);
            },
            .branch => |br| {
                // branches have to destroy both halves
                br.left.destroy();
                br.right.destroy();
            },
        }
        // free the memory allocated for this Rope node
        self.alloc.destroy(self);
    }

    const Recursion = enum { recursive, nonrecursive };
    fn recalculate_stats(self: *Rope, recursion: Recursion) void {
        switch (self.data) {
            .branch => |br| {
                if (recursion == .recursive) {
                    br.left.recalculate_stats(.recursive);
                    br.right.recalculate_stats(.recursive);
                }
                self.stats = Stats.calculate(br.left.stats, br.right.stats);
            },
            .leaf => {}, // leaf strings are immutable, so they never have to be recalculated
        }
    }

    fn get_weight(self: *const Rope) usize {
        switch (self.data) {
            .leaf => |str| return str.len,
            .branch => |br| {
                const left = br.weight;
                const right = br.right.get_weight();
                return left + right;
            },
        }
    }

    /// Returns the left subtree of this Rope if there is one, otherwise null.
    fn get_left(self: *const Rope) ?*Rope {
        return switch (self.data) {
            .leaf => null,
            .branch => |node| node.left,
        };
    }

    /// Sets the left subtree of this Rope to the given Rope.
    /// Assumes that `self` is a branch, not a leaf.
    /// Also updates stats.
    fn set_left(self: *Rope, left: *Rope) void {
        self.data.branch.left = left;
        self.recalculate_stats(.nonrecursive);
    }

    /// Returns the right subtree of this Rope if there is one, otherwise null.
    fn get_right(self: *const Rope) ?*Rope {
        return switch (self) {
            .leaf => null,
            .branch => |node| node.right,
        };
    }

    /// Sets the right subtree of this Rope to the given Rope.
    /// Assumes that `self` is a branch, not a leaf.
    ///
    /// Also updates stats.
    fn set_right(self: *Rope, right: *Rope) void {
        self.data.branch.right = right;
        self.recalculate_stats(.nonrecursive);
    }

    pub const LeafIter = struct {
        stack: std.ArrayList(*const Rope),

        pub fn init(rope: *const Rope, alloc: Allocator) Allocator.Error!LeafIter {
            var stack = std.ArrayList(*const Rope).init(alloc);
            var curr: ?*const Rope = rope;
            while (curr) |curr_u| {
                try stack.append(curr_u);
                curr = curr_u.get_left();
            }
            return LeafIter{ .stack = stack };
        }

        pub fn deinit(self: *const LeafIter) void {
            self.stack.deinit();
        }

        pub fn next(self: *LeafIter) Allocator.Error!?*const Rope {
            if (self.stack.items.len == 0) {
                return null;
            }
            const result = self.stack.pop();

            if (self.stack.popOrNull()) |parent| {
                const right = parent.data.branch.right;
                try self.stack.append(right);
                var child_left: ?*Rope = right.get_left();
                while (child_left) |child_left_u| {
                    try self.stack.append(child_left_u);
                    child_left = child_left_u.get_left();
                }
            }

            return result;
        }
    };

    pub fn leaves(self: *const Rope, alloc: Allocator) Allocator.Error!LeafIter {
        return LeafIter.init(self, alloc);
    }

    pub const ChunkIter = struct {
        leaf_iter: LeafIter,

        pub fn next(self: *ChunkIter) Allocator.Error!?[]const u8 {
            const leaf = try self.leaf_iter.next() orelse return null;
            return leaf.data.leaf;
        }

        pub fn deinit(self: *const ChunkIter) void {
            self.leaf_iter.deinit();
        }
    };

    pub fn chunks(self: *const Rope, alloc: Allocator) Allocator.Error!ChunkIter {
        return ChunkIter{ .leaf_iter = try self.leaves(alloc) };
    }

    pub const LineIter = struct {
        /// Iterator over leaves of the rope.
        leaf_iter: LeafIter,
        /// The data in the leaf that we are currently working on
        chunk: []const u8,

        alloc: Allocator,

        /// Returns the next line in the rope. Caller owns the returned string
        /// and must free it.
        pub fn next(self: *LineIter) Allocator.Error!?[]const u8 {
            var line = std.ArrayList(u8).init(self.alloc);

            // check if we need to ask for a new multi-line chunk. otherwise, we can keep
            // working on the current one
            if (self.chunk.len == 0) {
                var leaf: *const Rope = undefined;
                // keep appending to self.line until we find a leaf that crosses to the next line
                // i.e. we're finding a multi-line chunk
                while (true) {
                    leaf = try self.leaf_iter.next() orelse {
                        // if we reach the last leaf, return what we have
                        if (line.items.len > 0) {
                            return try line.toOwnedSlice();
                        } else {
                            line.deinit();
                            return null;
                        }
                    };

                    // break once we find a multi-line chunk
                    if (leaf.get_line_count() > 1) {
                        self.chunk = leaf.data.leaf;
                        break;
                    }

                    try line.appendSlice(leaf.data.leaf);
                }
            }

            // find the next line ending
            var rem = self.chunk;
            while (rem.len > 0) {
                // we save the first char and shift rem before breaking to ensure
                // that we skip the newline char. if we waited until after, we'd
                // have to do redundant checks to figure out if we exited the
                // loop because we found a newline or because we ran out of chars.
                const char = rem[0];
                rem = rem[1..];
                if (char == '\n') {
                    const chunk_len = self.chunk.len - rem.len - 1;
                    try line.appendSlice(self.chunk[0..chunk_len]);

                    // shift the chunk to the next line
                    self.chunk = rem;

                    return try line.toOwnedSlice();
                }
            }

            // we just reached the end of the chunk
            try line.appendSlice(self.chunk);
            self.chunk = "";

            if (try self.next()) |next_line| {
                try line.appendSlice(next_line);
                self.alloc.free(next_line);
            }

            return try line.toOwnedSlice();
        }

        pub fn deinit(self: *const LineIter) void {
            self.leaf_iter.deinit();
        }
    };

    pub fn lines(self: *const Rope, alloc: Allocator) Allocator.Error!LineIter {
        return LineIter{
            .leaf_iter = try self.leaves(alloc),
            .chunk = "",
            .alloc = alloc,
        };
    }

    /// Returns a new Rope with the contents of `left` and `right` concatenated.
    /// The returned Rope takes ownership of `left` and `right`.
    pub fn concat(left: *Rope, right: *Rope) Allocator.Error!*Rope {
        std.debug.assert(left.alloc.ptr == right.alloc.ptr);
        const alloc = left.alloc;
        const rope_ptr = try alloc.create(Rope);
        rope_ptr.* = Rope{
            .alloc = alloc,
            .data = .{
                .branch = .{
                    .left = left,
                    .right = right,
                    .weight = left.get_weight(),
                },
            },
            .stats = Stats.calculate(left.stats, right.stats),
        };
        return rope_ptr;
    }

    /// Returns the string representation of the Rope.
    pub fn collect(self: *const Rope, alloc: Allocator) Allocator.Error![]u8 {
        switch (self.data) {
            .leaf => |str| return try alloc.dupe(u8, str),
            .branch => |br| {
                var str = try std.ArrayList(u8).initCapacity(alloc, br.weight);
                var it = try self.chunks(alloc);
                defer it.deinit();
                while (try it.next()) |chunk| {
                    try str.appendSlice(chunk);
                }
                return try str.toOwnedSlice();
            },
        }
    }

    pub const Split = struct {
        left: *Rope,
        right: *Rope,

        /// Deinitializes both halves of the split.
        pub inline fn deinit(self: Split) void {
            self.left.destroy();
            self.right.destroy();
        }
    };

    const Child = enum { left, right };

    /// Ensures that the given index points to the middle of a branch, not a leaf.
    fn fragment_at(self: *Rope, index: usize) Allocator.Error!void {
        if (max_leaf_len == 1) {
            return;
        }

        switch (self.data) {
            .leaf => |str| {
                // create the left rope...
                const left = try Rope.init(self.alloc, str[0..index]);
                errdefer self.alloc.destroy(left);

                // ...and the right rope
                const right = try Rope.init(self.alloc, str[index..]);
                errdefer self.alloc.destroy(right);

                // free the previously allocated string, because we split it
                self.alloc.free(str);

                self.data = .{
                    .branch = .{
                        .left = left,
                        .right = right,
                        .weight = index,
                    },
                };

                // we don't need to update stats here, because this Rope
                // hasn't changed in its representation
            },
            .branch => |br| {
                if (index < br.weight) {
                    // the fragmentation point is in the left subtree
                    try br.left.fragment_at(index);
                } else if (index > br.weight) {
                    // the fragmentation point is in the right subtree
                    try br.right.fragment_at(index - br.weight);
                }
            },
        }
    }

    /// Splits this Rope at the given index.
    ///
    /// Note: the caller owns the returned Ropes and the input Rope is freed.
    /// Thus, the input Rope may contain undefined memory and should not be
    /// accessed.
    fn split_new(self: *Rope, index: usize) Allocator.Error!Split {
        try self.fragment_at(index);
        return self.split_help(index);
    }

    /// Splits the Rope at the given index. The address of the Rope may be invalidated.
    /// Asserts that the index lies on a branch boundary.
    /// The returned Ropes have up-to-date newline counts.
    fn split_help(self: *Rope, index: usize) Allocator.Error!Split {
        switch (self.data) {
            .leaf => std.debug.panic("split_help called with invalid assumptions", .{}),
            .branch => {},
        }

        var br = self.data.branch;
        if (index == br.weight) {
            // this is the split
            const left = br.left;
            const right = br.right;

            // free memory allocated for this rope node
            self.alloc.destroy(self);
            self.* = undefined;
            return .{ .left = left, .right = right };
        } else if (index < br.weight) {
            // the split is in the left subtree
            const spl = try br.left.split_help(index); // after this, br.left == undefined
            // set the left branch and update stats
            self.set_left(spl.right);
            return .{ .left = spl.left, .right = self };
        } else { // index > br.weight
            // the split is in the right subtree
            const spl = try br.right.split_help(index - br.weight);
            // set the right branch and update stats
            self.set_right(spl.left);
            return .{ .left = self, .right = spl.right };
        }
    }

    pub fn eql_str(self: *const Rope, alloc: Allocator, str: []const u8) Allocator.Error!bool {
        const actual = try self.collect(alloc);
        defer alloc.free(actual);
        return std.mem.eql(u8, actual, str);
    }

    /// Inserts a string into the Rope.
    pub fn insert(self: *Rope, index: usize, str: []const u8) Allocator.Error!*Rope {
        const insertion = try Rope.init(self.alloc, str);
        errdefer insertion.destroy();

        // edge cases
        if (index == 0) {
            return try Rope.concat(insertion, self);
        } else if (index == self.get_weight()) {
            return try Rope.concat(self, insertion);
        }

        const spl = try self.split_new(index);
        errdefer spl.deinit();

        const left = try Rope.concat(spl.left, insertion);
        errdefer left.destroy();

        const final = try Rope.concat(left, spl.right);
        errdefer final.destroy();
        return final;
    }

    /// Returns the index in the buffer that the given position points to.
    /// Assumes that the top left of the buffer is row 0 and column 0.
    pub fn get_index_from_cursor_pos(self: *const Rope, target: Position) ?usize {
        if (target.row > self.stats.cursor_span.row) {
            return null;
        }

        // quick shortcut for easily, verifiably invalid positions
        if (target.row == self.stats.cursor_span.row and target.col > self.stats.cursor_span.col) {
            return null;
        }

        switch (self.data) {
            .leaf => |str| {
                var rem = str;
                for (0..target.row) |_| {
                    // eat a line
                    while (rem.len > 0 and rem[0] != '\n') {
                        rem = rem[1..];
                    }
                }

                rem = rem[target.col..];
                return str.len - rem.len;
            },
            .branch => |br| {
                const mid = br.left.stats.cursor_span;
                if (target.row < mid.row) {
                    // previous row
                    return br.left.get_index_from_cursor_pos(target);
                } else if (target.row > mid.row) {
                    // next row
                    return if (br.right.get_index_from_cursor_pos(.{ .row = target.row - mid.row, .col = target.col })) |index| br.weight + index else null;
                } else {
                    if (target.col < mid.col) {
                        // left branch
                        return br.left.get_index_from_cursor_pos(target);
                    } else {
                        // right branch
                        return if (br.right.get_index_from_cursor_pos(.{ .row = 0, .col = target.col - mid.col })) |index| br.weight + index else null;
                    }
                }
            },
        }
    }

    /// Returns the length of the string.
    pub fn get_length(self: *const Rope) usize {
        var node = self;
        var length = 0;

        while (true) {
            switch (node.data) {
                .leaf => |leaf| {
                    return length + leaf.len;
                },
                .branch => |br| {
                    length += br.weight;
                    node = br.right;
                },
            }
        }

        unreachable;
    }

    /// Returns the number of lines in the string.
    pub inline fn get_line_count(self: *const Rope) usize {
        return self.stats.cursor_span.row + 1;
    }

    /// Returns the length of the specified line, excluding line-feed.
    pub fn get_line_length(self: *const Rope, line_index: usize) ?usize {
        // length of line that doesn't exist is null
        if (line_index >= self.get_line_count()) {
            return null;
        }

        // length of last line is the span column bound
        if (line_index + 1 == self.get_line_count()) {
            return self.stats.cursor_span.col;
        }

        const next_line_start_index = self.get_index_from_cursor_pos(Position{
            .row = line_index + 1,
            .col = 0,
        }) orelse unreachable;

        const this_line_start_index = self.get_index_from_cursor_pos(Position{
            .row = line_index,
            .col = 0,
        }) orelse unreachable;

        return next_line_start_index - this_line_start_index;
    }

    /// Returns true if the string is empty.
    pub inline fn is_empty(self: *const Rope) bool {
        return self.stats.cursor_span.row == 0 and self.stats.cursor_span.col == 0;
    }

    pub fn dump_with_depth(self: *const Rope, depth: usize) Allocator.Error!void {
        const scope = std.log.scoped(.rope);

        const indent = try self.alloc.alloc(u8, depth * 2);
        defer self.alloc.free(indent);
        @memset(indent, ' ');

        switch (self.data) {
            .leaf => |str| {
                scope.err("{s}\"{s}\"", .{ indent, std.fmt.fmtSliceEscapeLower(str) });
            },
            .branch => |branch| {
                scope.err("{s}* ({}, {})", .{
                    indent,
                    self.stats.cursor_span.row,
                    self.stats.cursor_span.col,
                });
                try branch.left.dump_with_depth(depth + 1);
                try branch.right.dump_with_depth(depth + 1);
            },
        }
    }

    pub fn dump_stats(self: *const Rope) Allocator.Error!void {
        try self.dump_stats_with_depth(0);
    }

    pub fn dump_stats_with_depth(self: *const Rope, depth: usize) Allocator.Error!void {
        const scope = std.log.scoped(.rope_stats);

        const indent = try self.alloc.alloc(u8, depth * 2);
        defer self.alloc.free(indent);
        @memset(indent, ' ');

        switch (self.data) {
            .leaf => |str| {
                scope.err("{s}\"{s}\"", .{ indent, std.fmt.fmtSliceEscapeLower(str) });
            },
            else => {},
        }

        scope.err("{s}- cursor span: {}:{}", .{ indent, self.stats.cursor_span.row, self.stats.cursor_span.col });

        switch (self.data) {
            .branch => |br| {
                try br.left.dump_stats_with_depth(depth + 1);
                try br.right.dump_stats_with_depth(depth + 1);
            },
            else => {},
        }
    }
};

test "create and destroy" {
    const rope = try Rope.init(std.testing.allocator, "the quick brown fox jumps over the lazy dog");
    rope.destroy();
}

test "iter" {
    const S = struct {
        pub fn t(s: []const u8) !void {
            const alloc = std.testing.allocator;
            const rope = try Rope.init(alloc, s);
            defer rope.destroy();
            const str = try rope.collect(alloc);
            defer alloc.free(str);
            try std.testing.expectEqualSlices(u8, s, str);
        }
    };
    try S.t("Hello, world!");
    try S.t("");
    try S.t("h");
}

test "concat" {
    const alloc = std.testing.allocator;
    const left = try Rope.init(alloc, "Hello, ");
    const right = try Rope.init(alloc, "world!");

    const rope = try Rope.concat(left, right);
    defer rope.destroy();
    const str = try rope.collect(alloc);
    defer alloc.free(str);

    try std.testing.expectEqualSlices(u8, "Hello, world!", str);
}

test "fragment_at" {
    const alloc = std.testing.allocator;
    var rope = try Rope.init(alloc, "Hello, world!");

    try rope.fragment_at(7);

    rope.destroy();
}

test "split" {
    const alloc = std.testing.allocator;
    var rope = try Rope.init(alloc, "Hello, world!");

    try rope.fragment_at(7);

    const spl = try rope.split_help(7);

    spl.deinit();

    // try std.testing.expect(try spl.left.eql_str(alloc, "Hello, "));
    // try std.testing.expect(try spl.right.eql_str(alloc, "world!"));
}

test "insert" {
    const alloc = std.testing.allocator;

    const S = struct {
        pub fn t(initial: []const u8, index: usize, insertion: []const u8, expected: []const u8) !void {
            var rope = try Rope.init(alloc, initial);
            defer rope.destroy();
            rope = try Rope.insert(rope, index, insertion);
            try std.testing.expect(try rope.eql_str(alloc, expected));
        }
    };

    try S.t("Hello,world!", 6, " ", "Hello, world!");
    try S.t("bar", 0, "foo", "foobar");
    try S.t("foo", 3, "bar", "foobar");
    try S.t("", 0, "foo", "foo");
    try S.t("", 0, "", "");
}

test "append" {
    const alloc = std.testing.allocator;

    const str = "Hello\nthere\nmy\nname\nis\nJackson";

    var rope = try Rope.init(alloc, "Hello\nthere\nmy\nname\nis\nJackson");
    defer rope.destroy();

    rope = try rope.insert(str.len, "foo");

    try std.testing.expect(try rope.eql_str(alloc, "Hello\nthere\nmy\nname\nis\nJacksonfoo"));
}

test "insert_into_empty" {
    const alloc = std.testing.allocator;

    var rope = try Rope.init(alloc, "");
    defer rope.destroy();

    rope = try rope.insert(0, "foo");

    try std.testing.expect(try rope.eql_str(alloc, "foo"));
}

test "cursor_span" {
    const alloc = std.testing.allocator;
    var rope = try Rope.init(alloc, "Hello\nthere\nmy\nname\nis\nJackson");
    defer rope.destroy();

    try std.testing.expect(rope.stats.cursor_span.eq(Position{ .row = 5, .col = 7 }));
}

test "get_index_from_cursor_pos" {
    const alloc = std.testing.allocator;
    const str = "# editor\n\nA text editor, written in Zig.\n";
    var rope = try Rope.init(alloc, str);
    defer rope.destroy();

    try std.testing.expectEqual(@as(?usize, 0), rope.get_index_from_cursor_pos(.{ .row = 0, .col = 0 }));
    // try std.testing.expectEqual(@as(?usize, str.len), rope.get_index_from_cursor_pos(.{ .row = 3, .col = 0 }));
    try std.testing.expectEqual(@as(?usize, 36), rope.get_index_from_cursor_pos(.{ .row = 2, .col = 26 }));
}

test "get_line_count" {
    const S = struct {
        pub fn t(string: []const u8, expected_length: usize) !void {
            const rope = try Rope.init(std.testing.allocator, string);
            defer rope.destroy();

            try std.testing.expectEqual(expected_length, rope.get_line_count());
        }
    };

    try S.t("", 1);
    try S.t("foo", 1);
    try S.t("foo\n", 2);
    try S.t("foo\nbar", 2);
    try S.t("foo\nbar\n", 3);
}

test "is_empty" {
    const S = struct {
        pub fn t(string: []const u8, is_empty: bool) !void {
            const rope = try Rope.init(std.testing.allocator, string);
            defer rope.destroy();

            try std.testing.expectEqual(is_empty, rope.is_empty());
        }
    };

    try S.t("", true);
    try S.t(" ", false);
    try S.t("\n", false);
    try S.t("\nfoo", false);
    try S.t("foo", false);
}

test "get_line_length" {
    const S = struct {
        pub fn t(string: []const u8, line_index: usize, length: ?usize) !void {
            const rope = try Rope.init(std.testing.allocator, string);
            defer rope.destroy();

            try std.testing.expectEqual(length, rope.get_line_length(line_index));
        }
    };

    try S.t("", 0, 0);
    try S.t("\n", 0, 0);
    try S.t("\n", 1, 0);
    try S.t("foo", 0, 3);
    try S.t("foo\n", 0, 3);
    try S.t("foo\nbar", 0, 3);
    try S.t("foo\nbar", 1, 3);
    try S.t("foo\nbar\n", 1, 3);
}

test "lines_iter" {
    const rope = try Rope.init(std.testing.allocator, "Hello\nthere\nmy\nname\nis\nJackson");
    defer rope.destroy();

    const expected = [_]([]const u8){ "Hello", "there", "my", "name", "is", "Jackson" };
    var lines = try rope.lines(std.testing.allocator);
    defer lines.deinit();

    var i: usize = 0;
    while (try lines.next()) |line| : (i += 1) {
        defer std.testing.allocator.free(line);
        try std.testing.expectEqualSlices(u8, expected[i], line);
    }

    // we should have gotten all of the expected strings
    try std.testing.expectEqual(expected.len, i);
}
