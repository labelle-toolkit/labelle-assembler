/// Scene .jsonc manifest parsing for the labelle-assembler.
///
/// At codegen time the assembler peeks at each scene file in `scenes/` to:
///   1. Extract the optional top-level `assets:` array — a list of resource
///      names the scene wants the engine to preload before construction. The
///      assembler emits these as a comptime map (scene name → []const u8 slice
///      of asset names) consumed by labelle-engine's SceneEntry (issue #445).
///   2. Reject unknown top-level keys with a hard build error so typos like
///      `"asest"` instead of `"assets"` cannot silently disable preloading.
///
/// This module deliberately does not validate asset names against
/// `project.labelle` resources, nor offer Levenshtein "did you mean"
/// suggestions for unknown top-level scene keys — asset-name
/// validation lives in `asset_validator.zig` (ticket #47).
const std = @import("std");
const config = @import("config.zig");

/// Write a formatted diagnostic directly to stderr, matching the
/// repo-wide convention (see `flow_scanner.reportFlowError`,
/// `init_cmd.writeStderr`, `main_zig.validateResources`). We use a
/// fixed stack buffer rather than `std.debug.print` because the
/// project's test runner intercepts `std.log.err` to fail tests, and
/// `std.debug.print` is documented at line ~363 as the previous
/// workaround — but Gemini correctly pointed out that writing to
/// stderr directly is the cleaner convention this codebase already
/// uses elsewhere. The buffer is sized for the longest message in
/// this file plus a reasonably long scene path; if a path is so
/// pathological that it overflows we fall back to streaming the
/// format string verbatim so the user still sees *something*.
fn stderrPrint(comptime fmt: []const u8, args: anytype) void {
    const io = config.globalIo();
    const stderr = std.Io.File.stderr();
    var buf: [4096]u8 = undefined;
    if (std.fmt.bufPrint(&buf, fmt, args)) |formatted| {
        stderr.writeStreamingAll(io, formatted) catch {};
    } else |_| {
        // Buffer overflow — best-effort: write the unformatted template
        // so the user at least sees the message kind and can find the file.
        stderr.writeStreamingAll(io, fmt) catch {};
    }
}

/// Parsed manifest for a single scene file.
pub const SceneManifest = struct {
    /// Scene name as known by the assembler (path-style: "menu", "world/intro").
    /// Owned by the caller (typically the slice from `copyAndScan`).
    name: []const u8,
    /// Assets requested by the scene's top-level `assets:` array. May be empty.
    /// Each string is owned by this manifest's allocator.
    assets: []const []const u8,
    /// Game state the scene wants `setScene` to transition into after load.
    /// `null` means the scene didn't declare one; `setScene` leaves the
    /// game state untouched (current behavior). When non-null, codegen
    /// emits a `setSceneInitialState(name, state)` call so the engine
    /// honors it at runtime. See labelle-engine#500.
    /// String is owned by this manifest's allocator.
    initial_state: ?[]const u8 = null,
};

/// Whitelisted lowercase top-level keys allowed in a scene .jsonc file.
/// Anything lowercase outside this set triggers `error.UnknownSceneKey`
/// so typos are caught at build time. PascalCase keys are accepted
/// uniformly as flat-form components per RFC #596 axis 2 — see
/// `isAllowedTopLevelKey` for the case-aware gate.
///
/// The set unions every key the engine's JsoncSceneBridge currently consumes
/// (`include`, `entities`, plus the unified `root` block from RFC #560)
/// with cosmetic keys observed in real scenes (`name`, `scripts`) and the
/// `assets` key parsed here. Adding a real new scene-level key in the
/// future means adding it here too — that is the intended speed bump.
///
/// `root` is the unified-format wrapper introduced by
/// labelle-engine#573 / RFC-UNIFY-SCENES-AND-PREFABS.md (§"Unified shape").
/// A unified scene puts its entity list under `root.children` instead of
/// the legacy top-level `entities` array; the assembler accepts both so
/// in-tree projects can migrate file-by-file without breaking the pre-build
/// scan (issue #181).
///
/// `components`, `children`, `prefab`, `overrides` are the flat-form
/// entity-shape keys introduced by RFC #594 phase 2 (engine #595): the
/// file's top-level object IS the entity, with no `root:` wrapper. File-
/// level metadata keys (`name`, `assets`, etc.) coexist at the same
/// level — closed-and-disjoint key sets per the RFC. The assembler
/// accepts both shapes during v1.x; root-wrapped support is removed at
/// v2.0.
///
/// `meta` is the RFC #596 axis-4 free-form authoring-only side channel
/// (engine #597). Valid at both file-header scope (bundle headers) and
/// entity scope; never propagates to runtime. The scan does not validate
/// its contents — it only ensures the key itself is recognized.
const ALLOWED_TOP_LEVEL_KEYS: []const []const u8 = &.{
    "name",
    "assets",
    "include",
    "entities",
    "root",
    "scripts",
    "initial_state",
    // Flat-form entity-shape keys (RFC #594 phase 2 / engine #595).
    "components",
    "children",
    "prefab",
    "overrides",
    // RFC #596 axis 4: free-form authoring metadata.
    "meta",
};

