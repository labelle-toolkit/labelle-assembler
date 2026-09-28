/// Wording for a `local:` path that does not exist (#756).
///
/// In a git worktree, a relative `local:../sibling` path is anchored at the
/// MAIN checkout, not the worktree (see `resolveLocalPath` /
/// `resolveProjectRoot` in resolve.zig). That is by design — the same pin
/// then works from every worktree — but when the anchored path is missing,
/// a bare "does not exist" reads like a broken pin. This module formats the
/// message so it names the path that was checked, the pin as written, the
/// main checkout it resolved from, the worktree it was built from, and the
/// fix (an absolute pin). Only `..`-leading pins re-anchor; the wording
/// says so, since project-internal relative pins stay in the worktree.
///
/// Pure string formatting: no filesystem access, so every case is
/// unit-testable without a git layout.
const std = @import("std");

/// Whether a missing `written` path was anchored away from the project:
/// it is relative, and the directory it was joined against
/// (`project_root`, the main checkout) differs from `project_dir` (the
/// worktree). Absolute paths, main-checkout builds, and project-internal
/// paths (which never re-anchor, so `project_root` is null) return false.
pub fn anchoredFromWorktree(written: []const u8, project_dir: ?[]const u8, project_root: ?[]const u8) bool {
    if (std.fs.path.isAbsolute(written)) return false;
    const pd = project_dir orelse return false;
    const root = project_root orelse return false;
    return !std.mem.eql(u8, pd, root);
}

/// Message for a `local:` path that does not exist. Caller owns the result.
///
/// - `written`: the pin as it appears in project.labelle (e.g.
///   `../imgui-alpha`) — for a bundled assembler package, the assembler
///   pin, not the joined subpath.
/// - `resolved`: the path that was actually checked (the message subject).
/// - `project_dir`: the project the build runs from (maybe a worktree).
/// - `project_root`: the directory `written` was joined against when it
///   was re-anchored at the main checkout; null when it was not.
///
/// Outside the worktree case this is exactly the pre-#756 message.
pub fn missingLocalPathMessage(
    allocator: std.mem.Allocator,
    written: []const u8,
    resolved: []const u8,
    project_dir: ?[]const u8,
    project_root: ?[]const u8,
) ![]u8 {
    if (!anchoredFromWorktree(written, project_dir, project_root)) {
        return std.fmt.allocPrint(allocator, "labelle: local path '{s}' does not exist", .{resolved});
    }
    return std.fmt.allocPrint(
        allocator,
        "labelle: local path '{s}' does not exist.\n" ++
            "         The pin '{s}' starts with '..', so it resolves from the main checkout\n" ++
            "         ('{s}'), not this worktree ('{s}').\n" ++
            "         To use a package worktree, pin it with an absolute path.",
        .{ resolved, written, project_root.?, project_dir.? },
    );
}

// ── Tests ───────────────────────────────────────────────────────────────

test "missingLocalPathMessage: relative path missing from a worktree explains the anchoring" {
    const alloc = std.testing.allocator;
    const msg = try missingLocalPathMessage(
        alloc,
        "../imgui-alpha",
        "/src/fp/../imgui-alpha",
        "/src/.worktrees/fp-perf",
        "/src/fp",
    );
    defer alloc.free(msg);

    try std.testing.expectEqualStrings(
        "labelle: local path '/src/fp/../imgui-alpha' does not exist.\n" ++
            "         The pin '../imgui-alpha' starts with '..', so it resolves from the main checkout\n" ++
            "         ('/src/fp'), not this worktree ('/src/.worktrees/fp-perf').\n" ++
            "         To use a package worktree, pin it with an absolute path.",
        msg,
    );
}

test "missingLocalPathMessage: absolute path keeps the plain message" {
    const alloc = std.testing.allocator;
    // Even from a worktree: an absolute pin was not anchored anywhere.
    const msg = try missingLocalPathMessage(
        alloc,
        "/src/.worktrees/imgui-wt",
        "/src/.worktrees/imgui-wt",
        "/src/.worktrees/fp-perf",
        "/src/fp",
    );
    defer alloc.free(msg);
    try std.testing.expectEqualStrings("labelle: local path '/src/.worktrees/imgui-wt' does not exist", msg);
}

test "missingLocalPathMessage: main checkout keeps the plain message" {
    const alloc = std.testing.allocator;
    // resolveProjectRoot returns project_dir unchanged outside a worktree.
    const msg = try missingLocalPathMessage(
        alloc,
        "../imgui-alpha",
        "/src/fp/../imgui-alpha",
        "/src/fp",
        "/src/fp",
    );
    defer alloc.free(msg);
    try std.testing.expectEqualStrings("labelle: local path '/src/fp/../imgui-alpha' does not exist", msg);
}

test "missingLocalPathMessage: project-internal path (not re-anchored) keeps the plain message" {
    const alloc = std.testing.allocator;
    // `@libs/foo` → `libs/foo` joins against the worktree itself, so there
    // is no anchoring to explain: resolveLocalPath passes a null root.
    const msg = try missingLocalPathMessage(
        alloc,
        "libs/foo",
        "/src/.worktrees/fp-perf/libs/foo",
        "/src/.worktrees/fp-perf",
        null,
    );
    defer alloc.free(msg);
    try std.testing.expectEqualStrings("labelle: local path '/src/.worktrees/fp-perf/libs/foo' does not exist", msg);
}

test "missingLocalPathMessage: bundled subpath is the subject, the assembler pin is named separately" {
    const alloc = std.testing.allocator;
    // resolveAssemblerPackage checks `<pin>/<subpath>`; the missing thing
    // is that joined path, and the pin to replace is the assembler one.
    const msg = try missingLocalPathMessage(
        alloc,
        "../labelle-assembler",
        "/src/fp/../labelle-assembler/backends/fictional",
        "/src/.worktrees/fp-perf",
        "/src/fp",
    );
    defer alloc.free(msg);
    try std.testing.expect(std.mem.startsWith(u8, msg, "labelle: local path '/src/fp/../labelle-assembler/backends/fictional' does not exist.\n"));
    try std.testing.expect(std.mem.indexOf(u8, msg, "The pin '../labelle-assembler' starts with '..'") != null);
}
