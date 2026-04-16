/// Validates that every asset name referenced by a scene's `assets:`
/// array matches a declared resource in `project.labelle`. Unknown
/// names are a hard build error; when the edit distance to a declared
/// resource is small enough we include a "did you mean" suggestion.
///
/// This pass runs at assembler codegen time, after `scene_manifest`
/// parses each scene and before `main_zig` emits the generated source.
/// Catching typos here surfaces them against the scene file path
/// rather than as a confusing "atlas not found" runtime panic deep
/// inside labelle-engine.
///
/// The Levenshtein implementation is a straightforward O(n·m) dynamic
/// programming table. Resource lists in a game project are small
/// (typically well under 100 entries), so there is no motivation to
/// reach for BK-trees or similar.
const std = @import("std");
const config = @import("config.zig");
const scene_manifest = @import("scene_manifest.zig");

/// Edit-distance threshold for "did you mean" suggestions. A value of
/// 3 lets us catch most single-word typos (transposed or missing
/// letters) without drowning users in unhelpful matches when a scene
/// asks for something genuinely unrelated. Ticket #47 calls for ≤3.
pub const SUGGESTION_THRESHOLD: usize = 3;

pub const ValidationError = error{
    UnknownAssetName,
    OutOfMemory,
};

/// Maximum name length we'll DP with a stack buffer. Resource names in
/// `project.labelle` are identifiers like `"background"` / `"ship"` — in
/// practice well under 64 chars. Anything longer falls back to the heap
/// path so the algorithm stays correct for pathological inputs.
const STACK_DP_CAP: usize = 64;

/// Compute the Levenshtein edit distance between `a` and `b`, capped
/// at `cap`. Returns `cap` if the true distance is ≥ `cap`, which is
/// all we need for threshold checks — callers only care whether a
/// match is "close enough".
///
/// The two DP rows live on the stack when `b.len + 1 <= STACK_DP_CAP`,
/// which covers every realistic resource name and avoids per-call heap
/// allocation in the common typo path (one call per declared resource,
/// once per bad scene entry). `allocator` is only touched as the
/// fallback for longer inputs.
pub fn levenshteinCapped(
    allocator: std.mem.Allocator,
    a: []const u8,
    b: []const u8,
    cap: usize,
) !usize {
    // Trivial cases avoid the DP entirely.
    if (a.len == 0) return @min(b.len, cap);
    if (b.len == 0) return @min(a.len, cap);
    // If the length difference alone exceeds the cap, we can't do
    // better than that — short-circuit. This is the cheap path that
    // dominates for obviously-unrelated names.
    const len_diff = if (a.len > b.len) a.len - b.len else b.len - a.len;
    if (len_diff >= cap) return cap;

    const row_len = b.len + 1;

    // Fast path: both rows fit on the stack. `row_len * 2` slots total
    // — one for `prev`, one for `curr` — so the inline buffer is sized
    // for the worst case at `STACK_DP_CAP`.
    var stack_buf: [STACK_DP_CAP * 2]usize = undefined;

    var prev: []usize = undefined;
    var curr: []usize = undefined;
    var heap_slab: ?[]usize = null;
    defer if (heap_slab) |slab| allocator.free(slab);

    if (row_len <= STACK_DP_CAP) {
        prev = stack_buf[0..row_len];
        curr = stack_buf[row_len .. row_len * 2];
    } else {
        const slab = try allocator.alloc(usize, row_len * 2);
        heap_slab = slab;
        prev = slab[0..row_len];
        curr = slab[row_len .. row_len * 2];
    }

    for (0..row_len) |j| prev[j] = j;

    for (1..a.len + 1) |i| {
        curr[0] = i;
        for (1..row_len) |j| {
            const cost: usize = if (a[i - 1] == b[j - 1]) 0 else 1;
            const del = prev[j] + 1;
            const ins = curr[j - 1] + 1;
            const sub = prev[j - 1] + cost;
            curr[j] = @min(@min(del, ins), sub);
        }
        // Swap rows for the next iteration.
        const tmp = prev;
        prev = curr;
        curr = tmp;
    }
    return @min(prev[b.len], cap);
}