/// True if a key's first byte is an ASCII upper-case letter — the
/// PascalCase convention promoted to a parser rule by RFC #596 axis 2.
/// Component keys live under PascalCase; structural keys are lowercase.
/// The assembler scan uses this to recognize flat-form component
/// references at both the file's top level and inside entity objects.
fn isPascalCase(key: []const u8) bool {
    if (key.len == 0) return false;
    const c = key[0];
    return c >= 'A' and c <= 'Z';
}

fn isAllowedTopLevelKey(key: []const u8) bool {
    // RFC #596 axis 2: PascalCase keys at the file's top level are
    // component declarations on the flat-form root entity. The audit
    // and the loader (engine #597) catch unknown PascalCase names at
    // runtime — the assembler scan can't see the component registry
    // here, so we accept any PascalCase key and rely on the loader's
    // warn-once path. This matches the audit's option C resolution.
    if (isPascalCase(key)) return true;
    for (ALLOWED_TOP_LEVEL_KEYS) |allowed| {
        if (std.mem.eql(u8, key, allowed)) return true;
    }
    return false;
}

/// Errors surfaced from manifest parsing. `UnknownSceneKey`,
/// `InvalidAssetsField`, `InvalidInitialStateField`,
/// `InvalidEntityShape`, and `HybridForm` are hard build errors — the
/// assembler must abort and print a clear message naming the offending
/// file.
///
/// `InvalidEntityShape` covers RFC #560 §B2 violations: an entity
/// entry that declares both `prefab` (reference mode) and `children`
/// (authoring mode), plus malformed `root` blocks under the unified
/// format.
///
/// `HybridForm` covers the dual-accept contract corner case where a
/// file carries BOTH a `root:` wrapper AND top-level flat-form
/// entity-shape keys (`components` / `children` / `prefab` /
/// `overrides`). Under dual-accept the walker can only descend one of
/// the two — silently dropping the other would lose data for users
/// mid-migration. We reject the shape outright instead.
pub const ParseError = error{
    UnknownSceneKey,
    InvalidAssetsField,
    InvalidInitialStateField,
    InvalidEntityShape,
    HybridForm,
    InvalidSceneJson,
    OutOfMemory,
};

/// Strip JSONC line + block comments and trailing commas from `source`,
/// returning a freshly allocated buffer the caller owns.
///
/// The strategy preserves byte offsets where possible by overwriting comment
/// runs with spaces, so any error spans reported by `std.json` line up with
/// the original file. This is intentionally a tiny purpose-built routine —
/// the assembler only needs to read top-level keys, so a full JSONC parser
/// would be over-engineered.
fn stripJsonc(allocator: std.mem.Allocator, source: []const u8) ![]u8 {
    var out = try allocator.alloc(u8, source.len);
    @memcpy(out, source);

    var i: usize = 0;
    var in_string = false;
    while (i < out.len) {
        const c = out[i];
        if (in_string) {
            if (c == '\\' and i + 1 < out.len) {
                i += 2;
                continue;
            }
            if (c == '"') in_string = false;
            i += 1;
            continue;
        }
        if (c == '"') {
            in_string = true;
            i += 1;
            continue;
        }
        if (c == '/' and i + 1 < out.len) {
            const next = out[i + 1];
            if (next == '/') {
                // Line comment — blank to end of line.
                while (i < out.len and out[i] != '\n') : (i += 1) out[i] = ' ';
                continue;
            }
            if (next == '*') {
                // Block comment — blank to closing */, preserving newlines.
                out[i] = ' ';
                out[i + 1] = ' ';
                i += 2;
                while (i + 1 < out.len and !(out[i] == '*' and out[i + 1] == '/')) : (i += 1) {
                    if (out[i] != '\n') out[i] = ' ';
                }
                if (i + 1 < out.len) {
                    out[i] = ' ';
                    out[i + 1] = ' ';
                    i += 2;
                }
                continue;
            }
        }
        i += 1;
    }

    // Second pass: blank trailing commas (`, }` and `, ]`) so std.json accepts
    // the JSONC dialect without complaining. Whitespace between `,` and the
    // closer is allowed; we also tolerate newlines.
    in_string = false;
    i = 0;
    while (i < out.len) : (i += 1) {
        const c = out[i];
        if (in_string) {
            if (c == '\\' and i + 1 < out.len) {
                i += 1;
                continue;
            }
            if (c == '"') in_string = false;
            continue;
        }
        if (c == '"') {
            in_string = true;
            continue;
        }
        if (c == ',') {
            var j = i + 1;
            while (j < out.len and (out[j] == ' ' or out[j] == '\t' or out[j] == '\n' or out[j] == '\r')) : (j += 1) {}
            if (j < out.len and (out[j] == '}' or out[j] == ']')) {
                out[i] = ' ';
            }
        }
    }

    return out;
}

