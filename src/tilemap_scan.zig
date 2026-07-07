//! Tilemap asset embedding scan (T2 Phase 4, labelle-engine tilemap epic).
//!
//! A scene entity may carry a `Tilemap` component referencing a `.tmx`
//! map by `asset_name` (see `scene_manifest.collectTilemapAssets`). At
//! runtime labelle-engine (≥ v1.75.0) resolves that reference through a
//! single embedded registry it exposes on `Game`:
//!
//!   `game.addEmbeddedTilemapAsset(name, bytes)`  (game/tilemap_mixin.zig)
//!
//! populated by the assembler-generated `init()`. The SAME registry is
//! keyed by two kinds of name:
//!
//!   1. the scene's `asset_name` → the raw `.tmx` document bytes, and
//!   2. each tileset's `image_source` (the exact `<image source="...">`
//!      string as it appears in the `.tmx`) → that image's raw bytes.
//!
//! The engine decodes the `.tmx` via gfx's
//! `TileMap.loadFromMemoryWithBasePath(alloc, bytes, "")` and, for every
//! decoded tileset, calls an `ImageProvider.get(image_source)` that reads
//! back from this registry. **The image key is therefore load-bearing:**
//! the assembler MUST register each tileset image under the byte-identical
//! `image_source` string the `.tmx` carries (NOT the on-disk path), or the
//! runtime lookup misses and the tileset draws nothing.
//!
//! This module turns a deduped set of `asset_name`s into a flat list of
//! `Registration { key, embed_path }` — one per `.tmx` and one per unique
//! tileset image — that the lifecycle code-emitters render as
//! `@embedFile`-backed `addEmbeddedTilemapAsset` calls. Everything is
//! `@embedFile`/comptime; no runtime filesystem access is generated.
//!
//! **Path convention.** A scene's `asset_name` resolves to a `.tmx` under
//! the project's linked `assets/` dir: `assets/<asset_name>.tmx` (an
//! `asset_name` that already ends in `.tmx` is used as-is, so both
//! `"colony_map"` and `"colony_map.tmx"` work). The registry KEY stays the
//! verbatim `asset_name` — that is what the scene declares and the engine
//! looks up. Each tileset `image_source` is resolved relative to its
//! `.tmx`'s directory to form the `@embedFile` path, while the registry
//! key stays the verbatim `image_source`.

const std = @import("std");
const config = @import("config.zig");

/// One embedded-tilemap registration the generated `init()` must emit as
/// `addEmbeddedTilemapAsset("<key>", @embedFile("<embed_path>"))`.
pub const Registration = struct {
    /// Registry key the engine looks the bytes up by — the verbatim
    /// scene `asset_name` (for the `.tmx`) or the verbatim tileset
    /// `image_source` (for an image). Owned by the caller's allocator.
    key: []const u8,
    /// Path passed to `@embedFile`, relative to the generated `main.zig`
    /// (i.e. rooted at the target dir, e.g. `"assets/colony_map.tmx"`).
    /// Uses `/` separators so it is valid in generated Zig on every host.
    /// Owned by the caller's allocator.
    embed_path: []const u8,
};

pub const Error = error{
    TilemapAssetNotFound,
    TilemapKeyCollision,
} || std.mem.Allocator.Error;

fn stderrPrint(comptime fmt: []const u8, args: anytype) void {
    const io = config.globalIo();
    const stderr = std.Io.File.stderr();
    var buf: [4096]u8 = undefined;
    if (std.fmt.bufPrint(&buf, fmt, args)) |formatted| {
        stderr.writeStreamingAll(io, formatted) catch {};
    } else |_| {
        stderr.writeStreamingAll(io, fmt) catch {};
    }
}

/// The `@embedFile`-relative `.tmx` path for an `asset_name`. Appends
/// `.tmx` unless the name already carries it. Caller owns the result.
pub fn tmxEmbedPath(allocator: std.mem.Allocator, asset_name: []const u8) ![]u8 {
    if (std.mem.endsWith(u8, asset_name, ".tmx")) {
        return std.fmt.allocPrint(allocator, "assets/{s}", .{asset_name});
    }
    return std.fmt.allocPrint(allocator, "assets/{s}.tmx", .{asset_name});
}

