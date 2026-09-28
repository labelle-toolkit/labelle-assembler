//! `labelle-assembler upgrade backend [version]` — bump the backend
//! provider pin in `project.labelle` (labelle-cli RFC #471, item D2).
//!
//! ## What it writes
//!
//! * An explicit `.backend_package` — its `.version` string is rewritten in
//!   place (or inserted, when the package omits it). Nothing else in the
//!   file changes: comments, ordering, spacing and every other field keep
//!   their bytes.
//! * The `.backend = .<tag>` shorthand (or no `.backend` at all, which is
//!   the `default_backend`) — the shorthand CANNOT carry a version: it
//!   resolves through `builtinProvider`, i.e. it always tracks THIS
//!   assembler's default. So:
//!     - no version, or the default version → nothing is written; the
//!       shorthand already resolves to it, and writing an explicit package
//!       would freeze a pin the shorthand would otherwise keep current;
//!     - any other version → an explicit `.backend_package = .{ .name,
//!       .repo, .version }` naming the SAME first-party package is inserted
//!       next to `.backend` (and `.backend = .<default>` is inserted too when
//!       the project had none: an explicit package with no `.backend` would
//!       otherwise flip `effectiveBackend()` to the legacy `.raylib`
//!       sentinel and change e.g. the gamepad default). To go back to the
//!       tracking shorthand, delete `.backend_package`.
//!
//! ## What it refuses or leaves alone
//!
//! * A version that is not strict `MAJOR.MINOR.PATCH` — refused (exit 2):
//!   `1.2`, `1.2.3.4`, `v1.2.3` and anything else `std.SemanticVersion`
//!   rejects. A valid semver WITH a pre-release or build suffix
//!   (`1.2.3-rc.1`, `1.2.3+b.5`) is refused too: the fetch path cannot fetch
//!   such a pin yet (assembler#783). A pre-release pin ALREADY in the file
//!   is judged by the floor tables as its `MAJOR.MINOR.PATCH`.
//! * A `local:` / `@` package — it builds from its checkout, so there is no
//!   pin to bump: a no-op without a version, refused with one.
//! * A third-party package with no version given — it has no builtin
//!   default, so it is a no-op with a note (a given version is written:
//!   the first-party floors do not apply to it).
//! * An explicit pin NEWER than the builtin default with no version given
//!   — never silently downgraded (the CLI's `upgrade all` rule).
//! * A pairing `version_floors` refuses (a compile break between the
//!   backend and `.core_version`) — refused with the floor's own message,
//!   BEFORE anything is written. A curated floor warns and proceeds, as it
//!   does in `generate`. The judgement runs on the PROSPECTIVE config, the
//!   same way `upgrade core|engine|gfx` does (#739).
//!
//! ## Offline
//!
//! Reads and writes `project.labelle` only. No fetch, no cache access.
//!
//! Every rewrite is verified before it is written: the new text is parsed
//! again and must resolve to the same backend name, tag and repo, the
//! requested version, and the same core/engine/gfx pins. A rewrite that
//! does not round-trip is refused instead of written.

const std = @import("std");
const config = @import("config.zig");
const version_floors = @import("version_floors.zig");
const plugin_params = @import("plugin_params.zig");

const ProjectConfig = config.ProjectConfig;

pub const Outcome = struct {
    kind: Kind,
    /// The new file content — `.rewrite` only.
    content: []const u8 = "",
    /// One line for the user.
    message: []const u8,
    /// Printed (as warnings) before `message`.
    warnings: []const []const u8 = &.{},
    /// Process exit code for `.refuse`.
    code: u8 = 0,

    pub const Kind = enum { rewrite, noop, refuse };
};

/// Decide what `upgrade backend [requested]` does to `content` (the raw
/// `project.labelle`). Pure: no I/O. Every returned slice is owned by `a`
/// (use an arena).
pub fn plan(a: std.mem.Allocator, content: []const u8, requested: ?[]const u8) !Outcome {
    const cfg = try parse(a, content);

    if (requested) |v| {
        const example = ProjectConfig.builtinProvider(cfg.effectiveBackend()).?.version;
        if (!isStrictSemver(v)) return refuse(a, 2, "'{s}' is not a semantic version — pass MAJOR.MINOR.PATCH (e.g. {s})", .{ v, example });
        if (!isRelease(v)) return refuse(a, 2, "'{s}' has a pre-release/build suffix: the fetch path doesn't support pre-release versions yet; see assembler#783 — pass MAJOR.MINOR.PATCH (e.g. {s})", .{ v, example });
    }

    var out = if (cfg.backend_package) |bp|
        try planExplicit(a, content, cfg, bp, requested)
    else
        try planShorthand(a, content, cfg, requested);
    // A no-op writes nothing, but a pairing that is ALREADY below a floor
    // (e.g. the shorthand's default bgfx on a hand-edited older core) is
    // still worth saying: this is the command the user would reach for.
    if (out.kind == .noop) out.warnings = try currentFloorWarnings(a, cfg);
    return out;
}

fn currentFloorWarnings(a: std.mem.Allocator, cfg_in: ProjectConfig) ![]const []const u8 {
    // Same normalisation as the rewrite path: a pre-release pin already in
    // the file is judged as its MAJOR.MINOR.PATCH, not skipped.
    var cfg = cfg_in;
    if (cfg.backend_package) |*bp| bp.version = try floorVersion(a, bp.version);
    const v = version_floors.verdict(cfg) catch return &.{};
    var warnings: std.ArrayList([]const u8) = .empty;
    if (v.backend) |b| {
        var buf: [512]u8 = undefined;
        try warnings.append(a, try std.fmt.allocPrint(a, "this project's current backend/core pairing already trips a floor: {s}", .{b.describe(&buf)}));
    }
    if (v.trio) |t| {
        var buf: [1024]u8 = undefined;
        try warnings.append(a, try std.fmt.allocPrint(a, "this project's core/engine/gfx pins already trip a floor: {s}", .{t.describe(&buf)}));
    }
    return warnings.items;
}