/// Maximum nesting depth accepted when walking `children` arrays.
/// Game scenes are never legitimately deeper than a handful of levels;
/// this cap prevents stack exhaustion on adversarially crafted or
/// accidentally circular JSONC inputs.
/// pub for the extracted test file (scene_manifest_test.zig).
pub const MAX_CHILDREN_DEPTH: u32 = 64;

/// Returns true if any flat-form entity-shape key is present in `obj`.
///
/// Covers two RFC generations:
///   - RFC #594 phase 2 / engine #595: lowercase `components`,
///     `children`, `prefab`, `overrides`.
///   - RFC #596 / engine #597 axis 2: any PascalCase key (a component
///     reference or declaration sitting as a sibling of `prefab`).
///
/// File-level metadata keys (`name`, `assets`, `include`, `scripts`,
/// `initial_state`, `meta`) deliberately don't count — a file that
/// carries only metadata and no entity-shape keys is treated as having
/// no root entity (e.g. an `include`-only scene or a bundle header
/// shaped `{meta: {...}}`), exactly as before the flat-form change.
///
/// Note: `meta` alone is structural-but-non-entity-shape. A bundle's
/// first element with ONLY `meta` is a file header and must not be
/// walked as an entity (engine #597 follows the same rule). An entity
/// that happens to carry `meta` alongside other entity-shape keys is
/// walked normally — see `validateRootBlock`.
fn hasFlatEntityShapeKey(obj: std.json.ObjectMap) bool {
    // Single pass over the keys: a flat-form entity-shape key is either
    // one of the lowercase wrappers (`components` / `children` /
    // `prefab` / `overrides`) or — per RFC #596 — any PascalCase key
    // (a flat-form component reference).
    var iter = obj.iterator();
    while (iter.next()) |entry| {
        const key = entry.key_ptr.*;
        if (isPascalCase(key)) return true;
        if (std.mem.eql(u8, key, "components")) return true;
        if (std.mem.eql(u8, key, "children")) return true;
        if (std.mem.eql(u8, key, "prefab")) return true;
        if (std.mem.eql(u8, key, "overrides")) return true;
    }
    return false;
}

/// Returns the conflicting wrapper key name (`"overrides"` or
/// `"components"`) if `obj` mixes a legacy wrapper with flat-form
/// PascalCase component keys at this scope, or `null` if the shape is
/// internally consistent.
///
/// A file or entity that carries BOTH an `overrides:` / `components:`
/// wrapper AND PascalCase siblings is malformed: the walker can only
/// descend one of the two, and silently dropping the other would lose
/// data for users mid-migration (RFC #596 axis 2; engine #597 mirrors
/// the same gate at every entity site).
///
/// The check is a single pass over `obj.keys()`, tracking whether a
/// wrapper and any PascalCase key coexist. `overrides` takes precedence
/// when both wrappers are present, preserving the diagnostic the call
/// sites emitted before this consolidation (#236).
///
/// pub for the extracted test file (scene_manifest_test.zig).
pub fn checkHybridForm(obj: std.json.ObjectMap) ?[]const u8 {
    var has_pascal = false;
    var has_overrides = false;
    var has_components = false;
    var iter = obj.iterator();
    while (iter.next()) |entry| {
        const key = entry.key_ptr.*;
        if (isPascalCase(key)) {
            has_pascal = true;
        } else if (std.mem.eql(u8, key, "overrides")) {
            has_overrides = true;
        } else if (std.mem.eql(u8, key, "components")) {
            has_components = true;
        }
    }
    if (!has_pascal) return null;
    if (has_overrides) return "overrides";
    if (has_components) return "components";
    return null;
}

