//! C# EMBED-path splice helpers (labelle-assembler#617, follow-up to
//! labelle-engine#743 / labelle-scripting#26).
//!
//! A csharp game's `scripts/*.cs` are compiled — NOT embedded as source —
//! into the scripting plugin's managed assembly
//! (`labelle_csharp_scripts.dll` + its `runtimeconfig.json`/`deps.json`),
//! which the plugin's `src/csharp/vm.zig` loads at RUNTIME through
//! hostfxr. The pipeline (all of it pre-existing, the rust/crystal native
//! family): `labelle generate` stages the game's `scripts/` over the
//! plugin package's `native-csharp/src/game/` placeholder
//! (`scripting_splice.stageNativeSources`) and wires the plugin's
//! `.language_builds` `dotnet publish` step into the generated build.zig
//! (`plugin_build_steps` → `emitPluginBuildSteps`), so every `zig build`
//! recompiles the CURRENT scripts — the same edit-without-regenerate
//! property the cargo/crystal steps have, and the reason the compile runs
//! at generated-BUILD time rather than literally inside `generate`
//! (plugin_build_steps.zig module doc, "When steps run").
//!
//! What was MISSING — and what this module owns — is the two seams that
//! made `labelle generate && labelle build && labelle run` require manual
//! dotnet-adjacent steps:
//!
//!   1. **Runtime-output staging** (`stagesRuntimeOutputs`): the publish
//!      step is link-less (`.link = .none` — a CoreCLR host LOADS the
//!      assembly, nothing is linked), so its outputs landed in the
//!      per-plugin `{cache}` work dir and NEVER reached the game binary.
//!      The vm resolves the assembly from `LABELLE_CS_ASSEMBLY_DIR` or
//!      the running binary's own directory — so consumers had to export
//!      the env var by hand (labelle-scripting's csharp-example CI did
//!      exactly that). When this predicate fires, the generated build.zig
//!      additionally gets (see `build_zig.zig`):
//!        * an InstallDir step copying `{cache}` (the publish output dir)
//!          beside the installed exe — a `zig build` yields a COMPLETE
//!          deployable game dir, assembly next to the binary;
//!        * `run_cmd.setEnvironmentVariable(RUNTIME_ASSEMBLY_DIR_ENV,
//!          <cache>)` — `zig build run` (what `labelle run` invokes)
//!          executes the CACHED binary, not the installed copy, so the
//!          documented override points the host at the publish dir.
//!
//!   2. **Toolchain probe** (`ensureStepToolsOnPath`): the publish step
//!      needs the .NET SDK on the machine; without it the failure
//!      surfaced mid-`zig build` as an opaque child-spawn error. The
//!      probe runs at GENERATE over the selected language entry's
//!      OS-filtered steps and fails pointedly — naming the plugin, step,
//!      missing tool and an install hint — in the `labelle android
//!      doctor` "FAIL + → hint" spirit. It is deliberately GENERIC
//!      (argv[0] PATH lookup, a small hint table): a missing `cargo` or
//!      `crystal` gets the same early, pointed error.
//!
//! ── Why csharp-keyed, and the #619 migration path ────────────────────
//! `stagesRuntimeOutputs` keys on the language NAME, exactly like the
//! dev-`.csproj` emission precedent in root.zig (#617's first half): the
//! "publish dir is the runtime payload" semantic is a property of the
//! csharp row's contract with its vm, not derivable from the generic
//! step schema (a future language could legitimately keep build junk in
//! `{cache}` beside a linked artifact). When the language-capability-rows
//! framework (#619) lands, this predicate collapses into a manifest
//! capability on the csharp row; the emission halves in build_zig.zig
//! are already keyed off the generic `stage_runtime_outputs` wiring flag,
//! so the migration only moves the DECISION, not the codegen.

const std = @import("std");
const builtin = @import("builtin");
const config = @import("config.zig");
const cache = @import("cache.zig");
const plugin_build_steps = @import("plugin_build_steps.zig");

/// The env var `src/csharp/vm.zig` documents as the assembly-dir
/// override (its resolution order: this, then the running binary's own
/// directory). The generated build.zig sets it on the `run` step.
pub const RUNTIME_ASSEMBLY_DIR_ENV = "LABELLE_CS_ASSEMBLY_DIR";

/// Test seam: when set, `ensureStepToolsOnPath` resolves tools against
/// this PATH-shaped string instead of the process environment's PATH.
/// Same scoped-threadlocal pattern as `scripting_declare
/// .declare_tool_override`.
pub threadlocal var path_override: ?[]const u8 = null;

