//! i18n, phase 1 (RFC-I18N in labelle-engine#811, tracking #809).
//!
//! Scans `locales/*.jsonc`, validates against the declared reference locale,
//! and emits `i18n.zig` into the target dir: a `Key` type, the `K` namespace
//! of comptime key constants, every locale baked into one rectangular table,
//! and `t` / `setLocale` / `activeLocale` / `locales`.
//!
//! The properties the RFC promises, held here:
//!
//!  - a misspelled key does not compile (`K.menu.new_gme` names a missing
//!    declaration at the call site)
//!  - the table is rectangular: a locale missing a key gets the reference
//!    locale's string in that slot, so no runtime path can fail and no
//!    fallback code exists
//!  - coverage diagnostics are usage-aware (§3.1): a key *used in code* and
//!    missing from a locale warns, naming the key and every locale missing
//!    it; an unused untranslated key is silent. `strict` promotes the warning
//!    to a build error. The used-set comes from usage_scan.zig -- the same
//!    conservative alias-widening scanner constants use, with root `K`.
//!
//! A project with no `locales/` emits nothing and keeps a byte-identical
//! build.zig; a stale generated file is deleted, mirroring constants_phase.
const std = @import("std");
const Allocator = std.mem.Allocator;
const locales_mod = @import("i18n_locales.zig");
const usage = @import("usage_scan.zig");
const interp = @import("i18n_interp.zig");
const zig_keywords = @import("zig_keywords.zig");

// Same local io as constants_phase, for the same reason: config.zig pulls in
// build_options and would make this file untestable standalone.
var _threaded: std.Io.Threaded = undefined;
var _io: std.Io = undefined;
var _io_ready = false;

fn phaseIo() std.Io {
    if (!_io_ready) {
        _threaded = std.Io.Threaded.init(std.heap.page_allocator, .{});
        _io = _threaded.io();
        _io_ready = true;
    }
    return _io;
}

pub const GENERATED_FILENAME = "i18n.zig";

/// Mirror of config.I18nConfig, so this file does not import config.zig.
/// root.zig converts.
pub const Settings = struct {
    default: []const u8,
    reference: ?[]const u8 = null,
    strict: bool = false,
};

/// A pack that may ship locales: name, resolved source dir, and its declared
/// reference locale (pack.labelle `.i18n_reference`, RFC-I18N §2.2). Null
/// falls back to the project's reference.
pub const PackLocales = struct {
    name: []const u8,
    src_dir: []const u8,
    reference: ?[]const u8 = null,
};