/// Find the closest declared resource name to `query` using
/// Levenshtein distance, subject to `threshold`. Returns null when no
/// resource is within the threshold, or when `resources` is empty.
///
/// On ties (two resources with identical distance), the first one in
/// declaration order wins. Users see a deterministic suggestion and
/// we avoid an arbitrary tie-break rule that could surprise them
/// after a trivial rename.
pub fn closestResource(
    allocator: std.mem.Allocator,
    query: []const u8,
    resources: []const config.ResourceDef,
    threshold: usize,
) !?[]const u8 {
    var best_idx: ?usize = null;
    var best_dist: usize = threshold + 1;

    for (resources, 0..) |res, i| {
        if (res.name.len == 0) continue;
        const dist = try levenshteinCapped(allocator, query, res.name, threshold + 1);
        if (dist <= threshold and dist < best_dist) {
            best_dist = dist;
            best_idx = i;
        }
    }

    if (best_idx) |i| return resources[i].name;
    return null;
}

/// Validate every scene manifest's `assets:` entries against the
/// declared `resources` in `project.labelle`. Emits a hard build error
/// on the first unknown asset name, printing the scene path, the
/// offending name, and a "did you mean" suggestion when one exists.
///
/// Scenes with an empty `assets:` slice (or without an `assets:` key
/// at all) are trivially valid — they don't reference any resources.
///
/// Resources with an empty `name` field are silently skipped by
/// `closestResource`, mirroring the loose-tolerance behavior everywhere
/// else in the assembler: malformed `project.labelle` entries are a
/// separate concern, not something this pass should block on.
pub fn validateSceneAssets(
    allocator: std.mem.Allocator,
    manifests: []const scene_manifest.SceneManifest,
    resources: []const config.ResourceDef,
) ValidationError!void {
    for (manifests) |m| {
        for (m.assets) |asset| {
            if (isDeclared(asset, resources)) continue;

            // Unknown — build the "did you mean" hint (if any) and
            // print the hard-error line in the same style the rest
            // of the assembler uses.
            const suggestion = closestResource(allocator, asset, resources, SUGGESTION_THRESHOLD) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
            };
            if (suggestion) |s| {
                std.debug.print(
                    "labelle-assembler: scene '{s}' references unknown asset '{s}'.\n" ++
                        "  Did you mean '{s}'?\n" ++
                        "  Declared resources live in project.labelle's top-level `resources` array.\n",
                    .{ m.name, asset, s },
                );
            } else {
                std.debug.print(
                    "labelle-assembler: scene '{s}' references unknown asset '{s}'.\n" ++
                        "  No close match among declared resources.\n" ++
                        "  Declared resources live in project.labelle's top-level `resources` array.\n",
                    .{ m.name, asset },
                );
            }
            return error.UnknownAssetName;
        }
    }
}

fn isDeclared(name: []const u8, resources: []const config.ResourceDef) bool {
    for (resources) |res| {
        if (std.mem.eql(u8, res.name, name)) return true;
    }
    return false;
}

// ───── Tests ──────────────────────────────────────────────────────────

test "levenshtein: equal strings → 0" {
    const d = try levenshteinCapped(std.testing.allocator, "background", "background", 8);
    try std.testing.expectEqual(@as(usize, 0), d);
}

test "levenshtein: single transposition counts as 2 edits" {
    // "backgruond" → "background": swap 'u' and 'o' = 2 substitutions.
    const d = try levenshteinCapped(std.testing.allocator, "backgruond", "background", 8);
    try std.testing.expectEqual(@as(usize, 2), d);
}

test "levenshtein: single missing character → 1" {
    const d = try levenshteinCapped(std.testing.allocator, "backgroud", "background", 8);
    try std.testing.expectEqual(@as(usize, 1), d);
}