/// Pure helper that classifies a parsed file's top-level object into
/// the site label `validateRootBlock` will receive: `"root"` for a
/// root-wrapped file, `"top level"` for a flat-form file, `null` for a
/// file that has neither and so won't go through `validateRootBlock`
/// at all (e.g. `include`-only scenes), and `error.HybridForm` if the
/// file carries both shapes at once.
///
/// Extracted from the call-site in `parseSceneSource` so the
/// label-selection rule is unit-testable without intercepting stderr.
/// The label chosen here is what users see in §B2 error messages, so
/// regressions in the label-selection logic must fail tests directly,
/// not just whichever §B2 case happened to be exercised.
pub fn classifyTopLevel(obj: std.json.ObjectMap) ParseError!?[]const u8 {
    const has_root = obj.get("root") != null;
    const has_flat = hasFlatEntityShapeKey(obj);
    if (has_root and has_flat) return error.HybridForm;
    if (has_root) return "root";
    if (has_flat) return "top level";
    return null;
}

/// Returns true if `obj` is a bundle file header rather than an
/// entity: it carries ONLY a `meta:` key and nothing else. Engine #597
/// uses the same rule — the first element of a top-level Array can be
/// `{meta: {...}}` to attach friendly labels / authoring notes to the
/// file as a whole, and that header must not be walked as an entity.
///
/// Any extra key — entity-shape or otherwise — disqualifies the
/// header role: a `{meta, prefab}` first element is a real entity
/// (with `meta` as authoring metadata sitting alongside).
fn isBundleHeader(obj: std.json.ObjectMap) bool {
    if (obj.count() != 1) return false;
    return obj.get("meta") != null;
}

/// Parse an `assets:` field value (a JSON array of strings) into an
/// owned `[]const []const u8`. Returned slice + strings are allocated
/// from `allocator` and must be freed via `freeManifest`. An empty
/// array yields `&.{}` (no allocation).
///
/// Shared between the object-form file-level `assets:` key (RFC #594
/// flat-form / legacy unified) and the bundle `meta.assets` channel
/// (RFC #596 axis 3) so both report identical error vocabulary.
fn parseAssetsField(
    allocator: std.mem.Allocator,
    value: std.json.Value,
    display_path: []const u8,
) ParseError![]const []const u8 {
    const arr = switch (value) {
        .array => |a| a,
        else => {
            stderrPrint(
                "labelle-assembler: scene '{s}' has 'assets' but it is not an array\n",
                .{display_path},
            );
            return error.InvalidAssetsField;
        },
    };

    if (arr.items.len == 0) return &.{};

    var list = try allocator.alloc([]const u8, arr.items.len);
    var n: usize = 0;
    errdefer {
        for (list[0..n]) |s| allocator.free(s);
        allocator.free(list);
    }
    for (arr.items) |item| {
        switch (item) {
            .string => |s| {
                list[n] = try allocator.dupe(u8, s);
                n += 1;
            },
            else => {
                stderrPrint(
                    "labelle-assembler: scene '{s}' has a non-string entry in 'assets'\n",
                    .{display_path},
                );
                return error.InvalidAssetsField;
            },
        }
    }
    return list;
}

/// Validate a top-level bundle Array per RFC #596 axis 3. Every entry
/// must be a JSON object; the first MAY be a file-header (`{meta}`
/// only — passed through with no validation), every other element is
/// walked as an entity through `validateRootBlock` with the site
/// label `"bundle entry"` so §B2 messages name the actual site.
///
/// Empty bundles `[]` are valid zero-entity files (RFC #596 resolved
/// decision 2). Non-object entries are a hard error: a bundle of
/// strings or numbers is malformed.
fn validateBundle(arr: std.json.Array, display_path: []const u8) ParseError!void {
    for (arr.items, 0..) |item, idx| {
        const obj = switch (item) {
            .object => |o| o,
            else => {
                stderrPrint(
                    "labelle-assembler: scene '{s}' bundle entry at index {} is not a JSON object.\n" ++
                        "  RFC #596 axis 3: every bundle entry must be an entity object (or a `{{meta: ...}}` file header at index 0).\n",
                    .{ display_path, idx },
                );
                return error.InvalidEntityShape;
            },
        };
        // First element may be a file-header carrying only `meta:`.
        // Don't walk it as an entity. Any later occurrence of a
        // `{meta}`-only object IS treated as an entity — file-header
        // status is positional (index 0 only), matching engine #597.
        if (idx == 0 and isBundleHeader(obj)) continue;
        try validateRootBlock(.{ .object = obj }, display_path, "bundle entry");
    }
}