/// Runs the phase. Returns true when `i18n.zig` was emitted.
///
/// Phase 3 (§2.1/§2.2): packs ship `locales/*.jsonc` whose keys surface
/// prefixed `<pack>__`; the game overrides a pack's string, and may add
/// locales the pack never shipped, by writing the pack's keys under the
/// prefixed name in its own files. Writing under a pack's namespace asserts
/// the key exists in the pack's key space — a typo or a pack-renamed key is
/// a build error, not a silent fallthrough to the pack's string. Backfill
/// resolves locale → pack reference → project reference, so a pack shipping
/// en+fr in a game authored in pt still backfills from its own English.
pub fn runPhase(
    allocator: Allocator,
    game_dir: []const u8,
    target_dir: []const u8,
    settings: ?Settings,
    packs: []const PackLocales,
    /// False for the tests target, so per-generation diagnostics print once.
    diagnostics: bool,
) !bool {
    const io = phaseIo();
    const cwd = std.Io.Dir.cwd();

    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const src_path = try std.fs.path.join(arena, &.{ game_dir, "locales" });
    var src_dir = cwd.openDir(io, src_path, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound, error.NotDir => {
            const stale = try std.fs.path.join(arena, &.{ target_dir, GENERATED_FILENAME });
            cwd.deleteFile(io, stale) catch {};
            return false;
        },
        else => return err,
    };
    defer src_dir.close(io);

    // Tags, from filenames, sorted for determinism. The filename is a BCP-47
    // declaration, so a stem that is not one -- `en_US`, `english`, "" -- is
    // an error here rather than a tag that interoperates with nothing later.
    var tags: std.ArrayList([]const u8) = .empty;
    var bad_tag = false;
    var iter = src_dir.iterate();
    while (try iter.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".jsonc")) continue;
        const stem = entry.name[0 .. entry.name.len - ".jsonc".len];
        if (!isBcp47ish(stem)) {
            std.debug.print("locales/{s}: '{s}' is not a BCP-47 tag (expected e.g. en, pt-BR). Underscores are the classic typo: pt_BR should be pt-BR\n", .{ entry.name, stem });
            bad_tag = true;
            continue;
        }
        try tags.append(arena, try arena.dupe(u8, stem));
    }
    if (bad_tag) return error.I18nInvalid;
    std.mem.sort([]const u8, tags.items, {}, struct {
        fn lessThan(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.lessThan);

    if (tags.items.len == 0) {
        const stale = try std.fs.path.join(arena, &.{ target_dir, GENERATED_FILENAME });
        cwd.deleteFile(io, stale) catch {};
        return false;
    }

    // §8: `.default` is mandatory whenever locales/ exists. No implicit "en" --
    // a shipping language is a product decision, not a filename guess.
    const cfg = settings orelse {
        std.debug.print("locales/ exists but project.labelle declares no .i18n block. Add: .i18n = .{{ .default = \"{s}\" }}\n", .{tags.items[0]});
        return error.I18nInvalid;
    };
    const default_idx = indexOfTag(tags.items, cfg.default) orelse {
        std.debug.print("i18n.default = \"{s}\" names no locale file. Scanned: {s}\n", .{ cfg.default, try joinTags(arena, tags.items) });
        return error.I18nInvalid;
    };
    const reference_tag = cfg.reference orelse cfg.default;
    const reference_idx = indexOfTag(tags.items, reference_tag) orelse {
        std.debug.print("i18n.reference = \"{s}\" names no locale file. Scanned: {s}\n", .{ reference_tag, try joinTags(arena, tags.items) });
        return error.I18nInvalid;
    };

    // Parse every locale.
    var parsed: []locales_mod.Locale = try arena.alloc(locales_mod.Locale, tags.items.len);
    var had_error = false;
    for (tags.items, 0..) |tag, i| {
        const fname = try std.fmt.allocPrint(arena, "{s}.jsonc", .{tag});
        const source = src_dir.readFileAlloc(io, fname, arena, .limited(4 * 1024 * 1024)) catch |err| switch (err) {
            error.StreamTooLong => {
                std.debug.print("locales/{s}: file exceeds 4 MiB\n", .{fname});
                had_error = true;
                parsed[i] = .{ .entries = &.{} };
                continue;
            },
            else => return err,
        };
        switch (try locales_mod.parse(arena, source)) {
            .fail => |e| {
                std.debug.print("locales/{s}: {s}\n", .{ fname, e.msg });
                had_error = true;
                parsed[i] = .{ .entries = &.{} };
            },
            .ok => |l| parsed[i] = l,
        }
    }
    if (had_error) return error.I18nInvalid;

    // Keyword-key lint (flying-platform#786 friction #2). A segment named
    // like a Zig keyword GENERATES fine -- every K declaration is @""-quoted
    // -- but each call site must then write K.pause.@"resume", which is the
    // ergonomic trap FP hit. Warn against the reference locale (the key
    // space, so one warning per key however many files carry it) and show
    // the cheap rename. Never an error: the @"" path works.
    if (diagnostics) {
        for (try keywordKeyLints(arena, parsed[reference_idx].entries)) |l| {
            std.debug.print("warning: i18n: locales/{s}.jsonc: key '{s}': segment '{s}' is a Zig keyword, so call sites read K.{s} -- consider renaming the segment to '{s}_'\n", .{ reference_tag, l.key, l.seg, try zig_keywords.quoteDottedPath(arena, l.key), l.seg });
        }
    }

    // Phase 3: pack locales. Everything below folds the packs into ONE merged
    // key space and merged per-tag locales, then the whole existing pipeline
    // -- the rename catch, coverage, placeholder parity, emission -- runs on
    // the merged data unchanged. The precedence and must-exist rules live
    // here; nothing downstream knows packs exist.
    if (packs.len > 0) {
        const merged = mergePacks(arena, io, .{
            .game_tags = tags.items,
            .game_parsed = parsed,
            .reference_idx = reference_idx,
            .reference_tag = reference_tag,
            .packs = packs,
            .diagnostics = diagnostics,
        }) catch |err| switch (err) {
            error.I18nInvalid => return error.I18nInvalid,
            else => return err,
        };
        parsed = merged;
    }

    const reference = parsed[reference_idx];
    if (reference.entries.len == 0) {
        std.debug.print("locales/{s}.jsonc: the reference locale defines no keys\n", .{reference_tag});
        return error.I18nInvalid;
    }
    if (reference.entries.len > 65535) {
        std.debug.print("i18n: {d} keys exceeds the u16 key space\n", .{reference.entries.len});
        return error.I18nInvalid;
    }
    for (reference.entries) |re| {
        // The codegen walks segments through fixed [16] stacks; a deeper key
        // would write past them. 12 leaves margin, and no sane key needs it.
        if (std.mem.count(u8, re.key, ".") >= 12) {
            std.debug.print("i18n: key '{s}' nests deeper than 12 levels\n", .{re.key});
            return error.I18nInvalid;
        }
    }

    // §3 row 3: a key in L that the reference lacks is a build error -- it
    // catches renames that updated one file only.
    for (tags.items, 0..) |tag, i| {
        if (i == reference_idx) continue;
        for (parsed[i].entries) |e| {
            if (reference.get(e.key) == null) {
                std.debug.print("locales/{s}.jsonc: key '{s}' is absent from the reference locale ({s}) -- a rename that updated one file only?\n", .{ tag, e.key, reference_tag });
                had_error = true;
            }
        }
    }
    if (had_error) return error.I18nInvalid;

    // §3.1: usage-aware coverage. The used-set comes from the shared scanner
    // with root K; a used key missing from a locale warns (or errors under
    // strict), naming every locale missing it. Unused gaps stay silent --
    // they are the normal state mid-feature.
    //
    // `diagnostics` gates the warnings: generate runs once per target, and
    // without the gate every warning printed twice. Strict errors run
    // regardless -- a broken build must break both targets.
    var marks = usage.Marks.init(arena);
    try collectMarks(arena, &marks, game_dir);

    // When the scanner widened to all-used (a module alias it cannot follow),
    // "used" stops being evidence: promoting EVERY untranslated key to a
    // strict error would fail builds over keys nothing renders, which is the
    // opposite of the usage-aware contract. Fall back to warnings and say so.
    const strict_effective = cfg.strict and !marks.all;
    if (cfg.strict and marks.all and diagnostics) {
        std.debug.print("note: i18n.strict: usage could not be tracked precisely (a module alias widened the scan), so coverage gaps warn instead of failing this build\n", .{});
    }

    for (reference.entries) |re| {
        if (!marks.covers(re.key)) continue;
        var missing: std.ArrayList([]const u8) = .empty;
        for (tags.items, 0..) |tag, i| {
            if (i == reference_idx) continue;
            if (parsed[i].get(re.key) == null) try missing.append(arena, tag);
        }
        if (missing.items.len == 0) continue;
        const list = try std.mem.join(arena, ", ", missing.items);
        if (strict_effective) {
            std.debug.print("error: i18n: K.{s} is used but missing from: {s} (strict)\n", .{ re.key, list });
            had_error = true;
        } else if (diagnostics) {
            std.debug.print("warning: i18n: K.{s} is used but missing from: {s} (backfilled with {s})\n", .{ re.key, list, reference_tag });
        }
    }
    if (had_error) return error.I18nInvalid;

    // Phase 2 (§4): placeholders. Every string in every locale is parsed --
    // a syntax error names the locale and key. Parity compares placeholder
    // *sets* between the reference and each locale that defines the key:
    // order is legitimate translation (word order is the thing translation
    // changes), a differing set is drift.
    const interps = try arena.alloc(?KeyInterp, reference.entries.len);
    for (reference.entries, 0..) |re, ki| {
        const ref_segs = switch (try interp.parse(arena, re.value)) {
            .fail => |msg| {
                std.debug.print("locales/{s}.jsonc: key '{s}': {s}\n", .{ reference_tag, re.key, msg });
                had_error = true;
                interps[ki] = null;
                continue;
            },
            .ok => |segs| segs,
        };
        const ref_names = try interp.names(arena, ref_segs);

        const per_locale = try arena.alloc([]const interp.Segment, tags.items.len);
        for (tags.items, 0..) |tag, li| {
            const own = parsed[li].get(re.key);
            const segs = if (own) |s| switch (try interp.parse(arena, s)) {
                .fail => |msg| blk: {
                    std.debug.print("locales/{s}.jsonc: key '{s}': {s}\n", .{ tag, re.key, msg });
                    had_error = true;
                    break :blk ref_segs;
                },
                .ok => |segs| segs,
            } else ref_segs; // backfilled slot: the reference's segments
            if (own != null and li != reference_idx) {
                const l_names = try interp.names(arena, segs);
                if (!interp.sameNames(ref_names, l_names)) {
                    std.debug.print("locales/{s}.jsonc: key '{s}': placeholder set {{{s}}} differs from the reference's {{{s}}}\n", .{ tag, re.key, try std.mem.join(arena, ", ", l_names), try std.mem.join(arena, ", ", ref_names) });
                    had_error = true;
                }
            }
            per_locale[li] = segs;
        }
        interps[ki] = if (ref_names.len == 0) null else .{ .arg_names = ref_names, .segs = per_locale };
    }
    if (had_error) return error.I18nInvalid;

    // Emit.
    var out: std.Io.Writer.Allocating = .init(arena);
    const w = &out.writer;
    try emitModule(arena, w, tags.items, parsed, reference, reference_idx, default_idx, interps);

    const dst = try std.fs.path.join(arena, &.{ target_dir, GENERATED_FILENAME });
    try cwd.writeFile(io, .{ .sub_path = dst, .data = out.writer.buffered() });
    return true;
}

/// A pragmatic BCP-47 shape check: 2-3 letter primary subtag, then optional
/// `-` separated alphanumeric subtags of 1-8 chars. Not a registry lookup --
/// it exists to catch `en_US`, `english` and "" at build time, not to police
/// the IANA registry.
fn isBcp47ish(s: []const u8) bool {
    var it = std.mem.splitScalar(u8, s, '-');
    const primary = it.next() orelse return false;
    if (primary.len < 2 or primary.len > 3) return false;
    for (primary) |c| {
        if (!std.ascii.isAlphabetic(c)) return false;
    }
    while (it.next()) |sub| {
        if (sub.len < 1 or sub.len > 8) return false;
        for (sub) |c| {
            if (!std.ascii.isAlphanumeric(c)) return false;
        }
    }
    return true;
}

fn indexOfTag(tags: []const []const u8, tag: []const u8) ?usize {
    for (tags, 0..) |t, i| {
        if (std.mem.eql(u8, t, tag)) return i;
    }
    return null;
}

fn joinTags(arena: Allocator, tags: []const []const u8) ![]const u8 {
    return std.mem.join(arena, ", ", tags);
}

// ---------------------------------------------------------------------------
// codegen
// ---------------------------------------------------------------------------

const MergeInput = struct {
    game_tags: []const []const u8,
    game_parsed: []locales_mod.Locale,
    reference_idx: usize,
    reference_tag: []const u8,
    packs: []const PackLocales,
    diagnostics: bool,
};

/// One keyword-key finding (flying-platform#786 friction #2): the dotted key
/// and its first offending segment. A pure collector so the firing set is
/// unit-testable without capturing stderr; runPhase owns the printing.
const KeywordLint = struct {
    key: []const u8,
    seg: []const u8,
};

fn keywordKeyLints(arena: Allocator, entries: []const locales_mod.Entry) Allocator.Error![]const KeywordLint {
    var out: std.ArrayList(KeywordLint) = .empty;
    for (entries) |e| {
        if (zig_keywords.firstKeywordSegment(e.key)) |seg| {
            try out.append(arena, .{ .key = e.key, .seg = seg });
        }
    }
    return out.items;
}

/// Folds pack locales into the game's, returning merged per-tag locales over
/// the GAME's tag set. The game's tag set is deliberately authoritative: what
/// languages a game offers is a product decision, so a locale only a pack
/// ships is warned about and skipped, never silently added to the Options
/// menu.
///
/// Per (pack key k, game tag L), precedence is:
///   game's L override  >  pack's L string  >  pack's reference string
/// The chain never needs the project reference for pack keys: k exists by
/// construction in the pack's reference, which is the point of §2.2.
fn mergePacks(arena: Allocator, io: std.Io, in: MergeInput) ![]locales_mod.Locale {
    const cwd = std.Io.Dir.cwd();
    var had_error = false;

    const PackData = struct {
        name: []const u8,
        /// The pack's own reference locale -- its key space and backfill source.
        reference: locales_mod.Locale,
        /// Per game tag: the pack's locale for that tag, if it ships one.
        by_tag: []?locales_mod.Locale,
    };
    var pack_data: std.ArrayList(PackData) = .empty;

    for (in.packs) |pk| {
        const ldir_path = try std.fs.path.join(arena, &.{ pk.src_dir, "locales" });
        var ldir = cwd.openDir(io, ldir_path, .{ .iterate = true }) catch |err| switch (err) {
            error.FileNotFound, error.NotDir => continue, // ships no locales
            else => return err, // silently dropping a pack's strings is worse
        };
        defer ldir.close(io);

        // Scan the pack's tags and parse each file.
        var ptags: std.ArrayList([]const u8) = .empty;
        var pparsed: std.ArrayList(locales_mod.Locale) = .empty;
        var iter = ldir.iterate();
        while (try iter.next(io)) |entry| {
            if (entry.kind != .file) continue;
            if (!std.mem.endsWith(u8, entry.name, ".jsonc")) continue;
            const tag = try arena.dupe(u8, entry.name[0 .. entry.name.len - ".jsonc".len]);
            const source = try ldir.readFileAlloc(io, entry.name, arena, .limited(4 * 1024 * 1024));
            switch (try locales_mod.parse(arena, source)) {
                .fail => |e| {
                    std.debug.print("packs/{s}/locales/{s}.jsonc: {s}\n", .{ pk.name, tag, e.msg });
                    had_error = true;
                },
                .ok => |l| {
                    try ptags.append(arena, tag);
                    try pparsed.append(arena, l);
                },
            }
        }
        if (ptags.items.len == 0) continue;

        // §2.2: the pack's reference is its own declaration, falling back to
        // the project's -- and it must actually be one of the pack's locales,
        // because it defines the pack's key space and backfill source.
        const pref_tag = pk.reference orelse in.reference_tag;
        var pref: ?locales_mod.Locale = null;
        for (ptags.items, 0..) |t, i| {
            if (std.ascii.eqlIgnoreCase(t, pref_tag)) pref = pparsed.items[i];
        }
        const pack_ref = pref orelse {
            std.debug.print("packs/{s}/locales/: reference locale '{s}' has no file. A pack's reference defines its key space; declare .i18n_reference in pack.labelle if the pack is not authored in the project's reference language\n", .{ pk.name, pref_tag });
            had_error = true;
            continue;
        };

        // Per-realm rename catch: a pack locale key its own reference lacks.
        for (ptags.items, 0..) |t, i| {
            if (std.ascii.eqlIgnoreCase(t, pref_tag)) continue;
            for (pparsed.items[i].entries) |e| {
                if (pack_ref.get(e.key) == null) {
                    std.debug.print("packs/{s}/locales/{s}.jsonc: key '{s}' is absent from the pack's reference ({s})\n", .{ pk.name, t, e.key, pref_tag });
                    had_error = true;
                }
            }
        }

        // Keyword-key lint over the pack's key space (its reference), with
        // the surfaced K.<pack>__<key> path a game call site would read.
        if (in.diagnostics) {
            for (try keywordKeyLints(arena, pack_ref.entries)) |l| {
                const surfaced = try std.fmt.allocPrint(arena, "{s}__{s}", .{ pk.name, l.key });
                std.debug.print("warning: i18n: packs/{s}/locales/{s}.jsonc: key '{s}': segment '{s}' is a Zig keyword, so call sites read K.{s} -- consider renaming the segment to '{s}_'\n", .{ pk.name, pref_tag, l.key, l.seg, try zig_keywords.quoteDottedPath(arena, surfaced), l.seg });
            }
        }

        // Map the pack's locales onto the game's tag set; warn about the rest.
        const by_tag = try arena.alloc(?locales_mod.Locale, in.game_tags.len);
        @memset(by_tag, null);
        for (ptags.items, 0..) |t, i| {
            var placed = false;
            for (in.game_tags, 0..) |gt, gi| {
                // Case-insensitive, like the generated runtime: a pack's
                // pt-br.jsonc maps onto the game's pt-BR.
                if (std.ascii.eqlIgnoreCase(t, gt)) {
                    by_tag[gi] = pparsed.items[i];
                    placed = true;
                }
            }
            if (!placed) {
                std.debug.print("warning: i18n: pack '{s}' ships locale '{s}', which this game does not offer -- ignored (the game's locales/ decides the language list)\n", .{ pk.name, t });
            }
        }

        try pack_data.append(arena, .{ .name = pk.name, .reference = pack_ref, .by_tag = by_tag });
    }
    if (had_error) return error.I18nInvalid;

    // Validate every game-side write under a pack namespace: override or
    // added-locale entry, it must name a key the pack defines.
    for (in.game_tags, 0..) |gt, gi| {
        for (in.game_parsed[gi].entries) |e| {
            const sep = std.mem.indexOf(u8, e.key, "__") orelse continue;
            const pack_name = e.key[0..sep];
            const rest = e.key[sep + 2 ..];
            var found_pack: ?*const PackData = null;
            for (pack_data.items) |*pd| {
                if (std.mem.eql(u8, pd.name, pack_name)) found_pack = pd;
            }
            const pd = found_pack orelse {
                std.debug.print("locales/{s}.jsonc: key '{s}' writes under pack namespace '{s}', but no pack of that name ships locales\n", .{ gt, e.key, pack_name });
                had_error = true;
                continue;
            };
            if (pd.reference.get(rest) == null) {
                std.debug.print("locales/{s}.jsonc: key '{s}' overrides nothing -- pack '{s}' does not define '{s}'. A typo here, or a key the pack renamed, would otherwise silently keep the pack's string\n", .{ gt, e.key, pack_name, rest });
                had_error = true;
            }
        }
    }
    if (had_error) return error.I18nInvalid;

    // Build the merged locales: game entries as-is (overrides included, they
    // win by being present), then each pack's contribution for that tag --
    // its own locale's strings where shipped, its reference's for the
    // reference slot's completeness. Backfill to the PACK reference happens
    // here by construction: the merged game-reference locale carries the pack
    // reference's string for every pack key the game did not override, and
    // the downstream table backfill fills other locales from it.
    const merged = try arena.alloc(locales_mod.Locale, in.game_tags.len);
    for (in.game_tags, 0..) |_, gi| {
        var entries: std.ArrayList(locales_mod.Entry) = .empty;
        try entries.appendSlice(arena, in.game_parsed[gi].entries);

        for (pack_data.items) |pd| {
            // The strings this tag gets from the pack: its shipped locale for
            // the tag, else (reference slot only) the pack reference. Other
            // tags stay absent and ride the rectangular-table backfill, which
            // now sources the pack's string via the merged reference.
            const contrib: ?locales_mod.Locale = pd.by_tag[gi] orelse
                (if (gi == in.reference_idx) pd.reference else null);
            const c = contrib orelse continue;
            for (c.entries) |pe| {
                // Only keys of the pack's key space (its reference) surface.
                if (pd.reference.get(pe.key) == null) continue;
                const prefixed = try std.fmt.allocPrint(arena, "{s}__{s}", .{ pd.name, pe.key });
                if (in.game_parsed[gi].get(prefixed) != null) continue; // game wins
                try entries.append(arena, .{ .key = prefixed, .value = pe.value });
            }
            // The reference slot must carry EVERY pack key, even ones the
            // pack's shipped locale for the reference tag is missing.
            if (gi == in.reference_idx) {
                for (pd.reference.entries) |pe| {
                    const prefixed = try std.fmt.allocPrint(arena, "{s}__{s}", .{ pd.name, pe.key });
                    var present = false;
                    for (entries.items) |e| {
                        if (std.mem.eql(u8, e.key, prefixed)) present = true;
                    }
                    if (!present) try entries.append(arena, .{ .key = prefixed, .value = pe.value });
                }
            }
        }

        std.mem.sort(locales_mod.Entry, entries.items, {}, struct {
            fn lessThan(_: void, a: locales_mod.Entry, b: locales_mod.Entry) bool {
                return std.mem.order(u8, a.key, b.key) == .lt;
            }
        }.lessThan);
        merged[gi] = .{ .entries = entries.items };
    }
    return merged;
}

/// One interpolated key's build-time data: its (sorted) placeholder set from
/// the reference, and one segment list per locale (backfilled slots reuse the
/// reference's segments, so parity trivially holds there).
const KeyInterp = struct {
    arg_names: []const []const u8,
    segs: []const []const interp.Segment,
};

fn emitModule(
    arena: Allocator,
    w: *std.Io.Writer,
    tags: []const []const u8,
    parsed: []const locales_mod.Locale,
    reference: locales_mod.Locale,
    reference_idx: usize,
    default_idx: usize,
    interps: []const ?KeyInterp,
) !void {
    _ = reference_idx;
    try w.writeAll("//! Generated by labelle-assembler from locales/*.jsonc -- do not edit.\n");
    try w.writeAll("//! The table is rectangular: gaps are backfilled with the reference\n");
    try w.writeAll("//! locale's string at build time, so no runtime path can fail and no\n");
    try w.writeAll("//! fallback code exists (RFC-I18N section 3.1 / 5).\n\n");

    // Key type: non-exhaustive u16 enum; K's constants are the only names.
    try w.writeAll("pub const Key = enum(u16) { _ };\n\n");

    // K: nested namespaces of typed constants, indices in sorted-key order
    // (deterministic -- RFC Open Question 3).
    try w.writeAll("pub const K = struct {\n");
    try emitKeyTree(w, reference.entries, 1);
    try w.writeAll("};\n\n");

    // Locale tags, sorted; index is the runtime locale index.
    try w.writeAll("const tags = [_][:0]const u8{");
    for (tags, 0..) |t, i| {
        if (i != 0) try w.writeAll(", ");
        try w.writeAll("\"");
        try writeEscaped(w, t);
        try w.writeAll("\"");
    }
    try w.writeAll("};\n\n");

    // The rectangular table: [locale][key], reference string where a locale
    // has no translation. Plain keys emit the DECODED text -- a string like
    // "Set {{name}}" carries escaped braces that t() would otherwise show
    // doubled; the parsed segments already resolved them, and a plain key's
    // segments are all literals. Interpolated keys keep the raw string: t()
    // refuses them at comptime and tf() reads segments, so their table rows
    // are inert.
    try w.print("const table = [{d}][{d}][:0]const u8{{\n", .{ tags.len, reference.entries.len });
    for (tags, 0..) |tag, li| {
        try w.print("    // {s}\n", .{tag});
        try w.writeAll("    .{\n");
        for (reference.entries, 0..) |re, ki| {
            try w.writeAll("        \"");
            if (interps[ki] == null) {
                // Decoded: concatenate the literal segments of this locale's
                // own string (or the reference's, for a backfilled slot).
                const raw = parsed[li].get(re.key) orelse re.value;
                switch (try interp.parse(arena, raw)) {
                    // Validated earlier; a parse failure here cannot happen.
                    .fail => try writeEscaped(w, raw),
                    .ok => |segs| for (segs) |seg| switch (seg) {
                        .lit => |l| try writeEscaped(w, l),
                        .arg => {},
                    },
                }
            } else {
                const s = parsed[li].get(re.key) orelse re.value;
                try writeEscaped(w, s);
            }
            try w.writeAll("\",\n");
        }
        try w.writeAll("    },\n");
    }
    try w.writeAll("};\n\n");

    try w.print("var active: usize = {d}; // i18n.default\n\n", .{default_idx});

    // Interpolation (§4): per-(key, locale) segment lists. The string is
    // chosen at runtime by the active locale while the arguments are
    // comptime, so a comptime format string from the reference would render
    // every reordering locale wrong -- tf walks the active locale's segments
    // instead.
    try w.writeAll("const Seg = union(enum) { lit: []const u8, arg: []const u8 };\n\n");
    for (interps, 0..) |maybe, ki| {
        const inter = maybe orelse continue;
        for (inter.segs, 0..) |segs, li| {
            try w.print("const segs_{d}_{d} = [_]Seg{{ ", .{ ki, li });
            for (segs, 0..) |seg, si| {
                if (si != 0) try w.writeAll(", ");
                switch (seg) {
                    .lit => |l| {
                        try w.writeAll(".{ .lit = \"");
                        try writeEscaped(w, l);
                        try w.writeAll("\" }");
                    },
                    .arg => |n| {
                        try w.writeAll(".{ .arg = \"");
                        try writeEscaped(w, n);
                        try w.writeAll("\" }");
                    },
                }
            }
            try w.writeAll(" };\n");
        }
    }
    try w.writeByte('\n');

    // Two comptime-indexed tables drive t/tf's guards and tf's walk. null =
    // a plain key: t-only.
    try w.print("const interp_names = [{d}]?[]const []const u8{{\n", .{reference.entries.len});
    for (interps) |maybe| {
        if (maybe) |inter| {
            try w.writeAll("    &[_][]const u8{ ");
            for (inter.arg_names, 0..) |n, i| {
                if (i != 0) try w.writeAll(", ");
                try w.writeAll("\"");
                try writeEscaped(w, n);
                try w.writeAll("\"");
            }
            try w.writeAll(" },\n");
        } else {
            try w.writeAll("    null,\n");
        }
    }
    try w.writeAll("};\n\n");

    try w.print("const interp_segs = [{d}]?[{d}][]const Seg{{\n", .{ reference.entries.len, tags.len });
    for (interps, 0..) |maybe, ki| {
        if (maybe != null) {
            try w.writeAll("    .{ ");
            for (0..tags.len) |li| {
                if (li != 0) try w.writeAll(", ");
                try w.print("&segs_{d}_{d}", .{ ki, li });
            }
            try w.writeAll(" },\n");
        } else {
            try w.writeAll("    null,\n");
        }
    }
    try w.writeAll("};\n\n");

    try w.writeAll(
        \\// ---- LABELLE_LOCALE (RFC-I18N section 8, startup resolution) --------
        \\// The dev/CI override is applied by the module itself, lazily, on the
        \\// first lookup -- no generated-main wiring, and it works identically
        \\// under every lifecycle style. An explicit setLocale() before the
        \\// first lookup wins over the env var: a live choice outranks a dev
        \\// knob. Same getenv pattern as labelle-engine's runtime_env.zig --
        \\// comptime-guarded so libc-less targets (wasm/wasi) compile the
        \\// return-early branch only.
        \\var env_checked = false;
        \\
        \\fn ensureEnvLocale() void {
        \\    if (env_checked) return;
        \\    env_checked = true;
        \\    if (comptime builtin.os.tag == .wasi or !builtin.link_libc) return;
        \\    const raw = std.c.getenv("LABELLE_LOCALE") orelse return;
        \\    const val = std.mem.span(raw);
        \\    if (val.len == 0) return;
        \\    // Unknown tags are ignored, never an error: a leaked dev var must
        \\    // not be able to break a player's run. BCP-47 tags are
        \\    // case-insensitive, so pt-br finds pt-BR.
        \\    for (tags, 0..) |t_, i| {
        \\        if (std.ascii.eqlIgnoreCase(t_, val)) active = i;
        \\    }
        \\}
        \\
        \\/// The translated string for a key, in the active locale. Zero-cost
        \\/// after the first call: a table lookup with a comptime index, no
        \\/// allocation, no failure path. The sentinel means it hands directly
        \\/// to cimgui.
        \\pub fn t(comptime key: Key) [:0]const u8 {
        \\    comptime if (interp_names[@intFromEnum(key)] != null)
        \\        @compileError("this key has placeholders; use tf(key, .{...})");
        \\    ensureEnvLocale();
        \\    return table[active][@intFromEnum(key)];
        \\}
        \\
        \\/// The translated string with its placeholders filled. The argument
        \\/// struct is checked at compile time against the key's placeholder
        \\/// set: a missing argument, a misnamed one, or calling this on a key
        \\/// with no placeholders is a compile error.
        \\///
        \\/// The result lives in a module-owned ring buffer and is valid until
        \\/// the buffer wraps -- render it this frame, never store it in a
        \\/// component. Call resetFrameArena() once per frame to make the
        \\/// lifetime exact.
        \\pub fn tf(comptime key: Key, args: anytype) [:0]const u8 {
        \\    ensureEnvLocale();
        \\    const idx = comptime @intFromEnum(key);
        \\    const arg_names = comptime (interp_names[idx] orelse
        \\        @compileError("this key has no placeholders; use t(key)"));
        \\    comptime {
        \\        const fields = @typeInfo(@TypeOf(args)).@"struct".fields;
        \\        for (arg_names) |n| {
        \\            var found = false;
        \\            for (fields) |f| {
        \\                if (std.mem.eql(u8, f.name, n)) found = true;
        \\            }
        \\            if (!found) @compileError("tf: missing argument '" ++ n ++ "'");
        \\        }
        \\        for (fields) |f| {
        \\            var found = false;
        \\            for (arg_names) |n| {
        \\                if (std.mem.eql(u8, n, f.name)) found = true;
        \\            }
        \\            if (!found) @compileError("tf: no placeholder named '" ++ f.name ++ "'");
        \\        }
        \\    }
        \\    const segs = interp_segs[idx].?[active];
        \\    // Wrap only BETWEEN results. Wrapping mid-result would invalidate
        \\    // the captured start -- a reversed slice at best, bytes of some
        \\    // unrelated earlier string at worst.
        \\    if (frame_buf.len - frame_len < WRAP_RESERVE) frame_len = 0;
        \\    const start = frame_len;
        \\    for (segs) |seg| switch (seg) {
        \\        .lit => |l| appendBytes(l),
        \\        .arg => |name| {
        \\            inline for (@typeInfo(@TypeOf(args)).@"struct".fields) |f| {
        \\                if (std.mem.eql(u8, f.name, name)) appendValue(@field(args, f.name));
        \\            }
        \\        },
        \\    };
        \\    // appendBytes never writes the last byte, so the sentinel always
        \\    // has a home and frame_len never moves backwards mid-result.
        \\    frame_buf[frame_len] = 0;
        \\    const result = frame_buf[start..frame_len :0];
        \\    frame_len += 1;
        \\    return result;
        \\}
        \\
        \\// ---- the ring the tf results live in --------------------------------
        \\// Module-owned, so no wiring is required to use tf; resetFrameArena()
        \\// exists for the engine's frame loop to make the lifetime exact
        \\// (RFC-I18N Open Question 1 -- resolved as module-owned for now).
        \\// A result that outgrows the remaining space is TRUNCATED, never
        \\// wrapped and never an error: UI text is consumed the same frame, and
        \\// a cut label beats a crashed game.
        \\var frame_buf: [16384]u8 = undefined;
        \\var frame_len: usize = 0;
        \\const WRAP_RESERVE = 1024;
        \\
        \\pub fn resetFrameArena() void {
        \\    frame_len = 0;
        \\}
        \\
        \\fn appendBytes(bytes: []const u8) void {
        \\    // Truncating copy; the last byte stays free for tf's sentinel.
        \\    const room = frame_buf.len - 1 - frame_len;
        \\    const n = @min(bytes.len, room);
        \\    @memcpy(frame_buf[frame_len..][0..n], bytes[0..n]);
        \\    frame_len += n;
        \\}
        \\
        \\fn appendValue(v: anytype) void {
        \\    const T = @TypeOf(v);
        \\    const info = @typeInfo(T);
        \\    if (comptime isStringLike(T)) {
        \\        appendBytes(v);
        \\    } else switch (info) {
        \\        .int, .comptime_int => {
        \\            var buf: [48]u8 = undefined; // i128 needs 40 digits
        \\            appendBytes(std.fmt.bufPrint(&buf, "{d}", .{v}) catch "?");
        \\        },
        \\        .float, .comptime_float => {
        \\            var buf: [64]u8 = undefined;
        \\            appendBytes(std.fmt.bufPrint(&buf, "{d}", .{v}) catch "?");
        \\        },
        \\        .bool => appendBytes(if (v) "true" else "false"),
        \\        .@"enum" => appendBytes(@tagName(v)),
        \\        else => @compileError("tf: unsupported argument type " ++ @typeName(T) ++
        \\            " -- pass a string, integer, float, bool or enum"),
        \\    }
        \\}
        \\
        \\fn isStringLike(comptime T: type) bool {
        \\    const info = @typeInfo(T);
        \\    if (info != .pointer) return false;
        \\    const p = info.pointer;
        \\    if (p.size == .slice) return p.child == u8;
        \\    if (p.size == .one) {
        \\        const c = @typeInfo(p.child);
        \\        return c == .array and c.array.child == u8;
        \\    }
        \\    return false;
        \\}
        \\
        \\/// Switches the active locale. Returns false (and changes nothing)
        \\/// for a tag no locale file declared. An explicit call also settles
        \\/// the LABELLE_LOCALE question: a live choice outranks the dev knob,
        \\/// so the lazy env check will not overwrite this later.
        \\pub fn setLocale(tag: []const u8) bool {
        \\    // BCP-47 tags are case-insensitive: pt-br switches to pt-BR.
        \\    for (tags, 0..) |t_, i| {
        \\        if (std.ascii.eqlIgnoreCase(t_, tag)) {
        \\            active = i;
        \\            // Only a SUCCESSFUL explicit choice settles the env
        \\            // question -- a rejected tag "changes nothing", and that
        \\            // must include not eating the LABELLE_LOCALE fallback.
        \\            env_checked = true;
        \\            return true;
        \\        }
        \\    }
        \\    return false;
        \\}
        \\
        \\pub fn activeLocale() [:0]const u8 {
        \\    ensureEnvLocale();
        \\    return tags[active];
        \\}
        \\
        \\/// Every locale this build carries, for the Options selector.
        \\pub fn locales() []const [:0]const u8 {
        \\    return &tags;
        \\}
        \\
        \\/// Manual override hook: pass a tag (or null) to apply an externally
        \\/// read LABELLE_LOCALE value. Rarely needed now that the module reads
        \\/// the env var itself (ensureEnvLocale); kept for hosts without libc
        \\/// where the game reads its environment some other way. Unknown tags
        \\/// are ignored -- a leaked dev var must not break a player's run.
        \\pub fn initFromEnvValue(v: ?[]const u8) void {
        \\    if (v) |tag| _ = setLocale(tag);
        \\}
        \\
        \\const std = @import("std");
        \\const builtin = @import("builtin");
        \\
    );
}

/// Emits the nested K namespaces. Entries are sorted by dotted key, which
/// groups shared prefixes contiguously, so a single pass with a segment stack
/// suffices. Every declaration is @""-quoted so a key named like a Zig
/// keyword ("error", "test") still generates.
fn emitKeyTree(w: *std.Io.Writer, entries: []const locales_mod.Entry, base_depth: usize) !void {
    var stack: [16][]const u8 = undefined;
    var depth: usize = 0;

    for (entries, 0..) |e, idx| {
        // Split the key into segments.
        var segs: [16][]const u8 = undefined;
        var n: usize = 0;
        var it = std.mem.splitScalar(u8, e.key, '.');
        while (it.next()) |seg| {
            segs[n] = seg;
            n += 1;
        }

        // Find common prefix length with the open stack.
        var common: usize = 0;
        while (common < depth and common < n - 1 and std.mem.eql(u8, stack[common], segs[common])) common += 1;

        // Close namespaces below the common prefix.
        while (depth > common) {
            depth -= 1;
            try writeIndent(w, base_depth + depth);
            try w.writeAll("};\n");
        }
        // Open namespaces down to the leaf's parent.
        while (depth < n - 1) {
            try writeIndent(w, base_depth + depth);
            try w.print("pub const @\"{s}\" = struct {{\n", .{segs[depth]});
            stack[depth] = segs[depth];
            depth += 1;
        }
        // The leaf.
        try writeIndent(w, base_depth + depth);
        try w.print("pub const @\"{s}\": Key = @enumFromInt({d});\n", .{ segs[n - 1], idx });
    }
    while (depth > 0) {
        depth -= 1;
        try writeIndent(w, base_depth + depth);
        try w.writeAll("};\n");
    }
}

fn writeIndent(w: *std.Io.Writer, depth: usize) !void {
    var i: usize = 0;
    while (i < depth) : (i += 1) try w.writeAll("    ");
}

fn writeEscaped(w: *std.Io.Writer, s: []const u8) !void {
    for (s) |c| switch (c) {
        '\\' => try w.writeAll("\\\\"),
        '"' => try w.writeAll("\\\""),
        '\n' => try w.writeAll("\\n"),
        '\t' => try w.writeAll("\\t"),
        '\r' => try w.writeAll("\\r"),
        else => {
            // JSON's backslash-u escapes decode to raw control bytes, which
            // cannot sit inside a Zig string literal (and a NUL would corrupt
            // the [:0] sentinel). \xNN keeps the generated file compiling.
            if (c < 0x20 or c == 0x7F) {
                try w.print("\\x{x:0>2}", .{c});
            } else {
                try w.writeByte(c);
            }
        },
    };
}

/// Same walk constants_phase uses; kept separate so each phase stays
/// standalone-testable. Skips generated and vendored trees.
const skip_dirs = [_][]const u8{ ".labelle", ".git", "deps", "zig-out", "zig-cache", ".zig-cache" };

fn collectMarks(arena: Allocator, marks: *usage.Marks, dir_path: []const u8) !void {
    const io = phaseIo();
    const cwd = std.Io.Dir.cwd();
    var dir = cwd.openDir(io, dir_path, .{ .iterate = true }) catch {
        // An unopenable tree could hold uses. An empty mark set here means
        // every key reads as unused (warning spam, or missed strict
        // coverage) -- widen instead, the one safe direction.
        marks.all = true;
        return;
    };
    defer dir.close(io);

    var iter = dir.iterate();
    while (iter.next(io) catch blk: {
        marks.all = true; // aborted iteration may hide uses; widen, never warn falsely
        break :blk null;
    }) |entry| {
        switch (entry.kind) {
            .directory => {
                var skip = false;
                for (skip_dirs) |d| {
                    if (std.mem.eql(u8, entry.name, d)) skip = true;
                }
                if (skip) continue;
                const sub = try std.fs.path.join(arena, &.{ dir_path, entry.name });
                try collectMarks(arena, marks, sub);
            },
            .file => {
                if (!std.mem.endsWith(u8, entry.name, ".zig")) continue;
                const source = dir.readFileAlloc(io, entry.name, arena, .limited(4 * 1024 * 1024)) catch {
                    marks.all = true; // unreadable file may hold uses; widen
                    continue;
                };
                try usage.scanSource(marks, .{ .module_name = "i18n", .root_symbol = "K" }, source);
            },
            else => {},
        }
    }
}

// ---------------------------------------------------------------------------
// tests
// ---------------------------------------------------------------------------

const testing = std.testing;

fn tmpPaths(tmp: *std.testing.TmpDir, alloc: Allocator) !struct { game: []const u8, target: []const u8 } {
    var rel_buf: [96]u8 = undefined;
    const rel = try std.fmt.bufPrint(&rel_buf, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
    return .{
        .game = try std.fs.path.join(alloc, &.{ rel, "game" }),
        .target = try std.fs.path.join(alloc, &.{ rel, "target" }),
    };
}

test "no locales dir: nothing emitted, stale file cleaned" {
    const io = phaseIo();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "game");
    try tmp.dir.createDirPath(io, "target");
    try tmp.dir.writeFile(io, .{ .sub_path = "target/" ++ GENERATED_FILENAME, .data = "// stale\n" });

    const p = try tmpPaths(&tmp, testing.allocator);
    defer testing.allocator.free(p.game);
    defer testing.allocator.free(p.target);

    try testing.expectEqual(false, try runPhase(testing.allocator, p.game, p.target, null, &.{}, true));
    try testing.expectError(error.FileNotFound, tmp.dir.openFile(io, "target/" ++ GENERATED_FILENAME, .{}));
}

test "locales without .i18n.default is an error" {
    const io = phaseIo();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "game/locales");
    try tmp.dir.createDirPath(io, "target");
    try tmp.dir.writeFile(io, .{ .sub_path = "game/locales/en.jsonc", .data = "{ \"menu\": { \"play\": \"Play\" } }" });

    const p = try tmpPaths(&tmp, testing.allocator);
    defer testing.allocator.free(p.game);
    defer testing.allocator.free(p.target);

    try testing.expectError(error.I18nInvalid, runPhase(testing.allocator, p.game, p.target, null, &.{}, true));
}

