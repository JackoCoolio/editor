const std = @import("std");
const Build = std.Build;
const Module = Build.Module;

/// Returns a terminfo directory, or null.
fn getTerminfoDir(allocator: std.mem.Allocator, cmd: []const u8) ?[]u8 {
    const result = std.ChildProcess.exec(.{
        .allocator = allocator,
        .argv = &[_][]const u8{ cmd, "--terminfo-dirs" },
    }) catch return null;

    return result.stdout[0 .. result.stdout.len - 1];
}

/// Returns a colon-separated list of terminfo directories for use in
/// `unibilium`'s `TERMINFO_DIRS` macro.
/// This function attempts to match the behavior of `unibilium`'s Makefile.
/// Note: the returned string is surrounded by double quotes.
fn getTerminfoDirs(allocator: std.mem.Allocator) []const u8 {
    var dirs = std.ArrayList([]const u8).init(allocator);

    const commands = comptime [_][]const u8{
        "ncursesw6-config",
        "ncurses6-config",
        "ncursesw5-config",
        "ncurses5-config",
    };

    // space for both dbl quotes
    var len: usize = 2;

    inline for (commands) |cmd| {
        if (getTerminfoDir(allocator, cmd)) |dir| {
            dirs.append(dir) catch unreachable;
            // add space for directory string plus a colon
            len += dir.len + 1;
        }
    }

    if (len != 2) {
        len -= 1;
    }

    var out_buf = allocator.alloc(u8, len) catch unreachable;

    // set double quotes
    out_buf[0] = '"';
    out_buf[len - 1] = '"';

    var i: usize = 1;
    for (dirs.items, 0..) |dir, dir_i| {
        @memcpy(out_buf[i .. i + dir.len], dir);
        if (dir_i != dirs.items.len - 1) {
            out_buf[i + dir.len] = ':';
            i += 1;
        }
        i += dir.len;
    }

    // free dir strings
    for (dirs.items) |dir| {
        allocator.free(dir);
    }

    return out_buf;
}

const unicode_generated_file = "data/unicode.generated.zig";

fn file_exists(path: []const u8) bool {
    return if (std.fs.cwd().access(path, .{})) true else |_| false;
}

// Although this function looks imperative, note that its job is to
// declaratively construct a build graph that will be executed by an external
// runner.
pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const terminfo_main_path = "lib/terminfo/src/main.zig";
    std.debug.assert(file_exists(terminfo_main_path));
    const terminfo_module = b.createModule(Module.CreateOptions{
        .root_source_file = b.path(terminfo_main_path),
    });

    const gen = b.addSystemCommand(&[_][]const u8{ "python3", "data/gen.py", "data/", unicode_generated_file });
    const unicode_data_module = b.createModule(Module.CreateOptions{
        .root_source_file = b.path(unicode_generated_file),
    });

    const exe = b.addExecutable(.{
        .name = "editor",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    exe.root_module.addImport("terminfo", terminfo_module);
    exe.root_module.addImport("unicode", unicode_data_module);
    exe.step.dependOn(&gen.step);

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);

    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    const unit_tests = b.addTest(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    unit_tests.root_module.addImport("terminfo", terminfo_module);
    unit_tests.root_module.addImport("unicode", unicode_data_module);

    const run_unit_tests = b.addRunArtifact(unit_tests);

    // Similar to creating the run step earlier, this exposes a `test` step to
    // the `zig build --help` menu, providing a way for the user to request
    // running the unit tests.
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);
}
