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
//!
//! EMSDK-aware (labelle-studio#25 / #535 Option A): the backend hooks now honour a
//! managed `EMSDK` env (cli#283 layout `<EMSDK>/upstream/emscripten/emcc`) — when
//! set they link via that emcc instead of the zig-pkg dep. So the preflight would
//! WRONGLY fail if `EMSDK` selects a working managed toolchain while the zig-pkg
//! emsdk happens to be un-activated. The emitted helper therefore short-circuits:
//! if `EMSDK` is set AND its `upstream/emscripten/emcc` exists, it passes. Only
//! when there is no usable managed toolchain does it fall through to the zig-pkg
//! activation check + the #492 message — so the EMSDK-unset behaviour (and that
//! message) is unchanged. `managedToolchainReady` below is a pure mirror of the
//! decision, unit-testable without a real build. NOTE: this must ship together
//! with (or after) the backend hook change — an EMSDK-set + un-activated-zig-pkg
//! project would otherwise fail with the opaque FileNotFound the check exists to
//! prevent.

const std = @import("std");

/// Pure predicate mirroring the managed-toolchain branch the emitted helper
/// runs at the consumer's configure time — factored out so the decision is
/// unit-testable without a real build, a real emsdk install, or the env.
///
/// Returns `true` (⇒ preflight passes, skip the zig-pkg activation check) iff
/// `EMSDK` is set, non-empty, and `<EMSDK>/upstream/emscripten/emcc` exists per
/// `probe`. Otherwise `false` ⇒ the caller falls through to the zig-pkg check
/// (which emits the #492 message when that too is un-activated). A bogus/empty
/// `EMSDK`, or one whose managed emcc is missing, never silently passes.
///
/// `probe` is injected so tests can supply a fake filesystem; the emitted helper
/// uses `std.Io.Dir.cwd().access` for the real probe.
pub fn managedToolchainReady(
    emsdk_env: ?[]const u8,
    context: anytype,
    probe: *const fn (@TypeOf(context), []const u8) bool,
) bool {
    const root = emsdk_env orelse return false;
    if (root.len == 0) return false;
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const managed_emcc = std.fmt.bufPrint(
        &buf,
        "{s}/upstream/emscripten/emcc",
        .{root},
    ) catch return false;
    return probe(context, managed_emcc);
}

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
    \\    // Managed toolchain (labelle cli#283): when `EMSDK` is set and its
    \\    // `upstream/emscripten/emcc` exists, the backend hook links via that
    \\    // managed emcc, so the zig-pkg emsdk need not be activated. Pass.
    \\    if (b.graph.environ_map.get("EMSDK")) |emsdk_root| {
    \\        if (emsdk_root.len != 0) {
    \\            const managed_emcc = b.pathJoin(&.{ emsdk_root, "upstream", "emscripten", "emcc" });
    \\            if (std.Io.Dir.cwd().access(io, managed_emcc, .{})) |_| return else |_| {}
    \\        }
    \\    }
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

// ── EMSDK-aware branch (labelle-studio#25 / #535 Option A) ───────────────────

const ProbeCtx = struct {
    /// The single path this fake filesystem reports as existing (null ⇒ nothing
    /// exists). Set by each test to the managed emcc it expects to be probed.
    present: ?[]const u8 = null,

    fn exists(self: ProbeCtx, path: []const u8) bool {
        const p = self.present orelse return false;
        return std.mem.eql(u8, p, path);
    }
};

test "managedToolchainReady: unset EMSDK never passes (⇒ zig-pkg check + #492)" {
    const ctx = ProbeCtx{ .present = "irrelevant" };
    try std.testing.expect(!managedToolchainReady(null, ctx, ProbeCtx.exists));
}

test "managedToolchainReady: empty EMSDK never passes" {
    const ctx = ProbeCtx{ .present = "/upstream/emscripten/emcc" };
    try std.testing.expect(!managedToolchainReady("", ctx, ProbeCtx.exists));
}

test "managedToolchainReady: EMSDK set + managed emcc exists ⇒ passes" {
    // Probes exactly the cli#283 managed layout `<EMSDK>/upstream/emscripten/emcc`.
    const ctx = ProbeCtx{ .present = "/opt/emsdk/upstream/emscripten/emcc" };
    try std.testing.expect(managedToolchainReady("/opt/emsdk", ctx, ProbeCtx.exists));
}

test "managedToolchainReady: EMSDK set but managed emcc missing ⇒ falls through" {
    // A bogus EMSDK (no emcc under it) must NOT silently pass — the caller then
    // runs the zig-pkg activation check rather than assuming a managed toolchain.
    const ctx = ProbeCtx{ .present = null };
    try std.testing.expect(!managedToolchainReady("/opt/emsdk", ctx, ProbeCtx.exists));
}

test "emitted helper honours a managed EMSDK before the zig-pkg check" {
    // The EMSDK branch must appear, look up `EMSDK` from the build graph env, probe
    // the managed `upstream/emscripten/emcc`, and short-circuit — all BEFORE the
    // zig-pkg `b.dependency("emsdk", .{})` resolution.
    const emsdk_branch = "b.graph.environ_map.get(\"EMSDK\")";
    const managed_probe = "std.Io.Dir.cwd().access(io, managed_emcc, .{})";
    try std.testing.expect(std.mem.indexOf(u8, helper_fn, emsdk_branch) != null);
    try std.testing.expect(std.mem.indexOf(u8, helper_fn, managed_probe) != null);
    const branch_idx = std.mem.indexOf(u8, helper_fn, emsdk_branch).?;
    const zigpkg_idx = std.mem.indexOf(u8, helper_fn, "const emsdk_dep = b.dependency(\"emsdk\", .{})").?;
    try std.testing.expect(branch_idx < zigpkg_idx);
}

test "emitted #492 message is byte-identical (EMSDK-unset path unchanged)" {
    // The whole point of #492 must survive the EMSDK-aware refactor untouched:
    // the exact actionable message block, verbatim.
    const msg =
        "        std.debug.print(\n" ++
        "            \\\\\n" ++
        "            \\\\[labelle] Emscripten (emsdk) is fetched but not activated — the wasm\n" ++
        "            \\\\build cannot find `emcc`. Download + activate the pinned toolchain once:\n" ++
        "            \\\\\n" ++
        "            \\\\    cd \"{s}\" && ./emsdk install latest && ./emsdk activate latest\n" ++
        "            \\\\\n" ++
        "            \\\\then re-run your `zig build` command. (labelle-assembler#492)\n" ++
        "            \\\\\n" ++
        "            \\\\\n" ++
        "        , .{root});\n" ++
        "        std.process.exit(1);";
    try std.testing.expect(std.mem.indexOf(u8, helper_fn, msg) != null);
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
