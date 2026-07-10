# fantasy-dungeon

The **reference asset plugin** for the Asset-Plugins epic
([labelle-engine#725](https://github.com/labelle-toolkit/labelle-engine/issues/725),
[RFC-ASSET-PLUGINS.md](https://github.com/labelle-toolkit/labelle-engine/pull/726)) —
the Phase-2 acceptance fixture for
[#728](https://github.com/labelle-toolkit/labelle-engine/issues/728).

A vendor-style **full plugin** a game attaches by **one** `.plugins` entry to
get a whole dungeon content kit — bundled packs, plugin-level art, and license
metadata — with **zero manual `.resources` edits** in the consuming project.

## Layout

```
fantasy-dungeon/
├── project.labelle          # consuming game — attaches the plugin, declares NO .resources
├── scenes/main.jsonc        # instantiates the plugin's namespaced pack prefabs + banner
└── plugin/                  # the attachable plugin (local:./plugin)
    ├── plugin.labelle       # .packs + plugin-level .resources + .license/.author
    ├── build.zig(.zon)      # exposes the (content-only) labelle_fantasy_dungeon module
    ├── src/root.zig         # intentionally empty — this plugin ships CONTENT, not code
    ├── assets/              # plugin-LEVEL atlas (banner.json/png)
    └── packs/
        ├── tiles/           # bundled pack 1: tileset atlas + prefabs + a generator script
        │   ├── pack.labelle           # .resources = tileset atlas
        │   ├── assets/tileset.json/png # frames floor.png, wall.png
        │   ├── prefabs/{floor_tile,wall_tile}.jsonc
        │   └── scripts/playing/50_dungeon_generator.zig
        └── props/           # bundled pack 2: props atlas + prefabs
            ├── pack.labelle
            ├── assets/props.json/png    # frames torch.png, chest.png
            └── prefabs/{torch,chest}.jsonc
```

## What it demonstrates

1. **Plugin-bundled packs** (`plugin.labelle`'s `.packs`) — `tiles` and `props`
   live at `plugin/packs/<name>/` and are discovered as first-class packs, each
   flowing through the SAME machinery (copy, scan, `pack__` namespacing,
   resource merge, script wiring) as a game-local pack.
2. **Pack-shipped atlases** (Phase 1, `.resources` on each `pack.labelle`) —
   merged into the game resource list as `tiles__tileset` / `props__atlas`, with
   the atlas frame keys rewritten to `tiles/<frame>` / `props/<frame>` and the
   packs' own prefab `sprite_name` refs rewritten to match. Cross-unit sprite
   collisions become structurally impossible.
3. **Plugin-level assets** (Phase 2, `.resources` on `plugin.labelle`) — the
   `banner` atlas the plugin ships directly, merged as `fantasy_dungeon__banner`
   (frame `fantasy_dungeon/banner.png`).
4. **License / author provenance** — `.license = "CC0-1.0"`, `.author =
   "LaBelle Toolkit"`, surfaced by `labelle plugins`.
5. **Scene auto-wiring** — `scenes/main.jsonc` names **no** pack atlas; it just
   instantiates `tiles__floor_tile` etc. and the assembler auto-wires each
   pack's non-lazy atlas into the scene's asset manifest.
6. **A generator = an ordinary script** — `tiles`' generator is a plain
   dir-scanned pack script (the RFC's "tiles are entities, tilesets are just
   atlases" claim), needing no new engine machinery.

Attaching this plugin required **zero** `.resources` in `project.labelle` — that
emptiness is the Phase-2 acceptance criterion.

## Placeholder art

The three atlases (`tileset.png`, `props.png`, `banner.png`) are **minimal
solid-colour placeholder PNGs**, generated programmatically. The reference is
about the resource **mechanism** (merge + namespace + validate + consume), not
the art; a real vendor plugin drops in packed sheets of the same shape with no
manifest change.

## Running it

Headless `.null` backend — no window / GPU needed:

```bash
# from this directory
labelle-assembler generate --project-root .
cd .labelle/null_desktop
zig build
LABELLE_NULL_FRAMES=10 ./zig-out/bin/fantasy_dungeon_demo
```

The generated `main.zig` registers all three namespaced atlases and the
auto-wired scene manifest; the `tiles` generator script logs the room
silhouette it stamps each `playing` tick. The CI `examples-integration` job
(`Generate + build + run the fantasy-dungeon asset-plugin example`) asserts all
of this.