test "default naming no file is an error; a key absent from the reference is an error" {
    const io = phaseIo();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "game/locales");
    try tmp.dir.createDirPath(io, "target");
    try tmp.dir.writeFile(io, .{ .sub_path = "game/locales/en.jsonc", .data = "{ \"menu\": { \"play\": \"Play\" } }" });
    try tmp.dir.writeFile(io, .{ .sub_path = "game/locales/pt.jsonc", .data = "{ \"menu\": { \"play\": \"Jogar\", \"quit\": \"Sair\" } }" });

    const p = try tmpPaths(&tmp, testing.allocator);
    defer testing.allocator.free(p.game);
    defer testing.allocator.free(p.target);

    // BCP-47 typo shape: pt_BR for a file that does not exist.
    try testing.expectError(error.I18nInvalid, runPhase(testing.allocator, p.game, p.target, .{ .default = "pt_BR" }, &.{}, true));
    // pt has menu.quit which en (the reference) lacks -- the rename catch.
    try testing.expectError(error.I18nInvalid, runPhase(testing.allocator, p.game, p.target, .{ .default = "en" }, &.{}, true));
}

test "emission: K tree, rectangular backfilled table, default index" {
    const io = phaseIo();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "game/locales");
    try tmp.dir.createDirPath(io, "target");
    try tmp.dir.writeFile(io, .{ .sub_path = "game/locales/en.jsonc", .data = "{ \"menu\": { \"play\": \"Play\", \"quit\": \"Quit\" }, \"hud\": { \"stock\": \"Stock\" } }" });
    // pt is missing hud.stock -- it must be backfilled with en's string.
    try tmp.dir.writeFile(io, .{ .sub_path = "game/locales/pt-BR.jsonc", .data = "{ \"menu\": { \"play\": \"Jogar\", \"quit\": \"Sair\" } }" });

    const p = try tmpPaths(&tmp, testing.allocator);
    defer testing.allocator.free(p.game);
    defer testing.allocator.free(p.target);

    try testing.expectEqual(true, try runPhase(testing.allocator, p.game, p.target, .{ .default = "pt-BR", .reference = "en" }, &.{}, true));

    const generated = try tmp.dir.readFileAlloc(io, "target/" ++ GENERATED_FILENAME, testing.allocator, .limited(256 * 1024));
    defer testing.allocator.free(generated);

    // Keys sorted: hud.stock=0, menu.play=1, menu.quit=2.
    try testing.expect(std.mem.indexOf(u8, generated, "pub const @\"stock\": Key = @enumFromInt(0);") != null);
    try testing.expect(std.mem.indexOf(u8, generated, "pub const @\"play\": Key = @enumFromInt(1);") != null);
    // en sorts before pt-BR; default (pt-BR) is index 1.
    try testing.expect(std.mem.indexOf(u8, generated, "var active: usize = 1;") != null);
    // The pt-BR row backfills hud.stock with en's "Stock".
    const pt_row = std.mem.indexOf(u8, generated, "// pt-BR").?;
    try testing.expect(std.mem.indexOfPos(u8, generated, pt_row, "\"Stock\"") != null);
    try testing.expect(std.mem.indexOf(u8, generated, "\"Jogar\"") != null);

    // Structurally valid Zig.
    const src_z = try testing.allocator.dupeZ(u8, generated);
    defer testing.allocator.free(src_z);
    var ast = try std.zig.Ast.parse(testing.allocator, src_z, .zig);
    defer ast.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 0), ast.errors.len);
}