fn planExplicit(a: std.mem.Allocator, content: []const u8, cfg: ProjectConfig, bp: config.PluginDep, requested: ?[]const u8) !Outcome {
    if (bp.isLocal()) {
        if (requested != null) return refuse(a, 2, "backend package '{s}' is a local checkout ('{s}'): it builds from that directory, so there is no version to pin. Point `.repo` at a remote first", .{ bp.name, bp.repo });
        return noop(a, "backend package '{s}' is a local checkout ('{s}') — left unchanged", .{ bp.name, bp.repo });
    }
    const official = version_floors.officialBackendOf(bp);
    const target = requested orelse blk: {
        const b = official orelse return noop(
            a,
            "backend package '{s}' ({s}) is not a first-party backend, so this assembler has no default version for it — pin left at '{s}'. Pass one: upgrade backend <version>",
            .{ bp.name, bp.repo, bp.version },
        );
        const def = ProjectConfig.builtinProvider(b).?.version;
        // No `.version` at all (parsed as ""): nothing to downgrade, so the
        // default is inserted.
        if (bp.version.len == 0) break :blk def;
        if (std.mem.eql(u8, bp.version, def)) return noop(a, "backend package '{s}' is already at {s}, this assembler's default", .{ bp.name, def });
        const cur = std.SemanticVersion.parse(bp.version) catch return noop(a, "backend package '{s}' is pinned to '{s}', not a semantic version — left unchanged. Pass a version to replace it: upgrade backend {s}", .{ bp.name, bp.version, def });
        const def_v = std.SemanticVersion.parse(def) catch unreachable; // builtinProvider defaults are strict semver (tested)
        if (cur.order(def_v) != .lt) return noop(a, "backend package '{s}' {s} is newer than this assembler's default {s} — left unchanged (never downgraded; pass a version to set one explicitly)", .{ bp.name, bp.version, def });
        break :blk def;
    };
    if (std.mem.eql(u8, bp.version, target)) return noop(a, "backend package '{s}' is already at {s}", .{ bp.name, target });

    if (!isRelease(target)) return refuse(a, 1, "refusing to write '{s}': not a MAJOR.MINOR.PATCH release (assembler#783)", .{target});
    var prospective = cfg;
    prospective.backend_package.?.version = try floorVersion(a, target);
    var warnings: std.ArrayList([]const u8) = .empty;
    if (try floorGate(a, prospective, &warnings)) |r| return r;

    const new_content = (try rewritePackageVersion(a, content, target)) orelse
        return refuse(a, 1, "could not locate `.backend_package` in project.labelle to rewrite — set its `.version` to \"{s}\" by hand", .{target});
    if (!try roundTrips(a, cfg, new_content, target)) return refuse(a, 1, "the rewrite of `.backend_package.version` did not parse back to {s} — set it by hand", .{target});
    return .{
        .kind = .rewrite,
        .content = new_content,
        .warnings = warnings.items,
        .message = try std.fmt.allocPrint(a, "backend package '{s}' {s} -> {s}", .{ bp.name, bp.version, target }),
    };
}

fn planShorthand(a: std.mem.Allocator, content: []const u8, cfg: ProjectConfig, requested: ?[]const u8) !Outcome {
    const tag = cfg.effectiveBackend();
    const official = ProjectConfig.builtinProvider(tag).?;
    const target = requested orelse official.version;
    const how: []const u8 = if (cfg.backend == null) "no `.backend` (the default backend)" else "the `.backend` shorthand";
    if (std.mem.eql(u8, target, official.version)) return noop(
        a,
        "{s} resolves '{s}' to this assembler's default {s} — nothing to write (the shorthand tracks the assembler; pass another version to pin one)",
        .{ how, official.name, official.version },
    );

    if (!isRelease(target)) return refuse(a, 1, "refusing to write '{s}': not a MAJOR.MINOR.PATCH release (assembler#783)", .{target});
    var prospective = cfg;
    prospective.backend_package = .{ .name = official.name, .repo = official.repo, .version = try floorVersion(a, target) };
    var warnings: std.ArrayList([]const u8) = .empty;
    if (try floorGate(a, prospective, &warnings)) |r| return r;

    const package_field = try std.fmt.allocPrint(a, ".backend_package = .{{ .name = \"{s}\", .repo = \"{s}\", .version = \"{s}\" }}", .{ official.name, official.repo, target });
    const new_content = if (cfg.backend == null) blk: {
        const backend_field = try std.fmt.allocPrint(a, ".backend = .{s}", .{@tagName(tag)});
        break :blk try insertTopLevelFields(a, content, &.{ backend_field, package_field });
    } else try insertTopLevelFields(a, content, &.{package_field});
    const nc = new_content orelse
        return refuse(a, 1, "could not locate the top-level struct in project.labelle — add `{s}` by hand", .{package_field});
    if (!try roundTrips(a, cfg, nc, target)) return refuse(a, 1, "inserting `.backend_package` did not parse back to {s} — add `{s}` by hand", .{ target, package_field });
    return .{
        .kind = .rewrite,
        .content = nc,
        .warnings = warnings.items,
        .message = try std.fmt.allocPrint(a, "backend '{s}' {s} -> {s} (wrote an explicit `.backend_package`: the shorthand cannot carry a version; delete it to track the assembler's default again)", .{ official.name, official.version, target }),
    };
}

/// Judge the PROSPECTIVE pins. A backend/core compile break refuses with
/// the floor's own diagnostic; a curated floor warns. The trio is not moved
/// by this command, so a trio already below a floor only warns (the
/// `upgrade cli` rule in `cmdUpgrade`).
fn floorGate(a: std.mem.Allocator, prospective: ProjectConfig, warnings: *std.ArrayList([]const u8)) !?Outcome {
    const v = version_floors.verdict(prospective) catch |err| return try refuse(a, 2, "version pins: {s}", .{@errorName(err)});
    if (v.backend) |b| {
        var buf: [512]u8 = undefined;
        const msg = try a.dupe(u8, b.describe(&buf));
        switch (b.severity) {
            .compile_break => return try refuse(
                a,
                2,
                "{s} Upgrade core first (labelle-assembler upgrade core {s}, or upgrade all), or choose a backend version this core supports",
                .{ msg, b.recommended_core },
            ),
            .curated => try warnings.append(a, msg),
        }
    }
    if (v.trio) |t| {
        var buf: [1024]u8 = undefined;
        try warnings.append(a, try std.fmt.allocPrint(a, "this project's core/engine/gfx pins already trip a floor (this upgrade changes none of them): {s}", .{t.describe(&buf)}));
    }
    return null;
}

/// Strict semver 2.0.0 (`std.SemanticVersion.parse`): exactly
/// MAJOR.MINOR.PATCH, optionally `-pre.release` and/or `+build`; no `v`
/// prefix, no 4th numeric component, no `X.Y` abbreviation.
pub fn isStrictSemver(v: []const u8) bool {
    _ = std.SemanticVersion.parse(v) catch return false;
    return true;
}