/// Whether the SELECTED language's build steps publish RUNTIME-LOADED
/// outputs into `{cache}` (the C# CoreCLR-host contract): language
/// `csharp`, at least one step, and NO step links an artifact — a linked
/// artifact would mean `{cache}` also holds intermediates that must not
/// be shipped beside the binary. Drives `PluginBuildStepsWiring
/// .stage_runtime_outputs` (root.zig → build_zig.zig emission).
pub fn stagesRuntimeOutputs(language: []const u8, steps: []const plugin_build_steps.Step) bool {
    if (!std.mem.eql(u8, language, "csharp")) return false;
    if (steps.len == 0) return false;
    for (steps) |s| {
        if (s.link != .none) return false;
    }
    return true;
}

/// Probe every step's `command[0]` on PATH at generate time, failing
/// pointedly when a tool is absent — the alternative is an opaque
/// child-spawn error deep inside the user's next `zig build`. Callers
/// pass the SELECTED language entry's OS-filtered steps (the ones that
/// will actually run). argv[0]s that are not PATH-resolved — absolute or
/// relative paths, or placeholder-bearing (`{package}/…`) — are skipped:
/// the OS resolves those against the filesystem, not PATH, and the
/// staged-package cwd/artifact validations own their existence story.
pub fn ensureStepToolsOnPath(
    allocator: std.mem.Allocator,
    plugin_name: []const u8,
    language: []const u8,
    steps: []const plugin_build_steps.Step,
) !void {
    const path_value: []const u8, const owned: bool = blk: {
        if (path_override) |p| break :blk .{ p, false };
        const env = config.globalEnviron();
        const v = env.getAlloc(allocator, "PATH") catch break :blk .{ "", false };
        break :blk .{ v, true };
    };
    defer if (owned) allocator.free(path_value);

    for (steps) |step| {
        if (step.command.len == 0) continue;
        const tool = step.command[0];
        if (!isPathResolvedTool(tool)) continue;
        if (toolOnPath(path_value, tool)) continue;

        std.debug.print(
            "labelle-assembler: plugin '{s}' \"{s}\" build step '{s}' needs '{s}', which was not found on PATH.\n",
            .{ plugin_name, language, step.name, tool },
        );
        if (toolHint(tool)) |hint| {
            std.debug.print("  → {s}\n", .{hint});
        } else {
            std.debug.print(
                "  → install the toolchain that provides '{s}' (required to compile {s} scripts), or switch the project's script language.\n",
                .{ tool, language },
            );
        }
        return error.PluginBuildToolMissing;
    }
}

/// Install hints for the toolchains the scripting plugin's shipped
/// `.language_builds` entries invoke — the doctor-style "→" line.
/// Diagnostics-only: an unknown tool gets the generic hint, never an
/// error-path difference.
fn toolHint(tool: []const u8) ?[]const u8 {
    const hints = [_]struct { tool: []const u8, hint: []const u8 }{
        .{ .tool = "dotnet", .hint = "csharp games compile scripts/*.cs with the .NET SDK (>= 7, for the [LibraryImport] source generator): https://dotnet.microsoft.com/download" },
        .{ .tool = "cargo", .hint = "rust games compile scripts/*.rs with the Rust toolchain: https://rustup.rs" },
        .{ .tool = "crystal", .hint = "crystal games compile scripts/*.cr with the Crystal compiler: https://crystal-lang.org/install/" },
    };
    for (hints) |h| {
        if (std.mem.eql(u8, tool, h.tool)) return h.hint;
    }
    return null;
}

/// Whether `tool` is resolved via PATH by the OS: a bare program name —
/// no path separator, no placeholder. (`{package}`-rooted argv[0]s are
/// filesystem paths after substitution; absolute/relative paths likewise
/// never consult PATH.)
fn isPathResolvedTool(tool: []const u8) bool {
    if (tool.len == 0) return false;
    if (std.mem.indexOfScalar(u8, tool, '{') != null) return false;
    if (std.mem.indexOfScalar(u8, tool, '/') != null) return false;
    if (builtin.os.tag == .windows and std.mem.indexOfScalar(u8, tool, '\\') != null) return false;
    return true;
}

