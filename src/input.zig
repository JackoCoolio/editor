const std = @import("std");
const posix = std.posix;

const ByteTrie = @import("trie.zig").ByteTrie;
const terminfo = @import("terminfo");
const Capability = terminfo.Strings.Capability;
const TermInfo = terminfo.TermInfo;
const utf8 = @import("utf8.zig");
const EventQueue = @import("event_queue.zig").EventQueue;

pub const Symbol = enum {
    // C0
    backspace,
    tab,
    enter,
    escape,
    space,
    delete,

    // directional
    up,
    down,
    left,
    right,

    // terminfo `key_` keys
    begin,
    backtab,
    cancel,
    clear_all_tabs,
    clear_screen,
    close,
    command,
    copy,
    create,
    clear_tab,
    delete_line,
    eic, // ?
    end,
    clear_to_eol,
    clear_to_eos,
    exit,
    find,
    help,
    home,
    insert_character,
    insert_line,
    mark,
    message,
    move,
    next,
    next_page,
    open,
    options,
    prev_page,
    previous,
    print,
    redo,
    reference,
    refresh,
    replace,
    restart,
    resume_,
    save,
    select,
    scroll_forward,
    scroll_backward,
    undo,
    suspend_,

    unknown,
};

pub const InputEventType = enum {
    key,
    mouse,
};

pub const InputEvent = union(InputEventType) {
    key: Key,
    mouse: MouseEvent,
};

