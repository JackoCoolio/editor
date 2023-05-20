const std = @import("std");

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

// Although this function looks imperative, note that its job is to
// declaratively construct a build graph that will be executed by an external
// runner.
pub fn build(b: *std.Build) !void {
    // Standard target options allows the person running `zig build` to choose
    // what target to build for. Here we do not override the defaults, which
    // means any target is allowed, and the default is native. Other options
    // for restricting supported target set are available.
    const target = b.standardTargetOptions(.{});

    // Standard optimization options allow the person running `zig build` to select
    // between Debug, ReleaseSafe, ReleaseFast, and ReleaseSmall. Here we do not
    // set a preferred release mode, allowing the user to decide how to optimize.
    const optimize = b.standardOptimizeOption(.{});

    const module = b.createModule(std.build.CreateModuleOptions{
        .source_file = std.build.FileSource{
            .path = "vendor/terminfo/src/main.zig",
        },
    });

    const exe = b.addExecutable(.{
        .name = "editor",
        // In this case the main source file is merely a path, however, in more
        // complicated build scripts, this could be a generated file.
        .root_source_file = .{ .path = "src/main.zig" },
        .target = target,
        .optimize = optimize,
    });
    {
        exe.linkLibC();
        exe.addModule("terminfo", module);

        const terminfo_dirs = getTerminfoDirs(b.allocator);
        exe.defineCMacro("TERMINFO_DIRS", terminfo_dirs);
        exe.addCSourceFile("vendor/unibilium/unibilium.c", &[_][]const u8{});
        exe.addCSourceFile("vendor/unibilium/uninames.c", &[_][]const u8{});
        exe.addCSourceFile("vendor/unibilium/uniutil.c", &[_][]const u8{});
    }

    // This declares intent for the executable to be installed into the
    // standard location when the user invokes the "install" step (the default
    // step when running `zig build`).
    b.installArtifact(exe);

    // This *creates* a Run step in the build graph, to be executed when another
    // step is evaluated that depends on it. The next line below will establish
    // such a dependency.
    const run_cmd = b.addRunArtifact(exe);

    // By making the run step depend on the install step, it will be run from the
    // installation directory rather than directly from within the cache directory.
    // This is not necessary, however, if the application depends on other installed
    // files, this ensures they will be present and in the expected location.
    run_cmd.step.dependOn(b.getInstallStep());

    // This allows the user to pass arguments to the application in the build
    // command itself, like this: `zig build run -- arg1 arg2 etc`
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    // This creates a build step. It will be visible in the `zig build --help` menu,
    // and can be selected like this: `zig build run`
    // This will evaluate the `run` step rather than the default, which is "install".
    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    // Creates a step for unit testing. This only builds the test executable
    // but does not run it.
    const unit_tests = b.addTest(.{
        .root_source_file = .{ .path = "src/main.zig" },
        .target = target,
        .optimize = optimize,
    });

    const run_unit_tests = b.addRunArtifact(unit_tests);

    // Similar to creating the run step earlier, this exposes a `test` step to
    // the `zig build --help` menu, providing a way for the user to request
    // running the unit tests.
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);
}
