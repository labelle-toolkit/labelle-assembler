//! TypeScript check + emit at generate (labelle-engine#745, the assembler
//! half; epic labelle-engine#237). Replaces the `.ts`-present hard-fail
//! gate (#586's placeholder, `rejectUntranspiledScripts`) with the real
//! path: a typescript project whose `ts/` holds `.ts` sources gets them
//! TYPE-CHECKED and EMITTED to plain-JS ES modules by the TypeScript 7
//! NATIVE compiler — one platform binary, no node/npm on the machine,
//! ever. Type errors fail generate with tsc's diagnostics relayed
//! verbatim (the ticket's acceptance).
//!
//! ── Toolchain (the binding #745 decision) ────────────────────────────
//! TypeScript 7.0 (GA 2026-07-08) ships the Go-native `tsc` as npm
//! platform packages — `@typescript/typescript-<os>-<arch>` — exactly
//! esbuild's distribution shape: a registry tarball whose `package/lib/`
//! holds the native binary (`tsc`, `tsc.exe` on windows) beside the
//! standard-library `lib.*.d.ts` files the binary resolves relative to
//! itself. esbuild is out (it strips types, never checks — it cannot
//! satisfy "type errors fail at generate"); TS 7 native does check+emit
//! in one binary fast enough to run per-generate.
//!
//! The pin is EXACT (`TSC_VERSION`) and per-platform, with the npm
//! registry `dist.integrity` sha512 pinned in source (`TSC_PLATFORMS`).
//! Fetching rides the same plain-HTTPS curl + system-tar mechanics every
//! other assembler fetch uses (`cache/fetch.zig`); the tarball is
//! integrity-verified BEFORE extraction. The extracted toolchain lands in
//! the SHARED tool cache — `~/.labelle/tools/typescript/<version>/
//! <platform>/` — not the per-project `.labelle/`: unlike the declare
//! runner (built from the project's pinned plugin package, hence
//! per-project), tsc is pinned by the ASSEMBLER, so one fetch serves
//! every project on the machine. Outside any wiped deps tree, like
//! `declare-tool/`. Because that cache is shared, cold fetches follow
//! the stage-and-atomic-rename discipline (download/verify/extract under
//! per-process unique paths, validate, then one atomic `rename` into
//! place; a lost race resolves in the winner's favor) — see
//! `ensureTscToolAt`/`promoteStagedTool`.
//!
//! ── The phase (embed splice, typescript row only) ────────────────────
//! Ordered after the declare phase (deps are staged, `{package}` paths
//! resolve; script-declared components — none for typescript today, the
//! declare phase is lua-only — are already threaded). Every path below is
//! rooted at THE SPLICE ROW'S script dir (`splice.dir` — `ts/` today; the
//! scripts/-convention migration changes the row, never this phase) and
//! keyed by the row's extensions — nothing here hardcodes a dir name.
//! The NEED PROBE runs first: a project whose script dir has no `.ts`
//! sources (`.d.ts` exempt — declaration files carry no runtime code)
//! skips the phase entirely — no toolchain fetch, no materialization,
//! byte-identical output to v0.85.0 (`.js`-only projects must not pay
//! for a ~9 MB compiler download they don't use).
//!
//! When `.ts` sources exist:
//!   1. `.ts`↔`.js` same-stem collisions fail generate (the emitted
//!      `enemy.js` would silently REPLACE a hand-authored `enemy.js`
//!      sibling).
//!   2. The target's script-dir link (the `linkAndScan` symlink) is
//!      MATERIALIZED into a real directory: the game's plain `.js`
//!      scripts are copied in (they keep working untranspiled alongside),
//!      and tsc emits beside them — so the generated main's
//!      `@embedFile("<dir>/<stem>.js")` resolves both kinds from one dir.
//!      The live-edit property of the symlink is deliberately traded
//!      away here: a `.ts` edit needs a re-generate to re-transpile
//!      anyway, so the whole dir goes stale-until-regenerate together.
//!   3. `labelle-components.d.ts` is generated next to the copied
//!      scripts from the component registry the assembler already scans
//!      (game `components/*.zig` fields + pack components + script-
//!      declared components — the manifest sidecar's `parseStructDir`
//!      machinery). See `renderComponentsDts` for the augmentation shape.
//!   4. A `tsconfig.json` is generated at the target root (`--strict`,
//!      ES2020 for quickjs-ng, `module esnext` + `moduleDetection force`
//!      to keep ES-module-per-script semantics — two scripts' top-level
//!      `const`s must not collide the way global-script files would).
//!      Its `files` lists the game's `.ts`/`.d.ts` sources, the plugin's
//!      shipped `contract/labelle.d.ts` (skipped when the game carries
//!      its own copy — two copies would duplicate every global), and the
//!      generated components d.ts, so `.ts` scripts typecheck against
//!      REAL component shapes: a typo'd field name fails generate.
//!   5. `tsc -p <tsconfig>` runs check+emit (`noEmitOnError`); a nonzero
//!      exit relays tsc's stdout/stderr verbatim and fails generate.
//!   6. The target's `ts/` is re-scanned for `.js` stems — the new
//!      script_names the registerScript builders embed.
//!
//! ── Bespoke phase, not `.stage = .generate` (decision) ───────────────
//! plugin_build_steps.zig documents a future `.stage = .generate` step
//! variant as the generic fold-in for generate-time tool execs. This
//! phase is deliberately NOT that: the toolchain here is ASSEMBLER-owned
//! (the version pin and integrity hashes must live in assembler source,
//! not in a plugin manifest a third party edits), the tool is FETCHED
//! per-platform rather than built from the plugin package, and the
//! phase's inputs/outputs (tsconfig codegen, d.ts codegen, script_names
//! rewrite) are splice-specific — a manifest schema would need
//! placeholder vocabulary for all of that with exactly one consumer,
//! against the documented "stay hardcoded until a second consumer
//! exists" rule (scripting_declare.zig's exec-slice doc). The fold-in
//! path, mirroring declare's: when a second fetched-tool generate-time
//! consumer lands, lift `ensureTscTool`'s fetch/verify/cache mechanics
//! into the step schema (pinned-hash tool artifacts + a `.stage =
//! .generate` exec) and reduce this module to the codegen halves.
//!
//! Hermetic-test seam: `tsc_tool_override` bypasses platform resolution
//! and the fetch entirely — the suite must never touch the network (the
//! declare phase's `declare_tool_override` precedent).

const std = @import("std");
const builtin = @import("builtin");
const cache = @import("cache.zig");
const config = @import("config.zig");
const scan = @import("codegen/scan.zig");
const idents = @import("codegen/idents.zig");
const manifest_parse = @import("manifest/parse.zig");
const scanner = @import("scanner.zig");
const scripting_declare = @import("scripting_declare.zig");
const scripting_splice = @import("scripting_splice.zig");

/// The exact TypeScript release the assembler fetches — 7.0.2, the GA
/// `latest` (2026-07). Bumping it means re-pinning every row in
/// `TSC_PLATFORMS` from the registry's `dist.integrity`.
pub const TSC_VERSION = "7.0.2";

/// The generated declarations file, written into the target's
/// materialized `ts/` next to the copied scripts. Named deliberately:
/// `labelle-components.d.ts` says what it holds and that labelle owns it.
pub const GENERATED_DTS_FILENAME = "labelle-components.d.ts";

/// The generated compiler config, written at the target root (beside
/// main.zig/build.zig) so an author can reproduce the exact check with
/// `<tool> -p <target>/tsconfig.json`.
pub const TSCONFIG_FILENAME = "tsconfig.json";

/// The shipped contract declarations inside the scripting plugin package
/// (labelle-scripting >= 0.3.0) — the global `labelle`/`Entity`/`game`
/// surface the generated d.ts merges into.
const CONTRACT_DTS_REL = "contract" ++ std.fs.path.sep_str ++ "labelle.d.ts";

/// The contract file's BASENAME: a copy of it inside the game's script
/// dir (the documented `// @ts-check` authoring workflow) supersedes the
/// package's — including both would redeclare every global.
const CONTRACT_DTS_BASENAME = "labelle.d.ts";

/// Test seam: absolute path of a prebuilt/fake tsc. When set, platform
/// resolution, the cache probe and the fetch are skipped entirely and
/// this binary is exec'd instead. Same scoped-threadlocal pattern as
/// `scripting_declare.declare_tool_override`.
pub threadlocal var tsc_tool_override: ?[]const u8 = null;

// ── Toolchain pin (npm registry platform packages) ───────────────────

/// One supported host platform: the zig os/arch pair, the npm platform-
/// package suffix (`@typescript/typescript-<npm_suffix>`), and the
/// registry tarball's `dist.integrity` sha512 (standard base64), pinned
/// from `registry.npmjs.org` at 7.0.2.
const TscPlatform = struct {
    os: std.Target.Os.Tag,
    arch: std.Target.Cpu.Arch,
    npm_suffix: []const u8,
    tarball_sha512_b64: []const u8,
};