/// Resolve a tileset `image_source` (relative to its `.tmx`) into the
/// `@embedFile`-relative image path, normalising `.`/`..` segments and
/// forcing `/` separators. `tmx_path` is the value from `tmxEmbedPath`.
/// Caller owns the result.
pub fn imageEmbedPath(
    allocator: std.mem.Allocator,
    tmx_path: []const u8,
    image_source: []const u8,
) ![]u8 {
    const base = posixDirname(tmx_path);
    const joined = if (base.len == 0)
        try allocator.dupe(u8, image_source)
    else
        try std.fmt.allocPrint(allocator, "{s}/{s}", .{ base, image_source });
    defer allocator.free(joined);
    return normalizePosix(allocator, joined);
}

/// Directory portion of a `/`-separated path (no trailing slash), or ""
/// when there is none.
fn posixDirname(path: []const u8) []const u8 {
    const idx = std.mem.lastIndexOfScalar(u8, path, '/') orelse return "";
    return path[0..idx];
}

/// Collapse `.` and `..` segments in a `/`-separated relative path.
/// Leading `..` that cannot be popped are preserved (defensive — inside
/// the assets tree this never happens, but a mis-authored `.tmx` should
/// fail its `@embedFile` with the real path rather than silently rebase).
fn normalizePosix(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    var parts: std.ArrayList([]const u8) = .empty;
    defer parts.deinit(allocator);

    var it = std.mem.splitScalar(u8, path, '/');
    while (it.next()) |seg| {
        if (seg.len == 0 or std.mem.eql(u8, seg, ".")) continue;
        if (std.mem.eql(u8, seg, "..")) {
            if (parts.items.len > 0 and !std.mem.eql(u8, parts.items[parts.items.len - 1], "..")) {
                _ = parts.pop();
            } else {
                try parts.append(allocator, seg);
            }
            continue;
        }
        try parts.append(allocator, seg);
    }

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    for (parts.items, 0..) |seg, i| {
        if (i != 0) try out.append(allocator, '/');
        try out.appendSlice(allocator, seg);
    }
    return out.toOwnedSlice(allocator);
}

/// Extract every tileset `<image source="...">` value from raw `.tmx`
/// bytes, in document order. Pure string scan — the assembler has no full
/// TMX parser and only needs the image references (the engine's gfx
/// decoder does the real parsing at runtime).
///
/// Handles inline-image tilesets — the T2 shape:
///   `<tileset ...><image source="tiles.png" .../></tileset>`
/// External `<tileset source="foo.tsx"/>` references carry no inline
/// `<image>` and are skipped (gfx can't load an external `.tsx` from
/// memory under the embedded base_path anyway). Returns owned dupes.
pub fn extractImageSources(allocator: std.mem.Allocator, tmx: []const u8) ![][]const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (out.items) |s| allocator.free(s);
        out.deinit(allocator);
    }

    var search: usize = 0;
    while (std.mem.indexOfPos(u8, tmx, search, "<image")) |tag_start| {
        // Bound the attribute search to this element so a later element's
        // `source="..."` can't be attributed to a `<image>` that had none.
        const tag_end = std.mem.indexOfPos(u8, tmx, tag_start, ">") orelse tmx.len;
        const tag = tmx[tag_start..tag_end];
        if (attrValue(tag, "source")) |src| {
            // XML-unescape the attribute value: `source="a&amp;b.png"` on
            // disk is `a&b.png`, and gfx's TMX parser hands the engine the
            // DECODED string — so both the `@embedFile` path and the
            // registry key must be decoded to match.
            try out.append(allocator, try xmlUnescape(allocator, src));
        }
        search = tag_end;
    }

    return out.toOwnedSlice(allocator);
}

