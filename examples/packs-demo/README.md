# packs-demo — the pack module wall, end-to-end

Two light packs prove assembler#498 (`docs/packs.md`):

- **citizens** ships a component, an event, a per-state script, and a
  verb surface (`queries.zig`) exposing exactly one query.
- **production** declares `depends_on = .{"citizens"}` and calls the
  exposed query through `@import("citizens").queries.find_idle(game)`.

The citizens script also comptime-proves the Registry bridge:
`@import("pack").Registry.getType("citizens__Counter")` resolves to the
same type its relative import reaches.

CI builds this positive fixture headless on the null backend, then runs
negative probes (each must FAIL to compile): a sibling-pack relative
import, `@import("game")` from a pack, a non-exposed verb, and a
foreign name through the Registry bridge.
