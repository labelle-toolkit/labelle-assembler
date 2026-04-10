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
```

### Generate options

| Flag | Description |
|------|-------------|
| `--project-root <path>` | Path to game project (containing `project.labelle`) |
| `--scene <name>` | Override initial scene |
| `--platform <name>` | Override target platform (`desktop`, `wasm`, `ios`, `android`) |
| `--backend <name>` | Override graphics backend (`raylib`, `sokol`, `sdl`, `bgfx`, `wgpu`) |

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
