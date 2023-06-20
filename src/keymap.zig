const std = @import("std");
const Trie = @import("trie.zig").Trie;
const Key = @import("input.zig").Key;
const EventQueue = @import("event_queue.zig").EventQueue;

pub const ActionKind = enum {
    // special characters
    up,
    down,
    left,
    right,
    tab,
    backspace,
    delete,

    quit,

    // modes
    change_mode,

    // text entry
    insert_bytes,
};

pub const Mode = enum {
    normal,
    insert,
    select,
    command,
};

pub const Action = union(ActionKind) {
    up,
    down,
    left,
    right,
    tab,
    backspace,
    delete,

    quit,

    change_mode: Mode,

    insert_bytes: [4]u8,
};

fn key_event_to_bytes(key: Key) [7]u8 {
    return switch (key.code) {
        .unicode => |cp| [_]u8{
            // tag
            0,
            // value
            @truncate(u8, cp >> 16),
            @truncate(u8, cp >> 8),
            @truncate(u8, cp),
            // modifiers
            @boolToInt(key.modifiers.shift),
            @boolToInt(key.modifiers.control),
            @boolToInt(key.modifiers.alt),
        },
        .symbol => |sym| [_]u8{
            // tag
            1,
            // value
            @enumToInt(sym),
            0,
            0,
            // modifiers
            @boolToInt(key.modifiers.shift),
            @boolToInt(key.modifiers.control),
            @boolToInt(key.modifiers.alt),
        },
    };
}

pub const Keymaps = struct {
    normal: KeymapTrie,
    insert: KeymapTrie,
    select: KeymapTrie,
    command: KeymapTrie,

    pub fn init(alloc: std.mem.Allocator) Keymaps {
        return .{
            .normal = KeymapTrie.init(alloc),
            .insert = KeymapTrie.init(alloc),
            .select = KeymapTrie.init(alloc),
            .command = KeymapTrie.init(alloc),
        };
    }

    pub fn deinit(self: Keymaps) void {
        self.normal.deinit();
        self.insert.deinit();
        self.select.deinit();
        self.command.deinit();
    }

    pub fn insert_all(self: *Keymaps, seq: []const Key, action: Action) std.mem.Allocator.Error!void {
        const fields = @typeInfo(Keymaps).Struct.fields;
        inline for (fields) |field| {
            try @field(self, field.name).insert_sequence(seq, action);
        }
    }

    pub fn get_from_mode(self: *const Keymaps, mode: Mode) *const KeymapTrie {
        return switch (mode) {
            .normal => &self.normal,
            .insert => &self.insert,
            .select => &self.select,
            .command => &self.command,
        };
    }

    pub fn clone(self: *const Keymaps) Keymaps {
        return .{
            .normal = self.normal.clone(),
            .insert = self.insert.clone(),
            .select = self.select.clone(),
            .command = self.command.clone(),
        };
    }
};

pub const KeymapTrie = Trie(Key, Action, 7, .{
    .to_bytes = key_event_to_bytes,
});

