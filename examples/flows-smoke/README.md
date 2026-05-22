# flows-smoke

End-to-end smoke fixture for the `.flow.jsonc` codegen pipeline
(labelle-gui#96). `zig build generate` recursively scans
`scripts/flows/**` for `*.flow.jsonc`, parses `scripts/flows/tick.flow.jsonc`,
emits `scripts/flows/tick.zig`, and `zig build` proves the whole stack —
flow parser, codegen, component imports, `Game.getComponent` /
`Game.setField`, and the OnCreate alias path — compiles into a real game
binary.

CI builds this fixture but does not run the resulting binary (raylib
needs a display); the build-only depth matches `examples/raylib` and
`examples/asset-streaming-smoke`.

> **Note:** Only *discovery* keys on the `.flow.jsonc` extension today
> (RFC FLOWS-JSONC §5). The file *body* is still ZON — flow-codegen
> v0.1.0's parser consumes ZON, and its switch to JSONC content is
> tracked separately in the flow-codegen repo. So `tick.flow.jsonc`
> here has a `.jsonc` name but ZON syntax on purpose.

## Workaround note

`scripts/flows/components/Position.zig` is a temporary symlink back at
the project-level `components/Position.zig`. The flow codegen (labelle-gui
#102) emits `@import("components/<Name>.zig")` resolved relative to the
generated flow file's directory (`scripts/flows/`), so without the
symlink the import looks for `scripts/flows/components/<Name>.zig` and
fails. Once the codegen emits a depth-aware path (`../../components/`)
or the assembler exposes `components` as a named module, this directory
can be deleted. See `scripts/flows/components/.keep` for context.