/// The platforms the assembler runs generate on today (the desktop set —
/// matching the platform reach of the declare exec and the plugin build
/// steps). Adding a platform = one row + one registry hash.
pub const TSC_PLATFORMS = [_]TscPlatform{
    .{
        .os = .macos,
        .arch = .aarch64,
        .npm_suffix = "darwin-arm64",
        .tarball_sha512_b64 = "gowzar9MwS/aRWp6f3a4KUqzRjAZjOsmGNCM6LcTgXum+dBfgsBVMN+AgvOCCbguXyick6LJhpBszxMebJ8syA==",
    },
    .{
        .os = .macos,
        .arch = .x86_64,
        .npm_suffix = "darwin-x64",
        .tarball_sha512_b64 = "SZ9xZInqApNlNGc9s0W1VSsktYSOe9cFqNOIqmN1Gs8SmkjKZYFt017G4VwPxASInODuAdbTW7sXiFUf893RgA==",
    },
    .{
        .os = .linux,
        .arch = .x86_64,
        .npm_suffix = "linux-x64",
        .tarball_sha512_b64 = "EYdf2cNg7rgCWJnxCdJ+F3V39O8ihb37eHAu1LK8oAFizgTQbPOK7zHHXbPt8rX24COqODXeI3sIf0fCXG7H/A==",
    },
    .{
        .os = .linux,
        .arch = .aarch64,
        .npm_suffix = "linux-arm64",
        .tarball_sha512_b64 = "Qh4eU4/y3yDjnfjjyPYihMj5/ODIlmt+Bzu17OI+fiSRDW57QmU5SiN63exPRNJPKUzcc1INa1NXdrJ+MqHjUQ==",
    },
    .{
        .os = .windows,
        .arch = .x86_64,
        .npm_suffix = "win32-x64",
        .tarball_sha512_b64 = "0BQ3HkAHHlKLSp1qRvf3SUhGpGsDuhB/jgFw75guyqbxJqEaS0Cw/VFO8i2nHglJUzQCRtMMR/IBAKE3ETMC4g==",
    },
};

fn tscPlatformRow(os_tag: std.Target.Os.Tag, arch: std.Target.Cpu.Arch) ?TscPlatform {
    for (TSC_PLATFORMS) |row| {
        if (row.os == os_tag and row.arch == arch) return row;
    }
    return null;
}

/// The registry tarball URL for a platform row. Caller frees.
fn tscTarballUrl(allocator: std.mem.Allocator, row: TscPlatform) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "https://registry.npmjs.org/@typescript/typescript-{s}/-/typescript-{s}-{s}.tgz",
        .{ row.npm_suffix, row.npm_suffix, TSC_VERSION },
    );
}

/// The binary's package-relative path (the tarball's `package/` wrapper
/// is stripped at extraction, so this is also the tool-dir-relative path).
fn tscBinaryRelPath(os_tag: std.Target.Os.Tag) []const u8 {
    return if (os_tag == .windows) "lib" ++ std.fs.path.sep_str ++ "tsc.exe" else "lib" ++ std.fs.path.sep_str ++ "tsc";
}

// ── Diagnostics (the declare phase's stderr conventions) ─────────────

fn diag(comptime fmt: []const u8, args: anytype) void {
    const io = config.globalIo();
    var buf: [1024]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, "labelle-assembler: " ++ fmt ++ "\n", args) catch
        "labelle-assembler: typescript transpile: diagnostic too long\n";
    std.Io.File.stderr().writeStreamingAll(io, msg) catch {};
}

/// Relay a child process' output (tsc prints diagnostics to STDOUT, not
/// stderr) to our stderr verbatim — the file-line-and-code-bearing
/// `error TS2551: ...` lines ARE the acceptance-criterion UX.
fn relayChildOutput(text: []const u8) void {
    if (text.len == 0) return;
    const io = config.globalIo();
    std.Io.File.stderr().writeStreamingAll(io, text) catch {};
    if (text[text.len - 1] != '\n')
        std.Io.File.stderr().writeStreamingAll(io, "\n") catch {};
}

// ── Tool cache + fetch ───────────────────────────────────────────────

/// Verify `path`'s sha512 against a pinned standard-base64 digest (the
/// npm `dist.integrity` payload). Fails closed: a mismatched or
/// unreadable tarball never reaches extraction.
pub fn verifyTarballSha512(allocator: std.mem.Allocator, path: []const u8, expected_b64: []const u8) !void {
    const io = config.globalIo();
    const bytes = std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(256 * 1024 * 1024)) catch |err| {
        diag("could not read the downloaded typescript tarball {s}: {s}", .{ path, @errorName(err) });
        return error.TscToolFetchFailed;
    };
    defer allocator.free(bytes);

    var digest: [std.crypto.hash.sha2.Sha512.digest_length]u8 = undefined;
    std.crypto.hash.sha2.Sha512.hash(bytes, &digest, .{});
    var b64_buf: [std.base64.standard.Encoder.calcSize(digest.len)]u8 = undefined;
    const actual = std.base64.standard.Encoder.encode(&b64_buf, &digest);
    if (!std.mem.eql(u8, actual, expected_b64)) {
        diag(
            "typescript tarball integrity mismatch for {s}:\n  pinned sha512-{s}\n  got    sha512-{s}\n  (a corrupted download or a tampered registry response — nothing was extracted)",
            .{ path, expected_b64, actual },
        );
        return error.TscToolIntegrityMismatch;
    }
}

/// The tool dir for a platform row under `cache_root`:
/// `<cache_root>/tools/typescript/<version>/<npm_suffix>`. Caller frees.
fn tscToolDir(allocator: std.mem.Allocator, cache_root: []const u8, row: TscPlatform) ![]u8 {
    return std.fs.path.join(allocator, &.{ cache_root, "tools", "typescript", TSC_VERSION, row.npm_suffix });
}

/// Resolve (fetching if needed) the tsc binary for `row` under
/// `cache_root`. Split from `ensureTscTool` so tests can drive the cache
/// probe against a tmp root without touching `$HOME` or the network (a
/// pre-staged binary is a cache HIT — no fetch path runs).
///
/// ── Concurrency (the shared-cache discipline) ────────────────────────
/// The tool cache is SHARED across projects, so two `labelle generate`
/// processes can cold-fetch the same platform at once. Everything before
/// promotion is therefore PER-PROCESS (unique random suffix): the
/// download target, the integrity check (hashing a private file no other
/// process can overwrite mid-verify), and the extraction — into a
/// staging dir BESIDE the final one (same filesystem), so promotion is
/// one atomic `rename`. The staged tree is validated (binary present,
/// executable) BEFORE promotion; `promoteStagedTool` renames it into
/// place and resolves a lost race in the winner's favor. The presence
/// probe below is sound BECAUSE of that: the final dir only ever appears
/// complete-or-not-at-all, so "the binary exists" implies the whole
/// extracted tree does.
fn ensureTscToolAt(allocator: std.mem.Allocator, cache_root: []const u8, row: TscPlatform) ![]u8 {
    const io = config.globalIo();
    const cwd = std.Io.Dir.cwd();

    const tool_dir = try tscToolDir(allocator, cache_root, row);
    defer allocator.free(tool_dir);
    const bin_path = try std.fs.path.join(allocator, &.{ tool_dir, tscBinaryRelPath(row.os) });
    errdefer allocator.free(bin_path);
    if (cache.dirExists(bin_path)) return bin_path;

    const url = try tscTarballUrl(allocator, row);
    defer allocator.free(url);
    diag("fetching the typescript {s} native compiler ({s}) into {s} ...", .{ TSC_VERSION, row.npm_suffix, tool_dir });

    // Per-process unique suffix — concurrent cold fetches must never
    // share a download or staging path (random bytes, not a PID: unique
    // even across PID reuse and across threads of one process; the same
    // `io.random` idiom `std.testing.tmpDir` uses).
    var raw: [8]u8 = undefined;
    io.random(&raw);
    const unique = std.fmt.bytesToHex(raw, .lower);

    var slug_buf: [96]u8 = undefined;
    const slug = std.fmt.bufPrint(&slug_buf, "{s}-{s}-{s}", .{ TSC_VERSION, row.npm_suffix, unique }) catch
        return error.NameTooLong;
    const archive = try cache.getTempPath(allocator, "labelle-tsc", slug);
    defer allocator.free(archive);
    cache.downloadFile(allocator, url, archive) catch {
        diag("could not download the typescript compiler from {s} — check network access; the pin is typescript {s}", .{ url, TSC_VERSION });
        return error.TscToolFetchFailed;
    };
    defer cwd.deleteTree(io, archive) catch {};

    // Integrity gates extraction: nothing lands in the tool cache from a
    // tarball whose bytes don't match the source-pinned registry hash —
    // and the archive path is process-private, so the bytes hashed here
    // are exactly the bytes extracted below.
    try verifyTarballSha512(allocator, archive, row.tarball_sha512_b64);

    // Extract into the per-process STAGING dir, a sibling of the final
    // dir (same filesystem — the promotion rename is atomic; the `.`
    // prefix keeps it visually apart from real platform dirs).
    // `--strip-components=1` drops the npm `package/` wrapper, so
    // `lib/tsc` lands directly under it.
    var staging_name_buf: [64]u8 = undefined;
    const staging_name = std.fmt.bufPrint(&staging_name_buf, ".staging-{s}-{s}", .{ row.npm_suffix, unique }) catch
        return error.NameTooLong;
    const staging_dir = try std.fs.path.join(allocator, &.{ cache_root, "tools", "typescript", TSC_VERSION, staging_name });
    defer allocator.free(staging_dir);
    errdefer cwd.deleteTree(io, staging_dir) catch {};
    try cwd.createDirPath(io, staging_dir);
    cache.extractTarGz(allocator, archive, staging_dir) catch {
        diag("could not extract the typescript compiler tarball into {s}", .{staging_dir});
        return error.TscToolFetchFailed;
    };

    // Validate the staged tree BEFORE promotion — only complete trees
    // ever reach the final path.
    const staged_bin = try std.fs.path.join(allocator, &.{ staging_dir, tscBinaryRelPath(row.os) });
    defer allocator.free(staged_bin);
    if (!cache.dirExists(staged_bin)) {
        diag("the typescript tarball extracted but {s} is missing — the {s} package layout changed?", .{ staged_bin, row.npm_suffix });
        return error.TscToolFetchFailed;
    }
    // npm tarballs carry the executable bit and system tar preserves it;
    // belt-and-braces for exotic tar/umask setups (windows needs none).
    if (builtin.os.tag != .windows) ensureExecutable(staged_bin);

    try promoteStagedTool(staging_dir, tool_dir, bin_path);
    return bin_path;
}

