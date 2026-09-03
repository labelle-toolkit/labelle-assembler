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
//! keyed by three kinds of name:
//!
//!   1. the scene's `asset_name` → the raw `.tmx` document bytes,
//!   2. each tileset's `image_source` (the exact `<image source="...">`
//!      string as it appears in the `.tmx`) → that image's raw bytes, and
//!   3. each external `<tileset source="...">` reference (the exact string
//!      as written in the `.tmx`) → that `.tsx` document's raw bytes
//!      (labelle-assembler#678, completing labelle-gfx#336).
//!
//! **Engine floor.** Embedding a `.tsx` is only half of external-tileset
//! support: the engine has to hand gfx a `tsx_resolver` backed by this
//! registry (labelle-engine#834). Until the pinned engine is new enough
//! (`MIN_ENGINE_FOR_EXTERNAL_TILESETS`) a map with an external tileset is
//! REJECTED at generate time, exactly as it was before #678 — a loud build
//! error is strictly better than a map that decodes to nothing at runtime.
//!
//! **External tilesets (`.tsx`).** gfx#336 gave the TMX loader a
//! `LoadOptions.tsx_resolver` seam: `resolve(source)` is called with the
//! `source` attribute EXACTLY as written in the `.tmx` — never joined onto
//! a base path — and returns the `.tsx` XML bytes. The engine backs that
//! resolver with the very registry `addEmbeddedTilemapAsset` populates, so
//! embedding a `.tsx` under its verbatim `source` string is the whole of
//! the wiring: the generated `init()` call IS the resolver's table entry.
//! Get that key wrong and the resolver silently claims nothing.
//!
//! The `<image source>` INSIDE a `.tsx` needs a second translation. It is
//! relative to the `.tsx`'s own directory, which need not be the map's, so
//! gfx rebases it through `joinRelative(dirname(source), image_source)`
//! before storing it on the decoded `Tileset` — and the engine's
//! `ImageProvider.get` is then called with that REBASED string. The
//! registry key for such an image is therefore the rebased value
//! (`tsxImageKey` here), not the raw one the `.tsx` carries.
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
//! key stays the verbatim `image_source`. An external `<tileset source>`
//! resolves the same way (relative to the `.tmx`) for its `@embedFile`
//! path; the `.tsx`'s OWN `<image source>` resolves relative to the
//! `.tsx`'s directory instead.

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
    /// An external `<tileset source="…tsx">` named a file that is not on
    /// disk under the linked `assets/` tree (#678).
    ExternalTilesetNotFound,
    TilemapKeyCollision,
    /// A shape gfx's loader itself refuses — today: a `.tsx` whose root
    /// `<tileset>` only points at ANOTHER `.tsx`.
    ExternalTilesetUnsupported,
    /// The pinned engine predates the runtime half of external-tileset
    /// support (labelle-engine#834) — see `MIN_ENGINE_FOR_EXTERNAL_TILESETS`.
    EngineTooOldForExternalTilesets,
} || std.mem.Allocator.Error;

// ── Engine-version gate (labelle-engine#834) ────────────────────────────

/// First engine release whose tilemap runtime hands gfx a `tsx_resolver`
/// backed by the embedded registry — i.e. the first release that can
/// actually CONSUME what this module embeds for an external `.tsx`.
///
/// **Why a gate at all.** Embedding is only half the feature. The engine's
/// `tilemap_runtime.initInPlace` calls
/// `TileMap.loadFromMemoryWithBasePath(alloc, tmx_bytes, "")`, which is
/// `loadFromMemoryWithOptions(…, .{})` — no `tsx_resolver`, and an empty
/// `base_path` forces `read_external_from_filesystem = false`. gfx's
/// `resolveExternalTileset` then returns `error.ExternalTilesetUnsupported`
/// for every external reference, which `game/tilemap_mixin.zig` swallows
/// into a `log.warn` and a missing tilemap. Without this gate, following a
/// `.tsx` would trade a loud GENERATE-time error for a quiet RUNTIME one —
/// strictly worse to diagnose, even though the assembler got more capable.
///
/// **Provisional value.** labelle-engine#834 has not shipped; the engine's
/// latest release is v2.13.0, so v2.14.0 is the earliest it can appear in.
/// Bump this if the engine-side change slips to a later minor — that is the
/// only edit needed once it lands (same contract as
/// `scene_manifest.MIN_ENGINE_FOR_TARGET_OVERRIDES`).
pub const MIN_ENGINE_FOR_EXTERNAL_TILESETS = "2.14.0";

