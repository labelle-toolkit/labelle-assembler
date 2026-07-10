//! Asset-Plugins Phase 1 (labelle-toolkit/labelle-engine#725,
//! RFC-ASSET-PLUGINS.md rev 4) — pack-shipped assets end to end.
//!
//! A pack may now declare `.resources` in its `pack.labelle` (same
//! `ResourceDef` shape as `project.labelle`). This module carries the three
//! interlocking Phase-1 tickets:
//!
//!   - **#573 merge.** `mergePackResources` folds each pack's declared
//!     resources into the game's resource list, namespaced `<pack>__<name>`
//!     and repathed into the copied `packs/<pack>/…` dir, so the existing
//!     resource codegen (`resource_loader`, `asset_wiring`, `scene_manifests`)
//!     consumes them **unchanged**.
//!   - **#574 namespacing.** `processPackAssets` copies a pack's `assets/`
//!     into the target, rewrites its atlas JSON frame keys to `<pack>/<frame>`
//!     (path-like, matches the existing `cloud_day/…` idiom) AND the
//!     `sprite_name` references in the pack's own prefabs to match — one pass,
//!     the same copy stage that rewrites `pack__` prefab refs. Global
//!     `findSprite` then cannot collide across packs, with zero engine changes.
//!   - **#575 validation.** After the rewrite, every `sprite_name` in a pack's
//!     prefabs must resolve to a frame in (its own shipped atlases) ∪ (atlases
//!     named in `depends_on_resources`) — a miss is a generate-time error with
//!     the offending file:line, killing the silent-runtime-blank. Scene
//!     auto-wiring (`autoWireScenes`) adds a pack's non-lazy resources to any
//!     scene that instantiates one of its prefabs.
//!
//! **Byte-identity:** every entry point is additive and no-ops when no pack
//! declares `.resources` — a project with only code packs (or no packs) gets
//! output identical to before this ticket.

const std = @import("std");
const config = @import("config.zig");
const scanner = @import("scanner.zig");
const cache = @import("cache.zig");
const scene_manifest = @import("scene_manifest.zig");
const scene_name_lint = @import("scene_name_lint.zig");
const generate_phases = @import("root/generate_phases.zig");

const ResourceDef = config.ResourceDef;
const PackEntry = generate_phases.PackEntry;

// ── #573: resource merge ────────────────────────────────────────────

/// Result of `mergePackResources`: the merged resource slice plus the arena
/// that backs every string it (and the namespaced entries) point at. The
/// caller keeps `arena` alive for as long as `resources` is read, then calls
/// `deinit`.
pub const Merged = struct {
    resources: []ResourceDef,
    arena: std.heap.ArenaAllocator,

    pub fn deinit(self: *Merged) void {
        self.arena.deinit();
    }
};

/// Fold every pack's declared `.resources` into `game_resources`, namespaced
/// `<pack>__<name>` and repathed into the copied `packs/<pack>/…` dir
/// (labelle-assembler#573). Game resources are copied verbatim and come FIRST,
/// so with no pack resources the merged list is byte-identical to the input
/// (the additive contract). Pack resources follow in `pack_entries` order.
///
/// Repathing: a pack resource `.json = "assets/tiles.json"` becomes
/// `packs/<pack>/assets/tiles.json` — a target-relative `@embedFile` path
/// pointing at the dir `processPackAssets` copies the pack's `assets/` into.
/// The lazy flag / font params ride through unchanged.
pub fn mergePackResources(
    parent_allocator: std.mem.Allocator,
    game_resources: []const ResourceDef,
    pack_entries: []const PackEntry,
) !Merged {
    var arena = std.heap.ArenaAllocator.init(parent_allocator);
    errdefer arena.deinit();
    const a = arena.allocator();

    var out: std.ArrayList(ResourceDef) = .empty;
    // Game resources first, verbatim (strings still owned by the caller; they
    // outlive the merged view, which is only read during the same generate()).
    try out.appendSlice(a, game_resources);

    for (pack_entries) |e| {
        for (e.manifest.resources) |res| {
            try out.append(a, .{
                .name = try std.fmt.allocPrint(a, "{s}__{s}", .{ e.plugin.name, res.name }),
                .json = try repath(a, e.plugin.name, res.json),
                .texture = try repath(a, e.plugin.name, res.texture),
                .sound = try repath(a, e.plugin.name, res.sound),
                .font = try repath(a, e.plugin.name, res.font),
                .font_params = res.font_params,
                .lazy = res.lazy,
            });
        }
    }

    return .{ .resources = try out.toOwnedSlice(a), .arena = arena };
}

/// Repath a pack-relative asset path to its copied target-relative location.
/// Empty stays empty (an unset field on a non-atlas resource). Always uses
/// `/` — the separator the generated `@embedFile` paths use.
fn repath(a: std.mem.Allocator, pack_name: []const u8, path: []const u8) ![]const u8 {
    if (path.len == 0) return "";
    return std.fmt.allocPrint(a, "packs/{s}/{s}", .{ pack_name, path });
}

// ── #574 + #575: copy, namespace, validate ──────────────────────────

