# coin-collector — a complete gameplay loop, headless-verifiable

Showcase game for [labelle-toolkit#607](https://github.com/labelle-toolkit/labelle-assembler/issues/607).
Where `parallax-scroll` shows the render stack, this one shows a real
**gameplay loop**: a top-down collect-'em-up that plays itself to a win
condition, entirely in one game script.

## What it demonstrates

A cell the other examples don't cover — per-frame gameplay against a live
ECS world:

- **Queries** — `view(.{Player})` / `view(.{Coin})` each frame.
- **Homing movement** — the player steps toward the nearest coin via the
  engine's `getPosition` / `setPosition`.
- **Collision + pickup** — a radius overlap test collects a coin.
- **Runtime entity destruction** — `destroyEntity` removes a collected
  coin from the world (coins are snapshotted before any destroy so the
  `view` is never mutated mid-iteration).
- **Win condition** — a one-shot `[collector] cleared` when the field
  empties.

Files:

- `components/player.zig` — `Player { speed }`, the homing tag.
- `components/coin.zig` — `Coin { radius }`, the collectible tag.
- `scripts/playing/10_collect.zig` — the whole gameplay loop.
- `scenes/main.jsonc` — the opening board: one player, five coins, a HUD
  badge (unified RFC #560 format — file-level entities under `children`).

## Backend-selectable

Every touchpoint is renderer-agnostic (ECS + Position + entity APIs), so
the game builds **and runs** headless on `.null` for CI — deterministic
fixed `dt`, frame-capped by `LABELLE_NULL_FRAMES`, clean exit — and
renders as-is by flipping one line in `project.labelle`:

```zig
.backend = .raylib,   // or .sokol, or the external .bgfx package
```

## Build & run (headless)

```bash
ASM=../../zig-out/bin/labelle-assembler
$ASM install  --project-root .
$ASM generate --project-root .          # → .labelle/null_desktop/
cd .labelle/null_desktop && zig build
LABELLE_NULL_FRAMES=90 ./zig-out/bin/coin_collector
```

The transcript is deterministic — one line per frame — so a showcase-repo
CI step can pin it:

```text
[collector] frame=1 score=0 coins_left=5
… player homes, coins fall one by one …
[collector] frame=87 score=5 coins_left=0
[collector] cleared
```

Score and `coins_left` are exact each frame (fixed `dt`, fixed board), so
token extraction pins behaviour — the player actually reaching and
destroying each coin — not just liveness. The field clears on frame 87 at
the default `speed = 300`; run with enough frames to see the win.
