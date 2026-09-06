//! Cache-management subcommands for the labelle-assembler binary.
//!
//! Issue #217, phase 1 — the `labelle` CLI used to carry compiled-in copies
//! of this logic (it imported the assembler's `generator` module and called
//! `cache.fetchPlugin` / `cache.validateCache` / `cache.populate*` in
//! process). The assembler owns `cache.zig`, so it now also owns the
//! *commands* that drive it: `install`, `clean`, `upgrade`. The CLI shells
//! out to `labelle-assembler <subcommand>` instead.
//!
//! Each handler mirrors `main.zig:cmdGenerate` — it parses its own args,
//! prints diagnostics to stderr/stdout, and exits non-zero on failure so
//! the CLI can propagate the exit code.
//!
//! Not handled here: the `assembler` binary itself. `install assembler
//! <version>` and `upgrade assembler` download/pin the assembler *binary*,
//! which is a chicken-and-egg problem (the assembler can't fetch itself).
//! That stays in the CLI bootstrap. These handlers reject an `assembler`
//! package argument with a clear message.

const std = @import("std");
const gen = @import("root.zig");
const cache = @import("cache.zig");
const config = @import("config.zig");

/// Write directly to stderr without a level prefix. Matches main.zig.
fn writeStderr(io: std.Io, msg: []const u8) void {
    std.Io.File.stderr().writeStreamingAll(io, msg) catch {};
}

// ── install ──────────────────────────────────────────────────────────

const install_usage =
    \\labelle-assembler install — fetch packages into the local cache
    \\
    \\Usage:
    \\  labelle-assembler install --project-root <path>   Install deps for a project
    \\  labelle-assembler install <pkg> <version>         Cache a specific package
    \\  labelle-assembler install <pkg> local:<path>      Build <pkg> from a local checkout
    \\  labelle-assembler install <version>               Cache core+engine+gfx at a version
    \\
    \\Packages: core, engine, gfx
    \\
    \\`local:<path>` installs an EXPLICIT local-source override (#685, #704):
    \\the checkout is linked into ~/.labelle/packages/local/<pkg>, and every
    \\later build — by any assembler, released or not — resolves <pkg> there
    \\instead of its pinned release, warning each time. A relative path
    \\resolves against --project-root when given, else the working directory.
    \\Run `labelle-assembler clean` to drop the override.
    \\
;

/// `install` subcommand. Four forms:
///   install --project-root <p>    → ensure every dep in project.labelle is cached
///   install <pkg> <version>       → cache one framework package
///   install <pkg> local:<path>    → build one framework package from a checkout
///   install <version>             → cache core/engine/gfx at one version
pub fn cmdInstall(allocator: std.mem.Allocator, io: std.Io, args: *std.process.Args.Iterator) !void {
    var project_root: ?[]const u8 = null;
    var positionals: std.ArrayList([]const u8) = .empty;
    defer positionals.deinit(allocator);

    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--project-root")) {
            project_root = args.next() orelse {
                std.log.err("labelle-assembler install: --project-root requires a value", .{});
                std.process.exit(2);
            };
        } else if (std.mem.startsWith(u8, arg, "--project-root=")) {
            project_root = arg["--project-root=".len..];
        } else if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            writeStderr(io, install_usage);
            return;
        } else if (std.mem.startsWith(u8, arg, "-")) {
            std.log.err("labelle-assembler install: unknown flag '{s}'", .{arg});
            std.process.exit(2);
        } else {
            try positionals.append(allocator, arg);
        }
    }

    // Form 1: install deps for a project.
    if (positionals.items.len == 0) {
        const root = project_root orelse {
            writeStderr(io, install_usage);
            std.process.exit(2);
        };
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const cfg = readProjectConfig(arena.allocator(), io, root) catch |err| {
            // Name the error: `error.ParseZon` (a bad/unknown key, detailed
            // by the diagnostic `parseTyped` logs just above) reads nothing
            // like `error.FileNotFound`, and the bare message used to make
            // the two indistinguishable.
            std.log.err(
                "labelle-assembler install: failed to read project.labelle in '{s}': {s}",
                .{ root, @errorName(err) },
            );
            std.process.exit(1);
        };
        ensureCache(allocator, cfg) catch |err| {
            std.log.err("labelle-assembler install: {s}", .{@errorName(err)});
            std.process.exit(1);
        };
        std.log.info("labelle-assembler: all packages cached", .{});
        return;
    }

    // Every remaining form takes a VERSION positional that is joined into a
    // cache path — and, since the #685 migration, one that may be DELETED.
    // A value like `../../x` would escape the package namespace entirely, so
    // require a single, ordinary path component (#688 review round 5).
    //
    // A `local:<path>` spec is exempt: it is a SOURCE path, not a version,
    // and it never names a cache path — the slot it populates is
    // `packages/local/<pkg>`, named by the package. Running it through the
    // component rule rejected every absolute path, which on Windows is
    // every path a user would type (#704).
    for (positionals.items) |arg| {
        if (config.isLocalVersion(arg)) continue;
        if (isSafePathComponent(arg)) continue;
        std.log.err(
            "labelle-assembler install: '{s}' is not a valid package or version name " ++
                "(no absolute paths, no '.' or '..' components)",
            .{arg},
        );
        std.process.exit(2);
    }

    // Reject the `assembler` package — the CLI owns binary bootstrap.
    if (std.mem.eql(u8, positionals.items[0], "assembler")) {
        std.log.err("labelle-assembler install: the 'assembler' package is managed by the labelle CLI bootstrap, not the assembler binary", .{});
        std.process.exit(2);
    }

    // Form 3: install <version> — cache core/engine/gfx at one version.
    if (positionals.items.len == 1) {
        const version = positionals.items[0];
        // One checkout cannot be core AND engine AND gfx, so there is no
        // sensible reading of `install local:<path>` — and the silent one
        // (treat the spec as a git ref and go looking for a tarball named
        // after it) is how #704 repro B ended up 404ing against GitHub.
        if (config.isLocalVersion(version)) {
            std.log.err(
                "labelle-assembler install: a local source belongs to ONE package — " ++
                    "write 'install <pkg> {s}' (pkg: core, engine, gfx)",
                .{version},
            );
            std.process.exit(2);
        }
        std.log.info("labelle-assembler: caching core/engine/gfx at version {s}", .{version});
        const packages = [_][]const u8{ "core", "engine", "gfx" };
        for (packages) |pkg| {
            purgeLegacyFrameworkSlot(allocator, pkg, version) catch |err| {
                std.log.err("labelle-assembler install: could not repair the cache slot for {s} {s}: {s}", .{ pkg, version, @errorName(err) });
                std.process.exit(1);
            };
            // The VERSION-named slot, not the build resolver (#704 review):
            // this form is asked to put a release on disk, and an active
            // local override made the resolver answer yes for every
            // version, so nothing was fetched.
            if (!try cache.isFrameworkVersionCached(allocator, pkg, version)) {
                fetchFrameworkWithFallback(allocator, pkg, version) catch |err| {
                    std.log.err("labelle-assembler install: failed to fetch {s} {s}: {s}", .{ pkg, version, @errorName(err) });
                    std.process.exit(1);
                };
            } else {
                std.log.info("  {s} {s} already cached", .{ pkg, version });
            }
        }
        std.log.info("labelle-assembler: done", .{});
        return;
    }

    // Form 2: install <pkg> <version>. Reject any trailing positionals —
    // silently ignoring them hides typos like `install gfx 1.0 1.1`.
    if (positionals.items.len > 2) {
        std.log.err("labelle-assembler install: too many arguments — expected 'install <pkg> <version>'", .{});
        writeStderr(io, "\n" ++ install_usage);
        std.process.exit(2);
    }
    const pkg_name = positionals.items[0];
    const version = positionals.items[1];
    if (!std.mem.eql(u8, pkg_name, "core") and
        !std.mem.eql(u8, pkg_name, "engine") and
        !std.mem.eql(u8, pkg_name, "gfx"))
    {
        std.log.err("labelle-assembler install: unknown package '{s}' (known: core, engine, gfx)", .{pkg_name});
        std.process.exit(2);
    }

    // Form 2b: install <pkg> local:<path> — an explicit local-source
    // override (#704). Handled before the version path because none of it
    // applies: nothing is fetched, no version-named slot is involved, and
    // auto-discovery must NOT get a vote (that is the whole defect — the
    // sibling checkout next to the running binary used to win over the path
    // the user typed).
    if (config.isLocalVersion(version)) {
        installLocalFramework(allocator, pkg_name, version, project_root) catch |err| {
            std.log.err(
                "labelle-assembler install: could not install {s} from '{s}': {s}",
                .{ pkg_name, config.localVersionPath(version), @errorName(err) },
            );
            std.process.exit(1);
        };
        std.log.info("labelle-assembler: done", .{});
        return;
    }

    std.log.info("labelle-assembler: fetching {s} {s}", .{ pkg_name, version });
    purgeLegacyFrameworkSlot(allocator, pkg_name, version) catch |err| {
        std.log.err("labelle-assembler install: could not repair the cache slot for {s} {s}: {s}", .{ pkg_name, version, @errorName(err) });
        std.process.exit(1);
    };
    fetchFrameworkWithFallback(allocator, pkg_name, version) catch |err| {
        std.log.err("labelle-assembler install: failed to fetch {s}: {s}", .{ pkg_name, @errorName(err) });
        std.process.exit(1);
    };
    std.log.info("labelle-assembler: done", .{});
}

