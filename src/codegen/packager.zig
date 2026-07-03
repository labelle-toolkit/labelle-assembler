//! Shared platform-packager (epic #453 item 3, PR 4 — see
//! `docs/design/manifest-v2-build-graph.md` §3/§6/§7).
//!
//! This module is the ONE place that knows how to emit a platform's *packaging*
//! step. It is driven by a v2 manifest's `BackendManifestV2.Package` recipe
//! (`.platforms[p].package`): `.binary` (desktop — no packaging), `.apk`
//! (Android — the apk-staging copy + `zip` + `apksigner` shell-outs), and
//! `.web` (wasm — the emcc install/run step wiring).
//!
//! ## Why it exists — the packaging text, factored out
//!
//! The v2 codegen (`manifest_v2_splice.zig`) has no platform enum to switch on —
//! it works off the typed `Package` recipe — so it needs a shared entry point
//! that turns a `Package` into the exact packaging text. That is `emitPackage`
//! below.
//!
//! ## The packager OWNS the packaging text (#461)
//!
//! The packaging text is held here as packager-OWNED fixtures (`@embedFile` of
//! `templates/package_apk.txt` / `templates/package_web.txt`). These were captured
//! byte-identical to the former enum `.android_package` / `.wasm_footer` template
//! sections (validated by the golden cells `bgfx_v2_android.build.zig` /
//! `sokol_wasm_v2.build.zig`); those enum sections were deleted with the rest of
//! the v1/enum path (#461), so these fixtures are now the SOLE source of truth.
//!
//! Note on the `.web` fixture: it carries not only the emcc install/run step but
//! also the trailing build-function close and the `overrideImport` helper def that
//! sat after `.wasm_footer` in the old template — the `renderWasmFooterV2` +
//! packager split reproduces exactly the same bytes. (The `.apk` fixture carries
//! only the packaging block, ending before the footer.)

const std = @import("std");
const manifest_v2 = @import("manifest_v2.zig");

const Package = manifest_v2.BackendManifestV2.Package;

/// The Android apk packaging text (apk-staging copy + `zip` + `apksigner`). The
/// canonical source of the packaging block since the enum `.android_package`
/// section was deleted (#461); the golden cell `bgfx_v2_android.build.zig` locks
/// its output.
pub const apk_package_zig = @embedFile("../templates/package_apk.txt");

/// The wasm/web packaging text (emcc install/run + build-fn close + the
/// `overrideImport` helper def). Canonical since the enum `.wasm_footer` section
/// was deleted (#461); the golden cell `sokol_wasm_v2.build.zig` locks its output.
pub const web_package_zig = @embedFile("../templates/package_web.txt");

/// Emit the packaging step for a platform's `Package` recipe.
///
///   - `.binary` — desktop: NO packaging step (the exe is installed directly).
///     A no-op, so a desktop `PlatformEntry` can call this unconditionally.
///   - `.apk`    — Android: the apk-staging copy + `zip` + `apksigner` block.
///   - `.web`    — wasm: the emcc install/run wiring (+ trailing helpers, see
///     the module doc).
///
/// Byte-identical to the corresponding enum-path template section (design §7).
///
/// The recipe payload fields (`apk.manifest`, `web.shell`) are accepted but not
/// yet consumed — the current sections do not parameterize on them (the apk
/// manifest is staged elsewhere; the wasm shell is null on the enum path). They
/// become live when PR 5/7 wire the Android/wasm platform entries; keeping the
/// recipe in the signature now means those PRs need no signature change.
pub fn emitPackage(package: Package, w: anytype) !void {
    switch (package) {
        .binary => {}, // desktop — nothing to package
        .apk => try w.writeAll(apk_package_zig),
        .web => try w.writeAll(web_package_zig),
    }
}

// ============================================================================
// Tests — the packager owns its apk/web fixtures (the enum sections are gone, #461)
// ============================================================================

const testing = std.testing;

fn emitToOwned(package: Package) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    errdefer aw.deinit();
    try emitPackage(package, &aw.writer);
    return aw.toOwnedSlice();
}

test "emitPackage(.apk) emits the apk fixture verbatim" {
    const out = try emitToOwned(.{ .apk = .{ .manifest = "AndroidManifest.xml.tmpl" } });
    defer testing.allocator.free(out);
    try testing.expectEqualStrings(apk_package_zig, out);
}

test "emitPackage(.web) emits the web fixture verbatim" {
    const out = try emitToOwned(.{ .web = .{ .shell = null } });
    defer testing.allocator.free(out);
    try testing.expectEqualStrings(web_package_zig, out);
}

test "emitPackage(.web) recipe shell field does not change the emitted text" {
    // The shell field is not consumed yet; assert the packager stays byte-identical
    // regardless so a future non-null shell is an intentional, reviewed change
    // rather than silent drift.
    const out = try emitToOwned(.{ .web = .{ .shell = "custom_shell.html" } });
    defer testing.allocator.free(out);
    try testing.expectEqualStrings(web_package_zig, out);
}

test "emitPackage(.binary) emits nothing (desktop no-op)" {
    const out = try emitToOwned(.binary);
    defer testing.allocator.free(out);
    try testing.expectEqual(@as(usize, 0), out.len);
}
