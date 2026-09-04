//! Sequential phases of `root.generate()` carved out verbatim
//! (behavior-preserving split, keeps root.zig under 1000 lines). Each fn
//! below is a faithful move of one contiguous block of the original
//! `generate` body — same statement order, same mutations, same error/early-
//! return paths — reading only a bounded subset of the caller's locals passed
//! explicitly. No block was reordered or "cleaned up".
//!
//! Lifetime contract: helpers that build state consumed later by `generate`
//! (`loadPackEntries`, `loadPackScans`) RETURN the owned container and use
//! `errdefer` for the failure path; the CALLER holds the success-path cleanup
//! `defer`, exactly as the original generate-scope `defer` did. Helpers that
//! only touch the filesystem / mutate a threaded object own their scratch
//! allocations internally.
//!
//! Bit-identical contract: the copied dirs, scanned stems, rewritten pack
//! sources, and generated `__pack_root.zig` / `__surface.zig` bytes all feed
//! the codegen registries — the plugin/pack golden + codegen suites cover the
//! end-to-end shape.

const std = @import("std");
const builtin = @import("builtin");
const config = @import("../config.zig");
const scanner = @import("../scanner.zig");
const cache = @import("../cache.zig");
const plugin_manifest = @import("../plugin_manifest.zig");
const pack_validate = @import("../pack_validate.zig");
const language_policy = @import("../language_policy.zig");
const plugin_params = @import("../plugin_params.zig");
const script_scanner = @import("../script_scanner.zig");
const main_zig = @import("../main_zig.zig");
const pack_root_gen = @import("../codegen/pack_root.zig");
const manifest_v2 = @import("../codegen/manifest_v2.zig");
const scan = @import("../codegen/scan.zig");
const pack_scan = @import("pack_scan.zig");

const ProjectConfig = config.ProjectConfig;
const ResourceDef = config.ResourceDef;

/// Normalize the editor-preview request (labelle-studio Play mode). Preview is
/// WASM-ONLY — the browser editor drives the running game through the
/// `editor_*` wasm exports — so on every other platform the request is
/// NORMALIZED OFF (not errored): a desktop build run with the var set stays
/// byte-identical to a plain build. On wasm, honor an explicit
/// `cfg.editor_preview` or read the `LABELLE_EDITOR_PREVIEW` env var (Zig 0.16:
/// env goes through the process `Environ`, `std.process.hasEnvVarConstant` /
/// `std.posix.getenv` are gone). Mutates `cfg.editor_preview` in place.
pub fn normalizeEditorPreview(allocator: std.mem.Allocator, cfg: *ProjectConfig) void {
    if (cfg.platform != .wasm) {
        cfg.editor_preview = false;
    } else if (!cfg.editor_preview) {
        const environ = config.globalEnviron();
        if (environ.getAlloc(allocator, "LABELLE_EDITOR_PREVIEW")) |v| {
            defer allocator.free(v);
            cfg.editor_preview = config.editorPreviewEnvEnabled(v);
        } else |_| {}
    }
    if (cfg.editor_preview) {
        // Generate-time breadcrumb: the splice compiles only against an
        // engine that ships `editor_api` (the generated main.zig carries a
        // matching `@compileError` guard so a stale pin fails with a clear
        // message rather than a bare "no member named 'editor_api'").
        std.log.info(
            "labelle-assembler: editor-preview wasm build (LABELLE_EDITOR_PREVIEW) — requires a labelle-engine that ships `editor_api`",
            .{},
        );
    }
}

/// Editor-preview link-path gate (#526 review, codex P2). The `editor_*`
/// exports reach the emcc link ONLY through the manifest-v2 wasm splice
/// (`renderWasmLinkV2` → backend hook `post_wire`). On any other wasm build
/// path nothing threads the export list, so a hole-bearing template would
/// splice `editor_api` into main.zig while the JS side gets no callable editor
/// entry points. Reject at generate time with the upgrade-hint error. No-op
/// unless `cfg.editor_preview` is set (already normalized OFF off-wasm).
pub fn checkEditorPreviewLinkPath(
    allocator: std.mem.Allocator,
    cfg: ProjectConfig,
    game_dir: []const u8,
    backend_manifest_name: ?[]const u8,
) !void {
    if (!cfg.editor_preview) return;
    const v2_wasm_link = blk: {
        const name = backend_manifest_name orelse break :blk false;
        const m = manifest_v2.loadNamedManifest(allocator, cfg, game_dir, name) catch break :blk false;
        defer std.zon.parse.free(allocator, m);
        break :blk m.platforms.wasm != null;
    };
    if (!v2_wasm_link) {
        // Silenced under test — the Zig test runner fails any test that
        // emits `std.log.err`, even when the error is the asserted
        // outcome (see cache/env.zig's HOME-missing log for the same gate).
        if (!builtin.is_test) {
            std.log.err(
                "labelle-assembler: editor-preview build requested (LABELLE_EDITOR_PREVIEW) but " ++
                    "backend '{s}' does not take the manifest-v2 wasm build path — only the v2 wasm " ++
                    "backend hook (post_wire) can thread the editor_* exports into the emcc link. " ++
                    "Upgrade the backend package (labelle-bgfx >= 0.6.1) or build without editor preview",
                .{cfg.backendName()},
            );
        }
        return error.EditorPreviewUnsupportedByBackend;
    }
}

// ── Uniform tile grid → synthesised atlas (#675) ─────────────────────

/// Pixel dimensions read out of a PNG's `IHDR` chunk.
pub const PngDims = struct { width: u32, height: u32 };

/// Per-axis cell counts derived from an image's own dimensions.
pub const GridCounts = struct { cols: u32, rows: u32 };

/// The 8-byte PNG signature every PNG file opens with.
const png_signature = [_]u8{ 0x89, 'P', 'N', 'G', 0x0D, 0x0A, 0x1A, 0x0A };

/// Bytes of a PNG needed to reach the end of the `IHDR` width/height:
/// 8 signature + 4 chunk length + 4 chunk type + 4 width + 4 height.
const png_header_len = 24;

/// Ceiling on `cols * rows` for ONE grid resource (#675).
///
/// The manifest is synthesised by looping `cols * rows` times, and the
/// counts come from an `IHDR` this pass has no way to corroborate: the
/// header is 24 bytes and may be truncated, corrupt or hand-crafted, so
/// a 24-byte file claiming `0xFFFFFFFF` on both axes is enough to ask
/// for 1.8e19 frames. Even an honest file does it — `tile_width = 1` on
/// a 4096-wide sheet is a plausible typo worth 16.7M frames — and the
/// result is the same: a generate that appears to hang while it writes
/// a manifest measured in gigabytes, then a compile that `@embedFile`s
/// it. Bounded instead, with a diagnostic that names the numbers.
///
/// 262 144 = a 8192 × 8192 sheet (the max texture size on essentially
/// every GPU the toolkit targets) cut into 16 × 16 tiles — comfortably
/// past any real tileset, and small enough that `row * cols + col`
/// cannot overflow the `u32` frame index.
pub const max_grid_frames: u64 = 262_144;

/// Parse `width`/`height` out of a PNG header.
///
/// A PNG is: the 8-byte signature, then chunks. The FIRST chunk is
/// required by the spec to be `IHDR`, whose data starts with a
/// big-endian `u32` width then a big-endian `u32` height — bytes
/// `[16,20)` and `[20,24)` of the file. The signature AND the `IHDR`
/// chunk-type tag are both verified before those 8 bytes are trusted:
/// without that check, any 24-byte file would yield two plausible-looking
/// integers and the grid would expand against garbage dimensions.
///
/// Returns `error.GridImageNotPng` for anything that is not a PNG, and
/// `error.GridImageZeroDimension` for a header claiming a 0-pixel axis
/// (illegal per spec, and a divide-by-zero waiting to happen downstream).
pub fn parsePngDims(bytes: []const u8) !PngDims {
    if (bytes.len < png_header_len) return error.GridImageNotPng;
    if (!std.mem.eql(u8, bytes[0..8], &png_signature)) return error.GridImageNotPng;
    if (!std.mem.eql(u8, bytes[12..16], "IHDR")) return error.GridImageNotPng;
    const dims: PngDims = .{
        .width = std.mem.readInt(u32, bytes[16..20], .big),
        .height = std.mem.readInt(u32, bytes[20..24], .big),
    };
    if (dims.width == 0 or dims.height == 0) return error.GridImageZeroDimension;
    return dims;
}

/// Cell count along ONE axis, using Tiled's tileset layout.
///
/// `margin` borders BOTH edges of the axis and `spacing` sits BETWEEN
/// adjacent cells (never after the last one), so cell `i` starts at
/// `margin + i * (tile + spacing)` and `n` cells occupy
/// `n * tile + (n - 1) * spacing` = `n * (tile + spacing) - spacing`
/// pixels. Solving for `n` against the usable span `extent - 2*margin`:
///
///     n = (extent - 2*margin + spacing) / (tile + spacing)
///
/// The division must be EXACT. A grid that leaves a remainder is
/// rejected (`error.GridDoesNotDivideEvenly`) rather than truncated:
/// silently dropping the ragged last column is the failure mode that
/// looks almost right, and the "almost" is what costs the afternoon.
/// Arithmetic runs in `u64` so a hostile `margin` near `maxInt(u32)`
/// cannot wrap `2 * margin` into a small number.
fn axisCount(extent: u32, tile: u32, margin: u32, spacing: u32) !u32 {
    if (tile == 0) return error.GridZeroTileSize;
    const e: u64 = extent;
    const m: u64 = margin;
    const step: u64 = @as(u64, tile) + spacing;
    if (e < 2 * m) return error.GridMarginExceedsImage;
    const usable = e - 2 * m + spacing;
    if (usable % step != 0) return error.GridDoesNotDivideEvenly;
    const n = usable / step;
    if (n == 0) return error.GridDoesNotDivideEvenly;
    return @intCast(n);
}

/// Derive `cols` × `rows` from the image's own pixel dimensions —
/// deliberately NOT from a user-supplied count, which would be a second
/// source of truth that drifts the moment the artist adds a row.
pub fn gridCounts(dims: PngDims, grid: config.GridDef) !GridCounts {
    const counts: GridCounts = .{
        .cols = try axisCount(dims.width, grid.tile_width, grid.margin, grid.spacing),
        .rows = try axisCount(dims.height, grid.tile_height, grid.margin, grid.spacing),
    };
    // The counts are derived from an `IHDR` nothing has corroborated, so
    // cap the product BEFORE anyone loops over it. See `max_grid_frames`.
    if (@as(u64, counts.cols) * counts.rows > max_grid_frames) return error.GridTooManyFrames;
    return counts;
}

/// Render the synthesised TexturePacker manifest (JSON-hash flavour —
/// the shape `labelle-engine/src/atlas.zig`'s `parseFramesObject` reads,
/// and the same shape the in-tree example atlases are written in).
///
/// FRAME NAMING IS A PUBLIC CONTRACT: `<name>/<index>`, row-major from
/// the top-left, zero-based, `index = row * cols + col`. See `GridDef`'s
/// doc comment. Caller owns the returned bytes.
///
/// `meta.size` carries the image's real dimensions so the engine's
/// `applyTextureScale` computes a 1.0 scale (the authored logical size
/// and the uploaded texture agree); omitting it would leave the atlas
/// with a null logical size that `resolveUiFrame` reads.
pub fn buildGridManifest(
    allocator: std.mem.Allocator,
    name: []const u8,
    image_rel: []const u8,
    dims: PngDims,
    grid: config.GridDef,
    counts: GridCounts,
) ![]u8 {
    var alloc_writer: std.Io.Writer.Allocating = .init(allocator);
    errdefer alloc_writer.deinit();
    const w = &alloc_writer.writer;

    try w.writeAll("{\n  \"frames\": {\n");
    // Coordinates run in `u64`, exactly like `axisCount`. A grid that
    // `gridCounts` ACCEPTS can still overflow the `u32` form: a 1×1 image
    // with a 1×1 tile and `spacing = maxInt(u32)` has one mathematically
    // valid cell (spacing is never applied after the last one), yet
    // `tile_width + spacing` wraps on the very first iteration — a safety
    // panic where the correct answer is a one-frame atlas. The results
    // stay in range by construction (cell `col` ends at or before the
    // image edge, and the extents are `u32`), so only the intermediates
    // needed widening.
    const step_x: u64 = @as(u64, grid.tile_width) + grid.spacing;
    const step_y: u64 = @as(u64, grid.tile_height) + grid.spacing;
    var row: u32 = 0;
    while (row < counts.rows) : (row += 1) {
        var col: u32 = 0;
        while (col < counts.cols) : (col += 1) {
            // Bounded by `max_grid_frames`, so this cannot wrap `u32`.
            const index = row * counts.cols + col;
            const x: u64 = @as(u64, grid.margin) + @as(u64, col) * step_x;
            const y: u64 = @as(u64, grid.margin) + @as(u64, row) * step_y;
            if (index != 0) try w.writeAll(",\n");
            try w.print(
                "    \"{s}/{d}\": {{ \"frame\": {{ \"x\": {d}, \"y\": {d}, \"w\": {d}, \"h\": {d} }}, " ++
                    "\"rotated\": false, \"trimmed\": false, " ++
                    "\"spriteSourceSize\": {{ \"x\": 0, \"y\": 0, \"w\": {d}, \"h\": {d} }}, " ++
                    "\"sourceSize\": {{ \"w\": {d}, \"h\": {d} }} }}",
                .{
                    name,            index,            x,               y,
                    grid.tile_width, grid.tile_height, grid.tile_width, grid.tile_height,
                    grid.tile_width, grid.tile_height,
                },
            );
        }
    }
    try w.writeAll("\n  },\n  \"meta\": {\n");
    try w.writeAll("    \"app\": \"labelle-assembler\",\n");
    try w.print("    \"image\": \"{s}\",\n", .{std.fs.path.basename(image_rel)});
    try w.print("    \"size\": {{ \"w\": {d}, \"h\": {d} }},\n", .{ dims.width, dims.height });
    try w.writeAll("    \"scale\": \"1\"\n  }\n}\n");

    var arr_list = alloc_writer.toArrayList();
    errdefer arr_list.deinit(allocator);
    return arr_list.toOwnedSlice(allocator);
}