test "phase 2: reordered placeholders pass parity and emit per-locale segments" {
    const io = phaseIo();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "game/locales");
    try tmp.dir.createDirPath(io, "target");
    try tmp.dir.writeFile(io, .{ .sub_path = "game/locales/en.jsonc", .data = "{ \"hud\": { \"stock\": \"{count} of {max} items\" } }" });
    // German reorders -- same set, different order. Legitimate translation.
    try tmp.dir.writeFile(io, .{ .sub_path = "game/locales/de.jsonc", .data = "{ \"hud\": { \"stock\": \"Von {max} Artikeln: {count}\" } }" });

    const p = try tmpPaths(&tmp, testing.allocator);
    defer testing.allocator.free(p.game);
    defer testing.allocator.free(p.target);

    try testing.expectEqual(true, try runPhase(testing.allocator, p.game, p.target, .{ .default = "en" }, &.{}, true));

    const generated = try tmp.dir.readFileAlloc(io, "target/" ++ GENERATED_FILENAME, testing.allocator, .limited(256 * 1024));
    defer testing.allocator.free(generated);

    // Both locales carry their own segment order.
    try testing.expect(std.mem.indexOf(u8, generated, ".{ .arg = \"count\" }, .{ .lit = \" of \" }") != null);
    try testing.expect(std.mem.indexOf(u8, generated, ".{ .lit = \"Von \" }, .{ .arg = \"max\" }") != null);
    try testing.expect(std.mem.indexOf(u8, generated, "pub fn tf(") != null);

    const src_z = try testing.allocator.dupeZ(u8, generated);
    defer testing.allocator.free(src_z);
    var ast = try std.zig.Ast.parse(testing.allocator, src_z, .zig);
    defer ast.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 0), ast.errors.len);
}

