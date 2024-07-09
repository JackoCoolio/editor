const std = @import("std");
const posix = std.posix;

/// Returns the current user's home directory if `$HOME` is set, otherwise null.
fn get_home_dir() ?std.fs.Dir {
    const path = posix.getenv("HOME") orelse return null;
    return std.fs.openDirAbsolute(path, .{}) catch null;
}

/// Returns `~/.config/editor` if `$HOME` is set, otherwise null.
pub fn get_config_dir() ?std.fs.Dir {
    const home_dir = get_home_dir() orelse return null;
    return home_dir.makeOpenPath(".config/editor", .{}) catch null;
}