/// Filename (relative to the target dir) of the manifest synthesised for
/// resource `name`. The `__` prefix is the target root's generated-file
/// convention (`__pack_root.zig`, `__surface.zig`) and cannot collide with
/// a user path: the target root holds only generated files plus the
/// symlinked convention dirs. One file per resource, and resource names
/// are proven unique by `validateResources`.
///
/// The name is SANITISED first. Only font names are checked for
/// identifier shape (their emission interpolates them into Zig
/// identifier positions); an image name is otherwise free-form, so
/// `.name = "ui/tiles"` is legal and would produce the sub-path
/// `__grid_ui/tiles.json`. `scanner.writeFile` opens the target dir and
/// creates the file in it — it does not create intermediate directories
/// — so that spelling fails generation with a bare `FileNotFound`, and a
/// `..` segment would write outside the generated tree entirely. Every
/// byte outside `[A-Za-z0-9_.-]` therefore becomes `_`, and a name that
/// needed rewriting gains a hash of the ORIGINAL so two names cannot
/// collapse onto one file (`a/b` and `a\b` both sanitise to `a_b`).
/// Names that are already safe — the overwhelming majority — keep the
/// plain, greppable `__grid_<name>.json` spelling.
pub fn gridManifestRel(allocator: std.mem.Allocator, name: []const u8) ![]const u8 {
    if (isSafeManifestStem(name)) return std.fmt.allocPrint(allocator, "__grid_{s}.json", .{name});

    const sanitized = try allocator.alloc(u8, name.len);
    defer allocator.free(sanitized);
    for (name, 0..) |c, i| sanitized[i] = switch (c) {
        'A'...'Z', 'a'...'z', '0'...'9', '_', '.', '-' => c,
        else => '_',
    };
    const hash = std.hash.Wyhash.hash(0, name);
    return std.fmt.allocPrint(allocator, "__grid_{s}.{x:0>16}.json", .{ sanitized, hash });
}

/// True when `name` can be interpolated into a manifest filename as-is:
/// non-empty, no path separators or other filesystem-significant bytes,
/// and not one of the two directory aliases (`.` / `..`), which are
/// `[A-Za-z0-9_.-]`-clean yet name a directory rather than a file.
fn isSafeManifestStem(name: []const u8) bool {
    if (name.len == 0) return false;
    if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) return false;
    for (name) |c| switch (c) {
        'A'...'Z', 'a'...'z', '0'...'9', '_', '.', '-' => {},
        else => return false,
    };
    return true;
}

/// Read just enough of a PNG to parse its `IHDR`. Streams the first 24
/// bytes rather than slurping the file: a tileset sheet is routinely tens
/// of megabytes and nothing past the header is wanted.
fn readPngHeader(io: std.Io, abs_path: []const u8, out: *[png_header_len]u8) !void {
    var file = try std.Io.Dir.cwd().openFile(io, abs_path, .{});
    defer file.close(io);
    var filled: usize = 0;
    while (filled < png_header_len) {
        const n = file.readStreaming(io, &.{out[filled..]}) catch |err| switch (err) {
            error.EndOfStream => break,
            else => return err,
        };
        if (n == 0) break;
        filled += n;
    }
    if (filled < png_header_len) return error.GridImageNotPng;
}

/// Expand every `.grid` resource into an ordinary atlas (#675).
///
/// A uniform tileset is a regular grid, so the TexturePacker manifest that
/// names each frame is derivable — `(col, row) * (tile + spacing) + margin`
/// — from the image's own pixel dimensions. This pass does exactly that:
/// it reads the PNG `IHDR` at `<game_dir>/<res.image>`, writes a synthesised
/// manifest into the TARGET dir (a generated tree — the user's `assets/` is
/// symlinked in and must never be written to), and REWRITES the entry to
/// `.json` + `.texture`. Nothing downstream learns a new resource kind:
/// emission, lazy inference, scene wiring, the reverse frame index and the
/// pack machinery all see a normal atlas.
///
/// Runs BEFORE `swapAstcTexturePaths` / `swapRgbaTexturePaths`, which is the
/// whole reason it sits here rather than after the target dir is otherwise
/// populated: the rewritten `.texture` is a `.png` path, so a tileset gets
/// the same `.astc` / `.rgba` sibling preference a hand-authored atlas does.
/// Dimensions are read from the SOURCE `.png` — an `.astc` sibling has no
/// PNG header — so the ordering is load-bearing in both directions.
///
/// Creates `target_dir` if needed (idempotent; `generate` calls
/// `createDirPath` on it again later).
///
/// Returns the owned list of allocated manifest rel-paths — the rewritten
/// `res.json` slices point INTO it, so the CALLER holds the cleanup `defer`,
/// exactly like the two texture-swap phases below.
pub fn expandGridResources(
    allocator: std.mem.Allocator,
    io: std.Io,
    mutable_resources: []ResourceDef,
    game_dir: []const u8,
    target_dir: []const u8,
) !std.ArrayList([]const u8) {
    var manifest_path_allocs: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (manifest_path_allocs.items) |s| allocator.free(s);
        manifest_path_allocs.deinit(allocator);
    }

    var made_target_dir = false;
    for (mutable_resources) |*res| {
        const grid = res.grid orelse continue;

        // Shape first: `.grid` is only meaningful next to `.image`, and a
        // zero cell has no frame count. `validate()` owns both rules so the
        // classification tests cover them without touching the filesystem.
        switch (res.validate()) {
            .ok => {},
            .grid_misplaced => return gridFail(res.name, error.GridMisplaced, "`.grid` is only valid alongside `.image` (it expands ONE image into a synthesised atlas). Drop `.grid`, or declare the image with `.image = \"assets/<sheet>.png\"`."),
            .grid_zero_tile_size => return gridFail(res.name, error.GridZeroTileSize, "`.grid` declares a zero `tile_width` / `tile_height`. Both must be > 0 — the frame count is the image extent divided by the cell extent."),
            // The remaining shape errors are ALSO diagnosed by
            // `validateResources` — but that runs at codegen time, well
            // after this pass, so bailing with a bare `error.InvalidResource`
            // here means the user sees only `generate failed: InvalidResource`
            // and never learns which entry is wrong. Every variant carries its
            // own diagnostic instead. Exhaustive on purpose: a new variant
            // must decide, not fall into a silent bucket.
            .no_path => return gridFail(res.name, error.InvalidResource, "declares no asset path. A `.grid` expands ONE image, so pair it with `.image = \"assets/<sheet>.png\"`."),
            .multiple_paths => return gridFail(res.name, error.InvalidResource, "sets more than one asset path. A `.grid` resource is the LOOSE-IMAGE form — keep `.image` and drop `.json`/`.texture`/`.sound`/`.font`."),
            .atlas_incomplete => return gridFail(res.name, error.InvalidResource, "is missing either `.json` or `.texture`. A `.grid` does not complete an atlas pair — it REPLACES one, alongside `.image`."),
            .font_params_misplaced => return gridFail(res.name, error.InvalidResource, "sets `.font_params` but is not a font resource. Remove `.font_params`."),
        }

        // PNG only: the dimensions come from the `IHDR`, and a `.jpg` /
        // `.astc` / `.rgba` has no such header. Rejecting up front beats
        // reporting "not a PNG" from inside the parser with no hint that
        // the FORMAT, not the file, is the problem.
        if (!std.ascii.endsWithIgnoreCase(res.image, ".png")) {
            return gridFail(res.name, error.GridImageNotPng, "`.grid` requires a `.png` image — the tile counts are derived from the PNG header. Convert the sheet to PNG (a pre-converted `.astc`/`.rgba` sibling is still picked up automatically), or write the atlas manifest by hand.");
        }

        const abs = try std.fs.path.join(allocator, &.{ game_dir, res.image });
        defer allocator.free(abs);
        var header: [png_header_len]u8 = undefined;
        readPngHeader(io, abs, &header) catch |err| {
            return gridFail(res.name, if (err == error.GridImageNotPng) error.GridImageNotPng else error.GridImageUnreadable, "could not read the `.image` PNG header. Check that the path is correct and relative to the project root.");
        };
        const dims = parsePngDims(&header) catch |err| {
            return gridFail(res.name, err, "the `.image` file is not a readable PNG (bad signature or IHDR).");
        };
        const counts = gridCounts(dims, grid) catch |err| {
            return gridFailDims(res.name, err, dims, grid);
        };

        const manifest = try buildGridManifest(allocator, res.name, res.image, dims, grid, counts);
        defer allocator.free(manifest);

        if (!made_target_dir) {
            try std.Io.Dir.cwd().createDirPath(io, target_dir);
            made_target_dir = true;
        }
        const rel = try gridManifestRel(allocator, res.name);
        {
            errdefer allocator.free(rel);
            try scanner.writeFile(target_dir, rel, manifest);
            try manifest_path_allocs.append(allocator, rel);
        }

        // Rewrite to an ordinary atlas. `.grid` is cleared so a value
        // surviving this pass (a pack-declared grid — see
        // `validateResources`) is detectable rather than silently inert.
        res.json = rel;
        res.texture = res.image;
        res.image = "";
        res.grid = null;
    }
    return manifest_path_allocs;
}

/// One-line stderr diagnostic + the mapped error, in the style the rest of
/// the generate gates use. Silenced under test: the Zig test runner fails
/// any test that emits `std.log.err`, even when the error IS the assertion.
fn gridFail(name: []const u8, err: anyerror, hint: []const u8) anyerror {
    if (!builtin.is_test) {
        std.log.err("labelle-assembler: grid resource '{s}': {s}", .{ name, hint });
    }
    return err;
}

/// The divides-evenly diagnostic, which is only useful with the numbers in
/// it: the image's real dimensions and the cell pitch that failed to fit.
fn gridFailDims(name: []const u8, err: anyerror, dims: PngDims, grid: config.GridDef) anyerror {
    if (err == error.GridTooManyFrames) {
        if (!builtin.is_test) {
            std.log.err(
                "labelle-assembler: grid resource '{s}': a {d}x{d} image cut into {d}x{d} tiles " ++
                    "(margin {d}, spacing {d}) asks for more than {d} frames. That is past any real " ++
                    "tileset, so the numbers are almost certainly wrong: check `tile_width`/`tile_height` " ++
                    "(a stray 1 turns a sheet into a million one-pixel frames) and that the `.image` " ++
                    "really is the sheet you meant. Every frame becomes an entry in a manifest the build " ++
                    "then embeds, so the limit is what keeps a typo from producing a multi-gigabyte one.",
                .{ name, dims.width, dims.height, grid.tile_width, grid.tile_height, grid.margin, grid.spacing, max_grid_frames },
            );
        }
        return err;
    }
    if (!builtin.is_test) {
        std.log.err(
            "labelle-assembler: grid resource '{s}': a {d}x{d} image does not divide evenly into " ++
                "{d}x{d} tiles (margin {d}, spacing {d}). Tiled's layout puts cell (col,row) at " ++
                "`margin + col*(tile_width+spacing), margin + row*(tile_height+spacing)`, so each axis must " ++
                "satisfy `(extent - 2*margin + spacing) % (tile + spacing) == 0`. Fix the tile size, the " ++
                "margin/spacing, or re-export the sheet — the frame count is derived from the image, never " ++
                "truncated to fit.",
            .{ name, dims.width, dims.height, grid.tile_width, grid.tile_height, grid.margin, grid.spacing },
        );
    }
    return err;
}

