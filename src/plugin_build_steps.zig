//! Plugin build-integration hooks (labelle-assembler#586) — the declarative
//! `.build` block of `plugin.labelle`.
//!
//! A plugin that must run an EXTERNAL build producing a linkable artifact
//! (the native language family: `cargo build` for a Rust scripts module,
//! `crystal build` + `ld -r`, `go build -buildmode=c-archive`, …) declares
//! the commands and the produced artifact in its manifest:
//!
//! ```zon
//! .build = .{
//!     .steps = .{
//!         .{ .name = "cargo-lib",
//!            .command = .{ "cargo", "build", "--release", "--target-dir", "{cache}" },
//!            .cwd = "native",                        // package-relative
//!            .artifact = "{cache}/release/libfoo.a", // produced staticlib/object
//!            .link = .static_lib },                  // how the game consumes it
//!     },
//! },
//! ```
//!
//! ── When steps run: generated-BUILD-time, not generate-time ─────────────
//! Steps are emitted into the generated `build.zig` as
//! `b.addSystemCommand(...)` run steps, artifact wired via
//! `addObjectFile` + step dependencies (`build_files/build_zig.zig`,
//! `emitPluginBuildSteps`). They execute on every `zig build`, NOT during
//! `labelle generate`, because:
//!
//!   1. rebuilds ride zig's build graph — edit the plugin's native sources
//!      and the next `zig build` re-runs the (internally incremental)
//!      tool; a generate-time exec would go stale until the next generate;
//!   2. the concrete cross-compilation triple only EXISTS at build time on
//!      android/ios (the v2 backend `resolve_target` hooks run inside
//!      build.zig), so a `{target}`-parameterised command cannot be
//!      resolved at generate time;
//!   3. `labelle generate && zig build` (the acceptance shape) behaves
//!      identically either way for the first build.
//!
//! The OTHER hook flavor — a generate-time HOST-tool exec — already exists
//! as the declare-mode runner (`scripting_declare.zig`, #585): it runs
//! `zig build labelle-declare` inside the staged package while the
//! assembler itself is running, because its OUTPUT feeds codegen. When a
//! plugin needs a generic "run this at generate time and feed the
//! assembler" step, the fold-in path is a `.stage = .generate` variant of
//! this schema executing declare-style (cache/prefix outside the wiped
//! deps tree, capability-probed, path-absolutized); until a second
//! consumer exists the declare mechanics deliberately stay hardcoded
//! there (see the #586 cross-reference in its module doc).
//!
//! ── Placeholders (the WHOLE templating language) ────────────────────────
//! Exactly three placeholders may appear inside `command` args and
//! `artifact`; there is no other substitution — no shell, no `$VAR` /
//! environment expansion, no globbing:
//!
//!   `{package}` — absolute path of the plugin's STAGED package copy
//!                 (`<output>/deps/labelle-<name>`, the same bytes the game
//!                 links; cache-resolved dir when deps staging fell back).
//!                 Substituted at generate time.
//!   `{cache}`   — a per-plugin, per-target persistent work dir
//!                 (`<build-root>/plugin-build/<name>`). OUTSIDE the wiped
//!                 deps tree, so tool caches (cargo's target dir…) survive
//!                 re-generates; per backend×platform build root, so
//!                 cross-target artifacts never collide. Substituted at
//!                 build time (`b.pathFromRoot`).
//!   `{target}`  — the resolved zig target triple (e.g.
//!                 `aarch64-linux-android`), substituted at build time via
//!                 `target.result.zigTriple`. Command authors owe any
//!                 tool-specific triple mapping (a cargo target name is not
//!                 a zig triple) to their own command.
//!
//! Any other `{...}` token — and any stray `{`/`}` — is rejected at
//! generate time (`error.PluginBuildUnknownPlaceholder`), so a typo'd
//! placeholder can never silently reach the emitted argv.
//!
//! ── Determinism & safety posture ────────────────────────────────────────
//! Commands are DECLARED argv arrays in a manifest you can read: no shell
//! interpretation, no env expansion, cwd is validated to stay inside the
//! staged package, and the artifact must land under `{cache}/` or
//! `{package}/`. That posture is AUDITABILITY, not sandboxing: a hostile
//! plugin can still run arbitrary code AT BUILD TIME — exactly like any
//! build dependency (a `build.zig`, a `plugin.hook.zig` (#518), a cargo
//! build script) can. What the declarative form buys is that the entire
//! exec surface is visible in `plugin.labelle` before you build, instead
//! of buried in imperative build code. Steps run with the invoking user's
//! environment (build tools legitimately need HOME/PATH); argv itself is
//! never env-expanded.
//!
//! ── Platform constraints ────────────────────────────────────────────────
//! A step may declare `.platforms = .{ "desktop", "android" }` (labelle
//! platform names, the `config.Platform` vocabulary). Generating a project
//! whose platform is NOT in a declared allowlist FAILS with a pointed
//! error naming the plugin, step, platform, and allowlist — a plugin that
//! cannot produce (say) a wasm artifact must fail the wasm generate up
//! front rather than let the game die at link time with missing symbols.
//! Absent/empty allowlist = every platform (the command runs on the HOST;
//! cross-target correctness is the command's job, aided by `{target}`).
//!
//! ── Schema strictness & manifest compatibility ──────────────────────────
//! The manifest-level parse keeps its documented forward-compat
//! (`ignore_unknown_fields = true`, see `plugin_manifest/plugin.zig`), so
//! OLD assemblers ignore a `.build` block entirely (the plugin then fails
//! at the game's link step with missing symbols — plugin authors that hard
//! -require build steps should document the minimum assembler). Like every
//! additive optional key before it (`.resources`, `.packs`,
//! `requires_language`), `.build` does NOT bump `manifest_version`.
//! WITHIN the `.build` subtree, though, unknown keys hard-fail: this
//! module re-parses just the `.build` node strictly
//! (`ignore_unknown_fields = false` via `fromZoirNodeAlloc`), because a
//! typo'd `.artifcat` that silently parses would produce a command whose
//! output is never linked — the worst kind of silent no-op.