/// Validate a unified-format root block. The block must be a JSON
/// object; it carries either inline content (`components`/`children`)
/// or a reference (`prefab`/`overrides`). Walks the `children` array
/// recursively to enforce §B2 on every descendant.
///
/// `site_label` names the site being validated for the user's
/// benefit: `"root"` for a root-wrapped block (where the offending
/// keys live inside an explicit `root:` object), `"top level"` for a
/// flat-form file (where the entity-shape keys live at the file's top
/// level with no `root:` wrapper). Threading this label through keeps
/// the error vocabulary aligned with the engine's unified-loader
/// labels ("child entry", "reference-mode root", etc., per engine
/// #586/#593) instead of pointing users at a `root:` key that may not
/// exist in their file.
///
/// Mirrors the engine loader's two-mode grammar (see
/// labelle-engine/src/jsonc/unified_format.zig). The assembler doesn't
/// need the full accessor surface — it only needs to descend the tree
/// far enough to catch §B2 violations early, with a clear scene-path
/// in the error message.
fn validateRootBlock(
    value: std.json.Value,
    display_path: []const u8,
    site_label: []const u8,
) ParseError!void {
    const obj = switch (value) {
        .object => |o| o,
        else => {
            stderrPrint(
                "labelle-assembler: scene '{s}' has a {s} that is not a JSON object.\n" ++
                    "  Expected an entity-shape object with \"children\": [...] or \"prefab\": \"...\".\n" ++
                    "  See labelle-engine/RFC-UNIFY-SCENES-AND-PREFABS.md §\"Unified shape\".\n",
                .{ display_path, site_label },
            );
            return error.InvalidEntityShape;
        },
    };

    // RFC #596 hybrid-form rejection at entity scope: an entity that
    // mixes the legacy `overrides:` / `components:` wrapper with flat
    // PascalCase siblings is ambiguous — the loader and the assembler
    // walker can only honor one of the two shapes, silently dropping
    // the other would lose data for users mid-migration. Engine #597
    // applies the same gate at every entity site.
    //
    // We check this BEFORE the §B2 prefab+children gate so the message
    // points at the structural ambiguity first; a hybrid file that
    // ALSO trips §B2 is fixed by un-mixing the forms anyway.
    if (checkHybridForm(obj)) |conflict| {
        if (std.mem.eql(u8, conflict, "overrides")) {
            stderrPrint(
                "labelle-assembler: scene '{s}' has a {s} that mixes 'overrides:' with flat-form PascalCase component keys.\n" ++
                    "  RFC #596 axis 2: lift the keys out of 'overrides' or wrap them back in — not both at once.\n" ++
                    "  Either {{prefab, overrides: {{Position, ...}}}} or {{prefab, Position, ...}}, never both.\n",
                .{ display_path, site_label },
            );
        } else {
            stderrPrint(
                "labelle-assembler: scene '{s}' has a {s} that mixes 'components:' with flat-form PascalCase component keys.\n" ++
                    "  RFC #596 axis 2: lift the keys out of 'components' or wrap them back in — not both at once.\n" ++
                    "  Either {{components: {{Image, ...}}, children: [...]}} or {{Image, ..., children: [...]}}, never both.\n",
                .{ display_path, site_label },
            );
        }
        return error.HybridForm;
    }

    // Reference-mode root: §B2 forbids `children` here just as for
    // child entries. The RFC calls this out explicitly: "The same §B2
    // rule applies here as at child entries: reference-mode root
    // cannot declare `children` — instantiating doesn't author."
    //
    // Hoist the two hash-map lookups into locals so we don't pay
    // `obj.get` twice (once for the null check, once for the unwrap).
    const maybe_prefab = obj.get("prefab");
    const maybe_children = obj.get("children");
    if (maybe_prefab != null and maybe_children != null) {
        stderrPrint(
            "labelle-assembler: scene '{s}' has a {s} that declares both 'prefab' and 'children'.\n" ++
                "  RFC #560 §B2: reference-mode entries cannot carry children — instantiating doesn't author.\n" ++
                "  Either author a new prefab file that combines them, or drop one of the keys.\n",
            .{ display_path, site_label },
        );
        return error.InvalidEntityShape;
    }

    if (maybe_children) |children_val| {
        try validateChildrenArrayDepth(children_val, display_path, 0);
    }
}

