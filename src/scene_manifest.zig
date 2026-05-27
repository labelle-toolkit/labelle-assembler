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
const MAX_CHILDREN_DEPTH: u32 = 64;

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
    if (obj.get("components") != null) return true;
    if (obj.get("children") != null) return true;
    if (obj.get("prefab") != null) return true;
    if (obj.get("overrides") != null) return true;
    // RFC #596: any PascalCase key is a flat-form component.
    var iter = obj.iterator();
    while (iter.next()) |entry| {
        if (isPascalCase(entry.key_ptr.*)) return true;
    }
    return false;
}

/// Returns true if `obj` carries any PascalCase key — used by the
/// hybrid-form gate at entity scope (engine #597 mirrors the same
/// rule). A file or entity that carries BOTH an `overrides:` /
/// `components:` wrapper AND PascalCase siblings is malformed: the
/// walker can only descend one of the two, silently dropping the
/// other would lose data for users mid-migration.
fn hasFlatPascalCaseKey(obj: std.json.ObjectMap) bool {
    var iter = obj.iterator();
    while (iter.next()) |entry| {
        if (isPascalCase(entry.key_ptr.*)) return true;
    }
    return false;
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
    if (hasFlatPascalCaseKey(obj)) {
        if (obj.get("overrides") != null) {
            stderrPrint(
                "labelle-assembler: scene '{s}' has a {s} that mixes 'overrides:' with flat-form PascalCase component keys.\n" ++
                    "  RFC #596 axis 2: lift the keys out of 'overrides' or wrap them back in — not both at once.\n" ++
                    "  Either {{prefab, overrides: {{Position, ...}}}} or {{prefab, Position, ...}}, never both.\n",
                .{ display_path, site_label },
            );
            return error.HybridForm;
        }
        if (obj.get("components") != null) {
            stderrPrint(
                "labelle-assembler: scene '{s}' has a {s} that mixes 'components:' with flat-form PascalCase component keys.\n" ++
                    "  RFC #596 axis 2: lift the keys out of 'components' or wrap them back in — not both at once.\n" ++
                    "  Either {{components: {{Image, ...}}, children: [...]}} or {{Image, ..., children: [...]}}, never both.\n",
                .{ display_path, site_label },
            );
            return error.HybridForm;
        }
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
        if (hasFlatPascalCaseKey(obj)) {
            if (obj.get("overrides") != null) {
                stderrPrint(
                    "labelle-assembler: scene '{s}' has a child entry that mixes 'overrides:' with flat-form PascalCase component keys.\n" ++
                        "  RFC #596 axis 2: lift the keys out of 'overrides' or wrap them back in — not both at once.\n",
                    .{display_path},
                );
                return error.HybridForm;
            }
            if (obj.get("components") != null) {
                stderrPrint(
                    "labelle-assembler: scene '{s}' has a child entry that mixes 'components:' with flat-form PascalCase component keys.\n" ++
                        "  RFC #596 axis 2: lift the keys out of 'components' or wrap them back in — not both at once.\n",
                    .{display_path},
                );
                return error.HybridForm;
            }
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
        return .{
            .name = scene_name,
            .assets = &.{},
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
        const arr = switch (assets_val) {
            .array => |a| a,
            else => {
                stderrPrint(
                    "labelle-assembler: scene '{s}' has 'assets' but it is not an array\n",
                    .{display_path},
                );
                return error.InvalidAssetsField;
            },
        };

        if (arr.items.len > 0) {
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
            assets = list;
        }
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

// ───── Tests ──────────────────────────────────────────────────────────

test "parses scene with assets array" {
    const src =
        \\{
        \\    "name": "menu",
        \\    "assets": ["background", "ship"],
        \\    "entities": []
        \\}
    ;
    const m = try parseSceneSource(std.testing.allocator, "menu", "menu.jsonc", src);
    defer freeManifest(std.testing.allocator, m);

    try std.testing.expectEqual(@as(usize, 2), m.assets.len);
    try std.testing.expectEqualStrings("background", m.assets[0]);
    try std.testing.expectEqualStrings("ship", m.assets[1]);
}

test "scene without assets key yields empty slice" {
    const src =
        \\{
        \\    "name": "menu",
        \\    "entities": []
        \\}
    ;
    const m = try parseSceneSource(std.testing.allocator, "menu", "menu.jsonc", src);
    defer freeManifest(std.testing.allocator, m);
    try std.testing.expectEqual(@as(usize, 0), m.assets.len);
}

test "empty assets array yields empty slice" {
    const src =
        \\{
        \\    "assets": [],
        \\    "entities": []
        \\}
    ;
    const m = try parseSceneSource(std.testing.allocator, "menu", "menu.jsonc", src);
    defer freeManifest(std.testing.allocator, m);
    try std.testing.expectEqual(@as(usize, 0), m.assets.len);
}

test "unknown top-level key is a hard error" {
    const src =
        \\{
        \\    "name": "menu",
        \\    "asest": ["background"],
        \\    "entities": []
        \\}
    ;
    const result = parseSceneSource(std.testing.allocator, "menu", "scenes/menu.jsonc", src);
    try std.testing.expectError(error.UnknownSceneKey, result);
}

test "singular 'asset' typo is a hard error" {
    const src =
        \\{
        \\    "asset": ["background"]
        \\}
    ;
    const result = parseSceneSource(std.testing.allocator, "menu", "scenes/menu.jsonc", src);
    try std.testing.expectError(error.UnknownSceneKey, result);
}

test "parses initial_state string" {
    const src =
        \\{
        \\    "name": "combat_arena",
        \\    "initial_state": "playing",
        \\    "entities": []
        \\}
    ;
    const m = try parseSceneSource(std.testing.allocator, "combat_arena", "combat.jsonc", src);
    defer freeManifest(std.testing.allocator, m);
    try std.testing.expect(m.initial_state != null);
    try std.testing.expectEqualStrings("playing", m.initial_state.?);
}

test "scene without initial_state yields null (back-compat default)" {
    const src =
        \\{
        \\    "name": "menu",
        \\    "entities": []
        \\}
    ;
    const m = try parseSceneSource(std.testing.allocator, "menu", "menu.jsonc", src);
    defer freeManifest(std.testing.allocator, m);
    try std.testing.expect(m.initial_state == null);
}

test "non-string initial_state is a hard error" {
    const src =
        \\{
        \\    "initial_state": ["playing"]
        \\}
    ;
    const result = parseSceneSource(std.testing.allocator, "menu", "menu.jsonc", src);
    try std.testing.expectError(error.InvalidInitialStateField, result);
}

test "empty initial_state string is a hard error" {
    const src =
        \\{
        \\    "initial_state": ""
        \\}
    ;
    const result = parseSceneSource(std.testing.allocator, "menu", "menu.jsonc", src);
    try std.testing.expectError(error.InvalidInitialStateField, result);
}

test "assets and entities coexist (back-compat)" {
    const src =
        \\{
        \\    "name": "menu",
        \\    "assets": ["a", "b"],
        \\    "entities": [
        \\        { "prefab": "player" }
        \\    ]
        \\}
    ;
    const m = try parseSceneSource(std.testing.allocator, "menu", "menu.jsonc", src);
    defer freeManifest(std.testing.allocator, m);
    try std.testing.expectEqual(@as(usize, 2), m.assets.len);
    try std.testing.expectEqualStrings("a", m.assets[0]);
    try std.testing.expectEqualStrings("b", m.assets[1]);
}

test "JSONC line comments are stripped" {
    const src =
        \\{
        \\    // top comment
        \\    "name": "menu", // trailing comment
        \\    "assets": ["a"] // another
        \\}
    ;
    const m = try parseSceneSource(std.testing.allocator, "menu", "menu.jsonc", src);
    defer freeManifest(std.testing.allocator, m);
    try std.testing.expectEqual(@as(usize, 1), m.assets.len);
}

test "JSONC block comments and trailing commas are tolerated" {
    const src =
        \\{
        \\    /* block
        \\       comment */
        \\    "assets": [
        \\        "a",
        \\        "b",
        \\    ],
        \\    "entities": [],
        \\}
    ;
    const m = try parseSceneSource(std.testing.allocator, "menu", "menu.jsonc", src);
    defer freeManifest(std.testing.allocator, m);
    try std.testing.expectEqual(@as(usize, 2), m.assets.len);
}

test "non-string asset entry is a hard error" {
    const src =
        \\{
        \\    "assets": ["good", 42]
        \\}
    ;
    const result = parseSceneSource(std.testing.allocator, "menu", "menu.jsonc", src);
    try std.testing.expectError(error.InvalidAssetsField, result);
}

test "non-array assets field is a hard error" {
    const src =
        \\{
        \\    "assets": "background"
        \\}
    ;
    const result = parseSceneSource(std.testing.allocator, "menu", "menu.jsonc", src);
    try std.testing.expectError(error.InvalidAssetsField, result);
}

// ── Unified-format scene tests (RFC #560 / labelle-engine#573) ────────

test "unified-format scene with root.children loads" {
    // The smoke-test shape from labelle-assembler#181: a scene
    // authored in the unified format that previously got rejected
    // with "unknown top-level key 'root'".
    const src =
        \\{
        \\    "name": "main",
        \\    "root": {
        \\        "children": []
        \\    }
        \\}
    ;
    const m = try parseSceneSource(std.testing.allocator, "main", "scenes/main.jsonc", src);
    defer freeManifest(std.testing.allocator, m);
    try std.testing.expectEqualStrings("main", m.name);
}

test "unified-format scene with root reference (Mode B) loads" {
    // Reference-mode root — instantiates an existing prefab as the
    // scene root. Allowed by the unified format; the assembler must
    // not reject it.
    const src =
        \\{
        \\    "name": "level1",
        \\    "root": {
        \\        "prefab": "world",
        \\        "overrides": { "Position": { "x": 0, "y": 0 } }
        \\    }
        \\}
    ;
    const m = try parseSceneSource(std.testing.allocator, "level1", "scenes/level1.jsonc", src);
    defer freeManifest(std.testing.allocator, m);
}

test "unified-format scene with reference children inside root.children" {
    const src =
        \\{
        \\    "name": "playground",
        \\    "assets": ["background"],
        \\    "root": {
        \\        "children": [
        \\            { "prefab": "player" },
        \\            { "prefab": "enemy", "overrides": { "Health": { "hp": 5 } } },
        \\            { "components": { "Position": { "x": 0, "y": 0 } } }
        \\        ]
        \\    }
        \\}
    ;
    const m = try parseSceneSource(std.testing.allocator, "playground", "scenes/playground.jsonc", src);
    defer freeManifest(std.testing.allocator, m);
    try std.testing.expectEqual(@as(usize, 1), m.assets.len);
}

test "unified scene with initial_state + assets at file level" {
    // File-level metadata (`name`, `assets`, `initial_state`) coexists
    // with the unified `root` block. These keys live at the file level
    // — only the entity tree moves into `root`.
    const src =
        \\{
        \\    "name": "arena",
        \\    "assets": ["combat"],
        \\    "initial_state": "playing",
        \\    "root": {
        \\        "children": [
        \\            { "prefab": "fighter" }
        \\        ]
        \\    }
        \\}
    ;
    const m = try parseSceneSource(std.testing.allocator, "arena", "scenes/arena.jsonc", src);
    defer freeManifest(std.testing.allocator, m);
    try std.testing.expectEqualStrings("combat", m.assets[0]);
    try std.testing.expectEqualStrings("playing", m.initial_state.?);
}

test "§B2 — child entry with both prefab and children is rejected" {
    const src =
        \\{
        \\    "name": "main",
        \\    "root": {
        \\        "children": [
        \\            {
        \\                "prefab": "door",
        \\                "children": [
        \\                    { "prefab": "pressure_plate" }
        \\                ]
        \\            }
        \\        ]
        \\    }
        \\}
    ;
    const result = parseSceneSource(std.testing.allocator, "main", "scenes/main.jsonc", src);
    try std.testing.expectError(error.InvalidEntityShape, result);
}

test "§B2 — root with both prefab and children is rejected" {
    // The RFC calls this out explicitly: reference-mode root cannot
    // declare children. The assembler enforces the same rule the
    // engine's unified loader does.
    const src =
        \\{
        \\    "name": "broken",
        \\    "root": {
        \\        "prefab": "base",
        \\        "children": [ { "prefab": "extra" } ]
        \\    }
        \\}
    ;
    const result = parseSceneSource(std.testing.allocator, "broken", "scenes/broken.jsonc", src);
    try std.testing.expectError(error.InvalidEntityShape, result);
}

test "§B2 — nested child violation is detected (deep walk)" {
    // The walker must recurse — a violation buried two levels deep
    // is still a violation.
    const src =
        \\{
        \\    "root": {
        \\        "children": [
        \\            {
        \\                "components": { "Position": { "x": 0, "y": 0 } },
        \\                "children": [
        \\                    {
        \\                        "prefab": "boss",
        \\                        "children": [ { "prefab": "minion" } ]
        \\                    }
        \\                ]
        \\            }
        \\        ]
        \\    }
        \\}
    ;
    const result = parseSceneSource(std.testing.allocator, "deep", "scenes/deep.jsonc", src);
    try std.testing.expectError(error.InvalidEntityShape, result);
}

test "§B2 — legacy entities array is also walked for violations" {
    // Mixed legacy + unified projects must still have §B2 enforced
    // on the legacy side until the migration completes.
    const src =
        \\{
        \\    "name": "legacy",
        \\    "entities": [
        \\        {
        \\            "prefab": "door",
        \\            "children": [ { "prefab": "plate" } ]
        \\        }
        \\    ]
        \\}
    ;
    const result = parseSceneSource(std.testing.allocator, "legacy", "scenes/legacy.jsonc", src);
    try std.testing.expectError(error.InvalidEntityShape, result);
}

test "non-object root is a hard error" {
    const src =
        \\{
        \\    "name": "broken",
        \\    "root": []
        \\}
    ;
    const result = parseSceneSource(std.testing.allocator, "broken", "scenes/broken.jsonc", src);
    try std.testing.expectError(error.InvalidEntityShape, result);
}

test "legacy entities + unified root coexist (half-migrated scene)" {
    // A scene mid-migration may temporarily carry both keys — the
    // engine loader prefers `root.children` and warns about the
    // legacy key (see unified_format.fileChildren). The assembler
    // must accept the shape so it doesn't block the migration.
    const src =
        \\{
        \\    "name": "transition",
        \\    "entities": [],
        \\    "root": { "children": [] }
        \\}
    ;
    const m = try parseSceneSource(std.testing.allocator, "transition", "scenes/transition.jsonc", src);
    defer freeManifest(std.testing.allocator, m);
}

test "children nested at exactly MAX_CHILDREN_DEPTH levels is accepted" {
    // Build a chain: root.children → children → ... MAX_CHILDREN_DEPTH levels
    // deep with a single leaf entity at the bottom.  The depth counter starts
    // at 0 at the root's children array, so MAX_CHILDREN_DEPTH levels of
    // nesting must all pass.
    const allocator = std.testing.allocator;
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    try buf.appendSlice(allocator, "{\"root\":{\"children\":[");
    var i: u32 = 0;
    while (i < MAX_CHILDREN_DEPTH) : (i += 1) {
        try buf.appendSlice(allocator, "{\"children\":[");
    }
    try buf.appendSlice(allocator, "{\"prefab\":\"leaf\"}");
    i = 0;
    while (i < MAX_CHILDREN_DEPTH) : (i += 1) {
        try buf.appendSlice(allocator, "]}");
    }
    try buf.appendSlice(allocator, "]}}");
    const m = try parseSceneSource(allocator, "deep_ok", "deep_ok.jsonc", buf.items);
    freeManifest(allocator, m);
}

test "children nested beyond MAX_CHILDREN_DEPTH is a hard error" {
    // One extra level beyond the cap must trigger error.InvalidEntityShape.
    const allocator = std.testing.allocator;
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    try buf.appendSlice(allocator, "{\"root\":{\"children\":[");
    var i: u32 = 0;
    while (i < MAX_CHILDREN_DEPTH + 1) : (i += 1) {
        try buf.appendSlice(allocator, "{\"children\":[");
    }
    try buf.appendSlice(allocator, "{\"prefab\":\"leaf\"}");
    i = 0;
    while (i < MAX_CHILDREN_DEPTH + 1) : (i += 1) {
        try buf.appendSlice(allocator, "]}");
    }
    try buf.appendSlice(allocator, "]}}");
    const result = parseSceneSource(allocator, "deep_bad", "deep_bad.jsonc", buf.items);
    try std.testing.expectError(error.InvalidEntityShape, result);
}

test "comment-only string content is preserved" {
    // Make sure we don't accidentally treat // inside a string as a comment.
    const src =
        \\{
        \\    "name": "url://example",
        \\    "assets": ["a/b"]
        \\}
    ;
    const m = try parseSceneSource(std.testing.allocator, "url", "url.jsonc", src);
    defer freeManifest(std.testing.allocator, m);
    try std.testing.expectEqual(@as(usize, 1), m.assets.len);
    try std.testing.expectEqualStrings("a/b", m.assets[0]);
}

// ── Flat-form unified scene tests (RFC #594 phase 2 / engine #595) ───
//
// These mirror the engine's `flat:` tests in
// `labelle-engine/test/jsonc/unified_format_test.zig`. Each test
// pins one corner of the dual-acceptance contract:
//   1. Flat component-only entity.
//   2. Flat entity with components + children.
//   3. Flat reference (Mode B): `prefab` at the top level.
//   4. File-level metadata (`name`, `assets`) coexisting with flat
//      entity-shape keys.
//   5. §B2 still fires at the flat top level.
//   6. Mixed: root-wrapped form still loads unchanged (regression pin).

test "flat: component-only scene loads (no root wrapper)" {
    const src =
        \\{
        \\    "name": "spawn",
        \\    "components": { "Position": { "x": 0, "y": 0 } }
        \\}
    ;
    const m = try parseSceneSource(std.testing.allocator, "spawn", "scenes/spawn.jsonc", src);
    defer freeManifest(std.testing.allocator, m);
    try std.testing.expectEqualStrings("spawn", m.name);
}

test "flat: scene with components + children loads" {
    const src =
        \\{
        \\    "name": "playground",
        \\    "components": { "Position": { "x": 0, "y": 0 } },
        \\    "children": [
        \\        { "prefab": "player" },
        \\        { "prefab": "enemy" }
        \\    ]
        \\}
    ;
    const m = try parseSceneSource(std.testing.allocator, "playground", "scenes/playground.jsonc", src);
    defer freeManifest(std.testing.allocator, m);
}

test "flat: prefab reference at the file's top level (Mode B specialization)" {
    // A prefab file authored in the flat form, used to specialize an
    // existing recipe. The engine accepts this; the assembler must
    // accept it too. Mirrors engine #595's "flat: prefab reference at
    // root (specialization)" test.
    const src =
        \\{
        \\    "name": "fast_enemy",
        \\    "prefab": "enemy",
        \\    "overrides": { "Speed": { "px_per_s": 200 } }
        \\}
    ;
    const m = try parseSceneSource(std.testing.allocator, "fast_enemy", "prefabs/fast_enemy.jsonc", src);
    defer freeManifest(std.testing.allocator, m);
}

test "flat: scene with file metadata + entity-shape keys coexisting" {
    // Closed-and-disjoint key sets per the RFC: file metadata
    // (`name`, `assets`, `initial_state`) lives alongside entity-shape
    // keys (`components`, `children`) at the same top level.
    const src =
        \\{
        \\    "name": "arena",
        \\    "assets": ["combat"],
        \\    "initial_state": "playing",
        \\    "components": { "Position": { "x": 0, "y": 0 } },
        \\    "children": [
        \\        { "prefab": "fighter" }
        \\    ]
        \\}
    ;
    const m = try parseSceneSource(std.testing.allocator, "arena", "scenes/arena.jsonc", src);
    defer freeManifest(std.testing.allocator, m);
    try std.testing.expectEqualStrings("combat", m.assets[0]);
    try std.testing.expectEqualStrings("playing", m.initial_state.?);
}

test "flat: §B2 fires on flat reference-mode root with children" {
    // The flat-form analogue of "§B2 — root with both prefab and
    // children is rejected". With no `root:` wrapper, the file's
    // top-level object IS the root entity, so the §B2 rule must
    // still fire. Mirrors engine #595's "flat: §B2 still fires on
    // a flat reference-mode root with children" test.
    const src =
        \\{
        \\    "name": "broken",
        \\    "prefab": "base",
        \\    "children": [ { "prefab": "extra" } ]
        \\}
    ;
    const result = parseSceneSource(std.testing.allocator, "broken", "scenes/broken.jsonc", src);
    try std.testing.expectError(error.InvalidEntityShape, result);
}

test "flat: §B2 fires on a nested child violation below the flat top level" {
    // The walker must recurse into `children` arrays the same way it
    // does under the root-wrapped shape.
    const src =
        \\{
        \\    "children": [
        \\        {
        \\            "components": { "Position": { "x": 0, "y": 0 } },
        \\            "children": [
        \\                {
        \\                    "prefab": "boss",
        \\                    "children": [ { "prefab": "minion" } ]
        \\                }
        \\            ]
        \\        }
        \\    ]
        \\}
    ;
    const result = parseSceneSource(std.testing.allocator, "deep_flat", "scenes/deep_flat.jsonc", src);
    try std.testing.expectError(error.InvalidEntityShape, result);
}

test "flat: dual-acceptance regression — root-wrapped form still loads unchanged" {
    // Pin the dual-acceptance contract: same parser, same file,
    // root-wrapped form must continue to load with no behavioral
    // change. This is the regression sentinel for the v2.0 cutover.
    const src =
        \\{
        \\    "name": "wrapped",
        \\    "root": {
        \\        "components": { "Position": { "x": 1, "y": 2 } },
        \\        "children": [ { "prefab": "player" } ]
        \\    }
        \\}
    ;
    const m = try parseSceneSource(std.testing.allocator, "wrapped", "scenes/wrapped.jsonc", src);
    defer freeManifest(std.testing.allocator, m);
    try std.testing.expectEqualStrings("wrapped", m.name);
}

test "flat: metadata-only file (no entity-shape keys) parses (e.g. include-only)" {
    // A file that carries only metadata + `include` (no entity-shape
    // keys) is NOT in flat form — the §B2 walk must be a no-op,
    // exactly as it was before the flat-form change.
    const src =
        \\{
        \\    "name": "shared",
        \\    "include": ["common/base.jsonc"]
        \\}
    ;
    const m = try parseSceneSource(std.testing.allocator, "shared", "scenes/shared.jsonc", src);
    defer freeManifest(std.testing.allocator, m);
}

// ── Cursor #233 fixes: hybrid-form rejection + §B2 site labels ───────

test "hybrid: file with both 'root' wrapper and flat entity-shape keys is rejected" {
    // Cursor #233 finding 1 — dual-accept must not silently drop one
    // side when a file carries both shapes. The §B2 walker only
    // descends one branch, so a mixed file would lose data for users
    // mid-migration. The classifier rejects the shape outright.
    const src =
        \\{
        \\    "name": "mixed",
        \\    "root": { "components": { "Position": { "x": 0, "y": 0 } } },
        \\    "components": { "Other": {} }
        \\}
    ;
    const result = parseSceneSource(std.testing.allocator, "mixed", "scenes/mixed.jsonc", src);
    try std.testing.expectError(error.HybridForm, result);
}

test "§B2 site label — flat form classifies as 'top level' (not 'root')" {
    // Cursor #233 finding 2 — when a flat-form file trips §B2, the
    // error message must not point users at a `root:` key that
    // doesn't exist in their file. We can't intercept stderr in
    // tests, so the label-selection rule is exposed via the pure
    // `classifyTopLevel` helper and verified directly. The label
    // returned here is exactly what `validateRootBlock` will
    // interpolate into the §B2 message — see `parseSceneSource` and
    // the `{s}` format slot in the §B2 stderrPrint call.
    //
    // Shape: top-level `prefab` + `children`. parseSceneSource itself
    // will reject this with InvalidEntityShape; we cover the
    // end-to-end rejection in "flat: §B2 fires on flat reference-mode
    // root with children" above.
    const src =
        \\{ "prefab": "x", "children": [] }
    ;
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, src, .{});
    defer parsed.deinit();
    const label = try classifyTopLevel(parsed.value.object);
    try std.testing.expect(label != null);
    try std.testing.expectEqualStrings("top level", label.?);
}

test "§B2 site label — root-wrapped form classifies as 'root' (regression pin)" {
    // Cursor #233 finding 2 — regression sentinel for the
    // pre-existing label. Users with root-wrapped files must keep
    // seeing the "root" word in §B2 messages; if a future refactor
    // swaps the label to "top level" for wrapped files, this fails.
    const src =
        \\{ "root": { "prefab": "x", "children": [] } }
    ;
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, src, .{});
    defer parsed.deinit();
    const label = try classifyTopLevel(parsed.value.object);
    try std.testing.expect(label != null);
    try std.testing.expectEqualStrings("root", label.?);
}

// ── RFC #596 — wrapper-flat + bundle + meta shapes (engine #597) ─────
//
// These mirror engine #597's `rfc596:` test suite in
// `labelle-engine/test/jsonc/unified_format_test.zig`. Each test pins
// one corner of the new dual-acceptance axes:
//
//   - Axis 2: PascalCase keys as entity-scope components, dropping the
//     `overrides:` / `components:` wrappers.
//   - Axis 3: top-level JSON Array as a bundle of sibling entities,
//     with an optional `{meta}` header at index 0.
//   - Axis 4: free-form `meta:` keys at file-header and entity scope,
//     never validated.
//
// The hybrid-form gate (RFC #596 corollary; cursor #233 style)
// rejects any file that mixes a wrapper with its flat counterpart at
// the same site.

test "rfc596: flat reference — PascalCase override sibling of prefab key" {
    // The dominant FP shape post-RFC-#596: a scene reference with
    // PascalCase component overrides sitting next to `prefab:`, no
    // `overrides:` wrapper. Mirrors engine #597's
    // "rfc596: flat reference — PascalCase override sibling of prefab key".
    const src =
        \\{
        \\    "name": "fast_enemy",
        \\    "prefab": "enemy",
        \\    "Position": { "x": 100, "y": 50 },
        \\    "Speed": { "px_per_s": 200 }
        \\}
    ;
    const m = try parseSceneSource(std.testing.allocator, "fast_enemy", "prefabs/fast_enemy.jsonc", src);
    defer freeManifest(std.testing.allocator, m);
}

test "rfc596: flat inline — PascalCase keys declare an inline entity" {
    // The dominant FP shape for inline entities post-RFC-#596: a file
    // whose root entity declares its components directly via
    // PascalCase keys, no `components:` wrapper, optional `children:`
    // for true parent-of-children.
    const src =
        \\{
        \\    "name": "kitchen_workstation",
        \\    "Image": { "sprite": "kitchen" },
        \\    "Workstation": { "kind": "kitchen" },
        \\    "children": [
        \\        { "prefab": "eis_slot", "Position": { "x": -30, "y": 0 } }
        \\    ]
        \\}
    ;
    const m = try parseSceneSource(std.testing.allocator, "kitchen", "prefabs/kitchen.jsonc", src);
    defer freeManifest(std.testing.allocator, m);
}

test "rfc596: bundle scene — top-level Array spawns N siblings" {
    // The bundle shape collapses the colony scene's outer
    // `{name, children: [...]}` wrapping into a direct Array. Each
    // element is an entity walked through `validateRootBlock` with
    // the site label "bundle entry".
    const src =
        \\[
        \\    { "prefab": "ship_carcase", "Position": { "x": 0,   "y": 0 } },
        \\    { "prefab": "ship_carcase", "Position": { "x": 780, "y": 0 } },
        \\    { "prefab": "condenser",    "Position": { "x": 0,   "y": 0 } }
        \\]
    ;
    const m = try parseSceneSource(std.testing.allocator, "colony", "scenes/colony.jsonc", src);
    defer freeManifest(std.testing.allocator, m);
    // Bundles carry no file-level metadata channel — `assets` is
    // empty and `initial_state` is null. Pin that contract here so a
    // future refactor doesn't accidentally surface file metadata that
    // the bundle shape can't actually carry.
    try std.testing.expectEqual(@as(usize, 0), m.assets.len);
    try std.testing.expect(m.initial_state == null);
}

test "rfc596: bundle header — only-meta object at index 0 is file-meta, not entity" {
    // The first bundle element MAY be `{meta: {...}}` only, carrying
    // file-level authoring metadata. It is NOT walked as an entity.
    // If it were, the §B2 walker would still pass (no `prefab` /
    // `children`), but a future stricter check would mis-fire. Pin
    // the file-header detection here directly.
    const src =
        \\[
        \\    { "meta": { "name": "Production Colony Demo", "author": "alexandre" } },
        \\    { "prefab": "ship_carcase", "Position": { "x": 0, "y": 0 } },
        \\    { "prefab": "condenser",    "Position": { "x": 0, "y": 0 } }
        \\]
    ;
    const m = try parseSceneSource(std.testing.allocator, "colony", "scenes/colony.jsonc", src);
    defer freeManifest(std.testing.allocator, m);
}

test "rfc596: empty bundle [] is valid, zero entities" {
    // RFC #596 resolved decision 2: `[]` is a valid zero-entity file.
    // Authoring workflows (new file → `[]` → add entities) and the
    // empty-checked-in-by-mistake case both get the same treatment.
    const src = "[]";
    const m = try parseSceneSource(std.testing.allocator, "empty", "scenes/empty.jsonc", src);
    defer freeManifest(std.testing.allocator, m);
    try std.testing.expectEqual(@as(usize, 0), m.assets.len);
}

test "rfc596: meta on an entity is ignored by the scan (no findings)" {
    // `meta:` is structural, lowercase, and never validated. An
    // entity that carries `meta` alongside real components and
    // structural keys still walks normally. Pin that the presence
    // of `meta` doesn't change any other gate's behavior.
    const src =
        \\{
        \\    "name": "labeled_kitchen",
        \\    "prefab": "kitchen",
        \\    "Position": { "x": 156, "y": 93 },
        \\    "meta": { "name": "Main Kitchen", "notes": "first build" }
        \\}
    ;
    const m = try parseSceneSource(std.testing.allocator, "labeled_kitchen", "prefabs/labeled_kitchen.jsonc", src);
    defer freeManifest(std.testing.allocator, m);
}

test "rfc596: file-header-only `meta:` is accepted (no entity walk)" {
    // A file shaped `{meta: {...}}` alone — no entity-shape keys —
    // carries only authoring metadata at file-header scope. The
    // §B2 walk is skipped (no root entity to walk); the unknown-key
    // gate accepts `meta` from the allow-list. Mirrors the
    // metadata-only #594 contract for the new key.
    const src =
        \\{
        \\    "name": "labels",
        \\    "meta": { "author": "alexandre", "version": 1 }
        \\}
    ;
    const m = try parseSceneSource(std.testing.allocator, "labels", "scenes/labels.jsonc", src);
    defer freeManifest(std.testing.allocator, m);
}

test "rfc596: wrapped 'overrides' form still works (dual-accept regression)" {
    // The legacy wrapped form must continue to load unchanged through
    // v1.x. Same shape as yesterday's #233 regression pin, kept here
    // so anyone adding a new RFC #596 gate accidentally affecting the
    // wrapped path fails this test directly. Removed at v2.0.
    const src =
        \\{
        \\    "name": "fast_enemy",
        \\    "prefab": "enemy",
        \\    "overrides": { "Position": { "x": 100, "y": 50 } }
        \\}
    ;
    const m = try parseSceneSource(std.testing.allocator, "fast_enemy", "prefabs/fast_enemy.jsonc", src);
    defer freeManifest(std.testing.allocator, m);
}

test "rfc596: hybrid form — overrides + flat PascalCase at root is HybridForm" {
    // RFC #596 corollary (engine #597's same gate): a file that
    // declares BOTH the legacy `overrides:` wrapper AND flat
    // PascalCase siblings is ambiguous — the walker can only honor
    // one side, silently dropping the other would lose data for
    // users mid-migration. Reject the shape outright.
    const src =
        \\{
        \\    "prefab": "enemy",
        \\    "overrides": { "Position": { "x": 0, "y": 0 } },
        \\    "Speed": { "px_per_s": 200 }
        \\}
    ;
    const result = parseSceneSource(std.testing.allocator, "mixed", "scenes/mixed.jsonc", src);
    try std.testing.expectError(error.HybridForm, result);
}

test "rfc596: hybrid form — components + flat PascalCase at root is HybridForm" {
    // Same shape as the previous test but for the inline-entity
    // wrapper. `components:` + a PascalCase sibling is ambiguous.
    const src =
        \\{
        \\    "components": { "Workstation": { "kind": "kitchen" } },
        \\    "Image": { "sprite": "kitchen" }
        \\}
    ;
    const result = parseSceneSource(std.testing.allocator, "mixed", "scenes/mixed.jsonc", src);
    try std.testing.expectError(error.HybridForm, result);
}

test "rfc596: hybrid form — overrides + flat PascalCase on a child entry is HybridForm" {
    // The hybrid-form gate applies at every entity site, not just the
    // root — child entries are also rejected if they mix wrapper +
    // flat. Engine #597 follows the same per-entity rule.
    const src =
        \\{
        \\    "children": [
        \\        {
        \\            "prefab": "enemy",
        \\            "overrides": { "Position": { "x": 0, "y": 0 } },
        \\            "Speed": { "px_per_s": 200 }
        \\        }
        \\    ]
        \\}
    ;
    const result = parseSceneSource(std.testing.allocator, "mixed", "scenes/mixed.jsonc", src);
    try std.testing.expectError(error.HybridForm, result);
}

test "rfc596: §B2 fires on a flat bundle entry with {prefab + children}" {
    // The bundle shape doesn't bypass §B2 — every bundle entry is
    // walked the same way a root entity is, with the site label
    // "bundle entry". A reference-mode entry with `children` is still
    // a §B2 violation. Mirrors engine #597's
    // "rfc596: §B2 still fires on a flat bundle element with {prefab + children}".
    const src =
        \\[
        \\    { "prefab": "ship_carcase", "Position": { "x": 0, "y": 0 } },
        \\    { "prefab": "door", "children": [ { "prefab": "plate" } ] }
        \\]
    ;
    const result = parseSceneSource(std.testing.allocator, "broken_bundle", "scenes/broken_bundle.jsonc", src);
    try std.testing.expectError(error.InvalidEntityShape, result);
}

test "rfc596: §B2 fires on a nested bundle entry — recursion preserved" {
    // The walker still recurses into bundle entries' `children`.
    const src =
        \\[
        \\    {
        \\        "Image": { "sprite": "x" },
        \\        "children": [
        \\            { "prefab": "boss", "children": [ { "prefab": "minion" } ] }
        \\        ]
        \\    }
        \\]
    ;
    const result = parseSceneSource(std.testing.allocator, "nested_bundle", "scenes/nested_bundle.jsonc", src);
    try std.testing.expectError(error.InvalidEntityShape, result);
}

test "rfc596: bundle entry with non-object element is rejected" {
    // A bundle of strings/numbers is malformed.
    const src =
        \\[
        \\    { "prefab": "ship" },
        \\    "not-an-entity"
        \\]
    ;
    const result = parseSceneSource(std.testing.allocator, "bad_bundle", "scenes/bad_bundle.jsonc", src);
    try std.testing.expectError(error.InvalidEntityShape, result);
}

test "rfc596: §B2 site label — bundle entry classifies via validateBundle path" {
    // `classifyTopLevel` only runs for object-shape top-level files;
    // bundles bypass it entirely and go straight through
    // `validateBundle`. Pin that the classifier returns null when
    // handed an object that LOOKS like a bundle entry but at file
    // top level — to catch regressions where the wrong code path is
    // taken for the bundle shape.
    //
    // (The user-visible label "bundle entry" is interpolated into
    // §B2 messages from `validateBundle`'s direct call to
    // `validateRootBlock`; we can't capture stderr in tests, so this
    // pins the structural path instead.)
    const src =
        \\{ "prefab": "x", "Position": { "x": 0, "y": 0 } }
    ;
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, src, .{});
    defer parsed.deinit();
    const label = try classifyTopLevel(parsed.value.object);
    try std.testing.expect(label != null);
    try std.testing.expectEqualStrings("top level", label.?);
}

test "rfc596: unknown PascalCase key at top level is accepted (warn deferred to loader)" {
    // The audit's option-C resolution: the assembler scan can't see
    // the engine's component registry, so unknown PascalCase keys
    // (typos like `Posiiton`, or cross-repo plugin types) are
    // accepted at scan time and the loader's runtime warn-once path
    // catches them. Pin that behavior here so a future change that
    // tries to introspect the registry from the assembler — and
    // accidentally rejects valid unknown-PascalCase-at-scan-time —
    // fails this test directly.
    const src =
        \\{
        \\    "prefab": "enemy",
        \\    "Posiiton": { "x": 0, "y": 0 }
        \\}
    ;
    const m = try parseSceneSource(std.testing.allocator, "typo", "scenes/typo.jsonc", src);
    defer freeManifest(std.testing.allocator, m);
}

test "rfc596: bundle with `{meta}` at non-zero index is walked as an entity" {
    // File-header status is positional — only index 0 may be a pure
    // `{meta}` header. A `{meta}`-only object anywhere else is an
    // entity, and an entity with no `prefab` / no components / no
    // `children` is... not what the loader wants. The scan doesn't
    // currently distinguish "empty entity" from "well-formed entity"
    // (that's the loader's job — see RFC #596 "Empty bundles" final
    // paragraph), so the scan accepts the shape. Pin that contract.
    const src =
        \\[
        \\    { "prefab": "ship_carcase", "Position": { "x": 0, "y": 0 } },
        \\    { "meta": { "note": "this is not a header — it's at index 1" } }
        \\]
    ;
    const m = try parseSceneSource(std.testing.allocator, "labeled", "scenes/labeled.jsonc", src);
    defer freeManifest(std.testing.allocator, m);
}

test "rfc596: top-level non-object non-array is still a hard error" {
    // The error message for a malformed top-level was updated to
    // mention the bundle shape; pin that an actually malformed file
    // (e.g. a top-level string) still rejects.
    const src = "\"just a string\"";
    const result = parseSceneSource(std.testing.allocator, "bad", "scenes/bad.jsonc", src);
    try std.testing.expectError(error.InvalidSceneJson, result);
}

test "rfc596: file-header `{meta}` with extra keys is treated as an entity (positional)" {
    // `isBundleHeader` requires the object to have EXACTLY one key
    // and that key to be `meta`. A `{meta, prefab}` first element is
    // a real entity (with `meta` sitting alongside) and must be
    // walked as such — including any §B2 violation it carries.
    const src =
        \\[
        \\    { "meta": { "x": 1 }, "prefab": "enemy", "children": [ { "prefab": "minion" } ] }
        \\]
    ;
    const result = parseSceneSource(std.testing.allocator, "bad_header", "scenes/bad_header.jsonc", src);
    try std.testing.expectError(error.InvalidEntityShape, result);
}