const std = @import("std");
const config = @import("config.zig");
const cache = @import("cache.zig");

/// Directory (under the generated build root) that holds every plugin's
/// persistent `{cache}` work dir: `<build-root>/plugin-build/<plugin>/`.
/// Deliberately OUTSIDE `deps/` (wiped and re-hardlinked each generate) so
/// tool caches survive, mirroring `scripting_declare`'s `declare-tool/`.
pub const CACHE_DIR_NAME = "plugin-build";

pub const PLACEHOLDER_CACHE = "{cache}";
pub const PLACEHOLDER_PACKAGE = "{package}";
pub const PLACEHOLDER_TARGET = "{target}";

/// How the generated build consumes a step's produced artifact.
/// `static_lib` and `object` both wire through `addObjectFile` (zig's
/// build API treats `.a`/`.o` inputs uniformly there); the distinction is
/// declarative intent and headroom for modes that will NOT be uniform
/// (shared libs need rpath handling — not in v1). `none` = a pure command
/// step (e.g. a codegen pass a later step consumes); it links nothing.
pub const LinkMode = enum { none, object, static_lib };

/// One declared build step. Field vocabulary is CLOSED — the strict
/// subtree parse rejects unknown keys (see module doc).
pub const Step = struct {
    /// Diagnostic name ([A-Za-z0-9_-], ≤ 64 chars). Appears in generate
    /// errors and emitted build.zig comments; generated variable names use
    /// the step INDEX, so this never has to be a Zig identifier.
    name: []const u8,
    /// The declared argv. `command[0]` is the program — PATH-resolved by
    /// the OS or an absolute path; the assembler never shells out.
    command: []const []const u8,
    /// Package-relative working directory (plain relative path, no
    /// placeholders, no `..`). Absent = the package root. The command
    /// always runs INSIDE the staged package (posture, module doc).
    cwd: ?[]const u8 = null,
    /// Produced artifact path, rooted at `{cache}/` or `{package}/`.
    /// Required when `link != .none`, forbidden when `link == .none`.
    artifact: ?[]const u8 = null,
    link: LinkMode = .none,
    /// Platform allowlist (labelle platform names). Empty = all.
    platforms: []const []const u8 = &.{},
};

/// Parsed `.build` block of one plugin. Owns every slice reachable from
/// `steps` (deep copies made by the ZON parser); release with `deinit`.
pub const BuildSteps = struct {
    steps: []const Step,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *BuildSteps) void {
        std.zon.parse.free(self.allocator, self.steps);
        self.steps = &.{};
    }
};

// The strict-parse target: `.build` may (v1: does) carry only `.steps`.
const ZonBuildBlock = struct {
    steps: []const Step = &.{},
};