/// Atomically promote a VALIDATED staging tree to the final tool dir.
/// Owns `staging_dir`: it is gone on every return — renamed into place
/// on success, discarded when the race was lost to a valid winner,
/// deleted on every failure path (errdefer).
///
/// Race resolution, in order:
///   1. `rename(staging, final)` — the atomic happy path (on POSIX this
///      also silently replaces an EMPTY leftover final dir).
///   2. rename failed and the final BINARY now exists → another process
///      won with a complete tree (its promotion was equally atomic):
///      keep the winner byte-for-byte, discard our staging.
///   3. rename failed, the final dir exists but has NO binary → an
///      invalid leftover (an interrupted install predating this staging
///      discipline, or outside interference): replace it DELIBERATELY —
///      delete + retry the rename ONCE, with a note. (Should another
///      process land between the delete and the retry, the retry fails
///      and propagates — corrupt-leftover recovery is best-effort by
///      design, never silent.)
///   4. anything else → propagate the original rename error.
fn promoteStagedTool(staging_dir: []const u8, tool_dir: []const u8, final_bin_path: []const u8) !void {
    const io = config.globalIo();
    const cwd = std.Io.Dir.cwd();
    errdefer cwd.deleteTree(io, staging_dir) catch {};

    cwd.rename(staging_dir, cwd, tool_dir, io) catch |rename_err| {
        if (cache.dirExists(final_bin_path)) {
            // Lost the race to a COMPLETE winner — use it.
            cwd.deleteTree(io, staging_dir) catch {};
            return;
        }
        if (cache.dirExists(tool_dir)) {
            diag("replacing an incomplete typescript tool dir at {s} (no compiler binary inside)", .{tool_dir});
            cwd.deleteTree(io, tool_dir) catch {};
            try cwd.rename(staging_dir, cwd, tool_dir, io);
            return;
        }
        return rename_err;
    };
}

fn ensureExecutable(path: []const u8) void {
    const io = config.globalIo();
    var file = std.Io.Dir.cwd().openFile(io, path, .{ .mode = .read_write }) catch return;
    defer file.close(io);
    file.setPermissions(io, .executable_file) catch {};
}

/// Resolve the tsc binary for THIS host: the override seam, else the
/// shared tool cache (fetch-on-miss). Returned path is allocator-owned
/// EXCEPT for the override (borrowed, caller must not free — mirrored by
/// `runPhase` handling both). Unsupported host platforms fail pointedly.
fn ensureTscTool(allocator: std.mem.Allocator) ![]const u8 {
    if (tsc_tool_override) |p| return p;

    const row = tscPlatformRow(builtin.os.tag, builtin.cpu.arch) orelse {
        diag(
            "no pinned typescript {s} native compiler for {s}-{s} (pinned platforms: darwin-arm64/x64, linux-x64/arm64, win32-x64) — author .js against contract/labelle.d.ts on this host, or add the platform row",
            .{ TSC_VERSION, @tagName(builtin.os.tag), @tagName(builtin.cpu.arch) },
        );
        return error.TscToolUnsupportedPlatform;
    };
    const cache_root = try cache.getCacheRoot(allocator);
    defer allocator.free(cache_root);
    return ensureTscToolAt(allocator, cache_root, row);
}

// ── The need probe (game-side ts/ walk) ──────────────────────────────

/// What the game's script dir holds, sorted rel paths (platform sep) —
/// arena-owned. `.d.ts` files are DECLARATIONS (typecheck inputs, no
/// runtime code): they never make the phase run by themselves and are
/// never copied (tsc reads them from the game side).
const TsSourceSet = struct {
    /// `.ts` sources needing transpile (`.d.ts` excluded).
    ts_files: []const []const u8,
    /// `.d.ts` declaration files (typecheck inputs).
    dts_files: []const []const u8,
    /// Plain `.js` scripts (copied into the materialized dir verbatim).
    js_files: []const []const u8,
    /// A game-side copy of the contract d.ts exists (any depth) — the
    /// package's copy is then omitted from the tsconfig.
    has_contract_copy: bool,
};

fn collectTsSources(
    aa: std.mem.Allocator,
    game_dir: []const u8,
    dir_name: []const u8,
    src: scripting_splice.TranspileSource,
    embed_ext: []const u8,
) !TsSourceSet {
    const io = config.globalIo();
    var set = TsSourceSet{
        .ts_files = &.{},
        .dts_files = &.{},
        .js_files = &.{},
        .has_contract_copy = false,
    };

    const dir_path = try std.fs.path.join(aa, &.{ game_dir, dir_name });
    var dir = std.Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound, error.NotDir => return set,
        else => return err,
    };
    defer dir.close(io);

    var ts_list: std.ArrayList([]const u8) = .empty;
    var dts_list: std.ArrayList([]const u8) = .empty;
    var js_list: std.ArrayList([]const u8) = .empty;
    try walkTsSources(aa, io, dir, "", src, embed_ext, &ts_list, &dts_list, &js_list, &set.has_contract_copy);

    for ([_]*std.ArrayList([]const u8){ &ts_list, &dts_list, &js_list }) |list| {
        std.mem.sort([]const u8, list.items, {}, struct {
            fn lessThan(_: void, a: []const u8, b: []const u8) bool {
                return std.mem.order(u8, a, b) == .lt;
            }
        }.lessThan);
    }
    set.ts_files = try ts_list.toOwnedSlice(aa);
    set.dts_files = try dts_list.toOwnedSlice(aa);
    set.js_files = try js_list.toOwnedSlice(aa);
    return set;
}

fn walkTsSources(
    aa: std.mem.Allocator,
    io: std.Io,
    dir: std.Io.Dir,
    rel_prefix: []const u8,
    src: scripting_splice.TranspileSource,
    embed_ext: []const u8,
    ts_list: *std.ArrayList([]const u8),
    dts_list: *std.ArrayList([]const u8),
    js_list: *std.ArrayList([]const u8),
    has_contract_copy: *bool,
) !void {
    var iter = dir.iterate();
    while (try iter.next(io)) |entry| {
        if (entry.name.len == 0 or entry.name[0] == '.') continue;
        switch (entry.kind) {
            .directory => {
                var sub = dir.openDir(io, entry.name, .{ .iterate = true }) catch continue;
                defer sub.close(io);
                const sub_prefix = if (rel_prefix.len == 0)
                    try aa.dupe(u8, entry.name)
                else
                    try std.fs.path.join(aa, &.{ rel_prefix, entry.name });
                try walkTsSources(aa, io, sub, sub_prefix, src, embed_ext, ts_list, dts_list, js_list, has_contract_copy);
            },
            else => {
                const rel = if (rel_prefix.len == 0)
                    try aa.dupe(u8, entry.name)
                else
                    try std.fs.path.join(aa, &.{ rel_prefix, entry.name });
                if (std.mem.endsWith(u8, entry.name, src.declaration_suffix)) {
                    if (std.mem.eql(u8, entry.name, CONTRACT_DTS_BASENAME)) has_contract_copy.* = true;
                    try dts_list.append(aa, rel);
                } else if (std.mem.endsWith(u8, entry.name, src.source_extension)) {
                    try ts_list.append(aa, rel);
                } else if (std.mem.endsWith(u8, entry.name, embed_ext)) {
                    try js_list.append(aa, rel);
                }
            },
        }
    }
}

/// Fail generate on a source whose emitted twin would land on a
/// hand-authored sibling of the same stem — the emit would silently
/// replace the plain script in the materialized dir.
fn rejectStemCollisions(
    set: TsSourceSet,
    dir_name: []const u8,
    src: scripting_splice.TranspileSource,
    embed_ext: []const u8,
) !void {
    var any = false;
    for (set.ts_files) |ts_rel| {
        const stem = ts_rel[0 .. ts_rel.len - src.source_extension.len];
        for (set.js_files) |js_rel| {
            if (!std.mem.eql(u8, js_rel[0 .. js_rel.len - embed_ext.len], stem)) continue;
            if (!any) {
                std.debug.print(
                    "labelle-assembler: {s}/ authors the same script as both {s} and {s} — the transpiled output would silently replace the plain script:\n",
                    .{ dir_name, src.source_extension, embed_ext },
                );
                any = true;
            }
            std.debug.print("  {s}{c}{s}  vs  {s}{c}{s}\n", .{ dir_name, std.fs.path.sep, ts_rel, dir_name, std.fs.path.sep, js_rel });
        }
    }
    if (any) {
        std.debug.print("  keep exactly one source per script (delete the stale twin).\n", .{});
        return error.ScriptTranspileCollision;
    }
}

// ── Zig field type → TypeScript type mapping ─────────────────────────

