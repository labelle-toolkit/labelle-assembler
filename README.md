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
./zig-out/bin/labelle-assembler describe --project-root /path/to/game --target desktop
```

### Generate options

| Flag | Description |
|------|-------------|
| `--project-root <path>` | Path to game project (containing `project.labelle`) |
| `--scene <name>` | Override the initial prefab |
| `--platform <name>` | Override target platform (`desktop`, `wasm`, `ios`, `android`) |
| `--target <name>` | Alias for `--platform`, spelled the way the CLI names targets. An unknown name exits 2 with a message naming the resolved backend and the target |
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
(the `labelle` CLI always passes it). `generate` warns about the key only
when `--platform` or `--target` is given, since that is when the key was
overridden. A direct `generate` with neither still takes its target from
`.platform`, with no warning.

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

### Describe a backend × target (the CLI's source of backend facts)

```bash
./zig-out/bin/labelle-assembler describe --project-root /path/to/game --target android
./zig-out/bin/labelle-assembler describe --project-root /path/to/game --target ios --json
```

`describe` is the **single source of backend and target facts for the
`labelle` CLI** (labelle-cli RFC #471). The CLI asks it, from protocol 7 on,
instead of re-deriving them from its own copy of the assembler's enums —
which is how the CLI came to name a third-party
`.backend_package = .{ .name = "acme" }` project's target dir
`.labelle/bgfx_desktop` while `generate` wrote `.labelle/acme_desktop`.

It answers with the same code `generate` runs: the `.backend` shorthand
(`builtinProvider`), an explicit `.backend_package`, third-party packages,
the `bgfx` default, `backendName()` for the target dir, and `.asset_compression`
for the asset format. For `supported`, when the package is installed, it
calls **the same provider check `generate` runs before codegen**
(`provider_contracts.checkProvider`). That check covers:
- the manifest requirement and version floors;
- the v2 manifest parse;
- lifecycle privilege, provider identity and id collision;
- capabilities;
- the editor-preview link path and the declared build hook;
- the `.platforms.<target>` entry, its entry template and builtin root deps;
- the callback-lifecycle rule.

A failure there is `supported: false`, with the exact diagnostic `generate`
prints as the `reason`.

It is **offline and config-only**: it reads `project.labelle` and, when the
backend package is already installed, that package's manifest. It fetches
nothing, writes nothing to the cache, and generates nothing. When the package
is not installed, a first-party backend at its default version is answered
from a snapshot of its manifest's capabilities; any other package reads as
supported but unverified (`capabilities_source: "unknown"`), the same
back-compat rule `generate` applies to a provider that declares no
capabilities. Requirements that come from a resolved GUI plugin are not part
of the answer.

`--json` emits the `labelle.describe/v1` schema. Key order is fixed;
`package_dir` appears only when the package is installed, and `reason` only
when `supported` is false:

```json
{
  "schema": "labelle.describe/v1",
  "target": "ios",
  "target_dir": ".labelle/raylib_ios",
  "backend": {
    "name": "raylib",
    "id": "labelle.raylib",
    "repo": "github.com/labelle-toolkit/labelle-raylib",
    "version": "0.3.0",
    "local_path": null
  },
  "asset_format": "png",
  "supported": false,
  "reason": "backend provider 'labelle.raylib' does not support capability 'ios' required by target 'ios'",
  "capabilities_source": "builtin"
}
```

| Key | Meaning |
|-----|---------|
| `target_dir` | `.labelle/<backend name>_<target>`, relative to the project root — the dir `generate` creates |
| `backend.name` | `backendName()`: the package name (`bgfx`, `acme`) |
| `backend.id` | Canonical provider id: from the installed manifest once it passes `generate`'s identity check (a reserved, drifted or malformed id is `supported: false` with that check's reason instead), derived as `labelle.<name>` for a first-party backend, else `null` |
| `backend.repo`, `backend.version` | The resolved package's pin |
| `backend.local_path` | The resolved directory of a `local:` / `@` package, else `null` |
| `package_dir` | The package's directory, only when it is on disk |
| `asset_format` | `png` or `astc`, from `.asset_compression` for this target |
| `supported`, `reason` | Whether this backend can generate for this target, and why not |
| `capabilities_source` | `manifest` (parsed from the installed v2 manifest), `builtin` (first-party snapshot), or `unknown` (nothing read: not installed, or installed without a readable v2 manifest) |

Exit codes: 0 whenever an answer was produced, `supported: false` included
(`describe` is a query, not a gate); 1 when `project.labelle` cannot be read
or parsed; 2 on a usage error. An unknown target is `supported: false` with
a reason naming the backend and the target.

### Upgrade the backend

```bash
./zig-out/bin/labelle-assembler upgrade --project-root /path/to/game backend          # to this assembler's default
./zig-out/bin/labelle-assembler upgrade --project-root /path/to/game backend 0.31.0   # to a given release
```

`upgrade backend [version]` bumps the backend provider pin in
`project.labelle` (labelle-cli RFC #471, D2). The `labelle` CLI's
`upgrade all` delegates the backend half of its work to it. The command is
offline: it reads and rewrites `project.labelle` and fetches nothing.

The edit is minimal. Only the version string changes, or the one field that
is added; comments, ordering and spacing are kept. Each rewrite is parsed
back before it is written, and one that does not resolve to the same
backend at the requested version is refused, not written.

| Project has | No version given | A version given |
|---|---|---|
| `.backend = .<tag>` only (or no `.backend`, i.e. the default `bgfx`) | No-op: the shorthand already resolves to this assembler's default (`builtinProvider`) and follows it on every assembler upgrade | The default version is a no-op. Any other version adds an explicit `.backend_package = .{ .name, .repo, .version }` for the same first-party package, next to `.backend`. With no `.backend`, it also adds `.backend = .bgfx`, so the resolved backend tag and the gamepad default don't change. Delete `.backend_package` to go back to following the default |
| An explicit first-party `.backend_package` | `.version` set to this assembler's default for that backend (inserted when the package has no `.version`). A pin already newer than the default is left alone (never downgraded) | `.version` set to it (inserted when the package omits it) |
| A third-party `.backend_package` | No-op with a note: there is no builtin default for it | `.version` set to it |
| A `local:` / `@` `.backend_package` | No-op: it builds from its checkout | Refused (exit 2) |

The prospective pins go through the same `version_floors` gate as
`generate` and `upgrade core|engine|gfx`. A backend version whose floor on
`.core_version` is a compile break is refused (exit 2) with the floor's own
message, and nothing is written; upgrade core first (`upgrade core <ver>` or
`upgrade all`). A curated floor warns and proceeds. The command doesn't move
core, engine or gfx: an incoherent trio is only warned about, and a no-op
still warns when the current pairing is already below a floor. Versions are
strict semver: `MAJOR.MINOR.PATCH`, optionally with a `-pre.release` and/or
`+build` suffix. Anything else (`1.2`, `1.2.3.4`, `v1.2.3`) is refused
(exit 2). A pre-release is judged by the floors as its `MAJOR.MINOR.PATCH`.

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
