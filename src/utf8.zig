const std = @import("std");
const Allocator = std.mem.Allocator;

// this is created by data/gen.py and is part of the build process
const unicode = @import("unicode");

const max_combining_characters = 3;
/// A UTF-8 character with combining characters. Null terminated.
pub const Grapheme = [(max_combining_characters + 1) * 4 + 1]u8;

/// Determines the number of bytes that the given UTF-8 character requires.
///
/// Defaults to 1 if invalid.
pub fn char_len(bytes: []const u8) u3 {
    const byte = bytes[0];
    if ((byte & 0b111_00000) ^ 0b110_00000 == 0) {
        return 2;
    } else if ((byte & 0b1111_0000) ^ 0b1110_0000 == 0) {
        return 3;
    } else if ((byte & 0b11111_000) ^ 0b11110_000 == 0) {
        return 4;
    }

    return 1;
}

/// Determines the number of bytes the given unicode codepoint would require in
/// order to be encoded as UTF-8.
///
/// Guaranteed to be between 1 and 4, inclusive.
///
/// Defaults to 1 if invalid.
pub fn cp_len(cp: Codepoint) u3 {
    if (cp <= 0x007F) {
        return 1;
    } else if (cp <= 0x07FF) {
        return 2;
    } else if (cp <= 0xFFFF) {
        return 3;
    } else if (cp <= 0x10FFFF) {
        return 4;
    }

    return 1;
}

test "cp_len" {
    {
        // "a"
        const cp = 0x61;
        try std.testing.expectEqual(@as(u3, 1), cp_len(cp));
    }

    {
        // "ă"
        const cp = 0x103;
        try std.testing.expectEqual(@as(u3, 2), cp_len(cp));
    }

    {
        // "†"
        const cp = 0x2020;
        try std.testing.expectEqual(@as(u3, 3), cp_len(cp));
    }

    {
        // "😀"
        const cp = 0x1F600;
        try std.testing.expectEqual(@as(u3, 4), cp_len(cp));
    }
}

/// Recognizes a UTF-8 character from the given bytes.
/// Defaults to the first byte if invalid.
pub fn recognize(bytes: []const u8) []const u8 {
    const expected_len = char_len(bytes);

    // invalid codepoint
    if (bytes.len < expected_len) {
        return bytes[0..1];
    }

    // check that each continue byte begins with 0b10
    for (bytes[1..expected_len]) |byte| {
        if ((byte & 0b11_000000) ^ 0b10_000000 != 0) {
            return bytes[0..1];
        }
    }
    return bytes[0..expected_len];
}

/// Recognizes a UTF-8 grapheme.
/// Returns at least the first byte.
pub fn recognize_grapheme(bytes: []const u8) []const u8 {
    var len = recognize(bytes).len;
    var rem = bytes[len..];
    while (rem.len > 0) {
        const comb = recognize(rem);
        const cp = char_to_cp(comb);
        if (is_combining_char(cp)) {
            len += comb.len;
            rem = rem[comb.len..];
        } else {
            break;
        }
    }

    return bytes[0..len];
}

pub fn grapheme_from_bytes(bytes: []const u8) Grapheme {
    var grapheme = std.mem.zeroes(Grapheme);
    const size = @min(bytes.len, @sizeOf(Grapheme) - 1);
    @memcpy(grapheme[0..size], bytes[0..size]);

    // this shouldn't be necessary, but do it anyway
    grapheme[@sizeOf(Grapheme) - 1] = 0;

    return grapheme;
}

pub const Graphemes = struct {
    rem: []const u8,

    pub fn from(bytes: []const u8) Graphemes {
        return .{
            .rem = bytes,
        };
    }

    pub fn next(self: *Graphemes) ?Grapheme {
        if (self.rem.len == 0) {
            return null;
        }

        const grapheme_s = recognize_grapheme(self.rem);
        const graph = grapheme_from_bytes(grapheme_s);
        self.rem = self.rem[grapheme_s.len..];

        return graph;
    }

    pub fn into_bytes(self: *Graphemes, alloc: Allocator) Allocator.Error![]u8 {
        var bytes = std.ArrayList(u8).init(alloc);
        while (self.next()) |grapheme| {
            try bytes.appendSlice(&grapheme);
        }
        return bytes.toOwnedSlice();
    }

    pub fn into_slice(self: *Graphemes, alloc: Allocator) Allocator.Error![]Grapheme {
        var graphemes = std.ArrayList(Grapheme).init(alloc);
        while (self.next()) |grapheme| {
            try graphemes.append(grapheme);
        }
        return graphemes.toOwnedSlice();
    }
};

test "recognize" {
    {
        const str = "Ḿ";
        try std.testing.expectEqualSlices(u8, "\xe1\xb8\xbe", recognize(str));
    }

    {
        const str = "a";
        try std.testing.expectEqualSlices(u8, "a", recognize(str));
    }

    {
        const str = "aḾ";
        try std.testing.expectEqualSlices(u8, "a", recognize(str));
    }

    {
        const str = "Ḿa";
        try std.testing.expectEqualSlices(u8, "\xe1\xb8\xbe", recognize(str));
    }
}

const Codepoint = u21;

pub fn char_to_cp(bytes: []const u8) Codepoint {
    // ascii
    if (bytes[0] < 0b1000_0000) {
        return @as(Codepoint, bytes[0]);
    }

    const char = recognize(bytes);
    // zig fmt: off
    return switch (char.len) {
        1 => @as(Codepoint, (char[0] & 0b0_1111111)),
        2 => @as(Codepoint, @as(u21, char[0] & 0b000_11111) <<  6 | @as(u21, char[1] & 0b00_111111)),
        3 => @as(Codepoint, @as(u21, char[0] & 0b0000_1111) << 12 | @as(u21, char[1] & 0b00_111111) <<  6 | @as(u21, char[2] & 0b00_111111)),
        4 => @as(Codepoint, @as(u21, char[0] & 0b00000_111) << 18 | @as(u21, char[1] & 0b00_111111) << 12 | @as(u21, char[2] & 0b00_111111) << 6 | @as(u21, char[3] & 0b00_111111)),
        else => unreachable,
    };
}

