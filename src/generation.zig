//! Generation token — the freshness marker for generated metadata (#724).
//!
//! ## The problem it solves
//!
//! `hook_routes.json` describes the LAST successful generate. Writing it
//! atomically stops a torn file, but it cannot stop a *stale* one: a generate
//! that fails before the sidecar is emitted leaves the previous sidecar intact
//! and perfectly valid-looking, and `routes` would present it as current.
//!
//! Atomicity and freshness are different properties. This is the freshness half.
//!
//! ## The rule
//!
//! `<game>/.labelle/generation` holds an opaque token. `generate` advances it
//! **before** it changes any generated output, and every metadata artifact
//! stamps the token it was produced under. A reader compares:
//!
//!   * token missing from the artifact → **stale** (legacy, pre-token sidecar)
//!   * token present but ≠ the marker  → **stale** (an intervening generate,
//!     or one that failed before reaching the artifact)
//!   * equal                            → current
//!
//! Ordering is what makes it work. Advancing FIRST means any failure after that
//! point leaves the marker ahead of the artifact, which reads as stale — the
//! safe direction. Advancing last would leave a failed generate looking clean.
//!
//! If the marker cannot be advanced, `generate` must stop before mutating
//! outputs rather than proceed with metadata that will falsely read as current.
//!
//! ## Why not mtime
//!
//! An mtime or digest heuristic is wrong in the cases that matter: a fresh
//! checkout gives every file the same timestamp, a restored backup moves them
//! backwards, and a content digest cannot tell "regenerated identically" from
//! "never regenerated". An explicit token has no such cases — it is advanced by
//! exactly one writer at exactly one point.

const std = @import("std");
const config = @import("config.zig");

/// Filename of the marker inside `.labelle/`.
pub const FILENAME = "generation";

/// Errors a caller must not paper over: if the marker cannot be advanced, the
/// generate has to stop before touching outputs.
pub const AdvanceError = error{
    OutOfMemory,
    GenerationMarkerUnwritable,
};

/// Produce a fresh token. Opaque by construction — nothing may parse it or
/// order two tokens; the only meaningful operation is equality. Random rather
/// than a counter so two generates racing on one directory cannot mint the
/// same value and agree by accident.
fn mint(aa: std.mem.Allocator) ![]const u8 {
    // Zig 0.16 has no `std.time` clock and no `std.crypto.random`, so the
    // seed is address entropy (ASLR) mixed with a process-local counter.
    // That is ample for an EQUALITY TAG — nothing orders or parses these —
    // and `advance` additionally guarantees the new token differs from the
    // one it replaces, which is the property that actually matters.
    var local: u8 = 0;
    counter +%= 1;
    const seed: u64 = @intFromPtr(&local) ^ (counter *% 0x9E3779B97F4A7C15);
    var prng = std.Random.DefaultPrng.init(seed);
    var raw: [16]u8 = undefined;
    prng.random().bytes(&raw);
    return std.fmt.allocPrint(aa, "{x}", .{&raw});
}

var counter: u64 = 0;

/// Advance the marker and return the new token.
///
/// Atomic: writes a temp beside the marker and renames over it, so a reader
/// never sees a partial token, and a failed write leaves the PREVIOUS token in
/// place (which still reads as stale against a newer artifact — the safe
/// direction).
///
/// Call this BEFORE mutating any generated output.
pub fn advance(aa: std.mem.Allocator, labelle_dir: []const u8) AdvanceError![]const u8 {
    // "Advance" has to mean CHANGED. Reading the previous marker and
    // re-minting on a collision makes that true by construction rather than
    // by trusting the seed — a token equal to its predecessor would leave a
    // stale sidecar reading as current, the exact failure this exists to
    // prevent.
    // Scratch arena: `read` allocates the joined path and the file bytes,
    // and neither outlives this check. Using the caller's allocator here
    // leaked both on every generate.
    var scratch = std.heap.ArenaAllocator.init(aa);
    defer scratch.deinit();
    const previous: ?[]const u8 = read(scratch.allocator(), labelle_dir) catch null;
    var token = mint(aa) catch return error.OutOfMemory;
    if (previous) |prev| {
        var guard: u8 = 0;
        while (std.mem.eql(u8, token, prev) and guard < 8) : (guard += 1) {
            token = mint(aa) catch return error.OutOfMemory;
        }
        if (std.mem.eql(u8, token, prev)) return error.GenerationMarkerUnwritable;
    }
    const io = config.globalIo();
    const cwd = std.Io.Dir.cwd();

    cwd.createDirPath(io, labelle_dir) catch return error.GenerationMarkerUnwritable;
    var dir = cwd.openDir(io, labelle_dir, .{}) catch return error.GenerationMarkerUnwritable;
    defer dir.close(io);

    const tmp_name = FILENAME ++ ".tmp";
    {
        const file = dir.createFile(io, tmp_name, .{}) catch return error.GenerationMarkerUnwritable;
        defer file.close(io);
        file.writeStreamingAll(io, token) catch {
            dir.deleteFile(io, tmp_name) catch {};
            return error.GenerationMarkerUnwritable;
        };
    }
    dir.rename(tmp_name, dir, FILENAME, io) catch {
        dir.deleteFile(io, tmp_name) catch {};
        return error.GenerationMarkerUnwritable;
    };
    return token;
}

/// Read the current marker, or null when there is none (never generated, or a
/// project predating the marker).
pub fn read(aa: std.mem.Allocator, labelle_dir: []const u8) !?[]const u8 {
    const io = config.globalIo();
    const path = try std.fs.path.join(aa, &.{ labelle_dir, FILENAME });
    const bytes = std.Io.Dir.cwd().readFileAlloc(io, path, aa, .limited(4096)) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.FileNotFound => return null,
        // A marker we cannot READ is not a marker we may ignore: treating an
        // unreadable one as absent would silently downgrade to the legacy
        // path and present a stale artifact as merely un-stamped.
        else => return err,
    };
    const trimmed = std.mem.trim(u8, bytes, " \t\r\n");
    return if (trimmed.len == 0) null else trimmed;
}

/// How an artifact's stamp compares to the marker on disk.
pub const Freshness = enum {
    current,
    /// The artifact carries no token — written before the marker existed.
    untokenized,
    /// The artifact's token is not the current one.
    stale,
    /// No marker on disk at all: nothing has been generated here.
    never_generated,
};

pub fn compare(artifact_token: ?[]const u8, marker: ?[]const u8) Freshness {
    const m = marker orelse return .never_generated;
    const a = artifact_token orelse return .untokenized;
    return if (std.mem.eql(u8, a, m)) .current else .stale;
}

test "compare covers every combination" {
    try std.testing.expectEqual(Freshness.current, compare("abc", "abc"));
    try std.testing.expectEqual(Freshness.stale, compare("abc", "def"));
    try std.testing.expectEqual(Freshness.untokenized, compare(null, "def"));
    try std.testing.expectEqual(Freshness.never_generated, compare("abc", null));
    try std.testing.expectEqual(Freshness.never_generated, compare(null, null));
}

test "a token is opaque, non-empty, and does not repeat" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = try mint(arena.allocator());
    const b = try mint(arena.allocator());
    try std.testing.expect(a.len > 0);
    try std.testing.expect(!std.mem.eql(u8, a, b));
}