/// Strict semver with NO pre-release/build suffix: the only pins the fetch
/// path can fetch today (assembler#783) and so the only ones this command
/// writes.
pub fn isRelease(v: []const u8) bool {
    const sv = std.SemanticVersion.parse(v) catch return false;
    return sv.pre == null and sv.build == null;
}

/// The version the floor tables judge: MAJOR.MINOR.PATCH with any
/// pre-release/build suffix dropped. This command never WRITES a suffixed
/// pin (#783), but one may already be in the file (hand-edited). The tables
/// only read release-shaped pins (`config.isSemverVersion`) and would
/// otherwise SKIP a `-rc.1` pin entirely; judging `0.26.0-rc.1` as `0.26.0`
/// is conservative (a pre-release sorts below its release, so at most it is
/// floored early). A pin that is not semver at all is returned unchanged.
fn floorVersion(a: std.mem.Allocator, v: []const u8) ![]const u8 {
    const sv = std.SemanticVersion.parse(v) catch return v;
    if (sv.pre == null and sv.build == null) return v;
    return std.fmt.allocPrint(a, "{d}.{d}.{d}", .{ sv.major, sv.minor, sv.patch });
}

fn roundTrips(a: std.mem.Allocator, before: ProjectConfig, new_content: []const u8, target: []const u8) !bool {
    const after = parse(a, new_content) catch return false;
    const bp = after.backend_package orelse return false;
    const want = before.effectiveBackendPackage().?;
    return std.mem.eql(u8, bp.version, target) and
        std.mem.eql(u8, bp.name, want.name) and
        std.mem.eql(u8, bp.repo, want.repo) and
        std.mem.eql(u8, after.backendName(), before.backendName()) and
        after.effectiveBackend() == before.effectiveBackend() and
        after.effectiveGamepad() == before.effectiveGamepad() and
        std.mem.eql(u8, after.core_version, before.core_version) and
        std.mem.eql(u8, after.engine_version, before.engine_version) and
        std.mem.eql(u8, after.gfx_version, before.gfx_version) and
        after.plugins.len == before.plugins.len;
}

fn parse(a: std.mem.Allocator, content: []const u8) !ProjectConfig {
    return plugin_params.parseProjectConfig(a, try a.dupeZ(u8, content));
}

fn noop(a: std.mem.Allocator, comptime fmt: []const u8, args: anytype) !Outcome {
    return .{ .kind = .noop, .message = try std.fmt.allocPrint(a, fmt, args) };
}

fn refuse(a: std.mem.Allocator, code: u8, comptime fmt: []const u8, args: anytype) !Outcome {
    return .{ .kind = .refuse, .code = code, .message = try std.fmt.allocPrint(a, fmt, args) };
}

/// Run it: print, and write `project.labelle` on a rewrite. Returns the
/// exit code.
pub fn run(a: std.mem.Allocator, io: std.Io, labelle_path: []const u8, content: []const u8, requested: ?[]const u8) u8 {
    const out = plan(a, content, requested) catch |err| {
        std.log.err("labelle-assembler upgrade backend: {s}", .{@errorName(err)});
        return 1;
    };
    for (out.warnings) |w| std.log.warn("labelle-assembler upgrade backend: {s}", .{w});
    switch (out.kind) {
        .noop => {
            std.log.info("labelle-assembler upgrade backend: {s}", .{out.message});
            return 0;
        },
        .refuse => {
            std.log.err("labelle-assembler upgrade backend: {s} — project.labelle left unchanged", .{out.message});
            return out.code;
        },
        .rewrite => {
            std.Io.Dir.cwd().writeFile(io, .{ .sub_path = labelle_path, .data = out.content }) catch {
                std.log.err("labelle-assembler upgrade backend: could not write '{s}'", .{labelle_path});
                return 1;
            };
            std.log.info("labelle-assembler: {s}", .{out.message});
            std.log.info("  run 'labelle generate' to regenerate build files", .{});
            return 0;
        },
    }
}

// ── minimal ZON text editing ─────────────────────────────────────────
//
// `project.labelle` is hand-written, so this edits bytes, never
// re-serializes: comments, strings and nesting are skipped while scanning,
// and only field positions (after `{` or `,`) are matched, so a comment,
// a string or an enum literal that spells `.backend_package` is never
// mistaken for the field.

/// Index of the character following the comment starting at `i`, or null
/// when no comment starts there.
fn skipComment(s: []const u8, i: usize) ?usize {
    if (i + 1 < s.len and s[i] == '/' and s[i + 1] == '/') {
        return std.mem.indexOfScalarPos(u8, s, i, '\n') orelse s.len;
    }
    return null;
}

/// Index just past the string literal starting at `i` (a `"…"` string, a
/// `\\` multiline-string line, or a `'…'` char literal), or null when none
/// starts there.
fn skipString(s: []const u8, i: usize) ?usize {
    const c = s[i];
    if (c == '\\' and i + 1 < s.len and s[i + 1] == '\\') {
        return std.mem.indexOfScalarPos(u8, s, i, '\n') orelse s.len;
    }
    if (c != '"' and c != '\'') return null;
    var k = i + 1;
    while (k < s.len) : (k += 1) {
        if (s[k] == '\\') {
            k += 1;
            continue;
        }
        if (s[k] == c) return k + 1;
        if (s[k] == '\n') return k;
    }
    return s.len;
}

/// The `}` matching the `{` at `open`.
fn matchBrace(s: []const u8, open: usize) ?usize {
    var depth: usize = 0;
    var i = open;
    while (i < s.len) {
        if (skipComment(s, i)) |n| {
            i = n;
            continue;
        }
        if (skipString(s, i)) |n| {
            i = n;
            continue;
        }
        switch (s[i]) {
            '{' => depth += 1,
            '}' => {
                depth -= 1;
                if (depth == 0) return i;
            },
            else => {},
        }
        i += 1;
    }
    return null;
}

const Span = struct { open: usize, close: usize };

/// The top-level `.{ … }`.
fn topLevel(s: []const u8) ?Span {
    var i: usize = 0;
    while (i < s.len) {
        if (skipComment(s, i)) |n| {
            i = n;
            continue;
        }
        if (s[i] == '{') return .{ .open = i, .close = matchBrace(s, i) orelse return null };
        i += 1;
    }
    return null;
}

fn isIdentChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_';
}

fn skipSpaceAndComments(s: []const u8, from: usize, to: usize) usize {
    var i = from;
    while (i < to) {
        if (skipComment(s, i)) |n| {
            i = n;
            continue;
        }
        if (!std.ascii.isWhitespace(s[i])) return i;
        i += 1;
    }
    return to;
}