/// Validate a `children` (or legacy `entities`) array. Every entry
/// must be a JSON object, and §B2 forbids the simultaneous presence
/// of `prefab` and `children`. Recurses into nested `children`.
fn validateChildrenArray(value: std.json.Value, display_path: []const u8) ParseError!void {
    return validateChildrenArrayDepth(value, display_path, 0);
}

fn validateChildrenArrayDepth(value: std.json.Value, display_path: []const u8, depth: u32) ParseError!void {
    if (depth > MAX_CHILDREN_DEPTH) {
        stderrPrint(
            "labelle-assembler: scene '{s}' has children nested more than {} levels deep.\n" ++
                "  Check for circular includes or an unusually deep entity hierarchy.\n",
            .{ display_path, MAX_CHILDREN_DEPTH },
        );
        return error.InvalidEntityShape;
    }
    const arr = switch (value) {
        .array => |a| a,
        else => return, // Non-array `entities`/`children` is not this pass's concern.
    };
    for (arr.items) |item| {
        const obj = switch (item) {
            .object => |o| o,
            else => continue,
        };
        // RFC #596 hybrid-form rejection at child-entry scope — same
        // gate as `validateRootBlock`. We don't have a `site_label`
        // parameter here (the scene's child-entry message is fixed),
        // so the message names "a child entry" directly.
        if (checkHybridForm(obj)) |conflict| {
            if (std.mem.eql(u8, conflict, "overrides")) {
                stderrPrint(
                    "labelle-assembler: scene '{s}' has a child entry that mixes 'overrides:' with flat-form PascalCase component keys.\n" ++
                        "  RFC #596 axis 2: lift the keys out of 'overrides' or wrap them back in — not both at once.\n",
                    .{display_path},
                );
            } else {
                stderrPrint(
                    "labelle-assembler: scene '{s}' has a child entry that mixes 'components:' with flat-form PascalCase component keys.\n" ++
                        "  RFC #596 axis 2: lift the keys out of 'components' or wrap them back in — not both at once.\n",
                    .{display_path},
                );
            }
            return error.HybridForm;
        }
        // Hoist into locals so the second use (`children_val`) is a
        // simple unwrap of the already-looked-up optional rather than
        // a repeated hash-map probe + forced unwrap.
        const maybe_prefab = obj.get("prefab");
        const maybe_children = obj.get("children");
        if (maybe_prefab != null and maybe_children != null) {
            stderrPrint(
                "labelle-assembler: scene '{s}' has a child entry that declares both 'prefab' and 'children'.\n" ++
                    "  RFC #560 §B2: a reference-mode child cannot carry children — instantiating doesn't author.\n" ++
                    "  Author a wrapper prefab that combines them, or drop one of the keys.\n",
                .{display_path},
            );
            return error.InvalidEntityShape;
        }
        if (maybe_children) |children_val| {
            try validateChildrenArrayDepth(children_val, display_path, depth + 1);
        }
    }
}

