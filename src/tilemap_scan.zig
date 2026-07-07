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
    ExternalTilesetUnsupported,
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
///
/// **Windows separators.** A Tiled map authored on Windows can emit
/// `source="tiles\terrain.png"`. The copied asset lives at
/// `assets/tiles/terrain.png` on any builder, so backslash separators are
/// normalised to `/` for the `@embedFile` PATH here. The registry KEY,
/// however, stays the raw `image_source` (backslash intact) — gfx v1.21.0
/// keeps `image_source` verbatim, so that is the string the engine's
/// `ImageProvider.get` looks up (see `extractImageSources`).
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
    // Windows `\` separators → `/` before segment normalisation, so a
    // backslash-authored source resolves to the copied asset's real path.
    for (joined) |*c| {
        if (c.* == '\\') c.* = '/';
    }
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

/// Extract every TILESET `<image source="...">` value from raw `.tmx`
/// bytes, in document order. Pure string scan — the assembler has no full
/// TMX parser and only needs the image references (the engine's gfx
/// decoder does the real parsing at runtime).
///
/// **Tileset-scoped.** Only `<image>` elements INSIDE a `<tileset>…</tileset>`
/// are collected. The engine's `ImageProvider` is queried only for decoded
/// TILESET images, so an `<imagelayer><image source="bg.png"/></imagelayer>`
/// (a background image layer) must NOT be embedded — the runtime never
/// requests it, and embedding it could require an absent file or collide.
///
/// **Raw values.** The returned source is the VERBATIM attribute-value
/// bytes — no XML-entity decoding and no `\`→`/` normalization. gfx v1.21.0's
/// TMX parser stores `image_source` as a raw dupe (`tilemap/src/root.zig`
/// `parseAttributes` + `tileset.image_source = dupe(src)`), so the engine's
/// `ImageProvider.get` looks up by the raw string — the registry key MUST
/// match it byte-for-byte. (The `@embedFile` PATH is normalized separately in
/// `imageEmbedPath`.) Returns owned dupes.
pub fn extractImageSources(allocator: std.mem.Allocator, tmx: []const u8) ![][]const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (out.items) |s| allocator.free(s);
        out.deinit(allocator);
    }

    var search: usize = 0;
    while (indexOfTagSkippingComments(tmx, search, "<tileset")) |ts_start| {
        const ts_tag_end = std.mem.indexOfPos(u8, tmx, ts_start, ">") orelse tmx.len;
        // A self-closed `<tileset .../>` (external or empty) has no inner
        // `<image>` child — nothing to scan; advance past its opening tag.
        if (ts_tag_end > ts_start and tmx[ts_tag_end - 1] == '/') {
            search = ts_tag_end;
            continue;
        }
        // Bound the `<image>` scan to THIS tileset's content span so an
        // imagelayer / object image after `</tileset>` is never attributed
        // to it.
        const ts_close = std.mem.indexOfPos(u8, tmx, ts_tag_end, "</tileset>") orelse tmx.len;
        var isearch = ts_tag_end;
        while (indexOfTagSkippingComments(tmx, isearch, "<image")) |img_start| {
            if (img_start >= ts_close) break;
            // Bound the attr search to this element so a later element's
            // `source=` can't be attributed to an `<image>` that had none.
            const img_tag_end = std.mem.indexOfPos(u8, tmx, img_start, ">") orelse tmx.len;
            const tag = tmx[img_start..img_tag_end];
            if (attrValue(tag, "source")) |src| {
                try out.append(allocator, try allocator.dupe(u8, src));
            }
            isearch = img_tag_end;
        }
        search = ts_close;
    }

    return out.toOwnedSlice(allocator);
}

/// Return the `source` of the FIRST external `<tileset ... source="...">`
/// — a tileset that references an external `.tsx` file instead of carrying
/// an inline `<image>` — or null when every tileset is inline. The opening
/// `<tileset …>` tag of an inline tileset has NO `source` attribute (that
/// lives on the inner `<image>`), so a `source` on the tileset element is
/// the external marker. Minimal-T2 embeds inline tilesets only; `collect`
/// fails loud on an external one (assembler#563).
pub fn firstExternalTileset(tmx: []const u8) ?[]const u8 {
    var search: usize = 0;
    while (indexOfTagSkippingComments(tmx, search, "<tileset")) |tag_start| {
        const tag_end = std.mem.indexOfPos(u8, tmx, tag_start, ">") orelse tmx.len;
        const tag = tmx[tag_start..tag_end];
        if (attrValue(tag, "source")) |src| return src;
        if (tag_end >= tmx.len) break;
        search = tag_end + 1;
    }
    return null;
}