/// Swap `.texture = "...png"` to the pre-converted `.astc` sibling when the
/// target platform opts into ASTC (`asset_compression`) and `labelle astc`
/// produced one (labelle-gfx#269 / #340). Done BEFORE the `.rgba` swap so ASTC
/// wins. Falls back to the source PNG when no `.astc` sibling exists. Returns
/// the owned list of allocated `.astc` rel-paths — the swapped `res.texture`
/// slices point INTO it, so the CALLER holds the cleanup `defer` (the paths
/// must outlive this call for the rest of `generate`).
pub fn swapAstcTexturePaths(
    allocator: std.mem.Allocator,
    io: std.Io,
    cfg: ProjectConfig,
    mutable_resources: []ResourceDef,
    game_dir: []const u8,
) !std.ArrayList([]const u8) {
    var astc_path_allocs: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (astc_path_allocs.items) |s| allocator.free(s);
        astc_path_allocs.deinit(allocator);
    }
    if (cfg.asset_compression.formatFor(cfg.platform) == .astc) {
        for (mutable_resources) |*res| {
            if (res.texture.len == 0) continue;
            // Case-INSENSITIVE, matching the extension check in
            // `codegen/validate.zig`: `assets/tiles.PNG` is an accepted image
            // spelling everywhere else, so it must get the same sibling
            // preference (a `.grid` on such a sheet is accepted the same way).
            if (!std.ascii.endsWithIgnoreCase(res.texture, ".png")) continue;
            const astc_rel = try std.mem.concat(allocator, u8, &.{ res.texture[0 .. res.texture.len - 4], ".astc" });
            errdefer allocator.free(astc_rel);
            const abs = try std.fs.path.join(allocator, &.{ game_dir, astc_rel });
            defer allocator.free(abs);
            std.Io.Dir.cwd().access(io, abs, .{}) catch {
                allocator.free(astc_rel);
                continue;
            };
            try astc_path_allocs.append(allocator, astc_rel);
            res.texture = astc_rel;
        }
    }
    return astc_path_allocs;
}

/// Swap `.texture = "...png"` to the pre-baked `.rgba` sibling when `labelle
/// build --bake` produced one (runtime decoder detects the LRGBA magic and
/// skips stb_image). Leaves the path untouched when no sibling exists. Returns
/// the owned rel-path list — swapped `res.texture` slices point INTO it, so the
/// CALLER holds the cleanup `defer`.
pub fn swapRgbaTexturePaths(
    allocator: std.mem.Allocator,
    io: std.Io,
    mutable_resources: []ResourceDef,
    game_dir: []const u8,
) !std.ArrayList([]const u8) {
    var rgba_path_allocs: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (rgba_path_allocs.items) |s| allocator.free(s);
        rgba_path_allocs.deinit(allocator);
    }
    for (mutable_resources) |*res| {
        if (res.texture.len == 0) continue;
        // Case-INSENSITIVE for the same reason as the `.astc` swap above.
        if (!std.ascii.endsWithIgnoreCase(res.texture, ".png")) continue;
        const rgba_rel = try std.mem.concat(allocator, u8, &.{ res.texture[0 .. res.texture.len - 4], ".rgba" });
        errdefer allocator.free(rgba_rel);
        const abs = try std.fs.path.join(allocator, &.{ game_dir, rgba_rel });
        defer allocator.free(abs);
        std.Io.Dir.cwd().access(io, abs, .{}) catch {
            allocator.free(rgba_rel);
            continue;
        };
        try rgba_path_allocs.append(allocator, rgba_rel);
        res.texture = rgba_rel;
    }
    return rgba_path_allocs;
}

/// One declared pack: its `.plugins` entry paired with its parsed
/// `pack.labelle`. The manifest owns heap memory freed via `.deinit()`.
///
/// Asset-Plugins Phase 2 (#576) adds two optional fields so a pack bundled
/// INSIDE a plugin (`<plugin>/packs/<name>/`) — or a plugin's own plugin-level
/// `.resources` unit — flows through the SAME pack machinery as a game-local
/// pack. When `src_dir` is set the pack's source tree is already-resolved at
/// that absolute path (rather than at `cache.resolvePlugin(plugin, game_dir)`);
/// `owner_plugin` is the declaring plugin's name so the declaration-order
/// script loop scans the nested pack at its owner's position. Both are null for
/// a top-level game-local pack, preserving byte-identical behavior.
pub const PackEntry = struct {
    plugin: config.PluginDep,
    manifest: plugin_manifest.PackManifest,
    /// Already-resolved absolute source dir (nested pack / plugin root). Owned
    /// by the entry, freed in `deinit`. Null → resolve via `cache.resolvePlugin`.
    src_dir: ?[]const u8 = null,
    /// Declaring plugin's name for a nested-pack entry (borrowed from
    /// `cfg.plugins`; not freed). Null for a game-local pack.
    owner_plugin: ?[]const u8 = null,
    /// Whether this entry OWNS its `manifest` (frees it in `deinit`). A
    /// plugin-level `.resources` unit borrows its manifest slices from a
    /// kept-alive `PluginManifest`, so it sets this false to avoid a
    /// double-free. Game-local and nested packs own their manifest.
    owns_manifest: bool = true,

    /// Resolve the pack's source directory: the `src_dir` override when set
    /// (a nested / plugin-level unit), else `cache.resolvePlugin`. Always
    /// returns an owned string the caller frees.
    pub fn resolveSrcDir(
        self: PackEntry,
        allocator: std.mem.Allocator,
        game_dir: []const u8,
    ) ![]const u8 {
        if (self.src_dir) |d| return allocator.dupe(u8, d);
        return cache.resolvePlugin(allocator, self.plugin, game_dir);
    }

    /// Release everything the entry owns: the parsed manifest plus the owned
    /// `src_dir` (if any). `owner_plugin` is borrowed and never freed.
    pub fn deinit(self: *PackEntry, allocator: std.mem.Allocator) void {
        if (self.owns_manifest) self.manifest.deinit();
        if (self.src_dir) |d| allocator.free(d);
    }
};

/// Read every declared pack's `pack.labelle` ONCE (Packs RFC §6, #441). The
/// parsed manifests stay alive for the whole of `generate` (reused by the
/// pack-scan / pack-root / sidecar phases) — the CALLER holds the cleanup
/// `defer`; on the failure path the `errdefer` here frees what was parsed.
///
/// Reserve one slot per declared plugin (upper bound — non-pack plugins are
/// skipped) so the append cannot fail. This closes the window where a parsed
/// PackManifest is owned but not yet in the list, so a mid-loop OutOfMemory
/// would leak it (Gemini review, #441).
pub fn loadPackEntries(
    allocator: std.mem.Allocator,
    plugins: []const config.PluginDep,
    game_dir: []const u8,
) !std.ArrayList(PackEntry) {
    var pack_entries: std.ArrayList(PackEntry) = .empty;
    errdefer {
        for (pack_entries.items) |*e| e.deinit(allocator);
        pack_entries.deinit(allocator);
    }
    for (plugins) |plugin| {
        // A game-local pack: the `.plugins` entry itself carries `pack.labelle`.
        // Reserve BEFORE the (fallible) load so a parsed manifest is never
        // owned-but-unreachable on an OOM resize (#441 leak-window rule).
        try pack_entries.ensureUnusedCapacity(allocator, 1);
        if (try plugin_manifest.loadPackOptional(allocator, plugin, game_dir)) |pm| {
            pack_entries.appendAssumeCapacity(.{ .plugin = plugin, .manifest = pm });
        }
        // Asset-Plugins Phase 2 (#576): packs BUNDLED inside a decl-module
        // plugin at `<plugin>/packs/<name>/` register as first-class packs.
        try discoverNestedPacks(allocator, &pack_entries, plugin, game_dir);
    }
    return pack_entries;
}

/// Append a `PackEntry` for every pack `plugin` bundles under its `.packs`
/// (Asset-Plugins Phase 2, #576). Each nested pack is a light pack with the
/// identical structure to a game-local one — its own `pack.labelle` under
/// `<plugin>/packs/<name>/` — so it flows through the SAME pack machinery
/// (scan, `pack__` namespacing, resource merge). The entry records the resolved
/// nested `src_dir` (so downstream phases skip the `cache.resolvePlugin` name
/// lookup that only resolves top-level plugins) and the `owner_plugin` (so the
/// declaration-order script loop scans it at its owner's position). No-op for a
/// plugin with no `plugin.labelle` or an empty `.packs`.
fn discoverNestedPacks(
    allocator: std.mem.Allocator,
    pack_entries: *std.ArrayList(PackEntry),
    plugin: config.PluginDep,
    game_dir: []const u8,
) !void {
    var pmani = (try plugin_manifest.loadOptional(allocator, plugin, game_dir)) orelse return;
    defer pmani.deinit();
    if (pmani.packs.len == 0) return;

    const plugin_dir = try cache.resolvePlugin(allocator, plugin, game_dir);
    defer allocator.free(plugin_dir);

    for (pmani.packs) |nested_name| {
        try pack_entries.ensureUnusedCapacity(allocator, 1);
        const entry = (try loadNestedPackEntry(allocator, nested_name, plugin.name, plugin_dir)) orelse continue;
        pack_entries.appendAssumeCapacity(entry);
    }
}

/// Load one nested pack's `pack.labelle` from `<plugin_dir>/packs/<nested_name>/`
/// and build its `PackEntry` (Phase 2, #576). Returns `null` when the bundled
/// dir has no `pack.labelle` (tolerated, matching the game-local pack path).
/// `owner_name` is borrowed from `cfg.plugins` (lives the whole generate);
/// `.plugin.name` aliases the manifest's OWN duped `name`, so the entry needs no
/// separate name allocation.
fn loadNestedPackEntry(
    allocator: std.mem.Allocator,
    nested_name: []const u8,
    owner_name: []const u8,
    plugin_dir: []const u8,
) !?PackEntry {
    const nested_dir = try std.fs.path.join(allocator, &.{ plugin_dir, "packs", nested_name });
    errdefer allocator.free(nested_dir);
    const pm = (try plugin_manifest.loadPackFromDir(allocator, nested_dir, nested_name)) orelse {
        allocator.free(nested_dir);
        return null;
    };
    return PackEntry{
        .plugin = .{ .name = pm.name },
        .manifest = pm,
        .src_dir = nested_dir,
        .owner_plugin = owner_name,
    };
}

/// Plugin-level `.resources` units (Asset-Plugins Phase 2, #576): a decl-module
/// plugin may declare its OWN atlases directly in `plugin.labelle` (namespaced
/// `<plugin>__<name>`, copied into `packs/<plugin>/assets/`). Unlike a nested
/// pack, a plugin is NOT a scannable pack, so these entries feed ONLY the
/// resource-merge + asset-copy/validate path — never the pack scan / module /
/// script machinery.
///
/// Ownership: each unit's `PackManifest` BORROWS its slices from the kept-alive
/// `PluginManifest` (`owns_manifest = false`), so the parsed plugin manifests
/// must outlive the entries. `PluginResourceUnits` owns both; free the entries
/// FIRST (they touch only `src_dir`), then the manifests.
pub const PluginResourceUnits = struct {
    entries: std.ArrayList(PackEntry) = .empty,
    manifests: std.ArrayList(plugin_manifest.PluginManifest) = .empty,

    pub fn deinit(self: *PluginResourceUnits, allocator: std.mem.Allocator) void {
        for (self.entries.items) |*e| e.deinit(allocator);
        self.entries.deinit(allocator);
        for (self.manifests.items) |*m| m.deinit();
        self.manifests.deinit(allocator);
    }
};

pub fn loadPluginResourceEntries(
    allocator: std.mem.Allocator,
    plugins: []const config.PluginDep,
    game_dir: []const u8,
) !PluginResourceUnits {
    var units: PluginResourceUnits = .{};
    errdefer units.deinit(allocator);

    for (plugins) |plugin| {
        // Reserve the manifest slot BEFORE the fallible load so a parsed
        // PluginManifest is never owned-but-unreachable on an OOM resize.
        try units.manifests.ensureUnusedCapacity(allocator, 1);
        var pmani = (try plugin_manifest.loadOptional(allocator, plugin, game_dir)) orelse continue;
        if (pmani.resources.len == 0 and pmani.depends_on_resources.len == 0) {
            pmani.deinit();
            continue;
        }

        // Build the borrowing PackManifest from `pmani`'s stable heap slices
        // (they point at separately-allocated strings, not into the ArrayList
        // buffer, so a later manifests-resize can't invalidate them).
        const borrowed = plugin_manifest.PackManifest{
            .name = pmani.name,
            .manifest_version = pmani.manifest_version,
            .convention_dirs = .copy_and_scan,
            .resources = pmani.resources,
            .depends_on_resources = pmani.depends_on_resources,
            .allocator = allocator,
        };
        units.manifests.appendAssumeCapacity(pmani); // now owned by the list

        // Reserve the entry slot BEFORE resolving the plugin dir so the owned
        // `src_dir` is taken by an infallible append (no leak window).
        try units.entries.ensureUnusedCapacity(allocator, 1);
        const plugin_dir = try cache.resolvePlugin(allocator, plugin, game_dir);
        units.entries.appendAssumeCapacity(.{
            .plugin = plugin,
            .manifest = borrowed,
            .src_dir = plugin_dir,
            .owner_plugin = plugin.name,
            .owns_manifest = false,
        });
    }
    return units;
}