pub fn build_keymaps(alloc: std.mem.Allocator) std.mem.Allocator.Error!Keymaps {
    var keymaps = Keymaps.init(alloc);

    const utf8 = @import("utf8.zig");

    // quit
    try keymaps.normal.insert_sequence(&[_]Key{.{ .code = .{ .unicode = comptime utf8.char_to_cp("e") }, .modifiers = .{ .control = true } }}, .{ .quit = {} });

    // movement
    try keymaps.insert_all(&[_]Key{.{ .code = .{ .symbol = .up } }}, .{ .up = {} });
    try keymaps.insert_all(&[_]Key{.{ .code = .{ .symbol = .down } }}, .{ .down = {} });
    try keymaps.insert_all(&[_]Key{.{ .code = .{ .symbol = .left } }}, .{ .left = {} });
    try keymaps.insert_all(&[_]Key{.{ .code = .{ .symbol = .right } }}, .{ .right = {} });
    try keymaps.normal.insert_sequence(&[_]Key{.{ .code = .{ .unicode = comptime utf8.char_to_cp("k") } }}, .{ .up = {} });
    try keymaps.normal.insert_sequence(&[_]Key{.{ .code = .{ .unicode = comptime utf8.char_to_cp("j") } }}, .{ .down = {} });
    try keymaps.normal.insert_sequence(&[_]Key{.{ .code = .{ .unicode = comptime utf8.char_to_cp("h") } }}, .{ .left = {} });
    try keymaps.normal.insert_sequence(&[_]Key{.{ .code = .{ .unicode = comptime utf8.char_to_cp("l") } }}, .{ .right = {} });

    // text editing
    try keymaps.insert.insert_sequence(&[_]Key{.{ .code = .{ .symbol = .backspace } }}, .{ .backspace = {} });
    try keymaps.insert.insert_sequence(&[_]Key{.{ .code = .{ .symbol = .delete } }}, .{ .delete = {} });

    // mode switching
    try keymaps.insert_all(&[_]Key{.{ .code = .{ .symbol = .escape } }}, .{ .change_mode = .normal });
    try keymaps.normal.insert_sequence(&[_]Key{.{ .code = .{ .unicode = comptime utf8.char_to_cp("i") } }}, .{ .change_mode = .insert });
    try keymaps.normal.insert_sequence(&[_]Key{.{ .code = .{ .unicode = comptime utf8.char_to_cp("v") } }}, .{ .change_mode = .select });
    try keymaps.normal.insert_sequence(&[_]Key{.{ .code = .{ .unicode = comptime utf8.char_to_cp(":") } }}, .{ .change_mode = .command });

    try keymaps.normal.insert_sequence(&[_]Key{ .{ .code = .{ .unicode = comptime utf8.char_to_cp("a") } }, .{ .code = .{ .unicode = comptime utf8.char_to_cp("b") } } }, .{ .delete = {} });

    return keymaps;
}

pub const Settings = struct {
    key_timeout: u64,
};

pub const PatchedKeymaps = struct {
    alloc: std.mem.Allocator,
    base: Keymaps,
    patches: std.ArrayList(Patch),
    patched: ?Keymaps,

    pub fn init(alloc: std.mem.Allocator, base: Keymaps) PatchedKeymaps {
        return .{
            .alloc = alloc,
            .base = base,
            .patches = std.ArrayList(Patch).init(alloc),
            .patched = null,
        };
    }

    pub fn deinit(self: *const PatchedKeymaps) void {
        self.discard();

        while (self.patches.popOrNull()) |patch| {
            patch.deinit();
        }
        self.patches.deinit();

        self.base.deinit();
    }

    fn discard(self: *PatchedKeymaps) void {
        if (self.patched) |patched| {
            patched.deinit();
            self.patched = null;
        }
    }

    pub fn get_patched(self: *PatchedKeymaps) std.mem.Allocator.Error!*const Keymaps {
        if (self.patched) |patched| {
            return patched;
        }

        var patched = self.base.clone();
        for (self.patches) |patch| {
            try patched.get_from_mode(patch.mode).insert_sequence(patch.seq, patch.action);
        }
    }

    pub fn patch_mode(self: *PatchedKeymaps, mode: Mode, seq: []const Key, action: ?Action) std.mem.Allocator.Error!void {
        self.discard();

        try self.patches.append(.{
            .mode = mode,
            .seq = seq,
            .action = action,
        });
    }

    pub fn patch_all(self: *PatchedKeymaps, seq: []const Key, action: ?Action) std.mem.Allocator.Error!void {
        inline for (@typeInfo(Mode).Enum.fields) |field| {
            try self.patch_mode(@field(Mode, field.name), seq, action);
        }
    }

    const Patch = struct {
        mode: Mode,
        seq: []const Key,
        action: ?Action,

        pub fn deinit(self: *const Patch, alloc: std.mem.Allocator) void {
            alloc.free(self.seq);
        }
    };
};

