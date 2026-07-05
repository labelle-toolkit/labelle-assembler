//! Pack convention-dir scanning + copy + namespace rewriting, extracted
//! from `root.zig` (behavior-preserving split). Owns the filesystem
//! copy/scan of a light pack's `components/ events/ prefabs/ hooks/ scripts/`
//! subdirs and the `<pack>__`-prefix rewrite of the copied prefab/hook
//! sources (#439/#440/#487). See the Packs RFC §4.
//!
//! Bit-identical contract: the rewritten prefab/hook bytes and the scanned
//! stem lists feed the codegen registries — the pack-scan golden tests cover
//! the copy/scan/rewrite shape end-to-end.

const std = @import("std");
const config = @import("../config.zig");
const scanner = @import("../scanner.zig");
const cache = @import("../cache.zig");
const script_scanner = @import("../script_scanner.zig");
const scene_name_lint = @import("../scene_name_lint.zig");
const main_zig = @import("../main_zig.zig");
const scan = @import("../codegen/scan.zig");
const idents = @import("../codegen/idents.zig");

/// Copy + scan one convention subdir of a pack into the generated target,
/// returning the sorted file stems. Source is `<pack_src_dir>/<subdir>`;
/// destination is `<dst_base>/<subdir>` (a generator-owned dir under
/// `<target>/packs/<name>/`). A missing source subdir is tolerated —
/// `copyAndScanAbs` returns an empty list — so a pack can ship, say,
/// `components/` + `events/` without a `prefabs/` and not error.
fn scanPackSubdir(
    allocator: std.mem.Allocator,
    pack_src_dir: []const u8,
    dst_base: []const u8,
    subdir: []const u8,
    ext: []const u8,
) ![][]const u8 {
    const src = try std.fs.path.join(allocator, &.{ pack_src_dir, subdir });
    defer allocator.free(src);
    const dst = try std.fs.path.join(allocator, &.{ dst_base, subdir });
    defer allocator.free(dst);
    return scanner.copyAndScanAbs(allocator, src, dst, ext);
}

/// Select the decl-module subset of `plugins` (labelle-assembler#481).
///
/// A game's `.plugins` list mixes two kinds of dependency:
///
///   - **decl-module plugins** — a real Zig package (`plugin.labelle` +
///     `src/root.zig` exports) that the generated build wires in as a module
///     and the generated `main.zig` reaches via `@import("<name>")`.
///   - **light packs** — module-less, directory-scanned convention bundles
///     (they carry `pack.labelle`, so their name appears in `pack_names`).
///     A light pack has NO `build.zig` and NO importable module; its entire
///     contribution is the already-scanned + `<pack>__`-namespaced registry
///     entries (#439/#440). Emitting `@import("<pack>")` or a
///     `b.dependency("labelle_<pack>", …)` for one fails to resolve and breaks
///     `labelle build` — the gap this ticket closes.
///
/// Returns the subset of `plugins` whose name is NOT in `pack_names`, i.e. the
/// plugins that DO ship an importable module. The order of `plugins` is
/// preserved. The returned slice is caller-owned (`allocator.free`); the
/// `PluginDep` elements are shallow copies that alias the input's strings.
pub fn declModulePlugins(
    allocator: std.mem.Allocator,
    plugins: []const config.PluginDep,
    pack_names: []const []const u8,
) ![]config.PluginDep {
    var out: std.ArrayList(config.PluginDep) = .empty;
    errdefer out.deinit(allocator);
    try out.ensureTotalCapacity(allocator, plugins.len);
    for (plugins) |plugin| {
        var is_light_pack = false;
        for (pack_names) |pack_name| {
            if (std.mem.eql(u8, pack_name, plugin.name)) {
                is_light_pack = true;
                break;
            }
        }
        if (!is_light_pack) out.appendAssumeCapacity(plugin);
    }
    return out.toOwnedSlice(allocator);
}