/// Dependency-validation gate for the parsed pack manifests (Packs RFC §6,
/// #441). Runs BEFORE the target dir is created so a bad graph rejects the
/// build cheaply without leaving stale output. Fully self-contained — all
/// scratch is freed here.
pub fn validatePackGraph(
    allocator: std.mem.Allocator,
    pack_entries: []const PackEntry,
    plugins: []const config.PluginDep,
) !void {
    var pack_deps: std.ArrayList(pack_validate.PackDep) = .empty;
    defer pack_deps.deinit(allocator);
    try pack_deps.ensureTotalCapacity(allocator, pack_entries.len);
    for (pack_entries) |e| {
        pack_deps.appendAssumeCapacity(.{ .name = e.manifest.name, .depends_on = e.manifest.depends_on });
    }

    // Legal depends_on targets = every plugin/pack declared in
    // project.labelle (plus the implicit `contracts`, handled inside).
    var declared_names: std.ArrayList([]const u8) = .empty;
    defer declared_names.deinit(allocator);
    try declared_names.ensureTotalCapacity(allocator, plugins.len + pack_entries.len);
    for (plugins) |plugin| declared_names.appendAssumeCapacity(plugin.name);
    // Phase 2 (#576): nested packs are legal `depends_on` targets too — a pack
    // bundled inside a plugin isn't in `.plugins`, so add every pack entry's
    // own name (game-local names re-added harmlessly; membership is all the
    // dep check needs).
    for (pack_entries) |e| declared_names.appendAssumeCapacity(e.plugin.name);

    try pack_validate.validate(allocator, pack_deps.items, declared_names.items);

    // Prefix-collision gate (#440 / CodeRabbit): a pack's name feeds
    // `scan.packNamespacePrefix` (codegen). Two packs whose names sanitize
    // to the same `<pack>__` prefix (e.g. `my-pack` and `my_pack`) would
    // emit duplicate namespaced symbols and break the generated
    // imports/registries/hook tuples. Check over the SAME name the pack-scan
    // loop feeds `scanPack` (`plugin.name` → `PackScan.name` → prefix), so
    // the gate matches the symbols actually emitted. Fails before any target
    // is written.
    var pack_names: std.ArrayList([]const u8) = .empty;
    defer pack_names.deinit(allocator);
    try pack_names.ensureTotalCapacity(allocator, pack_entries.len);
    for (pack_entries) |e| pack_names.appendAssumeCapacity(e.plugin.name);
    try pack_validate.checkPrefixCollisions(pack_names.items);
}

/// One-language-per-project policy gate (labelle-assembler#584,
/// RFC-LANGUAGE-PLUGINS revs 8–9). Runs beside `validatePackGraph` — BEFORE
/// the target dir is created — so a policy violation rejects the build
/// cheaply without leaving stale output. Three layers, all fed from state
/// `generate` already has:
///
///   1. `.params.language` rules over `cfg.plugins` — supported vocabulary,
///      at most ONE declaring entry (`language_policy.resolveProjectLanguage`).
///   2. `requires_language` matching — every attached plugin manifest
///      (re-read via `loadOptional`, same per-phase pattern as
///      `copyPluginConventionDirs`) and every pack manifest (already parsed
///      into `pack_entries`, game-local AND plugin-bundled) must match the
///      declared language.
///   3. Script-dir scan — the game root and every pack SOURCE dir (resolved
///      exactly as the asset copy does, via `PackEntry.resolveSrcDir`) are
///      walked for language convention dirs; foreign-language files are a
///      hard error listing the offenders, files with no scripting plugin get
///      the attach hint, empty dirs warn only.
///
/// Parse + validate ONLY: nothing here writes, and a project with no
/// `.params.language` and no language dirs passes through untouched
/// (byte-identical generation).
pub fn validateLanguagePolicy(
    allocator: std.mem.Allocator,
    pack_entries: []const PackEntry,
    plugins: []const config.PluginDep,
    game_dir: []const u8,
) !void {
    const declared = try language_policy.resolveProjectLanguage(plugins);

    // The project's OPEN language vocabulary (#619): the frozen built-ins ∪
    // the DECLARING plugin's manifest `.languages` capability rows
    // (RFC-LANGUAGE-PLUGINS §7 — a resolved pin's own manifest declares
    // what it supports; a language the frozen tables never heard of is
    // admitted by its row alone, with zero assembler changes). A declaring
    // plugin without a manifest (or without rows) yields the EMPTY
    // vocabulary — bit-identical to the pre-#619 closed-table behavior.
    var vocab = language_policy.Vocabulary.EMPTY;
    defer vocab.deinit();
    if (declared) |d| {
        for (plugins) |plugin| {
            if (!std.mem.eql(u8, plugin.name, d.plugin_name)) continue;
            var pmani = (try plugin_manifest.loadOptional(allocator, plugin, game_dir)) orelse break;
            defer pmani.deinit();
            const inputs = try allocator.alloc(language_policy.RowInput, pmani.languages.len);
            defer allocator.free(inputs);
            for (pmani.languages, inputs) |row, *in| {
                in.* = .{ .name = row.name, .extensions = row.extensions };
            }
            vocab = try language_policy.Vocabulary.build(allocator, inputs);
            break;
        }
        // The vocabulary gate: the declared language must be a frozen
        // built-in or a manifest row (the check `resolveProjectLanguage`
        // used to make against the closed table, re-homed here where the
        // manifest is in hand).
        try language_policy.validateDeclaredLanguage(d, &vocab);
    }

    // requires_language on every attached plugin manifest (decl-module
    // plugins; a light pack ships no plugin.labelle so loadOptional is null
    // for it — its manifest is covered by the pack loop below).
    for (plugins) |plugin| {
        var pmani = (try plugin_manifest.loadOptional(allocator, plugin, game_dir)) orelse continue;
        defer pmani.deinit();
        try language_policy.checkRequiresLanguage("plugin", plugin.name, pmani.requires_language, declared, &vocab);
    }

    // requires_language on every pack manifest — game-local packs AND packs
    // bundled inside plugins (Phase-2 nested entries) ride the same list.
    for (pack_entries) |e| {
        try language_policy.checkRequiresLanguage("pack", e.manifest.name, e.manifest.requires_language, declared, &vocab);
    }

    // Script-dir scan: the game root, then every pack's SOURCE dir.
    try language_policy.scanUnitLanguageDirs(allocator, game_dir, "project root", declared, &vocab);
    for (pack_entries) |e| {
        const pack_src_dir = try e.resolveSrcDir(allocator, game_dir);
        defer allocator.free(pack_src_dir);
        const label = try std.fmt.allocPrint(allocator, "pack '{s}'", .{e.manifest.name});
        defer allocator.free(label);
        try language_policy.scanUnitLanguageDirs(allocator, pack_src_dir, label, declared, &vocab);
    }
}

/// Schema-declared plugin params gate + resolution (labelle-assembler#591).
/// Runs beside `validateLanguagePolicy` — BEFORE the target dir is created —
/// so an invalid `.params` rejects the build cheaply with no stale output.
/// For each declared plugin:
///
///   1. Its manifest (re-read via `loadOptional`, the same per-phase pattern
///      as the language gate) supplies the `.params_schema` — empty for a
///      manifest-less or schema-less plugin.
///   2. The entry's EFFECTIVE bag — the generic `params_bag` when the
///      tolerant parse extracted one, else the typed `.params.language` fast
///      path viewed as a one-entry bag — is validated + resolved against the
///      schema (`plugin_params.validateAndResolve`): unknown param, wrong
///      type, out-of-vocabulary enum, missing required → actionable errors
///      naming plugin + param; schema defaults fill unset optionals.
///
/// Returns the resolved sets (owned; caller frees via
/// `plugin_params.freeResolvedList`) that drive the staged
/// `plugin_<name>_params.zig` modules + the generated build.zig's
/// `overrideImport` wiring. Params-less plugins resolve to nothing —
/// the list stays empty and every emission site is a byte-identical no-op.
pub fn resolvePluginParams(
    allocator: std.mem.Allocator,
    plugins: []const config.PluginDep,
    game_dir: []const u8,
) !std.ArrayList(plugin_params.ResolvedPluginParams) {
    var resolved: std.ArrayList(plugin_params.ResolvedPluginParams) = .empty;
    errdefer plugin_params.freeResolvedList(allocator, &resolved);

    for (plugins) |plugin| {
        // The effective bag: the generic bag wins (the parse path fills it
        // for every `.params` literal, `language` included); a hand-built
        // config carrying only the typed fast-path field is viewed as the
        // equivalent one-entry bag so both spellings validate identically.
        var language_view: [1]plugin_params.Param = undefined;
        const bag: []const plugin_params.Param = if (plugin.params_bag) |b| b else blk: {
            const typed = plugin.params orelse break :blk &.{};
            const lang = typed.language orelse break :blk &.{};
            language_view[0] = .{ .name = "language", .value = .{ .str = lang } };
            break :blk &language_view;
        };

        var maybe_manifest = try plugin_manifest.loadOptional(allocator, plugin, game_dir);
        defer if (maybe_manifest) |*m| m.deinit();
        const schema: []const plugin_params.ParamSchema = if (maybe_manifest) |m| m.params_schema else &.{};

        const params = (try plugin_params.validateAndResolve(allocator, plugin.name, bag, schema)) orelse continue;
        errdefer plugin_params.freeResolved(allocator, params);

        // The staged module is injected under the FIXED import name
        // `plugin_params` (see `plugin_params.IMPORT_NAME`); a sibling
        // plugin literally named that would be shadowed inside THIS
        // plugin's imports — fail loudly instead of silently rewiring.
        for (plugins) |sibling| {
            if (std.mem.eql(u8, sibling.name, plugin_params.IMPORT_NAME)) {
                std.debug.print(
                    "labelle-assembler: plugin '{s}' resolves params, but a plugin is named '{s}' — the params module would shadow it inside '{s}'.\n" ++
                        "  rename the '{s}' plugin.\n",
                    .{ plugin.name, plugin_params.IMPORT_NAME, plugin.name, plugin_params.IMPORT_NAME },
                );
                return error.PluginParamsNameCollision;
            }
        }

        try resolved.append(allocator, .{ .plugin_name = plugin.name, .params = params });
    }
    return resolved;
}

/// Copy (and scan, per manifest `mode`) each plugin's declared convention
/// directories into the target (RFC-plugin-manifest). See
/// `docs/RFC-plugin-manifest.md`.
///
/// The manifest is read regardless of `plugin.states` (game-state gating
/// affects runtime, not generate-time layout). Missing source directories are
/// silently tolerated, matching the hardcoded scans in `generate`.
///
/// Duplicate directory declarations ACROSS plugins are a hard error (RFC E3);
/// a single plugin may re-declare a name across entries (multi-extension, Q3).
/// All manifests are loaded first and kept alive until every copy pass has run
/// so the duplicate-detection map (slices into parsed manifest memory) stays
/// valid. Capacity is pre-reserved so the per-plugin append cannot fail (a
/// fallible append could leak a loaded manifest on OOM-resize).
pub fn copyPluginConventionDirs(
    allocator: std.mem.Allocator,
    plugins: []const config.PluginDep,
    game_dir: []const u8,
    target_dir: []const u8,
) !void {
    var loaded_manifests: std.ArrayList(plugin_manifest.PluginManifest) = .empty;
    defer {
        for (loaded_manifests.items) |*m| m.deinit();
        loaded_manifests.deinit(allocator);
    }
    try loaded_manifests.ensureTotalCapacity(allocator, plugins.len);

    var owner_of_dir: std.StringHashMapUnmanaged([]const u8) = .empty;
    defer owner_of_dir.deinit(allocator);

    for (plugins) |plugin| {
        const maybe_manifest = try plugin_manifest.loadOptional(allocator, plugin, game_dir);
        const manifest = maybe_manifest orelse continue;
        // Capacity was reserved above — this cannot fail, so there's
        // no window where `manifest` is owned but outside the cleanup
        // list's reach.
        loaded_manifests.appendAssumeCapacity(manifest);

        for (manifest.convention_dirs) |dir| {
            // Duplicate detection is *cross-plugin only*. A single plugin
            // is allowed to declare the same directory name in multiple
            // convention_dirs entries with different extensions — that's
            // the RFC Q3 multi-extension pattern (e.g. a plugin wanting
            // both .zig and .zon files under state_machines/). Only error
            // when a different plugin already claimed the name.
            if (owner_of_dir.get(dir.name)) |prev_owner| {
                if (!std.mem.eql(u8, prev_owner, plugin.name)) {
                    std.debug.print(
                        "labelle: two plugins want the same convention directory '{s}':\n  - plugin '{s}' already declared it\n  - plugin '{s}' is trying to declare it again\n  each plugin must use a unique directory name\n",
                        .{ dir.name, prev_owner, plugin.name },
                    );
                    return error.PluginManifestDuplicateDir;
                }
                // Same plugin re-declaring the name (multi-extension) —
                // don't overwrite the claim, just keep going and let the
                // copy pass below handle it.
            } else {
                try owner_of_dir.put(allocator, dir.name, plugin.name);
            }

            switch (dir.mode) {
                .copy_and_scan => {
                    // `extension` is required for copy_and_scan and is
                    // validated by plugin_manifest.loadFromDir at load
                    // time, so .? here is safe.
                    const ext = dir.extension.?;
                    const names = try scanner.linkAndScan(
                        allocator,
                        game_dir,
                        target_dir,
                        dir.name,
                        ext,
                    );
                    // v1: name list is computed but not exposed to codegen.
                    // Future RFC will decide how plugins drive main.zig
                    // generation from these names.
                    scanner.freeNames(allocator, names);
                },
                .copy_only => {
                    try scanner.linkDir(
                        allocator,
                        game_dir,
                        target_dir,
                        dir.name,
                    );
                },
                .ship_from_plugin => {
                    // Plugin-shipped content: source dir lives in the
                    // plugin's cached package rather than the consuming
                    // game. Resolves the plugin's path up-front because
                    // copyAndScan takes a base and a folder-under-base.
                    // Silently skips if the plugin doesn't actually ship
                    // the declared directory — matches copy_and_scan's
                    // missing-source tolerance so a plugin author can
                    // declare the convention eagerly and ship content
                    // incrementally.
                    const ext = dir.extension.?;
                    const plugin_src_dir = try cache.resolvePlugin(allocator, plugin, game_dir);
                    defer allocator.free(plugin_src_dir);
                    const names = try scanner.copyAndScan(
                        allocator,
                        plugin_src_dir,
                        target_dir,
                        dir.name,
                        ext,
                    );
                    scanner.freeNames(allocator, names);
                },
            }
        }
    }
}