/// Decode the standard XML predefined entities in an attribute value into a
/// freshly allocated string the caller owns: `&amp; &lt; &gt; &quot;
/// &apos;`. Any other `&…;` run is left verbatim (a real TMX from Tiled
/// only ever emits the five predefined entities in path attributes).
fn xmlUnescape(allocator: std.mem.Allocator, s: []const u8) ![]u8 {
    // No `&` → no entities; fast path keeps the common case a plain dupe.
    if (std.mem.indexOfScalar(u8, s, '&') == null) return allocator.dupe(u8, s);

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    const entities = [_]struct { name: []const u8, ch: u8 }{
        .{ .name = "&amp;", .ch = '&' },
        .{ .name = "&lt;", .ch = '<' },
        .{ .name = "&gt;", .ch = '>' },
        .{ .name = "&quot;", .ch = '"' },
        .{ .name = "&apos;", .ch = '\'' },
    };

    var i: usize = 0;
    outer: while (i < s.len) {
        if (s[i] == '&') {
            for (entities) |e| {
                if (std.mem.startsWith(u8, s[i..], e.name)) {
                    try out.append(allocator, e.ch);
                    i += e.name.len;
                    continue :outer;
                }
            }
        }
        try out.append(allocator, s[i]);
        i += 1;
    }
    return out.toOwnedSlice(allocator);
}

/// Return the value of `name="..."` inside a single tag slice, or null.
/// Matches on a `name="` needle preceded by whitespace (or at tag start,
/// after the `<image` token) so `foosource="x"` doesn't match `source`.
fn attrValue(tag: []const u8, name: []const u8) ?[]const u8 {
    var search: usize = 0;
    while (std.mem.indexOfPos(u8, tag, search, name)) |at| {
        const after = at + name.len;
        // Require `="` immediately after the attribute name.
        if (after + 1 < tag.len and tag[after] == '=' and tag[after + 1] == '"') {
            // Require a separator before the name (whitespace or `<`),
            // so `source` isn't matched inside another attribute name.
            const ok_before = at == 0 or tag[at - 1] == ' ' or tag[at - 1] == '\t' or
                tag[at - 1] == '\n' or tag[at - 1] == '\r' or tag[at - 1] == '<';
            if (ok_before) {
                const val_start = after + 2;
                const val_end = std.mem.indexOfScalarPos(u8, tag, val_start, '"') orelse return null;
                return tag[val_start..val_end];
            }
        }
        search = at + name.len;
    }
    return null;
}

