const Grid = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const Grapheme = @import("../utf8.zig").Grapheme;

alloc: Allocator,
width: usize,
height: usize,
chars: []Grapheme,
dirty: bool,

pub fn init(alloc: Allocator, width: usize, height: usize) Allocator.Error!Grid {
    const size = width * height;
    var chars = try alloc.alloc(Grapheme, size);
    @memset(chars, std.mem.zeroes(Grapheme));

    return .{
        .alloc = alloc,
        .width = width,
        .height = height,
        .chars = chars,
        .dirty = true,
    };
}

pub fn deinit(self: Grid) void {
    self.alloc.free(self.chars);
}

pub fn get_row(self: *const Grid, row_idx: usize) []Grapheme {
    const offset = row_idx * self.width;
    return self.chars[offset .. offset + @as(usize, self.width)];
}

pub fn set_row_clear_after(self: *Grid, row_idx: usize, data: []const Grapheme) void {
    var row = self.get_row(row_idx);
    const len = @min(data.len, self.width);
    @memcpy(row[0..len], data[0..len]);
    @memset(row[len..], comptime std.mem.zeroes(Grapheme));
}

pub fn get_row_bytes(self: *Grid, row_idx: usize) []u8 {
    return std.mem.sliceAsBytes(self.get_row(row_idx));
}

// FIXME: this doesn't work if the grids are same size and x>0 and y>0
pub fn compose(noalias self: *Grid, noalias overlay: *const Grid, x: i32, y: i32) void {
    // shortcut if the grids don't overlap
    if (x >= @as(i32, @intCast(self.width)) or y >= @as(i32, @intCast(self.height)) or x + @as(i32, @intCast(overlay.width)) < 0 or y + @as(i32, @intCast(overlay.height)) < 0) {
        return;
    }

    // if x == -5, the first col we read from `overlay` is col 5
    // if x == 5, the first col we read is col 0
    const ol_col_offset: usize = @intCast(@max(-x, 0));
    const dst_col_offset: usize = @intCast(@max(x, 0));
    const ol_width: usize = overlay.width - ol_col_offset;
    // same reasoning as above
    const ol_row_offset: usize = @intCast(@max(-y, 0));
    const ol_height: usize = overlay.height - ol_row_offset;

    // iterate over rows
    for (ol_row_offset..ol_row_offset + ol_height) |src_row_idx| {
        const dst_row_idx: usize = @intCast(y + @as(i32, @intCast(src_row_idx)));
        const dst_row = self.get_row(dst_row_idx)[dst_col_offset .. dst_col_offset + ol_width];
        const src_row = overlay.get_row(src_row_idx)[ol_col_offset .. ol_col_offset + ol_width];
        @memcpy(dst_row, src_row);
    }
}

pub inline fn mark_dirty(self: *Grid) void {
    self.dirty = true;
}