/// Copy each plugin's own `scripts/` dir into the target and feed it to the
/// scanner (RFC-plugin-controllers §2). Game scripts live under `scripts/`;
/// each plugin's scripts land under `scripts/.plugin_<name>/`, forming their
/// own numeric-prefix namespace so the duplicate-prefix validator treats each
/// block independently. Both `copyAndScanAbs` and `scanPluginDir` no-op on a
/// missing source dir, so plugins without `scripts/` contribute nothing.
///
/// A *light pack* is also a `.plugins` entry, but its scripts flow through the
/// pack dir-scan (landing under `packs/<name>/scripts/` so their `../components`
/// relative imports resolve) — so packs are scanned HERE via
/// `scanPackScriptsAt`, at the pack's declaration-order position within this
/// loop (interleaved with decl-module plugins), so the scanner's `plugin_index`
/// reflects `.plugins` order. Scanning all packs in a SEPARATE later loop would
/// break the per-state script ordering contract (#487 / #494, codex review).
pub fn copyPluginShippedScripts(
    allocator: std.mem.Allocator,
    script_scan: *script_scanner.ScriptScanner,
    plugins: []const config.PluginDep,
    pack_entries: []const PackEntry,
    game_dir: []const u8,
    target_dir: []const u8,
) !void {
    for (plugins) |plugin| {
        const is_pack = blk: {
            for (pack_entries) |e| {
                if (std.mem.eql(u8, e.plugin.name, plugin.name)) break :blk true;
            }
            break :blk false;
        };
        if (is_pack) {
            const pack_src_dir = try cache.resolvePlugin(allocator, plugin, game_dir);
            defer allocator.free(pack_src_dir);
            _ = try pack_scan.scanPackScriptsAt(allocator, script_scan, pack_src_dir, target_dir, plugin.name);
            continue;
        }

        // Asset-Plugins Phase 2 (#576): scan the scripts of every pack this
        // decl-module plugin BUNDLES, at the OWNER plugin's declaration
        // position — so a nested pack's per-frame scripts keep the same
        // ordering guarantee a game-local pack gets (#494). Runs BEFORE the
        // plugin's own `scripts/` scan below so the bundled packs' scripts
        // order ahead of the host plugin's, matching declaration nesting.
        for (pack_entries) |e| {
            const owner = e.owner_plugin orelse continue;
            if (!std.mem.eql(u8, owner, plugin.name)) continue;
            const nested_src = try e.resolveSrcDir(allocator, game_dir);
            defer allocator.free(nested_src);
            _ = try pack_scan.scanPackScriptsAt(allocator, script_scan, nested_src, target_dir, e.plugin.name);
        }

        // Plugin was already resolved during the manifest-loading loop
        // above; re-resolving here is infallible in practice. Use `try`
        // to match the manifest-load contract — a failure here is a
        // cache corruption, not a plugin configuration error, and
        // should fail the generate rather than silently skip.
        const plugin_src_dir = try cache.resolvePlugin(allocator, plugin, game_dir);
        defer allocator.free(plugin_src_dir);

        const plugin_scripts_src = try std.fs.path.join(allocator, &.{ plugin_src_dir, "scripts" });
        defer allocator.free(plugin_scripts_src);

        // Destination: `<target>/scripts/.plugin_<name>/`. The leading `.`
        // prevents accidental collision with a game state directory (states
        // must be lowercase alphanumeric + `_`, per `isValidStateName`, so
        // `.plugin_foo` can never be mistaken for a state dir by the
        // scanner).
        const plugin_dst_subdir = try std.fmt.allocPrint(allocator, ".plugin_{s}", .{plugin.name});
        defer allocator.free(plugin_dst_subdir);
        const plugin_scripts_dst = try std.fs.path.join(allocator, &.{ target_dir, "scripts", plugin_dst_subdir });
        defer allocator.free(plugin_scripts_dst);

        const names = try scanner.copyAndScanAbs(
            allocator,
            plugin_scripts_src,
            plugin_scripts_dst,
            ".zig",
        );
        scanner.freeNames(allocator, names);

        // Feed the plugin's scripts into the scanner as a new block,
        // isolated under the plugin's namespace so the duplicate-prefix
        // validator treats it independently of the game block.
        try script_scan.scanPluginDir(plugin_scripts_dst, plugin.name);
    }
}

/// Pack dir-scan (Packs RFC §4, #439/#440): for every parsed pack, copy its
/// convention subdirs into `<target>/packs/<name>/<subdir>/` and record the
/// scanned stems (namespaced `<pack>__<Name>`, prefab refs rewritten). Returns
/// the owned scan list — the CALLER holds the success-path cleanup `defer`; the
/// `errdefer` here covers the failure path. Reuses the manifests parsed by
/// `loadPackEntries` (only the source dir is resolved here).
///
/// A pack's OWN per-frame system (`<pack>/scripts/<state>/*.zig`) is copied +
/// registered by the `cfg.plugins` script loop (`copyPluginShippedScripts`) at
/// its declaration-order position, NOT here — doing it in this pack-only loop
/// would order all pack scripts behind all plugin scripts (#494).
pub fn loadPackScans(
    allocator: std.mem.Allocator,
    pack_entries: []const PackEntry,
    game_dir: []const u8,
    target_dir: []const u8,
) !std.ArrayList(main_zig.PackScan) {
    var pack_scans: std.ArrayList(main_zig.PackScan) = .empty;
    errdefer {
        for (pack_scans.items) |*p| p.deinit(allocator);
        pack_scans.deinit(allocator);
    }
    try pack_scans.ensureTotalCapacity(allocator, pack_entries.len);
    for (pack_entries) |e| {
        // Reuse the manifest parsed above; only the source dir is resolved here.
        // A nested pack (Phase 2, #576) carries an already-resolved `src_dir`
        // override; a game-local pack resolves via `cache.resolvePlugin`.
        const pack_src_dir = try e.resolveSrcDir(allocator, game_dir);
        defer allocator.free(pack_src_dir);

        // ensureTotalCapacity above reserved pack_entries.len slots, so this
        // append cannot fail — no window where a scanned pack is owned but
        // outside the cleanup list's reach.
        const scanned = try pack_scan.scanPack(allocator, pack_src_dir, target_dir, e.plugin.name);
        pack_scans.appendAssumeCapacity(scanned);
    }
    return pack_scans;
}

/// Per-pack module roots (assembler#498 PR 2, "wire the wall"). Generate
/// `<target>/packs/<name>/__pack_root.zig` (re-exports each scanned
/// component/event/hook/script so main.zig reaches pack contents exclusively
/// through `@import("pack__<prefix>")`) and `__surface.zig` (the exposes-
/// narrowed module a dependent's `@import("<pack>")` maps to). Fully
/// self-contained — writes to disk, all scratch freed per iteration.
///
/// Pack SCRIPT entries were registered by the `cfg.plugins` loop
/// (`copyPluginShippedScripts`, declaration order, #494), so the scanner
/// already holds every pack script: filter by the `import_base == ""` pack
/// marker + the owning pack's name, re-rooting each `packs/<name>/scripts/<rel>`
/// path at the module root (`scripts/<rel>`).
pub fn writePackModuleRoots(
    allocator: std.mem.Allocator,
    pack_scans: []const main_zig.PackScan,
    pack_entries: []const PackEntry,
    script_scan: *script_scanner.ScriptScanner,
    target_dir: []const u8,
) !void {
    for (pack_scans) |pack| {
        var script_rels: std.ArrayList([]const u8) = .empty;
        defer script_rels.deinit(allocator);
        for (script_scan.getEntries()) |entry| {
            if (entry.import_base.len != 0) continue;
            const pname = entry.plugin_name orelse continue;
            if (!std.mem.eql(u8, pname, pack.name)) continue;
            try script_rels.append(allocator, pack_root_gen.packRelScriptPath(entry.rel_path, pack.name));
        }
        const pack_root_src = try pack_root_gen.renderPackRoot(allocator, pack, script_rels.items);
        defer allocator.free(pack_root_src);
        const rel = try std.fs.path.join(allocator, &.{ "packs", pack.name, "__pack_root.zig" });
        defer allocator.free(rel);
        try scanner.writeFile(target_dir, rel, pack_root_src);

        // `__surface.zig` (#498 PR 4): the exposes-narrowed module a
        // dependent's `@import("<this pack>")` maps to. Validated here so
        // a manifest exposing verbs from a file the pack doesn't ship
        // fails BEFORE any build, with the manifest named — the compile
        // error a dependent would eventually hit points at generated
        // code instead of the author's mistake.
        const exposes: pack_root_gen.SurfaceExposes = blk: {
            const manifest = for (pack_entries) |e| {
                if (std.mem.eql(u8, e.plugin.name, pack.name)) break e.manifest;
            } else unreachable; // pack_scans is built FROM pack_entries
            const ex = manifest.exposes orelse break :blk .{};
            try pack_validate.checkExposesFiles(pack.name, ex.queries.len, ex.commands.len, pack.has_queries, pack.has_commands);
            break :blk .{ .queries = ex.queries, .commands = ex.commands };
        };
        const surface_src = try pack_root_gen.renderSurface(allocator, pack.name, exposes);
        defer allocator.free(surface_src);
        const surface_rel = try std.fs.path.join(allocator, &.{ "packs", pack.name, "__surface.zig" });
        defer allocator.free(surface_rel);
        try scanner.writeFile(target_dir, surface_rel, surface_src);
    }
}

/// Pack-module wiring records for the generated build.zig (#498 PR 2): one
/// `pack__<prefix>_mod` per pack, rooted at the `__pack_root.zig` written by
/// `writePackModuleRoots`. Returns the owned list — each record's `.prefix` is
/// duped (the shared scratch buf doesn't outlive the loop), so the CALLER holds
/// the cleanup `defer`. `.depends_on` aliases the manifest's strings, valid
/// while `pack_entries` outlives the returned list.
pub fn buildPackModules(
    allocator: std.mem.Allocator,
    pack_scans: []const main_zig.PackScan,
    pack_entries: []const PackEntry,
) !std.ArrayList(pack_root_gen.PackModule) {
    var pack_modules: std.ArrayList(pack_root_gen.PackModule) = .empty;
    errdefer {
        for (pack_modules.items) |p| allocator.free(p.prefix);
        pack_modules.deinit(allocator);
    }
    try pack_modules.ensureTotalCapacity(allocator, pack_scans.len);
    for (pack_scans) |pack| {
        var pfx_buf: [128]u8 = undefined;
        const pfx = scan.packNamespacePrefix(pack.name, &pfx_buf);
        // depends_on aliases the manifest's strings — safe: `pack_entries`'
        // cleanup defer was declared before this list's, so it runs after.
        const depends_on: []const []const u8 = for (pack_entries) |e| {
            if (std.mem.eql(u8, e.plugin.name, pack.name)) break e.manifest.depends_on;
        } else &.{};
        pack_modules.appendAssumeCapacity(.{ .name = pack.name, .prefix = try allocator.dupe(u8, pfx), .depends_on = depends_on });
    }
    return pack_modules;
}

// ============================================================================
// Tests — Asset-Plugins Phase 2 (#576): plugin `.resources` + nested `.packs`
// ============================================================================

const testing = std.testing;
const pack_resources = @import("../pack_resources.zig");

fn writeTestFile(dir: std.Io.Dir, rel: []const u8, body: []const u8) !void {
    const tio = testing.io;
    if (std.fs.path.dirname(rel)) |sub| try dir.createDirPath(tio, sub);
    var f = try dir.createFile(tio, rel, .{});
    defer f.close(tio);
    try f.writeStreamingAll(tio, body);
}

/// Stage a full Phase-2 plugin tree under `<tmp>/myplugin/`:
///   plugin.labelle (.resources = ui, .packs = { dungeon })
///   assets/ui.{json,png}
///   packs/dungeon/pack.labelle + assets/tiles.{json,png}
/// Returns the plugin as a `local:` PluginDep pointing at its absolute path.
fn stagePhase2Plugin(tmp: *std.testing.TmpDir, allocator: std.mem.Allocator) !config.PluginDep {
    try writeTestFile(tmp.dir, "myplugin/plugin.labelle",
        \\.{
        \\    .name = "myplugin",
        \\    .manifest_version = 1,
        \\    .license = "MIT",
        \\    .author = "acme",
        \\    .resources = .{
        \\        .{ .name = "ui", .json = "assets/ui.json", .texture = "assets/ui.png" },
        \\    },
        \\    .packs = .{ "dungeon" },
        \\}
    );
    try writeTestFile(tmp.dir, "myplugin/assets/ui.json",
        \\{ "frames": { "button.png": {} }, "meta": {} }
    );
    try writeTestFile(tmp.dir, "myplugin/assets/ui.png", "PNG");
    try writeTestFile(tmp.dir, "myplugin/packs/dungeon/pack.labelle",
        \\.{
        \\    .name = "dungeon",
        \\    .manifest_version = 1,
        \\    .resources = .{
        \\        .{ .name = "tiles", .json = "assets/tiles.json", .texture = "assets/tiles.png" },
        \\    },
        \\}
    );
    try writeTestFile(tmp.dir, "myplugin/packs/dungeon/assets/tiles.json",
        \\{ "frames": { "wall.png": {} }, "meta": {} }
    );
    try writeTestFile(tmp.dir, "myplugin/packs/dungeon/assets/tiles.png", "PNG");

    const abs = try tmp.dir.realPathFileAlloc(testing.io, "myplugin", allocator);
    defer allocator.free(abs);
    const repo = try std.fmt.allocPrint(allocator, "local:{s}", .{abs});
    // `repo` is owned by the returned PluginDep; the caller frees it.
    return config.PluginDep{ .name = "myplugin", .repo = repo };
}