/// `install <pkg> local:<path>` — link a checkout into the reserved local
/// slot and record it as an EXPLICIT override (#704).
///
/// Three things distinguish this from the auto-discovery in
/// `fetchFrameworkWithFallback`, and each is one of the defects #704
/// reported:
///
///   * the path the user typed is the source. Auto-discovery is not
///     consulted, so a sibling checkout next to the running binary — quite
///     possibly months stale — cannot take its place;
///   * `pinned` records the version the checkout DECLARES rather than the
///     `local:` spec, so the marker answers "which framework version is
///     this, really" instead of restating the argument; and
///   * the slot is marked `.explicit`, which is what lets the released
///     `~/.labelle/bin/labelle-assembler` resolve through it. A discovered
///     slot still activates only inside its own monorepo.
fn installLocalFramework(
    allocator: std.mem.Allocator,
    package: []const u8,
    spec: []const u8,
    project_root: ?[]const u8,
) !void {
    // The canonical `local:` resolver, so a path typed here means exactly
    // what the same path means in project.labelle: absolute as written,
    // relative against --project-root (anchored at the main checkout when
    // it escapes a worktree), else against the working directory.
    const source = try cache.resolveFrameworkPackage(allocator, package, spec, project_root);
    defer allocator.free(source);

    // isDirectory, not dirExists: the latter only calls `access`, so a
    // regular file passed and was then linked into the cache as though it
    // were a checkout, failing far downstream (#704 review).
    if (!cache.isDirectory(source)) {
        std.log.err(
            "labelle-assembler install: not a directory: '{s}' — " ++
                "`local:` takes the path of a {s} checkout",
            .{ source, cache.localSlots.frameworkDirName(package) },
        );
        return error.LocalSourceNotFound;
    }

    return populateExplicitLocal(allocator, package, source);
}

/// Honour an explicit `install <pkg> local:<path>` override for `package`,
/// returning whether one is registered (in which case the caller must not
/// fetch anything for this package).
///
/// Refreshing matters because of the Windows copy fallback. `symlinkToCache`
/// links the checkout into the slot where it can — and a link needs nothing
/// further, it tracks the source by construction — but `std.Io.Dir.symLink`
/// needs SeCreateSymbolicLinkPrivilege on Windows, which an ordinary account
/// does not hold, so the slot ends up a COPY. A copy is a snapshot: without
/// this, the override would serve install-day sources forever while the user
/// edited the checkout and wondered why nothing changed — the same class of
/// baffling staleness #704 was filed about. Re-copying on every install is
/// the price of the platform not linking.
fn refreshExplicitLocalSlot(allocator: std.mem.Allocator, package: []const u8) !bool {
    const source = try cache.localSlots.explicitFrameworkSource(allocator, package) orelse return false;
    defer allocator.free(source);

    const slot = try cache.localSlots.frameworkSlot(allocator, package);
    defer allocator.free(slot);
    if (cache.localSlots.slotTracksSource(slot)) return true;

    try populateExplicitLocal(allocator, package, source);
    return true;
}

/// Link (or, where the platform won't, copy) `source` into `package`'s
/// reserved local slot and mark it an explicit override.
///
/// `pinned` records the version the checkout DECLARES, not the `local:` spec
/// the user typed (#704 expectation C): the marker exists to answer "which
/// framework version is this, really", and restating the argument answered
/// nothing.
fn populateExplicitLocal(allocator: std.mem.Allocator, package: []const u8, source: []const u8) !void {
    const declared = cache.declaredZonVersion(allocator, source);
    defer if (declared) |d| allocator.free(d);
    const pinned = declared orelse "unknown";

    std.log.warn(
        "  {s}: LOCAL sources from '{s}' (declares {s}) will be built instead of any pinned release — " ++
            "run 'labelle-assembler clean' to drop the override (#685)",
        .{ package, source, pinned },
    );
    try cache.populateFrameworkPackage(allocator, package, pinned, source, .explicit);
}

// ── clean ────────────────────────────────────────────────────────────