test "phase 2: a differing placeholder set is a build error showing both sets" {
    const io = phaseIo();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "game/locales");
    try tmp.dir.createDirPath(io, "target");
    try tmp.dir.writeFile(io, .{ .sub_path = "game/locales/en.jsonc", .data = "{ \"hud\": { \"stock\": \"{count} of {max}\" } }" });
    // pt drops {count} -- drift, not translation.
    try tmp.dir.writeFile(io, .{ .sub_path = "game/locales/pt.jsonc", .data = "{ \"hud\": { \"stock\": \"{max} itens\" } }" });

    const p = try tmpPaths(&tmp, testing.allocator);
    defer testing.allocator.free(p.game);
    defer testing.allocator.free(p.target);

    try testing.expectError(error.I18nInvalid, runPhase(testing.allocator, p.game, p.target, .{ .default = "en" }, &.{}, true));
}

test "phase 2: a brace-syntax error in any locale names the locale and key" {
    const io = phaseIo();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "game/locales");
    try tmp.dir.createDirPath(io, "target");
    try tmp.dir.writeFile(io, .{ .sub_path = "game/locales/en.jsonc", .data = "{ \"hud\": { \"pct\": \"100{ done\" } }" });

    const p = try tmpPaths(&tmp, testing.allocator);
    defer testing.allocator.free(p.game);
    defer testing.allocator.free(p.target);

    try testing.expectError(error.I18nInvalid, runPhase(testing.allocator, p.game, p.target, .{ .default = "en" }, &.{}, true));
}