/// A mapped field type: the TS type text plus whether the Zig side was
/// optional (`?T` → `T | null`; serde encodes null optionals as null).
pub const TsType = struct {
    ts: []const u8,
    nullable: bool,
};

/// The verbatim-Zig-type → TypeScript mapping (labelle-engine#745):
///   f32/f64                    → number
///   iN/uN (N <= 32)            → number
///   i64/u64 (+ isize/usize)    → bigint   — entity IDS: Number would
///                                           silently round past 2^53,
///                                           the contract's BigInt rule
///   bool                       → boolean
///   []const u8                 → string
///   Vec2 (incl. `<mod>.Vec2`)  → { x: number; y: number }
///   anything else              → unknown  — never lie about a shape we
///                                           can't map; authors narrow
/// Optionals unwrap recursively into `.nullable` (an unknown base stays
/// plain `unknown` — `unknown | null` collapses to `unknown` anyway).
pub fn tsFieldType(zig_type: []const u8) TsType {
    var t = std.mem.trim(u8, zig_type, " \t\r\n");
    var nullable = false;
    if (t.len > 0 and t[0] == '?') {
        nullable = true;
        t = std.mem.trim(u8, t[1..], " \t\r\n");
    }
    const ts: []const u8 = blk: {
        const numbers = [_][]const u8{ "f32", "f64", "i8", "i16", "i32", "u8", "u16", "u32" };
        for (numbers) |n| {
            if (std.mem.eql(u8, t, n)) break :blk "number";
        }
        const bigints = [_][]const u8{ "i64", "u64", "isize", "usize" };
        for (bigints) |n| {
            if (std.mem.eql(u8, t, n)) break :blk "bigint";
        }
        if (std.mem.eql(u8, t, "bool")) break :blk "boolean";
        if (std.mem.eql(u8, t, "[]const u8")) break :blk "string";
        if (std.mem.eql(u8, t, "Vec2") or std.mem.endsWith(u8, t, ".Vec2")) break :blk "{ x: number; y: number }";
        break :blk "unknown";
    };
    if (std.mem.eql(u8, ts, "unknown")) return .{ .ts = ts, .nullable = false };
    return .{ .ts = ts, .nullable = nullable };
}

/// The declared-component twin: schema `Default` tags map through the
/// SAME vocabulary codegen writes (`zigFieldTypeName`), so the d.ts can
/// never drift from `scripting_components.zig`.
fn tsDeclaredFieldType(default: scripting_declare.Default) TsType {
    return tsFieldType(scripting_declare.zigFieldTypeName(default));
}

// ── d.ts assembly + rendering ────────────────────────────────────────

pub const DtsField = struct {
    name: []const u8,
    type: TsType,
};

/// One registry-named component in the generated map — `key` is the
/// REGISTRY name scenes/scripts address it by (`Velocity`,
/// `citizens__Counter`, a declared `Hunger`).
pub const DtsComponent = struct {
    key: []const u8,
    fields: []const DtsField,
};

/// Assemble the d.ts component list from the same three providers the
/// component registry emits (and the manifest sidecar lists): game
/// `components/*.zig` (AST-parsed fields), script-declared components
/// (typed schema), pack components (parsed from the STAGED copies under
/// `<target>/<import_prefix>/`, keyed `<pfx>__<Pascal>` — the invisible
/// namespace codegen registers). Arena-owned.
fn collectDtsComponents(
    aa: std.mem.Allocator,
    game_dir: []const u8,
    target_dir: []const u8,
    component_names: []const []const u8,
    declared_components: []const scripting_declare.DeclaredComponent,
    pack_scans: []const scan.PackScan,
) ![]const DtsComponent {
    var list: std.ArrayList(DtsComponent) = .empty;

    const game_decls = try manifest_parse.parseStructDir(aa, game_dir, "components", component_names);
    for (game_decls) |decl| {
        try list.append(aa, .{ .key = decl.name, .fields = try mapParsedFields(aa, decl.fields) });
    }

    for (declared_components) |dc| {
        const fields = try aa.alloc(DtsField, dc.fields.len);
        for (dc.fields, fields) |df, *out| out.* = .{ .name = df.name, .type = tsDeclaredFieldType(df.default) };
        try list.append(aa, .{ .key = dc.name, .fields = fields });
    }

    for (pack_scans) |pack| {
        const pack_root = try std.fs.path.join(aa, &.{ target_dir, pack.import_prefix });
        const pack_decls = try manifest_parse.parseStructDir(aa, pack_root, "components", pack.component_names);
        var prefix_buf: [128]u8 = undefined;
        const prefix = scan.packNamespacePrefix(pack.name, &prefix_buf);
        for (pack_decls) |decl| {
            const key = try std.fmt.allocPrint(aa, "{s}__{s}", .{ prefix, decl.name });
            try list.append(aa, .{ .key = key, .fields = try mapParsedFields(aa, decl.fields) });
        }
    }

    return list.toOwnedSlice(aa);
}

fn mapParsedFields(aa: std.mem.Allocator, fields: []const manifest_parse.Field) ![]const DtsField {
    const out = try aa.alloc(DtsField, fields.len);
    for (fields, out) |f, *o| o.* = .{ .name = f.name, .type = tsFieldType(f.zig_type) };
    return out;
}

/// Render the generated `labelle-components.d.ts`.
///
/// The augmentation shape (verified against the real labelle-scripting
/// v0.8.0 `contract/labelle.d.ts` + tsc 7.0.2): the contract is a GLOBAL
/// declaration file (`declare class Entity`, `declare const game`), so
/// this file composes by global DECLARATION MERGING —
///
///   * `interface LabelleComponents` is the name-keyed map (keys quoted:
///     pack-namespaced `citizens__Counter` and any future spelling stay
///     legal), one `{ field: type }` shape per registry name;
///   * `interface Entity` merges into the contract's `declare class
///     Entity`, adding `keyof LabelleComponents`-constrained overloads of
///     `get`/`get-into`/`set` — merged-interface members win overload
///     resolution for literal names, so `e.get("Hunger")` types as the
///     REAL shape and a typo'd field is a TS2551 at generate. Names
///     outside the map still hit the contract's base `Payload` overloads
///     (dynamic component use keeps working).
///
/// No bare per-component global interfaces: `interface Position {...}`
/// would silently MERGE with same-named lib globals (es2020's `Math`,
/// dom's `Position`) — the quoted map cannot collide with anything.
pub fn renderComponentsDts(components: []const DtsComponent, w: anytype) !void {
    try w.writeAll(
        \\// labelle-components.d.ts — GENERATED by labelle-assembler from the
        \\// project's component registry (components/*.zig fields, pack
        \\// components, script-declared components). Do not edit; regenerate.
        \\//
        \\// Composes with the scripting plugin's contract/labelle.d.ts by
        \\// global declaration merging: `interface Entity` below merges into
        \\// the contract's `declare class Entity`, so `e.get("<Name>")` and
        \\// `e.set("<Name>", {...})` type against the real field shapes.
        \\
        \\interface LabelleComponents {
        \\
    );
    for (components) |comp| {
        try w.print("  \"{s}\": {{", .{comp.key});
        if (comp.fields.len == 0) {
            try w.writeAll("};\n");
            continue;
        }
        try w.writeAll(" ");
        for (comp.fields, 0..) |field, i| {
            if (i > 0) try w.writeAll("; ");
            try w.print("{s}: {s}", .{ field.name, field.type.ts });
            if (field.type.nullable) try w.writeAll(" | null");
        }
        try w.writeAll(" };\n");
    }
    try w.writeAll(
        \\}
        \\
        \\interface Entity {
        \\  get<K extends keyof LabelleComponents>(name: K): LabelleComponents[K] | null;
        \\  get<K extends keyof LabelleComponents>(name: K, into: LabelleComponents[K]): LabelleComponents[K] | null;
        \\  set<K extends keyof LabelleComponents>(name: K, obj?: Partial<LabelleComponents[K]> | null): boolean;
        \\}
        \\
    );
}

// ── tsconfig rendering ───────────────────────────────────────────────

/// Write one JSON string of a filesystem path, separators normalized to
/// `/` (valid for tsc on every OS; keeps windows `\` out of JSON
/// escaping) — paths never carry quotes/control chars, so char-level
/// normalization is the whole escape.
fn writeJsonPath(w: anytype, path: []const u8) !void {
    try w.writeAll("\"");
    for (path) |ch| {
        if (ch == '\\') {
            try w.writeAll("/");
        } else {
            try w.writeAll(&[_]u8{ch});
        }
    }
    try w.writeAll("\"");
}