/// Generate-time errors this module can raise (in addition to allocation /
/// filesystem errors that flow through the inferred error sets):
///   - `error.DanglingSpriteRef` — a `sprite_name` in a pack prefab resolves
///     to no frame in the pack's own atlases nor any `depends_on_resources`
///     atlas (#575).
///   - `error.UnknownResourceDependency` — a `depends_on_resources` entry
///     names a resource absent from the merged resource list (#575).
///
/// Copy each pack's `assets/` into the target, namespace its atlas frame keys
/// + own prefab `sprite_name` refs (#574), then validate every sprite ref
/// resolves (#575). No-op for a pack with no `.resources`.
///
/// Runs at the same copy stage `scanPack` used (after the pack's convention
/// dirs are copied), so the pack prefabs it rewrites already live under
/// `<target>/packs/<pack>/prefabs/`. `merged` is read to resolve a
/// `depends_on_resources` atlas name to the JSON the game/other pack shipped.
/// `game_dir` is the project root, used to resolve each pack's source dir the
/// same way `loadPackScans` does.
pub fn processPackAssets(
    allocator: std.mem.Allocator,
    pack_entries: []const PackEntry,
    merged: []const ResourceDef,
    game_dir: []const u8,
    target_dir: []const u8,
) !void {
    for (pack_entries) |e| {
        if (e.manifest.resources.len == 0 and e.manifest.depends_on_resources.len == 0) continue;
        const pack_src_dir = cache.resolvePlugin(allocator, e.plugin, game_dir) catch continue;
        defer allocator.free(pack_src_dir);
        try processOnePack(allocator, e, merged, pack_src_dir, target_dir);
    }
}

/// Process one pack's assets against an already-resolved source dir. Split
/// from `processPackAssets` so tests can drive a hand-built `PackEntry` +
/// pack src dir without the cache-resolution round trip.
pub fn processOnePack(
    allocator: std.mem.Allocator,
    entry: PackEntry,
    merged: []const ResourceDef,
    pack_src_dir: []const u8,
    target_dir: []const u8,
) !void {
    const pack_name = entry.plugin.name;
    const dst_base = try std.fs.path.join(allocator, &.{ target_dir, "packs", pack_name });
    defer allocator.free(dst_base);

    // 1. Copy the pack's shipped `assets/` into the target (frame-key rewrite
    //    below mutates the COPY, never the source pack tree).
    if (entry.manifest.resources.len > 0) {
        try scanner.copyDirRecursive(allocator, pack_src_dir, dst_base, "assets");
    }

    // 2. Collect the pack's OWN frame names (bare, e.g. "grass.png") from every
    //    atlas it ships, and rewrite each copied atlas JSON's frame keys to the
    //    namespaced `<pack>/grass.png` form.
    var own_frames: std.ArrayList([]const u8) = .empty;
    defer {
        for (own_frames.items) |f| allocator.free(f);
        own_frames.deinit(allocator);
    }
    for (entry.manifest.resources) |res| {
        if (res.kind() != .atlas) continue;
        const json_path = try std.fs.path.join(allocator, &.{ dst_base, res.json });
        defer allocator.free(json_path);
        const frames = collectAtlasFrames(allocator, json_path) catch continue;
        defer {
            for (frames) |f| allocator.free(f);
            allocator.free(frames);
        }
        for (frames) |f| try own_frames.append(allocator, try allocator.dupe(u8, f));
        try namespaceAtlasFile(allocator, json_path, pack_name, frames);
    }

    // 3. Resolve `depends_on_resources` — each must exist in the merged list;
    //    collect the bare frames those atlases provide so a pack that overlays
    //    game art validates.
    var dep_frames: std.ArrayList([]const u8) = .empty;
    defer {
        for (dep_frames.items) |f| allocator.free(f);
        dep_frames.deinit(allocator);
    }
    for (entry.manifest.depends_on_resources) |dep| {
        const found = findResource(merged, dep) orelse {
            std.debug.print(
                "labelle-assembler: pack '{s}' declares depends_on_resources \"{s}\" but no such resource is declared by the game or any pack.\n",
                .{ pack_name, dep },
            );
            return error.UnknownResourceDependency;
        };
        if (found.kind() != .atlas) continue;
        const json_path = try std.fs.path.join(allocator, &.{ target_dir, found.json });
        defer allocator.free(json_path);
        const frames = collectAtlasFrames(allocator, json_path) catch continue;
        defer {
            for (frames) |f| allocator.free(f);
            allocator.free(frames);
        }
        for (frames) |f| try dep_frames.append(allocator, try allocator.dupe(u8, f));
    }

    // 4. Rewrite + validate each of the pack's OWN prefabs.
    try processPackPrefabs(allocator, dst_base, pack_name, own_frames.items, dep_frames.items);
}

