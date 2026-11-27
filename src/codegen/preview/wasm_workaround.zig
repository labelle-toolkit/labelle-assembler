//! Zig 0.16.0 wasm32-emscripten panic/debug-io workaround snippets
//! (labelle-assembler#141). Extracted from `preview.zig` (behavior-preserving).

/// Workaround for Zig 0.16.0 wasm32-emscripten compile failure
/// (labelle-assembler#141). The default panic handler in 0.16.0
/// transitively imports `std.Io.Threaded`, whose posix wrappers fail
/// to type-check against emscripten's signal-enum shape
/// (`std/Io/Threaded.zig:15315` / `std/os/emscripten.zig:215`).
/// Overriding both `std_options_debug_io` and `panic` at the root
/// source keeps the default panic-handler chain from instantiating
/// `std.Io.Threaded`.
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
pub const WASM_DEBUG_IO_WORKAROUND =
    \\
    \\// Zig 0.16.0 wasm32-emscripten: keep std.Io.Threaded (whose emscripten
    \\// posix wrappers are broken) out of the default debug-io path. Panic and
    \\// std_options ownership are selected independently below (#141, #834).
    \\// Fixed upstream in 0.17.0-dev (PR #31850).
    \\pub const std_options_debug_io = std.Io.failing;
    \\
;

/// `std_options.logFn` component, emitted only when the backend template does
/// not declare its own `std_options`. The sink bypasses the disabled debug IO,
/// preserves scopes, streams messages of any length, and escapes embedded NUL
/// bytes so text after them is not discarded (#834).
pub const WASM_LOG_WORKAROUND =
    \\
    \\pub const std_options: std.Options = .{ .logFn = wasmLog };
    \\
    \\extern "c" fn printf(fmt: [*:0]const u8, ...) c_int;
    \\
    \\fn wasmLogChunk(bytes: []const u8) void {
    \\    if (bytes.len == 0) return;
    \\    _ = printf("%.*s", @as(c_int, @intCast(bytes.len)), bytes.ptr);
    \\}
    \\
    \\fn wasmLogBytes(bytes: []const u8) void {
    \\    var rest = bytes;
    \\    while (std.mem.indexOfScalar(u8, rest, 0)) |nul| {
    \\        wasmLogChunk(rest[0..nul]);
    \\        _ = printf("\\0");
    \\        rest = rest[nul + 1..];
    \\    }
    \\    wasmLogChunk(rest);
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

/// Panic component, emitted only when the backend template does not declare
/// its own root `panic` handler.
pub const WASM_NO_PANIC_WORKAROUND =
    \\
    \\pub const panic = std.debug.no_panic;
    \\
;

/// Full shim for a template that owns neither `panic` nor `std_options`.
pub const WASM_PANIC_WORKAROUND = WASM_DEBUG_IO_WORKAROUND ++ WASM_LOG_WORKAROUND ++ WASM_NO_PANIC_WORKAROUND;

/// Shim for a template that owns `std_options` but not `panic`.
pub const WASM_DEBUG_IO_AND_PANIC_WORKAROUND = WASM_DEBUG_IO_WORKAROUND ++ WASM_NO_PANIC_WORKAROUND;

/// Shim for a template that owns `panic` but not `std_options`.
pub const WASM_DEBUG_IO_AND_LOG_WORKAROUND = WASM_DEBUG_IO_WORKAROUND ++ WASM_LOG_WORKAROUND;
