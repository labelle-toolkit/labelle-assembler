# hook-order — explicit hook dispatch order, proven headless

Acceptance example for
[labelle-assembler#723](https://github.com/labelle-toolkit/labelle-assembler/issues/723)
(child of the hooks epic
[labelle-engine#854](https://github.com/labelle-toolkit/labelle-engine/issues/854)).
Contract: [`docs/design/hook-handler-ordering.md`](../../docs/design/hook-handler-ordering.md).

## What it demonstrates

Dispatch order is only observable when **two** receivers handle the **same**
event, so that is exactly what this game is:

- `events/pulse.zig` — one event, folded into `GameEvents` as `pulse`.
- `scripts/playing/10_emitter.zig` — emits it once per frame.
- `hooks/a_first.zig`, `hooks/z_second.zig` — two game-root hooks, both
  with a `pulse` method.

By default the assembler orders game-root hooks lexicographically by stem,
so `a_first` would run before `z_second` — an order that falls out of
*discovery*, not out of any decision the author made. `project.labelle`
declares:

```zig
.hooks = .{
    .order = .{
        .{ .handler = "hooks/z_second", .rank = 100 },
    },
},
```

and the runtime transcript inverts:

```text
[order] emit n=1
[order] z_second n=1
[order] a_first n=1
[order] emit n=2
[order] z_second n=2
[order] a_first n=2
…
```

Delete the `.hooks` block, re-generate, and the transcript returns to
`a_first` before `z_second`. That A/B is the proof that the declaration —
not the filenames — decides.

## Where to look in the generated code

`.labelle/null_desktop/main.zig` carries the resolved order as a comment
immediately above the receiver tuple, emitted only because this project
declares an order:

```zig
// Hook receiver dispatch order (labelle-assembler#723). `.hooks.order` is
// declared in project.labelle, so this sequence is explicit. ONE tuple,
// walked in this order for EVERY event; on a consumable event the first
// receiver that returns `true` stops the walk.
//   [0] rank   100 * hooks/z_second
//   [1] rank     0   hooks/a_first
// (* = rank declared in project.labelle `.hooks.order`)
const GameHooks = engine.MergeHooks(AllHookPayloads, .{ *z_u_second.ZSecond, *a_u_first.AFirst, });
```

The `handler` strings in `project.labelle` are those same ids. They are
source paths, so they survive ident mangling (`z_second` → `z_u_second`)
and stay stable when unrelated hook files are added or removed — which is
why labelle-assembler#724's route inspector and labelle-engine#858's
tracing key on them too.

## Build & run (headless)

```bash
ASM=../../zig-out/bin/labelle-assembler
$ASM install  --project-root .
$ASM generate --project-root .          # → .labelle/null_desktop/
cd .labelle/null_desktop && zig build
LABELLE_NULL_FRAMES=4 ./zig-out/bin/hook_order
```

## A note on consumable events

`pulse` is a notification event, so both receivers always run and order
decides only *when*. On a **consumable** event `MergeHooks.emit` stops at
the first receiver that returns `true` — there, order decides *whether* a
later receiver sees the event at all. Same tuple, same contract; the
consumable case is just where getting it wrong is silent.
