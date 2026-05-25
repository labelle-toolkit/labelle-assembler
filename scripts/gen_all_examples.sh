#!/usr/bin/env bash
# Generate every example's main.zig and stage them under $OUT for diffing.
# Used by the #183 refactor PoC to verify bit-identical output.
set -euo pipefail

BIN="${BIN:-./zig-out/bin/labelle-assembler}"
OUT="${1:?usage: gen_all_examples.sh <output-dir>}"
mkdir -p "$OUT"

EXAMPLES=(
  raylib
  sokol
  sokol_imgui
  null
  plugin-controllers
  flows-smoke
  asset-streaming-smoke
  bgfx
  wgpu
)

for ex in "${EXAMPLES[@]}"; do
  proj="examples/$ex"
  if [ ! -d "$proj" ]; then
    echo "skip $ex (missing dir)"
    continue
  fi
  echo "=== $ex ==="
  "$BIN" install --project-root "$proj" >/dev/null 2>&1 || echo "install failed for $ex (continuing)"
  # Wipe stale generated output, then regenerate.
  rm -rf "$proj/.labelle"
  if "$BIN" generate --project-root "$proj" >/dev/null 2>"$OUT/$ex.stderr"; then
    # Copy generated tree for diff.
    if [ -d "$proj/.labelle" ]; then
      rm -rf "$OUT/$ex"
      cp -R "$proj/.labelle" "$OUT/$ex"
    fi
    echo "  ok"
  else
    echo "  FAIL (see $OUT/$ex.stderr)"
  fi
done