test "Phase 2: a plugin's nested .packs are discovered as first-class packs (#576)" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const plugin = try stagePhase2Plugin(&tmp, allocator);
    defer allocator.free(plugin.repo);
    const project_dir = try tmp.dir.realPathFileAlloc(testing.io, ".", allocator);
    defer allocator.free(project_dir);

    var pack_entries = try loadPackEntries(allocator, &.{plugin}, project_dir);
    defer {
        for (pack_entries.items) |*e| e.deinit(allocator);
        pack_entries.deinit(allocator);
    }

    // The plugin itself is NOT a game-local pack (no pack.labelle at its root);
    // only its bundled `dungeon` pack is discovered.
    try testing.expectEqual(@as(usize, 1), pack_entries.items.len);
    const nested = pack_entries.items[0];
    try testing.expectEqualStrings("dungeon", nested.plugin.name);
    try testing.expectEqualStrings("myplugin", nested.owner_plugin.?);
    try testing.expect(nested.src_dir != null);
    try testing.expect(std.mem.endsWith(u8, nested.src_dir.?, "dungeon"));

    // resolveSrcDir returns the override, not a name-resolution.
    const resolved = try nested.resolveSrcDir(allocator, project_dir);
    defer allocator.free(resolved);
    try testing.expectEqualStrings(nested.src_dir.?, resolved);
}

test "Phase 2: a plugin's own .resources become a plugin-level unit (#576)" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const plugin = try stagePhase2Plugin(&tmp, allocator);
    defer allocator.free(plugin.repo);
    const project_dir = try tmp.dir.realPathFileAlloc(testing.io, ".", allocator);
    defer allocator.free(project_dir);

    var units = try loadPluginResourceEntries(allocator, &.{plugin}, project_dir);
    defer units.deinit(allocator);

    try testing.expectEqual(@as(usize, 1), units.entries.items.len);
    const unit = units.entries.items[0];
    try testing.expectEqualStrings("myplugin", unit.plugin.name);
    try testing.expect(!unit.owns_manifest); // borrows from the kept-alive PluginManifest
    try testing.expect(unit.src_dir != null);
    try testing.expectEqual(@as(usize, 1), unit.manifest.resources.len);
    try testing.expectEqualStrings("ui", unit.manifest.resources[0].name);
}

test "Phase 2: plugin `.resources` + nested-pack resources merge namespaced (#576)" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const plugin = try stagePhase2Plugin(&tmp, allocator);
    defer allocator.free(plugin.repo);
    const project_dir = try tmp.dir.realPathFileAlloc(testing.io, ".", allocator);
    defer allocator.free(project_dir);

    var pack_entries = try loadPackEntries(allocator, &.{plugin}, project_dir);
    defer {
        for (pack_entries.items) |*e| e.deinit(allocator);
        pack_entries.deinit(allocator);
    }
    var units = try loadPluginResourceEntries(allocator, &.{plugin}, project_dir);
    defer units.deinit(allocator);

    // Combined resource view = nested packs ++ plugin-level units (the exact
    // slice root.generate builds).
    var combined: std.ArrayList(PackEntry) = .empty;
    defer combined.deinit(allocator);
    try combined.appendSlice(allocator, pack_entries.items);
    try combined.appendSlice(allocator, units.entries.items);

    const game = [_]ResourceDef{
        .{ .name = "background", .json = "assets/bg.json", .texture = "assets/bg.png" },
    };
    var merged = try pack_resources.mergePackResources(allocator, &game, combined.items);
    defer merged.deinit();

    // Game resource first (byte-identical), then dungeon pack + plugin unit.
    try testing.expectEqual(@as(usize, 3), merged.resources.len);
    try testing.expectEqualStrings("background", merged.resources[0].name);
    try testing.expectEqualStrings("dungeon__tiles", merged.resources[1].name);
    try testing.expectEqualStrings("packs/dungeon/assets/tiles.json", merged.resources[1].json);
    try testing.expectEqualStrings("myplugin__ui", merged.resources[2].name);
    try testing.expectEqualStrings("packs/myplugin/assets/ui.json", merged.resources[2].json);
}

test "Phase 2: a code-only plugin discovers nothing → byte-identical (#576)" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    // A plugin.labelle with no .resources and no .packs — every plugin before
    // this ticket. No nested packs, no plugin-level resource units.
    try writeTestFile(tmp.dir, "codeonly/plugin.labelle",
        \\.{ .name = "codeonly", .manifest_version = 1 }
    );
    const abs = try tmp.dir.realPathFileAlloc(testing.io, "codeonly", allocator);
    defer allocator.free(abs);
    const repo = try std.fmt.allocPrint(allocator, "local:{s}", .{abs});
    defer allocator.free(repo);
    const plugin = config.PluginDep{ .name = "codeonly", .repo = repo };
    const project_dir = try tmp.dir.realPathFileAlloc(testing.io, ".", allocator);
    defer allocator.free(project_dir);

    var pack_entries = try loadPackEntries(allocator, &.{plugin}, project_dir);
    defer {
        for (pack_entries.items) |*e| e.deinit(allocator);
        pack_entries.deinit(allocator);
    }
    var units = try loadPluginResourceEntries(allocator, &.{plugin}, project_dir);
    defer units.deinit(allocator);

    try testing.expectEqual(@as(usize, 0), pack_entries.items.len);
    try testing.expectEqual(@as(usize, 0), units.entries.items.len);
}

// ============================================================================
// Tests — one-language-per-project policy gate (#584)
// ============================================================================

/// A `.plugins` entry for the scripting plugin:
/// `.params = .{ .language = … }`, repo a staged EMPTY local dir
/// (`<project>/plugins/scripting/`) so `loadOptional` resolves cleanly to
/// "no plugin.labelle" without warnings or cache access.
fn stageScriptingPlugin(tmp: *std.testing.TmpDir, lang: []const u8) !config.PluginDep {
    try tmp.dir.createDirPath(testing.io, "plugins/scripting");
    return .{ .name = "labelle-scripting", .repo = "local:plugins/scripting", .params = .{ .language = lang } };
}

test "validateLanguagePolicy: clean project (no .params.language, no language dirs) passes (#584)" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const project_dir = try tmp.dir.realPathFileAlloc(testing.io, ".", allocator);
    defer allocator.free(project_dir);

    try validateLanguagePolicy(allocator, &.{}, &.{}, project_dir);
}

test "validateLanguagePolicy: a rust/ file in a lua project fails the generate gate (#584)" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeTestFile(tmp.dir, "rust/native/collision.rs", "pub fn solve() {}\n");
    const scripting = try stageScriptingPlugin(&tmp, "lua");
    const project_dir = try tmp.dir.realPathFileAlloc(testing.io, ".", allocator);
    defer allocator.free(project_dir);

    try testing.expectError(
        error.ScriptLanguageMismatch,
        validateLanguagePolicy(allocator, &.{}, &.{scripting}, project_dir),
    );
}

test "validateLanguagePolicy: language files with NO scripting plugin error with the attach hint (#584)" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeTestFile(tmp.dir, "lua/player_ai.lua", "return {}\n");
    const project_dir = try tmp.dir.realPathFileAlloc(testing.io, ".", allocator);
    defer allocator.free(project_dir);

    try testing.expectError(
        error.MissingScriptingPlugin,
        validateLanguagePolicy(allocator, &.{}, &.{}, project_dir),
    );
}

test "validateLanguagePolicy: two plugins declaring .params.language error (#584)" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const project_dir = try tmp.dir.realPathFileAlloc(testing.io, ".", allocator);
    defer allocator.free(project_dir);

    const plugins = [_]config.PluginDep{
        .{ .name = "labelle-scripting", .repo = "local:plugins/a", .params = .{ .language = "lua" } },
        .{ .name = "acme-scripting", .repo = "local:plugins/b", .params = .{ .language = "rust" } },
    };
    // Fails on the config alone — before any manifest/dir access, so the
    // (nonexistent) repo dirs are never touched.
    try testing.expectError(
        error.MultipleLanguagePlugins,
        validateLanguagePolicy(allocator, &.{}, &plugins, project_dir),
    );
}

test "validateLanguagePolicy: pack requires_language mismatch errors naming the pack (#584)" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    // A Ruby-scripted pack attached to a Lua project (RFC rev 8's example).
    try writeTestFile(tmp.dir, "packs/dungeon/pack.labelle",
        \\.{
        \\    .name = "dungeon",
        \\    .manifest_version = 1,
        \\    .requires_language = "ruby",
        \\}
    );
    const scripting = try stageScriptingPlugin(&tmp, "lua");
    const project_dir = try tmp.dir.realPathFileAlloc(testing.io, ".", allocator);
    defer allocator.free(project_dir);

    const plugins = [_]config.PluginDep{
        scripting,
        .{ .name = "dungeon", .repo = "@packs/dungeon" },
    };
    var pack_entries = try loadPackEntries(allocator, &plugins, project_dir);
    defer {
        for (pack_entries.items) |*e| e.deinit(allocator);
        pack_entries.deinit(allocator);
    }
    try testing.expectEqual(@as(usize, 1), pack_entries.items.len);

    try testing.expectError(
        error.LanguageRequirementMismatch,
        validateLanguagePolicy(allocator, pack_entries.items, &plugins, project_dir),
    );
}

test "validateLanguagePolicy: pack requires_language match passes (#584)" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeTestFile(tmp.dir, "packs/dungeon/pack.labelle",
        \\.{
        \\    .name = "dungeon",
        \\    .manifest_version = 1,
        \\    .requires_language = "lua",
        \\}
    );
    // The pack's own lua/ scripts are the declared language — legal.
    try writeTestFile(tmp.dir, "packs/dungeon/lua/room.lua", "return {}\n");
    const scripting = try stageScriptingPlugin(&tmp, "lua");
    const project_dir = try tmp.dir.realPathFileAlloc(testing.io, ".", allocator);
    defer allocator.free(project_dir);

    const plugins = [_]config.PluginDep{
        scripting,
        .{ .name = "dungeon", .repo = "@packs/dungeon" },
    };
    var pack_entries = try loadPackEntries(allocator, &plugins, project_dir);
    defer {
        for (pack_entries.items) |*e| e.deinit(allocator);
        pack_entries.deinit(allocator);
    }

    try validateLanguagePolicy(allocator, pack_entries.items, &plugins, project_dir);
}

test "validateLanguagePolicy: a pack dir bundling a foreign-language script errors (#584)" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    // The pack declares NO requires_language but smuggles ruby/ scripts —
    // the dir scan (the cross-check layer) still catches it.
    try writeTestFile(tmp.dir, "packs/dungeon/pack.labelle",
        \\.{
        \\    .name = "dungeon",
        \\    .manifest_version = 1,
        \\}
    );
    try writeTestFile(tmp.dir, "packs/dungeon/ruby/room.rb", "class Room; end\n");
    const scripting = try stageScriptingPlugin(&tmp, "lua");
    const project_dir = try tmp.dir.realPathFileAlloc(testing.io, ".", allocator);
    defer allocator.free(project_dir);

    const plugins = [_]config.PluginDep{
        scripting,
        .{ .name = "dungeon", .repo = "@packs/dungeon" },
    };
    var pack_entries = try loadPackEntries(allocator, &plugins, project_dir);
    defer {
        for (pack_entries.items) |*e| e.deinit(allocator);
        pack_entries.deinit(allocator);
    }

    try testing.expectError(
        error.ScriptLanguageMismatch,
        validateLanguagePolicy(allocator, pack_entries.items, &plugins, project_dir),
    );
}

test "validateLanguagePolicy: plugin manifest requires_language mismatch errors (#584)" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    // A decl-module plugin whose plugin.labelle requires ruby, attached to a
    // lua project — the plugin-manifest half of the attach check.
    try writeTestFile(tmp.dir, "plugins/rubyplug/plugin.labelle",
        \\.{
        \\    .name = "rubyplug",
        \\    .manifest_version = 1,
        \\    .requires_language = "ruby",
        \\}
    );
    const scripting = try stageScriptingPlugin(&tmp, "lua");
    const project_dir = try tmp.dir.realPathFileAlloc(testing.io, ".", allocator);
    defer allocator.free(project_dir);

    const plugins = [_]config.PluginDep{
        scripting,
        .{ .name = "rubyplug", .repo = "local:plugins/rubyplug" },
    };
    try testing.expectError(
        error.LanguageRequirementMismatch,
        validateLanguagePolicy(allocator, &.{}, &plugins, project_dir),
    );
}

