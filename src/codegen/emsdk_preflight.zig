//! emsdk activation preflight (labelle-assembler#492).
//!
//! The generated wasm `build.zig` links via the emsdk zig package's `emcc`, but
//! `b.dependency("emsdk", .{})` only fetches the emsdk *launcher* git repo — the
//! `emcc` under `upstream/emscripten/` does not exist until the toolchain is
//! downloaded with `./emsdk install latest && ./emsdk activate latest`. Without a
//! guard, a fresh `generate --platform wasm` + `zig build` fails with an opaque
//!
//!     error: ...upstream/emscripten/emcc file_hash FileNotFound
//!
//! which sent the last person on an hour-long debugging detour. This module emits
//! a small `ensureEmsdkActivated(b)` helper (plus its call site) into the
//! generated build.zig. The helper runs at configure time, BEFORE the emcc link
//! step, and — when the toolchain is missing — prints a clear, actionable message
//! naming the exact `cd <emsdk-pkg> && ./emsdk install latest && ./emsdk activate
//! latest` command, then exits. So the failure mode becomes a fix-it instruction
//! rather than a cache-hash riddle.
//!
//! Why an error (issue option (a)) and not system-emcc autodetection (option (b)):
//! the assembler does not own the emcc invocation — that lives in the backend's
//! `emLinkStep` / `post_wire` hook (a separate package). Redirecting it at a
//! system emcc + sysroot would require changing every backend hook, not the
//! generated build.zig. A clear error is the fix that is wholly the assembler's to
//! make, and it is enough to save the next person the debugging hour.

const std = @import("std");

/// Call site emitted inside the generated `build(b)` fn, just before the emcc
/// link step. Guards both the enum (`emccStep`/`emLinkStep`) and the manifest-v2
/// (`post_wire`) wasm paths — both resolve emcc through the same emsdk package.
pub const check_call = "    ensureEmsdkActivated(b);\n";

/// Top-level helper fn emitted into the generated build.zig. Leading blank line so
/// it separates cleanly from the preceding top-level decl.
pub const helper_fn =
    \\
    \\/// Preflight (labelle-assembler#492): fail early with an actionable message if
    \\/// the emsdk package's Emscripten toolchain has not been activated.
    \\///
    \\/// `b.dependency("emsdk", .{})` only fetches the emsdk *launcher* repo; `emcc`
    \\/// under `upstream/emscripten/` does not exist until the toolchain is installed
    \\/// and activated. Without this check the wasm build fails with an opaque
    \\/// `...upstream/emscripten/emcc file_hash FileNotFound`.
    \\fn ensureEmsdkActivated(b: *std.Build) void {
    \\    const io = b.graph.io;
    \\    const emsdk_dep = b.dependency("emsdk", .{});
    \\    const root = emsdk_dep.builder.build_root.path orelse return;
    \\    const emcc_path = b.pathJoin(&.{ root, "upstream", "emscripten", "emcc" });
    \\    std.Io.Dir.cwd().access(io, emcc_path, .{}) catch {
    \\        std.debug.print(
    \\            \\
    \\            \\[labelle] Emscripten (emsdk) is fetched but not activated — the wasm
    \\            \\build cannot find `emcc`. Download + activate the pinned toolchain once:
    \\            \\
    \\            \\    cd "{s}" && ./emsdk install latest && ./emsdk activate latest
    \\            \\
    \\            \\then re-run your `zig build` command. (labelle-assembler#492)
    \\            \\
    \\            \\
    \\        , .{root});
    \\        std.process.exit(1);
    \\    };
    \\}
    \\
;

/// Emit the guard call (inside the build fn, before the emcc link step).
pub fn emitCheckCall(w: anytype) !void {
    try w.writeAll(check_call);
}

/// Emit the top-level `ensureEmsdkActivated` helper fn.
pub fn emitHelperFn(w: anytype) !void {
    try w.writeAll(helper_fn);
}

// ── tests ──────────────────────────────────────────────────────────────────

test "check_call invokes the guard with the build object" {
    try std.testing.expectEqualStrings("    ensureEmsdkActivated(b);\n", check_call);
}

test "helper_fn names the exact activation command" {
    // The whole point of #492: the emitted message must name the actionable
    // `emsdk install latest && emsdk activate latest` command, keyed off the
    // resolved package root, so the reader can copy-paste the fix.
    try std.testing.expect(std.mem.indexOf(u8, helper_fn, "./emsdk install latest && ./emsdk activate latest") != null);
    try std.testing.expect(std.mem.indexOf(u8, helper_fn, "cd \"{s}\"") != null);
}

test "helper_fn checks the emcc path the opaque error complains about" {
    // The residual failure is `.../upstream/emscripten/emcc file_hash FileNotFound`;
    // the guard must probe exactly that path so it triggers on the same condition.
    try std.testing.expect(std.mem.indexOf(u8, helper_fn, "\"upstream\", \"emscripten\", \"emcc\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, helper_fn, "std.Io.Dir.cwd().access(io, emcc_path, .{})") != null);
}

test "helper_fn defines the fn the call site invokes" {
    try std.testing.expect(std.mem.indexOf(u8, helper_fn, "fn ensureEmsdkActivated(b: *std.Build) void") != null);
    try std.testing.expect(std.mem.indexOf(u8, check_call, "ensureEmsdkActivated(b)") != null);
}

test "emitCheckCall / emitHelperFn write their constants" {
    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    try emitCheckCall(&aw.writer);
    try emitHelperFn(&aw.writer);
    try std.testing.expect(std.mem.indexOf(u8, aw.written(), check_call) != null);
    try std.testing.expect(std.mem.indexOf(u8, aw.written(), "fn ensureEmsdkActivated") != null);
}

test "emitted helper fn parses as valid Zig" {
    // Wrap the helper in a minimal std-importing unit so `std.zig.Ast.parse`
    // sees a complete file — guards against a typo in the emitted source.
    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    try aw.writer.writeAll("const std = @import(\"std\");\n");
    try emitHelperFn(&aw.writer);
    const src = try std.testing.allocator.dupeZ(u8, aw.written());
    defer std.testing.allocator.free(src);
    var ast = try std.zig.Ast.parse(std.testing.allocator, src, .zig);
    defer ast.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), ast.errors.len);
}