/// Knobs for `collectWithOptions`. `collect` uses the defaults.
pub const Options = struct {
    /// The project's pinned `engine_version` (`project.labelle`). Decides
    /// whether an external `<tileset source>` may be followed at all — see
    /// `MIN_ENGINE_FOR_EXTERNAL_TILESETS`. Defaults to the curated pin so a
    /// caller that forgets to thread it gets the conservative answer.
    engine_version: []const u8 = config.ENGINE_VERSION,
};

/// Per-generation state for the external-tileset gate: the verdict, plus a
/// latch so the "cannot verify" note is printed once, not once per map.
const ExternalTilesetGate = struct {
    support: config.FeatureSupport,
    engine_version: []const u8,
    noted: bool = false,

    fn init(engine_version: []const u8) ExternalTilesetGate {
        return .{
            .support = config.engineFeatureSupport(engine_version, MIN_ENGINE_FOR_EXTERNAL_TILESETS),
            .engine_version = engine_version,
        };
    }

    /// Called once per map that has at least one external `<tileset source>`,
    /// with the first such reference for the diagnostic.
    fn check(self: *ExternalTilesetGate, asset_name: []const u8, source: []const u8) Error!void {
        switch (self.support) {
            .yes => {},
            .no => {
                stderrPrint(
                    "labelle-assembler: tilemap '{s}' references the external tileset '{s}'\n" ++
                        "  (<tileset source=...>), but the pinned engine v{s} cannot load one from an\n" ++
                        "  EMBEDDED build (needs >= v{s}). Its `tilemap_runtime.initInPlace` calls gfx's\n" ++
                        "  loader with NO `tsx_resolver` (labelle-engine#834), so the embedded `.tsx`\n" ++
                        "  bytes would never be consulted: the map would fail to decode at RUNTIME with\n" ++
                        "  `ExternalTilesetUnsupported`, logged as a warning and drawn as nothing.\n" ++
                        "  Bump `engine_version` in project.labelle once #834 ships, or embed the tileset\n" ++
                        "  into the `.tmx` in Tiled (Map > Embed Tileset).\n",
                    .{ asset_name, source, self.engine_version, MIN_ENGINE_FOR_EXTERNAL_TILESETS },
                );
                return error.EngineTooOldForExternalTilesets;
            },
            .unverifiable => {
                // A `local:` override or branch pin is a deliberate dev setup
                // (quite possibly the one developing #834), so this must not
                // hard-fail — but it must not be SILENT either: if that engine
                // predates the resolver the failure moves to runtime.
                if (self.noted) return;
                self.noted = true;
                stderrPrint(
                    "labelle-assembler: note: tilemap '{s}' embeds the external tileset '{s}', but the\n" ++
                        "  pinned engine '{s}' is not a release version, so the assembler cannot verify it\n" ++
                        "  wires the embedded `.tsx` into gfx's `LoadOptions.tsx_resolver`\n" ++
                        "  (labelle-engine#834, expected in >= v{s}). An engine without it fails to decode\n" ++
                        "  the map at RUNTIME with `ExternalTilesetUnsupported`.\n",
                    .{ asset_name, source, self.engine_version, MIN_ENGINE_FOR_EXTERNAL_TILESETS },
                );
            },
        }
    }
};

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
/// the external marker. `collect` now FOLLOWS external references
/// (assembler#678); this stays as the cheap "is there any" probe, and is what
/// detects a `.tsx` that chains to another `.tsx` (which gfx refuses).
/// See `extractExternalTilesets` for the full, ordered list.
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

/// Every external `<tileset ... source="...">` reference in `tmx`, in
/// document order, as VERBATIM attribute-value bytes. This is the string
/// gfx's `LoadOptions.tsx_resolver.resolve` is handed — the reference as
/// written, NOT joined onto any base path — so it is the registry key the
/// `.tsx` bytes must be embedded under. Returns owned dupes; duplicates
/// within one map are returned as-is (`collect` dedups by key).
pub fn extractExternalTilesets(allocator: std.mem.Allocator, tmx: []const u8) ![][]const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (out.items) |s| allocator.free(s);
        out.deinit(allocator);
    }

    var search: usize = 0;
    while (indexOfTagSkippingComments(tmx, search, "<tileset")) |tag_start| {
        const tag_end = std.mem.indexOfPos(u8, tmx, tag_start, ">") orelse tmx.len;
        const tag = tmx[tag_start..tag_end];
        if (attrValue(tag, "source")) |src| {
            try out.append(allocator, try allocator.dupe(u8, src));
        }
        if (tag_end >= tmx.len) break;
        search = tag_end + 1;
    }

    return out.toOwnedSlice(allocator);
}

