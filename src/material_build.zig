//! Staged beside generated build.zig. Shader compilation belongs to Zig's graph.
const std = @import("std");
const schema = @import("material_schema.zig");
pub const Input = struct { name: []const u8, json: []const u8 };
/// `glsl_profile` is the toolchain's (`material_schema.Toolchain`), chosen at
/// generate time from the project's bgfx pin together with `material_shaderc`.
pub fn create(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, core: *std.Build.Module, inputs: []const Input, platform: []const u8, glsl_profile: []const u8) *std.Build.Module {
    // Always a HOST executable, even for Android, Emscripten and iOS.
    const tool = b.dependency("material_shaderc", .{ .target = b.graph.host, .with_shaderc = true });
    const override = b.option([]const u8, "shaderc", "Override the pinned host shaderc executable") orelse b.graph.environ_map.get("LABELLE_SHADERC");
    if (override) |exe| if (!std.fs.path.isAbsolute(exe)) {
        std.debug.panic("shaderc override must be an absolute host executable path: {s}", .{exe});
    };
    const files = b.addWriteFiles();
    const varying = b.addWriteFiles().add("sprite-varying.def.sc", schema.varying);
    var source = std.Io.Writer.Allocating.init(b.allocator);
    source.writer.writeAll("comptime { if (!@hasDecl(@import(\"labelle-core\").backend_contract, \"MATERIAL_CONTRACT_VERSION\") or @import(\"labelle-core\").backend_contract.MATERIAL_CONTRACT_VERSION != 2) @compileError(\"game-owned materials require material contract v2\"); }\n") catch @panic("OOM");
    for (inputs) |input| {
        if (!schema.materialName(input.name)) std.debug.panic("materials/{s}: invalid or reserved material name", .{input.name});
        const parsed = schema.parse(b.allocator, input.json) catch |err| std.debug.panic("materials/{s}/material.json: {s}", .{ input.name, @errorName(err) });
        const d = parsed.value;
        var has_required = false;
        const required: schema.Target = if (std.mem.eql(u8, platform, "wasm") or std.mem.eql(u8, platform, "android")) .essl else if (target.result.os.tag.isDarwin()) .mtl else .spv;
        for (d.targets) |variant| if (variant == required) {
            has_required = true;
        };
        if (!has_required and !std.mem.eql(u8, platform, "tests")) std.debug.panic("materials/{s}/material.json: target requires '{s}' in targets", .{ input.name, @tagName(required) });
        schema.render(&source.writer, input.name, d) catch @panic("OOM");
        for (d.targets) |variant| {
            const run = if (override) |exe| b.addSystemCommand(&.{exe}) else b.addRunArtifact(tool.artifact("shaderc"));
            run.step.name = b.fmt("shader {s} ({s})", .{ input.name, @tagName(variant) });
            if (override) |exe| run.addFileInput(.{ .cwd_relative = exe });
            run.addArgs(&.{ "--type", "fragment", "--platform", schema.platform(variant, platform), "-p", schema.profile(variant, glsl_profile), "-O", "3", "-f" });
            run.addFileArg(b.path(b.fmt("materials/{s}/{s}", .{ input.name, d.fragment })));
            run.addArg("--varyingdef");
            run.addFileArg(varying);
            run.addArg("-i");
            run.addDirectoryArg(tool.path("shaders"));
            run.addArg("-i");
            run.addDirectoryArg(b.path(b.fmt("materials/{s}", .{input.name})));
            run.addArg("-i");
            run.addDirectoryArg(b.path("materials"));
            // shaderc's include search must invalidate the cache as well as its -f input.
            trackTree(b, run, tool.path("shaders"), false);
            trackTree(b, run, b.path("materials"), true);
            run.addArg("-o");
            const out_name = b.fmt("{s}.{s}.bin", .{ input.name, @tagName(variant) });
            _ = files.addCopyFile(run.addOutputFileArg(out_name), out_name);
        }
    }
    return b.createModule(.{ .root_source_file = files.add("materials.zig", source.written()), .target = target, .optimize = optimize, .imports = &.{.{ .name = "labelle-core", .module = core }} });
}
fn trackTree(b: *std.Build, run: *std.Build.Step.Run, path: std.Build.LazyPath, validate: bool) void {
    const io = b.graph.io;
    var dir = std.Io.Dir.cwd().openDir(io, path.getPath(b), .{ .iterate = true }) catch |err| std.debug.panic("shader include directory: {s}", .{@errorName(err)});
    defer dir.close(io);
    var walker = dir.walk(b.allocator) catch @panic("OOM");
    defer walker.deinit();
    while (walker.next(io) catch |err| std.debug.panic("shader include scan: {s}", .{@errorName(err)})) |entry| {
        if (entry.kind == .sym_link) std.debug.panic("shader package cannot contain symlinks: {s}", .{entry.path});
        if (entry.kind == .file) {
            run.addFileInput(path.path(b, entry.path));
            if (validate) {
                const bytes = dir.readFileAlloc(io, entry.path, b.allocator, .limited(1024 * 1024)) catch |err| std.debug.panic("shader source {s}: {s}", .{ entry.path, @errorName(err) });
                schema.validateIncludes(bytes) catch |err| std.debug.panic("shader source {s}: {s}; includes must be package-local literal paths", .{ entry.path, @errorName(err) });
            }
        }
    }
}