// ── Errors ─────────────────────────────────────────────────────────────
//
//   error.PluginBuildParseError          — `.build` subtree rejected (unknown
//                                          key, wrong shape, bad enum, …)
//   error.PluginBuildBadStepName         — step name empty/oversized/unsafe
//   error.PluginBuildEmptyCommand        — a step declared no argv
//   error.PluginBuildUnknownPlaceholder  — `{typo}` or stray brace in an arg
//                                          or artifact
//   error.PluginBuildUnsafePath          — cwd/artifact escapes (absolute,
//                                          `..`, `\`, drive colon, …)
//   error.PluginBuildMissingArtifact     — link != .none without artifact
//   error.PluginBuildArtifactWithoutLink — artifact with link == .none
//   error.PluginBuildBadArtifactRoot     — artifact not rooted at {cache}/
//                                          or {package}/
//   error.PluginBuildUnknownPlatform     — `.platforms` entry outside the
//                                          config.Platform vocabulary
//
// Raised by root.zig's generate-time wiring (not this loader):
//
//   error.PluginBuildUnsupportedPlatform — project platform not in a step's
//                                          allowlist (`stepAllowsPlatform`)
//   error.PluginBuildMissingCwd          — a declared cwd does not exist in
//                                          the staged package

fn diag(comptime fmt: []const u8, args: anytype) void {
    std.debug.print("labelle: " ++ fmt ++ "\n", args);
}

// ── Placeholder scanning ───────────────────────────────────────────────

/// The placeholder starting at `text[i]`, or null. Exact-token match —
/// this IS the whole templating language.
pub fn placeholderAt(text: []const u8, i: usize) ?[]const u8 {
    const candidates = [_][]const u8{ PLACEHOLDER_CACHE, PLACEHOLDER_PACKAGE, PLACEHOLDER_TARGET };
    for (candidates) |ph| {
        if (std.mem.startsWith(u8, text[i..], ph)) return ph;
    }
    return null;
}

/// Reject any `{`/`}` that is not part of a recognized placeholder. Keeps
/// the templating language closed: a typo'd `{cachce}` fails generate
/// instead of reaching the emitted argv as literal text.
pub fn validatePlaceholders(text: []const u8) error{PluginBuildUnknownPlaceholder}!void {
    var i: usize = 0;
    while (i < text.len) {
        switch (text[i]) {
            '{' => {
                const ph = placeholderAt(text, i) orelse return error.PluginBuildUnknownPlaceholder;
                i += ph.len;
            },
            '}' => return error.PluginBuildUnknownPlaceholder,
            else => i += 1,
        }
    }
}

/// True when `text` contains `ph` (one of the PLACEHOLDER_* tokens).
pub fn containsPlaceholder(text: []const u8, ph: []const u8) bool {
    return std.mem.indexOf(u8, text, ph) != null;
}

// ── Path safety ────────────────────────────────────────────────────────

/// A plain relative path that cannot escape its root: non-empty, no
/// leading `/`, no `\` (declare with `/`; windows join handles it), no
/// `:` (drive letters / URL schemes), no NUL, and no `.`/`..`/empty
/// segments. Multi-segment (`native/gen`) is fine — unlike
/// `plugin_manifest.isSafeDirName`, which guards single convention-dir
/// SEGMENTS, these are paths.
pub fn isSafeRelPath(p: []const u8) bool {
    if (p.len == 0) return false;
    if (p[0] == '/') return false;
    if (std.mem.indexOfAny(u8, p, "\\:") != null) return false;
    if (std.mem.indexOfScalar(u8, p, 0) != null) return false;
    var it = std.mem.splitScalar(u8, p, '/');
    while (it.next()) |seg| {
        if (seg.len == 0) return false;
        if (std.mem.eql(u8, seg, ".") or std.mem.eql(u8, seg, "..")) return false;
    }
    return true;
}

fn isSafeStepName(name: []const u8) bool {
    if (name.len == 0 or name.len > 64) return false;
    for (name) |c| {
        const ok = (c >= 'A' and c <= 'Z') or (c >= 'a' and c <= 'z') or
            (c >= '0' and c <= '9') or c == '_' or c == '-';
        if (!ok) return false;
    }
    return true;
}

// ── Platform gate ──────────────────────────────────────────────────────