/// Rewrite (in place) every pack prefab's `sprite_name` refs that name one of
/// the pack's OWN frames to the namespaced `<pack>/<frame>` form (#574), then
/// validate that every `sprite_name` in the rewritten prefab resolves to a
/// pack frame (`<pack>/…`) or a `depends_on_resources` (bare) frame (#575).
fn processPackPrefabs(
    allocator: std.mem.Allocator,
    dst_base: []const u8,
    pack_name: []const u8,
    own_frames: []const []const u8,
    dep_frames: []const []const u8,
) !void {
    const io = config.globalIo();
    const cwd = std.Io.Dir.cwd();
    const prefabs_dir = try std.fs.path.join(allocator, &.{ dst_base, "prefabs" });
    defer allocator.free(prefabs_dir);

    var dir = cwd.openDir(io, prefabs_dir, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    defer dir.close(io);

    try walkPrefabDir(allocator, dir, prefabs_dir, pack_name, own_frames, dep_frames);
}

fn walkPrefabDir(
    allocator: std.mem.Allocator,
    dir: std.Io.Dir,
    dir_path: []const u8,
    pack_name: []const u8,
    own_frames: []const []const u8,
    dep_frames: []const []const u8,
) !void {
    const io = config.globalIo();
    var iter = dir.iterate();
    while (try iter.next(io)) |e| {
        switch (e.kind) {
            .directory => {
                const sub_path = try std.fs.path.join(allocator, &.{ dir_path, e.name });
                defer allocator.free(sub_path);
                var sub = try dir.openDir(io, e.name, .{ .iterate = true });
                defer sub.close(io);
                try walkPrefabDir(allocator, sub, sub_path, pack_name, own_frames, dep_frames);
            },
            .file => {
                if (!std.mem.endsWith(u8, e.name, ".jsonc") and !std.mem.endsWith(u8, e.name, ".json")) continue;
                const path = try std.fs.path.join(allocator, &.{ dir_path, e.name });
                defer allocator.free(path);
                try rewriteAndValidatePrefab(allocator, path, pack_name, own_frames, dep_frames);
            },
            else => {},
        }
    }
}

fn rewriteAndValidatePrefab(
    allocator: std.mem.Allocator,
    path: []const u8,
    pack_name: []const u8,
    own_frames: []const []const u8,
    dep_frames: []const []const u8,
) !void {
    const io = config.globalIo();
    const cwd = std.Io.Dir.cwd();

    const src = cwd.readFileAlloc(io, path, allocator, .limited(4 * 1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return error.OutOfMemory,
    };
    defer allocator.free(src);

    const rewritten = try namespaceSpriteRefs(allocator, src, pack_name, own_frames);
    defer allocator.free(rewritten);

    // Validate BEFORE persisting so a bad ref fails generate rather than
    // leaving a rewritten-but-invalid copy behind.
    try validateSpriteRefs(rewritten, path, pack_name, own_frames, dep_frames);

    if (std.mem.eql(u8, rewritten, src)) return;
    var f = try cwd.createFile(io, path, .{});
    defer f.close(io);
    try f.writeStreamingAll(io, rewritten);
}

// ── pure string/JSON helpers (unit-tested) ──────────────────────────

/// Parse a TexturePacker JSON-hash atlas and return its bare frame names
/// (the keys of the top-level `"frames"` object). Caller owns the slice + each
/// string. A non-atlas / unparseable file yields an empty list.
pub fn collectAtlasFrames(allocator: std.mem.Allocator, json_path: []const u8) ![][]u8 {
    const io = config.globalIo();
    const cwd = std.Io.Dir.cwd();
    const bytes = try cwd.readFileAlloc(io, json_path, allocator, .limited(16 * 1024 * 1024));
    defer allocator.free(bytes);
    return collectAtlasFramesFromBytes(allocator, bytes);
}

pub fn collectAtlasFramesFromBytes(allocator: std.mem.Allocator, bytes: []const u8) ![][]u8 {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, bytes, .{}) catch {
        return allocator.alloc([]u8, 0);
    };
    defer parsed.deinit();
    const root = parsed.value;
    if (root != .object) return allocator.alloc([]u8, 0);
    const frames = root.object.get("frames") orelse return allocator.alloc([]u8, 0);
    if (frames != .object) return allocator.alloc([]u8, 0);

    var out: std.ArrayList([]u8) = .empty;
    errdefer {
        for (out.items) |s| allocator.free(s);
        out.deinit(allocator);
    }
    var it = frames.object.iterator();
    while (it.next()) |kv| {
        try out.append(allocator, try allocator.dupe(u8, kv.key_ptr.*));
    }
    return out.toOwnedSlice(allocator);
}

/// Rewrite (in place, on disk) an atlas JSON file's frame keys to the
/// namespaced `<pack>/<frame>` form. `frames` is the bare-name set from
/// `collectAtlasFrames`. No-op when the file already carries no bare key.
pub fn namespaceAtlasFile(
    allocator: std.mem.Allocator,
    json_path: []const u8,
    pack_name: []const u8,
    frames: []const []const u8,
) !void {
    const io = config.globalIo();
    const cwd = std.Io.Dir.cwd();
    const bytes = try cwd.readFileAlloc(io, json_path, allocator, .limited(16 * 1024 * 1024));
    defer allocator.free(bytes);

    const rewritten = try namespaceAtlasFrameKeys(allocator, bytes, pack_name, frames);
    defer allocator.free(rewritten);
    if (std.mem.eql(u8, rewritten, bytes)) return;

    var f = try cwd.createFile(io, json_path, .{});
    defer f.close(io);
    try f.writeStreamingAll(io, rewritten);
}

/// Prefix each bare frame KEY (`"grass.png":`) with `<pack>/`. A frame name in
/// TexturePacker JSON-hash only ever appears as an object key immediately
/// followed by `:`; the leading `"` and trailing `":` anchor the match so a
/// meta value like `"image": "grass.png"` (png AFTER the colon) is never
/// touched. Caller owns the returned buffer.
pub fn namespaceAtlasFrameKeys(
    allocator: std.mem.Allocator,
    bytes: []const u8,
    pack_name: []const u8,
    frames: []const []const u8,
) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);
    try buf.appendSlice(allocator, bytes);

    for (frames) |frame| {
        const needle = try std.fmt.allocPrint(allocator, "\"{s}\":", .{frame});
        defer allocator.free(needle);
        const replacement = try std.fmt.allocPrint(allocator, "\"{s}/{s}\":", .{ pack_name, frame });
        defer allocator.free(replacement);
        const next = try replaceAllOwned(allocator, buf.items, needle, replacement);
        buf.deinit(allocator);
        buf = .empty;
        try buf.appendSlice(allocator, next);
        allocator.free(next);
    }
    return buf.toOwnedSlice(allocator);
}