/// Where the value of field `.name` (directly inside `span`) starts, and
/// where its field ends (the index of the `,` that terminates it, or
/// `span.close` when it is the last field without a trailing comma).
const FieldLoc = struct { value: usize, end: usize };

fn findField(s: []const u8, span: Span, name: []const u8) ?FieldLoc {
    var depth: usize = 0;
    var prev_sig: u8 = '{';
    var i = span.open + 1;
    while (i < span.close) {
        if (skipComment(s, i)) |n| {
            i = n;
            continue;
        }
        if (skipString(s, i)) |n| {
            prev_sig = '"';
            i = n;
            continue;
        }
        const c = s[i];
        if (std.ascii.isWhitespace(c)) {
            i += 1;
            continue;
        }
        if (c == '{') depth += 1;
        if (c == '}') depth -= 1;
        if (depth == 0 and c == '.' and (prev_sig == '{' or prev_sig == ',')) {
            const id_end = i + 1 + name.len;
            if (id_end <= span.close and std.mem.eql(u8, s[i + 1 .. id_end], name) and (id_end == span.close or !isIdentChar(s[id_end]))) {
                const eq = skipSpaceAndComments(s, id_end, span.close);
                if (eq < span.close and s[eq] == '=') {
                    const value = skipSpaceAndComments(s, eq + 1, span.close);
                    return .{ .value = value, .end = fieldEnd(s, value, span.close) };
                }
            }
        }
        prev_sig = c;
        i += 1;
    }
    return null;
}

/// The `,` ending the field whose value starts at `from`, or `close`.
fn fieldEnd(s: []const u8, from: usize, close: usize) usize {
    var depth: usize = 0;
    var i = from;
    while (i < close) {
        if (skipComment(s, i)) |n| {
            i = n;
            continue;
        }
        if (skipString(s, i)) |n| {
            i = n;
            continue;
        }
        switch (s[i]) {
            '{' => depth += 1,
            '}' => depth -= 1,
            ',' => if (depth == 0) return i,
            else => {},
        }
        i += 1;
    }
    return close;
}

/// Last significant (not whitespace, not comment) byte in `[from, to)`.
fn lastSignificant(s: []const u8, from: usize, to: usize) ?usize {
    var last: ?usize = null;
    var i = from;
    while (i < to) {
        if (skipComment(s, i)) |n| {
            i = n;
            continue;
        }
        if (skipString(s, i)) |n| {
            last = n - 1;
            i = n;
            continue;
        }
        if (!std.ascii.isWhitespace(s[i])) last = i;
        i += 1;
    }
    return last;
}

fn lineIndent(s: []const u8, idx: usize) []const u8 {
    const start = if (std.mem.lastIndexOfScalar(u8, s[0..idx], '\n')) |n| n + 1 else 0;
    var e = start;
    while (e < s.len and (s[e] == ' ' or s[e] == '\t')) e += 1;
    return s[start..e];
}

fn splice(a: std.mem.Allocator, s: []const u8, at: usize, drop: usize, insert: []const u8) ![]const u8 {
    return std.mem.concat(a, u8, &.{ s[0..at], insert, s[at + drop ..] });
}

/// Insert `fields` into the struct `span`, after the field that ends at
/// `anchor` (a `,`, or the struct's last significant byte), matching the
/// struct's layout: one line per field, indented like the anchor's line,
/// in a multi-line struct; `, a, b` on a single line.
fn insertFieldsAfter(a: std.mem.Allocator, s: []const u8, span: Span, anchor: ?usize, fields: []const []const u8) ![]const u8 {
    const multiline = std.mem.indexOfScalar(u8, s[span.open..span.close], '\n') != null;
    var buf: std.ArrayList(u8) = .empty;
    const last = anchor orelse {
        // An empty struct.
        if (multiline) {
            const indent = try std.fmt.allocPrint(a, "{s}    ", .{lineIndent(s, span.close)});
            for (fields) |f| try buf.print(a, "\n{s}{s},", .{ indent, f });
        } else {
            for (fields) |f| try buf.print(a, " {s},", .{f});
            try buf.append(a, ' ');
        }
        return splice(a, s, span.open + 1, 0, buf.items);
    };
    const needs_comma = s[last] != ',';
    if (!multiline) {
        // After the struct's last field (no comma): `, a, b`. After a
        // field's comma (mid-struct, or a trailing comma): ` a, b,`.
        for (fields, 0..) |f, n| {
            if (needs_comma or n > 0) try buf.append(a, ',');
            try buf.print(a, " {s}", .{f});
        }
        if (!needs_comma) try buf.append(a, ',');
        return splice(a, s, last + 1, 0, buf.items);
    }
    // Another field follows the anchor's comma on the SAME line
    // (`.backend = .sokol, .title = "T"`): insert right after the comma, in
    // the line — `, a, b,` then the existing field — so every separator
    // stays valid whatever that line ends with.
    const eol = @min(std.mem.indexOfScalarPos(u8, s, last, '\n') orelse span.close, span.close);
    if (!needs_comma and lastSignificant(s, last + 1, eol) != null) {
        for (fields) |f| try buf.print(a, " {s},", .{f});
        return splice(a, s, last + 1, 0, buf.items);
    }
    // After the anchor's LINE, so a trailing `// comment` stays where it is.
    const indent = lineIndent(s, last);
    for (fields) |f| try buf.print(a, "\n{s}{s},", .{ indent, f });
    const with_fields = try splice(a, s, eol, 0, buf.items);
    if (!needs_comma) return with_fields;
    return splice(a, with_fields, last + 1, 0, ",");
}

/// Insert top-level fields right after `.backend` when the project has it,
/// else at the end of the top-level struct. Null when the file has no
/// top-level struct.
fn insertTopLevelFields(a: std.mem.Allocator, s: []const u8, fields: []const []const u8) !?[]const u8 {
    const top = topLevel(s) orelse return null;
    if (findField(s, top, "backend")) |loc| {
        if (loc.end < top.close) return try insertFieldsAfter(a, s, top, loc.end, fields);
    }
    return try insertFieldsAfter(a, s, top, lastSignificant(s, top.open + 1, top.close), fields);
}