const clean_usage =
    \\labelle-assembler clean — prune unused cached package versions
    \\
    \\Usage:
    \\  labelle-assembler clean [--dry-run] [--project-root <path>]
    \\
    \\Keeps the versions referenced by project.labelle (if found) plus the
    \\assembler's built-in default versions; removes everything else under
    \\~/.labelle/packages/ (core, engine, gfx, cli, and assembler namespaces).
    \\
;

/// `clean` subcommand. Removes cached package versions that are neither
/// the assembler's built-in defaults nor referenced by project.labelle.
pub fn cmdClean(allocator: std.mem.Allocator, io: std.Io, args: *std.process.Args.Iterator) !void {
    var dry_run = false;
    var project_root: []const u8 = ".";

    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--dry-run")) {
            dry_run = true;
        } else if (std.mem.eql(u8, arg, "--project-root")) {
            project_root = args.next() orelse {
                std.log.err("labelle-assembler clean: --project-root requires a value", .{});
                std.process.exit(2);
            };
        } else if (std.mem.startsWith(u8, arg, "--project-root=")) {
            project_root = arg["--project-root=".len..];
        } else if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            writeStderr(io, clean_usage);
            return;
        } else {
            std.log.err("labelle-assembler clean: unknown option '{s}'", .{arg});
            writeStderr(io, "\n" ++ clean_usage);
            std.process.exit(2);
        }
    }

    const packages_dir = cache.getPackagesDir(allocator) catch {
        std.log.err("labelle-assembler clean: could not determine packages directory", .{});
        std.process.exit(1);
    };
    defer allocator.free(packages_dir);

    std.log.info("labelle-assembler: scanning {s}", .{packages_dir});

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_alloc = arena.allocator();

    var kept = std.StringHashMap(std.StringHashMap(void)).init(arena_alloc);

    // The `assembler` namespace (~/.labelle/packages/assembler/<version>/)
    // is pruned alongside the framework packages. Its built-in default is
    // this binary's own version.
    const pkg_names = [_][]const u8{ "core", "engine", "gfx", "cli", "assembler" };
    const default_versions = [_][]const u8{
        gen.CORE_VERSION, gen.ENGINE_VERSION, gen.GFX_VERSION, gen.CLI_VERSION, gen.ASSEMBLER_VERSION,
    };
    for (pkg_names, 0..) |name, i| {
        var version_set = std.StringHashMap(void).init(arena_alloc);
        try version_set.put(default_versions[i], {});
        try kept.put(name, version_set);
    }

    if (readProjectConfigQuiet(arena_alloc, io, project_root)) |cfg| {
        const project_refs = [_]struct { name: []const u8, version: []const u8 }{
            .{ .name = "core", .version = cfg.core_version },
            .{ .name = "engine", .version = cfg.engine_version },
            .{ .name = "gfx", .version = cfg.gfx_version },
            .{ .name = "cli", .version = cfg.labelle_version },
            // assembler_version is optional in project.labelle; it falls
            // back to labelle_version, matching ensureCache's resolution.
            .{ .name = "assembler", .version = cfg.assembler_version orelse cfg.labelle_version },
        };
        for (project_refs) |ref| {
            if (config.isLocalVersion(ref.version)) continue;
            if (kept.getPtr(ref.name)) |set| try set.put(ref.version, {});
        }
        std.log.info("  found project.labelle in '{s}'", .{project_root});
    } else |_| {
        std.log.info("  no project.labelle found — keeping default versions only", .{});
    }

    var removed_count: u32 = 0;
    for (pkg_names) |pkg_name| {
        const pkg_dir_path = std.fs.path.join(arena_alloc, &.{ packages_dir, pkg_name }) catch continue;

        var pkg_dir = std.Io.Dir.cwd().openDir(io, pkg_dir_path, .{ .iterate = true }) catch continue;
        defer pkg_dir.close(io);

        const version_set = kept.get(pkg_name) orelse continue;

        var it = pkg_dir.iterate();
        while (it.next(io) catch null) |entry| {
            if (entry.kind != .directory and entry.kind != .sym_link) continue;
            if (version_set.contains(entry.name)) continue;

            if (dry_run) {
                std.log.info("  would remove {s}/{s}", .{ pkg_name, entry.name });
            } else {
                const full_path = std.fs.path.join(arena_alloc, &.{ pkg_dir_path, entry.name }) catch continue;
                if (entry.kind == .sym_link) {
                    std.Io.Dir.cwd().deleteFile(io, full_path) catch |err| {
                        std.log.warn("  could not remove {s}/{s}: {s}", .{ pkg_name, entry.name, @errorName(err) });
                        continue;
                    };
                } else {
                    std.Io.Dir.cwd().deleteTree(io, full_path) catch |err| {
                        std.log.warn("  could not remove {s}/{s}: {s}", .{ pkg_name, entry.name, @errorName(err) });
                        continue;
                    };
                }
                std.log.info("  removed {s}/{s}", .{ pkg_name, entry.name });
            }
            removed_count += 1;
        }
    }

    // Locally-sourced slots live in their own namespace (`packages/local/…`),
    // which the version-pruning loop above never walks — so the diagnostic
    // that tells users `labelle-assembler clean` will drop a local slot used
    // to be a lie for plugins and external backends, and the same implicit
    // source stayed active (#688 review). The whole namespace goes: every
    // path under it is a slot or a marker by construction, so there is
    // nothing to classify and no version pruning to do.
    removed_count += cleanLocalSlots(arena_alloc, io, packages_dir, dry_run);

    if (removed_count == 0) {
        std.log.info("  nothing to clean", .{});
    } else if (dry_run) {
        std.log.info("  {d} version(s) would be removed (run without --dry-run to delete)", .{removed_count});
    } else {
        std.log.info("  cleaned {d} old version(s)", .{removed_count});
    }
}

/// Remove the reserved local-slot namespace (`packages/local/`) whole.
/// Returns 1 when it existed (or, under `--dry-run`, would have been
/// removed), else 0.
///
/// Deliberately NOT a search for directories named `local`: an earlier
/// draft walked `packages/plugins/**` for that name and would have deleted
/// an owner directory of a repo such as `github.com/local/example`, along
/// with anything named `local` inside an extracted checkout (#688 review).
/// The namespace makes the question structural instead.
fn cleanLocalSlots(
    arena_alloc: std.mem.Allocator,
    io: std.Io,
    packages_dir: []const u8,
    dry_run: bool,
) u32 {
    var removed: u32 = 0;
    for ([_][]const u8{ cache.localSlots.SLOT_NS, cache.localSlots.ORIGINS_NS }) |ns| {
        const ns_root = std.fs.path.join(arena_alloc, &.{ packages_dir, ns }) catch continue;
        if (!cache.localSlots.pathExists(ns_root)) continue;

        if (dry_run) {
            std.log.info("  would remove {s}/ (locally-sourced slots)", .{ns});
            removed += 1;
            continue;
        }
        std.Io.Dir.cwd().deleteTree(io, ns_root) catch |err| {
            std.log.warn("  could not remove {s}/: {s}", .{ ns, @errorName(err) });
            continue;
        };
        std.log.info("  removed {s}/ (locally-sourced slots)", .{ns});
        removed += 1;
    }
    return removed;
}