test "phase 3: pack keys surface prefixed; the game overrides and adds; backfill is the pack's reference" {
    const io = phaseIo();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "game/locales");
    try tmp.dir.createDirPath(io, "thepack/locales");
    try tmp.dir.createDirPath(io, "target");

    // The game ships en (reference) and pt. The pack ships en and fr.
    try tmp.dir.writeFile(io, .{ .sub_path = "game/locales/en.jsonc", .data = "{ \"menu\": { \"play\": \"Play\" }, \"citizens__hunger\": { \"starving\": \"Starving!\" } }" });
    try tmp.dir.writeFile(io, .{ .sub_path = "game/locales/pt.jsonc", .data = "{ \"menu\": { \"play\": \"Jogar\" }, \"citizens__hunger\": { \"starving\": \"Faminto!\" } }" });
    try tmp.dir.writeFile(io, .{ .sub_path = "thepack/locales/en.jsonc", .data = "{ \"hunger\": { \"starving\": \"Hungry\", \"fed\": \"Fed\" } }" });
    try tmp.dir.writeFile(io, .{ .sub_path = "thepack/locales/fr.jsonc", .data = "{ \"hunger\": { \"starving\": \"Affame\" } }" });

    var rel_buf: [96]u8 = undefined;
    const rel = try std.fmt.bufPrint(&rel_buf, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
    const game = try std.fs.path.join(testing.allocator, &.{ rel, "game" });
    defer testing.allocator.free(game);
    const target = try std.fs.path.join(testing.allocator, &.{ rel, "target" });
    defer testing.allocator.free(target);
    const pack_dir = try std.fs.path.join(testing.allocator, &.{ rel, "thepack" });
    defer testing.allocator.free(pack_dir);

    const packs = [_]PackLocales{.{ .name = "citizens", .src_dir = pack_dir }};
    try testing.expectEqual(true, try runPhase(testing.allocator, game, target, .{ .default = "en" }, &packs, true));

    const generated = try tmp.dir.readFileAlloc(io, "target/" ++ GENERATED_FILENAME, testing.allocator, .limited(256 * 1024));
    defer testing.allocator.free(generated);

    // The pack's namespace exists, prefixed.
    try testing.expect(std.mem.indexOf(u8, generated, "pub const @\"citizens__hunger\" = struct {") != null);
    // The game's en override wins over the pack's en.
    try testing.expect(std.mem.indexOf(u8, generated, "\"Starving!\"") != null);
    try testing.expect(std.mem.indexOf(u8, generated, "\"Hungry\"") == null);
    // The game ADDED pt for a pack that never shipped it.
    try testing.expect(std.mem.indexOf(u8, generated, "\"Faminto!\"") != null);
    // hunger.fed: overridden nowhere, pt lacks it -> backfilled from the
    // pack's reference ("Fed") in every row.
    try testing.expect(std.mem.indexOf(u8, generated, "\"Fed\"") != null);
    // fr is pack-only: warned, not shipped.
    try testing.expect(std.mem.indexOf(u8, generated, "\"fr\"") == null);
    try testing.expect(std.mem.indexOf(u8, generated, "Affame") == null);

    const src_z = try testing.allocator.dupeZ(u8, generated);
    defer testing.allocator.free(src_z);
    var ast = try std.zig.Ast.parse(testing.allocator, src_z, .zig);
    defer ast.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 0), ast.errors.len);
}