/// Rewrite (or insert) `.version` inside the top-level `.backend_package`.
/// Null when there is no `.backend_package = .{ … }` to edit.
fn rewritePackageVersion(a: std.mem.Allocator, s: []const u8, version: []const u8) !?[]const u8 {
    const top = topLevel(s) orelse return null;
    const loc = findField(s, top, "backend_package") orelse return null;
    // `.{`
    if (loc.value + 1 >= s.len or s[loc.value] != '.') return null;
    const open = skipSpaceAndComments(s, loc.value + 1, top.close);
    if (open >= top.close or s[open] != '{') return null;
    const pkg: Span = .{ .open = open, .close = matchBrace(s, open) orelse return null };
    if (findField(s, pkg, "version")) |v| {
        if (s[v.value] != '"') return null; // not a plain string literal
        const end = skipString(s, v.value).?;
        if (end < 2 or s[end - 1] != '"') return null;
        return try splice(a, s, v.value + 1, end - 1 - (v.value + 1), version);
    }
    const field = try std.fmt.allocPrint(a, ".version = \"{s}\"", .{version});
    return try insertFieldsAfter(a, s, pkg, lastSignificant(s, pkg.open + 1, pkg.close), &.{field});
}

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;

const Arena = struct {
    state: std.heap.ArenaAllocator,
    fn init() Arena {
        return .{ .state = std.heap.ArenaAllocator.init(testing.allocator) };
    }
    fn deinit(self: *Arena) void {
        self.state.deinit();
    }
    fn a(self: *Arena) std.mem.Allocator {
        return self.state.allocator();
    }
};

const sokol_default = ProjectConfig.builtinProvider(.sokol).?.version;
const bgfx_default = ProjectConfig.builtinProvider(.bgfx).?.version;

/// Apply the plan and return the resulting file (the input on a no-op).
fn applied(a: std.mem.Allocator, content: []const u8, requested: ?[]const u8) ![]const u8 {
    const out = try plan(a, content, requested);
    return switch (out.kind) {
        .rewrite => out.content,
        .noop => content,
        .refuse => error.TestUnexpectedRefusal,
    };
}

test "upgrade backend: shorthand-only, no version — no-op, the shorthand already tracks the default" {
    var ar = Arena.init();
    defer ar.deinit();
    const src =
        \\.{
        \\    .name = "g",
        \\    .backend = .sokol,
        \\}
        \\
    ;
    const out = try plan(ar.a(), src, null);
    try testing.expectEqual(Outcome.Kind.noop, out.kind);
    try testing.expect(std.mem.indexOf(u8, out.message, "tracks the assembler") != null);
    // And the default version given explicitly is the same no-op.
    try testing.expectEqual(Outcome.Kind.noop, (try plan(ar.a(), src, sokol_default)).kind);
}

test "upgrade backend: shorthand-only with a version writes an explicit .backend_package next to .backend, formatting kept" {
    var ar = Arena.init();
    defer ar.deinit();
    const src =
        \\// my game
        \\.{
        \\    .name = "g",
        \\    .backend = .sokol, // the renderer
        \\    .core_version = "1.32.0",
        \\    .engine_version = "2.12.2",
        \\    .gfx_version = "1.30.1",
        \\}
        \\
    ;
    const out = try plan(ar.a(), src, "0.99.0");
    try testing.expectEqual(Outcome.Kind.rewrite, out.kind);
    const want =
        \\// my game
        \\.{
        \\    .name = "g",
        \\    .backend = .sokol, // the renderer
        \\    .backend_package = .{ .name = "sokol", .repo = "github.com/labelle-toolkit/labelle-sokol", .version = "0.99.0" },
        \\    .core_version = "1.32.0",
        \\    .engine_version = "2.12.2",
        \\    .gfx_version = "1.30.1",
        \\}
        \\
    ;
    try testing.expectEqualStrings(want, out.content);
    const cfg = try parse(ar.a(), out.content);
    try testing.expectEqual(config.Backend.sokol, cfg.effectiveBackend());
    try testing.expectEqualStrings("0.99.0", cfg.effectiveBackendPackage().?.version);
    try testing.expectEqualStrings("sokol", cfg.backendName());
    try testing.expect(cfg.isEnumTagBacked());
}

test "upgrade backend: no .backend at all inserts .backend = .bgfx with the package, so effectiveBackend and the gamepad default do not move" {
    var ar = Arena.init();
    defer ar.deinit();
    const src = ".{ .name = \"g\", .core_version = \"2.1.0\", .engine_version = \"3.4.1\", .gfx_version = \"2.2.0\" }";
    const before = try parse(ar.a(), src);
    const out = try plan(ar.a(), src, "0.31.0");
    try testing.expectEqual(Outcome.Kind.rewrite, out.kind);
    try testing.expectEqualStrings(
        ".{ .name = \"g\", .core_version = \"2.1.0\", .engine_version = \"3.4.1\", .gfx_version = \"2.2.0\", .backend = .bgfx, .backend_package = .{ .name = \"bgfx\", .repo = \"github.com/labelle-toolkit/labelle-bgfx\", .version = \"0.31.0\" } }",
        out.content,
    );
    const after = try parse(ar.a(), out.content);
    try testing.expectEqual(config.Backend.bgfx, after.effectiveBackend());
    try testing.expectEqual(before.effectiveGamepad(), after.effectiveGamepad());
    try testing.expectEqualStrings("0.31.0", after.backend_package.?.version);
}

test "upgrade backend: an explicit first-party package is bumped in place to the builtin default; only the version bytes change" {
    var ar = Arena.init();
    defer ar.deinit();
    const src =
        \\.{
        \\    .name = "g",
        \\    .backend = .sokol,
        \\    // pinned for the android fix
        \\    .backend_package = .{
        \\        .name = "sokol",
        \\        .repo = "github.com/labelle-toolkit/labelle-sokol", // official
        \\        .version = "0.6.0",
        \\    },
        \\}
        \\
    ;
    const out = try plan(ar.a(), src, null);
    try testing.expectEqual(Outcome.Kind.rewrite, out.kind);
    const want = try std.mem.replaceOwned(u8, ar.a(), src, "\"0.6.0\"", "\"" ++ sokol_default ++ "\"");
    try testing.expectEqualStrings(want, out.content);
    // An explicit version works the same way.
    const pinned = try plan(ar.a(), src, "0.7.0");
    try testing.expectEqualStrings(try std.mem.replaceOwned(u8, ar.a(), src, "\"0.6.0\"", "\"0.7.0\""), pinned.content);
}

