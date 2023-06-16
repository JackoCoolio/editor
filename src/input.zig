const std = @import("std");
const ByteTrie = @import("trie.zig").ByteTrie;
const terminfo = @import("terminfo");
const Capability = terminfo.Strings.Capability;
const TermInfo = terminfo.TermInfo;

pub const InputEventType = enum {
    Key,
    Mouse,
};

pub const InputEvent = union(InputEventType) {
    Key: KeyEvent,
    Mouse: MouseEvent,
};

pub const KeyEvent = struct {
    key: Key,
    modifiers: Modifiers = .{},
};

pub const KeyType = enum {
    Regular,
    Capability,
};

pub const Key = union(KeyType) {
    Regular: u8,
    Capability: Capability,
};

pub const Modifiers = struct {
    shift: bool = false,
    control: bool = false,
    alt: bool = false,
};

pub const MouseEvent = struct {};

pub const CapabilitiesTrie = ByteTrie(Capability);

pub fn build_capabilities_trie(allocator: std.mem.Allocator, term_info: TermInfo) std.mem.Allocator.Error!CapabilitiesTrie {
    const log = std.log.scoped(.build_capabilities_trie);

    var trie = CapabilitiesTrie.init(allocator);
    errdefer trie.deinit();

    var iter = term_info.strings.iter();
    while (iter.next()) |item| {
        log.info("insert: '{s}' -> '{s}'", .{ std.fmt.fmtSliceEscapeLower(item.value), @tagName(item.capability) });
        try trie.insert_sequence(item.value, item.capability);
    }
    return trie;
}

pub const InputEventQueue = struct {
    allocator: std.mem.Allocator,
    inner: *std.atomic.Queue(InputEvent),

    pub fn init(allocator: std.mem.Allocator) std.mem.Allocator.Error!InputEventQueue {
        const inner = blk: {
            const inner_ptr = try allocator.create(std.atomic.Queue(InputEvent));
            const inner = std.atomic.Queue(InputEvent).init();
            inner_ptr.* = inner;
            break :blk inner_ptr;
        };

        return InputEventQueue{
            .allocator = allocator,
            .inner = inner,
        };
    }

    pub fn deinit(self: InputEventQueue) void {
        var self_var = self;
        while (self_var.get()) |_| {}
        self.allocator.destroy(self.inner);
    }

    pub fn put(self: *InputEventQueue, event: InputEvent) std.mem.Allocator.Error!void {
        const node = std.atomic.Queue(InputEvent).Node{
            .data = event,
        };

        var node_ptr = try self.allocator.create(@TypeOf(node));
        node_ptr.* = node;

        self.inner.put(node_ptr);
    }

    pub fn get(self: *InputEventQueue) ?InputEvent {
        const node_ptr = self.inner.get() orelse return null;
        const data = node_ptr.data;

        // free the node
        self.allocator.destroy(node_ptr);

        return data;
    }
};

fn read_input(tty: std.os.fd_t, buf: []u8) std.os.ReadError![]u8 {
    var stream = std.io.fixedBufferStream(buf);

    while (true) {
        var segment_buf: [16]u8 = undefined;
        const segment_len = try std.os.read(tty, &segment_buf);

        // append the input segment to the input buffer
        _ = stream.write(segment_buf[0..segment_len]) catch std.debug.panic("input was longer than 1KB", .{});

        // if the input was at least as large as the segment, it might have
        // been incomplete, so read again
        if (segment_len == @sizeOf(@TypeOf(segment_buf))) {
            continue;
        }

        // getEndPos never fails. not sure why it returns !usize
        if ((stream.getEndPos() catch unreachable) == 0) {
            continue;
        }

        return stream.getWritten();
    }
}

/// Returns the unshifted version of the character, or null if it isn't shifted.
/// Example: `unshift('A') == 'a'`, `unshift('1') == null`.
pub fn unshift(key: u8) ?u8 {
    const lower = std.ascii.toLower(key);
    if (key == lower) {
        return null;
    } else {
        return lower;
    }
}

/// Returns the shifted version of the character, or null if it can't be shifted.
/// This only acts on alphabetic characters, not numbers, i.e. `shift('1') != '!'`.
/// Example: `shift('a') == 'A'`, `shift('1') == null`.
pub fn shift(key: u8) ?u8 {
    const upper = std.ascii.toUpper(key);
    if (key == upper) {
        return null;
    } else {
        return upper;
    }
}

pub fn input_thread_entry(tty: std.os.fd_t, trie: CapabilitiesTrie, event_queue: InputEventQueue) !void {
    // it's stupid that I have to do this, andrewrk pls fix
    // immutable parameters are fine, just allow shadowing
    var event_queue_var = event_queue;

    // if an input is larger than 1KB, something is very wrong!
    var input_buf: [1024]u8 = undefined;

    while (true) {
        var input = try read_input(tty, &input_buf);

        // we shift the input slice thru the buffer until we reach the end
        while (input.len > 0) {
            const longest_n = trie.lookup_longest(input);
            if (longest_n) |longest| {
                const cap = longest.value;

                try event_queue_var.put(InputEvent{
                    .Key = KeyEvent{
                        .key = Key{
                            .Capability = cap,
                        },
                        .modifiers = Modifiers{
                            .alt = false,
                            .shift = false,
                            .control = false,
                        },
                    },
                });

                input = input[longest.eaten..];
            } else {
                var char = input_buf[0];
                const unshifted_m = unshift(char);
                var modifiers = Modifiers{
                    .shift = false,
                    .control = false,
                    .alt = false,
                };
                if (unshifted_m) |unshifted| {
                    char = unshifted;
                    modifiers.shift = true;
                }
                try event_queue_var.put(InputEvent{
                    .Key = KeyEvent{
                        .key = Key{
                            .Regular = char,
                        },
                        .modifiers = modifiers,
                    },
                });
                input = input[1..];
            }
        }
    }

    unreachable;
}