/// Scan a pack's convention subdirs (Packs RFC §4, labelle-assembler#439).
///
/// Copies `<pack_src_dir>/{components,events,prefabs,hooks}/` into
/// `<target_dir>/packs/<pack_name>/{...}/` and collects the scanned stems
/// into a `PackScan` whose `import_prefix` is `packs/<pack_name>` — the path
/// the generated `main.zig` imports through. The returned `PackScan` owns
/// every string; the caller must `deinit` it.
///
/// After copying the pack's `prefabs/`, this rewrites each copied prefab's
/// local component references to the invisible `<pack>__<Name>` form (#440,
/// see `scan.rewritePackComponentKeys`) so a pack author's `.Worker` resolves
/// against the namespaced field the component registry emits. Only the pack's
/// OWN scanned components are rewritten; built-in/engine names are left alone.
///
/// Exposed publicly so tests can exercise the copy/scan without the full
/// cache-resolution + codegen pipeline.
/// Copy a light pack's `scripts/` subtree into `<target>/packs/<name>/scripts/`
/// and register it into `script_scan` (labelle-assembler#487). Call at the
/// pack's `.plugins` declaration-order position so the scanner's `plugin_index`
/// reflects that order (#494).
///
/// Pack scripts land UNDER the pack dir (NOT `scripts/.plugin_<name>/`) so a
/// pack script's own `@import("../components/foo.zig")` keeps resolving against
/// the pack's copied `components/`.
///
/// If the pack ships NO `scripts/` source, this prunes any STALE destination a
/// PRIOR `generate` copied (whose upstream `scripts/` has since been removed)
/// and registers nothing. Without the prune, `copyAndScanAbs` would no-op on
/// the missing source — leaving the stale copy in place — and the subsequent
/// `scanPackScriptsDir` would pick those leftovers up and compile them
/// (labelle-assembler#496, codex review). Returns true iff scripts were
/// registered.
pub fn scanPackScriptsAt(
    allocator: std.mem.Allocator,
    script_scan: *script_scanner.ScriptScanner,
    pack_src_dir: []const u8,
    target_dir: []const u8,
    pack_name: []const u8,
) !bool {
    const io = config.globalIo();
    const cwd = std.Io.Dir.cwd();

    const pack_scripts_src = try std.fs.path.join(allocator, &.{ pack_src_dir, "scripts" });
    defer allocator.free(pack_scripts_src);
    const pack_scripts_dst = try std.fs.path.join(allocator, &.{ target_dir, "packs", pack_name, "scripts" });
    defer allocator.free(pack_scripts_dst);

    // Probe the pack's source `scripts/` dir. Mirror `copyAndScanAbs`'s
    // source-root open EXACTLY (scanner.copyAndScanRecursive): tolerate ONLY
    // `error.FileNotFound` — the absent-directory case — and PROPAGATE every
    // other `openDir` failure. Swallowing e.g. `AccessDenied` (broken mount /
    // permissions) or `NotDir` (`scripts` is a file) as "no scripts" would
    // prune the generated copy and silently produce an incomplete build
    // instead of surfacing the real error (codex P2 on #500).
    var probe = cwd.openDir(io, pack_scripts_src, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => {
            // No `scripts/` source → prune any stale dest a prior generate copied.
            cwd.deleteTree(io, pack_scripts_dst) catch {};
            return false;
        },
        else => return err,
    };
    probe.close(io);

    const names = try scanner.copyAndScanAbs(allocator, pack_scripts_src, pack_scripts_dst, ".zig");
    scanner.freeNames(allocator, names);
    // The generated `@import` base is the target-relative dir, mirroring
    // `PackScan.import_prefix` (`packs/<name>`) plus `/scripts`.
    const import_prefix = try std.fmt.allocPrint(allocator, "packs/{s}/scripts", .{pack_name});
    defer allocator.free(import_prefix);
    try script_scan.scanPackScriptsDir(pack_scripts_dst, import_prefix, pack_name);
    return true;
}