test "upgrade backend: an explicit package without .version gets one inserted" {
    var ar = Arena.init();
    defer ar.deinit();
    const single = ".{ .name = \"g\", .backend = .sokol, .backend_package = .{ .name = \"sokol\", .repo = \"github.com/labelle-toolkit/labelle-sokol\" } }";
    const out = try plan(ar.a(), single, "0.8.0");
    try testing.expectEqualStrings(
        ".{ .name = \"g\", .backend = .sokol, .backend_package = .{ .name = \"sokol\", .repo = \"github.com/labelle-toolkit/labelle-sokol\", .version = \"0.8.0\" } }",
        out.content,
    );
    const multi =
        \\.{
        \\    .name = "g",
        \\    .backend_package = .{
        \\        .name = "sokol",
        \\        .repo = "github.com/labelle-toolkit/labelle-sokol" // no trailing comma
        \\    },
        \\}
    ;
    const m = try plan(ar.a(), multi, "0.8.0");
    try testing.expectEqualStrings(
        \\.{
        \\    .name = "g",
        \\    .backend_package = .{
        \\        .name = "sokol",
        \\        .repo = "github.com/labelle-toolkit/labelle-sokol", // no trailing comma
        \\        .version = "0.8.0",
        \\    },
        \\}
    , m.content);
}

test "upgrade backend: an explicit pin newer than the default is never downgraded without a version" {
    var ar = Arena.init();
    defer ar.deinit();
    const src = ".{ .name = \"g\", .backend = .sokol, .backend_package = .{ .name = \"sokol\", .repo = \"github.com/labelle-toolkit/labelle-sokol\", .version = \"9.0.0\" } }";
    const out = try plan(ar.a(), src, null);
    try testing.expectEqual(Outcome.Kind.noop, out.kind);
    try testing.expect(std.mem.indexOf(u8, out.message, "never downgraded") != null);
}

test "upgrade backend: a third-party package has no builtin default — no-op with a note; an explicit version is written" {
    var ar = Arena.init();
    defer ar.deinit();
    const src = ".{ .name = \"g\", .backend_package = .{ .name = \"acme\", .repo = \"github.com/acme/labelle-acme\", .version = \"1.0.0\" } }";
    const out = try plan(ar.a(), src, null);
    try testing.expectEqual(Outcome.Kind.noop, out.kind);
    try testing.expect(std.mem.indexOf(u8, out.message, "not a first-party backend") != null);
    try testing.expect(std.mem.indexOf(u8, out.message, "no default version") != null);

    const pinned = try plan(ar.a(), src, "1.1.0");
    try testing.expectEqual(Outcome.Kind.rewrite, pinned.kind);
    try testing.expectEqualStrings(try std.mem.replaceOwned(u8, ar.a(), src, "\"1.0.0\"", "\"1.1.0\""), pinned.content);
    // The package still names the backend (no `.backend` was invented).
    try testing.expectEqualStrings("acme", (try parse(ar.a(), pinned.content)).backendName());
}

test "upgrade backend: a local package is left alone, and refused with a version" {
    var ar = Arena.init();
    defer ar.deinit();
    const src = ".{ .name = \"g\", .backend = .bgfx, .backend_package = .{ .name = \"bgfx\", .repo = \"local:../labelle-bgfx\", .version = \"0.30.0\" } }";
    try testing.expectEqual(Outcome.Kind.noop, (try plan(ar.a(), src, null)).kind);
    const r = try plan(ar.a(), src, "0.31.0");
    try testing.expectEqual(Outcome.Kind.refuse, r.kind);
    try testing.expectEqual(@as(u8, 2), r.code);
    try testing.expect(std.mem.indexOf(u8, r.message, "local checkout") != null);
}

test "upgrade backend: a pairing below the backend's core floor is refused with the floor's message, nothing written" {
    var ar = Arena.init();
    defer ar.deinit();
    // bgfx 0.21.0 on the core 2.0.0 line is coherent; the default bgfx
    // (>= 0.26.0) needs core >= 2.1.0 — a compile break.
    const explicit = ".{ .name = \"g\", .backend = .bgfx, .core_version = \"2.0.0\", .engine_version = \"3.0.0\", .gfx_version = \"2.0.0\", .backend_package = .{ .name = \"bgfx\", .repo = \"github.com/labelle-toolkit/labelle-bgfx\", .version = \"0.21.0\" } }";
    const r = try plan(ar.a(), explicit, null);
    try testing.expectEqual(Outcome.Kind.refuse, r.kind);
    try testing.expectEqual(@as(u8, 2), r.code);
    try testing.expectEqualStrings("", r.content);
    // The floor's own diagnostic, verbatim, is the message's head.
    const v = (try version_floors.configBackendCoreFloorViolation(blk: {
        var c = try parse(ar.a(), explicit);
        c.backend_package.?.version = bgfx_default;
        break :blk c;
    })).?;
    var buf: [512]u8 = undefined;
    try testing.expect(std.mem.startsWith(u8, r.message, v.describe(&buf)));
    try testing.expect(std.mem.indexOf(u8, r.message, "requires labelle-core >= 2.1.0") != null);
    try testing.expect(std.mem.indexOf(u8, r.message, "upgrade core 2.1.0") != null);

    // The shorthand path runs the same gate on the package it would write.
    const shorthand = ".{ .name = \"g\", .backend = .bgfx, .core_version = \"2.0.0\", .engine_version = \"3.0.0\", .gfx_version = \"2.0.0\" }";
    const s = try plan(ar.a(), shorthand, "0.26.0");
    try testing.expectEqual(Outcome.Kind.refuse, s.kind);
    try testing.expect(std.mem.indexOf(u8, s.message, "requires labelle-core >= 2.1.0") != null);
    // ...and a version on the right side of the floor passes.
    try testing.expectEqual(Outcome.Kind.rewrite, (try plan(ar.a(), shorthand, "0.25.0")).kind);
}

test "upgrade backend: a no-op still reports a pairing that is already below a floor" {
    var ar = Arena.init();
    defer ar.deinit();
    // The shorthand's default bgfx (>= 0.26.0) on core 2.0.0: nothing to
    // write, but the project cannot build as it stands.
    const out = try plan(ar.a(), ".{ .name = \"g\", .backend = .bgfx, .core_version = \"2.0.0\", .engine_version = \"3.0.0\", .gfx_version = \"2.0.0\" }", null);
    try testing.expectEqual(Outcome.Kind.noop, out.kind);
    try testing.expectEqual(@as(usize, 1), out.warnings.len);
    try testing.expect(std.mem.indexOf(u8, out.warnings[0], "already trips a floor") != null);
    try testing.expect(std.mem.indexOf(u8, out.warnings[0], "requires labelle-core >= 2.1.0") != null);
    // A coherent project's no-op is silent.
    const ok = try plan(ar.a(), ".{ .name = \"g\", .backend = .sokol }", null);
    try testing.expectEqual(@as(usize, 0), ok.warnings.len);
}