/// Which host's `std.fs.path.dirname` the RUNTIME will use when gfx rebases
/// a `.tsx`'s `<image source>`. gfx calls the generic `std.fs.path.dirname`,
/// which is `dirnamePosix` (only `/` separates) or `dirnameWindows` (`/` and
/// `\` both separate) depending on the TARGET the game is built for — a
/// choice made at `zig build` time, i.e. AFTER generation. The assembler
/// therefore cannot pick one; it registers under both when they differ
/// (see `processExternalTileset`).
pub const Separators = enum {
    posix,
    windows,

    /// Index of the last directory separator, mirroring the corresponding
    /// `std.fs.path.dirname` implementation's separator set. The
    /// drive-relative `C:foo` shape (which `dirnameWindows` also splits, at
    /// the colon) is not modelled — Tiled never writes it, and a `.tsx`
    /// reference bound to a drive letter could not be embedded anyway.
    fn lastSeparator(self: Separators, path: []const u8) ?usize {
        return switch (self) {
            .posix => std.mem.lastIndexOfScalar(u8, path, '/'),
            .windows => std.mem.lastIndexOfAny(u8, path, "/\\"),
        };
    }
};

/// The registry KEY under which a `.tsx`'s own `<image source>` must be
/// embedded — i.e. what the engine's `ImageProvider.get` will be called
/// with for a tileset that came from an external reference.
///
/// This MUST mirror gfx's `resolveExternalTileset` byte-for-byte
/// (labelle-gfx#336): after parsing the `.tsx` it rewrites
/// `tileset.image_source` to `joinRelative(dirname(tsx_source),
/// image_source)` — rebasing the `.tsx`-relative path onto the MAP's
/// directory — but ONLY when the reference has a directory component. A
/// bare `source="Overworld.tsx"` has no dirname, so the image source stays
/// exactly as the `.tsx` wrote it (`"../Sheet.png"` and all).
///
/// **Separators.** Tiled writes `/` on every host, and for a `/`-only
/// reference both `seps` modes give the same answer. They diverge only for
/// a hand-authored / Windows-tool-authored `source="tilesets\terrain.tsx"`:
/// a Windows runtime's `dirname` sees `tilesets` and rebases, a POSIX
/// runtime sees no directory and keeps the raw name. Which one the game
/// gets is decided by the build target, long after generation — so the
/// caller asks for both and registers each (codex P2 on #684). Caller owns
/// the result.
pub fn tsxImageKey(
    allocator: std.mem.Allocator,
    tsx_source: []const u8,
    image_source: []const u8,
    seps: Separators,
) ![]u8 {
    const idx = seps.lastSeparator(tsx_source) orelse
        return allocator.dupe(u8, image_source);
    return joinRelative(allocator, tsx_source[0..idx], image_source);
}

