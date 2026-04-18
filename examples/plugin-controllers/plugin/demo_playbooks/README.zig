// Intentionally empty. Exists so the assembler's `ship_from_plugin`
// copy pass has something to do — smoke-tests that the plugin's
// `demo_playbooks/` directory is actually walked during `generate`
// without contributing any runtime behaviour to the example.
//
// A real plugin would ship code here (e.g. labelle-pathfinder's
// `bridges/`). Declared as `.zig` to satisfy the manifest's extension
// filter; the file is not `@import`ed from anywhere, so Zig never
// compiles it.