test "upgrade backend: a curated floor warns and proceeds" {
    var ar = Arena.init();
    defer ar.deinit();
    // bgfx 0.20.0 on core 1.28.0 builds but is not its released pairing.
    const src = ".{ .name = \"g\", .backend = .bgfx, .core_version = \"1.28.0\", .engine_version = \"2.11.0\", .gfx_version = \"1.28.1\", .backend_package = .{ .name = \"bgfx\", .repo = \"github.com/labelle-toolkit/labelle-bgfx\", .version = \"0.15.0\" } }";
    const out = try plan(ar.a(), src, "0.20.0");
    try testing.expectEqual(Outcome.Kind.rewrite, out.kind);
    try testing.expectEqual(@as(usize, 1), out.warnings.len);
    try testing.expect(std.mem.indexOf(u8, out.warnings[0], "is released against labelle-core >= 1.32.0") != null);
}

test "upgrade backend: idempotent — a second run is a no-op and leaves the bytes alone" {
    var ar = Arena.init();
    defer ar.deinit();
    const inputs = [_][]const u8{
        ".{\n    .name = \"g\",\n    .backend = .sokol,\n}\n",
        ".{ .name = \"g\", .backend = .sokol, .backend_package = .{ .name = \"sokol\", .repo = \"github.com/labelle-toolkit/labelle-sokol\", .version = \"0.6.0\" } }",
        ".{ .name = \"g\", .core_version = \"2.1.0\", .engine_version = \"3.4.1\", .gfx_version = \"2.2.0\" }",
    };
    for (inputs) |src| {
        for ([_]?[]const u8{ null, "0.99.0" }) |req| {
            const once = try applied(ar.a(), src, req);
            const second = try plan(ar.a(), once, req);
            try testing.expectEqual(Outcome.Kind.noop, second.kind);
        }
    }
    // After pinning past the default through the shorthand, a bare
    // `upgrade backend` does not undo it either.
    const pinned = try applied(ar.a(), inputs[0], "0.99.0");
    try testing.expectEqual(Outcome.Kind.noop, (try plan(ar.a(), pinned, null)).kind);
}

test "upgrade backend: single-line shorthand inserts the package after .backend with the commas right" {
    var ar = Arena.init();
    defer ar.deinit();
    const out = try plan(ar.a(), ".{ .name = \"g\", .backend = .sokol, .title = \"T\" }", "0.99.0");
    try testing.expectEqualStrings(
        ".{ .name = \"g\", .backend = .sokol, .backend_package = .{ .name = \"sokol\", .repo = \"github.com/labelle-toolkit/labelle-sokol\", .version = \"0.99.0\" }, .title = \"T\" }",
        out.content,
    );
    const last = try plan(ar.a(), ".{ .name = \"g\", .backend = .sokol }", "0.99.0");
    try testing.expectEqualStrings(
        ".{ .name = \"g\", .backend = .sokol, .backend_package = .{ .name = \"sokol\", .repo = \"github.com/labelle-toolkit/labelle-sokol\", .version = \"0.99.0\" } }",
        last.content,
    );
}

test "upgrade backend: a non-semver version is refused" {
    var ar = Arena.init();
    defer ar.deinit();
    const r = try plan(ar.a(), ".{ .name = \"g\", .backend = .sokol }", "main");
    try testing.expectEqual(Outcome.Kind.refuse, r.kind);
    try testing.expect(std.mem.indexOf(u8, r.message, "not a semantic version") != null);
}

test "upgrade backend: versions are strict MAJOR.MINOR.PATCH — 1.2.3.4, 1.2, v1.2.3 invalid; 1.2.3-rc.1 refused (#783)" {
    var ar = Arena.init();
    defer ar.deinit();
    const shorthand = ".{ .name = \"g\", .backend = .sokol }";
    const explicit = ".{ .name = \"g\", .backend_package = .{ .name = \"acme\", .repo = \"github.com/acme/labelle-acme\", .version = \"1.0.0\" } }";
    for ([_][]const u8{ shorthand, explicit }) |src| {
        for ([_][]const u8{ "1.2.3.4", "1.2", "v1.2.3", "1.2.3-", "01.2.3" }) |bad| {
            const r = try plan(ar.a(), src, bad);
            errdefer std.debug.print("version '{s}' was not refused\n", .{bad});
            try testing.expectEqual(Outcome.Kind.refuse, r.kind);
            try testing.expectEqual(@as(u8, 2), r.code);
            try testing.expect(std.mem.indexOf(u8, r.message, "not a semantic version") != null);
        }
        // Valid semver with a suffix: refused because it cannot be fetched.
        for ([_][]const u8{ "1.2.3-rc.1", "1.2.3+build.5", "1.2.3-rc.1+b" }) |pre| {
            const r = try plan(ar.a(), src, pre);
            errdefer std.debug.print("version '{s}' was not refused\n", .{pre});
            try testing.expectEqual(Outcome.Kind.refuse, r.kind);
            try testing.expectEqual(@as(u8, 2), r.code);
            try testing.expect(std.mem.indexOf(u8, r.message, "the fetch path doesn't support pre-release versions yet; see assembler#783") != null);
            try testing.expectEqualStrings("", r.content);
        }
        // A plain release is still written.
        try testing.expectEqual(Outcome.Kind.rewrite, (try plan(ar.a(), src, "1.2.4")).kind);
    }
}

test "upgrade backend: a no-op judges a pre-release pin already in the file by its MAJOR.MINOR.PATCH" {
    var ar = Arena.init();
    defer ar.deinit();
    // A hand-edited bgfx 0.31.0-rc.1 (newer than the default, so a bare run
    // is a no-op) on core 2.0.0. As 0.31.0 it trips bgfx >= 0.26.0's
    // core >= 2.1.0 floor; unnormalised, the floor table would skip it.
    const src = ".{ .name = \"g\", .backend = .bgfx, .core_version = \"2.0.0\", .engine_version = \"3.0.0\", .gfx_version = \"2.0.0\", .backend_package = .{ .name = \"bgfx\", .repo = \"github.com/labelle-toolkit/labelle-bgfx\", .version = \"0.31.0-rc.1\" } }";
    const out = try plan(ar.a(), src, null);
    try testing.expectEqual(Outcome.Kind.noop, out.kind);
    try testing.expectEqual(@as(usize, 1), out.warnings.len);
    try testing.expect(std.mem.indexOf(u8, out.warnings[0], "already trips a floor") != null);
    try testing.expect(std.mem.indexOf(u8, out.warnings[0], "requires labelle-core >= 2.1.0") != null);
    // Mechanism: the raw config alone is NOT judged by the table.
    try testing.expect((try version_floors.configBackendCoreFloorViolation(try parse(ar.a(), src))) == null);
}

