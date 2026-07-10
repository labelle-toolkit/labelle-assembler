//! UTF-8-correct libc file-open shim for the sokol backend's one-shot loaders.
//!
//! ## Why this exists (labelle-assembler#232)
//!
//! The sokol backend reads/writes a handful of files through libc stdio —
//! `gfx/texture.zig` (demo texture loader), `audio.zig` (legacy WAV loader)
//! and `screenshot/bmp.zig` (screenshot writer). libc was chosen because Zig
//! 0.16 dropped the allocator-free `std.fs.cwd()`; its replacement
//! (`std.Io.Dir.cwd().openFile`) threads an `Io` through every call site,
//! which isn't worth it for these one-shot paths.
//!
//! The catch: on Windows, libc `fopen` takes a byte path that the CRT
//! interprets in the process **ANSI codepage**, so a UTF-8 path containing
//! non-ASCII characters (日本語, ñ, ü, …) fails to open or is silently
//! corrupted. On POSIX, `fopen` already takes the UTF-8 bytes verbatim.
//!
//! ## The fix
//!
//! This module centralises the `fopen`/`remove` calls behind two helpers that
//! are UTF-8-correct on every platform:
//!
//!   * POSIX — pass the UTF-8 bytes straight through to `fopen`/`remove`.
//!   * Windows — convert UTF-8 → UTF-16 and call the wide-char CRT entry
//!     points `_wfopen`/`_wremove`, which open the file by its real Unicode
//!     name.
//!
//! Only the `fopen`/`remove` step is routed here; the existing
//! `fread`/`fwrite`/`fclose`/`fseek`/`ftell` calls at each site stay exactly
//! as they were, so read/write behaviour (binary modes, short-read handling)
//! is unchanged. Every consuming module already sets `link_libc = true` (see
//! backends/sokol/build.zig — pulled in for stb_image / stb_vorbis), so the
//! wide-char CRT entry points are available with no new link-time cost.

const std = @import("std");
const builtin = @import("builtin");

const is_windows = builtin.os.tag == .windows;

// Windows CRT wide-char stdio. Both are exported by MSVCRT/UCRT; `link_libc`
// puts them on the link line. Declared here (rather than pulled from `std.c`)
// because std does not surface the `_w`-prefixed CRT entry points.
extern "c" fn _wfopen(filename: [*:0]const u16, mode: [*:0]const u16) ?*std.c.FILE;
extern "c" fn _wremove(filename: [*:0]const u16) c_int;

// POSIX `remove` (std does not surface it via `std.c`).
extern "c" fn remove(path: [*:0]const u8) c_int;

/// Size (in UTF-16 code units) of the Windows conversion buffer, INCLUDING
/// the slot reserved for the NUL terminator — so at most `max_path_wide - 1`
/// code units of an actual path are stored. Any real asset/screenshot path is
/// far shorter; longer paths return null rather than truncate or overflow. A
/// UTF-8 path of N bytes encodes to at most N UTF-16 code units, so a path
/// whose byte length fits also fits after conversion.
const max_path_wide = 4096;

/// Open `path` (UTF-8) with the C stdio `mode` string ("rb", "wb", …),
/// returning a libc `FILE*` or null on failure — a drop-in replacement for
/// `std.c.fopen(path.ptr, mode)` that is UTF-8-correct on Windows.
///
/// `mode` is comptime because the CRT mode strings are all string literals;
/// on Windows it is widened to UTF-16 at comptime.
pub fn openC(path: [:0]const u8, comptime mode: [:0]const u8) ?*std.c.FILE {
    if (!is_windows) return std.c.fopen(path.ptr, mode.ptr);

    var path_w: [max_path_wide]u16 = undefined;
    const path_w_z = utf8PathToWideZ(&path_w, path) catch return null;
    const mode_w = std.unicode.utf8ToUtf16LeStringLiteral(mode);
    return _wfopen(path_w_z.ptr, mode_w);
}

