const std = @import("std");

/// Returns a slice to a string containing the Linux home directory path.
/// The slice should not be freed.
fn get_home_dir() ?std.fs.Dir {
    const path = std.os.getenv("HOME") orelse return null;
    return std.fs.openDirAbsolute(path, .{}) catch null;
}

/// Returns a slice to a string containing the path to the config directory.
/// The string does not end with a '/' character.
pub fn get_config_dir() ?std.fs.Dir {
    const home_dir = get_home_dir() orelse return null;
    return home_dir.makeOpenPath(".config/editor", .{}) catch null;
}
