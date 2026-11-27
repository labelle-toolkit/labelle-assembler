//! Zig 0.16.0 wasm32-emscripten panic/debug-io workaround snippets
//! (labelle-assembler#141). Extracted from `preview.zig` (behavior-preserving).

// PID is purely informational in the `hello` message — the editor
// uses it for UI display, not for any process management. Earlier
// snippets tried a per-OS comptime branch (`std.posix.getpid()` on
// POSIX, kernel32 on Windows) but `std.posix.getpid` isn't exposed
// in Zig 0.15.2's stdlib (only `std.os.linux.getpid` and
// `std.c.getpid` exist, and the latter requires linking libc which
// not every backend does). Simplest portable fix: send 0. A
// follow-up can wire the real PID once we settle on a stdlib import
// that's universal across our backends.

/// Workaround for Zig 0.16.0 wasm32-emscripten compile failure
/// (labelle-assembler#141). The default panic handler in 0.16.0
/// transitively imports `std.Io.Threaded`, whose posix wrappers fail
/// to type-check against emscripten's signal-enum shape
/// (`std/Io/Threaded.zig:15315` / `std/os/emscripten.zig:215`).
/// Overriding both `std_options_debug_io` and `panic` at the root
/// source keeps the default panic-handler chain from instantiating
/// `std.Io.Threaded`. This is the workaround recommended on the
/// Ziggit forum thread linked below and lands the documented fix
/// inside the generated `main.zig`.
///
/// Fixed upstream on Zig master by PR #31850 (lands in 0.17.0-dev);
/// drop this once labelle-toolkit moves off 0.16.x.
///
/// NOTE: this only neutralises the *implicit* path from the panic
/// handler. The generated preview-mode block (PREVIEW_INIT_CALLBACK)
/// still calls `std.Io.Threaded.init(...).io()` directly, which
/// re-instantiates the offending type. Skipping that on wasm is a
/// separate follow-up (the preview env-var is never set in a browser
/// context anyway).
///
/// References:
///   https://ziggit.dev/t/0-16-0-wasm32-emscripten-fails-to-build-because-of-default-panic-handler-recommended-workaround/15052
///   PR #31850 (Zig upstream)
///
/// Emitted only when `cfg.platform == .wasm`; lands near the top of
/// the generated `main.zig` so the overrides are at module root (Zig
/// looks up these names there). The log sink bypasses the disabled debug
/// IO, preserving scopes and streaming messages of any length (#834).
pub const WASM_PANIC_WORKAROUND =
    \\
    \\// Zig 0.16.0 wasm32-emscripten: override the default panic handler to
    \\// avoid std.Io.Threaded import (which has broken posix wrappers on
    \\// emscripten). Fixed upstream in 0.17.0-dev (PR #31850); remove this
    \\// once labelle-toolkit moves off 0.16.
    \\// https://ziggit.dev/t/0-16-0-wasm32-emscripten-fails-to-build-because-of-default-panic-handler-recommended-workaround/15052
    \\pub const std_options_debug_io = std.Io.failing;
    \\pub const std_options: std.Options = .{ .logFn = wasmLog };
    \\pub const panic = std.debug.no_panic;
    \\
    \\extern "c" fn printf(fmt: [*:0]const u8, ...) c_int;
    \\
    \\fn wasmLogBytes(bytes: []const u8) void {
    \\    if (bytes.len == 0) return;
    \\    _ = printf("%.*s", @as(c_int, @intCast(bytes.len)), bytes.ptr);
    \\}
    \\
    \\fn wasmLogDrain(w: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
    \\    wasmLogBytes(w.buffered());
    \\    w.end = 0;
    \\    var written: usize = 0;
    \\    for (data[0 .. data.len - 1]) |bytes| {
    \\        wasmLogBytes(bytes);
    \\        written += bytes.len;
    \\    }
    \\    const pattern = data[data.len - 1];
    \\    for (0..splat) |_| wasmLogBytes(pattern);
    \\    return written + pattern.len * splat;
    \\}
    \\
    \\// std.log's default sink uses the disabled debug IO above. Route it through
    \\// Emscripten's console-backed printf instead (labelle-assembler#834).
    \\fn wasmLog(comptime level: std.log.Level, comptime scope: @EnumLiteral(), comptime fmt: []const u8, args: anytype) void {
    \\    var buf: [1024]u8 = undefined;
    \\    var writer: std.Io.Writer = .{ .vtable = &.{ .drain = wasmLogDrain }, .buffer = &buf };
    \\    writer.writeAll(level.asText()) catch return;
    \\    if (scope != .default) writer.print("({t})", .{scope}) catch return;
    \\    writer.writeAll(": ") catch return;
    \\    writer.print(fmt, args) catch return;
    \\    writer.writeByte('\n') catch return;
    \\    writer.flush() catch return;
    \\}
    \\
;

/// Reduced form of `WASM_PANIC_WORKAROUND` for backends whose `templates/wasm.txt`
/// ALREADY declares its own `pub const panic` (e.g. bgfx's browser-console
/// handler). Emitting the full workaround's `panic = no_panic` there is a
/// duplicate root decl, but the `std_options_debug_io` override is STILL required
/// and is INDEPENDENT of `panic`: `std.Options.debug_io` (std/std.zig) resolves to
/// the `std.Io.Threaded`-backed `debug_threaded_io` UNLESS root declares
/// `std_options_debug_io` — and that Threaded path is what fails to compile for
/// wasm32-emscripten on Zig 0.16 (labelle-assembler#141). So emit ONLY the
/// debug-io override here; the backend template owns `panic` (+ typically
/// `std_options`). Dropped once labelle-toolkit moves off Zig 0.16.x (PR #31850).
pub const WASM_DEBUG_IO_WORKAROUND =
    \\
    \\// Zig 0.16.0 wasm32-emscripten: override the default debug IO so the
    \\// std.Io.Threaded path (broken posix wrappers on emscripten) is never
    \\// instantiated. The backend's wasm template supplies its own `pub const
    \\// panic`, so only this half of the labelle-assembler#141 workaround is
    \\// emitted here. Fixed upstream in 0.17.0-dev (PR #31850).
    \\// https://ziggit.dev/t/0-16-0-wasm32-emscripten-fails-to-build-because-of-default-panic-handler-recommended-workaround/15052
    \\pub const std_options_debug_io = std.Io.failing;
    \\
;
