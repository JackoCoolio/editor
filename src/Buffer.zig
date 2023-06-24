const std = @import("std");
const Allocator = std.mem.Allocator;
const Buffer = @This();

alloc: std.mem.Allocator,
data: []u8,
lines: [][]const u8,
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
    try self.update_lines();
}

fn update_lines(self: *Buffer) Allocator.Error!void {
    self.alloc.free(self.lines);
    var lines = std.ArrayList([]const u8).init(self.alloc);
    var line = self.data;
    var rem = self.data;
    var len: usize = 0;
    var skipped_crs: usize = 0;
    while (rem.len > 0) {
        if (rem[0] == '\n') {
            try lines.append(line[0 .. len - skipped_crs]);
            rem = rem[1..];
            line = rem;
            len = 0;
            skipped_crs = 0;
            continue;
        } else if (rem[0] == '\r') {
            skipped_crs += 1;
        } else {
            skipped_crs = 0;
        }

        len += 1;
        rem = rem[1..];
    }
    try lines.append(line);
    self.lines = try lines.toOwnedSlice();
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

    return try file.write(self.data);
}

pub const InitFromFileError = std.fs.File.OpenError || Allocator.Error;
/// Initializes a Buffer from the given file path.
pub fn init_from_file(alloc: Allocator, file_path: []const u8, read_only: bool) InitFromFileError!Buffer {
    const flags = .{
        .mode = .read_only,
    };

    const file = try std.fs.openFileAbsolute(file_path, flags);

    const data = file.readToEndAlloc(alloc, std.math.maxInt(usize)) catch unreachable;
    return try Buffer.init_from_data(alloc, data, if (read_only) null else file_path);
}

/// Initializes a Buffer from `data`. The data must be managed by the given
/// allocator.
pub fn init_from_data(alloc: Allocator, data: []u8, save_location: ?[]const u8) Allocator.Error!Buffer {
    var buffer: Buffer = .{
        .alloc = alloc,
        .data = data,
        .save_location = save_location,
        .lines = try alloc.alloc([]const u8, 0),
        .id = get_id(),
        .dirty = false,
    };

    try buffer.on_change();

    return buffer;
}