test "levenshtein: empty vs non-empty" {
    const d = try levenshteinCapped(std.testing.allocator, "", "ship", 8);
    try std.testing.expectEqual(@as(usize, 4), d);
}

test "levenshtein: cap short-circuit on length diff" {
    // "a" vs "abcdef" — length diff is 5, cap is 3 → returns cap.
    const d = try levenshteinCapped(std.testing.allocator, "a", "abcdef", 3);
    try std.testing.expectEqual(@as(usize, 3), d);
}

test "closestResource: finds typo within threshold" {
    const res = [_]config.ResourceDef{
        .{ .name = "background" },
        .{ .name = "ship" },
    };
    const suggestion = try closestResource(std.testing.allocator, "backgroud", &res, 3);
    try std.testing.expect(suggestion != null);
    try std.testing.expectEqualStrings("background", suggestion.?);
}

test "closestResource: no match beyond threshold" {
    const res = [_]config.ResourceDef{
        .{ .name = "background" },
        .{ .name = "ship" },
    };
    const suggestion = try closestResource(std.testing.allocator, "zzzzzzzz", &res, 3);
    try std.testing.expect(suggestion == null);
}

test "closestResource: empty resources list" {
    const res = [_]config.ResourceDef{};
    const suggestion = try closestResource(std.testing.allocator, "anything", &res, 3);
    try std.testing.expect(suggestion == null);
}

test "closestResource: deterministic first-match on tie" {
    const res = [_]config.ResourceDef{
        .{ .name = "alpha" },
        .{ .name = "alpho" }, // also distance 1 from "alphx"
    };
    const suggestion = try closestResource(std.testing.allocator, "alphx", &res, 3);
    try std.testing.expect(suggestion != null);
    // First declaration wins when distances tie.
    try std.testing.expectEqualStrings("alpha", suggestion.?);
}

test "validateSceneAssets: all valid passes" {
    const res = [_]config.ResourceDef{
        .{ .name = "background" },
        .{ .name = "ship" },
    };
    const assets = [_][]const u8{ "background", "ship" };
    const manifests = [_]scene_manifest.SceneManifest{
        .{ .name = "menu", .assets = &assets },
    };
    try validateSceneAssets(std.testing.allocator, &manifests, &res);
}

test "validateSceneAssets: empty assets passes" {
    const res = [_]config.ResourceDef{
        .{ .name = "background" },
    };
    const empty: []const []const u8 = &.{};
    const manifests = [_]scene_manifest.SceneManifest{
        .{ .name = "menu", .assets = empty },
    };
    try validateSceneAssets(std.testing.allocator, &manifests, &res);
}

test "validateSceneAssets: unknown name is a hard error" {
    const res = [_]config.ResourceDef{
        .{ .name = "background" },
    };
    const assets = [_][]const u8{"mystery"};
    const manifests = [_]scene_manifest.SceneManifest{
        .{ .name = "menu", .assets = &assets },
    };
    const result = validateSceneAssets(std.testing.allocator, &manifests, &res);
    try std.testing.expectError(error.UnknownAssetName, result);
}

test "validateSceneAssets: unknown name near a declared one still errors" {
    // The suggestion path is still an error — "did you mean" is
    // advisory, not a pass.
    const res = [_]config.ResourceDef{
        .{ .name = "background" },
    };
    const assets = [_][]const u8{"backgroud"};
    const manifests = [_]scene_manifest.SceneManifest{
        .{ .name = "menu", .assets = &assets },
    };
    const result = validateSceneAssets(std.testing.allocator, &manifests, &res);
    try std.testing.expectError(error.UnknownAssetName, result);
}

test "validateSceneAssets: empty resources + non-empty assets errors" {
    const res = [_]config.ResourceDef{};
    const assets = [_][]const u8{"background"};
    const manifests = [_]scene_manifest.SceneManifest{
        .{ .name = "menu", .assets = &assets },
    };
    const result = validateSceneAssets(std.testing.allocator, &manifests, &res);
    try std.testing.expectError(error.UnknownAssetName, result);
}