/// Whether `tool` exists in any dir of the PATH-shaped `path_value`
/// (platform delimiter; on Windows the conventional executable
/// extensions are probed too). Existence-only — no spawn: the probe must
/// stay assumption-free about tool CLIs (`--version` is not universal)
/// and add no per-generate child-process latency. Allocation-free (gemini
/// #644): candidate paths are formatted into one stack buffer — a PATH
/// with hundreds of dirs must not mean hundreds of heap allocations. A
/// candidate longer than the buffer can't name a real file, so an
/// over-long dir is simply skipped (`bufPrint … catch continue`).
fn toolOnPath(path_value: []const u8, tool: []const u8) bool {
    var it = std.mem.splitScalar(u8, path_value, std.fs.path.delimiter);
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    while (it.next()) |dir| {
        if (dir.len == 0) continue;
        if (builtin.os.tag == .windows) {
            for ([_][]const u8{ ".exe", ".cmd", ".bat", "" }) |ext| {
                const candidate = std.fmt.bufPrint(&buf, "{s}{c}{s}{s}", .{ dir, std.fs.path.sep, tool, ext }) catch continue;
                if (cache.dirExists(candidate)) return true;
            }
        } else {
            const candidate = std.fmt.bufPrint(&buf, "{s}{c}{s}", .{ dir, std.fs.path.sep, tool }) catch continue;
            if (cache.dirExists(candidate)) return true;
        }
    }
    return false;
}

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;
const test_io = std.testing.io;

/// A one-command Step for the probe/staging tests. `argv0` is COMPTIME so
/// `&[_][]const u8{argv0}` is a static array literal — a runtime `&.{argv0}`
/// would return a pointer to this function's stack frame, dangling after
/// return (its `command[0]` reads back empty; the classic native-splice
/// suite lesson, hence the crystal tests inline their argv).
fn stepNamed(comptime link: plugin_build_steps.LinkMode, comptime argv0: []const u8) plugin_build_steps.Step {
    return .{
        .name = "s",
        .command = &[_][]const u8{argv0},
        .artifact = if (link == .none) null else "{cache}/a.o",
        .link = link,
    };
}

test "stagesRuntimeOutputs: csharp with only link-less steps fires; a linked step, another language, or zero steps do not" {
    // The csharp shape — one link-less dotnet-publish step: `{cache}` IS the
    // runtime payload, staged beside the binary.
    try testing.expect(stagesRuntimeOutputs("csharp", &.{stepNamed(.none, "dotnet")}));
    // A linked artifact means {cache} holds intermediates — never shipped.
    try testing.expect(!stagesRuntimeOutputs("csharp", &.{ stepNamed(.none, "dotnet"), stepNamed(.object, "ld") }));
    // The rust/crystal native rows keep their link wiring, no staging.
    try testing.expect(!stagesRuntimeOutputs("rust", &.{stepNamed(.none, "cargo")}));
    try testing.expect(!stagesRuntimeOutputs("crystal", &.{stepNamed(.none, "crystal")}));
    // Steps-less never fires (nothing would produce the payload).
    try testing.expect(!stagesRuntimeOutputs("csharp", &.{}));
}

test "ensureStepToolsOnPath: a present tool passes, a missing one fails pointedly, path-shaped argv0s are skipped" {
    const allocator = testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // A fake on-PATH tool: existence is the probe's contract (no spawn).
    var f = try tmp.dir.createFile(test_io, "faketool", .{});
    f.close(test_io);
    const tmp_abs = try tmp.dir.realPathFileAlloc(test_io, ".", allocator);
    defer allocator.free(tmp_abs);

    path_override = tmp_abs;
    defer path_override = null;

    // Present → ok.
    try ensureStepToolsOnPath(allocator, "scripting", "csharp", &.{stepNamed(.none, "faketool")});
    // Missing → the pointed generate error.
    try testing.expectError(
        error.PluginBuildToolMissing,
        ensureStepToolsOnPath(allocator, "scripting", "csharp", &.{stepNamed(.none, "no-such-tool-617")}),
    );
    // Absolute and placeholder-bearing argv0s are not PATH-resolved — skipped
    // even though they don't exist under the override PATH.
    try ensureStepToolsOnPath(allocator, "scripting", "csharp", &.{stepNamed(.none, "/abs/path/tool")});
    try ensureStepToolsOnPath(allocator, "scripting", "csharp", &.{stepNamed(.none, "{package}/tools/x")});
}

test "toolHint: dotnet names the .NET SDK requirement; unknown tools get the generic line" {
    // The #617 acceptance: the error names the requirement when dotnet is
    // absent — pin the hint's load-bearing tokens.
    const dotnet = toolHint("dotnet").?;
    try testing.expect(std.mem.indexOf(u8, dotnet, ".NET SDK") != null);
    try testing.expect(std.mem.indexOf(u8, dotnet, "dotnet.microsoft.com") != null);
    try testing.expect(toolHint("some-future-tool") == null);
}