/// Returns an allocated buffer with the UTF-8 encoding of the given Unicode
/// codepoint.
/// The returned slice is guaranteed to be between 1 and 4 bytes, inclusive.
pub fn cp_to_char(buf: *[4]u8, cp: Codepoint) []u8 {
    const len = cp_len(cp);
    std.debug.assert(len >= 1 and len <= 4);

    @memset(buf, 0);

    // handle ascii case
    if (len == 1) {
        buf[0] = @as(u8, @truncate(cp)) & 0b01111111;
        return buf[0..1];
    }

    var i: usize = len;
    var cp_shifted = cp;
    while (i > 1) { // don't do first byte yet, because it depends on the length
        i -= 1;

        buf[i] = 0b1000_0000 | (@as(u8, @truncate(cp_shifted)) & 0b0011_1111);
        cp_shifted >>= 6;
    }

    // do the first byte now
    // we don't need to handle len==1, we return early in that case
    buf[0] = switch (len) {
        2 => 0b110_00000 | (@as(u8, @truncate(cp_shifted)) & 0b000_11111),
        3 => 0b1110_0000 | (@as(u8, @truncate(cp_shifted)) & 0b0000_1111),
        4 => 0b11110_000 | (@as(u8, @truncate(cp_shifted)) & 0b00000_111),
        else => unreachable,
    };

    return buf[0..len];
}

test "char_to_cp" {
    // 1 byte (ascii)
    {
        const char = "a";
        try std.testing.expectEqual(@as(u21, 0x0061), char_to_cp(char));
    }

    // 2 bytes
    {
        const char = "ă";
        try std.testing.expectEqual(@as(u21, 0x0103), char_to_cp(char));
    }

    // 3 bytes
    {
        const char = "†";
        try std.testing.expectEqual(@as(u21, 0x2020), char_to_cp(char));
    }

    // 4 bytes
    {
        const char = "😀";
        try std.testing.expectEqual(@as(u21, 0x1F600), char_to_cp(char));
    }
}

fn search_entries(entries: []const unicode.Entry, key: Codepoint) ?Codepoint {
    var start: usize = 0;
    var end: usize = entries.len - 1;
    while (start <= end) {
        const mid = (start + end) / 2;
        const entry = entries[mid];
        if (key == entry.from) {
            return entry.to;
        } else if (key < entry.from) {
            end = mid - 1;
        } else { // if (key > entry.from)
            start = mid + 1;
        }
    }
    return null;
}

inline fn is_combining_char(cp: Codepoint) bool {
    return is_in_interval_table(&unicode.is_combining_char_table, cp);
}

test "is_combining_char" {
    try std.testing.expect(is_combining_char(0x0300));
    try std.testing.expect(is_combining_char(0x0367));
    try std.testing.expect(is_combining_char(0x036F));
    try std.testing.expect(is_combining_char(0x1E94A));
}

fn is_in_interval_table(table: []const unicode.Interval, key: Codepoint) bool {
    var start: usize = 0;
    var end: usize = table.len - 1;

    if (key < table[0].first) {
        return false;
    }

    if (key > table[table.len - 1].last) {
        return false;
    }

    while (start <= end) {
        const mid = (start + end) / 2;
        const interval = table[mid];
        if (key < interval.first) {
            end = mid - 1;
        } else if (key > interval.last) {
            start = mid + 1;
        } else {
            return true;
        }
    }

    return false;
}

pub const Case = enum(u1) {
    lower,
    upper,
};

/// Changes the case of the given UTF-8 string.
/// Returns an allocated buffer with the new string.
pub fn change_case(alloc: Allocator, s: []const u8, case: Case) Allocator.Error![]u8 {
    var rem = s;
    var buf = try std.ArrayList(u8).initCapacity(alloc, s.len);

    while (rem.len > 0) {
        const char = recognize(rem);
        rem = rem[char.len..];

        const cp = char_to_cp(char);
        const new_cp = switch (case) {
            .upper => cp_to_upper(cp),
            .lower => cp_to_lower(cp),
        } orelse cp;
        var char_buf: [4]u8 = undefined;
        const new_char = cp_to_char(&char_buf, new_cp);
        try buf.appendSlice(new_char);
    }

    return try buf.toOwnedSlice();
}

test "change_case.upper" {
    const alloc = std.testing.allocator;

    {
        const input = "foo";
        const output = try change_case(alloc, input, .upper);
        defer alloc.free(output);
        try std.testing.expectEqualSlices(u8, "FOO", output);
    }

    {
        const input = "ăfoo";
        const output = try change_case(alloc, input, .upper);
        defer alloc.free(output);
        try std.testing.expectEqualSlices(u8, "ĂFOO", output);
    }
}

const MAX_ASCII = 127;
pub fn cp_to_upper(cp: Codepoint) ?Codepoint {
    if (cp <= MAX_ASCII) {
        const upper = @as(Codepoint, std.ascii.toUpper(@truncate(cp)));
        return if (cp == upper) null else upper;
    }

    return search_entries(&unicode.to_upper_table, cp);
}

pub fn cp_to_lower(cp: Codepoint) ?Codepoint {
    if (cp <= MAX_ASCII) {
        const lower = @as(Codepoint, std.ascii.toLower(@truncate(cp)));
        return if (cp == lower) null else lower;
    }

    return search_entries(&unicode.to_lower_table, cp);
}