/// Generate-time check: may `step` run for `platform`? Empty allowlist =
/// yes. root.zig raises `error.PluginBuildUnsupportedPlatform` (with a
/// pointed diagnostic) when this returns false — a constrained plugin must
/// fail the generate up front, not the game's link step later.
pub fn stepAllowsPlatform(step: Step, platform: config.Platform) bool {
    if (step.platforms.len == 0) return true;
    for (step.platforms) |p| {
        if (std.mem.eql(u8, p, @tagName(platform))) return true;
    }
    return false;
}

// ── Loading ────────────────────────────────────────────────────────────

/// Read and strictly parse the `.build` block of `<plugin_dir>/plugin.labelle`.
///
/// Returns null when the plugin has no manifest OR the manifest has no
/// `.build` key (the common case — every plugin before #586). The
/// MANIFEST-level schema (name, manifest_version, convention_dirs, …) is
/// validated by `plugin_manifest.loadFromDir` on its own pass; this loader
/// deliberately reads the file independently so the two additive schema
/// surfaces (#586 `.build`, #591 `.params`) never edit shared parsing code.
///
/// The subtree parse runs with `ignore_unknown_fields = false` (module
/// doc: a typo'd step key must hard-fail), then every step is validated:
/// name/argv/placeholder/path/link/platform rules — see the error table.
pub fn loadFromDir(
    allocator: std.mem.Allocator,
    plugin_dir: []const u8,
    plugin_name: []const u8,
) !?BuildSteps {
    const manifest_path = try std.fs.path.join(allocator, &.{ plugin_dir, "plugin.labelle" });
    defer allocator.free(manifest_path);

    const cwd = std.Io.Dir.cwd();
    const raw_bytes = cwd.readFileAlloc(config.globalIo(), manifest_path, allocator, .limited(64 * 1024)) catch |err| {
        if (err == error.FileNotFound) return null;
        return err;
    };
    defer allocator.free(raw_bytes);

    const raw_z = try allocator.dupeZ(u8, raw_bytes);
    defer allocator.free(raw_z);

    return loadFromSource(allocator, raw_z, plugin_name, manifest_path);
}