// ── upgrade ──────────────────────────────────────────────────────────

const upgrade_usage =
    \\labelle-assembler upgrade — bump version fields in project.labelle
    \\
    \\Usage:
    \\  labelle-assembler upgrade --project-root <path> [pkg [version]]
    \\
    \\Packages: core, engine, gfx, cli, all
    \\  (no pkg)   upgrade core/engine/gfx/cli to the assembler's defaults
    \\  <pkg>      upgrade one package (to <version>, or the default if omitted)
    \\
;

/// `upgrade` subcommand. Rewrites version fields in project.labelle.
/// The `assembler` package is intentionally not handled here — pinning
/// the assembler binary version is a CLI-bootstrap concern.
pub fn cmdUpgrade(allocator: std.mem.Allocator, io: std.Io, args: *std.process.Args.Iterator) !void {
    var project_root: ?[]const u8 = null;
    var positionals: std.ArrayList([]const u8) = .empty;
    defer positionals.deinit(allocator);

    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--project-root")) {
            project_root = args.next() orelse {
                std.log.err("labelle-assembler upgrade: --project-root requires a value", .{});
                std.process.exit(2);
            };
        } else if (std.mem.startsWith(u8, arg, "--project-root=")) {
            project_root = arg["--project-root=".len..];
        } else if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            writeStderr(io, upgrade_usage);
            return;
        } else if (std.mem.startsWith(u8, arg, "-")) {
            std.log.err("labelle-assembler upgrade: unknown flag '{s}'", .{arg});
            std.process.exit(2);
        } else {
            try positionals.append(allocator, arg);
        }
    }

    const root = project_root orelse {
        std.log.err("labelle-assembler upgrade: --project-root is required", .{});
        std.process.exit(2);
    };

    if (positionals.items.len > 0 and std.mem.eql(u8, positionals.items[0], "assembler")) {
        std.log.err("labelle-assembler upgrade: 'assembler' is pinned by the labelle CLI bootstrap, not the assembler binary", .{});
        std.process.exit(2);
    }

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_alloc = arena.allocator();

    // Parse project.labelle up front to fail fast on a malformed file —
    // the parsed config itself is no longer needed (replaceVersionField
    // edits the raw text and inserts omitted fields directly).
    _ = readProjectConfig(arena_alloc, io, root) catch {
        std.log.err("labelle-assembler upgrade: failed to read project.labelle in '{s}'", .{root});
        std.process.exit(1);
    };

    const labelle_path = try std.fs.path.join(arena_alloc, &.{ root, "project.labelle" });
    var content = std.Io.Dir.cwd().readFileAlloc(io, labelle_path, arena_alloc, .limited(1024 * 1024)) catch {
        std.log.err("labelle-assembler upgrade: could not read '{s}'", .{labelle_path});
        std.process.exit(1);
    };

    if (positionals.items.len == 0) {
        std.log.info("labelle-assembler: upgrading to compatible set (core={s}, engine={s}, gfx={s}, cli={s})", .{
            gen.CORE_VERSION, gen.ENGINE_VERSION, gen.GFX_VERSION, gen.CLI_VERSION,
        });
        content = try replaceVersionField(arena_alloc, content, "core_version", gen.CORE_VERSION);
        content = try replaceVersionField(arena_alloc, content, "engine_version", gen.ENGINE_VERSION);
        content = try replaceVersionField(arena_alloc, content, "gfx_version", gen.GFX_VERSION);
        content = try replaceVersionField(arena_alloc, content, "labelle_version", gen.CLI_VERSION);
    } else {
        const pkg = positionals.items[0];

        // `upgrade all` is defined as "snap every package to the
        // assembler's built-in compatible set". A version argument is
        // meaningless there — one version can't apply to four distinct
        // packages — so reject it instead of logging a version we ignore.
        if (std.mem.eql(u8, pkg, "all") and positionals.items.len > 1) {
            std.log.err("labelle-assembler upgrade: 'all' upgrades every package to the assembler's compatible set — it does not take a version argument", .{});
            std.process.exit(2);
        }

        const default_version: []const u8 = if (std.mem.eql(u8, pkg, "core"))
            gen.CORE_VERSION
        else if (std.mem.eql(u8, pkg, "engine"))
            gen.ENGINE_VERSION
        else if (std.mem.eql(u8, pkg, "gfx"))
            gen.GFX_VERSION
        else
            gen.CLI_VERSION;
        const version = if (positionals.items.len > 1) positionals.items[1] else default_version;

        if (std.mem.eql(u8, pkg, "core")) {
            content = try replaceVersionField(arena_alloc, content, "core_version", version);
        } else if (std.mem.eql(u8, pkg, "engine")) {
            content = try replaceVersionField(arena_alloc, content, "engine_version", version);
        } else if (std.mem.eql(u8, pkg, "gfx")) {
            content = try replaceVersionField(arena_alloc, content, "gfx_version", version);
        } else if (std.mem.eql(u8, pkg, "labelle") or std.mem.eql(u8, pkg, "cli")) {
            content = try replaceVersionField(arena_alloc, content, "labelle_version", version);
        } else if (std.mem.eql(u8, pkg, "all")) {
            content = try replaceVersionField(arena_alloc, content, "core_version", gen.CORE_VERSION);
            content = try replaceVersionField(arena_alloc, content, "engine_version", gen.ENGINE_VERSION);
            content = try replaceVersionField(arena_alloc, content, "gfx_version", gen.GFX_VERSION);
            content = try replaceVersionField(arena_alloc, content, "labelle_version", gen.CLI_VERSION);
        } else {
            std.log.err("labelle-assembler upgrade: unknown package '{s}' (packages: core, engine, gfx, cli, all)", .{pkg});
            std.process.exit(2);
        }
        if (std.mem.eql(u8, pkg, "all")) {
            std.log.info("labelle-assembler: upgrading all packages to the assembler's compatible set (core={s}, engine={s}, gfx={s}, cli={s})", .{
                gen.CORE_VERSION, gen.ENGINE_VERSION, gen.GFX_VERSION, gen.CLI_VERSION,
            });
        } else {
            std.log.info("labelle-assembler: upgrading {s} to {s}", .{ pkg, version });
        }
    }

    std.Io.Dir.cwd().writeFile(io, .{ .sub_path = labelle_path, .data = content }) catch {
        std.log.err("labelle-assembler upgrade: could not write '{s}'", .{labelle_path});
        std.process.exit(1);
    };

    std.log.info("labelle-assembler: project.labelle updated", .{});
    std.log.info("  run 'labelle generate' to regenerate build files", .{});
}