// ============================================================================
// Tests — uniform tile grid → synthesised atlas (#675)
// ============================================================================

/// A PNG prefix that is real enough for `parsePngDims`: signature, the
/// 13-byte IHDR chunk length, the `IHDR` tag, then big-endian width/height.
/// The rest of a PNG is irrelevant to the pass — it never decodes pixels.
fn fakePngHeader(width: u32, height: u32) [png_header_len]u8 {
    var out: [png_header_len]u8 = undefined;
    @memcpy(out[0..8], &png_signature);
    std.mem.writeInt(u32, out[8..12], 13, .big);
    @memcpy(out[12..16], "IHDR");
    std.mem.writeInt(u32, out[16..20], width, .big);
    std.mem.writeInt(u32, out[20..24], height, .big);
    return out;
}

test "parsePngDims: reads big-endian width/height out of the IHDR (#675)" {
    const header = fakePngHeader(640, 608);
    const dims = try parsePngDims(&header);
    try testing.expectEqual(@as(u32, 640), dims.width);
    try testing.expectEqual(@as(u32, 608), dims.height);
}

test "parsePngDims: a bad signature is rejected before the ints are trusted (#675)" {
    var header = fakePngHeader(64, 64);
    header[1] = 'X';
    try testing.expectError(error.GridImageNotPng, parsePngDims(&header));
}

test "parsePngDims: a non-IHDR first chunk is rejected (#675)" {
    var header = fakePngHeader(64, 64);
    @memcpy(header[12..16], "IDAT");
    try testing.expectError(error.GridImageNotPng, parsePngDims(&header));
}

test "parsePngDims: a file shorter than the header is rejected (#675)" {
    const header = fakePngHeader(64, 64);
    try testing.expectError(error.GridImageNotPng, parsePngDims(header[0..23]));
}

test "gridCounts: the plain case divides the image by the tile size (#675)" {
    const counts = try gridCounts(.{ .width = 640, .height = 608 }, .{ .tile_width = 16, .tile_height = 16 });
    try testing.expectEqual(@as(u32, 40), counts.cols);
    try testing.expectEqual(@as(u32, 38), counts.rows);
}

test "gridCounts: margin borders BOTH edges and spacing sits BETWEEN tiles (Tiled, #675)" {
    // 4 tiles of 16 with 1px spacing between them and a 2px border:
    //   2 + 4*16 + 3*1 + 2 = 71
    // Getting this wrong (e.g. margin counted once, or spacing counted after
    // the last tile) yields subtly-offset tiles that look almost right.
    const counts = try gridCounts(
        .{ .width = 71, .height = 71 },
        .{ .tile_width = 16, .tile_height = 16, .margin = 2, .spacing = 1 },
    );
    try testing.expectEqual(@as(u32, 4), counts.cols);
    try testing.expectEqual(@as(u32, 4), counts.rows);
}

test "gridCounts: a grid that does not divide evenly is an error, not a truncation (#675)" {
    // 641 is one pixel past 40 columns of 16 — the silent-truncation bug
    // would report 40 and drop the ragged remainder without a word.
    try testing.expectError(
        error.GridDoesNotDivideEvenly,
        gridCounts(.{ .width = 641, .height = 608 }, .{ .tile_width = 16, .tile_height = 16 }),
    );
}

test "gridCounts: a tile larger than the image is an error (#675)" {
    try testing.expectError(
        error.GridDoesNotDivideEvenly,
        gridCounts(.{ .width = 8, .height = 8 }, .{ .tile_width = 16, .tile_height = 16 }),
    );
}

test "gridCounts: a margin wider than the image is an error, not a wrap (#675)" {
    try testing.expectError(
        error.GridMarginExceedsImage,
        gridCounts(.{ .width = 32, .height = 32 }, .{ .tile_width = 16, .tile_height = 16, .margin = 40 }),
    );
}

test "gridCounts: a huge margin cannot wrap `2 * margin` into a small number (#675)" {
    try testing.expectError(
        error.GridMarginExceedsImage,
        gridCounts(
            .{ .width = 32, .height = 32 },
            .{ .tile_width = 16, .tile_height = 16, .margin = std.math.maxInt(u32) },
        ),
    );
}

test "gridCounts: a zero tile size is an error, not a divide-by-zero (#675)" {
    try testing.expectError(
        error.GridZeroTileSize,
        gridCounts(.{ .width = 32, .height = 32 }, .{ .tile_width = 0, .tile_height = 16 }),
    );
}

test "buildGridManifest: FRAME NAMING CONTRACT — `<name>/<index>`, row-major, zero-based (#675)" {
    // This is the string a game spells in a prefab's `sprite_name`, in
    // `findSprite`, or derives from a Tiled GID. Changing it breaks every
    // project that ships a `.grid` resource, so it is pinned here.
    const allocator = testing.allocator;
    const dims: PngDims = .{ .width = 48, .height = 32 };
    const grid: config.GridDef = .{ .tile_width = 16, .tile_height = 16 };
    const counts = try gridCounts(dims, grid);
    try testing.expectEqual(@as(u32, 3), counts.cols);
    try testing.expectEqual(@as(u32, 2), counts.rows);

    const manifest = try buildGridManifest(allocator, "tiles", "assets/overworld.png", dims, grid, counts);
    defer allocator.free(manifest);

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, manifest, .{});
    defer parsed.deinit();
    const frames = parsed.value.object.get("frames").?.object;

    // Exactly cols*rows frames, named 0..n-1 under the resource name.
    try testing.expectEqual(@as(usize, 6), frames.count());
    for (0..6) |i| {
        var name_buf: [32]u8 = undefined;
        const key = try std.fmt.bufPrint(&name_buf, "tiles/{d}", .{i});
        try testing.expect(frames.get(key) != null);
    }
    // No zero-padding, no `t0` form, no 1-based index.
    try testing.expect(frames.get("tiles/00") == null);
    try testing.expect(frames.get("t0") == null);
    try testing.expect(frames.get("tiles/6") == null);

    // Row-major from the TOP-LEFT: index 1 is the cell to the RIGHT of 0,
    // index 3 is the first cell of the second row.
    const f0 = frames.get("tiles/0").?.object.get("frame").?.object;
    try testing.expectEqual(@as(i64, 0), f0.get("x").?.integer);
    try testing.expectEqual(@as(i64, 0), f0.get("y").?.integer);
    const f1 = frames.get("tiles/1").?.object.get("frame").?.object;
    try testing.expectEqual(@as(i64, 16), f1.get("x").?.integer);
    try testing.expectEqual(@as(i64, 0), f1.get("y").?.integer);
    const f3 = frames.get("tiles/3").?.object.get("frame").?.object;
    try testing.expectEqual(@as(i64, 0), f3.get("x").?.integer);
    try testing.expectEqual(@as(i64, 16), f3.get("y").?.integer);
    const f5 = frames.get("tiles/5").?.object.get("frame").?.object;
    try testing.expectEqual(@as(i64, 32), f5.get("x").?.integer);
    try testing.expectEqual(@as(i64, 16), f5.get("y").?.integer);
    try testing.expectEqual(@as(i64, 16), f5.get("w").?.integer);
    try testing.expectEqual(@as(i64, 16), f5.get("h").?.integer);

    // `meta.size` mirrors the real image so the engine's texture scale is 1.
    const size = parsed.value.object.get("meta").?.object.get("size").?.object;
    try testing.expectEqual(@as(i64, 48), size.get("w").?.integer);
    try testing.expectEqual(@as(i64, 32), size.get("h").?.integer);
}

test "buildGridManifest: margin/spacing place cells at `margin + i*(tile+spacing)` (#675)" {
    const allocator = testing.allocator;
    const dims: PngDims = .{ .width = 71, .height = 71 };
    const grid: config.GridDef = .{ .tile_width = 16, .tile_height = 16, .margin = 2, .spacing = 1 };
    const counts = try gridCounts(dims, grid);
    const manifest = try buildGridManifest(allocator, "extruded", "assets/extruded.png", dims, grid, counts);
    defer allocator.free(manifest);

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, manifest, .{});
    defer parsed.deinit();
    const frames = parsed.value.object.get("frames").?.object;
    try testing.expectEqual(@as(usize, 16), frames.count());

    const f0 = frames.get("extruded/0").?.object.get("frame").?.object;
    try testing.expectEqual(@as(i64, 2), f0.get("x").?.integer);
    try testing.expectEqual(@as(i64, 2), f0.get("y").?.integer);
    // col 1 → 2 + 1*(16+1) = 19; last col (3) → 2 + 3*17 = 53, ending at 69,
    // which leaves exactly the 2px right margin of a 71px image.
    const f1 = frames.get("extruded/1").?.object.get("frame").?.object;
    try testing.expectEqual(@as(i64, 19), f1.get("x").?.integer);
    const f15 = frames.get("extruded/15").?.object.get("frame").?.object;
    try testing.expectEqual(@as(i64, 53), f15.get("x").?.integer);
    try testing.expectEqual(@as(i64, 53), f15.get("y").?.integer);
}

test "expandGridResources: rewrites the entry to an ordinary atlas + writes the manifest (#675)" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const header = fakePngHeader(48, 32);
    try writeTestFile(tmp.dir, "game/assets/overworld.png", &header);
    try tmp.dir.createDirPath(testing.io, "game/.labelle/null_desktop");

    const game_dir = try tmp.dir.realPathFileAlloc(testing.io, "game", allocator);
    defer allocator.free(game_dir);
    const target_dir = try std.fs.path.join(allocator, &.{ game_dir, ".labelle", "null_desktop" });
    defer allocator.free(target_dir);

    var resources = [_]ResourceDef{
        .{ .name = "sfx", .sound = "audio/click.wav" },
        .{
            .name = "tiles",
            .image = "assets/overworld.png",
            .grid = .{ .tile_width = 16, .tile_height = 16 },
        },
    };

    var allocs = try expandGridResources(allocator, testing.io, &resources, game_dir, target_dir);
    defer {
        for (allocs.items) |s| allocator.free(s);
        allocs.deinit(allocator);
    }

    // The non-grid resource is untouched (purely additive).
    try testing.expectEqual(config.ResourceKind.sound, resources[0].kind());
    try testing.expectEqualStrings("audio/click.wav", resources[0].sound);

    // The grid entry is now an ORDINARY atlas — nothing downstream needs to
    // learn a new kind.
    const tiles = resources[1];
    try testing.expectEqual(config.ResourceKind.atlas, tiles.kind());
    try testing.expectEqual(config.ResourceValidationError.ok, tiles.validate());
    try testing.expectEqualStrings("__grid_tiles.json", tiles.json);
    try testing.expectEqualStrings("assets/overworld.png", tiles.texture);
    try testing.expectEqualStrings("", tiles.image);
    try testing.expect(tiles.grid == null);

    // The synthesised manifest landed in the TARGET dir (a generated tree),
    // never in the user's `assets/` — which is symlinked into the target.
    const written = try tmp.dir.readFileAlloc(
        testing.io,
        "game/.labelle/null_desktop/__grid_tiles.json",
        allocator,
        .limited(1 << 20),
    );
    defer allocator.free(written);
    const frames = try pack_resources.collectAtlasFramesFromBytes(allocator, written);
    defer {
        for (frames) |f| allocator.free(f);
        allocator.free(frames);
    }
    try testing.expectEqual(@as(usize, 6), frames.len);
}

test "expandGridResources: `.texture` stays a .png so the astc/rgba swaps still apply (#675)" {
    // The phase deliberately runs BEFORE `swapAstcTexturePaths` /
    // `swapRgbaTexturePaths`: those key on a `.png`-suffixed `res.texture`,
    // so a tileset gets the same sibling preference a hand-authored atlas
    // does. Reordering would silently drop compression for tilesets — the
    // single biggest texture in most projects.
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const header = fakePngHeader(32, 32);
    try writeTestFile(tmp.dir, "game/assets/tiles.png", &header);
    try writeTestFile(tmp.dir, "game/assets/tiles.astc", "not-really-astc");
    const game_dir = try tmp.dir.realPathFileAlloc(testing.io, "game", allocator);
    defer allocator.free(game_dir);
    const target_dir = try std.fs.path.join(allocator, &.{ game_dir, "target" });
    defer allocator.free(target_dir);

    var resources = [_]ResourceDef{.{
        .name = "tiles",
        .image = "assets/tiles.png",
        .grid = .{ .tile_width = 16, .tile_height = 16 },
    }};
    var allocs = try expandGridResources(allocator, testing.io, &resources, game_dir, target_dir);
    defer {
        for (allocs.items) |s| allocator.free(s);
        allocs.deinit(allocator);
    }
    try testing.expectEqualStrings("assets/tiles.png", resources[0].texture);

    var astc_allocs = try swapAstcTexturePaths(
        allocator,
        testing.io,
        .{ .name = "g", .asset_compression = .{ .desktop = .astc }, .platform = .desktop },
        &resources,
        game_dir,
    );
    defer {
        for (astc_allocs.items) |s| allocator.free(s);
        astc_allocs.deinit(allocator);
    }
    try testing.expectEqualStrings("assets/tiles.astc", resources[0].texture);
}