/// Rewrite every `sprite_name` value naming one of the pack's OWN frames to
/// `<pack>/<frame>`. Whitespace-tolerant: finds each `"sprite_name"` key, skips
/// to its string value, and prefixes it when the bare value is a pack frame.
/// Returns an owned buffer (identical to input when nothing matched).
pub fn namespaceSpriteRefs(
    allocator: std.mem.Allocator,
    bytes: []const u8,
    pack_name: []const u8,
    frames: []const []const u8,
) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    const key = "\"sprite_name\"";
    var i: usize = 0;
    while (i < bytes.len) {
        if (std.mem.startsWith(u8, bytes[i..], key)) {
            // Emit the key, then locate the value string.
            try out.appendSlice(allocator, key);
            var j = i + key.len;
            // skip whitespace + the ':' separator + whitespace
            while (j < bytes.len and (bytes[j] == ' ' or bytes[j] == '\t' or bytes[j] == '\r' or bytes[j] == '\n')) : (j += 1) {}
            if (j < bytes.len and bytes[j] == ':') {
                try out.appendSlice(allocator, bytes[i + key.len .. j + 1]);
                j += 1;
                const ws_start = j;
                while (j < bytes.len and (bytes[j] == ' ' or bytes[j] == '\t' or bytes[j] == '\r' or bytes[j] == '\n')) : (j += 1) {}
                try out.appendSlice(allocator, bytes[ws_start..j]);
                if (j < bytes.len and bytes[j] == '"') {
                    const val_start = j + 1;
                    var k = val_start;
                    while (k < bytes.len and bytes[k] != '"') : (k += 1) {}
                    if (k < bytes.len) {
                        const val = bytes[val_start..k];
                        if (containsStr(frames, val)) {
                            try out.print(allocator, "\"{s}/{s}\"", .{ pack_name, val });
                        } else {
                            try out.appendSlice(allocator, bytes[j .. k + 1]);
                        }
                        i = k + 1;
                        continue;
                    }
                }
                i = j;
                continue;
            }
            i = i + key.len;
            continue;
        }
        try out.append(allocator, bytes[i]);
        i += 1;
    }
    return out.toOwnedSlice(allocator);
}

/// Validate that every `sprite_name` in `bytes` resolves — either a namespaced
/// `<pack>/…` frame (the pack's own, post-rewrite) or a bare frame provided by
/// a `depends_on_resources` atlas. The first miss is a generate-time error
/// naming the file + line:col of the offending value.
pub fn validateSpriteRefs(
    bytes: []const u8,
    display_path: []const u8,
    pack_name: []const u8,
    own_frames: []const []const u8,
    dep_frames: []const []const u8,
) !void {
    const key = "\"sprite_name\"";
    var i: usize = 0;
    while (std.mem.indexOfPos(u8, bytes, i, key)) |pos| {
        var j = pos + key.len;
        while (j < bytes.len and (bytes[j] == ' ' or bytes[j] == '\t' or bytes[j] == '\r' or bytes[j] == '\n')) : (j += 1) {}
        if (j >= bytes.len or bytes[j] != ':') {
            i = pos + key.len;
            continue;
        }
        j += 1;
        while (j < bytes.len and (bytes[j] == ' ' or bytes[j] == '\t' or bytes[j] == '\r' or bytes[j] == '\n')) : (j += 1) {}
        if (j >= bytes.len or bytes[j] != '"') {
            i = pos + key.len;
            continue;
        }
        const val_start = j + 1;
        var k = val_start;
        while (k < bytes.len and bytes[k] != '"') : (k += 1) {}
        if (k >= bytes.len) break;
        const val = bytes[val_start..k];
        if (!spriteRefResolves(val, pack_name, own_frames, dep_frames)) {
            const loc = scene_name_lint.locOf(bytes, val_start);
            std.debug.print(
                "labelle-assembler: pack '{s}' prefab '{s}':{d}:{d} references sprite '{s}' " ++
                    "that no shipped or declared atlas provides.\n" ++
                    "  A pack sprite must resolve to a frame in one of the pack's own atlases " ++
                    "(its `.resources`) or an atlas named in `depends_on_resources`.\n",
                .{ pack_name, display_path, loc.line, loc.col, val },
            );
            return error.DanglingSpriteRef;
        }
        i = k + 1;
    }
}