/// Rewrite a ZON version field to `new_value`.
///
/// Two cases:
///   1. The field is written explicitly (`.<field> = "<anything>"`) — its
///      value is replaced in place, preserving the original quoting/spacing
///      around the `=`.
///   2. The field is absent — it defaulted from the config schema, so it
///      was never in the file. The field is *inserted* before the final
///      closing `}` of the top-level struct so the upgrade actually takes
///      effect (the previous behavior was a silent no-op).
///
/// `old_value` is no longer used to locate the field — matching only an
/// exact prior value meant a defaulted/omitted field was never touched.
/// Only the returned slice is allocated; all intermediates are freed, so
/// the function is safe under a leak-checking allocator (it's normally
/// called with an arena, but the tests use the testing allocator).
fn replaceVersionField(
    allocator: std.mem.Allocator,
    content: []const u8,
    field_name: []const u8,
    new_value: []const u8,
) ![]u8 {
    // Locate an existing `.<field>` token (start of a struct field).
    const field_token = try std.fmt.allocPrint(allocator, ".{s}", .{field_name});
    defer allocator.free(field_token);

    if (findFieldAssignment(content, field_token)) |span| {
        var result: std.ArrayList(u8) = .empty;
        errdefer result.deinit(allocator);
        try result.appendSlice(allocator, content[0..span.start]);
        try result.print(allocator, ".{s} = \"{s}\"", .{ field_name, new_value });
        try result.appendSlice(allocator, content[span.end..]);
        return result.toOwnedSlice(allocator);
    }

    // Field absent — insert it before the final closing brace.
    const close = std.mem.lastIndexOfScalar(u8, content, '}') orelse {
        // Not a recognizable ZON struct — leave it untouched rather than
        // corrupt the file.
        return try allocator.dupe(u8, content);
    };
    var result: std.ArrayList(u8) = .empty;
    errdefer result.deinit(allocator);
    try result.appendSlice(allocator, content[0..close]);
    try result.print(allocator, "    .{s} = \"{s}\",\n", .{ field_name, new_value });
    try result.appendSlice(allocator, content[close..]);
    return result.toOwnedSlice(allocator);
}

/// Byte span `[start, end)` of a `.<field> = "<value>"` assignment.
const FieldSpan = struct { start: usize, end: usize };

/// Find a `.<field> = "..."` assignment in ZON `content`. `field_token` is
/// the `.<field>` prefix. Returns the span covering the dot through the
/// closing quote of the string value, or null when the field is absent or
/// not assigned a string literal.
fn findFieldAssignment(content: []const u8, field_token: []const u8) ?FieldSpan {
    var search_from: usize = 0;
    while (std.mem.indexOfPos(u8, content, search_from, field_token)) |idx| {
        search_from = idx + field_token.len;
        // Must be a real field token: preceded by whitespace/brace/start and
        // followed by whitespace or `=` (so `.gfx_version` doesn't match a
        // hypothetical `.gfx_versions`).
        if (idx > 0) {
            const prev = content[idx - 1];
            if (prev != ' ' and prev != '\t' and prev != '\n' and prev != '{' and prev != ',') continue;
        }
        var j = idx + field_token.len;
        if (j >= content.len) return null;
        const after = content[j];
        if (after != ' ' and after != '\t' and after != '=') continue;
        // Skip whitespace, require `=`.
        while (j < content.len and (content[j] == ' ' or content[j] == '\t')) j += 1;
        if (j >= content.len or content[j] != '=') continue;
        j += 1;
        while (j < content.len and (content[j] == ' ' or content[j] == '\t')) j += 1;
        if (j >= content.len or content[j] != '"') continue;
        // Find the matching closing quote (honoring backslash escapes).
        var k = j + 1;
        while (k < content.len) : (k += 1) {
            if (content[k] == '\\') {
                k += 1;
                continue;
            }
            if (content[k] == '"') return .{ .start = idx, .end = k + 1 };
        }
        return null;
    }
    return null;
}

// ── cache population (ported from labelle-cli/src/cli/cache.zig) ──────

/// Ensure every dependency declared in `cfg` is present in the local cache.
/// No-op when the cache already validates.
pub fn ensureCache(allocator: std.mem.Allocator, cfg: config.ProjectConfig) !void {
    // #685 migration: drop any version-named slot an OLDER assembler
    // symlinked at a sibling checkout, before the presence probes run — a
    // poisoned slot looks cached but holds the wrong source, so it must be
    // invalidated rather than trusted. Cheap (a readlink per pinned dep) and
    // idempotent: once repaired, nothing here is a symlink any more.
    try cache.purgeLegacyLocalSlots(allocator, cfg);

    const missing = try cache.validateCache(allocator, cfg);
    defer {
        for (missing) |m| allocator.free(m);
        allocator.free(missing);
    }
    if (missing.len == 0) return;

    std.log.info("labelle-assembler: populating package cache", .{});

    const framework = [_]struct { name: []const u8, version: []const u8 }{
        .{ .name = "core", .version = cfg.core_version },
        .{ .name = "engine", .version = cfg.engine_version },
        .{ .name = "gfx", .version = cfg.gfx_version },
    };
    for (framework) |pkg| {
        // An explicit override owns the package outright: it must not be
        // replaced by the pinned release the project asks for, and — where
        // the platform copied instead of linking — it is the one thing here
        // that goes stale, so it is refreshed rather than probed (#704).
        if (try refreshExplicitLocalSlot(allocator, pkg.name)) continue;
        if (!try cache.isFrameworkCached(allocator, pkg.name, pkg.version)) {
            try fetchFrameworkWithFallback(allocator, pkg.name, pkg.version);
        }
    }

    const asm_ver = cfg.assembler_version orelse cfg.labelle_version;
    if (!try cache.isAssemblerCached(allocator, asm_ver)) {
        try fetchAssemblerWithFallback(allocator, asm_ver);
    }

    // External backend package (#386 Phase 6a): fetch a remote backend into the
    // cache exactly like a plugin. Local (`local:`/`@libs`) backends report
    // cached and are skipped — they already resolve to their checkout in place.
    //
    // `effectiveBackendPackage()` (not the raw `.backend_package` field) so an
    // EXTRACTED built-in (the enum-as-shorthand flip, e.g. `.backend = .bgfx`,
    // #386 Phase 6c) is fetched too — its package comes from `builtinProvider`.
    if (cfg.effectiveBackendPackage()) |bp| {
        if (!try cache.isPluginCached(allocator, bp)) {
            try fetchBackendWithFallback(allocator, bp);
        }
    }

    // The tests target (#83) ALWAYS forces `.backend = .null` (so `zig build test`
    // needs no native libs/toolchain, on any host). Once null is an EXTRACTED
    // external backend (the flip, #386 Phase 6c), it must be in the cache for that
    // tests-target generate even when the PROJECT's own backend is something else
    // (raylib/sokol/…). Fetch it here so every project's `install` covers its tests
    // target. null is now an EXTRACTED external backend (#386 Phase 6c) —
    // `builtinProvider(.null)` returns the labelle-null package and no
    // `builtinProvider` arm returns null anymore, so `effectiveBackendPackage()`
    // here always resolves (the `orelse null` bundled path is gone). The no-op is
    // therefore the `isPluginCached` guard, not a null effective package: when the
    // project already IS null the fetch above (line ~534) already cached it, so
    // this skips. Idempotent regardless. null is pure-Zig + tiny.
    const tests_target_cfg = config.ProjectConfig{ .name = cfg.name, .backend = .null };
    if (tests_target_cfg.effectiveBackendPackage()) |null_bp| {
        if (!try cache.isPluginCached(allocator, null_bp)) {
            try fetchBackendWithFallback(allocator, null_bp);
        }
    }

    for (cfg.plugins) |plugin| {
        if (!try cache.isPluginCached(allocator, plugin)) {
            try fetchPluginWithFallback(allocator, plugin);
        }
    }

    try cache.patchCachedDeps(allocator, cfg);
    std.log.info("  cache populated", .{});
}