pub fn scanPack(
    allocator: std.mem.Allocator,
    pack_src_dir: []const u8,
    target_dir: []const u8,
    pack_name: []const u8,
) !main_zig.PackScan {
    const import_prefix = try std.fmt.allocPrint(allocator, "packs/{s}", .{pack_name});
    errdefer allocator.free(import_prefix);
    const name_owned = try allocator.dupe(u8, pack_name);
    errdefer allocator.free(name_owned);

    const dst_base = try std.fs.path.join(allocator, &.{ target_dir, "packs", pack_name });
    defer allocator.free(dst_base);

    const component_names = try scanPackSubdir(allocator, pack_src_dir, dst_base, "components", ".zig");
    errdefer scanner.freeNames(allocator, component_names);
    const event_names = try scanPackSubdir(allocator, pack_src_dir, dst_base, "events", ".zig");
    errdefer scanner.freeNames(allocator, event_names);
    const prefab_names = try scanPackSubdir(allocator, pack_src_dir, dst_base, "prefabs", ".jsonc");
    errdefer scanner.freeNames(allocator, prefab_names);
    // hooks/ (#440): scanned + registered into the game-root hook pipeline
    // under the `<pack>__` ident prefix (see the hook block-writers).
    const hook_names = try scanPackSubdir(allocator, pack_src_dir, dst_base, "hooks", ".zig");
    errdefer scanner.freeNames(allocator, hook_names);

    // Local→prefixed ref rewrite (#440): rewrite the copied prefab JSONC so a
    // pack's own component references (`"Worker"`) and prefab compositions
    // (`{ "prefab": "worker" }`) become the namespaced forms
    // (`"citizens__Worker"` / `"citizens__worker"`). Done against the copied
    // (destination) files so the source pack tree is never mutated.
    try rewritePackPrefabRefs(allocator, dst_base, pack_name, component_names, prefab_names);

    // Verb-surface files (RFC §6, #498 PR 4): a pack's root-level
    // `queries.zig` / `commands.zig` are copied beside the convention
    // dirs so `__pack_root.zig` can re-export them and `__surface.zig`
    // can narrow them to the manifest's `exposes` lists. Absent source
    // prunes a stale copy (same #496 discipline as pack scripts).
    const has_queries = try copyPackRootFile(allocator, pack_src_dir, dst_base, "queries.zig");
    const has_commands = try copyPackRootFile(allocator, pack_src_dir, dst_base, "commands.zig");
    // …and rewrite the copied hook sources so a handler written with the pack's
    // bare local event name receives its `<pack>__`-prefixed event (chatgpt-codex
    // #3). Same "mutate the copy, never the source" discipline.
    try rewritePackHookHandlers(allocator, dst_base, pack_name, event_names, hook_names);

    return .{
        .name = name_owned,
        .import_prefix = import_prefix,
        .component_names = component_names,
        .event_names = event_names,
        .prefab_names = prefab_names,
        .hook_names = hook_names,
        .has_queries = has_queries,
        .has_commands = has_commands,
    };
}