/// Port of gfx#336's `joinRelative`: join `dir` (relative to the map) with
/// `rel` (relative to `dir`), collapsing `.`/`..` so the result stays
/// relative to the MAP's directory. Purely textual — the value is a
/// catalog lookup key as much as a path, so it must not depend on the
/// process cwd. A leading `..` survives; an absolute `rel` passes through.
fn joinRelative(allocator: std.mem.Allocator, dir: []const u8, rel: []const u8) ![]u8 {
    if (std.fs.path.isAbsolute(rel)) return allocator.dupe(u8, rel);

    // Tokenizing drops the leading separator, so an absolute `dir` would come
    // back RELATIVE. Capture the root VERBATIM and put it back — on Windows
    // that root is `C:\` or `\\server\share\`, not `/`, so rebuilding it as
    // `/` would turn `C:\tilesets` into `/C:/tilesets` and collapse a UNC
    // root to one slash. Mirrors gfx's `joinRelative` after its own Windows-
    // roots fix (labelle-gfx#336) — the two must agree byte-for-byte.
    const absolute = std.fs.path.isAbsolute(dir);
    const root: []const u8 = if (absolute) blk: {
        var it = std.fs.path.componentIterator(dir);
        break :blk it.root() orelse "/";
    } else "";

    var parts: std.ArrayList([]const u8) = .empty;
    defer parts.deinit(allocator);

    // `dir` is tokenized past its root so the root's own bytes (`C:`) are not
    // re-emitted as an ordinary component after the prefix.
    for ([_][]const u8{ dir[root.len..], rel }) |path| {
        var it = std.mem.tokenizeAny(u8, path, "/\\");
        while (it.next()) |part| {
            if (std.mem.eql(u8, part, ".")) continue;
            if (std.mem.eql(u8, part, "..")) {
                if (parts.items.len > 0 and !std.mem.eql(u8, parts.items[parts.items.len - 1], "..")) {
                    _ = parts.pop();
                    continue;
                }
                // The root is its own parent: `/a/../..` stays `/`.
                if (absolute) continue;
            }
            try parts.append(allocator, part);
        }
    }

    const joined = try std.mem.join(allocator, "/", parts.items);
    if (!absolute) return joined;
    defer allocator.free(joined);
    // A root usually carries its own trailing separator (`/`, `C:\`), but a
    // bare UNC share (`\\server\share`, what `dirname` leaves when the `.tsx`
    // sits at the share root) does not — supply one.
    const sep: []const u8 = if (std.fs.path.isSep(root[root.len - 1])) "" else std.fs.path.sep_str;
    return std.mem.concat(allocator, u8, &.{ root, sep, joined });
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
/// (key = verbatim `image_source`, embed = image path relative to the
/// `.tmx`).
///
/// External tilesets (#678) are FOLLOWED, not rejected: each
/// `<tileset source="X.tsx">` registers the `.tsx` bytes under the verbatim
/// `source` (the key gfx#336's `tsx_resolver` looks up) and the image the
/// `.tsx` names under `tsxImageKey(source, image_source)` (the rebased value
/// gfx stores on the decoded tileset). A `.tsx` — or a tileset image — shared
/// by two maps, or a repeated `asset_name`, emits once.
///
/// Following an external tileset is GATED on the pinned engine version
/// (`MIN_ENGINE_FOR_EXTERNAL_TILESETS`): an engine that predates
/// labelle-engine#834 never hands gfx a `tsx_resolver`, so embedding for it
/// would swap a generate-time error for a silent runtime one. `collect` uses
/// the curated default pin; `collectWithOptions` takes the project's.
///
/// Hard errors: a `.tmx` key colliding with a tileset-asset key, or the same
/// key resolving to two different files (`TilemapKeyCollision`); a missing
/// `.tmx` (`TilemapAssetNotFound`); an external tileset under too old an
/// engine pin (`EngineTooOldForExternalTilesets`); a missing `.tsx`
/// (`ExternalTilesetNotFound`); a `.tsx` chaining to another `.tsx`
/// (`ExternalTilesetUnsupported`, which gfx's loader itself refuses).
///
/// Caller frees via `freeRegistrations`.
pub fn collect(
    allocator: std.mem.Allocator,
    target_dir: []const u8,
    asset_names: []const []const u8,
) Error![]Registration {
    return collectWithOptions(allocator, target_dir, asset_names, .{});
}

/// `collect` with explicit `Options` — notably the project's pinned
/// `engine_version`, which decides whether external `.tsx` tilesets may be
/// followed (`MIN_ENGINE_FOR_EXTERNAL_TILESETS`).
pub fn collectWithOptions(
    allocator: std.mem.Allocator,
    target_dir: []const u8,
    asset_names: []const []const u8,
    options: Options,
) Error![]Registration {
    var gate: ExternalTilesetGate = .init(options.engine_version);

    var regs: std.ArrayList(Registration) = .empty;
    errdefer {
        for (regs.items) |r| {
            allocator.free(r.key);
            allocator.free(r.embed_path);
        }
        regs.deinit(allocator);
    }

    // The `.tmx` documents, the tileset images AND the external `.tsx`
    // documents share ONE engine registry (`addEmbeddedTilemapAsset`), so
    // keys that collide would silently overwrite each other — the runtime
    // would then hand the wrong bytes to whichever lost. Guard three ways
    // (see `registerAsset`):
    //   - a `.tmx` key equal to a tileset-asset key (ACROSS spaces) → hard
    //     error;
    //   - the SAME tileset-asset key resolving to DIFFERENT embed paths (e.g.
    //     two maps in different dirs both referencing `source="tiles.png"` or
    //     `source="Terrain.tsx"`) → hard error. `asset_seen` therefore maps
    //     key → resolved embed path so a same-key-DIFFERENT-path clash is
    //     caught; same-key-same-path stays a benign dedup (which is also how
    //     one `.tsx` shared by many maps embeds exactly once);
    //   - a repeated `.tmx` `asset_name` (SAME space) → benign dedup.
    var tmx_seen = std.StringHashMap(void).init(allocator);
    defer tmx_seen.deinit();
    var asset_seen = std.StringHashMap([]const u8).init(allocator);
    defer asset_seen.deinit();

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
        try processMap(allocator, target_dir, io, cwd, asset_name, &regs, &tmx_seen, &asset_seen, &gate);
    }

    return regs.toOwnedSlice(allocator);
}

