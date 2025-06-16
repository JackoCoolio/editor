const std = @import("std");
const Allocator = std.mem.Allocator;
const Position = @import("Position.zig");
const Rope = @import("rope.zig").Rope;
const Buffer = @This();

alloc: std.mem.Allocator,
data: *Rope,
save_location: ?[]const u8,
id: Id,
dirty: bool,

pub const Id = u32;

var next_id: Id = 0;
fn get_id() Id {
    defer next_id += 1;
    return next_id;
}

fn on_change(self: *Buffer) Allocator.Error!void {
    self.dirty = true;
}

pub fn get_byte_offset_from_position(self: *const Buffer, position: Position) usize {
    @compileLog("deprecated");
    return self.data.get_index_from_cursor_pos(position);
}

pub fn insert_byte_at_offset(self: *Buffer, offset: usize, byte: u8) Allocator.Error!void {
    var data = std.ArrayList(u8).fromOwnedSlice(self.alloc, self.data);

    try data.insert(offset, byte);

    self.data = try data.toOwnedSlice();

    // TODO: optimize this. we don't need to recalculate line offsets if the byte
    // wasn't a newline. we also don't need to recalculate all of them, only split
    // the current line and increment the offsets of the following lines
    try self.on_change();
}

pub fn insert_byte_at_position(self: *Buffer, position: Position, byte: u8) Allocator.Error!void {
    const offset = self.get_byte_offset_from_position(position);
    try self.insert_byte_at_offset(offset, byte);
}

pub fn insert_bytes_at_position(self: *Buffer, position: Position, bytes: []const u8) Allocator.Error!void {
    const scope = std.log.scoped(.insert_bytes_at_position);
    scope.info("position: ({}, {})", .{ position.row, position.col });

    const index = self.data.get_index_from_cursor_pos(position) orelse unreachable;
    self.data = try self.data.insert(index, bytes);

    try self.on_change();
}

pub const SaveError = std.fs.File.OpenError || std.fs.File.WriteError;
/// Saves the buffer if not read-only. Returns the number of bytes that were
/// written if write-enabled.
pub fn save(self: *const Buffer, force: bool) SaveError!?usize {
    if (!self.dirty and !force) {
        return null;
    }
    const save_location = self.save_location orelse return null;
    return self.save_to(save_location);
}

/// Saves the buffer to the given location. Returns the number of bytes that were
/// written if write-enabled.
pub fn save_to(self: *const Buffer, save_location: []const u8) SaveError!usize {
    const flags = std.fs.File.OpenFlags{
        .mode = std.fs.File.OpenMode.write_only,
    };

    const file = try std.fs.openFileAbsolute(save_location, flags);
    defer {
        file.sync() catch {};
        file.close();
    }

    var bytes_written = 0;
    var chunks_iter = try self.data.chunks();
    while (try chunks_iter.next()) |chunk| {
        bytes_written += try file.write(chunk);
    }

    return bytes_written;
}

pub const InitFromFileError = std.fs.File.OpenError || Allocator.Error;
/// Initializes a Buffer from the given file path.
pub fn init_from_file(alloc: Allocator, file_path: []const u8, read_only: bool) InitFromFileError!Buffer {
    const flags = .{
        .mode = .read_only,
    };

    const file = try std.fs.cwd().openFile(file_path, flags);

    const data = file.readToEndAlloc(alloc, std.math.maxInt(usize)) catch unreachable;
    defer alloc.free(data);
    return try Buffer.init_from_data(alloc, data, if (read_only) null else file_path);
}

/// Initializes a Buffer from `data`. The data must be managed by the given
/// allocator.
pub fn init_from_data(alloc: Allocator, data: []const u8, save_location: ?[]const u8) Allocator.Error!Buffer {
    var buffer: Buffer = .{
        .alloc = alloc,
        .data = try Rope.init(alloc, data),
        .save_location = save_location,
        .id = get_id(),
        .dirty = false,
    };

    try buffer.on_change();

    return buffer;
}

pub fn deinit(self: Buffer) void {
    self.data.destroy();
}
