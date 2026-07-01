//! Shared platform-packager (epic #453 item 3, PR 4 — see
//! `docs/design/manifest-v2-build-graph.md` §3/§6/§7).
//!
//! This module is the ONE place that knows how to emit a platform's *packaging*
//! step. It is driven by a v2 manifest's `BackendManifestV2.Package` recipe
//! (`.platforms[p].package`): `.binary` (desktop — no packaging), `.apk`
//! (Android — the apk-staging copy + `zip` + `apksigner` shell-outs), and
//! `.web` (wasm — the emcc install/run step wiring).
//!
//! ## Why it exists — factor the packaging OUT of the enum template
//!
//! Today the packaging lives as two verbatim template sections that
//! `build_files.zig` emits with a `switch (cfg.platform)`:
//!   - `.android_package` (`src/templates/build_zig.txt`) → `writeSection(.., "android_package")`
//!   - `.wasm_footer`     (`src/templates/build_zig.txt`) → `writeSection(.., "wasm_footer")`
//! The v2 codegen (`manifest_v2_splice.zig`) has no platform enum to switch on —
//! it works off the typed `Package` recipe — so it needs a shared entry point
//! that turns a `Package` into the exact same packaging text. That is
//! `emitPackage` below. It lands BEFORE the Android/wasm backend conversions
//! (PRs 5/7) so their `.package` delegation is ready and their golden cells are
//! achievable (§7).
//!
//! ## Byte-identity is the contract (design §7)
//!
//! `emitPackage(.apk, …)` MUST emit text byte-identical to the enum path's
//! `.android_package` section, and `emitPackage(.web, …)` byte-identical to the
//! enum path's `.wasm_footer` section — otherwise PR 5/7's golden cells (which
//! are generated FROM this packager and hand-reviewed against the enum output)
//! could not match the enum baseline. The packaging text is held here as
//! packager-OWNED fixtures (`@embedFile` of `templates/package_apk.txt` /
//! `templates/package_web.txt`, byte-copies of the two sections), and the tests
//! below assert equality against the live template sections so drift in EITHER
//! representation fails loudly. The enum-path sections are left in place and
//! unchanged (the lower-risk migration option, design §7 / task PR-4): the enum
//! path still `writeSection`s them, and this packager reproduces their output.
//! When PR 12 deletes the enum sections, these fixtures remain the source of
//! truth.
//!
//! Note on the `.web` fixture: the `.wasm_footer` template section (as
//! `writeSection` emits it) runs to the next section header, so it carries not
//! only the emcc install/run step but also the trailing build-function close and
//! the `overrideImport`/`unifyGfxSubpackageCore` helper defs that sit after it in
//! the template. The packager reproduces the section verbatim — matching exactly
//! what the enum path emits today — so byte-identity holds. (The `.apk` section
//! ends before `.android_footer`, so it carries only the packaging block.)

const std = @import("std");
const manifest_v2 = @import("manifest_v2.zig");

const Package = manifest_v2.BackendManifestV2.Package;

/// Verbatim byte-copy of the enum path's `.android_package` template section
/// (`src/templates/build_zig.txt`). Owned by the packager so that when the enum
/// sections are deleted (PR 12) the packaging text survives here. The
/// byte-identity test below locks it to the live template section.
pub const apk_package_zig = @embedFile("../templates/package_apk.txt");

/// Verbatim byte-copy of the enum path's `.wasm_footer` template section
/// (`src/templates/build_zig.txt`). See the module doc for why this carries the
/// trailing helper defs.
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
// Tests — byte-identity vs the live enum-path sections (design §7 anchor)
// ============================================================================

const testing = std.testing;
const tpl = @import("../template.zig");
const build_zig_tmpl = @embedFile("../templates/build_zig.txt");

fn emitToOwned(package: Package) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    errdefer aw.deinit();
    try emitPackage(package, &aw.writer);
    return aw.toOwnedSlice();
}

test "emitPackage(.apk) is byte-identical to the .android_package section" {
    const section = tpl.getSection(build_zig_tmpl, "android_package").?;
    const out = try emitToOwned(.{ .apk = .{ .manifest = "AndroidManifest.xml.tmpl" } });
    defer testing.allocator.free(out);
    try testing.expectEqualStrings(section, out);
}

test "emitPackage(.web) is byte-identical to the .wasm_footer section" {
    const section = tpl.getSection(build_zig_tmpl, "wasm_footer").?;
    const out = try emitToOwned(.{ .web = .{ .shell = null } });
    defer testing.allocator.free(out);
    try testing.expectEqualStrings(section, out);
}

test "emitPackage(.web) recipe shell field does not change the emitted text" {
    // The shell field is not consumed yet (enum path emits it null); assert the
    // packager stays byte-identical regardless so a future non-null shell is an
    // intentional, reviewed change rather than silent drift.
    const out = try emitToOwned(.{ .web = .{ .shell = "custom_shell.html" } });
    defer testing.allocator.free(out);
    try testing.expectEqualStrings(web_package_zig, out);
}

test "emitPackage(.binary) emits nothing (desktop no-op)" {
    const out = try emitToOwned(.binary);
    defer testing.allocator.free(out);
    try testing.expectEqual(@as(usize, 0), out.len);
}

test "packager fixtures match their live template sections (drift guard)" {
    // The @embedFile'd packager fixtures are byte-copies of the enum sections.
    // If someone edits one representation but not the other, this fails.
    try testing.expectEqualStrings(
        tpl.getSection(build_zig_tmpl, "android_package").?,
        apk_package_zig,
    );
    try testing.expectEqualStrings(
        tpl.getSection(build_zig_tmpl, "wasm_footer").?,
        web_package_zig,
    );
}