/// `loadFromDir` over an in-memory manifest source (the file-less seam the
/// unit tests drive). `manifest_path` is diagnostics-only.
pub fn loadFromSource(
    allocator: std.mem.Allocator,
    source: [:0]const u8,
    plugin_name: []const u8,
    manifest_path: []const u8,
) !?BuildSteps {
    var ast = try std.zig.Ast.parse(allocator, source, .zon);
    defer ast.deinit(allocator);
    if (ast.errors.len != 0) {
        // A syntactically broken manifest is `plugin_manifest.loadFromDir`'s
        // error domain (it parses the same file and names the problem);
        // report the same class of error here for standalone robustness.
        diag(
            "failed to parse plugin.labelle for plugin '{s}' at {s} (syntax error)",
            .{ plugin_name, manifest_path },
        );
        return error.PluginBuildParseError;
    }

    var zoir = try std.zig.ZonGen.generate(allocator, ast, .{ .parse_str_lits = false });
    defer zoir.deinit(allocator);
    if (zoir.hasCompileErrors()) {
        diag(
            "failed to parse plugin.labelle for plugin '{s}' at {s} (invalid ZON)",
            .{ plugin_name, manifest_path },
        );
        return error.PluginBuildParseError;
    }

    // Locate the root struct's `build` field. Non-struct roots and absent
    // keys are both "no build steps".
    const build_node = switch (std.zig.Zoir.Node.Index.root.get(zoir)) {
        .struct_literal => |sl| blk: {
            for (sl.names, 0..) |n, i| {
                if (std.mem.eql(u8, n.get(zoir), "build")) break :blk sl.vals.at(@intCast(i));
            }
            return null;
        },
        else => return null,
    };

    // Strict subtree parse: unknown keys ANYWHERE under `.build` hard-fail.
    // A Diagnostics is REQUIRED for leak-freedom, not just messaging: the
    // parser allocates the type-check failure message unconditionally, and
    // only a Diagnostics ever owns it.
    var pdiag: std.zon.parse.Diagnostics = .{};
    const parsed = std.zon.parse.fromZoirNodeAlloc(
        ZonBuildBlock,
        allocator,
        ast,
        zoir,
        build_node,
        &pdiag,
        .{ .ignore_unknown_fields = false },
    ) catch |err| switch (err) {
        error.ParseZon => {
            diag(
                "plugin '{s}' has an invalid .build block at {s}\n  {f}\n" ++
                    "  allowed: .build = .{{ .steps = .{{ .{{ .name, .command, .cwd, .artifact, .link, .platforms }}, … }} }}\n" ++
                    "  unknown keys are rejected (typos must not silently drop a step's wiring)",
                .{ plugin_name, manifest_path, &pdiag },
            );
            // `fromZoirNodeAlloc` stored BORROWED views of our ast/zoir in
            // the diagnostics; the type-check failure (and its message) is
            // parser-allocated and ours to free. Detach the borrowed views
            // before deinit so the defers above don't double-free.
            pdiag.ast = .{ .source = "", .tokens = .empty, .nodes = .empty, .extra_data = &.{}, .mode = .zon, .errors = &.{} };
            pdiag.zoir = .{ .nodes = .empty, .extra = &.{}, .limbs = &.{}, .string_bytes = &.{}, .compile_errors = &.{}, .error_notes = &.{} };
            pdiag.deinit(allocator);
            return error.PluginBuildParseError;
        },
        error.OutOfMemory => return error.OutOfMemory,
    };
    // On success nothing in `pdiag` is parser-owned (type_check is null and
    // ast/zoir are our borrows) — no deinit.
    errdefer std.zon.parse.free(allocator, parsed);

    // ── Per-step validation ──
    for (parsed.steps, 0..) |step, i| {
        if (!isSafeStepName(step.name)) {
            diag(
                "plugin '{s}' .build step #{d} has an invalid name '{s}' ([A-Za-z0-9_-], 1..64 chars)",
                .{ plugin_name, i, step.name },
            );
            return error.PluginBuildBadStepName;
        }
        if (step.command.len == 0) {
            diag("plugin '{s}' .build step '{s}' declares an empty command", .{ plugin_name, step.name });
            return error.PluginBuildEmptyCommand;
        }
        for (step.command) |arg| {
            validatePlaceholders(arg) catch {
                diag(
                    "plugin '{s}' .build step '{s}' argv contains an unknown placeholder or stray brace in \"{s}\"\n" ++
                        "  the placeholder set is exactly: {{cache}}, {{package}}, {{target}}",
                    .{ plugin_name, step.name, arg },
                );
                return error.PluginBuildUnknownPlaceholder;
            };
        }
        if (step.cwd) |c| {
            // cwd is a package-relative LITERAL: placeholders make no sense
            // ({package} is implied, {cache} would leave the package —
            // against the posture) and read as escape attempts.
            if (!isSafeRelPath(c) or std.mem.indexOfScalar(u8, c, '{') != null) {
                diag(
                    "plugin '{s}' .build step '{s}' cwd '{s}' is not a plain package-relative path\n" ++
                        "  (no absolute paths, no '..', no '\\', no placeholders — commands run inside the staged package)",
                    .{ plugin_name, step.name, c },
                );
                return error.PluginBuildUnsafePath;
            }
        }
        switch (step.link) {
            .none => if (step.artifact != null) {
                diag(
                    "plugin '{s}' .build step '{s}' declares an artifact but .link = .none — nothing would consume it\n" ++
                        "  (set .link = .static_lib / .object, or drop .artifact)",
                    .{ plugin_name, step.name },
                );
                return error.PluginBuildArtifactWithoutLink;
            },
            .object, .static_lib => if (step.artifact == null) {
                diag(
                    "plugin '{s}' .build step '{s}' has .link = .{s} but no .artifact to link",
                    .{ plugin_name, step.name, @tagName(step.link) },
                );
                return error.PluginBuildMissingArtifact;
            },
        }
        if (step.artifact) |a| {
            validatePlaceholders(a) catch {
                diag(
                    "plugin '{s}' .build step '{s}' artifact \"{s}\" contains an unknown placeholder or stray brace",
                    .{ plugin_name, step.name, a },
                );
                return error.PluginBuildUnknownPlaceholder;
            };
            const rest: []const u8 = if (std.mem.startsWith(u8, a, PLACEHOLDER_CACHE ++ "/"))
                a[PLACEHOLDER_CACHE.len + 1 ..]
            else if (std.mem.startsWith(u8, a, PLACEHOLDER_PACKAGE ++ "/"))
                a[PLACEHOLDER_PACKAGE.len + 1 ..]
            else {
                diag(
                    "plugin '{s}' .build step '{s}' artifact \"{s}\" must be rooted at {{cache}}/ or {{package}}/\n" ++
                        "  (artifacts stay inside the plugin's staged package or its build-cache dir)",
                    .{ plugin_name, step.name, a },
                );
                return error.PluginBuildBadArtifactRoot;
            };
            // The tail must be a plain relative path AND placeholder-free
            // (a second `{cache}` mid-path would double-substitute).
            if (!isSafeRelPath(rest) or std.mem.indexOfScalar(u8, rest, '{') != null) {
                diag(
                    "plugin '{s}' .build step '{s}' artifact \"{s}\" escapes its root or nests a placeholder",
                    .{ plugin_name, step.name, a },
                );
                return error.PluginBuildUnsafePath;
            }
        }
        for (step.platforms) |p| {
            const known = blk: {
                inline for (@typeInfo(config.Platform).@"enum".fields) |f| {
                    if (std.mem.eql(u8, p, f.name)) break :blk true;
                }
                break :blk false;
            };
            if (!known) {
                diag(
                    "plugin '{s}' .build step '{s}' names unknown platform \"{s}\" (known: desktop, ios, android, wasm)",
                    .{ plugin_name, step.name, p },
                );
                return error.PluginBuildUnknownPlatform;
            }
        }
    }

    if (parsed.steps.len == 0) {
        // `.build = .{}` / empty steps: a declared no-op. Free and treat as
        // absent so downstream wiring (and its byte-identity invariant)
        // never sees an empty entry.
        std.zon.parse.free(allocator, parsed);
        return null;
    }

    return BuildSteps{ .steps = parsed.steps, .allocator = allocator };
}