/// Delete the file at `path` (UTF-8). Returns true on success. UTF-8-correct
/// on Windows (mirrors `openC`); used for temp-file cleanup.
pub fn removeC(path: [:0]const u8) bool {
    if (!is_windows) return remove(path.ptr) == 0;

    var path_w: [max_path_wide]u16 = undefined;
    const path_w_z = utf8PathToWideZ(&path_w, path) catch return false;
    return _wremove(path_w_z.ptr) == 0;
}

/// Convert a UTF-8 `path` into `buf` as a NUL-terminated UTF-16LE string,
/// returning a sentinel-terminated slice that borrows `buf`.
///
/// Buffer safety: one slot is reserved for the NUL terminator, so the
/// conversion is handed `buf[0 .. buf.len - 1]` and can write at most
/// `buf.len - 1` code units — `buf[len] = 0` is therefore always in bounds.
/// A UTF-8 path of N bytes encodes to at most N UTF-16 code units, so any
/// `path` with `path.len >= buf.len` cannot leave room for the terminator
/// and is rejected up front with `error.PathTooLong` (never truncated, never
/// overflowed). Invalid UTF-8 yields `error.InvalidUtf8`.
///
/// Not platform-gated so the bounds logic is unit-testable on any host.
fn utf8PathToWideZ(buf: []u16, path: []const u8) error{ PathTooLong, InvalidUtf8 }![:0]u16 {
    if (path.len >= buf.len) return error.PathTooLong;
    const len = std.unicode.utf8ToUtf16Le(buf[0 .. buf.len - 1], path) catch
        return error.InvalidUtf8;
    buf[len] = 0;
    return buf[0..len :0];
}

test "openC round-trips a UTF-8 path" {
    // A non-ASCII filename exercises the Windows UTF-8 → UTF-16 conversion;
    // on POSIX it verifies the pass-through leaves the bytes intact. Written
    // to the current working directory and removed via the matching
    // UTF-8-correct `removeC` so cleanup doesn't reintroduce the ANSI bug.
    const path: [:0]const u8 = "labelle_café_日本_232.tmp";
    const payload = "labelle-assembler#232 utf8 fopen round-trip";

    {
        const fp = openC(path, "wb") orelse return error.OpenWriteFailed;
        defer _ = std.c.fclose(fp);
        try std.testing.expectEqual(payload.len, std.c.fwrite(payload.ptr, 1, payload.len, fp));
    }
    defer std.debug.assert(removeC(path));

    var buf: [128]u8 = undefined;
    const fp = openC(path, "rb") orelse return error.OpenReadFailed;
    defer _ = std.c.fclose(fp);
    const n = std.c.fread(&buf, 1, buf.len, fp);
    try std.testing.expectEqualStrings(payload, buf[0..n]);
}

test "utf8PathToWideZ is bounds-safe at and over the buffer limit" {
    // Small buffer so the boundary is easy to hit exactly. One slot is
    // reserved for the NUL, so the longest path that fits is `buf.len - 1`.
    var buf: [8]u16 = undefined;

    // buf.len - 1 (7) ASCII chars fit, with the terminator at index 7.
    {
        const w = try utf8PathToWideZ(&buf, "abcdefg");
        try std.testing.expectEqual(@as(usize, 7), w.len);
        try std.testing.expectEqual(@as(u16, 0), buf[7]);
        try std.testing.expectEqual(@as(u16, 'a'), w[0]);
    }

    // Exactly buf.len (8) chars would need an 8th unit + a NUL = 9 > 8, so it
    // must be rejected — this is the case that previously wrote buf[8] OOB.
    try std.testing.expectError(error.PathTooLong, utf8PathToWideZ(&buf, "abcdefgh"));

    // Well over the limit is likewise safe (error, not panic/overflow).
    try std.testing.expectError(error.PathTooLong, utf8PathToWideZ(&buf, "abcdefghijklmnop"));

    // A zero-length path still fits and produces an empty NUL-terminated slice.
    {
        const w = try utf8PathToWideZ(&buf, "");
        try std.testing.expectEqual(@as(usize, 0), w.len);
        try std.testing.expectEqual(@as(u16, 0), buf[0]);
    }
}
