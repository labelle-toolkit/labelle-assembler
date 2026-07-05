//! Game-script → named-module promotion extracted from
//! `codegen/scan.zig` (behavior-preserving split, labelle-assembler#534
//! follow-up).
//!
//! Collects the deduplicated set of FlowNodes-bearing game scripts that
//! must be promoted to NAMED build-system modules
//! (labelle-assembler#240, Gap 2). Re-exported from the `scan.zig` barrel.

const std = @import("std");
const flow_decls = @import("flow_decls.zig");
const PluginFlowNode = flow_decls.PluginFlowNode;

/// One game-script module that exports `pub const FlowNodes` and is
/// therefore promoted to a NAMED build-system module
/// (labelle-assembler#240, Gap 2). A game script reached by both the
/// **root** module (path-imported by `AllScripts` in main.zig for hook
/// registration) and the **game** module (the shim's `PluginFlowNodes`)
/// would be a member of two modules — which Zig forbids. Promotion to a
/// named module sidesteps the conflict: the file is the root of its own
/// module, and both the exe/root module and the `game` module add it as
/// an `@import("<named>")` import.
///
/// `module_name` is the build-system module name (also the string every
/// `@import("<named>")` consumer uses). `rel_path` is the script's path
/// under `scripts/` (so build.zig can `b.path("scripts/<rel>")` the
/// root source file).
pub const PromotedScript = struct {
    /// Named build-system module name, e.g. `script__bouncing_u_ball`.
    /// Built by `promotedScriptModuleName` from `module_sanitized` so it
    /// matches the `<module_sanitized>__<node>` decl prefix used in the
    /// `PluginFlowNodes` block. Caller owns the bytes.
    module_name: []const u8,
    /// Script path under `scripts/`, e.g. `bouncing_ball.zig`. Caller
    /// owns the bytes.
    rel_path: []const u8,
};

/// Build the named-module name for a FlowNodes-bearing game script from
/// its `module_sanitized` form (the `pathToIdent` of its rel_path). The
/// `script__` prefix namespaces it away from plugin module names (which
/// are the project.labelle `.name` verbatim) so a game script and a
/// plugin can never collide on the module-name string. Reusing
/// `module_sanitized` keeps the name byte-identical to the
/// `<module_sanitized>__<node>` decl prefix in `PluginFlowNodes`, which
/// is the invariant the three emission sites (build.zig wiring,
/// main.zig `PluginFlowNodes` + `AllScripts`, and the shim) all depend
/// on. Caller owns the returned bytes.
pub fn promotedScriptModuleName(
    allocator: std.mem.Allocator,
    module_sanitized: []const u8,
) ![]u8 {
    return std.fmt.allocPrint(allocator, "script__{s}", .{module_sanitized});
}

/// Collect the deduplicated set of game scripts that must be promoted to
/// named modules — every `is_script` FlowNode's source module, keyed by
/// `module_sanitized` so a script declaring N FlowNodes yields ONE
/// promoted module. Plugin-contributed nodes (`is_script == false`) are
/// skipped: plugins are already named modules (Gap 2 doesn't apply).
///
/// Caller owns the returned slice and each `PromotedScript`'s
/// `module_name` / `rel_path` bytes — free via `freePromotedScripts`.
pub fn collectPromotedScripts(
    allocator: std.mem.Allocator,
    flow_nodes: []const PluginFlowNode,
) ![]PromotedScript {
    var out: std.ArrayList(PromotedScript) = .empty;
    errdefer {
        for (out.items) |p| {
            allocator.free(p.module_name);
            allocator.free(p.rel_path);
        }
        out.deinit(allocator);
    }
    for (flow_nodes) |fn_| {
        if (!fn_.is_script) continue;
        // Dedupe by sanitized module — one named module per script file.
        var seen = false;
        for (out.items) |p| {
            if (std.mem.eql(u8, p.module_name[("script__".len)..], fn_.module_sanitized)) {
                seen = true;
                break;
            }
        }
        if (seen) continue;
        const module_name = try promotedScriptModuleName(allocator, fn_.module_sanitized);
        errdefer allocator.free(module_name);
        const rel_path = try allocator.dupe(u8, fn_.module_import_path);
        // Ownership hasn't transferred to `out` yet — the function-scope
        // errdefer can't reach `rel_path`, so guard it locally against an
        // OOM in `append`.
        errdefer allocator.free(rel_path);
        try out.append(allocator, .{ .module_name = module_name, .rel_path = rel_path });
    }
    return out.toOwnedSlice(allocator);
}

/// Free a slice returned by `collectPromotedScripts`.
pub fn freePromotedScripts(allocator: std.mem.Allocator, scripts: []const PromotedScript) void {
    for (scripts) |p| {
        allocator.free(p.module_name);
        allocator.free(p.rel_path);
    }
    allocator.free(scripts);
}

// ── Regression: no leak-on-OOM in the append path (#540) ─────────────
//
// `rel_path` is allocated after `module_name` and only becomes owned by
// `out` once `out.append(...)` succeeds. If that append OOMs, the
// freshly-duped `rel_path` used to leak — the function-scope errdefer
// walks `out.items`, which does not yet include the pending entry. A
// local `errdefer allocator.free(rel_path)` now covers the gap.
//
// This test runs `collectPromotedScripts` through a `FailingAllocator`
// forced to fail at each allocation index and asserts the freed/allocated
// tally balances at every point (any leak breaks the invariant).
test "collectPromotedScripts: no allocator leak at any OOM point" {
    const nodes = [_]PluginFlowNode{
        .{ .module_import_path = "hits.zig", .module_sanitized = "hits", .node_name = "a", .is_script = true },
        .{ .module_import_path = "flows/counter.zig", .module_sanitized = "flows_s_counter", .node_name = "b", .is_script = true },
    };

    const total_allocs = blk: {
        var fa = std.testing.FailingAllocator.init(std.testing.allocator, .{});
        const scripts = try collectPromotedScripts(fa.allocator(), &nodes);
        freePromotedScripts(fa.allocator(), scripts);
        break :blk fa.alloc_index;
    };

    var i: usize = 0;
    while (i < total_allocs) : (i += 1) {
        var fa = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = i });
        if (collectPromotedScripts(fa.allocator(), &nodes)) |scripts| {
            freePromotedScripts(fa.allocator(), scripts);
        } else |err| {
            try std.testing.expectEqual(error.OutOfMemory, err);
        }
        try std.testing.expectEqual(fa.allocated_bytes, fa.freed_bytes);
    }
}