/// `loadFromDir` via the plugin-cache resolution path (the shape root.zig
/// uses; mirrors `plugin_manifest.loadOptional`).
pub fn loadOptional(
    allocator: std.mem.Allocator,
    plugin: config.PluginDep,
    project_dir: []const u8,
) !?BuildSteps {
    const plugin_dir = try cache.resolvePlugin(allocator, plugin, project_dir);
    defer allocator.free(plugin_dir);
    return loadFromDir(allocator, plugin_dir, plugin.name);
}

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;

fn loadSrc(src: [:0]const u8) !?BuildSteps {
    return loadFromSource(testing.allocator, src, "fixture", "<test>/plugin.labelle");
}

test "loadFromSource: manifest without .build → null" {
    const result = try loadSrc(
        \\.{ .name = "fixture", .manifest_version = 1 }
    );
    try testing.expect(result == null);
}

test "loadFromSource: parses the ticket's cargo shape" {
    var steps = (try loadSrc(
        \\.{
        \\    .name = "fixture",
        \\    .manifest_version = 1,
        \\    .build = .{
        \\        .steps = .{
        \\            .{ .name = "cargo-lib",
        \\               .command = .{ "cargo", "build", "--release", "--target-dir", "{cache}" },
        \\               .cwd = "native",
        \\               .artifact = "{cache}/release/libfoo.a",
        \\               .link = .static_lib },
        \\        },
        \\    },
        \\}
    )).?;
    defer steps.deinit();

    try testing.expectEqual(@as(usize, 1), steps.steps.len);
    const s = steps.steps[0];
    try testing.expectEqualStrings("cargo-lib", s.name);
    try testing.expectEqual(@as(usize, 5), s.command.len);
    try testing.expectEqualStrings("cargo", s.command[0]);
    try testing.expectEqualStrings("{cache}", s.command[4]);
    try testing.expectEqualStrings("native", s.cwd.?);
    try testing.expectEqualStrings("{cache}/release/libfoo.a", s.artifact.?);
    try testing.expectEqual(LinkMode.static_lib, s.link);
    try testing.expectEqual(@as(usize, 0), s.platforms.len);
}

test "loadFromSource: unknown key inside a step hard-fails (strict subtree parse)" {
    // `.artifcat` (typo) would silently drop the link wiring under the
    // manifest-level `ignore_unknown_fields = true` — the exact silent
    // no-op the strict subtree parse exists to reject.
    const result = loadSrc(
        \\.{
        \\    .name = "fixture",
        \\    .manifest_version = 1,
        \\    .build = .{
        \\        .steps = .{
        \\            .{ .name = "s", .command = .{ "true" }, .artifcat = "{cache}/x.a" },
        \\        },
        \\    },
        \\}
    );
    try testing.expectError(error.PluginBuildParseError, result);
}