test "upgrade backend: .backend sharing a line with a later last field keeps valid separators" {
    var ar = Arena.init();
    defer ar.deinit();
    const pkg = ".backend_package = .{ .name = \"sokol\", .repo = \"github.com/labelle-toolkit/labelle-sokol\", .version = \"0.99.0\" }";
    const Case = struct { src: []const u8, want: []const u8 };
    const cases = [_]Case{
        // The reported layout: `.backend` and a final no-comma field on one line.
        .{
            .src = ".{\n    .name = \"g\",\n    .backend = .sokol, .title = \"T\"\n}\n",
            .want = ".{\n    .name = \"g\",\n    .backend = .sokol, " ++ pkg ++ ", .title = \"T\"\n}\n",
        },
        // ...with a trailing comment on that line.
        .{
            .src = ".{\n    .name = \"g\",\n    .backend = .sokol, .title = \"T\" // t\n}\n",
            .want = ".{\n    .name = \"g\",\n    .backend = .sokol, " ++ pkg ++ ", .title = \"T\" // t\n}\n",
        },
        // `.backend` last, no trailing comma, trailing comment.
        .{
            .src = ".{\n    .name = \"g\",\n    .backend = .sokol // renderer\n}\n",
            .want = ".{\n    .name = \"g\",\n    .backend = .sokol, // renderer\n    " ++ pkg ++ ",\n}\n",
        },
        // `.backend` alone on its line with a comment after the comma.
        .{
            .src = ".{\n    .name = \"g\",\n    .backend = .sokol, // renderer\n    .title = \"T\",\n}\n",
            .want = ".{\n    .name = \"g\",\n    .backend = .sokol, // renderer\n    " ++ pkg ++ ",\n    .title = \"T\",\n}\n",
        },
        // Single-line struct, `.backend` last / in the middle.
        .{ .src = ".{ .name = \"g\", .backend = .sokol }", .want = ".{ .name = \"g\", .backend = .sokol, " ++ pkg ++ " }" },
        .{ .src = ".{ .name = \"g\", .backend = .sokol, .title = \"T\" }", .want = ".{ .name = \"g\", .backend = .sokol, " ++ pkg ++ ", .title = \"T\" }" },
        // `.backend` then a multi-line nested field on the same line.
        .{
            .src = ".{\n    .backend = .sokol, .layers = .{\n        .{ .name = \"hud\", .order = 0, .space = .screen },\n    },\n    .name = \"g\",\n}\n",
            .want = ".{\n    .backend = .sokol, " ++ pkg ++ ", .layers = .{\n        .{ .name = \"hud\", .order = 0, .space = .screen },\n    },\n    .name = \"g\",\n}\n",
        },
    };
    for (cases) |c| {
        errdefer std.debug.print("input:\n{s}\n", .{c.src});
        const out = try plan(ar.a(), c.src, "0.99.0");
        try testing.expectEqual(Outcome.Kind.rewrite, out.kind);
        try testing.expectEqualStrings(c.want, out.content);
        // And it parses back to the pinned package (roundTrips ran too).
        try testing.expectEqualStrings("0.99.0", (try parse(ar.a(), out.content)).backend_package.?.version);
    }
}

test "upgrade backend: a first-party .backend_package with no .version gets the default inserted by a bare run" {
    var ar = Arena.init();
    defer ar.deinit();
    const src =
        \\.{
        \\    .name = "g",
        \\    .backend = .sokol,
        \\    .backend_package = .{
        \\        .name = "sokol",
        \\        .repo = "github.com/labelle-toolkit/labelle-sokol",
        \\    },
        \\}
    ;
    // Mechanism: the parser really does hand us "" for the omitted field.
    try testing.expectEqualStrings("", (try parse(ar.a(), src)).backend_package.?.version);
    const out = try plan(ar.a(), src, null);
    try testing.expectEqual(Outcome.Kind.rewrite, out.kind);
    try testing.expectEqualStrings(
        \\.{
        \\    .name = "g",
        \\    .backend = .sokol,
        \\    .backend_package = .{
        \\        .name = "sokol",
        \\        .repo = "github.com/labelle-toolkit/labelle-sokol",
        \\        .version = "
    ++ sokol_default ++
        \\",
        \\    },
        \\}
    , out.content);
    // ...and a second bare run is a no-op.
    try testing.expectEqual(Outcome.Kind.noop, (try plan(ar.a(), out.content, null)).kind);
}

test "isStrictSemver / isRelease, and every builtinProvider default is a release" {
    for ([_][]const u8{ "1.2.3", "0.30.0", "1.2.3-rc.1", "1.2.3+b.5", "1.2.3-alpha.1+sha.abc" }) |v| try testing.expect(isStrictSemver(v));
    for ([_][]const u8{ "1.2.3.4", "1.2", "v1.2.3", "", "main", "1.2.3-", "1.2.3-01" }) |v| try testing.expect(!isStrictSemver(v));
    try testing.expect(isRelease("1.2.3"));
    for ([_][]const u8{ "1.2.3-rc.1", "1.2.3+b.5", "1.2", "1.2.3.4" }) |v| try testing.expect(!isRelease(v));
    inline for (@typeInfo(config.Backend).@"enum".fields) |f| {
        try testing.expect(isRelease(ProjectConfig.builtinProvider(@enumFromInt(f.value)).?.version));
    }
}

test "upgrade backend: comments, strings and enum literals spelling the field are not matched" {
    var ar = Arena.init();
    defer ar.deinit();
    const src =
        \\.{
        \\    // .backend_package = .{ .name = "x", .version = "0.0.1" },
        \\    .name = ".backend_package = .{",
        \\    .backend = .sokol,
        \\    .backend_package = .{ .name = "sokol", .repo = "github.com/labelle-toolkit/labelle-sokol", .version = "0.6.0" },
        \\}
    ;
    const out = try plan(ar.a(), src, "0.7.0");
    try testing.expectEqualStrings(try std.mem.replaceOwned(u8, ar.a(), src, "\"0.6.0\"", "\"0.7.0\""), out.content);
}
