# flows-smoke

End-to-end smoke fixture for the `.flow.jsonc` codegen pipeline
(labelle-gui#96). `zig build generate` recursively scans
`scripts/flows/**` for `*.flow.jsonc`, parses `scripts/flows/tick.flow.jsonc`,
emits `scripts/flows/tick.zig`, and `zig build` proves the whole stack —
flow parser, codegen, component imports, `Game.getComponent` /
`Game.setField`, and the OnCreate alias path — compiles into a real game
binary.

`scripts/flows/custom.flow.jsonc` extends the fixture with a
game-script **CustomNode** (labelle-assembler#240): it calls
`logger.log_i32`, a `pub const FlowNodes` node declared in
`scripts/logger.zig`. Compiling that path proves the assembler (a) emits
`PluginFlowNodes` into the `game` shim so the generated flow's
`@import("game").PluginFlowNodes.<q>.impl(...)` resolves (Gap 1), and
(b) promotes the FlowNodes-bearing game script to a *named* build module
(`script__logger`) so it isn't a member of both the root module (via
`AllScripts`) and the `game` module (via the shim) at once (Gap 2).

This fixture targets the headless `.null` backend (labelle-assembler #520)
— it tests flow *codegen*, not rendering, so it needs no display /
GPU to generate or build. CI builds it but does not run the resulting
binary: the generated `tick` flow-handler does a runtime
`game.getComponent` on the `entity_created` payload that currently faults
inside labelle-core's ecs — a pre-existing, backend-independent runtime
gap unrelated to flow codegen. The codegen contract this fixture exists
to prove is fully asserted at generate + build time.

> **Note:** Only *discovery* keys on the `.flow.jsonc` extension today
> (RFC FLOWS-JSONC §5). The file *body* is still ZON — flow-codegen
> v0.1.0's parser consumes ZON, and its switch to JSONC content is
> tracked separately in the flow-codegen repo. So `tick.flow.jsonc`
> here has a `.jsonc` name but ZON syntax on purpose.