test "loadFromSource: unknown key on the .build block itself hard-fails" {
    const result = loadSrc(
        \\.{
        \\    .name = "fixture",
        \\    .manifest_version = 1,
        \\    .build = .{ .stepz = .{} },
        \\}
    );
    try testing.expectError(error.PluginBuildParseError, result);
}

test "loadFromSource: manifest-level unknown keys still parse (forward-compat untouched)" {
    // The strictness is scoped to the `.build` SUBTREE — a future
    // manifest-level key next to `.build` must keep loading (the
    // plugin_manifest.zig forward-compat contract).
    var steps = (try loadSrc(
        \\.{
        \\    .name = "fixture",
        \\    .manifest_version = 1,
        \\    .some_future_key = "ignored",
        \\    .build = .{
        \\        .steps = .{
        \\            .{ .name = "s", .command = .{ "true" } },
        \\        },
        \\    },
        \\}
    )).?;
    defer steps.deinit();
    try testing.expectEqual(@as(usize, 1), steps.steps.len);
}

test "loadFromSource: unknown placeholder in argv rejected" {
    const result = loadSrc(
        \\.{
        \\    .name = "fixture",
        \\    .manifest_version = 1,
        \\    .build = .{
        \\        .steps = .{
        \\            .{ .name = "s", .command = .{ "tool", "--out={cachce}/x" } },
        \\        },
        \\    },
        \\}
    );
    try testing.expectError(error.PluginBuildUnknownPlaceholder, result);
}

test "loadFromSource: stray closing brace in argv rejected" {
    const result = loadSrc(
        \\.{
        \\    .name = "fixture",
        \\    .manifest_version = 1,
        \\    .build = .{
        \\        .steps = .{
        \\            .{ .name = "s", .command = .{ "tool", "weird}arg" } },
        \\        },
        \\    },
        \\}
    );
    try testing.expectError(error.PluginBuildUnknownPlaceholder, result);
}

