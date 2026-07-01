//! sokol backend build hook (manifest-v2, epic #453 item 3) — the DEDICATED
//! hook file the v2 manifest points at via `.build_hook = "backend.hook.zig"`
//! (design §3/§4). It is NOT sokol's own `build.zig`: that file re-exports
//! `pub const emLinkStep = @import("sokol").emLinkStep;` at top level, and
//! `"sokol"` is a name resolvable only inside the labelle_sokol package build
//! context — absent from the generated ROOT package the assembler imports the
//! hook into. So the hook makes NO package-local import assumptions: it may
//! `@import("std")` (and `@import("builtin")` for the host tag) and take
//! everything else through the hook context.
//!
//! ## PR 5 scope — android is the first HOOK-BEARING conversion
//!
//! DESKTOP has no residual: it is fully declarative and `.target = .native`
//! resolves without a hook, so the assembler never invokes this hook on a
//! desktop build. ANDROID (this PR) exercises BOTH hook phases:
//!
//!   * `resolve_target` — runs BEFORE any `b.dependency` and produces the
//!     android `ResolvedTarget` from `-Demulator`/`-Dandroid_arch` + host arch.
//!     This reproduces the enum path's `header_android` target-resolution block
//!     (`build_zig.txt:690`-`719`) exactly.
//!   * `post_wire` — runs AFTER the generic module/artifact/system-lib wiring and
//!     supplements the graph with the residual the manifest cannot express
//!     statically (design §2 residual (a)): NDK sysroot detection + the
//!     `addSystemIncludePath`/`addLibraryPath` calls that consume it + the
//!     `libc.txt` generation. Reproduces `build_zig.txt:776`-`777`/`851`/
//!     `859`-`868`.
//!
//! ios/wasm are PR-6/7 stubs. The generated v2 build.zig `@import`s this file
//! (as a sibling `backend_build_hook.zig`) and calls the two functions; that
//! import is the design's "assembler imports the hook into the generated root
//! package" (§3). Because the whole v2 route is gated-dark (opt-in via the
//! assembler's `backend_manifest_name`, never set on the production `generate`
//! path — §6), PR 5 exercises it only through the golden-cell + hook gates, not
//! a production android build.

const std = @import("std");
const builtin = @import("builtin");

/// Versioned with the hook ABI (design §4). Asserted `== HOOK_ABI_VERSION` by the
/// assembler before the hook is ever called; matches
/// `manifest_v2.HOOK_ABI_VERSION`.
pub const HOOK_ABI_VERSION: u8 = 2;

/// The platform tag the hook branches on. Mirrors `config.Platform` structurally
/// so the hook needs no assembler import.
pub const Platform = enum { desktop, ios, android, wasm };

/// Error surface for the pure decision helpers (so they stay unit-testable
/// without a live `*std.Build` and without an uncatchable `@panic`). The
/// `resolve_target`/`post_wire` entry points turn these into a `@panic` at the
/// call site — a misconfiguration is a hard build error, not a recoverable one —
/// but the underlying logic is exercised through the error return in tests.
pub const HookError = error{
    /// `-Dandroid_arch=<v>` was neither arm64/aarch64 nor x86_64/x64.
    InvalidAndroidArch,
    /// `ctx.android_target_sdk` was null on an Android build. The assembler MUST
    /// populate it (from `cfg.android.target_sdk_version`, always a concrete
    /// value) — a null is an assembler bug, and a silent `orelse 34` would emit a
    /// wrong `usr/lib/<triple>/34` path while appearing to honor the user's
    /// `target_sdk_version` (design §4 review-correction #6). So this is a hard
    /// error, never a default.
    AndroidTargetSdkRequired,
};

// ── resolve_target (design §4) — runs BEFORE any b.dependency ──────────────

/// What the pre-dependency `resolve_target` phase returns: the `ResolvedTarget`
/// every subsequent `b.dependency` (backend + plugins) consumes, plus the iOS SDK
/// path plugin dependency calls need (null on non-iOS). Android carries only the
/// target; the NDK sysroot is detected later in `post_wire` (it is not needed
/// before the dependency calls).
pub const ResolvedTargetInfo = struct {
    target: std.Build.ResolvedTarget,
    ios_sdk_path: ?[]const u8 = null,
};