/// Read + scan ONE `.tmx`, appending its `.tmx`, tileset-image, external
/// `.tsx` and `.tsx`-image registrations to `regs` and recording their keys
/// in `tmx_seen` / `asset_seen`. The `.tmx` byte buffer and the extracted
/// slices are freed on return (per-map lifetime); everything appended to
/// `regs` is dup'd first, so it safely outlives this frame. Errors propagate
/// to `collect`, whose errdefer frees `regs`.
fn processMap(
    allocator: std.mem.Allocator,
    target_dir: []const u8,
    io: std.Io,
    cwd: std.Io.Dir,
    asset_name: []const u8,
    regs: *std.ArrayList(Registration),
    tmx_seen: *std.StringHashMap(void),
    asset_seen: *std.StringHashMap([]const u8),
    gate: *ExternalTilesetGate,
) Error!void {
    // Cross-space collision: a tileset asset already claimed this key.
    if (asset_seen.contains(asset_name)) {
        stderrPrint(
            "labelle-assembler: tilemap key collision on '{s}' — a scene's Tilemap\n" ++
                "  `asset_name` matches a tileset asset (`<image source>` / `.tsx`) already\n" ++
                "  embedded. Both share the engine's single tilemap registry; rename the `.tmx`\n" ++
                "  asset or the tileset asset.\n",
            .{asset_name},
        );
        return error.TilemapKeyCollision;
    }

    const tmx_embed = try tmxEmbedPath(allocator, asset_name);
    // From here `tmx_embed` is freed explicitly on every failure path until
    // it is handed to `regs` — no `errdefer` (which would linger across the
    // later loops and double-free with the outer one).

    const tmx_bytes = readAsset(allocator, io, cwd, target_dir, tmx_embed) catch |err| {
        stderrPrint(
            "labelle-assembler: tilemap asset '{s}' -> '{s}/{s}' could not be read: {s}\n" ++
                "  A scene declares a Tilemap referencing this asset; place the map at\n" ++
                "  '<project>/{s}' (T2 tilemap path convention).\n",
            .{ asset_name, target_dir, tmx_embed, @errorName(err), tmx_embed },
        );
        allocator.free(tmx_embed);
        return if (err == error.OutOfMemory) error.OutOfMemory else error.TilemapAssetNotFound;
    };
    defer allocator.free(tmx_bytes);

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
    // `asset_name` — uniform with the asset side and robust if the caller
    // frees `asset_names` early.
    try tmx_seen.put(tmx_key, {});

    // ── Inline tilesets: `<image source>` relative to the `.tmx` ──
    {
        const images = try extractImageSources(allocator, tmx_bytes);
        defer {
            for (images) |s| allocator.free(s);
            allocator.free(images);
        }

        for (images) |image_source| {
            const img_embed = try imageEmbedPath(allocator, tmx_embed, image_source);
            _ = try registerAsset(allocator, regs, tmx_seen, asset_seen, image_source, img_embed, .image);
        }
    }

    // ── External tilesets: the `.tsx` bytes + the image the `.tsx` names ──
    // (labelle-assembler#678, completing labelle-gfx#336.)
    const sources = try extractExternalTilesets(allocator, tmx_bytes);
    defer {
        for (sources) |s| allocator.free(s);
        allocator.free(sources);
    }

    // The runtime half of this feature lives in the ENGINE: without a
    // `tsx_resolver` the embedded `.tsx` is never consulted and the map fails
    // to decode at runtime. Refuse (or, for an unverifiable dev pin, say so)
    // BEFORE embedding anything, so an engine that cannot use these bytes
    // never turns a generate-time error into a runtime warning.
    if (sources.len > 0) try gate.check(asset_name, sources[0]);

    for (sources) |source| {
        // The `@embedFile` path: the reference resolved against the MAP's
        // directory. The registry KEY stays the verbatim `source` — that is
        // what gfx hands `tsx_resolver.resolve`.
        const tsx_embed = try imageEmbedPath(allocator, tmx_embed, source);

        // Dedup FIRST: the same `.tsx` shared by several maps (the common
        // Tiled arrangement) must be read, scanned and embedded exactly
        // once. A benign dedup also means its image is already registered.
        if (!try registerAsset(allocator, regs, tmx_seen, asset_seen, source, tsx_embed, .tileset)) continue;
        // `tsx_embed` now belongs to `regs`; the BUFFER stays put across any
        // list growth, so borrowing it below is safe for this frame.

        try processExternalTileset(allocator, target_dir, io, cwd, asset_name, source, tsx_embed, regs, tmx_seen, asset_seen);
    }
}

