# Packs: the module wall and the sanctioned surfaces

*(assembler#498, the enforcement layer of the Packs epic —
labelle-engine#650. Status: PRs 1–5 landed — the wall is complete;
`examples/packs-demo` + the CI e2e fixture are PR 6.)*

A **pack** is the light, directory-scanned form of a plugin: a
namespaced subtree (`packs/<name>/{components,events,prefabs,hooks,scripts}/`)
plus a one-line `pack.labelle`. Under the hood the assembler compiles it
to registry entries in the same unified set the game root feeds — one
`Components` registry, one `GameEvents` union, one hook pipeline —
namespaced `<pack>__<Name>`.

## The wall

Every pack's `.zig` files belong to the pack's **own Zig module**
(`pack__<prefix>`), rooted at the generated
`packs/<name>/__pack_root.zig`. The module boundary is the enforcement
mechanism: Zig resolves imports only through a module's declared import
table plus files under its root directory, so anything outside the
table is a **compile error**, not a lint.

What a pack module can import:

| Surface | How | Why |
|---|---|---|
| Own files | relative paths (`../components/foo.zig`) | the module root is the pack dir |
| Own module root | `@import("pack")` | uniform self-import — authored code never hardcodes its prefix |
| Engine substrate | `labelle-engine`, `labelle-core`, `labelle-gfx`, backend modules, `ecs_backend`/`gui_backend` | shared infrastructure |
| Decl-module plugins | `@import("<plugin>")` by project.labelle name | plugins are the sanctioned inter-domain surface (e.g. FP routes worker access through `worker_controller`) |
| Shared contracts pack | `@import("contracts")` | implicit dependency (`pack_validate.IMPLICIT_DEPS`) |
| Declared pack deps | `@import("<dep>")` → the dep's `exposes` surface (`__surface.zig`) | `depends_on` in `pack.labelle` |

What it cannot import — the wall itself:

- **the `game` shim** — `no module named 'game' available within module 'pack__<x>'`
- **sibling packs** (relative escape or otherwise) — `file exists in modules 'pack__a' and 'pack__b'`
- **the game root's files** — same dual-module/out-of-module errors

## The sanctioned string-keyed registry: `@import("pack").Registry`

Pack code that needs registry-style lookup (`getType`/`has` by name)
uses its **own view**, not the full game registry:

```zig
const Registry = @import("pack").Registry;
const Worker = Registry.getType("citizens__Worker"); // own name: ok
_ = Registry.getType("production__Recipe"); // foreign-private: comptime error
```

`Registry` resolves through `@import("root")` to the
`<prefix>_pack_view` the generated main.zig emits — an
`engine.PackView` **name lens** over the single full `Components`
registry (storage/serde untouched). It admits the pack's own
`<pack>__` names plus components marked `.global` visibility;
everything else `@compileError`s in the engine's `ComponentView`.
Under a root module with no generated views (the tests target,
preview shells) it falls back to a registry of the pack's own
components only — no globals.

## The verb surfaces: `exposes` + `depends_on`

A pack's public API is its root-level `queries.zig` / `commands.zig`,
narrowed by the manifest:

```zig
// packs/citizens/pack.labelle
.{
    .name = "citizens",
    .manifest_version = 1,
    .convention_dirs = .copy_and_scan,
    .exposes = .{ .queries = .{"find_idle_worker"} },
}
// packs/production/pack.labelle
.{ …, .depends_on = .{"citizens"} }
// packs/production/scripts/…
const citizens = @import("citizens");
_ = citizens.queries.find_idle_worker(game);
```

`@import("<dep>")` maps to the dep's generated `__surface.zig` — a
module that re-exports **exactly** the `exposes` lists through the
dep's own pack module (its sole import). A `null`/empty `exposes`
yields a header-only surface with no imports at all — dependents can
call nothing. A non-exposed verb is "no member named …" at compile
time; an undeclared dependency is "no module named …". Exposing verbs
from a file the pack doesn't ship fails at generate time with the
manifest named. `.exposes = .all` is deliberately unsupported (an
unbounded surface defeats the wall): the manifest fails to parse and
a targeted diagnostic names the explicit-list fix. `contracts` is the
exception: implicit, full-module, no exposes-narrowing.

## What deliberately stays open

- **`game.ComponentRegistry` through the `anytype` `game` param** still
  resolves every name — that hole is lint territory
  (`cross_pack_registry_access`), kept as the fast no-build diagnostic.
- **JSONC scenes are data**: a scene may reference any `<pack>__X`
  component; the wall does nothing for declarative files.
- **Prefab `.jsonc`** stays `@embedFile`d by path from main.zig — the
  embed path and the `<pack>__<name>` registration key are the save
  contract.

## Invariants the generator holds

- Registry **field names never change** — `<pack>__<Pascal>` is the
  serde/save key and the prefab registration key.
- A **pack-less project emits byte-identical output** — every pack
  writer gates on pack presence.
- `Components` stays the **single full registry** (it feeds
  `GameConfigWithYAxis`, `JsoncBridge`, and the serializer);
  `PackView` is a lens, never a second registry, and there are no
  per-pack ECS worlds.