/// Find the next occurrence of `needle` in `tmx` at or after `from` that is
/// NOT inside an XML comment (`<!-- ... -->`), or null. XML comments in a
/// `.tmx` — e.g. a commented-out `<!-- <image source="old.png"/> -->` — must
/// not yield a registration (the generated `@embedFile` would reference an
/// asset the map never requests, breaking the build or embedding dead bytes).
/// An unterminated comment swallows the rest of the document (fail-closed).
fn indexOfTagSkippingComments(tmx: []const u8, from: usize, needle: []const u8) ?usize {
    var i = from;
    while (true) {
        const hit = std.mem.indexOfPos(u8, tmx, i, needle) orelse return null;
        // Is there a comment opening at/after `i` but BEFORE this hit? If so
        // the hit may sit inside it — skip past the comment and re-search.
        if (std.mem.indexOfPos(u8, tmx, i, "<!--")) |c| {
            if (c < hit) {
                const end = std.mem.indexOfPos(u8, tmx, c + 4, "-->") orelse return null;
                i = end + 3;
                continue;
            }
        }
        return hit;
    }
}

/// Return the raw value of the `name` attribute inside a
/// single tag slice, or null. Tolerates the legal XML variations Tiled and
/// hand-authored maps emit: optional whitespace around `=`, and either
/// double or single quotes (`source="x"`, `source = "x"`, `source='x'`).
/// A separator (whitespace / `<`) must precede the name so `source` isn't
/// matched inside another attribute name (`foosource="x"`). Still a tight
/// scan, not a full XML parser.
fn attrValue(tag: []const u8, name: []const u8) ?[]const u8 {
    var search: usize = 0;
    while (std.mem.indexOfPos(u8, tag, search, name)) |at| {
        search = at + name.len;
        // Require a separator before the name (whitespace or `<`).
        const ok_before = at == 0 or isXmlSpace(tag[at - 1]) or tag[at - 1] == '<';
        if (!ok_before) continue;

        // Skip whitespace, then require `=`, then whitespace, then a quote.
        var i = at + name.len;
        while (i < tag.len and isXmlSpace(tag[i])) : (i += 1) {}
        if (i >= tag.len or tag[i] != '=') continue;
        i += 1;
        while (i < tag.len and isXmlSpace(tag[i])) : (i += 1) {}
        if (i >= tag.len or (tag[i] != '"' and tag[i] != '\'')) continue;
        const quote = tag[i];
        const val_start = i + 1;
        const val_end = std.mem.indexOfScalarPos(u8, tag, val_start, quote) orelse return null;
        return tag[val_start..val_end];
    }
    return null;
}

fn isXmlSpace(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\n' or c == '\r';
}

/// Turn a set of scene-declared `asset_name`s into the flat list of
/// `addEmbeddedTilemapAsset` registrations the generated `init()` emits.
///
/// For each unique `asset_name`: registers the `.tmx` (key = `asset_name`,
/// embed = `assets/<asset_name>.tmx`), reads that `.tmx` from
/// `<target_dir>/<embed>`, and registers each unique tileset image
/// (key = XML-decoded `image_source`, embed = image path relative to the
/// `.tmx`). A tileset image shared by two maps — or a repeated `asset_name`
/// — emits once. Hard errors: a `.tmx` key colliding with an image key, or
/// the same image key resolving to two different files (`TilemapKeyCollision`);
/// an external `<tileset source="*.tsx">` (`ExternalTilesetUnsupported`,
/// assembler#563); a missing `.tmx` (`TilemapAssetNotFound`).
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
    // (`addEmbeddedTilemapAsset`), so keys that collide would silently
    // overwrite each other — the runtime would then hand the wrong bytes to
    // whichever lost. Guard three ways:
    //   - a `.tmx` key equal to an image key (ACROSS spaces) → hard error;
    //   - the SAME image key resolving to DIFFERENT embed paths (e.g. two
    //     maps in different dirs both referencing `source="tiles.png"`) →
    //     hard error (the second would otherwise silently reuse the first's
    //     bytes). `img_seen` therefore maps key → resolved embed path so a
    //     same-key-DIFFERENT-path clash is caught; same-key-same-path stays
    //     a benign dedup;
    //   - a repeated `.tmx` `asset_name` (SAME space) → benign dedup.
    var tmx_seen = std.StringHashMap(void).init(allocator);
    defer tmx_seen.deinit();
    var img_seen = std.StringHashMap([]const u8).init(allocator);
    defer img_seen.deinit();

    const io = config.globalIo();
    const cwd = std.Io.Dir.cwd();

    for (asset_names) |asset_name| {
        // Dedup the `.tmx` registration by its key (the asset_name).
        if (tmx_seen.contains(asset_name)) continue;
        // Each map is parsed in its own frame (`processMap`) so the `.tmx`
        // bytes (up to 8 MiB) + the extracted image slice free at the END of
        // that map — a project with many large maps never retains more than
        // one map's buffers at once. Registrations + `*_seen` keys are copied
        // into `regs` (program-lifetime) before those per-map buffers free.
        try processMap(allocator, target_dir, io, cwd, asset_name, &regs, &tmx_seen, &img_seen);
    }

    return regs.toOwnedSlice(allocator);
}

