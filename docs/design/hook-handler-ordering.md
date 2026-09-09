# Design: explicit native hook-handler ordering

Status: **implemented** — labelle-assembler#723, child of the hooks epic
labelle-engine#854. This document is the *ordering contract*: it is the thing
labelle-assembler#724 (static route inspector) and labelle-engine#858 (opt-in
tracing) build on, so it pins the identity, the default sequence, the opt-in
declaration and — explicitly — what is **not** guaranteed.

Read §2 for what a project can rely on today without changing anything, and §4
for the opt-in syntax.

---

## 1. Problem — one implicit order and one explicit order, unrelated

The generated `main.zig` wires every hook receiver into a single tuple:

```zig
const GameHooks = engine.MergeHooks(AllHookPayloads, .{
    *animation_u_hooks.AnimationHooks,
    *plugin_u_controllers_u_hooks.PluginControllersHooks,
    *ui_u_kit_u_hooks.UiKitHooks,
    *transport__transport_u_hooks.TransportHooks,
    *combat__raid_u_hooks.RaidHooks,
    …
});
```

(That literal is from Flying Platform's `.labelle/bgfx_desktop/main.zig`: three
game-root hooks followed by seven pack hooks.)

`MergeHooks.emit` walks that tuple **in tuple position order**, so tuple order
*is* dispatch order. Before this change, tuple order was produced by two
mechanisms that never met:

1. **Native hooks** (`hooks/**/*.zig` in the game root and in packs) had no
   declaration at all. Their order fell out of `scanner.linkAndScan`'s
   lexicographic stem sort, followed by pack-declaration order — an artifact of
   *discovery*, not an authored decision. An author could neither express "this
   one first" nor discover the current answer without reading generated code.
2. **Flow handlers** (`scripts/flows/**/*.flow.jsonc` → `FlowEventHandler`) had
   `ScriptEntry.event_priority`, an `i32` sorted descending — but only *within
   the flow tail*, which is appended after every native hook.

So there were two currencies, one of them invisible, and the visible one was
scoped to a subgroup. The epic names this directly: *"Native hooks follow
generated receiver order; flow handlers have a separately ordered priority
tail."*

Two facts shaped the design:

- **`MergeHooks` takes one tuple for all events.** There is no per-event
  receiver list. Any ordering contract the assembler can offer today is
  therefore **per receiver and global across events**, not per event. Promising
  per-event ordering would be a lie the generated code cannot keep.
- **Flow `event_priority` is currently unreachable from disk.** Post
  RFC-FLOW-VOCABULARY phase 6 the `event:` header that carried `priority` is
  gone, and `flow_scanner.zig` reads `null` for every parsed flow (see the
  comment at `src/flow_scanner.zig:328`). The field and its sort survive for
  forward compatibility. That means folding it into a new scheme could not
  regress any real project — but it also means it is not a currency worth
  building the new contract *on*.

---

## 2. The contract

### 2.1 One sequence, walked for every event

The generated receiver tuple is a **single totally ordered sequence**. The
dispatcher walks it in order for every event it delivers. Consequently:

- For a **notification** event, order decides the order side effects happen in.
- For a **consumable** event, order decides *who gets first refusal*:
  `MergeHooks.emit` stops at the first handler that returns `true`. A receiver
  placed earlier can consume an event before a later receiver ever sees it.
- Ordering is a property of the **receiver**, not of the (receiver, event) pair.
  Moving a receiver moves it for every event it handles.

### 2.2 Stable receiver identity

Every receiver has an **id**: its source file path, relative to the generated
target root, without the `.zig` extension.

| Group | Id shape | Example |
| --- | --- | --- |
| Game-root hook | `hooks/<stem>` | `hooks/animation_hooks`, `hooks/ui/toolbar` |
| Pack hook | `<pack import prefix>/hooks/<stem>` | `packs/citizens/hooks/needs_hooks` |
| Flow handler | `<import base><rel path>` minus `.zig` | `scripts/flows/hit_counter` |

Properties that make this the right key for #724 and #858:

- **Source-oriented.** It is a path the author can open. Diagnostics can quote
  it; an inspector can print it; a tracer can label a frame with it.
- **Stable.** It does not move when an unrelated hook file is added or removed,
  unlike a tuple index. It survives ident mangling
  (`pathToIdent`/`pathToPascal`, `<pack>__` prefixes) because it is derived from
  the path *before* mangling.
- **Unique by construction.** Two receivers cannot share a path. Pack hooks are
  disambiguated by the pack's `import_prefix`, which is already unique per pack.
- **Not save-stable.** Renaming a pack changes its hook ids (as it already
  changes its component save keys). Renaming a hook file changes its id. Both
  are source edits, and a `.hooks.order` entry naming the old id fails loudly
  (§5) rather than silently reverting to default order.

The exported Zig surface is `codegen/blocks/hooks.zig`:

```zig
pub const ReceiverKind = enum { root_hook, pack_hook, flow_handler };
pub const Receiver = struct { kind, id, index, pack_index, rank, declared, baseline };
pub const ReceiverPlan = struct { receivers: []Receiver, … };
pub fn buildReceiverPlan(allocator, cfg, hook_names, pack_scans, script_entries) !ReceiverPlan
```

`buildReceiverPlan` is the **single** producer of dispatch order. Both the
`GameHooks` type tuple and the `hooks_init` instance tuple are emitted by
iterating the same `plan.receivers` slice, so "generated receiver types and
instances remain in matching order" is now structural rather than a comment
asking two loops to agree. #724 should call `buildReceiverPlan` rather than
re-deriving order, which is what makes "static route inspection reports the same
order used for dispatch" true by construction.

### 2.3 The default sequence (unchanged)

With no ordering declared, the sequence is exactly what the assembler emitted
before this change:

1. **Game-root hooks** — `hooks/**/*.zig` stems, ascending lexicographic by stem
   path (`scanner.linkAndScan` sorts them).
2. **Pack hooks** — packs in the order their pack dirs are scanned, and within a
   pack, stems ascending lexicographic.
3. **Flow handlers** — entries with `event_priority` set first, descending by
   priority; then the remainder in scanner order (numeric prefix, then
   alphabetical). Ties inside either bucket keep scanner order.

This sequence is the **baseline**. Everything in §4 is a stable perturbation of
it.

### 2.4 Guaranteed vs incidental

**Guaranteed**

- The three groups appear in the order root → pack → flow, absent an explicit
  declaration.
- Lexicographic stem order within the root group and within one pack.
- The sort is **stable**: equal keys never reorder, so a build is deterministic
  and re-running `generate` on unchanged input produces byte-identical output.
- The type tuple and the instance tuple are index-by-index identical.
- A declaration moves only the receivers it names. Every other pair of receivers
  keeps its relative order, so declaring an order for two handlers of event `X`
  cannot silently reshuffle the handlers of an unrelated event `Y`.

**Incidental — do not rely on**

- A receiver's absolute tuple index. Adding a hook file shifts indices.
- Any *meaning* in the relative order of two receivers that no declaration
  mentions. Independent listeners are order-independent by contract; if two
  handlers must run in a particular order, that ordering must be **declared**.
  The assembler will keep today's incidental order working, but it is not a
  promise the toolkit will defend against, say, a future change in pack scan
  order.
- The group boundary as a *barrier*. A declared rank crosses it (§4.2). That is
  deliberate: the alternative is a scheme that cannot express "this pack hook
  must beat that root hook", which is the realistic cross-cutting case.

---

## 3. Priority ranks, not `before`/`after` relations

The issue left the choice open. Ranks won for four reasons:

1. **There is already a rank currency.** Flow `event_priority` is an `i32`
   sorted descending. Introducing `before`/`after` would have made *three*
   mechanisms, not one.
2. **Ranks are total; relations are partial.** A partial order needs a
   topological solve, a deterministic tie-break *inside* the solve, and cycle
   detection. Each of those is a place where the answer the inspector prints and
   the answer the dispatcher walks can drift apart. Ranks have exactly one
   answer, computable by a stable sort.
3. **Ambiguity becomes structurally impossible.** With `(rank desc, baseline
   asc)` as the key and ids unique, there is no ambiguous input to diagnose —
   the only invalid inputs are *unknown handler* and *duplicate handler*, both
   trivially checkable (§5). The acceptance item about cycles is satisfied by
   not having a construct that can cycle.
4. **It is explainable in one line.** #858's trace can say `rank 100 (declared)`
   or `rank 0 (default, baseline 3)`; #724 can print the same. A relation-based
   scheme would have to explain a solve.

The cost is the well-known one: bare numbers age badly and invite magic
constants. Mitigations: rank `0` is the default so most projects declare
nothing; ranks are per-project (not a global registry a plugin can squat); and
the generated file carries a rendered order comment (§4.3) so the resolved
answer is always visible next to the code it governs.

---

## 4. Opt-in declaration

### 4.1 Syntax

In `project.labelle`:

```zig
.{
    .name = "my_game",
    …
    .hooks = .{
        .order = .{
            .{ .handler = "packs/citizens/hooks/status_overlay_hooks", .rank = 100 },
            .{ .handler = "hooks/animation_hooks",                     .rank = -50 },
        },
    },
}
```

- `.handler` — a receiver id from §2.2. Must match a discovered receiver exactly.
- `.rank` — `i32`, default `0`. **Higher runs earlier.**

Absent `.hooks`, or with an empty `.order`, nothing changes: every receiver has
rank `0`, the sort is the identity on the baseline, and the generated file is
byte-identical to what the previous assembler produced.

### 4.2 Resolution

```
sort key = (rank descending, baseline index ascending)   — stable sort
```

That is: the baseline (§2.3) is resolved *first*, in full, including the flow
tail's `event_priority` bucketing. Ranks are then applied over the resolved
baseline as the outer key. Concretely:

- A rank `> 0` promotes a receiver ahead of every rank-`0` receiver, including
  ones in an earlier group. A pack hook can be made to run before a game-root
  hook; a flow handler can be made to run before both.
- A rank `< 0` demotes a receiver behind every rank-`0` receiver.
- Two receivers with the same rank keep their baseline order.
- Receivers nobody declared keep their baseline order relative to each other,
  always.

### 4.3 How native ordering composes with the flow priority tail

They compose as **baseline shaping** and **ranking**, and the two levels are not
interchangeable:

| | Flow `event_priority` | `.hooks.order` rank |
| --- | --- | --- |
| Declared in | `.flow.jsonc` (currently unreachable — §1) | `project.labelle` |
| Scope | Flow handlers only, among themselves | Every receiver, all three groups |
| Level | Shapes the **baseline** sequence | Outer sort key **over** the baseline |
| Applies to | Group 3 only | Groups 1, 2 and 3 |

So a flow with `priority = 100` sorts ahead of other flows but still after every
game-root and pack hook — because it shapes the baseline, and the baseline puts
the flow tail last. To move that flow ahead of a native hook, name it in
`.hooks.order`; flow handlers have ids like any other receiver and are
first-class there.

This is the deliberate answer to *"do not silently promise a global priority
while sorting only a subgroup"*: `event_priority` is documented as subgroup
scoped and stays that way, and the one mechanism that *is* global is the one
that says so. When both apply to the same flow handler, the rank is the outer
key and the priority still orders it against equally-ranked flows.

Migration: none is required, and none is forced. `event_priority` keeps working
exactly as before. When a graph-form expression for flow priority returns, the
recommendation is to keep it subgroup-scoped and point cross-group cases at
`.hooks.order`, so there stays exactly one global mechanism.

### 4.4 What the generated file shows

When — and only when — `.hooks.order` is non-empty, the emitter writes a
rendered order comment immediately above `const GameHooks`:

```zig
// Hook receiver dispatch order (labelle-assembler#723). `.hooks.order` is
// declared in project.labelle, so this sequence is explicit. ONE tuple,
// walked in this order for EVERY event; on a consumable event the first
// receiver that returns `true` stops the walk.
//   [0] rank  100 * packs/citizens/hooks/status_overlay_hooks
//   [1] rank    0   hooks/animation_hooks
//   [2] rank    0   scripts/flows/hit_counter
// (* = rank declared in project.labelle `.hooks.order`)
const GameHooks = engine.MergeHooks(AllHookPayloads, .{ … });
```

The comment is suppressed for projects that declare nothing, which is what keeps
default output byte-identical.

---

## 5. Diagnostics

Both failures are detected in `buildReceiverPlan`, before any code is emitted,
and both print a source-oriented message to stderr naming `project.labelle`, the
offending handler string, and the full list of discovered ids in default order —
so a typo is one glance from its fix.

| Input | Error |
| --- | --- |
| `.handler` matches no discovered receiver | `error.UnknownHookOrderHandler` |
| Two `.order` entries name the same receiver | `error.DuplicateHookOrderHandler` |

Cycles are impossible by construction (§3). Ambiguity is impossible by
construction: the sort key is total and the tie-break is deterministic.

A note on the unknown-handler being a **hard error** rather than a warning: a
silently ignored ordering declaration is exactly the failure mode this contract
exists to remove. A hook file renamed out from under an `.order` entry must stop
the build, not quietly revert to discovery order.

---

## 6. Scope and non-goals

- **Per-event ordering is out of scope** and cannot be added by the assembler
  alone. `MergeHooks` would need per-event receiver lists; that is a core
  change, and it should not be attempted before there is a consumer that needs
  it. Until then this document is deliberate about saying "per receiver".
- **Group-level ranks** (`.{ .pack = "citizens", .rank = 10 }`) are a plausible
  extension for a project with many hooks from one pack. Left out to keep the
  first contract small; exact ids cover every case, just more verbosely.
- **Manifest/JSON exposure** of the resolved plan belongs to #724, which should
  consume `buildReceiverPlan` rather than duplicating the derivation.
- **Runtime trace labels** belong to #858; the receiver id in §2.2 is the
  intended label.

---

## 7. Verification

- `test/hook_ordering_tests.zig` — default order preserved (including a proof
  that a *declared but rank-0* order emits the same sequence as no declaration
  at all), cross-group promotion and demotion, mixed root/pack/flow groups, tie
  stability, type-tuple/instance-tuple agreement, the order comment's presence
  and absence, and both diagnostics.
- `test/flow_scanner/handler_wiring_tests.zig` — the pre-existing flow-tail
  priority and tie tests are unchanged and still pass, which is the regression
  proof that the baseline was not disturbed.
- `examples/hook-order` — a headless `.null`-backend example with two root hooks
  whose log lines make the execution sequence directly observable, and a
  `.hooks.order` that inverts the lexicographic default.