/// Context handed to `resolve_target`. Only the platform is needed today; kept a
/// struct so future fields (e.g. an explicit device/simulator override for iOS)
/// are additive.
pub const ResolveContext = struct {
    platform: Platform,
};

/// PURE arch selection — the testable core of the android target resolution
/// (`build_zig.txt:703`-`713`). `-Dandroid_arch` wins when set (arm64|x86_64);
/// otherwise `-Demulator` picks the host-matching arch (arm64 on Apple Silicon,
/// x86_64 on Intel); otherwise arm64. Returns an error on an unknown explicit
/// arch so the caller can decide whether to panic (build) or assert (test).
pub fn selectAndroidArch(
    host_arch: std.Target.Cpu.Arch,
    emulator_mode: bool,
    arch_opt: ?[]const u8,
) HookError!std.Target.Cpu.Arch {
    if (arch_opt) |name| {
        if (std.mem.eql(u8, name, "arm64") or std.mem.eql(u8, name, "aarch64")) return .aarch64;
        if (std.mem.eql(u8, name, "x86_64") or std.mem.eql(u8, name, "x64")) return .x86_64;
        return HookError.InvalidAndroidArch;
    }
    const emulator_arch: std.Target.Cpu.Arch = switch (host_arch) {
        .aarch64 => .aarch64,
        else => .x86_64,
    };
    return if (emulator_mode) emulator_arch else .aarch64;
}

/// PURE NDK triple mapping (`build_zig.txt:722`-`726`). The `usr/include/<triple>`
/// and `usr/lib/<triple>/<api>` NDK paths are keyed by this.
pub fn ndkArchTriple(arch: std.Target.Cpu.Arch) []const u8 {
    return switch (arch) {
        .aarch64 => "aarch64-linux-android",
        .x86_64 => "x86_64-linux-android",
        // resolve_target only ever produces the two arches above; a third would
        // be an assembler bug, not a user error.
        else => "aarch64-linux-android",
    };
}

/// Produce the android `ResolvedTarget`. Reproduces `build_zig.txt:690`-`719`.
/// Runs before any `b.dependency`, so it constructs no graph nodes.
pub fn resolve_target(b: *std.Build, ctx: ResolveContext) ResolvedTargetInfo {
    switch (ctx.platform) {
        .android => {
            const emulator_mode = b.option(bool, "emulator", "Build for Android emulator (x86_64 on Intel Mac, arm64 on Apple Silicon)") orelse false;
            const android_arch_opt = b.option([]const u8, "android_arch", "Android target arch (arm64|x86_64). Overrides -Demulator when set.");
            const android_arch = selectAndroidArch(b.graph.host.result.cpu.arch, emulator_mode, android_arch_opt) catch {
                std.debug.print("build.zig: unknown -Dandroid_arch value (expected arm64 or x86_64)\n", .{});
                @panic("invalid android_arch");
            };
            return .{ .target = b.resolveTargetQuery(.{
                .cpu_arch = android_arch,
                .os_tag = .linux,
                .abi = .android,
            }) };
        },
        // desktop=.native and wasm=.triple resolve without a hook; iOS lands in
        // PR 6. resolve_target is never called for these in PR 5.
        else => @panic("resolve_target: only android is implemented (PR 5)"),
    }
}

// ── post_wire (design §4) — runs AFTER generic wiring ──────────────────────

/// `post_wire` context (design §4). Every field is valid because `post_wire` runs
/// strictly AFTER `b.dependency` and after the root exe/lib is created. Kept
/// structurally in sync with `manifest_v2.HookContext`.
pub const HookContext = struct {
    manifest_version: u8,
    backend_dep: *std.Build.Dependency,
    root_module: *std.Build.Module,
    root_artifact: *std.Build.Step.Compile,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    platform: Platform,
    ios_sdk_path: ?[]const u8,
    android_target_sdk: ?u32,
};

/// REQUIRED android SDK accessor — the testable enforcement of "no silent 34
/// default" (design §4 review-correction #6). Returns an error on null so the
/// error path is unit-testable; `post_wire` turns it into a `@panic`.
pub fn requireAndroidSdk(ctx: HookContext) HookError!u32 {
    return ctx.android_target_sdk orelse HookError.AndroidTargetSdkRequired;
}

