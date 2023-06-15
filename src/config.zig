const std = @import("std");

pub const get_config_dir = switch (@import("builtin").os.tag) {
    .linux => @import("config/linux.zig").get_config_dir,
    .windows => @compileError("windows support coming soon"),
    else => @compileError("unsupported operating system"),
};