/// Read the `.tsx` named by `source` (already registered by the caller) and
/// embed the image it references. Split out of `processMap` so the `.tsx`
/// byte buffer frees per-reference rather than accumulating across a map's
/// tilesets.
fn processExternalTileset(
    allocator: std.mem.Allocator,
    target_dir: []const u8,
    io: std.Io,
    cwd: std.Io.Dir,
    asset_name: []const u8,
    source: []const u8,
    /// The `@embedFile`-relative path `source` resolved to — BORROWED from
    /// the registration `processMap` just appended.
    tsx_embed: []const u8,
    regs: *std.ArrayList(Registration),
    tmx_seen: *std.StringHashMap(void),
    asset_seen: *std.StringHashMap([]const u8),
) Error!void {
    const tsx_bytes = readAsset(allocator, io, cwd, target_dir, tsx_embed) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        stderrPrint(
            "labelle-assembler: tilemap '{s}' references the external tileset '{s}', which\n" ++
                "  resolves to '{s}/{s}' — not readable: {s}\n" ++
                "  Tiled stores a shared tileset next to (or above) the map; copy the `.tsx`\n" ++
                "  into the project's `assets/` tree so it can be embedded.\n",
            .{ asset_name, source, target_dir, tsx_embed, @errorName(err) },
        );
        return error.ExternalTilesetNotFound;
    };
    defer allocator.free(tsx_bytes);

    // A `.tsx` whose root `<tileset>` only points at ANOTHER `.tsx` is not
    // something Tiled writes, and gfx#336 refuses to chase the chain
    // (`error.ExternalTilesetUnsupported`) — so embedding the chain would
    // ship bytes the runtime can never use. Fail loud here instead.
    if (firstExternalTileset(tsx_bytes)) |nested| {
        stderrPrint(
            "labelle-assembler: external tileset '{s}' (via tilemap '{s}') itself references\n" ++
                "  another tileset '{s}'. gfx's TMX loader does not follow a `.tsx` chain, so the\n" ++
                "  map could not load at runtime. Point the `.tmx` at the real tileset instead.\n",
            .{ source, asset_name, nested },
        );
        return error.ExternalTilesetUnsupported;
    }

    const images = try extractImageSources(allocator, tsx_bytes);
    defer {
        for (images) |s| allocator.free(s);
        allocator.free(images);
    }

    for (images) |image_source| {
        // PATH: relative to the `.tsx`'s OWN directory (which need not be
        // the map's — the whole point of #678 step 3). One path, however
        // many keys point at it.
        const img_embed = try imageEmbedPath(allocator, tsx_embed, image_source);
        defer allocator.free(img_embed);

        // KEY: what gfx rebases `image_source` to before the engine's
        // `ImageProvider.get` sees it — which depends on whether the RUNTIME's
        // `std.fs.path.dirname` treats `\` as a separator. The build target is
        // chosen after generation, so for a backslash-bearing reference the two
        // readings differ and BOTH are registered against the same bytes (one
        // `@embedFile` path, so no duplicate bytes in the binary). For the `/`
        // references Tiled actually writes they are identical and exactly one
        // registration is emitted (codex P2 on #684).
        const posix_key = try tsxImageKey(allocator, source, image_source, .posix);
        defer allocator.free(posix_key);
        const windows_key = try tsxImageKey(allocator, source, image_source, .windows);
        defer allocator.free(windows_key);

        var key_buf = [2][]const u8{ posix_key, windows_key };
        const keys = key_buf[0..if (std.mem.eql(u8, posix_key, windows_key)) @as(usize, 1) else 2];
        for (keys) |key| {
            // `registerAsset` takes ownership of the path it is handed.
            const embed_copy = try allocator.dupe(u8, img_embed);
            _ = try registerAsset(allocator, regs, tmx_seen, asset_seen, key, embed_copy, .image);
        }
    }
}