/// Read + scan ONE `.tmx`, appending its `.tmx` + tileset-image registrations
/// to `regs` and recording their keys in `tmx_seen` / `img_seen`. The `.tmx`
/// byte buffer and the extracted `image_source` slice are freed on return
/// (per-map lifetime); everything appended to `regs` is dup'd first, so it
/// safely outlives this frame. Errors propagate to `collect`, whose errdefer
/// frees `regs`.
fn processMap(
    allocator: std.mem.Allocator,
    target_dir: []const u8,
    io: std.Io,
    cwd: std.Io.Dir,
    asset_name: []const u8,
    regs: *std.ArrayList(Registration),
    tmx_seen: *std.StringHashMap(void),
    img_seen: *std.StringHashMap([]const u8),
) Error!void {
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
    // From here `tmx_embed` is freed explicitly on every failure path until
    // it is handed to `regs` — no `errdefer` (which would linger across the
    // later image loop and double-free with the outer one).

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

    // External `<tileset source="*.tsx">` isn't embedded in minimal-T2:
    // gfx's loader returns error.ExternalTilesetUnsupported for it under
    // the embedded base_path, so the map would fail at runtime. Fail loud
    // now with the offending `.tsx` named (assembler#563).
    if (firstExternalTileset(tmx_bytes)) |tsx| {
        stderrPrint(
            "labelle-assembler: tilemap '{s}' uses an external tileset '{s}' (<tileset source=...>),\n" ++
                "  which is not supported yet (minimal-T2 embeds inline tilesets only). Inline the\n" ++
                "  tileset in the .tmx, or track external-tileset support at labelle-assembler#563.\n",
            .{ asset_name, tsx },
        );
        allocator.free(tmx_embed); // not yet handed to `regs`
        return error.ExternalTilesetUnsupported;
    }

    // Append the `.tmx` registration; once it is in `regs` the outer errdefer
    // owns both strings, so later failures free them exactly once.
    const tmx_key = allocator.dupe(u8, asset_name) catch |err| {
        allocator.free(tmx_embed);
        return err;
    };
    regs.append(allocator, .{ .key = tmx_key, .embed_path = tmx_embed }) catch |err| {
        allocator.free(tmx_key);
        allocator.free(tmx_embed);
        return err;
    };
    // Store the DUPED key (owned by `regs`) in `tmx_seen`, not the borrowed
    // `asset_name` — uniform with the image side and robust if the caller
    // frees `asset_names` early.
    try tmx_seen.put(tmx_key, {});

    const images = try extractImageSources(allocator, tmx_bytes);
    defer {
        for (images) |s| allocator.free(s);
        allocator.free(images);
    }

    for (images) |image_source| {
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

        // Resolve the embed path up front so a same-key dedup can compare
        // the RESOLVED path, not just the key.
        const img_embed = try imageEmbedPath(allocator, tmx_embed, image_source);

        if (img_seen.get(image_source)) |existing_path| {
            // Same registry key seen before. If it resolves to the SAME file
            // it's a benign dedup; a DIFFERENT file under the same key would
            // make the runtime hand the wrong bytes — hard error.
            if (!std.mem.eql(u8, existing_path, img_embed)) {
                stderrPrint(
                    "labelle-assembler: tilemap image key collision on '{s}' — two tilesets resolve it\n" ++
                        "  to different files ('{s}' vs '{s}'), but the engine keys images by the bare\n" ++
                        "  `<image source>` string. Give the images distinct source names.\n",
                    .{ image_source, existing_path, img_embed },
                );
                allocator.free(img_embed);
                return error.TilemapKeyCollision;
            }
            allocator.free(img_embed);
            continue;
        }

        const key = allocator.dupe(u8, image_source) catch |err| {
            allocator.free(img_embed);
            return err;
        };
        regs.append(allocator, .{ .key = key, .embed_path = img_embed }) catch |err| {
            allocator.free(key);
            allocator.free(img_embed);
            return err;
        };
        // Store the DUPED key + its resolved path (both owned by `regs`) so
        // later dedup lookups never read freed memory and can compare paths.
        // `key` is the registration's key; `img_embed` its path.
        try img_seen.put(key, img_embed);
    }
}

pub fn freeRegistrations(allocator: std.mem.Allocator, regs: []const Registration) void {
    for (regs) |r| {
        allocator.free(r.key);
        allocator.free(r.embed_path);
    }
    allocator.free(regs);
}