fn spriteRefResolves(
    val: []const u8,
    pack_name: []const u8,
    own_frames: []const []const u8,
    dep_frames: []const []const u8,
) bool {
    // Own frame post-rewrite: "<pack>/<frame>".
    if (std.mem.startsWith(u8, val, pack_name) and
        val.len > pack_name.len and val[pack_name.len] == '/')
    {
        const bare = val[pack_name.len + 1 ..];
        if (containsStr(own_frames, bare)) return true;
    }
    // A bare ref covered by a depends_on atlas.
    if (containsStr(dep_frames, val)) return true;
    // Already-namespaced game/other-unit ref (path-like) is left to that
    // unit's own validation — accept a value that itself contains a '/'
    // (idiomatic path-like frame the pack didn't ship, e.g. `cloud_day/x.png`).
    if (std.mem.indexOfScalar(u8, val, '/') != null and
        !std.mem.startsWith(u8, val, pack_name))
    {
        return true;
    }
    return false;
}

// ── #575: scene auto-wiring ──────────────────────────────────────────

/// Add each pack's non-lazy resources to any scene manifest that instantiates
/// one of that pack's prefabs (labelle-assembler#575), so a scene using
/// `sky__sky_system` preloads the sky pack's atlases without hand-editing
/// `meta.assets`. A pack resource declared `lazy = true` is skipped — it rides
/// the streaming catalog and loads on first use.
///
/// Mutates `manifests` in place: an augmented manifest's `assets` slice (and
/// its added strings) are re-allocated from `allocator`, so the existing
/// `freeManifests` frees them uniformly. No-op when no scene references a
/// pack prefab (byte-identical output).
pub fn autoWireScenes(
    allocator: std.mem.Allocator,
    manifests: []scene_manifest.SceneManifest,
    pack_entries: []const PackEntry,
    scenes_dir: []const u8,
) !void {
    if (pack_entries.len == 0) return;

    for (manifests) |*m| {
        const scene_path = try std.fmt.allocPrint(allocator, "{s}/{s}.jsonc", .{ scenes_dir, m.name });
        defer allocator.free(scene_path);
        const refs = scene_manifest.scanScenePrefabRefs(allocator, scene_path) catch continue;
        defer scene_manifest.freePrefabRefs(allocator, refs);
        if (refs.len == 0) continue;

        // Collect the non-lazy resource names of every pack this scene uses.
        var add: std.ArrayList([]const u8) = .empty;
        defer add.deinit(allocator);
        for (pack_entries) |e| {
            if (e.manifest.resources.len == 0) continue;
            if (!sceneUsesPack(refs, e.plugin.name)) continue;
            for (e.manifest.resources) |res| {
                if (res.lazy orelse false) continue; // lazy rides streaming
                const ns = try std.fmt.allocPrint(allocator, "{s}__{s}", .{ e.plugin.name, res.name });
                defer allocator.free(ns);
                if (!containsStr(m.assets, ns) and !containsStrList(add.items, ns)) {
                    try add.append(allocator, try allocator.dupe(u8, ns));
                }
            }
        }
        if (add.items.len == 0) continue;

        // Re-materialise `assets` = old ++ additions (old freed).
        var new_assets = try allocator.alloc([]const u8, m.assets.len + add.items.len);
        for (m.assets, 0..) |s, idx| new_assets[idx] = s; // move ownership
        for (add.items, 0..) |s, idx| new_assets[m.assets.len + idx] = s;
        if (m.assets.len > 0) allocator.free(m.assets);
        m.assets = new_assets;
    }
}

fn sceneUsesPack(refs: []const []const u8, pack_name: []const u8) bool {
    for (refs) |ref| {
        // A pack prefab is referenced as `<pack>__<name>`.
        if (std.mem.startsWith(u8, ref, pack_name) and
            ref.len > pack_name.len + 1 and
            ref[pack_name.len] == '_' and ref[pack_name.len + 1] == '_')
        {
            return true;
        }
    }
    return false;
}

// ── small shared utilities ──────────────────────────────────────────

fn findResource(resources: []const ResourceDef, name: []const u8) ?ResourceDef {
    for (resources) |r| {
        if (std.mem.eql(u8, r.name, name)) return r;
    }
    return null;
}

fn containsStr(list: []const []const u8, needle: []const u8) bool {
    for (list) |s| if (std.mem.eql(u8, s, needle)) return true;
    return false;
}

fn containsStrList(list: []const []const u8, needle: []const u8) bool {
    return containsStr(list, needle);
}