/// Read `<target_dir>/<rel>` (a `/`-separated, `@embedFile`-style path).
fn readAsset(
    allocator: std.mem.Allocator,
    io: std.Io,
    cwd: std.Io.Dir,
    target_dir: []const u8,
    rel: []const u8,
) ![]u8 {
    const disk_path = try std.fs.path.join(allocator, &.{ target_dir, rel });
    defer allocator.free(disk_path);
    return cwd.readFileAlloc(io, disk_path, allocator, .limited(8 * 1024 * 1024));
}

/// What a non-`.tmx` registration is, for diagnostics only.
const AssetKind = enum { image, tileset };

/// Append one tileset-side registration (`key` → `embed_path`), applying the
/// shared-registry rules. Returns true when a NEW registration was appended,
/// false on a benign dedup (same key, same resolved file).
///
/// Takes OWNERSHIP of `embed_path`: it is either handed to `regs` or freed
/// here. `key` is BORROWED and dup'd on append.
///
/// Three guards, all because the `.tmx` documents, tileset images and `.tsx`
/// documents share ONE engine registry (`addEmbeddedTilemapAsset`):
///   - a key equal to a `.tmx` `asset_name` → hard error;
///   - the SAME key resolving to a DIFFERENT file → hard error (the second
///     would otherwise silently reuse the first's bytes);
///   - the same key resolving to the SAME file → benign dedup.
fn registerAsset(
    allocator: std.mem.Allocator,
    regs: *std.ArrayList(Registration),
    tmx_seen: *std.StringHashMap(void),
    asset_seen: *std.StringHashMap([]const u8),
    key: []const u8,
    embed_path: []u8,
    kind: AssetKind,
) Error!bool {
    const what = switch (kind) {
        .image => "a tileset `<image source>`",
        .tileset => "an external `<tileset source>` (.tsx)",
    };

    // Cross-space collision: a `.tmx` already claimed this key.
    if (tmx_seen.contains(key)) {
        stderrPrint(
            "labelle-assembler: tilemap key collision on '{s}' — {s} matches a scene's\n" ++
                "  Tilemap `asset_name` already embedded. Both share the engine's single tilemap\n" ++
                "  registry; rename the tileset asset or the `.tmx` asset.\n",
            .{ key, what },
        );
        allocator.free(embed_path);
        return error.TilemapKeyCollision;
    }

    if (asset_seen.get(key)) |existing_path| {
        if (!std.mem.eql(u8, existing_path, embed_path)) {
            stderrPrint(
                "labelle-assembler: tilemap asset key collision on '{s}' — two tilesets resolve it\n" ++
                    "  to different files ('{s}' vs '{s}'), but the engine keys {s} by the bare\n" ++
                    "  source string. Give them distinct source names.\n",
                .{ key, existing_path, embed_path, what },
            );
            allocator.free(embed_path);
            return error.TilemapKeyCollision;
        }
        allocator.free(embed_path);
        return false;
    }

    const owned_key = allocator.dupe(u8, key) catch |err| {
        allocator.free(embed_path);
        return err;
    };
    regs.append(allocator, .{ .key = owned_key, .embed_path = embed_path }) catch |err| {
        allocator.free(owned_key);
        allocator.free(embed_path);
        return err;
    };
    // Store the DUPED key + its resolved path (both owned by `regs`) so later
    // dedup lookups never read freed memory and can compare paths.
    try asset_seen.put(owned_key, embed_path);
    return true;
}

pub fn freeRegistrations(allocator: std.mem.Allocator, regs: []const Registration) void {
    for (regs) |r| {
        allocator.free(r.key);
        allocator.free(r.embed_path);
    }
    allocator.free(regs);
}