test "loadFromSource: cwd path escapes rejected (.., absolute, placeholder)" {
    inline for (.{ "\"../sibling\"", "\"/abs/path\"", "\"{cache}\"" }) |bad_cwd| {
        const src =
            \\.{
            \\    .name = "fixture",
            \\    .manifest_version = 1,
            \\    .build = .{
            \\        .steps = .{
            \\            .{ .name = "s", .command = .{ "true" }, .cwd =
        ++ " " ++ bad_cwd ++ " },\n" ++
            \\        },
            \\    },
            \\}
        ;
        const result = loadSrc(src);
        try testing.expectError(error.PluginBuildUnsafePath, result);
    }
}

test "loadFromSource: artifact must be rooted at {cache}/ or {package}/" {
    const result = loadSrc(
        \\.{
        \\    .name = "fixture",
        \\    .manifest_version = 1,
        \\    .build = .{
        \\        .steps = .{
        \\            .{ .name = "s", .command = .{ "true" }, .artifact = "release/libfoo.a", .link = .static_lib },
        \\        },
        \\    },
        \\}
    );
    try testing.expectError(error.PluginBuildBadArtifactRoot, result);
}

test "loadFromSource: artifact tail escaping its root rejected" {
    const result = loadSrc(
        \\.{
        \\    .name = "fixture",
        \\    .manifest_version = 1,
        \\    .build = .{
        \\        .steps = .{
        \\            .{ .name = "s", .command = .{ "true" }, .artifact = "{cache}/../outside.a", .link = .static_lib },
        \\        },
        \\    },
        \\}
    );
    try testing.expectError(error.PluginBuildUnsafePath, result);
}

test "loadFromSource: link without artifact / artifact without link rejected" {
    try testing.expectError(error.PluginBuildMissingArtifact, loadSrc(
        \\.{
        \\    .name = "fixture",
        \\    .manifest_version = 1,
        \\    .build = .{ .steps = .{ .{ .name = "s", .command = .{ "true" }, .link = .static_lib } } },
        \\}
    ));
    try testing.expectError(error.PluginBuildArtifactWithoutLink, loadSrc(
        \\.{
        \\    .name = "fixture",
        \\    .manifest_version = 1,
        \\    .build = .{ .steps = .{ .{ .name = "s", .command = .{ "true" }, .artifact = "{cache}/x.a" } } },
        \\}
    ));
}

test "loadFromSource: empty command rejected; empty steps → null (declared no-op)" {
    try testing.expectError(error.PluginBuildEmptyCommand, loadSrc(
        \\.{
        \\    .name = "fixture",
        \\    .manifest_version = 1,
        \\    .build = .{ .steps = .{ .{ .name = "s", .command = .{} } } },
        \\}
    ));
    try testing.expect((try loadSrc(
        \\.{ .name = "fixture", .manifest_version = 1, .build = .{} }
    )) == null);
    try testing.expect((try loadSrc(
        \\.{ .name = "fixture", .manifest_version = 1, .build = .{ .steps = .{} } }
    )) == null);
}

test "loadFromSource: bad step name and unknown platform rejected" {
    try testing.expectError(error.PluginBuildBadStepName, loadSrc(
        \\.{
        \\    .name = "fixture",
        \\    .manifest_version = 1,
        \\    .build = .{ .steps = .{ .{ .name = "has space", .command = .{ "true" } } } },
        \\}
    ));
    try testing.expectError(error.PluginBuildUnknownPlatform, loadSrc(
        \\.{
        \\    .name = "fixture",
        \\    .manifest_version = 1,
        \\    .build = .{ .steps = .{ .{ .name = "s", .command = .{ "true" }, .platforms = .{ "amiga" } } } },
        \\}
    ));
}

test "stepAllowsPlatform: empty allowlist = all; named list gates" {
    const open = Step{ .name = "s", .command = &.{"true"} };
    try testing.expect(stepAllowsPlatform(open, .desktop));
    try testing.expect(stepAllowsPlatform(open, .wasm));

    const desktop_only = Step{
        .name = "s",
        .command = &.{"true"},
        .platforms = &.{"desktop"},
    };
    try testing.expect(stepAllowsPlatform(desktop_only, .desktop));
    try testing.expect(!stepAllowsPlatform(desktop_only, .android));
    try testing.expect(!stepAllowsPlatform(desktop_only, .wasm));
}

test "isSafeRelPath: accepts nested relative, rejects escapes" {
    try testing.expect(isSafeRelPath("native"));
    try testing.expect(isSafeRelPath("native/gen"));
    try testing.expect(!isSafeRelPath(""));
    try testing.expect(!isSafeRelPath("/abs"));
    try testing.expect(!isSafeRelPath("a//b"));
    try testing.expect(!isSafeRelPath("a/"));
    try testing.expect(!isSafeRelPath(".."));
    try testing.expect(!isSafeRelPath("a/../b"));
    try testing.expect(!isSafeRelPath("."));
    try testing.expect(!isSafeRelPath("a\\b"));
    try testing.expect(!isSafeRelPath("C:/x"));
}

test "validatePlaceholders: accepts the closed set, rejects everything else" {
    try validatePlaceholders("plain");
    try validatePlaceholders("{cache}/release/{target}/lib.a");
    try validatePlaceholders("{package}");
    try testing.expectError(error.PluginBuildUnknownPlaceholder, validatePlaceholders("{oops}"));
    try testing.expectError(error.PluginBuildUnknownPlaceholder, validatePlaceholders("{cache"));
    try testing.expectError(error.PluginBuildUnknownPlaceholder, validatePlaceholders("cache}"));
    try testing.expectError(error.PluginBuildUnknownPlaceholder, validatePlaceholders("{{cache}}"));
}

test "loadFromDir: reads plugin.labelle from a real dir; missing file → null" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = testing.io;

    const tmp_path = try tmp.dir.realPathFileAlloc(io, ".", testing.allocator);
    defer testing.allocator.free(tmp_path);

    try testing.expect((try loadFromDir(testing.allocator, tmp_path, "fixture")) == null);

    {
        var f = try tmp.dir.createFile(io, "plugin.labelle", .{});
        defer f.close(io);
        try f.writeStreamingAll(io,
            \\.{
            \\    .name = "fixture",
            \\    .manifest_version = 1,
            \\    .build = .{
            \\        .steps = .{
            \\            .{ .name = "mk", .command = .{ "true" } },
            \\        },
            \\    },
            \\}
        );
    }
    var steps = (try loadFromDir(testing.allocator, tmp_path, "fixture")).?;
    defer steps.deinit();
    try testing.expectEqualStrings("mk", steps.steps[0].name);
}