fn replaceAllOwned(allocator: std.mem.Allocator, input: []const u8, needle: []const u8, replacement: []const u8) ![]u8 {
    const count = std.mem.count(u8, input, needle);
    if (count == 0) return allocator.dupe(u8, input);
    const out_len = input.len - count * needle.len + count * replacement.len;
    const out = try allocator.alloc(u8, out_len);
    _ = std.mem.replace(u8, input, needle, replacement, out);
    return out;
}

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;

test "namespaceAtlasFrameKeys: prefixes bare frame keys, leaves meta value alone" {
    const src =
        \\{ "frames": { "grass.png": { "frame": { "x": 0 } }, "dirt.png": {} },
        \\  "meta": { "image": "grass.png" } }
    ;
    const frames = [_][]const u8{ "grass.png", "dirt.png" };
    const got = try namespaceAtlasFrameKeys(testing.allocator, src, "terrain", &frames);
    defer testing.allocator.free(got);

    try testing.expect(std.mem.indexOf(u8, got, "\"terrain/grass.png\":") != null);
    try testing.expect(std.mem.indexOf(u8, got, "\"terrain/dirt.png\":") != null);
    // The meta value (png after a colon) is NOT rewritten.
    try testing.expect(std.mem.indexOf(u8, got, "\"image\": \"grass.png\"") != null);
    // No bare frame key survives.
    try testing.expect(std.mem.indexOf(u8, got, "\"grass.png\":") == null);
}

test "namespaceSpriteRefs: prefixes only known frames, tolerates whitespace" {
    const src =
        \\{ "Sprite": { "sprite_name": "grass.png" },
        \\  "Other":  { "sprite_name":"unknown.png" },
        \\  "Third":  { "sprite_name" :  "dirt.png" } }
    ;
    const frames = [_][]const u8{ "grass.png", "dirt.png" };
    const got = try namespaceSpriteRefs(testing.allocator, src, "terrain", &frames);
    defer testing.allocator.free(got);

    try testing.expect(std.mem.indexOf(u8, got, "\"sprite_name\": \"terrain/grass.png\"") != null);
    try testing.expect(std.mem.indexOf(u8, got, "\"sprite_name\" :  \"terrain/dirt.png\"") != null);
    // Unknown frame (not shipped by the pack) is left bare for validation to catch.
    try testing.expect(std.mem.indexOf(u8, got, "\"unknown.png\"") != null);
}

test "namespaceSpriteRefs: no known frames → byte-identical" {
    const src = "{ \"Sprite\": { \"sprite_name\": \"grass.png\" } }";
    const frames = [_][]const u8{};
    const got = try namespaceSpriteRefs(testing.allocator, src, "terrain", &frames);
    defer testing.allocator.free(got);
    try testing.expectEqualStrings(src, got);
}

test "collectAtlasFramesFromBytes: reads frame keys" {
    const src = "{ \"frames\": { \"a.png\": {}, \"b.png\": {} }, \"meta\": {} }";
    const frames = try collectAtlasFramesFromBytes(testing.allocator, src);
    defer {
        for (frames) |f| testing.allocator.free(f);
        testing.allocator.free(frames);
    }
    try testing.expectEqual(@as(usize, 2), frames.len);
}

test "validateSpriteRefs: dangling own-namespaced ref errors" {
    // Post-rewrite the pack references `terrain/missing.png` but only ships grass.
    const src = "{ \"Sprite\": { \"sprite_name\": \"terrain/missing.png\" } }";
    const own = [_][]const u8{"grass.png"};
    const dep = [_][]const u8{};
    const r = validateSpriteRefs(src, "prefabs/x.jsonc", "terrain", &own, &dep);
    try testing.expectError(error.DanglingSpriteRef, r);
}

test "validateSpriteRefs: own + depends_on frames both resolve" {
    const src =
        \\{ "A": { "sprite_name": "terrain/grass.png" },
        \\  "B": { "sprite_name": "hero_idle.png" } }
    ;
    const own = [_][]const u8{"grass.png"};
    const dep = [_][]const u8{"hero_idle.png"};
    try validateSpriteRefs(src, "prefabs/x.jsonc", "terrain", &own, &dep);
}

test "mergePackResources: no pack resources → byte-identical game list" {
    const game = [_]ResourceDef{
        .{ .name = "background", .json = "assets/bg.json", .texture = "assets/bg.png" },
    };
    var merged = try mergePackResources(testing.allocator, &game, &.{});
    defer merged.deinit();
    try testing.expectEqual(@as(usize, 1), merged.resources.len);
    try testing.expectEqualStrings("background", merged.resources[0].name);
    try testing.expectEqualStrings("assets/bg.json", merged.resources[0].json);
}

test "spriteRefResolves: path-like foreign ref is accepted" {
    const own = [_][]const u8{"grass.png"};
    const dep = [_][]const u8{};
    // A path-like value the pack didn't ship (e.g. another unit's frame) is
    // left for that unit's own validation, not flagged here.
    try testing.expect(spriteRefResolves("cloud_day/cloud_7.png", "terrain", &own, &dep));
    try testing.expect(!spriteRefResolves("bare_unknown.png", "terrain", &own, &dep));
}