/// Render the generated tsconfig. The `--strict`-honoring defaults this
/// module defines (all empirically verified against tsc 7.0.2):
///
///   * `target es2020` — quickjs-ng's level (BigInt literals included);
///   * `module esnext` + `moduleDetection force` — every file is an ES
///     module regardless of imports/exports, matching the runtime's
///     module-per-script isolation (two scripts' top-level `const`s must
///     not collide the way tsc's default "global script file" rule would
///     make them);
///   * `lib [es2020]` — no DOM: the VM has none, and a DOM lib would
///     also re-introduce global names (`Position`) for shapes to collide
///     with;
///   * `types []` — no @types auto-inclusion (there is no node_modules);
///   * `noEmitOnError` — type errors emit NOTHING and fail generate;
///   * explicit `rootDir`/`outDir` — emitted `.js` mirrors the game's
///     `ts/` layout into the target's materialized `ts/`. Declaration
///     inputs OUTSIDE rootDir are fine (they never emit).
///
/// `files` is explicit (no `include` globbing): the phase already walked
/// the sources, and an explicit sorted list keeps the config auditable
/// and byte-deterministic. Paths are absolute, `/`-normalized.
pub fn renderTsconfig(
    w: anytype,
    root_dir: []const u8,
    out_dir: []const u8,
    files: []const []const u8,
) !void {
    try w.writeAll(
        \\{
        \\  "compilerOptions": {
        \\    "strict": true,
        \\    "target": "es2020",
        \\    "module": "esnext",
        \\    "lib": ["es2020"],
        \\    "moduleDetection": "force",
        \\    "types": [],
        \\    "noEmitOnError": true,
        \\
    );
    try w.writeAll("    \"rootDir\": ");
    try writeJsonPath(w, root_dir);
    try w.writeAll(",\n    \"outDir\": ");
    try writeJsonPath(w, out_dir);
    try w.writeAll("\n  },\n  \"files\": [\n");
    for (files, 0..) |file, i| {
        try w.writeAll("    ");
        try writeJsonPath(w, file);
        if (i + 1 < files.len) try w.writeAll(",");
        try w.writeAll("\n");
    }
    try w.writeAll("  ]\n}\n");
}

// ── Phase orchestration (called from root.zig's generate) ────────────

pub const PhaseOptions = struct {
    plugins: []const config.PluginDep,
    plugin_name: []const u8,
    language: []const u8,
    /// The splice ROW's script dir (`ts` today; the scripts/-convention
    /// migration re-points the row and this phase follows) and embed
    /// extension (`.js`). Never hardcoded here — always the row's.
    dir: []const u8,
    extension: []const u8,
    game_dir: []const u8,
    output_dir: []const u8,
    target_dir: []const u8,
    project_dir: []const u8,
    /// Game-root component stems (d.ts providers).
    component_names: []const []const u8,
    /// Pack scans (d.ts providers, `<pack>__<Pascal>` keys).
    pack_scans: []const scan.PackScan,
    /// Script-declared components (empty for typescript today — the
    /// declare phase is lua-only — but wired so a ts-capable declare
    /// runner feeds the same map).
    declared_components: []const scripting_declare.DeclaredComponent = &.{},
};

/// Run the transpile phase for an active embed splice. Returns the NEW
/// sorted script stems (owned by `allocator`, the `linkAndScan` contract
/// — the caller swaps them onto the splice) when the phase transpiled,
/// null for every skip shape:
///
///   * the splice language has no transpile row (lua, ruby — and native
///     rows never reach here);
///   * the game's script dir holds no `.ts` sources (`.d.ts` exempt) —
///     THE need probe, checked before any tool resolution so `.js`-only
///     projects never fetch the toolchain (and the target keeps the
///     plain `linkAndScan` symlink layout, byte-identical to v0.85.0).
///
/// Skip shapes also delete a stale generated `<target>/tsconfig.json`
/// from a previously-transpiling project state (the materialized `ts/`
/// dir itself was already reconciled back to a symlink by this
/// generate's `linkAndScan`, which also removed the stale generated
/// d.ts inside it).
pub fn runPhase(allocator: std.mem.Allocator, opts: PhaseOptions) !?[][]const u8 {
    const src = scripting_splice.transpileSource(opts.language) orelse return null;

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    const sources = try collectTsSources(aa, opts.game_dir, opts.dir, src, opts.extension);
    if (sources.ts_files.len == 0) {
        removeStaleTsconfig(aa, opts.target_dir);
        return null;
    }
    try rejectStemCollisions(sources, opts.dir, src, opts.extension);

    // Tool AFTER the probe (the no-fetch guarantee) and BEFORE any target
    // mutation — an unsupported platform / failed fetch leaves the
    // symlink layout untouched.
    const tool_path = try ensureTscTool(allocator);
    defer if (tsc_tool_override == null) allocator.free(tool_path);

    // The shipped contract d.ts from the staged plugin package — unless
    // the game carries its own copy (the documented @ts-check workflow),
    // which is already a walk-collected input; both would redeclare
    // every global.
    var contract_path: ?[]const u8 = null;
    if (!sources.has_contract_copy) {
        const pkg_dir = try scripting_declare.resolvePluginPackageDir(
            aa,
            opts.plugins,
            opts.plugin_name,
            opts.output_dir,
            opts.project_dir,
        );
        const candidate = try std.fs.path.join(aa, &.{ pkg_dir, CONTRACT_DTS_REL });
        if (cache.dirExists(candidate)) {
            contract_path = candidate;
        } else {
            diag(
                "the pinned scripting plugin ships no contract/labelle.d.ts — .ts scripts typecheck without the labelle globals (pin labelle-scripting >= 0.3.0, or copy a labelle.d.ts into {s}/)",
                .{opts.dir},
            );
        }
    }

    // Materialize the target's script dir as a REAL directory (replacing
    // the linkAndScan symlink — CLI-managed, same posture as linkDirAbs's
    // reconcile) holding the copied plain .js scripts; tsc emits beside
    // them below.
    const io = config.globalIo();
    const cwd = std.Io.Dir.cwd();
    const game_script_dir = try std.fs.path.join(aa, &.{ opts.game_dir, opts.dir });
    const target_script_dir = try std.fs.path.join(aa, &.{ opts.target_dir, opts.dir });
    try cwd.deleteTree(io, target_script_dir);
    try cwd.createDirPath(io, target_script_dir);
    for (sources.js_files) |rel| {
        const from = try std.fs.path.join(aa, &.{ game_script_dir, rel });
        const to = try std.fs.path.join(aa, &.{ target_script_dir, rel });
        if (std.fs.path.dirname(to)) |parent| try cwd.createDirPath(io, parent);
        const bytes = try cwd.readFileAlloc(io, from, aa, .limited(16 * 1024 * 1024));
        var f = try cwd.createFile(io, to, .{});
        defer f.close(io);
        try f.writeStreamingAll(io, bytes);
    }

    // The generated declarations, next to the copied scripts.
    {
        const components = try collectDtsComponents(
            aa,
            opts.game_dir,
            opts.target_dir,
            opts.component_names,
            opts.declared_components,
            opts.pack_scans,
        );
        var rendered: std.Io.Writer.Allocating = .init(aa);
        try renderComponentsDts(components, &rendered.writer);
        try scanner.writeFile(target_script_dir, GENERATED_DTS_FILENAME, rendered.writer.buffered());
    }

    // The generated tsconfig at the target root. Absolute paths: the
    // config must mean the same thing regardless of the invoking cwd.
    const tsconfig_path = try std.fs.path.join(aa, &.{ opts.target_dir, TSCONFIG_FILENAME });
    {
        const game_script_abs = try cwd.realPathFileAlloc(io, game_script_dir, aa);
        const target_script_abs = try cwd.realPathFileAlloc(io, target_script_dir, aa);

        var files: std.ArrayList([]const u8) = .empty;
        for (sources.ts_files) |rel| {
            try files.append(aa, try std.fs.path.join(aa, &.{ game_script_abs, rel }));
        }
        for (sources.dts_files) |rel| {
            try files.append(aa, try std.fs.path.join(aa, &.{ game_script_abs, rel }));
        }
        if (contract_path) |p| {
            try files.append(aa, try cwd.realPathFileAlloc(io, p, aa));
        }
        try files.append(aa, try std.fs.path.join(aa, &.{ target_script_abs, GENERATED_DTS_FILENAME }));

        var rendered: std.Io.Writer.Allocating = .init(aa);
        try renderTsconfig(&rendered.writer, game_script_abs, target_script_abs, files.items);
        try scanner.writeFile(opts.target_dir, TSCONFIG_FILENAME, rendered.writer.buffered());
    }

    // Check + emit. tsc prints diagnostics to STDOUT; relay both streams
    // verbatim — the `file(line,col): error TSxxxx:` lines are the fix.
    const result = std.process.run(allocator, io, .{
        .argv = &.{ tool_path, "-p", tsconfig_path },
    }) catch |err| {
        diag("could not run the typescript compiler {s}: {s}", .{ tool_path, @errorName(err) });
        return error.ScriptTypecheckFailed;
    };
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    switch (result.term) {
        .exited => |code| if (code != 0) {
            relayChildOutput(result.stdout);
            relayChildOutput(result.stderr);
            diag("typescript check failed (tsc exit {d}) — fix the errors above; nothing was emitted", .{code});
            return error.ScriptTypecheckFailed;
        },
        else => {
            relayChildOutput(result.stdout);
            relayChildOutput(result.stderr);
            diag("the typescript compiler terminated abnormally", .{});
            return error.ScriptTypecheckFailed;
        },
    }

    // The embeddable set is now the MATERIALIZED dir's: copied plain .js
    // + tsc-emitted .js, one sorted scan (the linkAndScan stem contract).
    return try scanner.scanDirAbs(allocator, target_script_dir, opts.extension);
}

/// Best-effort cleanup of a stale generated tsconfig (a project whose
/// `.ts` sources were all removed): nothing invokes it anymore, but a
/// lingering generated file misleads readers of the target dir.
fn removeStaleTsconfig(allocator: std.mem.Allocator, target_dir: []const u8) void {
    const io = config.globalIo();
    const path = std.fs.path.join(allocator, &.{ target_dir, TSCONFIG_FILENAME }) catch return;
    std.Io.Dir.cwd().deleteFile(io, path) catch {};
}

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;

test "TSC_PLATFORMS: the pinned 7.0.2 rows — five platforms, esbuild-shaped npm suffixes, distinct hashes" {
    try testing.expectEqualStrings("7.0.2", TSC_VERSION);
    try testing.expectEqual(@as(usize, 5), TSC_PLATFORMS.len);
    // Row lookup by host tuple.
    try testing.expectEqualStrings("darwin-arm64", tscPlatformRow(.macos, .aarch64).?.npm_suffix);
    try testing.expectEqualStrings("darwin-x64", tscPlatformRow(.macos, .x86_64).?.npm_suffix);
    try testing.expectEqualStrings("linux-x64", tscPlatformRow(.linux, .x86_64).?.npm_suffix);
    try testing.expectEqualStrings("linux-arm64", tscPlatformRow(.linux, .aarch64).?.npm_suffix);
    try testing.expectEqualStrings("win32-x64", tscPlatformRow(.windows, .x86_64).?.npm_suffix);
    // Unsupported hosts resolve to null (the pointed-error path).
    try testing.expect(tscPlatformRow(.windows, .aarch64) == null);
    try testing.expect(tscPlatformRow(.freebsd, .x86_64) == null);
    // Every pinned hash is a well-formed standard-base64 sha512 (88 chars,
    // "==" padded) and no two rows share one.
    for (TSC_PLATFORMS, 0..) |row, i| {
        try testing.expectEqual(@as(usize, 88), row.tarball_sha512_b64.len);
        try testing.expect(std.mem.endsWith(u8, row.tarball_sha512_b64, "=="));
        for (TSC_PLATFORMS[0..i]) |prev| {
            try testing.expect(!std.mem.eql(u8, prev.tarball_sha512_b64, row.tarball_sha512_b64));
        }
    }
}

test "tscTarballUrl: the registry URL golden (darwin-arm64) — plain HTTPS, no npm client" {
    const url = try tscTarballUrl(testing.allocator, tscPlatformRow(.macos, .aarch64).?);
    defer testing.allocator.free(url);
    try testing.expectEqualStrings(
        "https://registry.npmjs.org/@typescript/typescript-darwin-arm64/-/typescript-darwin-arm64-7.0.2.tgz",
        url,
    );
}

test "tscBinaryRelPath: lib/tsc everywhere, lib/tsc.exe on windows (the npm package layout)" {
    try testing.expect(std.mem.endsWith(u8, tscBinaryRelPath(.macos), "tsc"));
    try testing.expect(std.mem.endsWith(u8, tscBinaryRelPath(.linux), "tsc"));
    try testing.expect(std.mem.endsWith(u8, tscBinaryRelPath(.windows), "tsc.exe"));
    try testing.expect(std.mem.startsWith(u8, tscBinaryRelPath(.macos), "lib"));
}

test "verifyTarballSha512: matches the pinned digest, rejects tampered bytes" {
    const tio = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    {
        var f = try tmp.dir.createFile(tio, "blob.tgz", .{});
        defer f.close(tio);
        try f.writeStreamingAll(tio, "labelle tsc fixture bytes\n");
    }
    const path = try tmp.dir.realPathFileAlloc(tio, "blob.tgz", testing.allocator);
    defer testing.allocator.free(path);

    // Pin computed from the fixture bytes themselves.
    var digest: [std.crypto.hash.sha2.Sha512.digest_length]u8 = undefined;
    std.crypto.hash.sha2.Sha512.hash("labelle tsc fixture bytes\n", &digest, .{});
    var b64_buf: [std.base64.standard.Encoder.calcSize(digest.len)]u8 = undefined;
    const good = std.base64.standard.Encoder.encode(&b64_buf, &digest);

    try verifyTarballSha512(testing.allocator, path, good);
    try testing.expectError(
        error.TscToolIntegrityMismatch,
        verifyTarballSha512(testing.allocator, path, TSC_PLATFORMS[0].tarball_sha512_b64),
    );
}

test "ensureTscToolAt: a pre-staged binary is a cache HIT — returned without any fetch machinery" {
    // The hermetic half of the fetch path: the probe precedes the
    // download, so a populated tool cache never touches the network. (The
    // fetch itself is exercised manually — see the module doc; the suite
    // must never depend on registry.npmjs.org.)
    const tio = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const row = tscPlatformRow(.macos, .aarch64).?;
    try tmp.dir.createDirPath(tio, "cache-root/tools/typescript/" ++ TSC_VERSION ++ "/darwin-arm64/lib");
    {
        var f = try tmp.dir.createFile(tio, "cache-root/tools/typescript/" ++ TSC_VERSION ++ "/darwin-arm64/lib/tsc", .{ .permissions = .executable_file });
        defer f.close(tio);
        try f.writeStreamingAll(tio, "#!/bin/sh\nexit 0\n");
    }
    const cache_root = try tmp.dir.realPathFileAlloc(tio, "cache-root", testing.allocator);
    defer testing.allocator.free(cache_root);

    const bin = try ensureTscToolAt(testing.allocator, cache_root, row);
    defer testing.allocator.free(bin);
    try testing.expect(std.fs.path.isAbsolute(bin));
    try testing.expect(std.mem.startsWith(u8, bin, cache_root));
    try testing.expect(std.mem.endsWith(u8, bin, "tsc"));
    try testing.expect(std.mem.indexOf(u8, bin, "typescript") != null);
    try testing.expect(std.mem.indexOf(u8, bin, TSC_VERSION) != null);
}

/// Promotion-fixture paths: a validated staging tree + the final tool
/// dir/bin paths, all under one tmp "version dir" (the real layout's
/// `tools/typescript/<ver>/`). Caller frees via the arena.
const PromoteFixture = struct {
    staging_dir: []const u8,
    tool_dir: []const u8,
    bin_path: []const u8,

    fn init(aa: std.mem.Allocator, tmp: *std.testing.TmpDir, staged_bin_content: []const u8) !PromoteFixture {
        try writeTestFile(tmp.dir, "ver/.staging-darwin-arm64-cafe0123/lib/tsc", staged_bin_content);
        try writeTestFile(tmp.dir, "ver/.staging-darwin-arm64-cafe0123/lib/lib.es2020.d.ts", "// stdlib\n");
        const ver_dir = try tmp.dir.realPathFileAlloc(testing.io, "ver", aa);
        const staging_dir = try std.fs.path.join(aa, &.{ ver_dir, ".staging-darwin-arm64-cafe0123" });
        const tool_dir = try std.fs.path.join(aa, &.{ ver_dir, "darwin-arm64" });
        const bin_path = try std.fs.path.join(aa, &.{ tool_dir, "lib", "tsc" });
        return .{ .staging_dir = staging_dir, .tool_dir = tool_dir, .bin_path = bin_path };
    }
};

test "promoteStagedTool: clean promotion — staging renamed into place atomically, no staging residue" {
    const tio = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const fx = try PromoteFixture.init(arena.allocator(), &tmp, "#!/bin/sh\n# ours\n");
    try promoteStagedTool(fx.staging_dir, fx.tool_dir, fx.bin_path);

    // The final tree is the staged one — binary AND stdlib beside it —
    // and the staging dir is gone (renamed, not copied).
    const got = try tmp.dir.readFileAlloc(tio, "ver/darwin-arm64/lib/tsc", testing.allocator, .limited(4096));
    defer testing.allocator.free(got);
    try testing.expect(std.mem.indexOf(u8, got, "# ours") != null);
    try tmp.dir.access(tio, "ver/darwin-arm64/lib/lib.es2020.d.ts", .{});
    try testing.expectError(
        error.FileNotFound,
        tmp.dir.access(tio, "ver/.staging-darwin-arm64-cafe0123", .{}),
    );
}

test "promoteStagedTool: a lost race keeps the WINNER byte-for-byte and discards the staging" {
    // THE race pin (CodeRabbit finding on PR #613): two processes
    // cold-fetch concurrently; the loser's promotion must NOT disturb
    // the winner's complete tree. The pre-fix in-place discipline
    // (deleteTree final + extract into it) fails exactly this assertion
    // — the winner's dir would be destroyed and rebuilt by the loser
    // (negative-verified by simulating that discipline; see the fix PR).
    const tio = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const fx = try PromoteFixture.init(arena.allocator(), &tmp, "#!/bin/sh\n# loser\n");
    // The winner landed first: a COMPLETE tool dir (binary present).
    try writeTestFile(tmp.dir, "ver/darwin-arm64/lib/tsc", "#!/bin/sh\n# winner\n");
    try writeTestFile(tmp.dir, "ver/darwin-arm64/lib/lib.es2020.d.ts", "// winner stdlib\n");

    try promoteStagedTool(fx.staging_dir, fx.tool_dir, fx.bin_path);

    const got = try tmp.dir.readFileAlloc(tio, "ver/darwin-arm64/lib/tsc", testing.allocator, .limited(4096));
    defer testing.allocator.free(got);
    try testing.expect(std.mem.indexOf(u8, got, "# winner") != null);
    try testing.expect(std.mem.indexOf(u8, got, "# loser") == null);
    // Our staging was discarded, not left to rot in the shared cache.
    try testing.expectError(
        error.FileNotFound,
        tmp.dir.access(tio, "ver/.staging-darwin-arm64-cafe0123", .{}),
    );
}

test "promoteStagedTool: an invalid pre-existing final dir (no binary) is replaced deliberately" {
    // The corrupt-leftover shape: a NON-EMPTY final dir without the
    // compiler binary (an install interrupted before this staging
    // discipline existed). The probe rejects it (no bin), promotion
    // rename fails (dir not empty) — the fix replaces it with the
    // validated staging, with a note.
    const tio = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const fx = try PromoteFixture.init(arena.allocator(), &tmp, "#!/bin/sh\n# ours\n");
    // Partial junk: stdlib extracted, binary missing (tar interrupted).
    try writeTestFile(tmp.dir, "ver/darwin-arm64/lib/lib.es2020.d.ts", "// truncated install\n");

    try promoteStagedTool(fx.staging_dir, fx.tool_dir, fx.bin_path);

    const got = try tmp.dir.readFileAlloc(tio, "ver/darwin-arm64/lib/tsc", testing.allocator, .limited(4096));
    defer testing.allocator.free(got);
    try testing.expect(std.mem.indexOf(u8, got, "# ours") != null);
    // The junk tree is gone wholesale (deleted, then replaced by rename).
    const junk = tmp.dir.readFileAlloc(tio, "ver/darwin-arm64/lib/lib.es2020.d.ts", testing.allocator, .limited(4096)) catch null;
    if (junk) |j| {
        defer testing.allocator.free(j);
        try testing.expect(std.mem.indexOf(u8, j, "truncated install") == null);
    }
    try testing.expectError(
        error.FileNotFound,
        tmp.dir.access(tio, "ver/.staging-darwin-arm64-cafe0123", .{}),
    );
}

test "promoteStagedTool: an unresolvable rename failure propagates AND cleans the staging (errdefer)" {
    // No winner, no invalid leftover — the final path's PARENT doesn't
    // even exist, so the rename fails outright. The error must propagate
    // (never a silent half-install) and the staging must not linger in
    // the shared cache.
    const tio = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    const fx = try PromoteFixture.init(aa, &tmp, "#!/bin/sh\n# ours\n");
    const bad_tool_dir = try std.fs.path.join(aa, &.{ fx.tool_dir, "..", "..", "no-such-parent", "darwin-arm64" });
    const bad_bin = try std.fs.path.join(aa, &.{ bad_tool_dir, "lib", "tsc" });

    try testing.expectError(
        error.FileNotFound,
        promoteStagedTool(fx.staging_dir, bad_tool_dir, bad_bin),
    );
    try testing.expectError(
        error.FileNotFound,
        tmp.dir.access(tio, "ver/.staging-darwin-arm64-cafe0123", .{}),
    );
}

test "tsFieldType: the zig→ts mapping table — numbers, bigint ids, bool, string, vec2, optionals, unknown" {
    // f32/f64 and every <=32-bit integer → number.
    for ([_][]const u8{ "f32", "f64", "i8", "i16", "i32", "u8", "u16", "u32" }) |t| {
        const m = tsFieldType(t);
        try testing.expectEqualStrings("number", m.ts);
        try testing.expect(!m.nullable);
    }
    // 64-bit integers are IDS: bigint (Number rounds past 2^53).
    for ([_][]const u8{ "i64", "u64", "usize", "isize" }) |t| {
        try testing.expectEqualStrings("bigint", tsFieldType(t).ts);
    }
    try testing.expectEqualStrings("boolean", tsFieldType("bool").ts);
    try testing.expectEqualStrings("string", tsFieldType("[]const u8").ts);
    // vec2: bare and module-qualified spellings.
    try testing.expectEqualStrings("{ x: number; y: number }", tsFieldType("Vec2").ts);
    try testing.expectEqualStrings("{ x: number; y: number }", tsFieldType("zig_utils.Vec2").ts);
    try testing.expectEqualStrings("{ x: number; y: number }", tsFieldType("@import(\"zig-utils\").Vec2").ts);
    // Optionals unwrap to `| null`.
    const opt = tsFieldType("?u64");
    try testing.expectEqualStrings("bigint", opt.ts);
    try testing.expect(opt.nullable);
    // Unmappable types NEVER lie: unknown, and `?Unmapped` collapses
    // (unknown | null is just unknown).
    try testing.expectEqualStrings("unknown", tsFieldType("SomeEnum").ts);
    try testing.expectEqualStrings("unknown", tsFieldType("[4]f32").ts);
    const opt_unknown = tsFieldType("?SomeEnum");
    try testing.expectEqualStrings("unknown", opt_unknown.ts);
    try testing.expect(!opt_unknown.nullable);
    // A name merely ENDING in Vec2 without the dot is not vec2.
    try testing.expectEqualStrings("unknown", tsFieldType("MyVec2").ts);
}

fn renderDtsForTest(components: []const DtsComponent) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    errdefer aw.deinit();
    try renderComponentsDts(components, &aw.writer);
    var arr = aw.toArrayList();
    errdefer arr.deinit(testing.allocator);
    return arr.toOwnedSlice(testing.allocator);
}

test "renderComponentsDts: golden — quoted map keys, bigint/vec2/null mappings, the Entity merge block" {
    const components = [_]DtsComponent{
        .{ .key = "Hunger", .fields = &.{
            .{ .name = "level", .type = .{ .ts = "number", .nullable = false } },
            .{ .name = "starving", .type = .{ .ts = "boolean", .nullable = false } },
        } },
        .{ .key = "Ship", .fields = &.{
            .{ .name = "owner", .type = .{ .ts = "bigint", .nullable = false } },
            .{ .name = "target", .type = .{ .ts = "bigint", .nullable = true } },
            .{ .name = "pos", .type = .{ .ts = "{ x: number; y: number }", .nullable = false } },
            .{ .name = "label", .type = .{ .ts = "string", .nullable = false } },
        } },
        .{ .key = "citizens__Counter", .fields = &.{
            .{ .name = "count", .type = .{ .ts = "number", .nullable = false } },
        } },
        .{ .key = "Marker", .fields = &.{} },
    };
    const got = try renderDtsForTest(&components);
    defer testing.allocator.free(got);

    try testing.expect(std.mem.indexOf(u8, got, "interface LabelleComponents {\n") != null);
    try testing.expect(std.mem.indexOf(u8, got, "  \"Hunger\": { level: number; starving: boolean };\n") != null);
    // The bigint id + optional-as-null + vec2 shape pins.
    try testing.expect(std.mem.indexOf(u8, got, "  \"Ship\": { owner: bigint; target: bigint | null; pos: { x: number; y: number }; label: string };\n") != null);
    // Pack-namespaced keys stay legal because keys are QUOTED.
    try testing.expect(std.mem.indexOf(u8, got, "  \"citizens__Counter\": { count: number };\n") != null);
    // Field-less marker.
    try testing.expect(std.mem.indexOf(u8, got, "  \"Marker\": {};\n") != null);
    // The class-merge augmentation (the shipped contract's declare class
    // Entity): typed get / get-into / set overloads.
    try testing.expect(std.mem.indexOf(u8, got, "interface Entity {\n") != null);
    try testing.expect(std.mem.indexOf(u8, got, "  get<K extends keyof LabelleComponents>(name: K): LabelleComponents[K] | null;\n") != null);
    try testing.expect(std.mem.indexOf(u8, got, "  get<K extends keyof LabelleComponents>(name: K, into: LabelleComponents[K]): LabelleComponents[K] | null;\n") != null);
    try testing.expect(std.mem.indexOf(u8, got, "  set<K extends keyof LabelleComponents>(name: K, obj?: Partial<LabelleComponents[K]> | null): boolean;\n") != null);
    // No bare global per-component interfaces (lib-global merge hazard).
    try testing.expect(std.mem.indexOf(u8, got, "interface Hunger") == null);
}

test "renderComponentsDts: an empty registry still renders the (never-keyed) map + merge block" {
    const got = try renderDtsForTest(&.{});
    defer testing.allocator.free(got);
    try testing.expect(std.mem.indexOf(u8, got, "interface LabelleComponents {\n}") != null);
    try testing.expect(std.mem.indexOf(u8, got, "interface Entity {") != null);
}

test "renderTsconfig: golden — strict es2020/esnext defaults, explicit files, parseable JSON, /-normalized paths" {
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    const files = [_][]const u8{
        "/abs/game/ts/behavior.ts",
        "/abs/game/ts/labelle.d.ts",
        "/abs/out/target/ts/labelle-components.d.ts",
    };
    try renderTsconfig(&aw.writer, "/abs/game/ts", "/abs/out/target/ts", &files);
    const got = aw.writer.buffered();

    // Strict JSON (std.json is stricter than tsc's JSONC — the golden
    // guarantees any JSON consumer can read the generated config).
    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, got, .{});
    defer parsed.deinit();
    const opts = parsed.value.object.get("compilerOptions").?.object;
    try testing.expect(opts.get("strict").?.bool);
    try testing.expectEqualStrings("es2020", opts.get("target").?.string);
    try testing.expectEqualStrings("esnext", opts.get("module").?.string);
    try testing.expectEqualStrings("es2020", opts.get("lib").?.array.items[0].string);
    try testing.expectEqualStrings("force", opts.get("moduleDetection").?.string);
    try testing.expectEqual(@as(usize, 0), opts.get("types").?.array.items.len);
    try testing.expect(opts.get("noEmitOnError").?.bool);
    try testing.expectEqualStrings("/abs/game/ts", opts.get("rootDir").?.string);
    try testing.expectEqualStrings("/abs/out/target/ts", opts.get("outDir").?.string);
    const file_arr = parsed.value.object.get("files").?.array;
    try testing.expectEqual(@as(usize, 3), file_arr.items.len);
    try testing.expectEqualStrings("/abs/game/ts/behavior.ts", file_arr.items[0].string);

    // Windows separators normalize to `/` inside the JSON strings.
    var aw2: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw2.deinit();
    try renderTsconfig(&aw2.writer, "C:\\game\\ts", "C:\\out\\ts", &.{"C:\\game\\ts\\a.ts"});
    try testing.expect(std.mem.indexOf(u8, aw2.writer.buffered(), "C:/game/ts/a.ts") != null);
    try testing.expect(std.mem.indexOf(u8, aw2.writer.buffered(), "\\") == null);
}

