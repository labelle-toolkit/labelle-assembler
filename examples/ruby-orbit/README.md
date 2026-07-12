# ruby-orbit — Ruby gameplay scripting, headless-verified

Showcase game #3 for [labelle-toolkit#607](https://github.com/labelle-toolkit/labelle-assembler/issues/607)
— the ticket's Ruby seed candidate, and the Ruby counterpart of the
in-repo Lua `scripting-smoke`. A single `scripts/orbit.rb` script drives the
REAL engine through the Script Runtime Contract (labelle-engine#749),
headless over the null backend.

## What it demonstrates

The **Ruby scripting** cell of the showcase grid via `labelle-scripting`:

- A plain-hooks Ruby script (`init` / `update` / `deinit`) that creates
  an entity, writes/reads its `Position` through the contract each frame,
  and reacts to the engine's own `engine__tick` event.
- The assembler's scripting splice: `scripts/*.rb` is embedded and
  `registerScript`-ed into the generated `main`, the null backend's
  `script_contract.bind` touchpoint boots the mruby VM, and per-frame
  `Controller.tick` + `drainEvents` run the script over the live engine.
- Ruby's non-declare path: the assembler's declare phase SKIPS for ruby
  (declare is lua-only today) with a note — scripts still run.

## Wiring (mirrors labelle-scripting's `examples/ruby-game`)

- The scripting plugin is pinned `local:../../../labelle-scripting` — the
  sibling working tree — so this exercises the CURRENT plugin (vendored
  mruby, prelude, bindings), not a release. `.params.language = "ruby"`
  selects Ruby, validated at generate against the plugin's params_schema.
- The backend is an explicit `backend_package` pinned to the labelle-null
  SIBLING, because the generated main's `script_contract.bind` touchpoint
  lives in labelle-null's `templates/headless.txt` and the registry
  release predates it (same reason the Lua scripting-smoke pins it).
- core/engine/gfx resolve through `local:` siblings — the in-repo
  convention (see `docs/showcase-plan.md` for the showcase-repo pin
  delta).

## Build & run (headless)

Needs the `labelle-null` and `labelle-scripting` siblings checked out
beside this repo (CI clones `labelle-null`; `labelle-scripting` is a
toolkit repo). The first build compiles the vendored mruby (a minute or
two), then:

```bash
ASM=../../zig-out/bin/labelle-assembler
$ASM install  --project-root .
$ASM generate --project-root .          # → .labelle/null_desktop/ (+ declare-skip note)
cd .labelle/null_desktop && zig build   # apply the CLI fixFingerprint rewrite
LABELLE_NULL_FRAMES=5 ./zig-out/bin/ruby_orbit
```

The transcript is deterministic — a showcase-repo CI step pins the
ordered `RUBY_*` sequence exactly as labelle-scripting's ruby-example
does:

```text
RUBY_INIT
RUBY_MOVED_X_10.0
RUBY_MOVED_X_20.0
RUBY_ENGINE_TICK_SEEN
RUBY_MOVED_X_30.0
RUBY_MOVED_X_40.0
RUBY_MOVED_X_50.0
RUBY_DONE
```

Each `X` value is only reachable through the previous tick's persisted
`Position` write, so the sequence pins ECS round-tripping through the
real engine, not just liveness. `RUBY_ENGINE_TICK_SEEN` lands on tick 3
because event subscriptions activate at a drain boundary (one-tick
latency) — see `scripts/orbit.rb` for the frame-by-frame timeline.
