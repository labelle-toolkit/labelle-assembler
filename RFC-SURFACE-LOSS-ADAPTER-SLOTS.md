# RFC: Surface-loss adapter slot cleanup

Status: intake draft — pending Claude authorship and independent Claude, Astra, Gemini and DeepSeek reviews. No implementation approval.

Tracking issue: https://github.com/labelle-toolkit/labelle-assembler/issues/454

## Scope and source evidence

This RFC starts from the current Ready item. Historical statements below are evidence to verify against the pinned source snapshots, not established facts about current main. Items 1 and 2 are recorded as completed by PR #455; do not reopen them without new evidence. The remaining substantive scope is generated adapter slot cleanup on surface loss, potentially requiring an engine hook. Fixture slimming is optional and its inclusion remains a product decision.

The review input also includes `inputs/related-source/labelle-engine/`, pinned at be0991eabf5ff4bf75700ceab7bfc2365c7ce22b, and `inputs/related-sources.json`. Inspect the actual lifetime, ownership and recreation paths across both repositories. Do not execute repository scripts or tests during the RFC review.

## Problem and historical issue context

Small cleanups left behind by the backend-extraction work (epic #386, now complete). Low-risk, non-blocking.

### 1. Re-check the callback-external guard
`src/codegen/lifecycle/render.zig:195` raises `error.ExternalCallbackBackendUnsupported`. Now that **sokol (callback loop_style) works as an external backend via the manifest splice**, this guard may be dead code (removable) or need narrowing like the bgfx-android case (#416). Verify which and clean up.

### 2. Stale comment in `src/cache_cmd.zig:545`
Comment reads "…no-op when null is still bundled (effectivePkg == null)". `null` is no longer bundled (extracted to `labelle-null`). Update the comment (flagged as out-of-scope during the sokol flip).

### 3. Surface-loss leak-guard (from Phase-4 on-device validation)
Adapter `slots[]` accumulate across many surface destroy/recreate cycles (shared `asset_wiring.zig` codegen). Needs an engine-driven `clearSlots` on surface loss. GPU mem plateaued in the 9-cycle Tab A7 test, but the slot array itself grows unbounded over a long session.

### 4. (Cosmetic) sokol test fixture
`backends/sokol` (+ `backends/sdl_gamepad` / `backends/android_gamepad` sub-packages) is retained in-tree purely to give the generic codegen tests an offline manifest to read (pinned via `local:backends/sokol` + `project_dir`). Could eventually be slimmed to a minimal synthetic fixture instead of the full real backend. Purely cosmetic — production never bundles it.

Ref: epic #386.

---

## Cleanup audit — 2026-09-08

Items 1 and 2 were completed by #455, as established in the July 11 audit above. The remaining work is:

- [ ] Clear generated adapter slots on surface loss, with the required engine hook. No `clearSlots` seam was found in the current assembler/engine source; later direct-texture reupload support does not itself prove these arrays are cleared.
- [ ] Optionally slim the retained backend test fixtures.

The title now reflects the outstanding work; the original checklist and audit history are retained.


## Proposed contract — to be authored

Define when surface loss invalidates generated adapter slots, which component owns cleanup, how the engine reaches the generated adapters, and what survives recreation. Distinguish freeing CPU metadata, invalidating handles and destroying GPU resources. Explain idempotence, repeated loss/recreation, callback-loop variants and ordering constraints from inspected source. Do not assume a hook exists or promise measured leak elimination without evidence.

## Alternatives and owner decisions — to be authored

Compare feasible hook/ownership designs, migration and compatibility. Explicitly separate essential leak-guard work from optional fixture slimming. Record unresolved choices with concrete alternatives instead of treating review suggestions as owner approval.

## Implementation plan and validation — to be authored

Propose ordered engine/assembler changes, dependency/version coordination, regression tests for repeated surface loss, stale handles and recreation, and a bounded device validation plan. These are planned checks, not tests already executed. No implementation or merge is authorized by this RFC draft.

## Review gate

Four independent reviewers must inspect one immutable document hash. Later document changes invalidate prior approvals. All findings and limitations remain visible. Readiness requires resolving blocking objections and owner decisions; implementation requires explicit approval of the resulting revision.
