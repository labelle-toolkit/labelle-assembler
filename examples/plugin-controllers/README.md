# plugin-controllers

Minimal end-to-end example for the plugin-Controller machinery introduced
in PR [#73](https://github.com/labelle-toolkit/labelle-assembler/pull/73)
([RFC flying-platform-labelle#208](https://github.com/Flying-Platform/flying-platform-labelle/blob/main/docs/RFC-plugin-controllers.md)).

## What it demonstrates

1. **`Controller` discovery** — `plugin/src/root.zig` exports
   `pub const Controller = struct { setup, deinit, … }`. The assembler's
   `writePluginControllersBlock` (see `src/main_zig.zig`) scans every
   plugin module at comptime via `@hasDecl(mod, "Controller")` and emits
   a `PluginControllers` dispatcher that `main()` calls on scene load
   (`setup`) and scene unload (`deinit` via `defer`).

2. **Plugin-shipped scripts** — `plugin/scripts/playing/01_plugin_tick.zig`
   is copied by `generate()` into
   `<target>/scripts/.plugin_demo_plugin/playing/…` and registered as a
   plugin-namespaced script block. It runs after the game's own scripts
   each tick, producing the interleaved log output the CI test asserts.

3. **`ship_from_plugin` convention mode** — `plugin/plugin.labelle`
   declares a `demo_playbooks/` directory with
   `.mode = .ship_from_plugin`. The assembler's plugin-manifest loop
   copies that directory out of the plugin's cached package into the
   generated build target. The example itself doesn't use the copied
   content; the entry exists so the new convention mode is exercised by
   a real `labelle generate` run rather than only by unit tests.

## Layout

```
examples/plugin-controllers/
├── project.labelle                # declares the fixture plugin via local:./plugin
├── scenes/main.jsonc              # empty scene, no entities
├── scripts/playing/01_game_tick.zig
├── README.md                      # this file
└── plugin/                        # fixture plugin
    ├── build.zig
    ├── build.zig.zon
    ├── plugin.labelle             # manifest_version = 1, demo_playbooks ship_from_plugin
    ├── demo_playbooks/README.zig  # no-op smoke-test file for the ship_from_plugin copy pass
    ├── src/root.zig               # Controller.setup / Controller.deinit
    └── scripts/playing/01_plugin_tick.zig
```

## Expected log sequence

The CI `Runtime log-order check` step greps stderr for the canonical
sequence:

```
[demo-plugin] setup
[game] game-tick frame=1
[demo-plugin] plugin-tick frame=1
[game] game-tick frame=2
[demo-plugin] plugin-tick frame=2
…
```

`setup` appears once, before any tick. Within each tick, the `[game] …`
line precedes the `[demo-plugin] plugin-tick …` line because block-1
(game) scripts run before block-2 (plugin) scripts — see
`ScriptScanner.scanPluginDir` and the `PluginBlockOrdering` tests in
`test/script_scanner_tests.zig`.

### Why no `[demo-plugin] deinit` at runtime?

raylib's main loop polls `window.windowShouldClose()`, which only flips
on ESC / user-initiated close — neither of which a hidden-window CI run
can deliver. The generated code still emits
`defer PluginControllers.deinit(&g)`; the assertion that it's wired
correctly lives in the snapshot tests
(`test/tests.zig::PLUGIN_CONTROLLERS`) which compile-check the string
content of `main.zig`. The runtime test covers what snapshots can't —
that the generated code actually compiles and runs — by asserting the
setup + tick order.

## Running locally

```sh
cd examples/plugin-controllers
labelle generate
cd .labelle/raylib_desktop
zig build
timeout 3 ./zig-out/bin/plugin_controllers_demo 2>&1 | head -40
```

The project declares `.hidden = true`, so raylib creates its OpenGL
context without a visible window. On Linux the context still requires a
display server — CI wraps the run in `xvfb-run`. The game itself quits
via `game.quit()` on frame 5, but raylib's main loop polls
`window.windowShouldClose()` which only flips on ESC or an explicit
window close; `timeout` is what guarantees bounded runtime in CI.