/// Parse a single scene file's source buffer. `scene_name` is the name the
/// assembler uses elsewhere (e.g. "menu" or "world/intro") and `display_path`
/// is the path printed in error messages so users can find the offending file.
///
/// Returns a `SceneManifest` whose `assets` slice (and the contained strings)
/// are allocated from `allocator`. Caller frees via `freeManifest`.
pub fn parseSceneSource(
    allocator: std.mem.Allocator,
    scene_name: []const u8,
    display_path: []const u8,
    source: []const u8,
) ParseError!SceneManifest {
    const stripped = stripJsonc(allocator, source) catch return error.OutOfMemory;
    defer allocator.free(stripped);

    var parsed = std.json.parseFromSlice(std.json.Value, allocator, stripped, .{}) catch |err| {
        stderrPrint(
            "labelle-assembler: failed to parse scene '{s}': {s}\n",
            .{ display_path, @errorName(err) },
        );
        return error.InvalidSceneJson;
    };
    defer parsed.deinit();

    // RFC #596 axis 3: file-as-array bundles. When the top-level
    // value is a JSON Array, every element is an independent sibling
    // entity (no implicit root). An optional first element shaped
    // `{meta: {...}}` (only `meta`, no entity-shape keys) is a file
    // header rather than an entity — see `isBundleHeader`. Empty
    // bundles `[]` are valid zero-entity files per the RFC's
    // "Empty bundles" resolution.
    //
    // Bundles have no file-level metadata channel (no `name:` /
    // `assets:` / `initial_state:` / `scripts:` available); identity
    // comes from the file basename, and `meta.name` in the header
    // carries any friendly label. The returned manifest reflects this
    // — `assets` is empty and `initial_state` is null. Projects that
    // need preloads stay on the object-shape form during v1.x.
    if (parsed.value == .array) {
        try validateBundle(parsed.value.array, display_path);

        // RFC #596 axis 3: a bundle may carry a `{meta: {...}}` header
        // as its first element. The header is the bundle's only file-
        // level metadata channel — `meta.assets` is the codegen-time
        // preload list (counterpart to the object-form `assets:` key).
        //
        // `meta.initial_state` is deliberately NOT extracted here:
        // engine #599 already consumes it at runtime via
        // `applyFileMetaDirectives`. Reading it at codegen time would
        // double-fire the directive. Only assets needs an assembler-
        // side consumer because `SceneAssetManifests.<scene>` is a
        // comptime const baked into the generated code.
        var bundle_assets: []const []const u8 = &.{};
        if (parsed.value.array.items.len > 0) {
            if (parsed.value.array.items[0] == .object) {
                const first_obj = parsed.value.array.items[0].object;
                if (isBundleHeader(first_obj)) {
                    if (first_obj.get("meta")) |meta_val| {
                        if (meta_val == .object) {
                            if (meta_val.object.get("assets")) |assets_val| {
                                bundle_assets = try parseAssetsField(
                                    allocator,
                                    assets_val,
                                    display_path,
                                );
                            }
                        }
                    }
                }
            }
        }

        return .{
            .name = scene_name,
            .assets = bundle_assets,
            .initial_state = null,
        };
    }

    const root = switch (parsed.value) {
        .object => |obj| obj,
        else => {
            stderrPrint(
                "labelle-assembler: scene '{s}' must have a top-level JSON object or array (RFC #596 bundle)\n",
                .{display_path},
            );
            return error.InvalidSceneJson;
        },
    };

    // Unknown-key guard. Run this BEFORE reading any field so we always report
    // typos even when the rest of the file looks valid.
    var key_iter = root.iterator();
    while (key_iter.next()) |entry| {
        if (!isAllowedTopLevelKey(entry.key_ptr.*)) {
            stderrPrint(
                "labelle-assembler: unknown top-level key '{s}' in scene '{s}'.\n" ++
                    "  Allowed lowercase keys: name, assets, include, entities, root, scripts, initial_state,\n" ++
                    "    components, children, prefab, overrides (flat-form per RFC #594), meta (RFC #596).\n" ++
                    "  PascalCase keys are accepted as flat-form components (RFC #596 axis 2).\n" ++
                    "  (Did-you-mean suggestions land in labelle-assembler#47.)\n",
                .{ entry.key_ptr.*, display_path },
            );
            return error.UnknownSceneKey;
        }
    }

    // RFC #560 §B2 — walk the scene's entity tree and reject any reference
    // entry (`prefab` set) that also declares `children`. Inline mode is
    // authoring; reference mode is instantiating. Appending children at a
    // reference site silently re-authors a recipe at the call site — the
    // engine's unified loader (labelle-engine#573) rejects this at load
    // time, and the assembler does the same so the failure surfaces against
    // the assembler's scene-path-aware error message rather than a deeper
    // engine panic.
    //
    // Dual-accept (RFC #594 phase 2 / engine #595): walk either the
    // legacy root-wrapped form (`root: { ... }`) OR the new flat form
    // where the file's top-level object IS the entity. The pattern
    // mirrors engine #595's `getObject("root") orelse file_obj` — if
    // `root` is present we recurse into it; otherwise we treat the
    // top-level object itself as the root entity (provided it carries
    // any of the entity-shape keys). This makes §B2 fire identically
    // on `{"prefab": "x", "children": [...]}` whether it appears under
    // a `root:` wrapper or at the file's flat top level.
    //
    // Note we *also* still walk the legacy top-level `entities` array
    // for projects mid-migration; the engine accepts that shape for
    // the v1.x window.
    // Classify the top level: root-wrapped, flat-form, neither, or
    // hybrid (= both shapes at once → reject; see cursor #233). The
    // classifier is a pure function so the label-selection rule is
    // unit-testable directly without intercepting stderr.
    const maybe_site_label = classifyTopLevel(root) catch |err| {
        if (err == error.HybridForm) {
            stderrPrint(
                "labelle-assembler: scene '{s}' mixes a 'root' wrapper with top-level entity-shape keys.\n" ++
                    "  Use one form or the other: either wrap the entity in \"root\": {{ ... }} (legacy unified shape)\n" ++
                    "  or move everything to the file's top level (flat form, RFC #594 phase 2). Mixing both is\n" ++
                    "  ambiguous — the assembler would have to silently drop one side.\n",
                .{display_path},
            );
        }
        return err;
    };
    if (maybe_site_label) |label| {
        // For the root-wrapped form we descend into the `root` value;
        // for the flat form the file's top-level object IS the root
        // entity. The same validator handles both, with the site label
        // threaded through so §B2 error messages name the actual site
        // (no nonexistent `root:` key for flat-form users).
        const block: std.json.Value = if (std.mem.eql(u8, label, "root"))
            root.get("root").?
        else
            .{ .object = root };
        try validateRootBlock(block, display_path, label);
    }
    if (root.get("entities")) |entities_val| {
        try validateChildrenArray(entities_val, display_path);
    }

    // Read assets — optional, default empty.
    var assets: []const []const u8 = &.{};
    if (root.get("assets")) |assets_val| {
        assets = try parseAssetsField(allocator, assets_val, display_path);
    }

    // Read initial_state — optional, default null. Must be a plain
    // string ("playing", "menu", etc.). Invalid types are a hard build
    // error so a typo like a numeric or array value can't silently fall
    // back to "no initial state declared".
    var initial_state: ?[]const u8 = null;
    if (root.get("initial_state")) |state_val| {
        switch (state_val) {
            .string => |s| {
                if (s.len == 0) {
                    // Use direct stderr writes (via `stderrPrint`), not
                    // `std.log.err` — the negative-path tests in this
                    // file rely on these messages not counting as
                    // logged errors (which would fail the expectError
                    // tests). Same pattern as the assets validation
                    // errors above and the repo-wide convention used
                    // in `flow_scanner.reportFlowError` and
                    // `main_zig.validateResources`.
                    stderrPrint(
                        "labelle-assembler: scene '{s}' has empty 'initial_state' string\n",
                        .{display_path},
                    );
                    return error.InvalidInitialStateField;
                }
                initial_state = try allocator.dupe(u8, s);
            },
            else => {
                stderrPrint(
                    "labelle-assembler: scene '{s}' has 'initial_state' but it is not a string\n",
                    .{display_path},
                );
                return error.InvalidInitialStateField;
            },
        }
    }

    return .{
        .name = scene_name,
        .assets = assets,
        .initial_state = initial_state,
    };
}

