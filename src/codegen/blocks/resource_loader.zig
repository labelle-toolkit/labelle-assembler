//! Per-resource loader emit for the generated `main.zig`.
//!
//! Extracted from `src/main_zig.zig` (labelle-assembler#183, step 5b)
//! per `docs/REFACTOR-PLAN-main-zig.md`. Owns the one-line dispatcher
//! that the orchestrator calls once per `ResourceDef` to materialise
//! a `Game.load{Atlas,Sound,Font}FromMemory(...)` (or `register…` for
//! lazy resources) into the generated source.
//!
//! `emitResourceLoad` is reached from BOTH lifecycle paths today —
//! `buildSetupCode` (loop-backend setup) uses `.try_style`, the sokol
//! callback initializer uses `.catch_panic_style`. Keeping the
//! per-style branching here means neither lifecycle builder has to
//! know how the underlying `Game.*FromMemory` calls are spelled.
//!
//! Pure emit: no allocations, no template state beyond the writer.
//! Depends on `idents.extWithoutDot` (asset ext sans the dot, matches
//! the engine's `file_type` contract) — `isValidZigIdentifier` is
//! validated upstream by `validateResources`, so this module just
//! interpolates the name into the generated source.

const config = @import("../../config.zig");
const idents = @import("../idents.zig");

const ResourceDef = config.ResourceDef;
const extWithoutDot = idents.extWithoutDot;
const lowerExtWithoutDot = idents.lowerExtWithoutDot;

/// Wrapper style for `emitResourceLoad`. The two callers differ only
/// in how they propagate load failures:
///
/// - `try_style` — used by `buildSetupCode`, whose enclosing function
///   returns `!void`. Emits `try g.loadXxxFromMemory(...);`.
/// - `catch_panic_style` — used by `buildCallbackInitCode`, whose
///   sokol-callback host has no error channel to unwind into. Emits
///   `g.loadXxxFromMemory(...) catch @panic("failed to load ...");`.
pub const LoadStyle = enum { try_style, catch_panic_style };

