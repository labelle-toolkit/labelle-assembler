//! Minimal fixture plugin root module for the plugin-controllers E2E example.
//!
//! Exports only a `Controller` with `setup` and `deinit` lifecycle hooks.
//! The assembler's `PluginControllers` dispatcher (RFC-plugin-controllers §2,
//! emitted by `src/main_zig.zig::writePluginControllersBlock`) discovers
//! this via `@hasDecl(mod, "Controller")` at comptime and calls
//! `Controller.setup(&g)` on scene load / `Controller.deinit(&g)` on scene
//! unload.
//!
//! No `Systems`, `Components`, `Hooks`, or other plugin machinery — the
//! goal is to prove the Controller discovery path works end-to-end in the
//! smallest possible surface area. A per-frame log line comes from a
//! plugin-shipped script (`scripts/playing/01_plugin_tick.zig`) so the CI
//! log-order assertion can see Controller and script events interleave.

pub const Controller = struct {
    /// Called once after the scene has loaded and plugin Systems have run
    /// their own `setup`. The `!void` signature is intentional — real
    /// controllers may fail to wire external resources and should propagate
    /// the error so the lifecycle panics early instead of limping along.
    pub fn setup(game: anytype) !void {
        game.log.info("[demo-plugin] setup", .{});
    }

    /// Called on scene unload (or game shutdown). `void` — a deinit that
    /// can fail would leak the setup it cannot undo, so the dispatcher
    /// refuses to accept one.
    pub fn deinit(game: anytype) void {
        game.log.info("[demo-plugin] deinit", .{});
    }
};