/// PURE libc.txt body builder (`build_zig.txt:859`-`866`). Zig does not bundle
/// Android libc, so the generated `.so` build needs a `libc.txt` pointing the
/// compiler at the NDK sysroot. Takes pre-joined paths so it is unit-testable
/// without a `*std.Build`; `post_wire` joins the paths via `b.pathJoin` and calls
/// this. Caller owns the returned slice.
pub fn libcTxt(
    allocator: std.mem.Allocator,
    include_dir: []const u8,
    sys_include_dir: []const u8,
    crt_dir: []const u8,
) ![]u8 {
    return std.mem.concat(allocator, u8, &.{
        "include_dir=",     include_dir,     "\n",
        "sys_include_dir=", sys_include_dir, "\n",
        "crt_dir=",         crt_dir,         "\n",
        "msvc_lib_dir=\n",
        "kernel32_lib_dir=\n",
        "gcc_dir=\n",
    });
}

/// Detect the Android NDK sysroot. Copied verbatim from the enum path's
/// `header_android` (`build_zig.txt:632`-`676`) so the residual behaves
/// identically — env lookups go through `b.graph.environ_map`, FS probes through
/// `std.Io.Dir.cwd().access(io, ...)` (Zig 0.16 removed the older APIs, #144).
fn getAndroidNdkSysroot(b: *std.Build) ?[]const u8 {
    const io = b.graph.io;
    if (b.graph.environ_map.get("ANDROID_NDK_HOME")) |ndk_home| {
        const sysroot = b.pathJoin(&.{ ndk_home, "toolchains", "llvm", "prebuilt", ndkHostTag(), "sysroot" });
        if (std.Io.Dir.cwd().access(io, sysroot, .{})) |_| {
            return sysroot;
        } else |_| {}
    }
    if (b.graph.environ_map.get("ANDROID_HOME")) |home| {
        const ndk_dir = b.pathJoin(&.{ home, "ndk" });
        var dir = std.Io.Dir.cwd().openDir(io, ndk_dir, .{ .iterate = true }) catch return null;
        defer dir.close(io);
        // Collect every version dir together with WHETHER it actually has a
        // usable sysroot, then pick the greatest VALID one. A stray/partial NDK
        // install (or a lexicographically-greater dir with no sysroot) must NOT
        // shadow an older, valid NDK — checking validity only AFTER picking the
        // greatest dir made us miss it and panic (PR #466 Finding 2).
        var candidates: std.ArrayList(NdkCandidate) = .empty;
        defer {
            for (candidates.items) |c| b.allocator.free(c.name);
            candidates.deinit(b.allocator);
        }
        var iter = dir.iterate();
        while (iter.next(io) catch null) |entry| {
            if (entry.kind != .directory) continue;
            const name = b.allocator.dupe(u8, entry.name) catch continue;
            const sysroot = b.pathJoin(&.{ ndk_dir, name, "toolchains", "llvm", "prebuilt", ndkHostTag(), "sysroot" });
            const has_sysroot = if (std.Io.Dir.cwd().access(io, sysroot, .{})) |_| true else |_| false;
            candidates.append(b.allocator, .{ .name = name, .has_sysroot = has_sysroot }) catch {
                b.allocator.free(name);
                continue;
            };
        }
        if (selectGreatestValidNdk(candidates.items)) |version| {
            return b.pathJoin(&.{ ndk_dir, version, "toolchains", "llvm", "prebuilt", ndkHostTag(), "sysroot" });
        }
    }
    return null;
}

/// A candidate `$ANDROID_HOME/ndk/<name>` dir paired with whether its
/// `toolchains/llvm/prebuilt/<host>/sysroot` actually exists.
const NdkCandidate = struct { name: []const u8, has_sysroot: bool };

/// Pick the lexicographically-greatest NDK version dir that HAS a valid sysroot.
/// Validity is part of the selection (not an after-the-fact check on the greatest
/// dir), so a stray/partial install can't shadow an older valid NDK (PR #466
/// Finding 2). Returns a borrowed slice from `candidates` or null when none valid.
fn selectGreatestValidNdk(candidates: []const NdkCandidate) ?[]const u8 {
    var best: ?[]const u8 = null;
    for (candidates) |c| {
        if (!c.has_sysroot) continue;
        if (best) |prev| {
            if (std.mem.order(u8, c.name, prev) == .gt) best = c.name;
        } else {
            best = c.name;
        }
    }
    return best;
}

