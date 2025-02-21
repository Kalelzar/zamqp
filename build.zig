const std = @import("std");

const Builder = struct {
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    opt: std.builtin.OptimizeMode,
    check_step: *std.Build.Step,
    zamqp: *std.Build.Module,

    fn init(b: *std.Build) Builder {
        const target = b.standardTargetOptions(.{});
        const opt = b.standardOptimizeOption(.{});

        const check_step = b.step("check", "");

        const zamqp = b.addModule("zamqp", .{
            .root_source_file = b.path("src/zamqp.zig"),
            .target = target,
            .optimize = opt,
        });

        return .{
            .b = b,
            .check_step = check_step,
            .target = target,
            .opt = opt,
            .zamqp = zamqp,
        };
    }

    fn addDependencies(
        self: *Builder,
        step: *std.Build.Step.Compile,
    ) void {
        _ = self;
        step.linkLibC();
        step.linkSystemLibrary("rabbitmq.4");
    }

    fn addExecutable(self: *Builder, name: []const u8, root_source_file: []const u8) *std.Build.Step.Compile {
        return self.b.addExecutable(.{
            .name = name,
            .root_source_file = self.b.path(root_source_file),
            .target = self.target,
            .optimize = self.opt,
        });
    }

    fn addStaticLibrary(self: *Builder, name: []const u8, root_source_file: []const u8) *std.Build.Step.Compile {
        return self.b.addStaticLibrary(.{
            .name = name,
            .root_source_file = self.b.path(root_source_file),
            .target = self.target,
            .optimize = self.opt,
        });
    }

    fn addTest(self: *Builder, name: []const u8, root_source_file: []const u8) *std.Build.Step.Compile {
        return self.b.addTest(.{
            .name = name,
            .root_source_file = self.b.path(root_source_file),
            .target = self.target,
            .optimize = self.opt,
        });
    }

    fn installAndCheck(self: *Builder, exe: *std.Build.Step.Compile) !void {
        const check_exe = try self.b.allocator.create(std.Build.Step.Compile);
        check_exe.* = exe.*;
        self.check_step.dependOn(&check_exe.step);
        self.b.installArtifact(exe);
    }
};

pub fn build(b: *std.Build) !void {
    var builder = Builder.init(b);

    const lib = builder.addStaticLibrary("zamqp", "src/zamqp.zig");
    builder.addDependencies(lib);
    try builder.installAndCheck(lib);
}
