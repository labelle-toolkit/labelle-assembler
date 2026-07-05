//! Preview snippets for callback-style backends (sokol, raylib wasm):
//! init / cleanup / heartbeat. Extracted from `preview.zig`.

/// Init-callback preview block. Runs once at startup, AFTER
/// `g = AssembledGame.init(...)` — `g.preview` is the canonical
/// storage; no module-level `_preview` needed.
///
/// Note: the original `catch &[_][:0]u8{}` form gave `_argv` a
/// `[]const [:0]u8` type, which doesn't satisfy `argsFree`'s
/// `[][:0]u8` parameter. The `if/else |_|` shape pulls the alloc
/// success path into its own scope where `_argv`'s type matches.
pub const PREVIEW_INIT_CALLBACK =
    \\    // ── Preview mode (labelle-assembler#94, labelle-engine#520) ──
    \\    // Sokol callback path: connect once in `init`, frame-callback
    \\    // pulses the heartbeat, cleanup-callback sends bye. Storage is
    \\    // `g.preview` (Game owns the lifecycle); see PREVIEW_LOOP_SETUP
    \\    // above for the env-var rationale.
    \\    if (_preview_getenv("LABELLE_PREVIEW")) |_env_z| {
    \\        const _host_port = std.mem.span(_env_z);
    \\        if (_host_port.len > 0) {
    \\            var _preview_threaded = std.Io.Threaded.init(allocator, .{});
    \\            defer _preview_threaded.deinit();
    \\            g.preview = engine.Preview.connect(_preview_threaded.io(), allocator, _host_port) catch |err| blk: {
    \\                std.debug.print("labelle: preview-mode connect to '{s}' failed: {s}\n", .{ _host_port, @errorName(err) });
    \\                break :blk null;
    \\            };
    \\            if (g.preview) |*_p| {
    \\                _p.sendHello("labelle-engine", 0) catch {};
    \\                // labelle-assembler#140 Phase B: wire the engine.Preview
    \\                // methods into the backend's preview_mtl vtable so the
    \\                // backend can drive IOSurface stream lifecycle without
    \\                // needing an engine type-import. Bridges declared at
    \\                // module scope (see PREVIEW_READBACK_HELPERS_METAL_SOKOL).
    \\                if (comptime @hasDecl(window, "preview_mtl")) {
    \\                    window.preview_mtl.attach(.{
    \\                        .ctx = @ptrCast(_p),
    \\                        .beginStream = _preview_mtl_begin_stream_bridge,
    \\                        .getSurfaceAt = _preview_mtl_get_surface_bridge,
    \\                        .signalSlotReady = _preview_mtl_signal_bridge,
    \\                        .endStream = _preview_mtl_end_stream_bridge,
    \\                        .isFrameAccepted = _preview_mtl_accepted_bridge,
    \\                    });
    \\                }
    \\                if (comptime @hasDecl(window, "hideWindow")) window.hideWindow();
    \\            }
    \\        }
    \\    }
    \\
;

/// Cleanup-callback preview teardown. Only emits the graceful `bye`
/// frame — `Game.deinit` (called by `{{cleanup_code}}` immediately
/// after) owns the actual socket + arena teardown
/// (labelle-engine#520).
pub const PREVIEW_CLEANUP_CALLBACK =
    \\    if (g.preview) |*_p| _p.sendBye(.normal) catch {};
    \\
;

/// Heartbeat for sokol's frame callback (one extra indent level vs.
/// the loop variant, since sokol's `frame` body sits at function scope
/// not inside a `while`).
///
/// Same poll-before-write ordering as the loop variant: drain any
/// `subscribe` / `unsubscribe` frames the editor sent BEFORE the
/// heartbeat write so a malformed subscription can't poison the
/// outbound flush. See the loop variant for the full rationale.
pub const PREVIEW_HEARTBEAT_CALLBACK =
    \\    if (g.preview) |*_p| {
    \\        _p.pollSubscription() catch {};
    \\        _p.tickHeartbeat(_preview_now_ms()) catch {};
    \\        while (_p.popInputEvent()) |_ev| {
    \\            switch (_ev) {
    \\                .mouse_pos => |_m| _preview_input_mouse_pos(_m.x, _m.y),
    \\                .mouse_button => |_m| _preview_input_mouse_button(_m.button, _m.down),
    \\            }
    \\        }
    \\    }
    \\
;
