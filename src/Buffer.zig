const std = @import("std");
const Allocator = std.mem.Allocator;
const Buffer = @This();

alloc: std.mem.Allocator,
data: []u8,
save_location: ?[]const u8,
id: Id,
dirty: bool,

pub const Id = u32;

var next_id: Id = 0;

fn get_id() Id {
    defer next_id += 1;
    return next_id;
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

/// Initializes a Buffer from the given file path.
pub fn init_from_file(alloc: Allocator, file_path: []const u8, read_only: bool) std.fs.File.OpenError!Buffer {
    const flags = .{
        .mode = .read_only,
    };

    const file = try std.fs.openFileAbsolute(file_path, flags);

    const data = file.readToEndAlloc(alloc, std.math.maxInt(usize)) catch unreachable;
    return Buffer.init_from_data(alloc, data, if (read_only) null else file_path);
}

/// Initializes a Buffer from `data`. The data must be managed by the given
/// allocator.
pub fn init_from_data(alloc: Allocator, data: []u8, save_location: ?[]const u8) Buffer {
    return .{
        .alloc = alloc,
        .data = data,
        .save_location = save_location,
        .id = get_id(),
        .dirty = false,
    };
}
