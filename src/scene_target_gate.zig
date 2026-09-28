//! `@` target-override engine-version gate (labelle-engine#801): finds
//! scene/prefab files that use `@<ref>` keys so `generate` can refuse an
//! engine pin too old to understand them. Split out of `scene_manifest.zig`
//! (which re-exports every public name here) to keep that file under the
//! 1000-line limit.

const std = @import("std");
const config = @import("config.zig");
const stderrPrint = @import("scene_manifest.zig").stderrPrint;

/// True iff `src` uses `@` target-override syntax (labelle-engine#801).
/// Delegates to `scene_name_lint.sourceUsesTargetKeys` — the scope-aware
/// walker — so opaque component-payload keys (`{ "Config": { "@id": … } }`)
/// and `@ref` VALUES never count, while flat/wrapped `@` keys do. (The
/// JSON-escaped `"\u0040…"` spelling does not: the engine's parser
/// rejects `\u` escapes outright, labelle-assembler#651.)
pub fn sourceUsesTargetKeys(src: []const u8) bool {
    return @import("scene_name_lint.zig").sourceUsesTargetKeys(src);
}

/// First engine release that understands `@` target-override keys
/// (labelle-engine#801). Bump ONLY if the engine-side feature slips to a
/// later minor.
pub const MIN_ENGINE_FOR_TARGET_OVERRIDES = "2.11.0";

/// True iff the pinned engine version understands `@` target overrides.
/// PERMISSIVE on anything unparseable (`local:` overrides, branch pins):
/// the gate exists to catch the "new assembler, old engine pin" skew where
/// an old engine silently drops `@` keys — a pin we cannot parse is a
/// deliberate dev setup, not that trap. Compat checking is MAJOR-only
/// (labelle-cli#269), so this per-feature minimum is the only guard. The
/// comparison itself (release-vs-dev classification, `X.Y` normalization,
/// fail-closed on garbage) lives in `config.engineFeatureSupport`, shared
/// with the external-tileset gate in `tilemap_scan`.
pub fn engineSupportsTargetOverrides(engine_version: []const u8) bool {
    return config.engineFeatureSupport(engine_version, MIN_ENGINE_FOR_TARGET_OVERRIDES) != .no;
}

/// Scan every `<name>.jsonc` under `dir` for `@` target-override keys;
/// returns the first file (allocator-owned name) that uses them, or null.
/// Missing/unreadable files are skipped — this is a version gate, not a
/// file validator (the real parse reports real errors) — EXCEPT an
/// oversized file (`error.StreamTooLong`): a file too big to scan may
/// contain the keys the gate exists to catch, so skipping it would bypass
/// the gate (CodeRabbit on #650). The 16 MiB ceiling is far above any
/// real scene/prefab; each buffer is freed before the next file is read
/// so peak memory stays one file, not the sum (codex P2 on #650).
pub fn findTargetKeyUsage(
    allocator: std.mem.Allocator,
    dir: []const u8,
    names: []const []const u8,
) !?[]const u8 {
    for (names) |name| {
        const rel = try std.fmt.allocPrint(allocator, "{s}/{s}.jsonc", .{ dir, name });
        errdefer allocator.free(rel);
        const source = std.Io.Dir.cwd().readFileAlloc(config.globalIo(), rel, allocator, .limited(16 * 1024 * 1024)) catch |err| switch (err) {
            error.StreamTooLong => {
                stderrPrint(
                    "labelle-assembler: '{s}' exceeds the 16 MiB scan ceiling for the target-override version gate — cannot verify it is free of `@` keys.\n",
                    .{rel},
                );
                return err;
            },
            else => {
                allocator.free(rel);
                continue;
            },
        };
        const used = sourceUsesTargetKeys(source);
        allocator.free(source);
        if (used) return rel;
        allocator.free(rel);
    }
    return null;
}

/// `findTargetKeyUsage` over every `.jsonc` in a directory TREE — used for
/// pack source dirs, whose file lists are not staged yet when the gate
/// runs (codex P1 / CodeRabbit on #650). A missing directory is fine
/// (packs need not ship prefabs or scenes). Returns the first offending
/// path (allocator-owned), or null.
pub fn findTargetKeyUsageInTree(
    allocator: std.mem.Allocator,
    dir_path: []const u8,
) !?[]const u8 {
    const io = config.globalIo();
    var dir = std.Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true }) catch return null;
    defer dir.close(io);

    var iter = dir.iterate();
    while (iter.next(io) catch return null) |entry| {
        switch (entry.kind) {
            .directory => {
                const sub = try std.fs.path.join(allocator, &.{ dir_path, entry.name });
                defer allocator.free(sub);
                if (try findTargetKeyUsageInTree(allocator, sub)) |hit| return hit;
            },
            .file => {
                if (!std.mem.endsWith(u8, entry.name, ".jsonc")) continue;
                const rel = try std.fs.path.join(allocator, &.{ dir_path, entry.name });
                errdefer allocator.free(rel);
                const source = std.Io.Dir.cwd().readFileAlloc(io, rel, allocator, .limited(16 * 1024 * 1024)) catch |err| switch (err) {
                    error.StreamTooLong => {
                        stderrPrint(
                            "labelle-assembler: '{s}' exceeds the 16 MiB scan ceiling for the target-override version gate — cannot verify it is free of `@` keys.\n",
                            .{rel},
                        );
                        return err;
                    },
                    else => {
                        allocator.free(rel);
                        continue;
                    },
                };
                const used = sourceUsesTargetKeys(source);
                allocator.free(source);
                if (used) return rel;
                allocator.free(rel);
            },
            else => {},
        }
    }
    return null;
}