test "phase 3: writing under a pack namespace asserts the key exists" {
    const io = phaseIo();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "game/locales");
    try tmp.dir.createDirPath(io, "thepack/locales");
    try tmp.dir.createDirPath(io, "target");
    try tmp.dir.writeFile(io, .{ .sub_path = "game/locales/en.jsonc", .data = "{ \"citizens__hunger\": { \"starvng\": \"typo\" } }" });
    try tmp.dir.writeFile(io, .{ .sub_path = "thepack/locales/en.jsonc", .data = "{ \"hunger\": { \"starving\": \"Hungry\" } }" });

    var rel_buf: [96]u8 = undefined;
    const rel = try std.fmt.bufPrint(&rel_buf, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
    const game = try std.fs.path.join(testing.allocator, &.{ rel, "game" });
    defer testing.allocator.free(game);
    const target = try std.fs.path.join(testing.allocator, &.{ rel, "target" });
    defer testing.allocator.free(target);
    const pack_dir = try std.fs.path.join(testing.allocator, &.{ rel, "thepack" });
    defer testing.allocator.free(pack_dir);

    const packs = [_]PackLocales{.{ .name = "citizens", .src_dir = pack_dir }};
    try testing.expectError(error.I18nInvalid, runPhase(testing.allocator, game, target, .{ .default = "en" }, &packs, true));
}

