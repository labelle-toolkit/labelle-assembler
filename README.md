# labelle-assembler

Code generator and build assembler for the [labelle](https://github.com/labelle-toolkit) game toolkit.

Reads a game project's `project.labelle` configuration and materializes the
`.labelle/<backend>_<platform>/` build directory with all generated build files
(`build.zig`, `build.zig.zon`, `main.zig`, plugin manifests, copied source
trees). Designed to be invoked as a subprocess by the `labelle` CLI launcher,
so generator versions can evolve independently of the CLI binary.

See the [RFC: Split the assembler from the CLI](https://github.com/labelle-toolkit/labelle-cli/blob/rfc/split-assembler/RFC-split-assembler.md)
([tracking issue #122](https://github.com/labelle-toolkit/labelle-cli/issues/122))
for the architectural plan and migration phases.

**Writing a plugin?** See the
[plugin authoring guide](https://github.com/labelle-toolkit/labelle-cli/blob/main/docs/plugin-authoring.md)
for the end-to-end `Controller` + `plugin.labelle` walk-through, and
[`examples/plugin-controllers/`](./examples/plugin-controllers/) for a
minimal working example that exercises every layer the assembler wires
up.

## Build

Requires [Zig 0.15.2+](https://ziglang.org/download/).

```bash
zig build
```

The binary is written to `zig-out/bin/labelle-assembler`.

## Usage

```bash
./zig-out/bin/labelle-assembler --help
./zig-out/bin/labelle-assembler --protocol-version
./zig-out/bin/labelle-assembler generate --project-root /path/to/game
./zig-out/bin/labelle-assembler routes --project-root /path/to/game
```

### Generate options

| Flag | Description |
|------|-------------|
| `--project-root <path>` | Path to game project (containing `project.labelle`) |
| `--scene <name>` | Override the initial prefab |
| `--platform <name>` | Override target platform (`desktop`, `wasm`, `ios`, `android`) |
| `--backend <name>` | Override graphics backend (`raylib`, `sokol`, `sdl`, `bgfx`, `wgpu`, `null`) |

A `project.labelle` with no `.backend` (and no `.backend_package`) builds
with **bgfx** on desktop, the same default `labelle-assembler init`
scaffolds. Before v0.117.0 the implicit default was raylib; a project that
relied on it must now declare `.backend = .raylib`. The bgfx default
needs `.core_version` >= 2.1.0, and `generate` refuses an older core with a
diagnostic that names the floor.

`.asset_compression` is keyed by target name (labelle-cli RFC #471 P1):
`.desktop`, `.android`, `.ios` and `.wasm` select `.png` (the default) or
`.astc` for that target. Any other identifier key is accepted and ignored,
with a warning, so a project written for a newer target set still
generates. `.web` is the original spelling of `.wasm` and stays accepted
as a warned alias; `.wasm` wins when both are set. The `.platform` key in
`project.labelle` is deprecated: the target comes from the command line
(the `labelle` CLI passes it), and `generate` warns when the key is set.

The `null` backend is a headless test/CI backend with no graphics, audio,
input, or window subsystem — every backend module is a no-op stub. The
generated `main()` runs the engine's tick loop for `LABELLE_NULL_FRAMES`
frames (default 5) and exits cleanly so `defer`-bound teardown actually
runs. Use `.backend = .null` in `project.labelle` for lifecycle /
integration / determinism tests that don't exercise rendering — see
`examples/plugin-controllers/` for a worked example. The null backend is
extracted out-of-tree (the labelle-null package); `.backend = .null`
resolves to it automatically.

### Inspect hook event routes

```bash
./zig-out/bin/labelle-assembler routes --project-root /path/to/game
./zig-out/bin/labelle-assembler routes --project-root /path/to/game --event pulse
./zig-out/bin/labelle-assembler routes --project-root /path/to/game --json | jq .
```

Answers "which listeners does event X reach, in what order, and can one of
them consume it" without reading the generated `MergeHooks` tuple. Reports
the receiver dispatch order (with each receiver's rank and why it sits
where it does), every event with its final generated tag, payload schema,
consumable semantics, listeners and emission call sites — plus, explicitly,
what it could not resolve.

`generate` writes the report to `<game>/.labelle/hook_routes.json` from the
same data that emits the receiver tuple, so the reported order **is** the
dispatch order rather than a second derivation of it. `routes` reads that
file: no package cache, no backend, no renderer. Run `generate` first.

`--json` emits the `labelle.hook-routes/v1` schema — deterministic,
documented, and keyed on the same handler identity
(`docs/design/hook-handler-ordering.md` §2.2) that runtime tracing uses.
See `docs/design/hook-route-inspection.md`.

### Run tests

```bash
zig build test
```

## Release binaries

Pre-built binaries are published on the
[Releases](https://github.com/labelle-toolkit/labelle-assembler/releases) page
when a version tag is pushed. Binary naming convention:

- `labelle-assembler-macos-aarch64`
- `labelle-assembler-macos-x86_64`
- `labelle-assembler-linux-aarch64`
- `labelle-assembler-linux-x86_64`