test "mergePackResources: pack atlas merges namespaced + repathed" {
    const game = [_]ResourceDef{
        .{ .name = "background", .json = "assets/bg.json", .texture = "assets/bg.png" },
    };
    const manifest = plugin_manifest.PackManifest{
        .name = "terrain",
        .manifest_version = 1,
        .convention_dirs = .copy_and_scan,
        .resources = &.{
            .{ .name = "tiles", .json = "assets/tiles.json", .texture = "assets/tiles.png" },
            .{ .name = "props", .json = "assets/props.json", .texture = "assets/props.png", .lazy = true },
        },
        .allocator = testing.allocator,
    };
    const entries = [_]PackEntry{.{ .plugin = .{ .name = "terrain" }, .manifest = manifest }};

    var merged = try mergePackResources(testing.allocator, &game, &entries);
    defer merged.deinit();

    try testing.expectEqual(@as(usize, 3), merged.resources.len);
    // Game resource stays byte-identical and comes first.
    try testing.expectEqualStrings("background", merged.resources[0].name);
    // Pack atlases are namespaced <pack>__<name> + repathed into packs/<pack>/…
    try testing.expectEqualStrings("terrain__tiles", merged.resources[1].name);
    try testing.expectEqualStrings("packs/terrain/assets/tiles.json", merged.resources[1].json);
    try testing.expectEqualStrings("packs/terrain/assets/tiles.png", merged.resources[1].texture);
    try testing.expectEqualStrings("terrain__props", merged.resources[2].name);
    try testing.expectEqual(true, merged.resources[2].lazy.?);
}

test "processOnePack: copies assets, namespaces atlas + prefab, validates" {
    const allocator = testing.allocator;
    const tio = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    // Pack source: assets/tiles.json (frames grass.png, dirt.png).
    try tmp.dir.createDirPath(tio, "src/terrain/assets");
    try writeTestFile(tmp.dir, "src/terrain/assets/tiles.json",
        \\{ "frames": { "grass.png": { "frame": {} }, "dirt.png": {} }, "meta": { "image": "tiles.png" } }
    );
    // A (dummy) texture so the copy has something to move.
    try writeTestFile(tmp.dir, "src/terrain/assets/tiles.png", "PNGDATA");
    // The pack prefab is copied to the TARGET by scanPack in the real flow; the
    // rewrite pass reads it from there, so stage it under target/packs/terrain.
    try tmp.dir.createDirPath(tio, "target/packs/terrain/prefabs");
    try writeTestFile(tmp.dir, "target/packs/terrain/prefabs/tile.jsonc",
        \\{ "Sprite": { "sprite_name": "grass.png" } }
    );

    const src_path = try tmp.dir.realPathFileAlloc(tio, "src/terrain", allocator);
    defer allocator.free(src_path);
    const target_path = try tmp.dir.realPathFileAlloc(tio, "target", allocator);
    defer allocator.free(target_path);

    const manifest = plugin_manifest.PackManifest{
        .name = "terrain",
        .manifest_version = 1,
        .convention_dirs = .copy_and_scan,
        .resources = &.{
            .{ .name = "tiles", .json = "assets/tiles.json", .texture = "assets/tiles.png" },
        },
        .allocator = allocator,
    };
    const entry = PackEntry{ .plugin = .{ .name = "terrain" }, .manifest = manifest };

    try processOnePack(allocator, entry, &.{}, src_path, target_path);

    // Atlas copied + frame keys namespaced.
    const atlas = try tmp.dir.readFileAlloc(tio, "target/packs/terrain/assets/tiles.json", allocator, .limited(1 << 20));
    defer allocator.free(atlas);
    try testing.expect(std.mem.indexOf(u8, atlas, "\"terrain/grass.png\":") != null);
    try testing.expect(std.mem.indexOf(u8, atlas, "\"grass.png\":") == null);

    // Prefab sprite_name rewritten to the namespaced frame.
    const prefab = try tmp.dir.readFileAlloc(tio, "target/packs/terrain/prefabs/tile.jsonc", allocator, .limited(1 << 20));
    defer allocator.free(prefab);
    try testing.expect(std.mem.indexOf(u8, prefab, "\"terrain/grass.png\"") != null);
}

test "processOnePack: a dangling sprite ref fails generate" {
    const allocator = testing.allocator;
    const tio = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(tio, "src/terrain/assets");
    try writeTestFile(tmp.dir, "src/terrain/assets/tiles.json",
        \\{ "frames": { "grass.png": {} }, "meta": {} }
    );
    try writeTestFile(tmp.dir, "src/terrain/assets/tiles.png", "PNGDATA");
    try tmp.dir.createDirPath(tio, "target/packs/terrain/prefabs");
    // References a frame the pack does NOT ship — the silent-blank case.
    try writeTestFile(tmp.dir, "target/packs/terrain/prefabs/bad.jsonc",
        \\{ "Sprite": { "sprite_name": "missing.png" } }
    );

    const src_path = try tmp.dir.realPathFileAlloc(tio, "src/terrain", allocator);
    defer allocator.free(src_path);
    const target_path = try tmp.dir.realPathFileAlloc(tio, "target", allocator);
    defer allocator.free(target_path);

    const manifest = plugin_manifest.PackManifest{
        .name = "terrain",
        .manifest_version = 1,
        .convention_dirs = .copy_and_scan,
        .resources = &.{.{ .name = "tiles", .json = "assets/tiles.json", .texture = "assets/tiles.png" }},
        .allocator = allocator,
    };
    const entry = PackEntry{ .plugin = .{ .name = "terrain" }, .manifest = manifest };

    const r = processOnePack(allocator, entry, &.{}, src_path, target_path);
    try testing.expectError(error.DanglingSpriteRef, r);
}