fn writeTestFile(dir: std.Io.Dir, rel: []const u8, body: []const u8) !void {
    const tio = testing.io;
    if (std.fs.path.dirname(rel)) |sub| try dir.createDirPath(tio, sub);
    var f = try dir.createFile(tio, rel, .{});
    defer f.close(tio);
    try f.writeStreamingAll(tio, body);
}

test "collectTsSources: classifies .ts/.d.ts/.js (nested, dot-entries skipped) and spots the contract copy" {
    const tio = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    try writeTestFile(tmp.dir, "ts/behavior.js", "export function update(dt) {}\n");
    try writeTestFile(tmp.dir, "ts/enemy.ts", "export function update(dt: number) {}\n");
    try writeTestFile(tmp.dir, "ts/ai/guard.ts", "export function update(dt: number) {}\n");
    try writeTestFile(tmp.dir, "ts/labelle.d.ts", "declare const labelle: any;\n");
    try writeTestFile(tmp.dir, "ts/globals.d.ts", "declare const DEBUG: boolean;\n");
    try writeTestFile(tmp.dir, "ts/.hidden.ts", "ignored\n");
    try writeTestFile(tmp.dir, "ts/notes.md", "not a source\n");
    const root = try tmp.dir.realPathFileAlloc(tio, ".", aa);

    const src = scripting_splice.transpileSource("typescript").?;
    const set = try collectTsSources(aa, root, "ts", src, ".js");
    try testing.expectEqual(@as(usize, 2), set.ts_files.len);
    // Sorted; nested rel paths use the platform separator.
    try testing.expect(std.mem.indexOf(u8, set.ts_files[0], "guard.ts") != null);
    try testing.expectEqualStrings("enemy.ts", set.ts_files[1]);
    try testing.expectEqual(@as(usize, 2), set.dts_files.len);
    try testing.expectEqual(@as(usize, 1), set.js_files.len);
    try testing.expectEqualStrings("behavior.js", set.js_files[0]);
    try testing.expect(set.has_contract_copy);

    // A missing dir is an empty set (splice-active, script-less project).
    const empty = try collectTsSources(aa, root, "nope", src, ".js");
    try testing.expectEqual(@as(usize, 0), empty.ts_files.len);
    try testing.expect(!empty.has_contract_copy);
}