test "phase 3: a declared pack reference with no file is an error; a pack-locale key outside its reference is an error" {
    const io = phaseIo();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "game/locales");
    try tmp.dir.createDirPath(io, "thepack/locales");
    try tmp.dir.createDirPath(io, "target");
    try tmp.dir.writeFile(io, .{ .sub_path = "game/locales/en.jsonc", .data = "{ \"menu\": { \"play\": \"Play\" } }" });
    try tmp.dir.writeFile(io, .{ .sub_path = "thepack/locales/en.jsonc", .data = "{ \"hunger\": { \"starving\": \"Hungry\" } }" });

    var rel_buf: [96]u8 = undefined;
    const rel = try std.fmt.bufPrint(&rel_buf, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
    const game = try std.fs.path.join(testing.allocator, &.{ rel, "game" });
    defer testing.allocator.free(game);
    const target = try std.fs.path.join(testing.allocator, &.{ rel, "target" });
    defer testing.allocator.free(target);
    const pack_dir = try std.fs.path.join(testing.allocator, &.{ rel, "thepack" });
    defer testing.allocator.free(pack_dir);

    // Declared reference "de" has no file in the pack.
    const bad_ref = [_]PackLocales{.{ .name = "citizens", .src_dir = pack_dir, .reference = "de" }};
    try testing.expectError(error.I18nInvalid, runPhase(testing.allocator, game, target, .{ .default = "en" }, &bad_ref, true));

    // A pack fr key its own reference lacks: per-realm rename catch.
    try tmp.dir.writeFile(io, .{ .sub_path = "thepack/locales/fr.jsonc", .data = "{ \"hunger\": { \"renamed_key\": \"x\" } }" });
    const packs = [_]PackLocales{.{ .name = "citizens", .src_dir = pack_dir }};
    try testing.expectError(error.I18nInvalid, runPhase(testing.allocator, game, target, .{ .default = "en" }, &packs, true));
}

test "keyword-key lint: fires on keyword segments, silent on clean and @''-renamed keys" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const entries = [_]locales_mod.Entry{
        .{ .key = "error.title", .value = "Oops" },
        .{ .key = "hud.gold", .value = "Gold" },
        .{ .key = "menu.new_game", .value = "New Game" },
        .{ .key = "pause.resume", .value = "Resume" },
        // The rename the lint suggests, and FP's actual fix: both clean.
        .{ .key = "pause.resume_", .value = "Resume" },
        .{ .key = "pause.resume_game", .value = "Resume" },
    };
    const lints = try keywordKeyLints(arena, &entries);
    try testing.expectEqual(@as(usize, 2), lints.len);
    try testing.expectEqualStrings("error.title", lints[0].key);
    try testing.expectEqualStrings("error", lints[0].seg);
    try testing.expectEqualStrings("pause.resume", lints[1].key);
    try testing.expectEqualStrings("resume", lints[1].seg);
}

test "a keyword key warns but still generates, @\"\"-quoted" {
    const io = phaseIo();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "game/locales");
    try tmp.dir.createDirPath(io, "target");
    // FP's exact friction shape: pause.resume (flying-platform#786 #2).
    try tmp.dir.writeFile(io, .{ .sub_path = "game/locales/en.jsonc", .data = "{ \"pause\": { \"resume\": \"Resume\" } }" });

    const p = try tmpPaths(&tmp, testing.allocator);
    defer testing.allocator.free(p.game);
    defer testing.allocator.free(p.target);

    try testing.expectEqual(true, try runPhase(testing.allocator, p.game, p.target, .{ .default = "en" }, &.{}, true));

    const generated = try tmp.dir.readFileAlloc(io, "target/" ++ GENERATED_FILENAME, testing.allocator, .limited(256 * 1024));
    defer testing.allocator.free(generated);
    try testing.expect(std.mem.indexOf(u8, generated, "pub const @\"resume\": Key = @enumFromInt(0);") != null);

    const src_z = try testing.allocator.dupeZ(u8, generated);
    defer testing.allocator.free(src_z);
    var ast = try std.zig.Ast.parse(testing.allocator, src_z, .zig);
    defer ast.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 0), ast.errors.len);
}

test "t/tf keep the [:0] sentinel contract (flying-platform#786 friction #3)" {
    // The cimgui hand-off: call sites pass t(...).ptr / tf(...).ptr straight
    // to C, so the emitted signatures and table type must stay sentinel-
    // terminated. #656 shipped this; the asserts pin it. The compile-and-run
    // proof lives in test/i18n_sentinel_tests.zig -- this is the cheap
    // text-level lock next to the emitter it guards.
    const io = phaseIo();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "game/locales");
    try tmp.dir.createDirPath(io, "target");
    try tmp.dir.writeFile(io, .{ .sub_path = "game/locales/en.jsonc", .data = "{ \"menu\": { \"play\": \"Play\" }, \"hud\": { \"stock\": \"{count} of {max}\" } }" });

    const p = try tmpPaths(&tmp, testing.allocator);
    defer testing.allocator.free(p.game);
    defer testing.allocator.free(p.target);

    try testing.expectEqual(true, try runPhase(testing.allocator, p.game, p.target, .{ .default = "en" }, &.{}, true));

    const generated = try tmp.dir.readFileAlloc(io, "target/" ++ GENERATED_FILENAME, testing.allocator, .limited(256 * 1024));
    defer testing.allocator.free(generated);

    try testing.expect(std.mem.indexOf(u8, generated, "pub fn t(comptime key: Key) [:0]const u8 {") != null);
    try testing.expect(std.mem.indexOf(u8, generated, "pub fn tf(comptime key: Key, args: anytype) [:0]const u8 {") != null);
    // The static table is sentinel-typed (string literals carry the NUL)...
    try testing.expect(std.mem.indexOf(u8, generated, "const table = [1][2][:0]const u8{") != null);
    // ...and the tf ring writes one before handing the slice out.
    try testing.expect(std.mem.indexOf(u8, generated, "frame_buf[frame_len] = 0;") != null);
    try testing.expect(std.mem.indexOf(u8, generated, "frame_buf[start..frame_len :0]") != null);
}

test "strict: a used key missing from a locale fails the build" {
    const io = phaseIo();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "game/locales");
    try tmp.dir.createDirPath(io, "game/scripts");
    try tmp.dir.createDirPath(io, "target");
    try tmp.dir.writeFile(io, .{ .sub_path = "game/locales/en.jsonc", .data = "{ \"menu\": { \"play\": \"Play\" }, \"hud\": { \"gold\": \"Gold\" } }" });
    try tmp.dir.writeFile(io, .{ .sub_path = "game/locales/pt.jsonc", .data = "{ \"menu\": { \"play\": \"Jogar\" } }" });
    // The game renders hud.gold, which pt lacks.
    try tmp.dir.writeFile(io, .{
        .sub_path = "game/scripts/ui.zig",
        .data = "const K = @import(\"i18n\").K;\npub fn f() void { _ = K.hud.gold; }\n",
    });

    const p = try tmpPaths(&tmp, testing.allocator);
    defer testing.allocator.free(p.game);
    defer testing.allocator.free(p.target);

    // Non-strict: warns, emits.
    try testing.expectEqual(true, try runPhase(testing.allocator, p.game, p.target, .{ .default = "en" }, &.{}, true));
    // Strict: the same gap is a build error.
    try testing.expectError(error.I18nInvalid, runPhase(testing.allocator, p.game, p.target, .{ .default = "en", .strict = true }, &.{}, true));
}