pub const Key = struct {
    code: Code,

    modifiers: Modifiers = .{},

    const Code = union(enum) {
        /// A text key-press, null-terminated or 4 bytes long.
        /// Example: "a", "è"
        unicode: u21,
        /// A non-text key-press.
        /// Example: "cursor_up", "key_backspace"
        symbol: Symbol,
    };

    /// Returns the UTF-8 representation of the Key. If the Key is a unicode
    /// codepoint, the returned value is the UTF-8 encoding of the codepoint.
    /// If it is a symbol that has a text representation, that is returned.
    /// Caller is responsible for freeing the returned memory.
    ///
    /// The returned slice is guaranteed to be between 1 and 4 bytes, inclusive.
    pub fn get_utf8(self: *const Key, buf: *[4]u8) ?[]u8 {
        return switch (self.code) {
            .unicode => |cp| utf8.cp_to_char(buf, cp),
            .symbol => |sym| switch (sym) {
                .space => utf8.cp_to_char(buf, 0x20),
                else => null,
            },
        };
    }

    pub fn from_capability(cap: Capability) Key {
        return switch (cap) {
            .key_backspace => .{ .code = .{ .symbol = .backspace } },
            .carriage_return => .{ .code = .{ .symbol = .enter } },
            .key_dc => .{ .code = .{ .symbol = .delete } },
            // tab
            .tab => .{ .code = .{ .symbol = .tab } },
            .key_btab => .{ .code = .{ .symbol = .tab }, .modifiers = .{ .shift = true } },
            // directional
            .cursor_up => .{ .code = .{ .symbol = .up } },
            .key_up => .{ .code = .{ .symbol = .up } },
            .cursor_down => .{ .code = .{ .symbol = .down } },
            .key_down => .{ .code = .{ .symbol = .down } },
            .cursor_left => .{ .code = .{ .symbol = .left } },
            .key_left => .{ .code = .{ .symbol = .left } },
            .cursor_right => .{ .code = .{ .symbol = .right } },
            .key_right => .{ .code = .{ .symbol = .right } },
            // shift-directional
            .key_sr => .{ .code = .{ .symbol = .up }, .modifiers = .{ .shift = true } },
            .key_sf => .{ .code = .{ .symbol = .down }, .modifiers = .{ .shift = true } },
            .key_sleft => .{ .code = .{ .symbol = .left }, .modifiers = .{ .shift = true } },
            .key_sright => .{ .code = .{ .symbol = .right }, .modifiers = .{ .shift = true } },
            // terminfos
            .key_beg => .{ .code = .{ .symbol = .begin } },
            .key_cancel => .{ .code = .{ .symbol = .cancel } },
            .key_catab => .{ .code = .{ .symbol = .clear_all_tabs } },
            .key_clear => .{ .code = .{ .symbol = .clear_screen } },
            .key_close => .{ .code = .{ .symbol = .close } },
            .key_command => .{ .code = .{ .symbol = .command } },
            .key_copy => .{ .code = .{ .symbol = .copy } },
            .key_create => .{ .code = .{ .symbol = .create } },
            .key_ctab => .{ .code = .{ .symbol = .clear_tab } },
            .key_dl => .{ .code = .{ .symbol = .delete_line } },
            .key_eic => .{ .code = .{ .symbol = .eic } },
            .key_end => .{ .code = .{ .symbol = .end } },
            .key_eol => .{ .code = .{ .symbol = .clear_to_eol } },
            .key_eos => .{ .code = .{ .symbol = .clear_to_eos } },
            .key_enter => .{ .code = .{ .symbol = .enter } },
            .key_exit => .{ .code = .{ .symbol = .exit } },
            .key_find => .{ .code = .{ .symbol = .find } },
            .key_help => .{ .code = .{ .symbol = .help } },
            .key_home => .{ .code = .{ .symbol = .home } },
            .key_ic => .{ .code = .{ .symbol = .insert_character } },
            .key_il => .{ .code = .{ .symbol = .insert_line } },
            .key_mark => .{ .code = .{ .symbol = .mark } },
            .key_message => .{ .code = .{ .symbol = .message } },
            .key_move => .{ .code = .{ .symbol = .move } },
            .key_next => .{ .code = .{ .symbol = .next } },
            .key_npage => .{ .code = .{ .symbol = .next_page } },
            .key_open => .{ .code = .{ .symbol = .open } },
            .key_options => .{ .code = .{ .symbol = .options } },
            .key_ppage => .{ .code = .{ .symbol = .prev_page } },
            .key_previous => .{ .code = .{ .symbol = .previous } },
            .key_print => .{ .code = .{ .symbol = .print } },
            .key_redo => .{ .code = .{ .symbol = .redo } },
            .key_reference => .{ .code = .{ .symbol = .reference } },
            .key_refresh => .{ .code = .{ .symbol = .refresh } },
            .key_replace => .{ .code = .{ .symbol = .replace } },
            .key_restart => .{ .code = .{ .symbol = .restart } },
            .key_resume => .{ .code = .{ .symbol = .resume_ } },
            .key_save => .{ .code = .{ .symbol = .save } },
            .key_select => .{ .code = .{ .symbol = .select } },
            .key_undo => .{ .code = .{ .symbol = .undo } },
            .key_suspend => .{ .code = .{ .symbol = .suspend_ } },
            else => blk: {
                std.log.scoped(.key_from_capability).err("capability '{s}' unimplemented", .{@tagName(cap)});
                break :blk .{ .code = .{ .symbol = .unknown } };
            },
        };
    }

    pub const FromCodepointError = error{UnknownC0} || std.mem.Allocator.Error;
    pub fn from_utf8_char(char: []const u8) FromCodepointError!Key {
        const log = std.log.scoped(.key_from_utf8_char);
        const cp = utf8.char_to_cp(char);

        // NUL, which by convention is C-Space
        if (cp == 0) {
            return .{
                .code = .{
                    .symbol = .space,
                },
                .modifiers = .{
                    .control = true,
                },
            };
        }

        // check for C0 range keys
        if (cp <= 0x20) {
            log.debug("key is in C0 range", .{});
            const sym: ?Symbol = switch (cp) {
                0x1b => .escape,
                0x08 => .backspace,
                0x09 => .tab,
                0x0d => .enter,
                0x20 => .space,
                else => null,
            };

            if (sym) |sym_u| {
                return .{
                    .code = .{
                        .symbol = sym_u,
                    },
                };
            }
        }

        // control alphas
        if (cp <= 26) {
            log.debug("key is a control alpha", .{});
            return .{
                .code = .{
                    // not 0x61, because ^A == 0x01
                    .unicode = cp + 0x60,
                },
                .modifiers = .{
                    .control = true,
                },
            };
        }

        // shifted keys
        if (utf8.cp_to_lower(cp)) |unshifted| {
            log.debug("0x{x} is shifted from 0x{x}", .{ cp, unshifted });
            return .{
                .code = .{
                    .unicode = unshifted,
                },
                .modifiers = .{
                    .shift = true,
                },
            };
        }

        // otherwise just use the given cp
        return .{
            .code = .{
                .unicode = cp,
            },
        };
    }
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
        log.debug("insert: '{s}' -> '{s}'", .{ std.fmt.fmtSliceEscapeLower(item.value), @tagName(item.capability) });
        try trie.insert_sequence(item.value, item.capability);
    }
    return trie;
}

fn read_input(tty: posix.fd_t, buf: []u8) posix.ReadError![]u8 {
    var stream = std.io.fixedBufferStream(buf);

    while (true) {
        var segment_buf: [16]u8 = undefined;
        const segment_len = try posix.read(tty, &segment_buf);

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

pub fn input_thread_entry(tty: posix.fd_t, trie: CapabilitiesTrie, event_queue: *EventQueue(InputEvent)) !void {
    const log = std.log.scoped(.input);

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

                log.debug("received capability: {s}", .{@tagName(cap)});

                try event_queue_var.put(.{ .key = Key.from_capability(cap) });

                input = input[longest.eaten..];
            } else {
                const char = utf8.recognize(input);
                input = input[char.len..];

                log.debug("received bytes: {x}", .{char});
                try event_queue_var.put(.{ .key = try Key.from_utf8_char(char) });
            }
        }
    }

    unreachable;
}