/// Turn a set of scene-declared `asset_name`s into the flat list of
/// `addEmbeddedTilemapAsset` registrations the generated `init()` emits.
///
/// For each unique `asset_name`: registers the `.tmx` (key = `asset_name`,
/// embed = `assets/<asset_name>.tmx`), reads that `.tmx` from
/// `<target_dir>/<embed>`, and registers each unique tileset image
/// (key = XML-decoded `image_source`, embed = image path relative to the
/// `.tmx`). Registrations are deduped by key within each key space so a
/// tileset image shared by two maps — or a repeated `asset_name` — emits
/// once. A `.tmx` key that collides with an image key is a hard error
/// (`TilemapKeyCollision`); a missing `.tmx` is a hard build error
/// (`TilemapAssetNotFound`).
///
/// Caller frees via `freeRegistrations`.
pub fn collect(
    allocator: std.mem.Allocator,
    target_dir: []const u8,
    asset_names: []const []const u8,
) Error![]Registration {
    var regs: std.ArrayList(Registration) = .empty;
    errdefer {
        for (regs.items) |r| {
            allocator.free(r.key);
            allocator.free(r.embed_path);
        }
        regs.deinit(allocator);
    }

    // The `.tmx` documents and the tileset images share ONE engine registry
    // (`addEmbeddedTilemapAsset`), so a `.tmx` key and an image key that
    // collide would silently overwrite each other — the runtime would then
    // hand the wrong bytes to whichever lost. Track the two key spaces
    // separately: within a space, an identical key is a benign dedup (same
    // map / same shared image); ACROSS spaces it is a hard error.
    var tmx_seen = std.StringHashMap(void).init(allocator);
    defer tmx_seen.deinit();
    var img_seen = std.StringHashMap(void).init(allocator);
    defer img_seen.deinit();

    const io = config.globalIo();
    const cwd = std.Io.Dir.cwd();

    for (asset_names) |asset_name| {
        // Dedup the `.tmx` registration by its key (the asset_name).
        if (tmx_seen.contains(asset_name)) continue;
        // Cross-space collision: a tileset image already claimed this key.
        if (img_seen.contains(asset_name)) {
            stderrPrint(
                "labelle-assembler: tilemap key collision on '{s}' — a scene's Tilemap\n" ++
                    "  `asset_name` matches a tileset `<image source>` already embedded. Both share the\n" ++
                    "  engine's single tilemap registry; rename the `.tmx` asset or the tileset image.\n",
                .{asset_name},
            );
            return error.TilemapKeyCollision;
        }

        const tmx_embed = try tmxEmbedPath(allocator, asset_name);
        // From here `tmx_embed` is freed explicitly on every failure path
        // until it is handed to `regs` — no `errdefer` (which would linger
        // across the later image loop and double-free with the outer one).

        const disk_path = std.fs.path.join(allocator, &.{ target_dir, tmx_embed }) catch |err| {
            allocator.free(tmx_embed);
            return err;
        };
        defer allocator.free(disk_path);

        const tmx_bytes = cwd.readFileAlloc(io, disk_path, allocator, .limited(8 * 1024 * 1024)) catch |err| {
            stderrPrint(
                "labelle-assembler: tilemap asset '{s}' -> '{s}' could not be read: {s}\n" ++
                    "  A scene declares a Tilemap referencing this asset; place the map at\n" ++
                    "  '<project>/{s}' (T2 tilemap path convention).\n",
                .{ asset_name, disk_path, @errorName(err), tmx_embed },
            );
            allocator.free(tmx_embed);
            return error.TilemapAssetNotFound;
        };
        defer allocator.free(tmx_bytes);

        // Append the `.tmx` registration; once it is in `regs` the outer
        // errdefer owns both strings, so later failures free them exactly
        // once.
        const tmx_key = allocator.dupe(u8, asset_name) catch |err| {
            allocator.free(tmx_embed);
            return err;
        };
        regs.append(allocator, .{ .key = tmx_key, .embed_path = tmx_embed }) catch |err| {
            allocator.free(tmx_key);
            allocator.free(tmx_embed);
            return err;
        };
        // Store the DUPED key (owned by `regs`) in `tmx_seen`, not the
        // borrowed `asset_name` — uniform with the image side and robust if
        // the caller frees `asset_names` early.
        try tmx_seen.put(tmx_key, {});

        const images = try extractImageSources(allocator, tmx_bytes);
        defer {
            for (images) |s| allocator.free(s);
            allocator.free(images);
        }

        for (images) |image_source| {
            // Dedup images by their registry key (the decoded image_source):
            // a tileset image shared by two maps, or two tilesets in one map,
            // registers once.
            if (img_seen.contains(image_source)) continue;
            // Cross-space collision: a `.tmx` already claimed this key.
            if (tmx_seen.contains(image_source)) {
                stderrPrint(
                    "labelle-assembler: tilemap key collision on '{s}' — a tileset `<image source>`\n" ++
                        "  matches a scene's Tilemap `asset_name` already embedded. Both share the engine's\n" ++
                        "  single tilemap registry; rename the tileset image or the `.tmx` asset.\n",
                    .{image_source},
                );
                return error.TilemapKeyCollision;
            }

            const img_embed = try imageEmbedPath(allocator, tmx_embed, image_source);
            const key = allocator.dupe(u8, image_source) catch |err| {
                allocator.free(img_embed);
                return err;
            };
            regs.append(allocator, .{ .key = key, .embed_path = img_embed }) catch |err| {
                allocator.free(key);
                allocator.free(img_embed);
                return err;
            };
            // Store the DUPED key (owned by `regs`) in `img_seen`, not the
            // soon-freed `image_source`, so cross-map dedup lookups never
            // read freed memory.
            try img_seen.put(key, {});
        }
    }

    return regs.toOwnedSlice(allocator);
}

pub fn freeRegistrations(allocator: std.mem.Allocator, regs: []const Registration) void {
    for (regs) |r| {
        allocator.free(r.key);
        allocator.free(r.embed_path);
    }
    allocator.free(regs);
}