/// Emit the loader call for one `ResourceDef`, dispatching on
/// `res.kind()`:
///
/// - `.atlas` → `g.{load,register}AtlasFromMemory(name, json, png, ".png")`
/// - `.image` → `g.assets.register(name, .image, ".ext", bytes)`, plus
///   `g.assets.acquire(name)` when the resource is EAGER.
///
///   There is deliberately no `g.loadImageFromMemory` call: the engine
///   ships no image-specific `Game` shim (`labelle-engine/src/game.zig`
///   re-exports `load{Atlas,Sound,Font}FromMemory` but nothing for a
///   loose image), and the engine's `Image` component resolves its
///   `name` straight off the `AssetCatalog` — so the catalog
///   registration IS the whole contract. `AssetAlreadyRegistered` is
///   swallowed, matching every engine-side `register*FromMemory` shim,
///   so a name some other path already registered is not a hard failure.
///   That suppression is only safe because the DECLARED names are proven
///   unique first: `validateResources` rejects two resources sharing a
///   name (`error.DuplicateResourceName`) over the MERGED game+pack list,
///   before any emission. Without that pass a duplicate would leave the
///   first image registered, drop the second, and silently resolve every
///   `acquire` to the wrong asset (coderabbit, #676).
///
///   EAGER here means "start decoding at init", not "block until
///   decoded". The engine's blocking helper (`loadAssetIfNeededInternal`)
///   is kind-agnostic but is NOT re-exported on the `Game` type — only
///   the kind-named `loadSoundIfNeeded` / `loadFontIfNeeded` aliases are,
///   and `loadAtlasIfNeeded` is atlas-specific (it ends in
///   `markPendingLoaded`, which errors `AtlasNotFound` for a loose
///   image). Calling a sound/font-named alias on an image would be a lie
///   in generated source, so the eager path uses the public
///   `AssetCatalog.acquire` instead: the refcount lands exactly where the
///   blocking helper leaves it (1, never released), the decode is
///   enqueued at init, and the per-tick `assets.pump()` completes it.
///   An `Image` entity simply skips rendering until then — the documented
///   pop-in model in `labelle-engine/src/image_component.zig`. Once the
///   engine grows `register/loadImageFromMemory` + `loadImageIfNeeded`
///   shims, this arm can move to them for blocking parity.
/// - `.sound` → `g.{load,register}SoundFromMemory(name, ext, bytes)`
/// - `.font`  → emits `{name}_ranges` const array + `{name}_params`
///   const struct, then `g.{load,register}FontFromMemory(name, ext,
///   bytes, &{name}_params)`. Materialising the params as a local
///   `engine.FontBakeParams` lets the catalog's `WorkRequest.params`
///   slot point at it without a runtime allocation; the const lives
///   on the stack frame for `main()`'s lifetime.
///
/// Caller has already validated `res.kind() != .invalid` via
/// `validateResources` — this function returns `error.InvalidResourceDef`
/// if reached anyway to guard against future call-site additions.
pub fn emitResourceLoad(w: anytype, res: ResourceDef, style: LoadStyle) !void {
    const is_lazy = res.lazy orelse false;
    switch (res.kind()) {
        .atlas => {
            const fn_name = if (is_lazy) "registerAtlasFromMemory" else "loadAtlasFromMemory";
            switch (style) {
                .try_style => try w.print(
                    "    try g.{s}(\"{s}\", @embedFile(\"{s}\"), @embedFile(\"{s}\"), \".png\");\n",
                    .{ fn_name, res.name, res.json, res.texture },
                ),
                .catch_panic_style => try w.print(
                    "    g.{s}(\"{s}\", @embedFile(\"{s}\"), @embedFile(\"{s}\"), \".png\") catch @panic(\"failed to load atlas: {s}\");\n",
                    .{ fn_name, res.name, res.json, res.texture, res.name },
                ),
            }
        },
        .image => {
            // Loose image (#675). `file_type` carries the LEADING DOT —
            // the same spelling the atlas arm passes ("`.png`"), which is
            // what raylib's `LoadImageFromMemory` expects and what every
            // other backend's `decodeImage` is written against. Derived
            // from the declared path rather than hard-coded so a `.astc` /
            // `.rgba` sibling pointed at directly still reports its real
            // type.
            //
            // LOWER-CASED on the way out: extension validation is
            // case-insensitive, so `assets/Logo.PNG` is a legal
            // declaration, but the `file_type` contract is the lower-case
            // extension — emitting `".PNG"` would hand a case-sensitive
            // `decodeImage` a type it does not recognise. 8 bytes covers
            // every accepted extension (longest is `"jpeg"`).
            var ext_buf: [8]u8 = undefined;
            const ext = lowerExtWithoutDot(&ext_buf, res.image);
            switch (style) {
                .try_style => {
                    try w.print(
                        "    g.assets.register(\"{s}\", .image, \".{s}\", @embedFile(\"{s}\")) catch |err| switch (err) {{ error.AssetAlreadyRegistered => {{}}, else => return err }};\n",
                        .{ res.name, ext, res.image },
                    );
                    if (!is_lazy) {
                        try w.print("    _ = try g.assets.acquire(\"{s}\");\n", .{res.name});
                    }
                },
                .catch_panic_style => {
                    try w.print(
                        "    g.assets.register(\"{s}\", .image, \".{s}\", @embedFile(\"{s}\")) catch |err| switch (err) {{ error.AssetAlreadyRegistered => {{}}, else => @panic(\"failed to register image: {s}\") }};\n",
                        .{ res.name, ext, res.image, res.name },
                    );
                    if (!is_lazy) {
                        try w.print("    _ = g.assets.acquire(\"{s}\") catch @panic(\"failed to acquire image: {s}\");\n", .{ res.name, res.name });
                    }
                },
            }
        },
        .sound => {
            const fn_name = if (is_lazy) "registerSoundFromMemory" else "loadSoundFromMemory";
            const ext = extWithoutDot(res.sound);
            switch (style) {
                .try_style => try w.print(
                    "    try g.{s}(\"{s}\", \"{s}\", @embedFile(\"{s}\"));\n",
                    .{ fn_name, res.name, ext, res.sound },
                ),
                .catch_panic_style => try w.print(
                    "    g.{s}(\"{s}\", \"{s}\", @embedFile(\"{s}\")) catch @panic(\"failed to load sound: {s}\");\n",
                    .{ fn_name, res.name, ext, res.sound, res.name },
                ),
            }
        },
        .font => {
            const fn_name = if (is_lazy) "registerFontFromMemory" else "loadFontFromMemory";
            const ext = extWithoutDot(res.font);
            const params = res.font_params orelse config.FontBakeParams{};
            // Materialise FontBakeParams locally so the slice field has
            // a real address to point at. The trailing const sits in
            // main()'s frame until process exit — same lifetime as
            // `@embedFile` bytes on the catalog side.
            try w.print("    const {s}_ranges = [_]engine.CodepointRange{{\n", .{res.name});
            for (params.ranges) |r| {
                try w.print("        .{{ .first = 0x{X}, .last = 0x{X} }},\n", .{ r.first, r.last });
            }
            try w.writeAll("    };\n");
            try w.print(
                "    const {s}_params: engine.FontBakeParams = .{{ .pixel_height = {d}, .ranges = &{s}_ranges, .atlas_width = {d}, .atlas_height = {d} }};\n",
                .{ res.name, params.pixel_height, res.name, params.atlas_width, params.atlas_height },
            );
            switch (style) {
                .try_style => try w.print(
                    "    try g.{s}(\"{s}\", \"{s}\", @embedFile(\"{s}\"), &{s}_params);\n",
                    .{ fn_name, res.name, ext, res.font, res.name },
                ),
                .catch_panic_style => try w.print(
                    "    g.{s}(\"{s}\", \"{s}\", @embedFile(\"{s}\"), &{s}_params) catch @panic(\"failed to load font: {s}\");\n",
                    .{ fn_name, res.name, ext, res.font, res.name, res.name },
                ),
            }
        },
        .invalid => return error.InvalidResourceDef,
    }
}

/// Mixin factory for `Codegen` (labelle-assembler#183, mixin conversion).
///
/// `emitResourceLoad` consults no shared state — `res` and `style` are
/// the only inputs. The mixin exists so the orchestrator can dispatch
/// through `ctx.emitResourceLoad(...)` uniformly with the other block
/// writers. Standalone function above stays `pub` for the test surface
/// and for direct calls from `lifecycle_loop` / `lifecycle_callback`'s
/// loop bodies.
pub fn Mixin(comptime Self: type) type {
    // Capture the enclosing file's namespace so the same-name method
    // below can reach the standalone body without shadowing recursion.
    // `@This()` evaluated here (in the factory body, outside the returned
    // struct) resolves to the file namespace; survives file renames that
    // an `@import("self.zig")` workaround would silently break.
    const file = @This();
    return struct {
        pub fn emitResourceLoad(_: *Self, w: anytype, res: ResourceDef, style: LoadStyle) !void {
            return file.emitResourceLoad(w, res, style);
        }
    };
}
