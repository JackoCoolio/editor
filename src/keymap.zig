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
            @truncate(cp >> 16),
            @truncate(cp >> 8),
            @truncate(cp),
            // modifiers
            @intFromBool(key.modifiers.shift),
            @intFromBool(key.modifiers.control),
            @intFromBool(key.modifiers.alt),
        },
        .symbol => |sym| [_]u8{
            // tag
            1,
            // value
            @intFromEnum(sym),
            0,
            0,
            // modifiers
            @intFromBool(key.modifiers.shift),
            @intFromBool(key.modifiers.control),
            @intFromBool(key.modifiers.alt),
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

pub const ContextualAction = struct {
    action: Action,
    mode: Mode,
};

pub const ActionContext = struct {
    settings: Settings,
    keymaps: Keymaps,
    last_keypress: ?std.time.Instant,
    action_queue: EventQueue(ContextualAction),
    mode: Mode,
    key_queue: std.BoundedArray(Key, 16),

    pub fn init(alloc: std.mem.Allocator, keymaps: Keymaps, settings: Settings, mode: Mode) std.mem.Allocator.Error!ActionContext {
        return ActionContext{
            .settings = settings,
            .keymaps = keymaps,
            .last_keypress = null,
            .action_queue = try EventQueue(ContextualAction).init(alloc),
            .key_queue = std.BoundedArray(Key, 16).init(0) catch unreachable,
            .mode = mode,
        };
    }

    pub fn deinit(self: ActionContext) void {
        self.action_queue.deinit();
        self.keymaps.deinit();
    }

    pub fn reset(self: *ActionContext, mode: Mode) void {
        self.key_queue.resize(0) catch {};
        while (self.action_queue.get()) |_| {}
        self.last_keypress = null;
        self.mode = mode;
    }

    pub fn check_timeout(self: *ActionContext) std.mem.Allocator.Error!void {
        const log = std.log.scoped(.check_timeout);

        const now = std.time.Instant.now() catch blk: {
            log.err("no clock found", .{});
            break :blk self.last_keypress;
        };

        const is_within_timeout = if (self.last_keypress) |last_keypress| (if (now) |now_u| now_u.since(last_keypress) < self.settings.key_timeout else true) else true;
        if (!is_within_timeout and self.key_queue.len > 0) {
            log.info("key timeout reached, handling queued keys", .{});
            // execute queued keys
            try self.handle_queued_keys();
        }
    }

    /// Returns the mode that the editor will be in after executing all of the
    /// actions in this action queue.
    pub fn get_curr_mode(self: *const ActionContext) Mode {
        const ctx_action = self.action_queue.tail() orelse return self.mode;
        return switch (ctx_action.action) {
            .change_mode => |mode| mode,
            else => ctx_action.mode,
        };
    }

    /// Consumes queued keys, and appends the generated actions to the action
    /// queue.
    fn handle_queued_keys(self: *ActionContext) std.mem.Allocator.Error!void {
        var rem_keys: []const Key = self.key_queue.constSlice();
        const curr_mode = self.get_curr_mode();
        while (rem_keys.len > 0) {
            if (self.keymaps.get_from_mode(curr_mode).lookup_longest(rem_keys)) |longest| {
                // we found an action for this key sequence
                rem_keys = rem_keys[longest.eaten..];
                const action: Action = longest.value;
                // if the action is a .change_mode action, we need to adjust the mode
                // or the rest of the keys won't make sense.
                // we also need to convey this information to the editor somehow
                try self.action_queue.put(.{ .action = action, .mode = curr_mode });
                switch (action) {
                    .change_mode => |new_mode| {
                        self.mode = new_mode;
                    },
                    else => {},
                }
            } else {
                // there weren't any actions for this key, so just append an .insert_bytes action
                const key = rem_keys[0];
                rem_keys = rem_keys[1..];

                var buf: [4]u8 = undefined;
                if (key.get_utf8(&buf)) |_| {
                    try self.action_queue.put(.{ .action = Action{ .insert_bytes = buf }, .mode = curr_mode });
                }
            }
        }

        // resize to 0 should never fail because 0 <= 16
        self.key_queue.resize(0) catch unreachable;
    }

    fn get_current_keymap(self: *const ActionContext) std.mem.Allocator.Error!*const KeymapTrie {
        return self.keymaps.get_from_mode(self.mode);
    }

    pub fn handle_key(self: *ActionContext, key: Key) std.mem.Allocator.Error!void {
        const log = std.log.scoped(.handle_key);

        var curr_mode = self.get_curr_mode();

        log.info("current mode: {s}", .{@tagName(curr_mode)});

        const keymap = try self.get_current_keymap();

        // invariant: the key queue must be a valid prefix at all times
        const node = keymap.lookup_node_exact(self.key_queue.constSlice()).?;

        if (node.get_next_with_char(key)) |with_key_node| {
            log.info("key continues valid prefix", .{});
            // the key continues a valid prefix
            if (with_key_node.is_leaf) {
                // the key queue is a leaf, so consume all of the keys and append the action
                log.info("key sequence is leaf", .{});

                if (with_key_node.value) |action| {
                    switch (action) {
                        .change_mode => |new_mode| {
                            self.mode = new_mode;
                        },
                        else => {},
                    }
                    try self.action_queue.put(.{ .action = action, .mode = curr_mode });
                } else {
                    log.warn("key sequence maps to null action", .{});
                }

                self.key_queue.resize(0) catch unreachable;

                // key was handled
                return;
            }
        } else {
            // the key does not continue a valid prefix. handle the queued keys first
            if (self.key_queue.len > 0) {
                log.info("handling queued keys", .{});
                try self.handle_queued_keys();
            }

            // update the current mode in case it changed
            curr_mode = self.get_curr_mode();

            if (!keymap.has_prefix(&[_]Key{key})) {
                log.info("keymap doesn't have prefix with this beginning; inserting bytes", .{});
                // if the key isn't a valid prefix, just append an .insert_bytes action
                var buf: [4]u8 = undefined;
                if (key.get_utf8(&buf) != null) {
                    try self.action_queue.put(.{ .action = Action{ .insert_bytes = buf }, .mode = curr_mode });
                }

                // key was handled
                return;
            }
        }

        log.info("key is valid prefix", .{});
        // it's a prefix
        self.key_queue.append(key) catch {
            log.err("action key queue ran out of space", .{});
        };
        self.last_keypress = std.time.Instant.now() catch null;
        log.info("appended {} to key queue", .{key});
    }
};