/// Fetch a framework package: symlink from the monorepo checkout when the
/// assembler is running inside it, else shallow-clone from the repo.
fn fetchFrameworkWithFallback(allocator: std.mem.Allocator, name: []const u8, version: []const u8) !void {
    // An explicit `local:` pin is a source path, never a git ref. Falling
    // through to the fetcher with one built a release URL out of it and
    // 404ed (#704 repro B); falling through to auto-discovery first would
    // build the sibling checkout instead of the named one (repro C).
    if (config.isLocalVersion(version)) return installLocalFramework(allocator, name, version, null);

    // An explicit override OWNS the local slot, so auto-discovery must not
    // populate over it (#704 review). Left unguarded, running `install core
    // <version>` from inside the monorepo replaced the checkout the user
    // registered with the sibling next door and rewrote the marker as
    // `discovered` — defect C returning through another door, and a
    // contradiction of the documented promise that only `clean` drops an
    // override. The refresh keeps a copied slot (Windows) current while it
    // is here.
    const overridden = try refreshExplicitLocalSlot(allocator, name);
    if (overridden) {
        std.log.warn(
            "  {s}: an explicit local override is active, so the pinned {s} will NOT be built — " ++
                "caching it anyway; run 'labelle-assembler clean' to drop the override (#704)",
            .{ name, version },
        );
    } else if (findRepoRoot(allocator)) |repo_root| {
        defer allocator.free(repo_root);
        const dir_name = cache.localSlots.frameworkDirName(name);
        const src = try std.fs.path.join(allocator, &.{ repo_root, dir_name });
        defer allocator.free(src);
        if (cache.dirExists(src)) {
            std.log.warn(
                "  {s}: using LOCAL sources from '{s}' — the pinned {s} will NOT be built (#685)",
                .{ name, src, version },
            );
            try cache.populateFrameworkPackage(allocator, name, version, src, .discovered);
            return;
        }
    }
    std.log.info("  fetching {s} {s} (remote)", .{ name, version });
    try cache.fetchFrameworkPackage(allocator, name, version);
}

/// Fetch assembler-bundled packages (backends, ecs, gui): symlink from the
/// monorepo when available, else clone the assembler repo at the tag.
fn fetchAssemblerWithFallback(allocator: std.mem.Allocator, version: []const u8) !void {
    if (findRepoRoot(allocator)) |repo_root| {
        defer allocator.free(repo_root);
        const companion = try std.fs.path.join(allocator, &.{ repo_root, "labelle-assembler" });
        defer allocator.free(companion);
        if (cache.dirExists(companion)) {
            std.log.warn(
                "  assembler: using LOCAL sources from '{s}' — the pinned {s} will NOT be built (#685)",
                .{ companion, version },
            );
            try cache.populateAssemblerCache(allocator, version, companion);
            return;
        }
    }
    std.log.info("  fetching assembler {s} (remote)", .{version});
    try cache.fetchAssemblerPackages(allocator, version);
}

/// Fetch a plugin: symlink from the monorepo when available, else clone.
fn fetchPluginWithFallback(allocator: std.mem.Allocator, plugin: config.PluginDep) !void {
    if (findRepoRoot(allocator)) |repo_root| {
        defer allocator.free(repo_root);
        const plugin_dir = try std.fmt.allocPrint(allocator, "labelle-{s}", .{plugin.name});
        defer allocator.free(plugin_dir);
        const src = try std.fs.path.join(allocator, &.{ repo_root, plugin_dir });
        defer allocator.free(src);
        if (cache.dirExists(src)) {
            std.log.warn(
                "  plugin {s}: using LOCAL sources from '{s}' — the pinned {s} will NOT be built (#685)",
                .{ plugin.name, src, plugin.version },
            );
            try cache.populatePlugin(allocator, plugin, src);
            return;
        }
    }
    std.log.info("  fetching plugin {s} {s} (remote)", .{ plugin.name, plugin.version });
    try cache.fetchPlugin(allocator, plugin);
}

