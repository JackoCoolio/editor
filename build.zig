const std = @import("std");
const Build = std.Build;
const Module = Build.Module;

fn file_exists(path: []const u8) bool {
    return if (std.fs.cwd().access(path, .{})) true else |_| false;
}

// Although this function looks imperative, note that its job is to
// declaratively construct a build graph that will be executed by an external
// runner.
pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // unicode module
    const unicode_data_module = blk: {
        // generate the source
        const run = b.addSystemCommand(&[_][]const u8{
            "python3",
            "data/gen.py",
            "data/", // the directory where the unicode data files live
        });
        const generated_source = run.addOutputFileArg("unicode.generated.zig");
        run.setName("generate unicode data source file");

        const module = b.createModule(Module.CreateOptions{
            .root_source_file = generated_source,
        });

        break :blk module;
    };

    // terminfo module
    const terminfo_module = blk: {
        const terminfo_main_path = "lib/terminfo/src/main.zig";
        std.debug.assert(file_exists(terminfo_main_path));
        break :blk b.createModule(Module.CreateOptions{
            .root_source_file = b.path(terminfo_main_path),
        });
    };

    // check
    {
        const check_step = b.step("check", "Check the app");

        const compile = b.addExecutable(.{
            .name = "editor",
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        });
        compile.root_module.addImport("terminfo", terminfo_module);
        compile.root_module.addImport("unicode", unicode_data_module);

        // note that we don't add an install artifact - we don't want zig to
        // actually build the executable and install it because that would take
        // too long

        check_step.dependOn(&compile.step);
    }

    // run
    {
        const step = b.step("run", "Run the app");

        const compile = b.addExecutable(.{
            .name = "editor",
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        });
        compile.root_module.addImport("terminfo", terminfo_module);
        compile.root_module.addImport("unicode", unicode_data_module);

        // tell compiler to install the generated executable
        b.installArtifact(compile);

        const run_cmd = b.addRunArtifact(compile);
        run_cmd.step.dependOn(b.getInstallStep());

        // pass any args to the built executable
        if (b.args) |args| {
            run_cmd.addArgs(args);
        }

        step.dependOn(&run_cmd.step);
    }

    // test
    {
        const step = b.step("test", "Run unit tests");

        const unit_tests = b.addTest(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        });
        unit_tests.root_module.addImport("terminfo", terminfo_module);
        unit_tests.root_module.addImport("unicode", unicode_data_module);

        const run_unit_tests = b.addRunArtifact(unit_tests);

        step.dependOn(&run_unit_tests.step);
    }

    // clean
    {
        const step = b.step("clean", "Clean up build and cache directories");

        const rm_cache = b.addRemoveDirTree(".zig-cache");
        step.dependOn(&rm_cache.step);

        const rm_out = b.addRemoveDirTree("zig-out");
        step.dependOn(&rm_out.step);
    }
}