test "generated resource loader for a merged pack atlas compiles under AstGen" {
    const allocator = testing.allocator;
    const game = [_]ResourceDef{};
    const manifest = plugin_manifest.PackManifest{
        .name = "terrain",
        .manifest_version = 1,
        .convention_dirs = .copy_and_scan,
        .resources = &.{.{ .name = "tiles", .json = "assets/tiles.json", .texture = "assets/tiles.png" }},
        .allocator = allocator,
    };
    const entries = [_]PackEntry{.{ .plugin = .{ .name = "terrain" }, .manifest = manifest }};

    var merged = try mergePackResources(allocator, &game, &entries);
    defer merged.deinit();

    // Emit the real resource-loader line the codegen would produce for the
    // merged pack atlas, wrap it in a self-contained unit, and run Zig's
    // front-end over it. `@embedFile` is a Sema builtin, so AstGen accepts the
    // reference without the file existing.
    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    try resource_loader.emitResourceLoad(&aw.writer, merged.resources[0], .try_style);
    const body = aw.written();

    const unit = try std.fmt.allocPrint(allocator,
        \\const G = struct {{
        \\    fn loadAtlasFromMemory(_: *G, _: []const u8, _: []const u8, _: []const u8, _: []const u8) !void {{}}
        \\}};
        \\fn setup(g: *G) !void {{
        \\{s}}}
    , .{body});
    defer allocator.free(unit);
    try expectAstGenOk(allocator, unit);
}

test "autoWireScenes: a scene using a pack prefab preloads its non-lazy atlas" {
    const allocator = testing.allocator;
    const tio = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(tio, "scenes");
    try writeTestFile(tmp.dir, "scenes/main.jsonc",
        \\{ "entities": [ { "prefab": "terrain__tile" } ] }
    );
    const scenes_path = try tmp.dir.realPathFileAlloc(tio, "scenes", allocator);
    defer allocator.free(scenes_path);

    const manifest = plugin_manifest.PackManifest{
        .name = "terrain",
        .manifest_version = 1,
        .convention_dirs = .copy_and_scan,
        .resources = &.{
            .{ .name = "tiles", .json = "assets/tiles.json", .texture = "assets/tiles.png" },
            .{ .name = "props", .json = "assets/props.json", .texture = "assets/props.png", .lazy = true },
        },
        .allocator = allocator,
    };
    const entries = [_]PackEntry{.{ .plugin = .{ .name = "terrain" }, .manifest = manifest }};

    const empty: []const []const u8 = &.{};
    var manifests = [_]scene_manifest.SceneManifest{.{ .name = "main", .assets = empty }};
    try autoWireScenes(allocator, &manifests, &entries, scenes_path);
    defer for (manifests) |m| {
        for (m.assets) |s| allocator.free(s);
        if (m.assets.len > 0) allocator.free(m.assets);
    };

    // The non-lazy atlas is auto-added; the lazy one stays out (rides streaming).
    try testing.expectEqual(@as(usize, 1), manifests[0].assets.len);
    try testing.expectEqualStrings("terrain__tiles", manifests[0].assets[0]);
}

// ── test helpers ────────────────────────────────────────────────────

const plugin_manifest = @import("plugin_manifest.zig");
const resource_loader = @import("codegen/blocks/resource_loader.zig");

fn writeTestFile(dir: std.Io.Dir, rel: []const u8, body: []const u8) !void {
    const tio = testing.io;
    if (std.fs.path.dirname(rel)) |sub| try dir.createDirPath(tio, sub);
    var f = try dir.createFile(tio, rel, .{});
    defer f.close(tio);
    try f.writeStreamingAll(tio, body);
}

/// Local copy of the front-end check used across the codegen tests: parse +
/// AstGen `src`, failing on any parse or compile error. Self-contained — does
/// not resolve `@import`/`@embedFile` (those are Sema).
fn expectAstGenOk(allocator: std.mem.Allocator, src: []const u8) !void {
    const src_z = try allocator.dupeZ(u8, src);
    defer allocator.free(src_z);
    var ast = try std.zig.Ast.parse(allocator, src_z, .zig);
    defer ast.deinit(allocator);
    if (ast.errors.len != 0) return error.AstGenParseError;
    var zir = try std.zig.AstGen.generate(allocator, ast);
    defer zir.deinit(allocator);
    if (zir.hasCompileErrors()) return error.AstGenCompileError;
}
