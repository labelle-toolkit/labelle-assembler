# Design: static hook-route inspection

Status: **implemented** — labelle-assembler#724, child of the hooks epic
labelle-engine#854. Builds directly on the ordering contract in
[`hook-handler-ordering.md`](hook-handler-ordering.md) (#723) and is the
static half of the pair whose runtime half is labelle-engine#858 (opt-in
tracing).

Read §2 for the JSON contract, §3 for the CLI, §5 for what the report
deliberately refuses to claim.

---

## 1. Problem — the routing answer only exists in generated code

The epic states the friction plainly:

> Finding final event names, listeners and delivery paths currently
> requires inspecting generated code or adding ad hoc logging.

Concretely, an author who wants to know *which listeners does
`citizens__needs_low` reach, in what order, and can an earlier one consume
it* has to:

1. open `.labelle/<target>/main.zig` and read the `MergeHooks(...)`
   receiver tuple to recover dispatch order,
2. open each receiver's source and check whether it declares a
   `pub fn citizens__needs_low(...)`,
3. know that a pack event's *final* tag carries an invisible `<pack>__`
   prefix that appears in no filename,
4. know that a plugin event may have been **elided** entirely because
   nothing consumes it (#630), and that this is not an error,
5. and read `labelle-core/src/dispatcher.zig` to learn that a payload
   declaring `pub const consumable = true` makes order decide *whether* a
   later listener runs rather than merely *when*.

Every one of those facts already exists inside the assembler at generate
time. None of it survives the build.

---

## 2. The report

### 2.1 A generate-time sidecar, not a re-scan

`generate` writes `<game>/.labelle/hook_routes.json`, alongside the
existing `manifest.json` (#442) and `flow_catalog.json` (RFC#178)
sidecars. `labelle-assembler routes` reads that file and renders it.

This split is the load-bearing decision.

The obvious alternative — a `routes` command that discovers the project
itself — would have been a **second discovery pipeline**, and the one
failure this feature cannot have is "the inspector said X, the game did
Y". The sidecar is built from the same in-memory scan results that emit
`main.zig`, in the same run, so it is a *record of what was emitted*
rather than an independent opinion about it.

Three consequences fall out, all of them wanted:

- **`routes` needs no package cache, no backend template and no
  renderer.** The issue's *"output works without launching the renderer"*
  is structural here, not something a test has to defend.
- **The command is fast and side-effect-free.** It reads one file.
- **The report is as old as the last `generate`.** That is the cost, and
  it is stated: a missing sidecar makes `routes` say *run `generate`
  first*, and the file carries the assembler version that wrote it.

The sidecar is **project-level**, not per-target: the receiver tuple and
the event universe derive from `project.labelle` plus the convention
dirs, neither of which varies by graphics backend. (Same reasoning
`flow_catalog.json` records for itself.) It is emitted only for the exe
target, never for the `.labelle/tests/` target, which has no `main.zig`.

Emission runs **after** `main.zig` is written. Both call
`buildReceiverPlan`, and a bad `.hooks.order` makes that call fail with a
stderr diagnostic (#723 §5); ordering the sidecar second means the user
sees that diagnostic once, not twice.

### 2.2 One producer of order — no second algorithm

`docs/design/hook-handler-ordering.md` §2.2 is explicit:

> #724 should call `buildReceiverPlan` rather than re-deriving order,
> which is what makes "static route inspection reports the same order used
> for dispatch" true by construction.

`hook_routes/build.zig` does exactly that and reports the returned
`[]Receiver` verbatim — including each receiver's `rank`, `declared` flag
and `baseline` index, so the report can explain *why* a receiver sits
where it does, not merely *that* it does.

"By construction" is still an argument, so the test suite closes it from
the other side. `test/hook_routes_tests.zig` builds a report **and**
generates a `main.zig` through the real emitter from the same inputs, then
parses the `MergeHooks(AllHookPayloads, .{ … })` tuple out of the emitted
text and compares it to the report's receiver sequence **entry by entry**.
A second test asserts that a `.hooks.order` rank moves the report and the
tuple *together*, so the pair cannot pass by being wrong in the same way.

### 2.3 Schema `labelle.hook-routes/v1`

The schema is the Zig type declarations in `src/hook_routes/model.zig`.
Both the writer (`std.json.Stringify`) and the reader
(`std.json.parseFromSliceLeaky`) reflect over those types, so the key set,
the key **order** and the value spellings have exactly one definition, and
there is no hand-written writer that can fall behind a field.

```jsonc
{
  "schema": "labelle.hook-routes/v1",
  "assembler_version": "1.2.3",
  "project": "my_game",
  "ordering": {
    "declared": true,                 // `.hooks.order` is non-empty
    "scope": "receiver",              // NOT per-event — see §4
    "contract": "docs/design/hook-handler-ordering.md"
  },
  "resolution": {                     // read this before trusting an empty array
    "engine_hook_payload": true,
    "emit_sites_scanned": true,
    "emit_sites_files_scanned": 12
  },
  "receivers": [                      // in DISPATCH order
    {
      "order": 0,                     // index in the MergeHooks tuple
      "id": "packs/citizens/hooks/needs_hooks",   // the join key (#723 §2.2)
      "kind": "pack_hook",            // root_hook | pack_hook | flow_handler
      "pack": "citizens",
      "source": "packs/citizens/hooks/needs_hooks.zig",
      "zig_type": "NeedsHooks",
      "rank": 100,
      "rank_declared": true,
      "baseline": 2,                  // position before ranks were applied
      "handlers": ["citizens__needs_low"],
      "handlers_resolved": true
    }
  ],
  "events": [                         // sorted by `tag`
    {
      "tag": "citizens__needs_low",   // the FINAL generated union tag
      "name": "needs_low",
      "owner": "pack",                // game|pack|plugin|engine|engine_hook|script
      "owner_name": "citizens",
      "source": "packs/citizens/events/needs_low.zig",
      "payload": { "zig_type": "NeedsLow",
                   "fields": [ { "name": "level", "zig_type": "f32" } ],
                   "resolved": true },
      "consumable": false,
      "status": "active",             // active | elided | force_kept
      "listeners": [ { "receiver": "packs/citizens/hooks/needs_hooks", "order": 0 } ],
      "emitters": [ { "site": "scripts/playing/20_needs.zig",
                      "delivery": "buffered" } ],   // buffered | sync
      "notes": []
    }
  ],
  "unmatched_handlers": [             // a handler matching no known event
    { "receiver": "hooks/typo_hooks", "handler": "puls",
      "reason": "unknown_event" }     // or engine_payload_unresolved
  ]
}
```

**Stability rules.**

- `Receiver.id` and `Event.tag` are the join keys. #858 should label its
  traces with exactly these strings; no lookup table is needed to
  correlate a trace line with a report row.
- Additive keys do **not** bump `v1`. Every reader must tolerate unknown
  keys — `hook_routes.parseReport` passes `ignore_unknown_fields = true`,
  and a consumer should do the same. Only a breaking key change bumps the
  version segment.
- The document is **deterministic**: no timestamp, no host paths,
  `receivers` in dispatch order, `events` sorted by tag. Re-running
  `generate` on unchanged input produces a byte-identical file, so the
  sidecar is not churn in every commit. A test asserts this, and asserts
  the absence of the build directory path in the output.

### 2.3.1 `generation` is VOLATILE — do not byte-compare two reports

`generation` carries the freshness token described in §2.5, and it is a fresh
random value on **every** `generate`. Two runs over an unchanged project
therefore produce reports that differ by exactly that field — by design, not as
byte-instability to be fixed. The token is what lets `routes` refuse a sidecar
left behind by a generate that failed partway (see `src/generation.zig`); a
stable or content-derived value could not distinguish "regenerated identically"
from "never regenerated", which is the case the whole mechanism exists for.

Consequences for anyone diffing or asserting on reports:

* **Do not byte-compare** two `hook_routes.json` files and expect equality.
  A determinism test must exclude `generation` — everything else in the
  document IS deterministic (no timestamps, no host paths, receivers in
  dispatch order, events sorted by tag), and there is a test asserting exactly
  that.
* **Compare structurally.** Parse both and compare the fields you care about,
  or strip `generation` before diffing.
* **Treat the value as opaque.** Nothing may parse it, order two tokens, or
  infer age from it. The only meaningful operation is equality against the
  marker at `.labelle/generation`.

The same applies to a consumer correlating this report against runtime traces:
join on `Receiver.id` and `Event.tag`, never on `generation`.

### 2.4 Where each field comes from

Most of the report is threaded from scans codegen already ran, so it
cannot drift. Three facts are derived here, and each carries a resolution
flag rather than a confident empty answer:

| Fact | Derivation | Blind spot, and where it is stated |
| --- | --- | --- |
| A receiver's handlers | AST walk for `pub fn <name>(a, b)` members of the receiver's container decl — labelle-core dispatches iff `@hasDecl(Base, @tagName(tag))` names a two-parameter fn | `handlers_resolved = false` when the source is unreadable |
| Engine lifecycle events (`game_init`, `frame_start`, `entity_created`, …) | the `HookPayload` union in the resolved engine package's `src/hooks_types.zig` | `resolution.engine_hook_payload = false`; handlers for them then land in `unmatched_handlers` with `reason = engine_payload_unresolved` |
| Emission call sites | literal-call-site scan of every hook receiver source plus every scanned script, for `emit(.{ .<tag>` (buffered) and `emitSync(.{ .<tag>` (sync) | `emitters: []` means "no literal call site found", never "never emitted"; `resolution.emit_sites_files_scanned` says how much was read |

One implementation note worth recording, because it was a real bug caught
by the fixture: parameter counting must go through `Ast.full.FnProto`'s
**iterator**, not `proto.ast.params.len`. That slice holds only parameters
with a type-expression node — `anytype` is a bare token and is absent from
it. Counting the slice reads
`pub fn on_hit(self: *Hooks, ev: anytype) void` as a one-parameter
function, and `anytype` is the dominant shape in generated flow handlers
and in hooks written against pack events. Every handler in such a file
would have vanished from the report while the receiver still appeared:
confidently empty, the exact failure mode this feature exists to remove.

---

## 3. CLI: `routes`

```
labelle-assembler routes --project-root <path> [--json] [--event <tag>] [--receiver <id>]
```

**On the spelling.** The epic says command names in child issues are
proposals to design. This repo's surface is bare nouns and verbs —
`generate`, `install`, `clean`, `upgrade`, `init`, `check`, `add`. A
flag-shaped (`--inspect-hooks`) or namespaced (`hooks routes`) spelling
would have been the odd one out, and a `hooks` namespace with exactly one
member is a namespace waiting to be wrong. `routes` is the noun for the
thing being shown, collides with none of the existing seven, and leaves
room for a sibling noun later.

`--event` and `--receiver` narrow both output forms. A filter never
renumbers: a receiver keeps the `order` it holds in the full tuple and a
listener keeps its global position, because a filtered view is a lens on
the real sequence, not a re-derived smaller one. A filtered JSON document
is still a valid `labelle.hook-routes/v1` document, so a tool can pipe
`--event X --json` into the same parser it uses for the whole file.

**`routes` inspects; it does not enforce.** It exits 0 whenever it could
produce a report, even one listing a handler that matches no event. The
issue is explicit that *"intentionally unobserved events are not
automatically errors"*, and this repo already has an enforcement command
(`check`) with an allowlist and a non-zero exit. An inspector that failed
builds would be a second, weaker lint. It exits non-zero only when it
cannot produce a report at all: no sidecar (run `generate`), or a schema
it does not recognise.

`PROTOCOL_VERSION` goes to **6**. The bump is additive — an older CLI
driving a newer binary is unaffected, and a newer CLI can require `>= 6`
to know `routes` exists.

### 3.1 The human form

Three sections, in the order the questions are actually asked:

1. **Dispatch order** — the one receiver tuple, since everything else is
   a filter over it. Each row carries rank, kind, source and baseline, so
   *why is it here* sits on the same line as *where is it*.
2. **Events** — for each routed event: owner, source, payload schema,
   consumable semantics spelled out in prose, listeners in dispatch
   order, and emission sites with the delivery mode of each call site.
3. **What this report does not know** — unresolved static information,
   never folded into the sections above where it could read as a finding.

Two compaction rules keep it readable. An event with no listener and no
known emit site is a *catalog* row, not a route; a project inherits dozens
from the engine's own `Events` block and lifecycle union, and printing
each in full buries the two the author came to read. Those are listed
compactly at the end, grouped by **why** they are inert — `ELIDED`
(declared, then dropped for want of a consumer) versus `AVAILABLE` (in the
dispatcher, nothing subscribes) — with the explanation given once. That
grouping *is* the issue's requirement that elision and missing listeners
stay distinguishable. An explicit `--event` / `--receiver` always gets the
full detail.

The header also carries the ordering contract's §2.4 split: when nothing
is declared, the report says the sequence is exact but **incidental**, and
that only a declared `.hooks.order` makes a relative order a guarantee.
Printing an incidental order without saying so is how an incidental order
comes to be relied upon.

The text renderer consumes the **parsed model**, not the builder's
intermediate state. That is deliberate: it makes the human report a
consumer of the same JSON #858 will consume, so a field the JSON fails to
carry shows up immediately as a hole in the text. The machine contract
cannot silently become the weaker of the two.

---

## 4. What the report says about ordering — exactly, and no more

`MergeHooks` takes **one** receiver tuple and walks it in tuple order for
every event (ordering doc §2.1). There is no per-event receiver list.
Therefore:

- `Report.receivers` is the whole ordering story, and `ordering.scope` is
  the literal string `"receiver"`.
- `Event.listeners` is a **filter** over that one sequence. Each listener
  carries the `order` it holds in `Report.receivers` — the global index,
  not a per-event rank. Sorting an event's listeners by `order` recovers
  the real dispatch sequence for that event, which is the point; what a
  consumer must not infer is that the order was *chosen for that event*.
  Moving a receiver moves it for every event it handles.

Reporting a per-event order would be a lie the generated code cannot
keep, so the schema does not offer a place to put one.

---

## 5. Non-goals and honest limits

- **Whole-program emit inference.** Not attempted. The emit scan is a
  literal-call-site scan over the hook receivers and scanned scripts. A
  computed emit, an event forwarded through a helper taking a `GameEvents`
  value, or an emit from a plugin's own Zig sources is invisible to it.
  The issue asks for exactly this honesty: *"label dynamic/unknown call
  sites honestly rather than claiming complete whole-program
  inference."*
- **Plugin event payload schemas.** Reported as `resolved: false` with a
  pointer to `flow_catalog.json`, which already publishes them per plugin.
  Re-walking every plugin's `Events` block to duplicate that would be a
  second copy to keep in sync.
- **Lint semantics.** See §3. An `unknown_event` handler is reported and
  explained (the generated game will not build — `MergeHooks`
  compile-errors on it), but `routes` does not fail on it.
- **Live re-scan.** By design (§2.1). If a stale report becomes a real
  complaint, the fix is for the CLI to run `generate` first, not for
  `routes` to grow its own discovery.

---

## 6. Verification

- `test/hook_routes_tests.zig` — the no-drift proof against the emitted
  `MergeHooks` tuple (default and ranked); qualified listener mappings for
  a root event, a pack-local event and a plugin event; that only public
  two-parameter fns count as handlers; elided-versus-unlistened;
  consumable semantics reaching the rendered text; per-call-site delivery
  (`emit` and `emitSync` on two events from one file); unresolved
  information being stated; and the machine contract — round-trip through
  the typed model, byte-identical output across builds, and the sidecar
  reading back through `readSidecar`.
- `src/routes_cmd.zig` — the missing-sidecar path is a nameable condition,
  both render forms work, and a filtered JSON document is still a valid
  report that keeps the receiver's global `order`.
- `examples/hook-order` — the #723 headless example, whose logged
  execution sequence is the runtime counterpart to what
  `labelle-assembler routes --project-root examples/hook-order` prints.
