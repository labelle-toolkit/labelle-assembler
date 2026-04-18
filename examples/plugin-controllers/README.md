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

4. **Null-backend lifecycle coverage** — the example runs on the
   `.null` backend (introduced in PR
   [#74](https://github.com/labelle-toolkit/labelle-assembler/pull/74)).
   The generated `main()` runs the engine's tick loop for a fixed
   number of frames (controlled by `LABELLE_NULL_FRAMES`, default 5)
   and then falls through to the `defer`-bound teardown — meaning
   `PluginControllers.deinit(&g)` is observed at runtime, not just in
   the codegen-snapshot tests. Closes the runtime coverage gap PR #73
   had to leave open because raylib's hidden-window loop can't exit
   cleanly.

## Layout

```
examples/plugin-controllers/
├── project.labelle                # .backend = .null, declares the fixture plugin
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

The CI `Runtime log-order check` step diffs stderr against this
canonical sequence:

```
[demo-plugin] setup
[game] game-tick frame=1
[demo-plugin] plugin-tick frame=1
[game] game-tick frame=2
[demo-plugin] plugin-tick frame=2
…
[game] game-tick frame=5
[demo-plugin] plugin-tick frame=5
[demo-plugin] deinit
```

`setup` appears once, before any tick. Within each tick, the `[game] …`
line precedes the `[demo-plugin] plugin-tick …` line because block-1
(game) scripts run before block-2 (plugin) scripts — see
`ScriptScanner.scanPluginDir` and the `PluginBlockOrdering` tests in
`test/script_scanner_tests.zig`. The trailing `[demo-plugin] deinit`
line is the runtime proof that `defer PluginControllers.deinit(&g)` is
both wired and reached, which the prior raylib-based incarnation could
only assert at the codegen layer.

## How this works (null-backend tick loop)

The `.null` backend (`backends/null/`) ships pure-Zig no-op stubs for
every gfx / input / audio / window symbol the engine expects, plus a
`templates/desktop.txt` that emits a `main()` shaped like:

```zig
pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var hooks = GameHooks{};
    var g = AssembledGame.init(allocator);
    defer g.deinit();
    g.setHooks(&hooks);

    // setup_code (loads scenes, calls runner.setup, calls
    // PluginControllers.setup, registers `defer PluginControllers.deinit`)
    …

    const max_frames = getMaxFrames(allocator);   // LABELLE_NULL_FRAMES, default 5
    const dt: f32 = 1.0 / 60.0;
    var frame: u32 = 0;
    while (frame < max_frames) : (frame += 1) {
        // tick_code (runner.tick + PluginSystems.tick blocks)
        …
        g.tick(dt);
    }
}
```

No window init, no GL context, no input poll, no `windowShouldClose()`
guard — the loop terminates on the frame counter and falls through to
the `defer` chain, which is what produces the trailing
`[demo-plugin] deinit` line.

That's it. Why this replaces the xvfb dance:

- **Raylib's main loop** polled `window.windowShouldClose()`, which only
  flips on ESC / user-initiated close. A hidden-window CI run could
  never reach either, so the previous incarnation wrapped execution in
  `xvfb-run … timeout 3 ./game` and accepted exit code 124 (SIGTERM).
- **The null backend** has no window to poll, so the bounded `for` loop
  is enough. CI runs `./game` directly, expects exit code 0, and
  diffs the captured log against the fixed expected sequence.

## Running locally

```sh
cd examples/plugin-controllers

# labelle-cli's bundled generator is pinned to a release that predates
# the `.null` Backend variant — invoke the assembler binary directly
# until labelle-cli bumps its assembler dep past PR #74.
../../zig-out/bin/labelle-assembler generate --project-root .

cd .labelle/null_desktop
zig build
./zig-out/bin/game            # default: 5 frames, exits cleanly

# Override the frame count for longer / shorter runs
LABELLE_NULL_FRAMES=20 ./zig-out/bin/game
```

The first `zig build` will fail with an
`invalid fingerprint: 0xBAD; … use this value: 0xGOOD` diagnostic
because the assembler intentionally leaves the fingerprint at a
placeholder (labelle-cli normally patches it via a post-generate
`runner.fixFingerprint` pass). Substitute the value Zig prints into
`build.zig.zon` and rerun `zig build`.

## Related

- PR [#73](https://github.com/labelle-toolkit/labelle-assembler/pull/73)
  — plugin-Controller discovery, plugin-shipped scripts, ship_from_plugin
- PR [#74](https://github.com/labelle-toolkit/labelle-assembler/pull/74)
  — null backend (this example's runtime)
- `backends/null/` — the no-op backend's source