pub const ActionContext = struct {
    settings: Settings,
    keymaps: PatchedKeymaps,
    last_keypress: ?std.time.Instant,
    action_queue: EventQueue(struct { Action, Mode }),
    key_queue: std.BoundedArray(Key, 16),

    pub fn init(alloc: std.mem.Allocator, keymaps: PatchedKeymaps, settings: Settings) std.mem.Allocator.Error!ActionContext {
        return ActionContext{
            .settings = settings,
            .keymaps = keymaps,
            .last_keypress = null,
            .action_queue = try EventQueue(Action).init(alloc),
            .key_queue = std.BoundedArray(Key, 16).init(0) catch unreachable,
        };
    }

    pub fn deinit(self: ActionContext) void {
        self.action_queue.deinit();
        self.keymaps.deinit();
    }

    pub fn check_timeout(self: *ActionContext, mode: Mode) std.mem.Allocator.Error!Mode {
        const log = std.log.scoped(.check_timeout);

        const now = std.time.Instant.now() catch blk: {
            log.err("no clock found", .{});
            break :blk self.last_keypress;
        };

        const is_within_timeout = if (self.last_keypress) |last_keypress| (if (now) |now_u| now_u.since(last_keypress) < self.settings.key_timeout else true) else true;
        if (!is_within_timeout and self.key_queue.len > 0) {
            log.info("key timeout reached, handling queued keys", .{});
            // execute queued keys
            return try self.handle_queued_keys(mode);
        }

        return mode;
    }

    fn handle_queued_keys(self: *ActionContext, mode: Mode) std.mem.Allocator.Error!Mode {
        const keymaps = try self.keymaps.get_patched();
        var key_queue_s: []const Key = self.key_queue.constSlice();
        var curr_mode = mode;
        while (key_queue_s.len > 0) {
            if (keymaps.get_from_mode(curr_mode).lookup_longest(key_queue_s)) |longest| {
                key_queue_s = key_queue_s[longest.eaten..];
                const action: Action = longest.value;
                switch (action) {
                    .change_mode => |new_mode| {
                        curr_mode = new_mode;
                    },
                    else => try self.action_queue.put(.{ action, curr_mode }),
                }
            } else {
                const key = key_queue_s[0];
                key_queue_s = key_queue_s[1..];

                var buf = std.mem.zeroes([4]u8);
                if (key.get_utf8(&buf)) |_| {
                    // this is technically unnecessary because the allocator
                    // only exists within this function call, but for
                    // consistency, I'll free it
                    try self.action_queue.put(.{ Action{ .insert_bytes = buf }, curr_mode });
                }
            }
        }

        // resize to 0 should never fail because 0 <= 16
        self.key_queue.resize(0) catch unreachable;

        return curr_mode;
    }

    fn get_current_keymap(self: *const ActionContext, mode: *Mode) std.mem.Allocator.Error!*const KeymapTrie {
        return (try self.keymaps.get_patched()).get_from_mode(mode.*);
    }

    pub fn handle_key(self: *ActionContext, key: Key, mode: Mode) std.mem.Allocator.Error!Mode {
        const log = std.log.scoped(.handle_key);

        var curr_mode = mode;

        curr_mode = try self.check_timeout(curr_mode);

        const keymap = try self.get_current_keymap(curr_mode);

        log.info("current key queue len: {}", .{self.key_queue.len});

        // invariant: the key queue must be a valid prefix at all times
        const node = keymap.lookup_node_exact(self.key_queue.constSlice()).?;

        if (node.get_next_with_char(key)) |with_key_node| {
            log.info("key continues a valid prefix", .{});
            if (with_key_node.is_leaf) {
                log.info("key queue is a leaf", .{});
                if (with_key_node.value) |action| {
                    try self.action_queue.put(.{ action, curr_mode });
                    self.key_queue.resize(0) catch unreachable;
                    return;
                } else {
                    log.warn("key sequence maps to null action", .{});
                }
            }
        } else if (self.key_queue.len > 0) {
            // it's not a valid prefix now, so handle the queued keys
            // this empties the key queue
            log.info("handling queued keys before appending new key", .{});
            curr_mode = try self.handle_queued_keys(curr_mode);
        }

        if (keymap.lookup_node_exact(&[_]Key{key}) == null) {
            // if the key isn't a valid prefix, just append a text-insertion
            // action if the key has a text repr
            var buf: [4]u8 = undefined;
            if (key.get_utf8(&buf) != null) {
                try self.action_queue.put(.{ Action{ .insert_bytes = buf }, curr_mode });
            }
            return;
        }

        // now the new key results in a valid prefix, so we can add it
        self.key_queue.append(key) catch {
            log.err("action key queue ran out of space", .{});
        };
        self.last_keypress = std.time.Instant.now() catch null;
        log.info("appended {} to key queue", .{key});
    }
};