test "expandGridResources: a project with no `.grid` writes nothing and touches nothing (#675)" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const game_dir = try tmp.dir.realPathFileAlloc(testing.io, ".", allocator);
    defer allocator.free(game_dir);
    const target_dir = try std.fs.path.join(allocator, &.{ game_dir, "target" });
    defer allocator.free(target_dir);

    var resources = [_]ResourceDef{
        .{ .name = "hero", .json = "assets/hero.json", .texture = "assets/hero.png" },
        .{ .name = "portrait", .image = "assets/portrait.png" },
    };
    const before = resources;
    var allocs = try expandGridResources(allocator, testing.io, &resources, game_dir, target_dir);
    defer allocs.deinit(allocator);

    try testing.expectEqual(@as(usize, 0), allocs.items.len);
    try testing.expectEqualStrings(before[0].json, resources[0].json);
    try testing.expectEqualStrings(before[1].image, resources[1].image);
    // The target dir is only created when there IS a grid to expand.
    try testing.expectError(error.FileNotFound, tmp.dir.openDir(testing.io, "target", .{}));
}

test "expandGridResources: `.grid` on a non-image resource is refused (#675)" {
    const allocator = testing.allocator;
    var resources = [_]ResourceDef{.{
        .name = "sfx",
        .sound = "audio/click.wav",
        .grid = .{ .tile_width = 16, .tile_height = 16 },
    }};
    try testing.expectError(
        error.GridMisplaced,
        expandGridResources(allocator, testing.io, &resources, "/nonexistent", "/nonexistent/target"),
    );
}

test "expandGridResources: a non-PNG `.grid` image is refused up front (#675)" {
    const allocator = testing.allocator;
    var resources = [_]ResourceDef{.{
        .name = "tiles",
        .image = "assets/tiles.astc",
        .grid = .{ .tile_width = 16, .tile_height = 16 },
    }};
    try testing.expectError(
        error.GridImageNotPng,
        expandGridResources(allocator, testing.io, &resources, "/nonexistent", "/nonexistent/target"),
    );
}

test "expandGridResources: a missing `.image` file reports GridImageUnreadable (#675)" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const game_dir = try tmp.dir.realPathFileAlloc(testing.io, ".", allocator);
    defer allocator.free(game_dir);

    var resources = [_]ResourceDef{.{
        .name = "tiles",
        .image = "assets/missing.png",
        .grid = .{ .tile_width = 16, .tile_height = 16 },
    }};
    try testing.expectError(
        error.GridImageUnreadable,
        expandGridResources(allocator, testing.io, &resources, game_dir, "target"),
    );
}

test "expandGridResources: an uneven grid is refused with the image in hand (#675)" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const header = fakePngHeader(50, 32);
    try writeTestFile(tmp.dir, "assets/tiles.png", &header);
    const game_dir = try tmp.dir.realPathFileAlloc(testing.io, ".", allocator);
    defer allocator.free(game_dir);
    const target_dir = try std.fs.path.join(allocator, &.{ game_dir, "target" });
    defer allocator.free(target_dir);

    var resources = [_]ResourceDef{.{
        .name = "tiles",
        .image = "assets/tiles.png",
        .grid = .{ .tile_width = 16, .tile_height = 16 },
    }};
    try testing.expectError(
        error.GridDoesNotDivideEvenly,
        expandGridResources(allocator, testing.io, &resources, game_dir, target_dir),
    );
}

test "gridCounts: a header claiming astronomical dimensions is capped, not looped over (#675)" {
    // The 24-byte IHDR is unverifiable — a truncated, corrupt or hand-crafted
    // file can claim 4-billion pixels on both axes. Without the cap,
    // `buildGridManifest` would enter a nested loop asking for ~1.8e19 frames:
    // a generate that appears to hang while it writes a manifest no machine
    // can hold. The counts are rejected BEFORE anything iterates them.
    const dims: PngDims = .{ .width = std.math.maxInt(u32), .height = std.math.maxInt(u32) };
    try testing.expectError(
        error.GridTooManyFrames,
        gridCounts(dims, .{ .tile_width = 1, .tile_height = 1 }),
    );
}

test "gridCounts: an honest typo (`tile_width = 1`) trips the same cap (#675)" {
    // Not just a hostile-file guard: a stray 1 on a real 4096-wide sheet is
    // worth 16.7M frames and a multi-gigabyte manifest the build then embeds.
    const dims: PngDims = .{ .width = 4096, .height = 4096 };
    try testing.expectError(
        error.GridTooManyFrames,
        gridCounts(dims, .{ .tile_width = 1, .tile_height = 1 }),
    );
}

test "gridCounts: the biggest REAL tileset still passes — the cap sits above it (#675)" {
    // 8192 x 8192 (max texture size on essentially every targeted GPU) cut
    // into 16 x 16 tiles is exactly `max_grid_frames`. The limit is an upper
    // bound on the absurd, never a budget a real project has to fit inside.
    const dims: PngDims = .{ .width = 8192, .height = 8192 };
    const counts = try gridCounts(dims, .{ .tile_width = 16, .tile_height = 16 });
    try testing.expectEqual(@as(u32, 512), counts.cols);
    try testing.expectEqual(@as(u32, 512), counts.rows);
    try testing.expectEqual(max_grid_frames, @as(u64, counts.cols) * counts.rows);
}

test "buildGridManifest: a maxInt spacing on a one-cell grid renders, it does not wrap (#675)" {
    // `spacing` is never applied AFTER the last cell, so a 1x1 image with a
    // 1x1 tile and `spacing = maxInt(u32)` is one mathematically valid frame —
    // and `gridCounts` says so. Computing `tile_width + spacing` in `u32`
    // would nonetheless overflow on the very first iteration, turning a legal
    // one-frame atlas into a safety panic. The intermediates run in `u64`.
    const allocator = testing.allocator;
    const dims: PngDims = .{ .width = 1, .height = 1 };
    const grid: config.GridDef = .{
        .tile_width = 1,
        .tile_height = 1,
        .spacing = std.math.maxInt(u32),
    };
    const counts = try gridCounts(dims, grid);
    try testing.expectEqual(@as(u32, 1), counts.cols);
    try testing.expectEqual(@as(u32, 1), counts.rows);

    const manifest = try buildGridManifest(allocator, "tiles", "assets/tiles.png", dims, grid, counts);
    defer allocator.free(manifest);
    try testing.expect(std.mem.indexOf(u8, manifest, "\"tiles/0\"") != null);
    try testing.expect(std.mem.indexOf(u8, manifest, "\"x\": 0, \"y\": 0") != null);
}

test "gridManifestRel: an ordinary name keeps the plain, greppable spelling (#675)" {
    const allocator = testing.allocator;
    const rel = try gridManifestRel(allocator, "tiles");
    defer allocator.free(rel);
    try testing.expectEqualStrings("__grid_tiles.json", rel);
}

test "gridManifestRel: a name with a path separator cannot become a sub-path (#675)" {
    // Only FONT names are checked for identifier shape; an image name is
    // free-form, so `.name = "ui/tiles"` is legal — and would have produced
    // the sub-path `__grid_ui/tiles.json`. `scanner.writeFile` creates the
    // file inside the target dir without creating intermediate directories,
    // so that spelling failed generation with a bare `FileNotFound`.
    const allocator = testing.allocator;
    const rel = try gridManifestRel(allocator, "ui/tiles");
    defer allocator.free(rel);
    try testing.expect(std.mem.indexOfAny(u8, rel, "/\\") == null);
    try testing.expect(std.mem.startsWith(u8, rel, "__grid_ui_tiles."));
    try testing.expect(std.mem.endsWith(u8, rel, ".json"));
}

test "gridManifestRel: `..` cannot escape the generated tree (#675)" {
    // `..` is `[A-Za-z0-9_.-]`-clean yet names a DIRECTORY: left alone,
    // `__grid_../../evil.json` would write outside the target dir entirely.
    // Flattening the separators is what defuses it — the dots may survive
    // inside the filename, because without a separator they are just bytes.
    const allocator = testing.allocator;
    const rel = try gridManifestRel(allocator, "../../evil");
    defer allocator.free(rel);
    try testing.expectEqualStrings(rel, std.fs.path.basename(rel));
    try testing.expect(std.mem.indexOfAny(u8, rel, "/\\") == null);

    // A bare `..` names the PARENT directory; it must not survive as one.
    const dots = try gridManifestRel(allocator, "..");
    defer allocator.free(dots);
    try testing.expect(!std.mem.eql(u8, "__grid_...json", dots));
    try testing.expectEqualStrings(dots, std.fs.path.basename(dots));
}

test "gridManifestRel: two names that sanitise alike still get separate files (#675)" {
    // `a/b` and `a\b` both flatten to `a_b`; the hash of the ORIGINAL name is
    // what keeps one resource from overwriting the other's manifest.
    const allocator = testing.allocator;
    const slash = try gridManifestRel(allocator, "a/b");
    defer allocator.free(slash);
    const backslash = try gridManifestRel(allocator, "a\\b");
    defer allocator.free(backslash);
    try testing.expect(!std.mem.eql(u8, slash, backslash));
}

test "expandGridResources: a separator-bearing name writes ONE file in the target dir (#675)" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const header = fakePngHeader(32, 32);
    try writeTestFile(tmp.dir, "game/assets/tiles.png", &header);
    try tmp.dir.createDirPath(testing.io, "game/target");
    const game_dir = try tmp.dir.realPathFileAlloc(testing.io, "game", allocator);
    defer allocator.free(game_dir);
    const target_dir = try std.fs.path.join(allocator, &.{ game_dir, "target" });
    defer allocator.free(target_dir);

    var resources = [_]ResourceDef{.{
        .name = "ui/tiles",
        .image = "assets/tiles.png",
        .grid = .{ .tile_width = 16, .tile_height = 16 },
    }};

    // Before the sanitisation this failed with `FileNotFound`: the manifest
    // path named a `ui/` directory that the target tree does not have.
    var allocs = try expandGridResources(allocator, testing.io, &resources, game_dir, target_dir);
    defer {
        for (allocs.items) |s| allocator.free(s);
        allocs.deinit(allocator);
    }

    try testing.expectEqual(config.ResourceKind.atlas, resources[0].kind());
    try testing.expect(std.mem.indexOfAny(u8, resources[0].json, "/\\") == null);

    // The file really is there, under the name the entry now points at, and
    // it still names its frames after the ORIGINAL resource (`<name>/<index>`
    // is a public contract; the filename is not).
    const rel = try std.fs.path.join(allocator, &.{ "game", "target", resources[0].json });
    defer allocator.free(rel);
    const written = try tmp.dir.readFileAlloc(testing.io, rel, allocator, .limited(1 << 20));
    defer allocator.free(written);
    try testing.expect(std.mem.indexOf(u8, written, "\"ui/tiles/0\"") != null);
}

test "expandGridResources: a grid entry with a second asset path is refused (#675)" {
    // `.image` + `.sound` is `multiple_paths`. The pass runs long before
    // `validateResources`, so it owns the diagnostic for this entry — it is
    // written to stderr (silenced under test) and the mapped error surfaces.
    const allocator = testing.allocator;
    var resources = [_]ResourceDef{.{
        .name = "tiles",
        .image = "assets/tiles.png",
        .sound = "audio/click.wav",
        .grid = .{ .tile_width = 16, .tile_height = 16 },
    }};
    try testing.expectError(
        error.InvalidResource,
        expandGridResources(allocator, testing.io, &resources, "game", "target"),
    );
}

test "swapAstcTexturePaths: an uppercase `.PNG` gets the same sibling preference (#675)" {
    // `codegen/validate.zig` accepts image extensions case-INSENSITIVELY, and
    // so does the `.grid` gate — a case-sensitive swap predicate therefore
    // silently skipped `assets/tiles.PNG` and embedded the raw PNG next to an
    // `.astc` sibling that exists and was never used.
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeTestFile(tmp.dir, "assets/tiles.PNG", "png");
    try writeTestFile(tmp.dir, "assets/tiles.astc", "astc");
    const game_dir = try tmp.dir.realPathFileAlloc(testing.io, ".", allocator);
    defer allocator.free(game_dir);

    var resources = [_]ResourceDef{.{
        .name = "tiles",
        .json = "assets/tiles.json",
        .texture = "assets/tiles.PNG",
    }};
    const cfg: ProjectConfig = .{ .name = "g", .asset_compression = .{ .desktop = .astc }, .platform = .desktop };

    var allocs = try swapAstcTexturePaths(allocator, testing.io, cfg, &resources, game_dir);
    defer {
        for (allocs.items) |s| allocator.free(s);
        allocs.deinit(allocator);
    }
    try testing.expectEqualStrings("assets/tiles.astc", resources[0].texture);
}

test "swapRgbaTexturePaths: an uppercase `.PNG` gets the same sibling preference (#675)" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeTestFile(tmp.dir, "assets/tiles.PNG", "png");
    try writeTestFile(tmp.dir, "assets/tiles.rgba", "rgba");
    const game_dir = try tmp.dir.realPathFileAlloc(testing.io, ".", allocator);
    defer allocator.free(game_dir);

    var resources = [_]ResourceDef{.{
        .name = "tiles",
        .json = "assets/tiles.json",
        .texture = "assets/tiles.PNG",
    }};
    var allocs = try swapRgbaTexturePaths(allocator, testing.io, &resources, game_dir);
    defer {
        for (allocs.items) |s| allocator.free(s);
        allocs.deinit(allocator);
    }
    try testing.expectEqualStrings("assets/tiles.rgba", resources[0].texture);
}