/// Fetch an external backend package (#386 Phase 6a). A `backend_package` is a
/// `PluginDep`, so it rides the exact same fetch path a plugin does: copy from a
/// sibling `labelle-{name}` checkout when the assembler runs inside the monorepo
/// (the backend author's local-dev story), else shallow-clone its `.repo`.
///
/// A failure here is fatal — the game cannot build without its backend — so we
/// surface a clear, backend-named diagnostic in addition to the git-level error
/// `fetchPlugin` already logs, then re-raise so `ensureCache` aborts.
fn fetchBackendWithFallback(allocator: std.mem.Allocator, bp: config.PluginDep) !void {
    // This is only reached for a NON-local backend that isn't cached (local
    // backends always report cached). A non-local backend with an empty `.repo`
    // or `.version` is a config error: `resolvePlugin` would probe a bogus
    // `plugins///` cache slot and the clone would degrade to
    // `git clone --branch "" https://.git`. Fail with a clear, actionable
    // message instead of that confusing downstream git error.
    if (bp.repo.len == 0 or bp.version.len == 0) {
        std.log.err(
            "labelle-assembler: external backend '{s}' needs both a '.repo' and a '.version' to fetch " ++
                "(got repo='{s}', version='{s}'). Add them to '.backend_package', or use a 'local:' repo.",
            .{ bp.name, bp.repo, bp.version },
        );
        return error.InvalidBackendPackage;
    }
    if (findRepoRoot(allocator)) |repo_root| {
        defer allocator.free(repo_root);
        const dir_name = try std.fmt.allocPrint(allocator, "labelle-{s}", .{bp.name});
        defer allocator.free(dir_name);
        const src = try std.fs.path.join(allocator, &.{ repo_root, dir_name });
        defer allocator.free(src);
        if (cache.dirExists(src)) {
            std.log.warn(
                "  backend {s}: using LOCAL sources from '{s}' — the pinned {s} will NOT be built (#685)",
                .{ bp.name, src, bp.version },
            );
            try cache.populatePlugin(allocator, bp, src);
            return;
        }
    }
    std.log.info("  fetching backend {s} {s} (remote)", .{ bp.name, bp.version });
    cache.fetchPlugin(allocator, bp) catch |err| {
        std.log.err(
            "labelle-assembler: could not fetch external backend '{s}' from '{s}' (version '{s}'): {s}\n" ++
                "  check the backend's '.repo'/'.version' in your project config and that the repo is reachable.",
            .{ bp.name, bp.repo, bp.version, @errorName(err) },
        );
        return err;
    };
}

/// Whether `name` is safe to join into a cache path that the migration
/// sweep may delete.
///
/// A `/` is NOT disqualifying (#688 review round 6): `versionToGitRef`
/// passes non-semver versions through verbatim, so `feature/foo` and
/// `2026/dev` are supported version pins and their cache paths are nested
/// to match. Only traversal is rejected — a `..` component, or an absolute
/// path that would ignore the cache root altogether.
fn isSafePathComponent(name: []const u8) bool {
    if (name.len == 0) return false;
    if (std.fs.path.isAbsolute(name)) return false;
    var it = std.mem.tokenizeAny(u8, name, "/\\");
    var any = false;
    while (it.next()) |component| {
        any = true;
        if (std.mem.eql(u8, component, "..") or std.mem.eql(u8, component, ".")) return false;
    }
    return any;
}

/// #685 migration for the single-package `install` forms, which have no
/// ProjectConfig to sweep: drop a version-named slot that an older
/// assembler symlinked at a sibling checkout so the release is re-fetched.
fn purgeLegacyFrameworkSlot(allocator: std.mem.Allocator, package: []const u8, version: []const u8) !void {
    if (config.isLocalVersion(version)) return;
    const packages_dir = cache.getPackagesDir(allocator) catch return;
    defer allocator.free(packages_dir);
    const slot = std.fs.path.join(allocator, &.{ packages_dir, package, version }) catch return;
    defer allocator.free(slot);
    // NOT discarded: a purge that failed leaves the poisoned slot in place,
    // and `isFrameworkCached` would then accept it as the pinned release
    // (#688 review round 5). Abort the install instead.
    _ = try cache.purgeLegacyLocalSlot(allocator, slot, version);
}

/// Walk up from the assembler executable's directory looking for the
/// monorepo root (identified by a `labelle-core` sibling). Returns null
/// when the binary isn't running inside the monorepo checkout.
///
/// Lives in `cache/local.zig` now (#685) — the resolve side needs the same
/// answer, so both sides share one probe.
const findRepoRoot = cache.findRepoRoot;

// ── project.labelle reading ──────────────────────────────────────────

/// Read + parse project.labelle. Mirrors main.zig:readProjectConfig.
fn readProjectConfig(allocator: std.mem.Allocator, io: std.Io, project_dir: []const u8) !config.ProjectConfig {
    @setEvalBranchQuota(10000);
    const labelle_path = try std.fs.path.join(allocator, &.{ project_dir, "project.labelle" });
    defer allocator.free(labelle_path);

    const source_raw = try std.Io.Dir.cwd().readFileAlloc(io, labelle_path, allocator, .limited(1024 * 1024));
    defer allocator.free(source_raw);

    const source = try allocator.dupeZ(u8, source_raw);
    // Params-tolerant parse (#591) — cache/upgrade must not choke on a
    // project whose plugins take schema-declared params.
    return try @import("plugin_params.zig").parseProjectConfig(allocator, source);
}

/// readProjectConfig that returns an error instead of treating a missing
/// file as fatal — used by `clean`, where no project.labelle is normal.
fn readProjectConfigQuiet(allocator: std.mem.Allocator, io: std.Io, project_dir: []const u8) !config.ProjectConfig {
    return readProjectConfig(allocator, io, project_dir);
}

test {
    std.testing.refAllDecls(@This());
}

// ── tests: upgrade version-field rewriting ───────────────────────────
//
// Regression guard for the #158 review findings: `upgrade` was a no-op
// for any version field not written verbatim in project.labelle (a
// defaulted/omitted field), because `replaceVersionField` only matched
// an exact `.field = "<old>"` string.

test "replaceVersionField rewrites an explicitly written field" {
    const alloc = std.testing.allocator;
    const content =
        \\.{
        \\    .name = "g",
        \\    .core_version = "0.1.0",
        \\}
        \\
    ;
    const out = try replaceVersionField(alloc, content, "core_version", "0.9.9");
    defer alloc.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, ".core_version = \"0.9.9\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "0.1.0") == null);
}

test "replaceVersionField rewrites regardless of the prior value" {
    // The old implementation needed the caller to pass the exact current
    // value. The new one locates the field by name, so any prior value
    // (including one that doesn't match the config default) is replaced.
    const alloc = std.testing.allocator;
    const content =
        \\.{
        \\    .gfx_version = "1.2.3-custom",
        \\}
        \\
    ;
    const out = try replaceVersionField(alloc, content, "gfx_version", "2.0.0");
    defer alloc.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, ".gfx_version = \"2.0.0\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "1.2.3-custom") == null);
}

test "replaceVersionField inserts an omitted field instead of no-op" {
    const alloc = std.testing.allocator;
    const content =
        \\.{
        \\    .name = "g",
        \\    .engine_version = "0.1.0",
        \\}
        \\
    ;
    // core_version is absent (it defaulted from the schema). Upgrading it
    // must insert the field, not silently do nothing.
    const out = try replaceVersionField(alloc, content, "core_version", "0.5.0");
    defer alloc.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, ".core_version = \"0.5.0\"") != null);
    // The pre-existing field must be untouched.
    try std.testing.expect(std.mem.indexOf(u8, out, ".engine_version = \"0.1.0\"") != null);
    // Result must still be a closed struct.
    try std.testing.expect(std.mem.endsWith(u8, std.mem.trimEnd(u8, out, "\n"), "}"));
}