/// Copy one root-level pack file (`queries.zig`/`commands.zig`) into the
/// generated pack dir, returning whether it exists. A missing source
/// deletes any stale destination a prior generate copied — without the
/// prune, a removed verb surface would keep compiling from the leftover
/// (labelle-assembler#496's discipline, applied to single files).
fn copyPackRootFile(
    allocator: std.mem.Allocator,
    pack_src_dir: []const u8,
    dst_base: []const u8,
    filename: []const u8,
) !bool {
    const io = config.globalIo();
    const cwd = std.Io.Dir.cwd();
    const src = try std.fs.path.join(allocator, &.{ pack_src_dir, filename });
    defer allocator.free(src);
    const dst = try std.fs.path.join(allocator, &.{ dst_base, filename });
    defer allocator.free(dst);

    const bytes = cwd.readFileAlloc(io, src, allocator, .limited(1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => {
            cwd.deleteFile(io, dst) catch {};
            return false;
        },
        else => return err,
    };
    defer allocator.free(bytes);
    // A pack may ship ONLY a verb surface (no convention dirs), in which
    // case nothing above created the destination dir yet.
    try cwd.createDirPath(io, dst_base);
    try scanner.writeFile(dst_base, filename, bytes);
    return true;
}

/// Rewrite every copied pack prefab JSONC in place so its local references
/// become the invisible `<pack>__…` form (#440). Two reference kinds are
/// rewritten (see `scan.rewritePackLocalRefs`):
///
///   - **Component keys** — Pascal forms of the pack's scanned component
///     stems, only in genuine component-declaration positions (context-aware,
///     chatgpt-codex #2). Payload-data keys that happen to share a component's
///     spelling are left alone. This covers BOTH authoring shapes (#513): the
///     wrapped `"components"`/`"overrides"` maps directly, and the flat
///     RFC #596 shape via a normalization pre-pass — a flat entity that
///     declares pack-local components is converted to the wrapped shape in
///     the copy, because a namespaced (lowercase-starting) key would be
///     silently dropped by the engine's case-based flat-key classification
///     (see `scan.wrapFlatEntityComponents`). All three engine-accepted
///     top-level FILE shapes are walked (#516): the plain entity object,
///     RFC #596 file-as-array bundles (only-`meta` header skipped), and
///     legacy `"root"`-wrapper files.
///   - **Prefab references** — a `"prefab": "worker"` value naming one of the
///     pack's OWN prefabs becomes `"prefab": "citizens__worker"`, matching the
///     namespaced registration key so a same-pack prefab composition resolves
///     (chatgpt-codex #1). A pack with prefabs that reference each other but
///     ships no components is still rewritten (the guard is on prefab count,
///     not component count).
fn rewritePackPrefabRefs(
    allocator: std.mem.Allocator,
    dst_base: []const u8,
    pack_name: []const u8,
    component_names: []const []const u8,
    prefab_names: []const []const u8,
) !void {
    // Nothing to walk without prefab files. Note the guard is intentionally
    // NOT gated on `component_names` — a component-less pack can still have
    // prefab-to-prefab references that need namespacing (chatgpt-codex #1).
    if (prefab_names.len == 0) return;

    var prefix_buf: [128]u8 = undefined;
    const prefix = scan.packNamespacePrefix(pack_name, &prefix_buf);

    // Build the Pascal-form key set once — this is the exact string a JSONC
    // component key uses and the exact field the registry emits.
    var keys: std.ArrayList([]const u8) = .empty;
    defer {
        for (keys.items) |k| allocator.free(k);
        keys.deinit(allocator);
    }
    try keys.ensureTotalCapacity(allocator, component_names.len);
    for (component_names) |stem| {
        var pascal_buf: [128]u8 = undefined;
        const pascal = idents.pathToPascal(stem, &pascal_buf);
        keys.appendAssumeCapacity(try allocator.dupe(u8, pascal));
    }

    const io = config.globalIo();
    const cwd = std.Io.Dir.cwd();
    const prefabs_dir = try std.fs.path.join(allocator, &.{ dst_base, "prefabs" });
    defer allocator.free(prefabs_dir);

    for (prefab_names) |name| {
        const rel = try std.fmt.allocPrint(allocator, "{s}.jsonc", .{name});
        defer allocator.free(rel);
        const path = try std.fs.path.join(allocator, &.{ prefabs_dir, rel });
        defer allocator.free(path);

        const src = cwd.readFileAlloc(io, path, allocator, .limited(1024 * 1024)) catch |err| switch (err) {
            error.FileNotFound => continue,
            else => return err,
        };
        defer allocator.free(src);

        const rewritten = try scan.rewritePackLocalRefs(allocator, src, keys.items, prefab_names, prefix);
        defer allocator.free(rewritten);

        // Generate-time net (#516): a component-declaration position that
        // still uses one of the pack's own BARE names after the rewrite will
        // NOT attach at load — warn now instead of failing silently there.
        warnLeftoverBareKeys(allocator, path, rewritten, keys.items);

        // Only rewrite the file when the content actually changed — avoids
        // churning mtimes (and the build cache) on prefabs with no local refs.
        if (std.mem.eql(u8, rewritten, src)) continue;
        var f = try cwd.createFile(io, path, .{});
        defer f.close(io);
        try f.writeStreamingAll(io, rewritten);
    }
}

/// Log the #516 generate-time net findings for one rewritten pack-prefab
/// copy: every component declaration still using one of the pack's own bare
/// Pascal names after `scan.rewritePackLocalRefs` (see
/// `scene_name_lint.findBareLocalRefs` for what a survivor means), plus a
/// bundle file-header that carries a legacy `"entities"` list (#521 codex
/// P2) — the engine consumes a header as metadata and extracts only its
/// `meta`, so such a list is dead data that never loads; the rewrite
/// correctly skips it verbatim (engine parity, see
/// `scan.bundleHeaderLegacyEntitiesOffset`), and this warning is what
/// surfaces the probable authoring mistake. Never fails the build — the
/// net is a diagnostic, not a gate (mirrors `scanScenesDir`'s posture);
/// allocation failure just drops the warning.
fn warnLeftoverBareKeys(
    allocator: std.mem.Allocator,
    path: []const u8,
    rewritten: []const u8,
    local_keys: []const []const u8,
) void {
    if (scan.bundleHeaderLegacyEntitiesOffset(rewritten)) |off| {
        const loc = scene_name_lint.locOf(rewritten, off);
        std.log.warn(
            "labelle-assembler: pack prefab copy '{s}':{d}:{d} — the bundle's file-header element carries a legacy \"entities\" list. The engine reads only `meta` from a bundle header (RFC #596), so those entities are dead data that never loads; move them out of the header into top-level bundle elements (ref labelle-assembler#521).",
            .{ path, loc.line, loc.col },
        );
    }
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const refs = scene_name_lint.findBareLocalRefs(arena_state.allocator(), rewritten, local_keys) catch return;
    for (refs) |ref| {
        std.log.warn(
            "labelle-assembler: pack prefab copy '{s}':{d}:{d} still declares component '{s}' by its bare local name after the pack rewrite — it will NOT attach at load. Either the entity mixes a components/overrides wrapper with flat keys (RFC #596 hybrid — pick one shape), or the key sits where the engine never reads it, or the file's shape escaped the rewriter (ref labelle-assembler#516).",
            .{ path, ref.line, ref.col, ref.name },
        );
    }
}

/// Rewrite every copied pack `hooks/*.zig` in place so a handler written with
/// the pack's BARE local event name receives its `<pack>__`-prefixed event
/// (chatgpt-codex #3). Mirrors `rewritePackPrefabRefs` but over the hook
/// sources and the pack's own event names — see
/// `scan.rewritePackHookHandlerNames` for the match rule. A pack with no
/// events (nothing to prefix) or no hooks is a no-op.
fn rewritePackHookHandlers(
    allocator: std.mem.Allocator,
    dst_base: []const u8,
    pack_name: []const u8,
    event_names: []const []const u8,
    hook_names: []const []const u8,
) !void {
    if (event_names.len == 0 or hook_names.len == 0) return;

    var prefix_buf: [128]u8 = undefined;
    const prefix = scan.packNamespacePrefix(pack_name, &prefix_buf);

    const io = config.globalIo();
    const cwd = std.Io.Dir.cwd();
    const hooks_dir = try std.fs.path.join(allocator, &.{ dst_base, "hooks" });
    defer allocator.free(hooks_dir);

    for (hook_names) |name| {
        const rel = try std.fmt.allocPrint(allocator, "{s}.zig", .{name});
        defer allocator.free(rel);
        const path = try std.fs.path.join(allocator, &.{ hooks_dir, rel });
        defer allocator.free(path);

        const src = cwd.readFileAlloc(io, path, allocator, .limited(1024 * 1024)) catch |err| switch (err) {
            error.FileNotFound => continue,
            else => return err,
        };
        defer allocator.free(src);

        // `name` is the hook file stem (`overlay` / `combat/overlay`); the
        // rewrite scopes the rename to that file's receiver container
        // (`pathToPascal(name)`), so unrelated helpers are never touched.
        const rewritten = try scan.rewritePackHookHandlerNames(allocator, src, event_names, prefix, name);
        defer allocator.free(rewritten);

        if (std.mem.eql(u8, rewritten, src)) continue;
        var f = try cwd.createFile(io, path, .{});
        defer f.close(io);
        try f.writeStreamingAll(io, rewritten);
    }
}