/// Free the strings + slice owned by a manifest produced by parseSceneSource.
pub fn freeManifest(allocator: std.mem.Allocator, manifest: SceneManifest) void {
    for (manifest.assets) |s| allocator.free(s);
    if (manifest.assets.len > 0) {
        allocator.free(manifest.assets);
    }
    if (manifest.initial_state) |s| allocator.free(s);
}

/// Free a slice of manifests in one shot.
pub fn freeManifests(allocator: std.mem.Allocator, manifests: []const SceneManifest) void {
    for (manifests) |m| freeManifest(allocator, m);
    allocator.free(manifests);
}

/// Read every `<scenes_dir>/<name>.jsonc` (where `name` is one of `scene_names`,
/// possibly with subfolder slashes), parse it, and return the manifest list in
/// the same order as `scene_names`.
///
/// Hard-aborts (returns error) on the first scene that fails the unknown-key
/// guard or has a malformed `assets:` field.
pub fn parseSceneDir(
    allocator: std.mem.Allocator,
    scenes_dir: []const u8,
    scene_names: []const []const u8,
) ![]SceneManifest {
    var manifests = try allocator.alloc(SceneManifest, scene_names.len);
    var n: usize = 0;
    errdefer {
        for (manifests[0..n]) |m| freeManifest(allocator, m);
        allocator.free(manifests);
    }

    for (scene_names) |name| {
        const rel = try std.fmt.allocPrint(allocator, "{s}/{s}.jsonc", .{ scenes_dir, name });
        defer allocator.free(rel);

        const source = std.Io.Dir.cwd().readFileAlloc(config.globalIo(), rel, allocator, .limited(1024 * 1024)) catch |err| {
            stderrPrint(
                "labelle-assembler: could not read scene '{s}': {s}\n",
                .{ rel, @errorName(err) },
            );
            return err;
        };
        defer allocator.free(source);

        manifests[n] = try parseSceneSource(allocator, name, rel, source);
        n += 1;
    }

    return manifests;
}