test "rejectStemCollisions: a same-stem .ts/.js pair fails; distinct stems and nested-vs-top pass" {
    const src = scripting_splice.transpileSource("typescript").?;

    // Same stem, same subdir → collision.
    const colliding = TsSourceSet{
        .ts_files = &.{"enemy.ts"},
        .dts_files = &.{},
        .js_files = &.{ "behavior.js", "enemy.js" },
        .has_contract_copy = false,
    };
    try testing.expectError(error.ScriptTranspileCollision, rejectStemCollisions(colliding, "ts", src, ".js"));

    // Distinct stems — and the SAME stem in DIFFERENT subdirs is legal
    // (the emitted ai/enemy.js does not land on enemy.js).
    const clean = TsSourceSet{
        .ts_files = &.{ "ai" ++ std.fs.path.sep_str ++ "enemy.ts", "boss.ts" },
        .dts_files = &.{},
        .js_files = &.{ "behavior.js", "enemy.js" },
        .has_contract_copy = false,
    };
    try rejectStemCollisions(clean, "ts", src, ".js");
}

test "collectDtsComponents: game components/*.zig fields + declared schema + pack <pfx>__ keys, one map" {
    const tio = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    // Game provider: components/ship.zig (fields AST-parsed).
    try writeTestFile(tmp.dir, "game/components/ship.zig",
        \\pub const Ship = struct {
        \\    owner: u64 = 0,
        \\    hp: f32 = 100,
        \\};
    );
    // Pack provider: the STAGED copy under <target>/<import_prefix>/.
    try writeTestFile(tmp.dir, "target/packs/citizens/components/counter.zig",
        \\pub const Counter = struct {
        \\    count: u32 = 0,
        \\};
    );
    const game = try tmp.dir.realPathFileAlloc(tio, "game", aa);
    const target = try tmp.dir.realPathFileAlloc(tio, "target", aa);

    // Declared provider: the typed schema (what a declare runner feeds).
    var schema = try scripting_declare.parseSchema(testing.allocator,
        \\{"components":[{"name":"Hunger","fields":[{"name":"level","type":"f32","default":1.0}]}]}
    );
    defer schema.deinit();

    const pack = scan.PackScan{
        .name = "citizens",
        .import_prefix = "packs/citizens",
        .component_names = &.{"counter"},
        .event_names = &.{},
        .prefab_names = &.{},
    };
    const components = try collectDtsComponents(
        aa,
        game,
        target,
        &.{"ship"},
        schema.components,
        &.{pack},
    );
    try testing.expectEqual(@as(usize, 3), components.len);
    // Game realm: file-stem Pascal registry name, real field mapping.
    try testing.expectEqualStrings("Ship", components[0].key);
    try testing.expectEqualStrings("owner", components[0].fields[0].name);
    try testing.expectEqualStrings("bigint", components[0].fields[0].type.ts);
    try testing.expectEqualStrings("number", components[0].fields[1].type.ts);
    // Declared realm: schema-typed via the SAME zigFieldTypeName codegen
    // vocabulary (no drift from scripting_components.zig).
    try testing.expectEqualStrings("Hunger", components[1].key);
    try testing.expectEqualStrings("number", components[1].fields[0].type.ts);
    // Pack realm: the invisible `<pfx>__<Pascal>` registry key.
    try testing.expectEqualStrings("citizens__Counter", components[2].key);
    try testing.expectEqualStrings("number", components[2].fields[0].type.ts);
}

