# labelle-assembler

Code generator and build assembler for the [labelle](https://github.com/labelle-toolkit) game toolkit.

## Status

**Placeholder.** This repository is reserved for the eventual extraction
of the assembler from [`labelle-cli`](https://github.com/labelle-toolkit/labelle-cli).
Code lives at `labelle-cli/generator/` today.

See [RFC: Split the assembler from the CLI](https://github.com/labelle-toolkit/labelle-cli/blob/rfc/split-assembler/RFC-split-assembler.md)
([tracking issue #122](https://github.com/labelle-toolkit/labelle-cli/issues/122))
for the architectural plan and migration phases.

## What this will be

A standalone, independently versioned binary that:

- Reads `project.labelle` from a game project root
- Materializes `.labelle/<target>/` build artifacts (`build.zig`,
  `build.zig.zon`, `main.zig`, copied source trees, plugin manifests)
- Resolves and validates plugin dependencies
- Exits with structured error codes; designed to be invoked as a
  subprocess by the `labelle` CLI launcher

The split lets generator versions evolve independently of the CLI binary,
so users no longer need to reinstall `labelle` every time the generator
changes, and different game projects on the same machine can pin different
generator versions via `project.labelle`.