fn ndkHostTag() []const u8 {
    return switch (builtin.os.tag) {
        .linux => "linux-x86_64",
        .macos => "darwin-x86_64",
        .windows => "windows-x86_64",
        else => "linux-x86_64",
    };
}

/// Runs AFTER the generic module/artifact/system-lib/framework wiring, to
/// supplement the graph with the residual the manifest cannot express statically
/// (design §2 residual (a)). DESKTOP is empty (no residual). ANDROID does the NDK
/// sysroot include/lib paths + libc.txt (the generic parts — `linkLibrary`,
/// `linkSystemLibrary`, `link_libc`, artifact `.pic` — are emitted declaratively
/// by the assembler from the manifest, NOT here). ios/wasm are PR-6/7 stubs.
pub fn post_wire(b: *std.Build, ctx: HookContext) void {
    switch (ctx.platform) {
        .desktop => {}, // fully declarative — no residual
        .android => {
            const sysroot = getAndroidNdkSysroot(b) orelse
                @panic("Could not find Android NDK. Set ANDROID_NDK_HOME or ANDROID_HOME.");
            // REQUIRED — no `orelse 34` fallback (design §4 review-correction #6).
            const api = requireAndroidSdk(ctx) catch
                @panic("android_target_sdk must be populated for Android builds");
            const triple = ndkArchTriple(ctx.target.result.cpu.arch);
            const api_str = b.fmt("{d}", .{api});

            const include_dir = b.pathJoin(&.{ sysroot, "usr/include" });
            const sys_include_dir = b.pathJoin(&.{ sysroot, "usr/include", triple });
            const crt_dir = b.pathJoin(&.{ sysroot, "usr/lib", triple, api_str });

            // C header include paths on the sokol_clib archive (the .pic on it is
            // set declaratively by the assembler). `build_zig.txt:776`-`777`.
            const clib = ctx.backend_dep.artifact("sokol_clib");
            clib.root_module.addSystemIncludePath(.{ .cwd_relative = include_dir });
            clib.root_module.addSystemIncludePath(.{ .cwd_relative = sys_include_dir });

            // Per-API NDK library path + libc.txt on the .so root
            // (`build_zig.txt:851`,`:859`-`868`).
            ctx.root_artifact.root_module.addLibraryPath(.{ .cwd_relative = crt_dir });
            const libc_content = libcTxt(b.allocator, include_dir, sys_include_dir, crt_dir) catch @panic("OOM");
            const android_libc = b.addWriteFiles();
            ctx.root_artifact.setLibCFile(android_libc.add("android-libc.txt", libc_content));
        },
        // PR 6: configureSdkPaths / addExeSdkPaths consuming ctx.ios_sdk_path.
        .ios => {},
        // PR 7: emccStep / emLinkStep on ctx.root_artifact (needs the emsdk root
        // dep declared via .platforms.wasm.root_build_deps).
        .wasm => {},
    }
}

// ============================================================================
// Tests — the PURE residual/decision helpers (design §7 "run the hook").
//
// These run because `backends/sokol/backend.hook.zig` is compiled as a test
// target in the assembler's `build.zig` (test_files), which ALSO typechecks
// `resolve_target`/`post_wire` against the real `std.Build` API — a compile-level
// gate that a residual API call (addLibraryPath/setLibCFile/linkSystemLibrary/…)
// stays valid. The pure helpers below then assert the residual DECISIONS
// (arch selection, NDK triple, required-SDK enforcement, libc.txt body).
// ============================================================================

const testing = std.testing;

test "selectAndroidArch: explicit -Dandroid_arch wins (both spellings)" {
    try testing.expectEqual(std.Target.Cpu.Arch.aarch64, try selectAndroidArch(.x86_64, false, "arm64"));
    try testing.expectEqual(std.Target.Cpu.Arch.aarch64, try selectAndroidArch(.x86_64, true, "aarch64"));
    try testing.expectEqual(std.Target.Cpu.Arch.x86_64, try selectAndroidArch(.aarch64, false, "x86_64"));
    try testing.expectEqual(std.Target.Cpu.Arch.x86_64, try selectAndroidArch(.aarch64, true, "x64"));
}