test "runPhase: a language without a transpile row returns null before any probe (lua)" {
    const opts = PhaseOptions{
        .plugins = &.{},
        .plugin_name = "scripting",
        .language = "lua",
        .dir = "lua",
        .extension = ".lua",
        .game_dir = "/nonexistent",
        .output_dir = "/nonexistent",
        .target_dir = "/nonexistent",
        .project_dir = "/nonexistent",
        .component_names = &.{},
        .pack_scans = &.{},
    };
    try testing.expect((try runPhase(testing.allocator, opts)) == null);
}

test "runPhase: no .ts sources → null BEFORE tool resolution (the no-fetch pin), stale tsconfig dropped" {
    // The override is a POISON path: if the phase consulted the tool
    // before/despite the probe, exec'ing it would fail loudly — instead
    // the probe returns null first, proving .js-only projects never
    // reach tool resolution (and therefore never fetch).
    const tio = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeTestFile(tmp.dir, "game/ts/behavior.js", "export function update(dt) {}\n");
    try writeTestFile(tmp.dir, "game/ts/labelle.d.ts", "declare const labelle: any;\n");
    try writeTestFile(tmp.dir, "target/" ++ TSCONFIG_FILENAME, "{ \"stale\": true }\n");
    const game = try tmp.dir.realPathFileAlloc(tio, "game", testing.allocator);
    defer testing.allocator.free(game);
    const target = try tmp.dir.realPathFileAlloc(tio, "target", testing.allocator);
    defer testing.allocator.free(target);

    tsc_tool_override = "/definitely/not/a/real/tsc";
    defer tsc_tool_override = null;

    const opts = PhaseOptions{
        .plugins = &.{},
        .plugin_name = "scripting",
        .language = "typescript",
        .dir = "ts",
        .extension = ".js",
        .game_dir = game,
        .output_dir = target,
        .target_dir = target,
        .project_dir = game,
        .component_names = &.{},
        .pack_scans = &.{},
    };
    try testing.expect((try runPhase(testing.allocator, opts)) == null);
    // The stale generated tsconfig from a previously-transpiling state
    // was cleaned, so the target matches a never-transpiling project.
    try testing.expectError(error.FileNotFound, tmp.dir.access(tio, "target/" ++ TSCONFIG_FILENAME, .{}));
}

test "runPhase: a .ts/.js stem collision fails BEFORE tool resolution (poison override untouched)" {
    const tio = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeTestFile(tmp.dir, "game/ts/enemy.ts", "export function update(dt: number) {}\n");
    try writeTestFile(tmp.dir, "game/ts/enemy.js", "export function update(dt) {}\n");
    const game = try tmp.dir.realPathFileAlloc(tio, "game", testing.allocator);
    defer testing.allocator.free(game);

    tsc_tool_override = "/definitely/not/a/real/tsc";
    defer tsc_tool_override = null;

    const opts = PhaseOptions{
        .plugins = &.{},
        .plugin_name = "scripting",
        .language = "typescript",
        .dir = "ts",
        .extension = ".js",
        .game_dir = game,
        .output_dir = game,
        .target_dir = game,
        .project_dir = game,
        .component_names = &.{},
        .pack_scans = &.{},
    };
    try testing.expectError(error.ScriptTranspileCollision, runPhase(testing.allocator, opts));
}
