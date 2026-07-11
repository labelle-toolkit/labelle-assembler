# event-relay — the game event bus + hooks, in pure Zig

Showcase game for [labelle-toolkit#607](https://github.com/labelle-toolkit/labelle-assembler/issues/607).
The pure-Zig **event bus** cell: no scripting language, no plugin — just
the engine's game event bus and the assembler's game-root convention
scans, wired end to end.

## What it demonstrates

One `game.emit(...)` reaching a native hook over the real engine bus with
zero glue — three game-root convention dirs the assembler scans
automatically:

- `events/pulse.zig` — `pub const Pulse` is folded into the project's
  `GameEvents` union under the tag matching the file stem (`pulse`).
- `scripts/playing/10_emitter.zig` — emits `Pulse` each frame via
  `game.emit(.{ .pulse = .{ .n = ... } })`.
- `hooks/pulse_watcher.zig` — a native hook the assembler folds into the
  generated `GameHooks = MergeHooks(...)` tuple; its `pulse` method
  (named after the `GameEvents` variant) fires at `dispatchEvents`.

It's the Zig twin of the cross-layer interop the scripting examples show
from a script language (cf. labelle-scripting's `feed_watcher.zig`): the
emit and the receive round-trip through `GameEvents`, not a mock.

## Backend-selectable

Engine-level and backend-agnostic (no renderer, no ECS), so it builds
**and runs** headless on `.null` for CI — deterministic, frame-capped,
clean exit — and works unchanged on any graphics backend.

## Build & run (headless)

```bash
ASM=../../zig-out/bin/labelle-assembler
$ASM install  --project-root .
$ASM generate --project-root .          # → .labelle/null_desktop/
cd .labelle/null_desktop && zig build
LABELLE_NULL_FRAMES=4 ./zig-out/bin/event_relay
```

The transcript pairs each emit with the hook's receipt, same frame — a
showcase-repo CI step pins the ordered sequence:

```text
[relay] emit n=1
[relay] pulse n=1
[relay] emit n=2
[relay] pulse n=2
…
```

The `[relay] pulse n=N` line is emitted by the native hook, carrying the
payload `n` — proving the `Pulse` emitted by the script crossed the bus
intact, not just that the hook fired.