test "selectAndroidArch: emulator picks host arch; default is arm64" {
    // No explicit arch, emulator on → host-matching.
    try testing.expectEqual(std.Target.Cpu.Arch.aarch64, try selectAndroidArch(.aarch64, true, null));
    try testing.expectEqual(std.Target.Cpu.Arch.x86_64, try selectAndroidArch(.x86_64, true, null));
    // No explicit arch, no emulator → arm64 device default regardless of host.
    try testing.expectEqual(std.Target.Cpu.Arch.aarch64, try selectAndroidArch(.aarch64, false, null));
    try testing.expectEqual(std.Target.Cpu.Arch.aarch64, try selectAndroidArch(.x86_64, false, null));
}

test "selectAndroidArch: unknown explicit arch is an error, not a silent default" {
    try testing.expectError(HookError.InvalidAndroidArch, selectAndroidArch(.aarch64, false, "riscv64"));
}

test "ndkArchTriple: the two resolvable arches map to the NDK triples" {
    try testing.expectEqualStrings("aarch64-linux-android", ndkArchTriple(.aarch64));
    try testing.expectEqualStrings("x86_64-linux-android", ndkArchTriple(.x86_64));
}

test "requireAndroidSdk: present value is returned; null is a hard error (no 34 default)" {
    const base: HookContext = .{
        .manifest_version = HOOK_ABI_VERSION,
        .backend_dep = undefined,
        .root_module = undefined,
        .root_artifact = undefined,
        .target = undefined,
        .optimize = .Debug,
        .platform = .android,
        .ios_sdk_path = null,
        .android_target_sdk = 30,
    };
    try testing.expectEqual(@as(u32, 30), try requireAndroidSdk(base));

    var missing = base;
    missing.android_target_sdk = null;
    try testing.expectError(HookError.AndroidTargetSdkRequired, requireAndroidSdk(missing));
}

test "libcTxt: body points the compiler at the NDK sysroot (matches the enum block)" {
    const out = try libcTxt(
        testing.allocator,
        "/ndk/sysroot/usr/include",
        "/ndk/sysroot/usr/include/aarch64-linux-android",
        "/ndk/sysroot/usr/lib/aarch64-linux-android/34",
    );
    defer testing.allocator.free(out);
    try testing.expectEqualStrings(
        "include_dir=/ndk/sysroot/usr/include\n" ++
            "sys_include_dir=/ndk/sysroot/usr/include/aarch64-linux-android\n" ++
            "crt_dir=/ndk/sysroot/usr/lib/aarch64-linux-android/34\n" ++
            "msvc_lib_dir=\n" ++
            "kernel32_lib_dir=\n" ++
            "gcc_dir=\n",
        out,
    );
}

test "HOOK_ABI_VERSION is 2 (matches manifest_v2)" {
    try testing.expectEqual(@as(u8, 2), HOOK_ABI_VERSION);
}

test "selectGreatestValidNdk: a stray dir doesn't shadow a valid older NDK (PR #466 Finding 2)" {
    // "27.0.0" sorts greatest but has NO sysroot (stray/partial install); the
    // greatest VALID dir is "26.1.10909125" — the old "greatest dir then check"
    // logic would have picked 27 and missed it.
    const c1 = [_]NdkCandidate{
        .{ .name = "25.2.9519653", .has_sysroot = true },
        .{ .name = "26.1.10909125", .has_sysroot = true },
        .{ .name = "27.0.0", .has_sysroot = false },
    };
    try testing.expectEqualStrings("26.1.10909125", selectGreatestValidNdk(&c1).?);

    // All valid → the greatest is chosen.
    const c2 = [_]NdkCandidate{
        .{ .name = "25.2.9519653", .has_sysroot = true },
        .{ .name = "26.1.10909125", .has_sysroot = true },
    };
    try testing.expectEqualStrings("26.1.10909125", selectGreatestValidNdk(&c2).?);

    // No valid candidate → null (caller then falls through / panics upstream).
    const c3 = [_]NdkCandidate{
        .{ .name = "27.0.0", .has_sysroot = false },
    };
    try testing.expectEqual(@as(?[]const u8, null), selectGreatestValidNdk(&c3));

    // Empty set → null.
    try testing.expectEqual(@as(?[]const u8, null), selectGreatestValidNdk(&.{}));
}