test "replaceVersionField inserted field round-trips through the ZON parser" {
    const alloc = std.testing.allocator;
    const content =
        \\.{
        \\    .name = "g",
        \\    .title = "g",
        \\    .backend = .raylib,
        \\    .ecs = .zig_ecs,
        \\}
        \\
    ;
    var c = try alloc.dupe(u8, content);
    inline for (.{
        .{ "core_version", "1.0.0" },
        .{ "engine_version", "1.0.1" },
        .{ "gfx_version", "1.0.2" },
        .{ "labelle_version", "1.0.3" },
    }) |pair| {
        const next = try replaceVersionField(alloc, c, pair[0], pair[1]);
        alloc.free(c);
        c = next;
    }
    defer alloc.free(c);

    const src = try alloc.dupeZ(u8, c);
    defer alloc.free(src);
    // Parse into an arena: ProjectConfig carries comptime-default slice
    // fields (e.g. `.layers`) that std.zon.parse.free would choke on.
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const cfg = try std.zon.parse.fromSliceAlloc(config.ProjectConfig, arena.allocator(), src, null, .{});
    try std.testing.expectEqualStrings("1.0.0", cfg.core_version);
    try std.testing.expectEqualStrings("1.0.1", cfg.engine_version);
    try std.testing.expectEqualStrings("1.0.2", cfg.gfx_version);
    try std.testing.expectEqualStrings("1.0.3", cfg.labelle_version);
}

test "replaceVersionField does not match a longer field name" {
    // `.gfx_version` must not be found inside a `.gfx_versions` token.
    const alloc = std.testing.allocator;
    const content =
        \\.{
        \\    .gfx_versions = "should-not-touch",
        \\}
        \\
    ;
    const out = try replaceVersionField(alloc, content, "gfx_version", "9.9.9");
    defer alloc.free(out);
    // The bogus field is left alone and a real `.gfx_version` is inserted.
    try std.testing.expect(std.mem.indexOf(u8, out, "should-not-touch") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, ".gfx_version = \"9.9.9\"") != null);
}

test "findFieldAssignment tolerates extra whitespace around =" {
    const content =
        \\.{
        \\    .core_version   =   "0.1.0",
        \\}
    ;
    const span = findFieldAssignment(content, ".core_version") orelse return error.NotFound;
    try std.testing.expectEqualStrings(".core_version   =   \"0.1.0\"", content[span.start..span.end]);
}

test "cleanLocalSlots: drops the local namespace, leaving version slots alone (#688 review)" {
    // `warnIfLocallySourced` tells users to run `labelle-assembler clean` to
    // drop a local slot, but `cmdClean`'s version-pruning loop only walks
    // core/engine/gfx/cli/assembler — a plugin or external backend's slot
    // survived it, so the same implicit source stayed active and the warning
    // repeated forever.
    const alloc = std.testing.allocator;
    const io = config.globalIo();

    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const arena_alloc = arena.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const repo = "github.com/labelle-toolkit/labelle-physics";
    // A plugin local slot, a plugin RELEASE slot, and — the trap an earlier
    // draft fell into — a plugin repo whose OWNER is literally named `local`.
    try tmp.dir.createDirPath(std.testing.io, "packages/local/plugins/" ++ repo);
    try tmp.dir.createDirPath(std.testing.io, "packages/plugins/" ++ repo ++ "/0.4.0");
    try tmp.dir.createDirPath(std.testing.io, "packages/plugins/github.com/local/example/1.0.0");
    try tmp.dir.createDirPath(std.testing.io, "checkout");

    const home = try tmp.dir.realPathFileAlloc(std.testing.io, ".", alloc);
    defer alloc.free(home);
    const packages_dir = try tmp.dir.realPathFileAlloc(std.testing.io, "packages", alloc);
    defer alloc.free(packages_dir);
    const checkout = try tmp.dir.realPathFileAlloc(std.testing.io, "checkout", alloc);
    defer alloc.free(checkout);

    cache.cacheEnv.setCacheRootForTesting(home);
    defer cache.cacheEnv.setCacheRootForTesting(null);

    const slot = try std.fs.path.join(alloc, &.{ packages_dir, cache.localSlots.SLOT_NS, "plugins", repo });
    defer alloc.free(slot);
    try std.Io.Dir.cwd().deleteTree(io, slot);
    try cache.junction.linkDir(alloc, checkout, slot);
    try cache.localSlots.writeOrigin(alloc, slot, checkout, "0.4.0", .discovered);

    const marker = try cache.localSlots.originPath(alloc, slot);
    defer alloc.free(marker);
    try std.testing.expect(cache.localSlots.pathExists(marker));

    // A dry run reports both namespaces without touching anything.
    try std.testing.expectEqual(@as(u32, 2), cleanLocalSlots(arena_alloc, io, packages_dir, true));
    try std.testing.expect(cache.localSlots.pathExists(slot));

    try std.testing.expectEqual(@as(u32, 2), cleanLocalSlots(arena_alloc, io, packages_dir, false));
    try std.testing.expect(!cache.localSlots.pathExists(slot));
    try std.testing.expect(!cache.localSlots.pathExists(marker));

    // The release slot, the `local`-OWNED repo, and the source checkout all
    // survive untouched.
    const release = try std.fs.path.join(alloc, &.{ packages_dir, "plugins", repo, "0.4.0" });
    defer alloc.free(release);
    try std.testing.expect(cache.localSlots.pathExists(release));
    const owner_local = try std.fs.path.join(alloc, &.{ packages_dir, "plugins", "github.com", "local", "example", "1.0.0" });
    defer alloc.free(owner_local);
    try std.testing.expect(cache.localSlots.pathExists(owner_local));
    try std.testing.expect(cache.localSlots.pathExists(checkout));

    // Idempotent.
    try std.testing.expectEqual(@as(u32, 0), cleanLocalSlots(arena_alloc, io, packages_dir, false));
}

test "isSafePathComponent: slash-delimited git refs are versions, traversal is not (#688 review)" {
    // `versionToGitRef` passes non-semver versions through verbatim, so a
    // slash-delimited branch is a supported pin and `install feature/foo`
    // must keep reaching the fetcher.
    try std.testing.expect(isSafePathComponent("1.29.0"));
    try std.testing.expect(isSafePathComponent("main"));
    try std.testing.expect(isSafePathComponent("feature/foo"));
    try std.testing.expect(isSafePathComponent("2026/dev"));

    try std.testing.expect(!isSafePathComponent(""));
    try std.testing.expect(!isSafePathComponent("."));
    try std.testing.expect(!isSafePathComponent(".."));
    try std.testing.expect(!isSafePathComponent("../../target"));
    try std.testing.expect(!isSafePathComponent("feature/../../../etc"));
    try std.testing.expect(!isSafePathComponent("/etc/passwd"));
}
