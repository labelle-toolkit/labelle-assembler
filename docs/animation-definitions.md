# Shared JSONC animation definitions

The assembler recursively discovers `animations/*.jsonc`, preserving subfolder
paths. It stages the full animations directory alongside generated sources and
embeds each JSONC file once. Definitions are registered by full relative path,
for example `animations/props/propeller.jsonc`, before scenes or scripts can
spawn entities. Both loop and callback lifecycle initialization use this path.

A prefab's registered engine `SpriteAnimation` can select the definition:

```jsonc
"SpriteAnimation": {
    "definition": "animations/props/propeller.jsonc",
    "clip": "spin",
    "fps": 10,
    "mode": "loop"
}
```

The file follows the labelle-engine `animation/` package schema (`version: 1`,
`clips`, explicit `frames` or `frames_pattern` with inclusive `from`/`to`).
List the clip's atlases in the scene asset manifest so the engine can validate
frame keys after resources are resident.

This requires an engine exposing `Game.loadAnimationJsoncSource`; older engines
receive an explicit compilation diagnostic only when JSONC animation files are
present. Existing `.zon` discovery and comptime `AnimationDef` imports are
unchanged. This stage covers the game-root animations directory, not pack-local
animation directories or live definition replacement.
