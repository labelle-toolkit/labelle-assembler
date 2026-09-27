//! Shared platform-packager (epic #453 item 3, PR 4 — see
//! `docs/design/manifest-v2-build-graph.md` §3/§6/§7).
//!
//! This module is the ONE place that knows how to emit a platform's *packaging*
//! step. It is driven by a v2 manifest's `BackendManifestV2.Package` recipe
//! (`.platforms[p].package`): `.binary` (desktop — no packaging), `.apk`
//! (Android — no generated packaging either, see below), and `.web` (wasm —
//! the emcc install/run step wiring).
//!
//! ## `.apk` emits nothing (labelle-cli#405)
//!
//! Android packaging moved out of the generated `build.zig` into the
//! labelle-android provider (`providers/android.json`), which stages, zips and
//! signs the APK itself. The former `templates/package_apk.txt` fixture (the
//! generated `zig build package` step) is gone. The `.apk = .{ .manifest }`
//! recipe is still ACCEPTED in backend manifests — released labelle-bgfx /
//! labelle-sokol pins still carry it, and rejecting it would break every pinned
//! backend — but it is ignored.
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
//! The packaging text is held here as a packager-OWNED fixture (`@embedFile` of
//! `templates/package_web.txt`). It was captured byte-identical to the former
//! enum `.wasm_footer` template section (validated by the golden cell
//! `sokol_wasm_v2.build.zig`); that enum section was deleted with the rest of
//! the v1/enum path (#461), so this fixture is now the SOLE source of truth.
//!
//! Note on the `.web` fixture: it carries not only the emcc install/run step but
//! also the trailing build-function close and the `overrideImport` helper def that
//! sat after `.wasm_footer` in the old template — the `renderWasmFooterV2` +
//! packager split reproduces exactly the same bytes.

const std = @import("std");
const manifest_v2 = @import("manifest_v2.zig");

const Package = manifest_v2.BackendManifestV2.Package;

/// The wasm/web packaging text (emcc install/run + build-fn close + the
/// `overrideImport` helper def). Canonical since the enum `.wasm_footer` section
/// was deleted (#461); the golden cell `sokol_wasm_v2.build.zig` locks its output.
pub const web_package_zig = @embedFile("../templates/package_web.txt");

/// Emit the packaging step for a platform's `Package` recipe.
///
///   - `.binary` — desktop: NO packaging step (the exe is installed directly).
///     A no-op, so a desktop `PlatformEntry` can call this unconditionally.
///   - `.apk`    — Android: NO packaging step either. The labelle-android
///     provider packages the APK (labelle-cli#405); the recipe's `.manifest`
///     is accepted for released backend pins but ignored.
///   - `.web`    — wasm: the emcc install/run wiring (+ trailing helpers, see
///     the module doc).
///
/// Byte-identical to the corresponding enum-path template section (design §7).
///
/// The recipe payload fields (`apk.manifest`, `web.shell`) are accepted but not
/// consumed — the web section does not parameterize on its shell, and the apk
/// recipe emits nothing at all.
pub fn emitPackage(package: Package, w: anytype) !void {
    switch (package) {
        .binary => {}, // desktop — nothing to package
        .apk => {}, // Android — the labelle-android provider packages (cli#405)
        .web => try w.writeAll(web_package_zig),
    }
}

// ============================================================================
// Tests — the packager owns its web fixture (the enum sections are gone, #461)
// ============================================================================

const testing = std.testing;

fn emitToOwned(package: Package) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    errdefer aw.deinit();
    try emitPackage(package, &aw.writer);
    return aw.toOwnedSlice();
}

test "emitPackage(.apk) emits no package step (labelle-cli#405)" {
    // The labelle-android provider packages the APK; the generated build.zig
    // must not grow a `zig build package` step (or any apksigner/zip wiring).
    const out = try emitToOwned(.{ .apk = .{ .manifest = "AndroidManifest.xml.tmpl" } });
    defer testing.allocator.free(out);
    try testing.expectEqual(@as(usize, 0), out.len);
}

test "emitPackage(.apk) accepts but ignores any .manifest value (released backend pins)" {
    // Released bgfx/sokol manifests still carry `.apk = .{ .manifest = ... }`
    // (sokol ships no such template file at all). The value must never be
    // read, so an arbitrary or empty path changes nothing.
    inline for (.{ "AndroidManifest.xml.tmpl", "does/not/exist.tmpl", "" }) |manifest| {
        const out = try emitToOwned(.{ .apk = .{ .manifest = manifest } });
        defer testing.allocator.free(out);
        try testing.expectEqual(@as(usize, 0), out.len);
    }
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
