# flows-smoke

End-to-end smoke fixture for the `.flow.zon` codegen pipeline
(labelle-gui#96). `zig build generate` parses `scripts/flows/tick.flow.zon`,
emits `scripts/flows/tick.zig`, and `zig build` proves the whole stack —
flow parser, codegen, component imports, `Game.getComponent` /
`Game.setField`, and the OnCreate alias path — compiles into a real game
binary.

CI builds this fixture but does not run the resulting binary (raylib
needs a display); the build-only depth matches `examples/raylib` and
`examples/asset-streaming-smoke`.
