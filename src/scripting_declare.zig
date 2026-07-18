//! Script-declared components AND events — declare-mode extraction + Zig
//! codegen (labelle-assembler#585 components, labelle-engine#772 events;
//! RFC-LANGUAGE-PLUGINS revs 6-7, epic labelle-engine#237).
//!
//! Scripts declare components natively in their own language — canonically
//! in `components/*.<ext>` beside the Zig components (labelle-engine#237's
//! refinement: `Hunger = Labelle.component "Hunger", level: 0.875` in
//! `components/hunger.rb`), with in-script chunk-scope declarations
//! (`labelle.component("Hunger", { level = 1.0 })` — the shipped lua
//! mechanism) remaining legal. At generate time this phase — the second
//! consumer of the #593 scripting splice — runs the language's DECLARE
//! RUNNER (`DECLARE_RUNNERS`: `labelle-declare` under `tools/declare` for
//! lua, `labelle-declare-ruby` under `tools/declare-ruby` for ruby — each
//! shipped inside the labelle-scripting package) over the project's
//! collected files: `components/*.<ext>` FIRST, then the script dir's.
//! Every runner executes only chunk bodies against a stub `labelle`/
//! `Labelle` and prints ONE schema JSON on stdout (byte-identical across
//! runners — the scripting repo's cross-runner golden is the proof) — the
//! runner↔assembler contract:
//!
//!   {"components":[{"name":"Hunger","persist":"persistent",
//!     "fields":[{"name":"level","type":"f32","default":1.0},
//!               {"name":"starving","type":"bool","default":false}]}]}
//!
//! Types v1: f32 i32 u32 u64 bool str vec2 entity ("persist":
//! "persistent" [default] | "transient"; enums land LATER and are
//! rejected with a clear error; u64 is scripting v0.10.0's `Labelle.id`
//! sentinel — legal in components and events alike). From that schema the
//! phase codegens `scripting_components.zig` into the target — one real
//! Zig struct per component, `Saveable`-decl'd exactly like a
//! hand-written `components/*.zig` — and the registry block registers
//! each by its declared name. Scenes, prefabs, save buckets, typed Zig
//! queries and the script contract's by-name dispatch all reach them with
//! zero further wiring.
//!
//! Events (labelle-engine#772, scripting v0.10.0): the same schema
//! carries a top-level `"events":[{name, fields}]` array — present ONLY
//! when non-empty (compat by construction: older schemas are
//! byte-identical), no persist key (events are never saved). Declarations
//! live in `events/*.<ext>` beside the Zig events (the #237 "where their
//! kind lives" convention — `HungerFeed = Labelle.event "hunger__feed",
//! entity: Labelle.id, amount: 0.5`), collected + embedded by root.zig
//! between the component declarations and the script dir's files. The
//! phase codegens ALL declared events into ONE `scripting_events.zig` at
//! the target root (beside `scripting_components.zig`) — the staged
//! `events/` dir is a whole-dir SYMLINK into the game tree
//! (`scanner.linkDir`), so per-event `events/<name>.zig` materialization
//! would write THROUGH into the game's sources. The game-events union
//! block then emits one variant per declared event
//! (`hunger__feed: @import("scripting_events.zig").HungerFeed`) — same
//! bus row an `events/hunger__feed.zig` would get, so script `emit`/`on`
//! by name and native hook methods (`pub fn hunger__feed(self, feed:
//! anytype)`) reach it with zero further wiring. (A native hook consuming
//! a DECLARED event spells its payload param `anytype` — the generated
//! file doesn't exist in the game tree for an in-tree typed import.)
//!
//! No-op guarantee: no scripts, or scripts with no declarations, emit
//! nothing — no file, no registry entries, byte-identical output (the
//! stale `scripting_components.zig` of a removed declaration set is
//! deleted, never regenerated).
//!
//! ── The exec slice (build + cache mechanics) ─────────────────────────
//! The runner binary is built FROM THE CONSUMING GAME'S staged plugin
//! package: `build.zig.zon` generation stages every plugin under
//! `<output>/.labelle/deps/labelle-<name>/` (deps_linker hardlinks), so
//! this phase — ordered right after it — invokes (per the selected row)
//!
//!   zig build <step_name>            # labelle-declare / labelle-declare-ruby
//!       --cache-dir <output>/declare-tool/zig-cache
//!       --prefix    <output>/declare-tool
//!       (cwd = <output>/deps/labelle-scripting)
//!
//! via std.process and picks up `<output>/declare-tool/bin/<step_name>`.
//! Building from the staged copy keeps the runner byte-consistent with the
//! plugin version the game links, and every artifact lands inside
//! `.labelle/` (never in the user's plugin checkout). The cache dir and
//! install prefix are EXTERNAL to the deps copy on purpose: deps are wiped
//! and re-hardlinked on every generate, so an in-package `zig-out/` would
//! force a from-scratch tool rebuild each time — parked under
//! `<output>/declare-tool/` they survive, and zig's content-keyed cache
//! (hardlinks preserve content) makes the warm re-generate a no-op build.
//! The resulting path is ALSO cached in-process (keyed by the package dir
//! + the row's step, so a lua build never satisfies a ruby lookup), so the
//! tests-target pass in the same process skips even the no-op `zig build`.
//! When the deps copy is missing (deps linking fell back to
//! cache-relative paths) the cache-resolved plugin dir is used instead.
//!
//! This narrow "exec `zig build <step>` inside a staged plugin package at
//! generate time" is deliberately the FIRST SLICE of the generic plugin
//! build hooks (labelle-assembler#586). #586's declarative `.build` block
//! (`plugin_build_steps.zig`) now covers the OTHER flavor — build-time
//! commands whose artifacts link into the game. This generate-time
//! HOST-tool exec stays hardcoded here until a second consumer exists;
//! the documented fold-in path is a `.stage = .generate` variant of the
//! `.build` step schema running with these exact mechanics (cache/prefix
//! outside the wiped deps tree, capability probe, path absolutization) —
//! see the exec-time rationale in plugin_build_steps.zig's module doc.
//!
//! Hermetic-test seam: `declare_tool_override` (below) bypasses the
//! build-and-locate step entirely — the assembler's own suite must not
//! depend on a network fetch of the lua sources or a `zig` on PATH, and
//! an override hook is the right seam for any harness that sandboxes
//! subprocess builds.

const std = @import("std");
const builtin = @import("builtin");
const config = @import("config.zig");
const cache = @import("cache.zig");
const scanner = @import("scanner.zig");
const scan = @import("codegen/scan.zig");
const idents = @import("codegen/idents.zig");
const plugin_manifest = @import("plugin_manifest.zig");

/// The generated file name, written beside `main.zig` in the target dir.
/// The registry block imports it verbatim (`@import("scripting_components.zig")`).
pub const GENERATED_FILENAME = "scripting_components.zig";

/// The generated EVENTS file name (labelle-engine#772), written beside
/// `main.zig` in the target dir. The game-events union block imports it
/// verbatim (`@import("scripting_events.zig")`) — one `pub const
/// <Pascal>` payload struct per declared event.
pub const GENERATED_EVENTS_FILENAME = "scripting_events.zig";

/// One declare-capable language: the plugin-shipped runner that extracts
/// its declarations (each runner IS an interpreter for its language —
/// pointing it at another language's sources would "run" them as the
/// wrong language and fail with a nonsense parse error naming the wrong
/// problem, which is why `runPhase` selects by row and skips non-listed
/// languages cleanly instead). Every runner speaks the SAME schema-JSON
/// contract (`parseSchema` — untouched by widening this table; the
/// cross-runner byte-parity golden in the labelle-scripting repo is the
/// contract proof).
pub const DeclareRunner = struct {
    /// `language_policy.SUPPORTED_LANGUAGES` name the row serves.
    language: []const u8,
    /// The plugin package's `zig build` step AND the installed exe name
    /// (`zig-out`-style prefix layout: `bin/<step_name>`).
    step_name: []const u8,
    /// Package-relative dir whose PRESENCE is the capability probe: an
    /// older pinned plugin simply doesn't ship it, and that must stay a
    /// WORKING project (scripts run, none declare) — never a generate
    /// failure.
    tool_dir: []const u8,
    /// The language's source extension (matches the embed row's — a test
    /// pins the agreement). Informational for diagnostics; collection is
    /// driven by the splice's extension.
    extension: []const u8,
    /// The labelle-scripting release that first shipped the runner — the
    /// absent-tool note's pointed pin hint.
    min_pin: []const u8,
    /// The labelle-scripting release whose declare tool AND runtime
    /// prelude first know `Labelle.event`/`Labelle.id`
    /// (labelle-engine#772). Unlike `min_pin` this floor is enforced as a
    /// hard generate error when `events/*.<ext>` declaration files exist:
    /// the capability probe can't see it (the tool DIR predates it), and
    /// an old runtime prelude would only fail at game BOOT with a
    /// missing-method error — far from the declaration. Local pins (and
    /// non-semver refs) satisfy the floor, exactly like the capability
    /// probes treat them — the tree is the authority there.
    events_min_pin: []const u8,
};

/// FROZEN FALLBACK (RFC-LANGUAGE-PLUGINS rev 17, the Migration bullet).
/// These rows are the declare capability for manifests that PREDATE the
/// `.languages` capability table — resolved pins of releases before
/// labelle-scripting shipped the lua/ruby rows keep working unchanged.
/// When a resolved manifest DOES carry a `.languages` declare row for the
/// language, `runPhase`'s generic path (the #619 dispatch flip) handles it
/// first and this table is never consulted. The table is FROZEN: never
/// extended again — a new language comes via a manifest row, not a row
/// here (the python litmus test). typescript is deliberately absent (no
/// declare tool; its declarations, when they arrive, come as a `.languages`
/// row, not a table entry).
pub const DECLARE_RUNNERS = [_]DeclareRunner{
    .{
        .language = "lua",
        .step_name = "labelle-declare",
        .tool_dir = "tools/declare",
        .extension = ".lua",
        .min_pin = "0.2.0",
        .events_min_pin = "0.10.0",
    },
    .{
        .language = "ruby",
        .step_name = "labelle-declare-ruby",
        .tool_dir = "tools/declare-ruby",
        .extension = ".rb",
        .min_pin = "0.9.0",
        .events_min_pin = "0.10.0",
    },
};

/// The declare runner for `language`, or null when script-declared
/// components aren't supported for it yet (runPhase's pointed skip).
pub fn declareRunner(language: []const u8) ?DeclareRunner {
    for (DECLARE_RUNNERS) |row| {
        if (std.mem.eql(u8, row.language, language)) return row;
    }
    return null;
}

/// Test seam: absolute path of a prebuilt declare tool. When set, the
/// build-and-locate step is skipped entirely and this binary is exec'd
/// over the scripts instead. Same scoped-threadlocal pattern as
/// `main_template.scripting_splice` — tests set it around a `generate`
/// call and clear it after.
pub threadlocal var declare_tool_override: ?[]const u8 = null;

// In-process cache of the last tool built (see the exec-slice doc above):
// the package dir it was built from, the runner STEP it was built for
// (two rows share one package — a lua build must never satisfy a ruby
// lookup), and the resulting binary path. Fixed buffers, not
// allocator-owned — the cache outlives any single generate call's
// allocator (and test allocators must not see it as a leak).
threadlocal var cached_pkg: [std.fs.max_path_bytes]u8 = undefined;
threadlocal var cached_pkg_len: usize = 0;
threadlocal var cached_step: [64]u8 = undefined;
threadlocal var cached_step_len: usize = 0;
threadlocal var cached_tool: [std.fs.max_path_bytes]u8 = undefined;
threadlocal var cached_tool_len: usize = 0;

// ── Schema model (the runner↔assembler contract) ─────────────────────

pub const Persist = enum { persistent, transient };

/// v1 field-type vocabulary. `enum`-typed fields are a known LATER —
/// `parseSchema` rejects them (and any other unknown type string) with a
/// clear error naming the declaration and field. `u64` is scripting
/// v0.10.0's `Labelle.id` marker (labelle-engine#772) — event payloads
/// carry entity ids, and components may use it too.
pub const FieldType = enum { f32, i32, u32, u64, bool, str, vec2, entity };

pub const Vec2Default = struct { x: f64, y: f64 };

/// A field's type + default, carried together: the tag IS the schema
/// "type" and the payload the parsed "default".
pub const Default = union(FieldType) {
    f32: f64,
    i32: i32,
    u32: u32,
    u64: u64,
    bool: bool,
    str: []const u8,
    vec2: Vec2Default,
    entity: u64,
};

pub const DeclaredField = struct {
    name: []const u8,
    default: Default,
};

pub const DeclaredComponent = struct {
    name: []const u8,
    persist: Persist,
    fields: []const DeclaredField,
};

/// One script-declared event (labelle-engine#772): the schema's
/// `"events":[{name, fields}]` row. No persist — events are never saved.
/// `name` is the bus/union-variant name (`hunger__feed`); the generated
/// payload struct is `idents.pathToPascal(name)` (`HungerFeed`) — the
/// SAME transform a Zig `events/hunger__feed.zig` follows by convention.
pub const DeclaredEvent = struct {
    name: []const u8,
    fields: []const DeclaredField,
};

/// A parsed schema. Owns every slice reachable from `components`/`events`
/// via its arena; `deinit` releases the lot.
pub const Schema = struct {
    arena: *std.heap.ArenaAllocator,
    components: []const DeclaredComponent,
    /// Script-declared events (labelle-engine#772). Empty for every
    /// schema without a top-level "events" key — including every schema
    /// a pre-v0.10.0 runner emits.
    events: []const DeclaredEvent,

    pub fn deinit(self: *Schema) void {
        const child = self.arena.child_allocator;
        self.arena.deinit();
        child.destroy(self.arena);
        self.components = &.{};
        self.events = &.{};
    }
};

// ── Diagnostics ──────────────────────────────────────────────────────

/// Print a labelled generate-time diagnostic to stderr (the
/// `main_template` style — NOT `std.log.err`, which the Zig test runner
/// classifies as a test failure even for expected-error cases).
fn diag(comptime fmt: []const u8, args: anytype) void {
    const io = config.globalIo();
    var buf: [1024]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, "labelle-assembler: " ++ fmt ++ "\n", args) catch
        "labelle-assembler: script-declared components: diagnostic too long\n";
    std.Io.File.stderr().writeStreamingAll(io, msg) catch {};
}

/// Relay a child process' stderr (already formatted, file-and-name
/// bearing) to our stderr verbatim.
fn relayChildStderr(text: []const u8) void {
    if (text.len == 0) return;
    const io = config.globalIo();
    std.Io.File.stderr().writeStreamingAll(io, text) catch {};
    if (text[text.len - 1] != '\n')
        std.Io.File.stderr().writeStreamingAll(io, "\n") catch {};
}

/// Print an indented file list under a `diag` headline (the events gates
/// name every offending `events/*.<ext>` file). Best-effort, like `diag`.
fn diagFileList(files: []const []const u8) void {
    const io = config.globalIo();
    for (files) |f| {
        var buf: [512]u8 = undefined;
        const line = std.fmt.bufPrint(&buf, "  {s}\n", .{f}) catch continue;
        std.Io.File.stderr().writeStreamingAll(io, line) catch {};
    }
}

// ── Schema parsing ───────────────────────────────────────────────────

fn isIdentifier(s: []const u8) bool {
    if (s.len == 0) return false;
    // `_` alone is Zig's discard token, not an identifier — `pub const _`
    // and `_: f32` both fail to compile.
    if (s.len == 1 and s[0] == '_') return false;
    for (s, 0..) |ch, i| {
        const ok = ch == '_' or
            (ch >= 'A' and ch <= 'Z') or
            (ch >= 'a' and ch <= 'z') or
            (i != 0 and ch >= '0' and ch <= '9');
        if (!ok) return false;
    }
    return true;
}

/// The generated file spells component and field names as BARE Zig
/// identifiers (`pub const <name> = struct { <field>: T = ..., }`), so a
/// Zig keyword (`error`, `align`, `struct`, …) passes the char-class check
/// above yet renders code that cannot compile in ANY position. The list is
/// the compiler's own tokenizer table, so it can never drift.
fn isZigKeyword(s: []const u8) bool {
    return std.zig.Token.keywords.has(s);
}

/// Primitive type/value names (`type`, `f32`, `u64`, `true`, …) are NOT
/// tokenizer keywords, but a decl spelling one is "name shadows primitive"
/// (breaks a component named `type`) — and they're reserved for FIELDS too,
/// so a declared field name stays spellable as a bare identifier in every
/// generated context, present and future. The compiler's own table again.
fn isZigPrimitive(s: []const u8) bool {
    return std.zig.primitives.isPrimitive(s);
}

/// Member decls EVERY rendered component struct carries (see
/// `renderComponentsFile`) — a field with one of these names would collide
/// with its own struct's generated decl. Events render NO member decls
/// (`renderEventsFile` — no Saveable, events aren't saved), so the check
/// is component-only.
const generated_member_decls = [_][]const u8{"save"};

/// Which declaration kind a shared parse/validation helper is speaking
/// about — the diagnostics name the right kind, and the one
/// component-only rule (`generated_member_decls`) gates on it.
const DeclKind = enum {
    component,
    event,

    fn label(self: DeclKind) []const u8 {
        return switch (self) {
            .component => "component",
            .event => "event",
        };
    }
};

/// Parse + validate one schema JSON document into typed components +
/// events. Validation is deliberately re-done here even though the lua
/// runner already validated: the schema is a CONTRACT — future runners
/// (other languages) feed the same seam, and a generate-time error beats
/// generated code that doesn't compile.
pub fn parseSchema(gpa: std.mem.Allocator, json_text: []const u8) !Schema {
    const arena = try gpa.create(std.heap.ArenaAllocator);
    errdefer gpa.destroy(arena);
    arena.* = std.heap.ArenaAllocator.init(gpa);
    errdefer arena.deinit();
    const a = arena.allocator();

    const trimmed = std.mem.trim(u8, json_text, " \t\r\n");
    const root = std.json.parseFromSliceLeaky(std.json.Value, a, trimmed, .{}) catch {
        diag("script component schema is not valid JSON: {s}", .{truncateForDiag(trimmed)});
        return error.ScriptSchemaInvalid;
    };

    const root_obj = switch (root) {
        .object => |o| o,
        else => {
            diag("script component schema: expected a top-level object", .{});
            return error.ScriptSchemaInvalid;
        },
    };
    const comps_val = root_obj.get("components") orelse {
        diag("script component schema: missing the \"components\" array", .{});
        return error.ScriptSchemaInvalid;
    };
    const comps_arr = switch (comps_val) {
        .array => |arr| arr,
        else => {
            diag("script component schema: \"components\" must be an array", .{});
            return error.ScriptSchemaInvalid;
        },
    };

    var components = try a.alloc(DeclaredComponent, comps_arr.items.len);
    for (comps_arr.items, 0..) |comp_val, i| {
        components[i] = try parseComponent(a, comp_val);
        // Duplicate names would generate two identical registry fields —
        // a confusing downstream compile error; catch them here. O(n²)
        // over a handful of declarations.
        for (components[0..i]) |prev| {
            if (std.mem.eql(u8, prev.name, components[i].name)) {
                diag("script component schema declares '{s}' twice", .{prev.name});
                return error.ScriptSchemaInvalid;
            }
        }
    }

    // Events (labelle-engine#772): the key is emitted ONLY when at least
    // one event was declared — absent means none (every pre-v0.10.0
    // schema). A SEPARATE namespace from components (an event may share a
    // component's name; the two never meet in generated code), so dups
    // are checked per kind only.
    var events: []DeclaredEvent = &.{};
    if (root_obj.get("events")) |events_val| {
        const events_arr = switch (events_val) {
            .array => |arr| arr,
            else => {
                diag("script event schema: \"events\" must be an array", .{});
                return error.ScriptSchemaInvalid;
            },
        };
        events = try a.alloc(DeclaredEvent, events_arr.items.len);
        for (events_arr.items, 0..) |event_val, i| {
            events[i] = try parseEvent(a, event_val);
            // A duplicate would emit two identical union variants. The
            // tool already rejects same-run dups; the schema is a
            // contract, so guard here too.
            for (events[0..i]) |prev| {
                if (std.mem.eql(u8, prev.name, events[i].name)) {
                    diag("script event schema declares '{s}' twice", .{prev.name});
                    return error.ScriptSchemaInvalid;
                }
            }
        }
        try checkEventStructNames(events);
    }

    return .{ .arena = arena, .components = components, .events = events };
}

/// The generated `scripting_events.zig` names each payload struct
/// `pathToPascal(event.name)` — a transform that COLLAPSES underscores,
/// so two distinct event names can fold to one struct (`a__b` and `a_b`
/// both render `pub const AB`). Reject the fold-collisions (and a Pascal
/// that lands on a Zig keyword/primitive or the reserved `Vec2` backing
/// decl) here, where the message can still name both declaration lines.
fn checkEventStructNames(events: []const DeclaredEvent) !void {
    var pascal_buf: [128]u8 = undefined;
    var prev_buf: [128]u8 = undefined;
    for (events, 0..) |ev, i| {
        const pascal = idents.pathToPascal(ev.name, &pascal_buf);
        if (pascal.len == 0) {
            diag("script-declared event '{s}': the name has no alphanumeric characters — the generated payload struct would have no name", .{ev.name});
            return error.ScriptSchemaInvalid;
        }
        if (isZigKeyword(pascal) or isZigPrimitive(pascal)) {
            diag("script-declared event '{s}': the generated payload struct name '{s}' is a Zig keyword or primitive — `pub const {s} = struct` would not compile; pick another name", .{ ev.name, pascal, pascal });
            return error.ScriptSchemaInvalid;
        }
        if (std.mem.eql(u8, pascal, "Vec2")) {
            diag("script-declared event '{s}': the generated payload struct name 'Vec2' is reserved by the generated file (the vec2-field backing struct)", .{ev.name});
            return error.ScriptSchemaInvalid;
        }
        for (events[0..i]) |prev| {
            const prev_pascal = idents.pathToPascal(prev.name, &prev_buf);
            if (std.mem.eql(u8, prev_pascal, pascal)) {
                diag("script-declared events '{s}' and '{s}' both generate the payload struct '{s}' (underscores collapse in the PascalCase transform) — rename one", .{ prev.name, ev.name, pascal });
                return error.ScriptSchemaInvalid;
            }
        }
    }
}

fn parseComponent(a: std.mem.Allocator, val: std.json.Value) !DeclaredComponent {
    const obj = switch (val) {
        .object => |o| o,
        else => {
            diag("script component schema: each components[] entry must be an object", .{});
            return error.ScriptSchemaInvalid;
        },
    };

    const name_val = obj.get("name") orelse {
        diag("script component schema: a component is missing its \"name\"", .{});
        return error.ScriptSchemaInvalid;
    };
    const name = switch (name_val) {
        .string => |s| s,
        else => {
            diag("script component schema: a component \"name\" must be a string", .{});
            return error.ScriptSchemaInvalid;
        },
    };
    if (!isIdentifier(name)) {
        diag("script-declared component '{s}' is not a valid identifier", .{name});
        return error.ScriptSchemaInvalid;
    }
    if (isZigKeyword(name)) {
        diag("script-declared component '{s}': the name is a Zig keyword — the generated `pub const {s} = struct` would not compile; pick another name", .{ name, name });
        return error.ScriptSchemaInvalid;
    }
    if (isZigPrimitive(name)) {
        diag("script-declared component '{s}': the name shadows a Zig primitive — the generated `pub const {s} = struct` would not compile; pick another name", .{ name, name });
        return error.ScriptSchemaInvalid;
    }
    if (std.mem.eql(u8, name, "Vec2")) {
        // The generated file reserves `Vec2` for the vec2-field backing
        // struct (see renderComponentsFile).
        diag("script-declared component name 'Vec2' is reserved by the generated file", .{});
        return error.ScriptSchemaInvalid;
    }

    var persist: Persist = .persistent;
    if (obj.get("persist")) |p_val| {
        const p_str = switch (p_val) {
            .string => |s| s,
            else => {
                diag("script-declared component '{s}': \"persist\" must be a string", .{name});
                return error.ScriptSchemaInvalid;
            },
        };
        persist = std.meta.stringToEnum(Persist, p_str) orelse {
            diag("script-declared component '{s}': unknown persist \"{s}\" (expected \"persistent\" or \"transient\")", .{ name, p_str });
            return error.ScriptSchemaInvalid;
        };
    }

    const fields = try parseFields(a, .component, name, obj);

    return .{
        .name = try a.dupe(u8, name),
        .persist = persist,
        .fields = fields,
    };
}

/// Parse one `events[]` entry (labelle-engine#772). The name lands in
/// TWO generated positions — the bare union variant (`hunger__feed:`)
/// and, PascalCased, the payload struct decl — so it carries the same
/// keyword/primitive gates a component name does. No persist key, no
/// options: events are never saved (the tool enforces it; the schema
/// simply has no field to parse).
fn parseEvent(a: std.mem.Allocator, val: std.json.Value) !DeclaredEvent {
    const obj = switch (val) {
        .object => |o| o,
        else => {
            diag("script event schema: each events[] entry must be an object", .{});
            return error.ScriptSchemaInvalid;
        },
    };

    const name_val = obj.get("name") orelse {
        diag("script event schema: an event is missing its \"name\"", .{});
        return error.ScriptSchemaInvalid;
    };
    const name = switch (name_val) {
        .string => |s| s,
        else => {
            diag("script event schema: an event \"name\" must be a string", .{});
            return error.ScriptSchemaInvalid;
        },
    };
    if (!isIdentifier(name)) {
        diag("script-declared event '{s}' is not a valid identifier", .{name});
        return error.ScriptSchemaInvalid;
    }
    if (isZigKeyword(name)) {
        diag("script-declared event '{s}': the name is a Zig keyword — the generated `{s}: ...` union variant would not compile; pick another name", .{ name, name });
        return error.ScriptSchemaInvalid;
    }
    if (isZigPrimitive(name)) {
        diag("script-declared event '{s}': the name shadows a Zig primitive — reserved so the union variant and hook handler names stay spellable bare; pick another name", .{name});
        return error.ScriptSchemaInvalid;
    }

    const fields = try parseFields(a, .event, name, obj);

    return .{
        .name = try a.dupe(u8, name),
        .fields = fields,
    };
}

/// The shared `"fields"` walk — components and events carry the same
/// {name, type, default} rows (one vocabulary, one validation matrix);
/// only the diagnostics' kind label and the component-only
/// `generated_member_decls` rule differ.
fn parseFields(a: std.mem.Allocator, kind: DeclKind, owner: []const u8, obj: std.json.ObjectMap) ![]DeclaredField {
    var fields: []DeclaredField = &.{};
    if (obj.get("fields")) |f_val| {
        const f_arr = switch (f_val) {
            .array => |arr| arr,
            else => {
                diag("script-declared {s} '{s}': \"fields\" must be an array", .{ kind.label(), owner });
                return error.ScriptSchemaInvalid;
            },
        };
        fields = try a.alloc(DeclaredField, f_arr.items.len);
        for (f_arr.items, 0..) |field_val, i| {
            fields[i] = try parseField(a, kind, owner, field_val);
            for (fields[0..i]) |prev| {
                if (std.mem.eql(u8, prev.name, fields[i].name)) {
                    diag("script-declared {s} '{s}' declares field '{s}' twice", .{ kind.label(), owner, prev.name });
                    return error.ScriptSchemaInvalid;
                }
            }
        }
    }
    return fields;
}

fn parseField(a: std.mem.Allocator, kind: DeclKind, owner: []const u8, val: std.json.Value) !DeclaredField {
    const obj = switch (val) {
        .object => |o| o,
        else => {
            diag("script-declared {s} '{s}': each fields[] entry must be an object", .{ kind.label(), owner });
            return error.ScriptSchemaInvalid;
        },
    };
    const name = switch (obj.get("name") orelse .null) {
        .string => |s| s,
        else => {
            diag("script-declared {s} '{s}': a field is missing its \"name\" string", .{ kind.label(), owner });
            return error.ScriptSchemaInvalid;
        },
    };
    if (!isIdentifier(name)) {
        diag("script-declared {s} '{s}' field '{s}' is not a valid identifier", .{ kind.label(), owner, name });
        return error.ScriptSchemaInvalid;
    }
    if (isZigKeyword(name)) {
        diag("script-declared {s} '{s}' field '{s}': the name is a Zig keyword — the generated `{s}: <type> = ...` field would not compile; pick another name", .{ kind.label(), owner, name, name });
        return error.ScriptSchemaInvalid;
    }
    if (isZigPrimitive(name)) {
        diag("script-declared {s} '{s}' field '{s}': the name is a Zig primitive type/value name — reserved so generated code can always spell the field bare; pick another name", .{ kind.label(), owner, name });
        return error.ScriptSchemaInvalid;
    }
    if (kind == .component) {
        // Component-only: events render NO member decls (no Saveable —
        // events are never saved), so an event field may spell `save`.
        for (generated_member_decls) |decl| {
            if (std.mem.eql(u8, name, decl)) {
                diag("script-declared component '{s}' field '{s}': the name collides with the `{s}` decl every generated component struct carries — pick another name", .{ owner, name, decl });
                return error.ScriptSchemaInvalid;
            }
        }
    }
    const type_str = switch (obj.get("type") orelse .null) {
        .string => |s| s,
        else => {
            diag("script-declared {s} '{s}' field '{s}': missing \"type\" string", .{ kind.label(), owner, name });
            return error.ScriptSchemaInvalid;
        },
    };
    const field_type = std.meta.stringToEnum(FieldType, type_str) orelse {
        if (std.mem.eql(u8, type_str, "enum")) {
            diag("script-declared {s} '{s}' field '{s}': enum fields are not supported yet (schema v1 types: f32 i32 u32 u64 bool str vec2 entity)", .{ kind.label(), owner, name });
        } else {
            diag("script-declared {s} '{s}' field '{s}': unknown type \"{s}\" (schema v1 types: f32 i32 u32 u64 bool str vec2 entity)", .{ kind.label(), owner, name, type_str });
        }
        return error.ScriptSchemaInvalid;
    };
    const default_val = obj.get("default") orelse {
        diag("script-declared {s} '{s}' field '{s}': missing \"default\"", .{ kind.label(), owner, name });
        return error.ScriptSchemaInvalid;
    };

    const default: Default = switch (field_type) {
        .f32 => .{ .f32 = try expectF32(kind, owner, name, default_val) },
        .i32 => .{ .i32 = std.math.cast(i32, try expectInteger(kind, owner, name, default_val)) orelse
            return failRange(kind, owner, name, "i32") },
        .u32 => .{ .u32 = std.math.cast(u32, try expectInteger(kind, owner, name, default_val)) orelse
            return failRange(kind, owner, name, "u32") },
        // `Labelle.id` (scripting v0.10.0, labelle-engine#772) — the
        // entity-id marker classifies as {"type":"u64","default":0} in
        // components AND events.
        .u64 => .{ .u64 = std.math.cast(u64, try expectInteger(kind, owner, name, default_val)) orelse
            return failRange(kind, owner, name, "u64") },
        .bool => switch (default_val) {
            .bool => |b| .{ .bool = b },
            else => {
                diag("script-declared {s} '{s}' field '{s}': bool default must be true/false", .{ kind.label(), owner, name });
                return error.ScriptSchemaInvalid;
            },
        },
        .str => switch (default_val) {
            .string => |s| .{ .str = try a.dupe(u8, s) },
            else => {
                diag("script-declared {s} '{s}' field '{s}': str default must be a string", .{ kind.label(), owner, name });
                return error.ScriptSchemaInvalid;
            },
        },
        .vec2 => switch (default_val) {
            .object => |vo| blk: {
                if (vo.count() != 2) return failVec2(kind, owner, name);
                const x = vo.get("x") orelse return failVec2(kind, owner, name);
                const y = vo.get("y") orelse return failVec2(kind, owner, name);
                break :blk .{ .vec2 = .{
                    .x = try expectF32(kind, owner, name, x),
                    .y = try expectF32(kind, owner, name, y),
                } };
            },
            else => return failVec2(kind, owner, name),
        },
        .entity => .{ .entity = std.math.cast(u64, try expectInteger(kind, owner, name, default_val)) orelse
            return failRange(kind, owner, name, "entity (u64)") },
    };

    return .{ .name = try a.dupe(u8, name), .default = default };
}

fn expectNumber(kind: DeclKind, owner: []const u8, field_name: []const u8, val: std.json.Value) !f64 {
    return switch (val) {
        .integer => |n| @floatFromInt(n),
        .float => |f| f,
        else => {
            diag("script-declared {s} '{s}' field '{s}': default must be a number", .{ kind.label(), owner, field_name });
            return error.ScriptSchemaInvalid;
        },
    };
}

/// Largest finite magnitude an f32 default may carry — the declare TOOL's
/// own gate mirrored with the identical constant (labelle-scripting#5,
/// `F32_MAX` in declare_prelude.lua; its golden pins that 3.4e38 passes).
const f32_max: f64 = 3.4028235e38;

/// `expectNumber` + the f32 range gate for `f32` fields and `vec2` axes:
/// the schema carries f64, so a runner emitting `1e100` would otherwise
/// pass validation and only fail LATER, as a compile error on the
/// generated `level: f32 = 1e100` — far from the declaration. Finite-only
/// (non-finite handling is unchanged; the tool rejects nan/inf on its
/// side), so the beyond-max check mirrors the tool's semantics exactly.
fn expectF32(kind: DeclKind, owner: []const u8, field_name: []const u8, val: std.json.Value) !f64 {
    const v = try expectNumber(kind, owner, field_name, val);
    if (std.math.isFinite(v) and @abs(v) > f32_max) {
        diag("script-declared {s} '{s}' field '{s}': default {e} is outside f32 range (magnitude must not exceed 3.4028235e38)", .{ kind.label(), owner, field_name, v });
        return error.ScriptSchemaInvalid;
    }
    return v;
}

fn expectInteger(kind: DeclKind, owner: []const u8, field_name: []const u8, val: std.json.Value) !i64 {
    return switch (val) {
        .integer => |n| n,
        else => {
            diag("script-declared {s} '{s}' field '{s}': default must be an integer", .{ kind.label(), owner, field_name });
            return error.ScriptSchemaInvalid;
        },
    };
}

fn failRange(kind: DeclKind, owner: []const u8, field_name: []const u8, comptime what: []const u8) error{ScriptSchemaInvalid} {
    diag("script-declared {s} '{s}' field '{s}': default out of " ++ what ++ " range", .{ kind.label(), owner, field_name });
    return error.ScriptSchemaInvalid;
}

fn failVec2(kind: DeclKind, owner: []const u8, field_name: []const u8) error{ScriptSchemaInvalid} {
    diag("script-declared {s} '{s}' field '{s}': vec2 default must be {{\"x\":<number>,\"y\":<number>}}", .{ kind.label(), owner, field_name });
    return error.ScriptSchemaInvalid;
}

fn truncateForDiag(s: []const u8) []const u8 {
    const cap = 200;
    return if (s.len <= cap) s else s[0..cap];
}

// ── Codegen: schema → scripting_components.zig ───────────────────────

/// The save-policy enum literal `renderComponentsFile` writes into the
/// generated `Saveable(.<policy>, …)` decl — persistent→`saveable` (core
/// has no `.persistent`), transient→`transient`. Public so the manifest
/// sidecar reports the SAME policy codegen emits.
pub fn savePolicyName(p: Persist) []const u8 {
    return switch (p) {
        .persistent => "saveable",
        .transient => "transient",
    };
}

/// The Zig type `renderComponentsFile` writes for a field — public so the
/// manifest sidecar reports the SAME field types codegen emits (`str` is
/// the slice type, `vec2` the generated-file-local backing struct,
/// `entity` the core Stored idiom's u64 id).
pub fn zigFieldTypeName(default: Default) []const u8 {
    return switch (default) {
        .f32 => "f32",
        .i32 => "i32",
        .u32 => "u32",
        .u64 => "u64",
        .bool => "bool",
        .str => "[]const u8",
        .vec2 => "Vec2",
        .entity => "u64",
    };
}

/// Render the generated `scripting_components.zig` for `components`.
/// Each struct copies the canonical hand-written component shape (the
/// `examples/packs-demo` pack components / `labelle add feature`
/// scaffold): a `pub const save = @import("labelle-core").Saveable(...)`
/// decl plus defaulted fields. Persist maps persistent→`.saveable`,
/// transient→`.transient`. `entity` fields are the core `Stored` idiom —
/// a `u64` id field listed in the Saveable's `.entity_refs`, so save/load
/// remaps them like any hand-written ref.
pub fn renderComponentsFile(components: []const DeclaredComponent, w: anytype) !void {
    try w.writeAll(
        \\//! Script-declared components (labelle-assembler#585,
        \\//! RFC-LANGUAGE-PLUGINS). GENERATED from the declare-mode schema —
        \\//! do not edit; change the `labelle.component(...)` declarations in
        \\//! the game's scripts instead. Each struct is registered into the
        \\//! game's component registry under its declared name, so scenes,
        \\//! prefabs, save buckets, typed queries and the script contract's
        \\//! by-name dispatch all reach it like any components/*.zig file.
        \\
        \\
    );

    var any_vec2 = false;
    for (components) |comp| {
        for (comp.fields) |field| {
            if (field.default == .vec2) any_vec2 = true;
        }
    }
    if (any_vec2) {
        try w.writeAll(
            \\/// Plain {x,y} pair backing `vec2` schema fields (no core Vec2
            \\/// export exists; serde reflects nested structs fine).
            \\pub const Vec2 = struct { x: f32 = 0, y: f32 = 0 };
            \\
            \\
        );
    }

    for (components) |comp| {
        try w.print("pub const {s} = struct {{\n", .{comp.name});

        const policy = savePolicyName(comp.persist);
        var entity_ref_count: usize = 0;
        for (comp.fields) |field| {
            if (field.default == .entity) entity_ref_count += 1;
        }
        if (entity_ref_count == 0) {
            try w.print("    pub const save = @import(\"labelle-core\").Saveable(.{s}, @This(), .{{}});\n", .{policy});
        } else {
            try w.print("    pub const save = @import(\"labelle-core\").Saveable(.{s}, @This(), .{{\n", .{policy});
            try w.writeAll("        .entity_refs = &.{");
            var emitted: usize = 0;
            for (comp.fields) |field| {
                if (field.default != .entity) continue;
                if (emitted > 0) try w.writeAll(", ");
                try w.print("\"{s}\"", .{field.name});
                emitted += 1;
            }
            try w.writeAll("},\n    });\n");
        }

        if (comp.fields.len > 0) try w.writeAll("\n");
        for (comp.fields) |field| {
            try writeFieldLine(w, field);
        }
        try w.writeAll("};\n\n");
    }
}

/// One defaulted struct-field line (`    level: f32 = 0.875,\n`) — shared
/// between `renderComponentsFile` and `renderEventsFile` so the two
/// generated files can never drift on the type/default spelling.
fn writeFieldLine(w: anytype, field: DeclaredField) !void {
    try w.print("    {s}: {s} = ", .{ field.name, zigFieldTypeName(field.default) });
    switch (field.default) {
        .f32 => |v| try w.print("{d}", .{v}),
        .i32 => |v| try w.print("{d}", .{v}),
        .u32 => |v| try w.print("{d}", .{v}),
        .u64 => |v| try w.print("{d}", .{v}),
        .bool => |v| try w.print("{}", .{v}),
        .str => |v| try w.print("\"{f}\"", .{std.zig.fmtString(v)}),
        .vec2 => |v| try w.print(".{{ .x = {d}, .y = {d} }}", .{ v.x, v.y }),
        .entity => |v| try w.print("{d}", .{v}),
    }
    try w.writeAll(",\n");
}

/// Render the generated `scripting_events.zig` for `events`
/// (labelle-engine#772): one plain payload struct per declared event,
/// named `pathToPascal(event.name)` — the shape an authored
/// `events/<name>.zig` carries by convention (see the ruby example's
/// `events/hunger__feed.zig`). NO `Saveable` decl and no options: events
/// are never saved. The game-events union block references each as
/// `@import("scripting_events.zig").<Pascal>`.
pub fn renderEventsFile(events: []const DeclaredEvent, w: anytype) !void {
    try w.writeAll(
        \\//! Script-declared events (labelle-engine#772,
        \\//! RFC-LANGUAGE-PLUGINS). GENERATED from the declare-mode schema —
        \\//! do not edit; change the `Labelle.event(...)` declarations in the
        \\//! game's events/*.<ext> files instead. Each struct backs one
        \\//! GameEvents union variant exactly like an events/*.zig payload:
        \\//! scripts reach it by name through emit/on, native hooks through a
        \\//! method named after the variant (spell the payload parameter
        \\//! `anytype` — this file only exists in the generated tree).
        \\
        \\
    );

    var any_vec2 = false;
    for (events) |ev| {
        for (ev.fields) |field| {
            if (field.default == .vec2) any_vec2 = true;
        }
    }
    if (any_vec2) {
        try w.writeAll(
            \\/// Plain {x,y} pair backing `vec2` schema fields (no core Vec2
            \\/// export exists; the bus JSON bridge reflects nested structs fine).
            \\pub const Vec2 = struct { x: f32 = 0, y: f32 = 0 };
            \\
            \\
        );
    }

    var pascal_buf: [128]u8 = undefined;
    for (events) |ev| {
        const pascal = idents.pathToPascal(ev.name, &pascal_buf);
        if (ev.fields.len == 0) {
            // Payloadless event — the `pub const WaveSpawned = struct {};`
            // one-liner zig fmt itself writes for an empty struct.
            try w.print("pub const {s} = struct {{}};\n\n", .{pascal});
            continue;
        }
        try w.print("pub const {s} = struct {{\n", .{pascal});
        for (ev.fields) |field| {
            try writeFieldLine(w, field);
        }
        try w.writeAll("};\n\n");
    }
}

// ── Collision gate ───────────────────────────────────────────────────

/// Reject a declared component whose registry name is already taken —
/// by the built-in `VideoComponent`, a game `components/*.zig`, or a
/// pack's namespaced `<pack>__<Pascal>` field. The error names BOTH
/// providers so the author knows which line to change. (Names come from
/// the same derivations `writeComponentRegistryBlock` emits, so the check
/// matches the generated field set exactly.)
pub fn checkCollisions(
    declared: []const DeclaredComponent,
    component_names: []const []const u8,
    pack_scans: []const scan.PackScan,
) !void {
    var pascal_buf: [128]u8 = undefined;
    var pack_pascal_buf: [128]u8 = undefined;
    var prefix_buf: [128]u8 = undefined;

    for (declared) |comp| {
        if (std.mem.eql(u8, comp.name, "VideoComponent")) {
            diag("script-declared component 'VideoComponent' collides with the built-in engine VideoComponent — pick another name", .{});
            return error.ScriptComponentCollision;
        }
        for (component_names) |name| {
            const pascal = idents.pathToPascal(name, &pascal_buf);
            if (std.mem.eql(u8, pascal, comp.name)) {
                diag("script-declared component '{s}' collides with the game component components/{s}.zig — rename one (script declarations and components/ share one registry namespace)", .{ comp.name, name });
                return error.ScriptComponentCollision;
            }
        }
        for (pack_scans) |pack| {
            // Slice-wise `<pack>__<Pascal>` match — never a formatted
            // copy into a fixed buffer whose overflow would skip the
            // comparison (PR #618 review; the sibling event check hit
            // that for real — see `checkEventCollisions`). The pack
            // prefix + `__` split depends only on the pack, so it hoists
            // out of the per-name loop.
            const prefix = scan.packNamespacePrefix(pack.name, &prefix_buf);
            if (!std.mem.startsWith(u8, comp.name, prefix)) continue;
            const rest = comp.name[prefix.len..];
            if (!std.mem.startsWith(u8, rest, "__")) continue;
            const bare = rest[2..];
            for (pack.component_names) |name| {
                if (std.mem.eql(u8, bare, idents.pathToPascal(name, &pack_pascal_buf))) {
                    diag("script-declared component '{s}' collides with pack '{s}' component {s}.zig — rename one", .{ comp.name, pack.name, name });
                    return error.ScriptComponentCollision;
                }
            }
        }
    }
}

/// Reject a declared EVENT whose GameEvents union variant is already
/// taken — by a game `events/*.zig` (whose variant is the file BASENAME,
/// `idents.eventVariantName`) or a pack's namespaced `<pack>__<ident>`
/// variant. The error names BOTH providers, mirroring `checkCollisions`.
/// Components are a SEPARATE namespace (a `Hunger` component and a
/// `hunger` event coexist — the ticket's contract), so they don't gate
/// here. Names come from the same derivations the game-events block
/// emits (`writeGameEventsBlock` / `writePackEventVariants`), so the
/// check matches the generated variant set exactly.
pub fn checkEventCollisions(
    declared: []const DeclaredEvent,
    event_names: []const []const u8,
    pack_scans: []const scan.PackScan,
) !void {
    var prefix_buf: [128]u8 = undefined;

    for (declared) |ev| {
        for (event_names) |stem| {
            if (std.mem.eql(u8, idents.eventVariantName(stem), ev.name)) {
                diag("script-declared event '{s}' collides with the game event events/{s}.zig — rename one (script declarations and events/ share one bus namespace)", .{ ev.name, stem });
                return error.ScriptEventCollision;
            }
        }
        for (pack_scans) |pack| {
            // Slice-wise `<pack>__<variant>` match, mirroring the pack
            // loop in `checkCollisions`. The old format-then-compare
            // (`bufPrint` into a fixed 280-byte buffer, `catch continue`)
            // silently SKIPPED the check when the joined name overflowed —
            // reachable here because `eventVariantName` is a slice of the
            // stem (unbounded), unlike the 128-capped Pascal/prefix
            // transforms (PR #618 review).
            const prefix = scan.packNamespacePrefix(pack.name, &prefix_buf);
            if (!std.mem.startsWith(u8, ev.name, prefix)) continue;
            const rest = ev.name[prefix.len..];
            if (!std.mem.startsWith(u8, rest, "__")) continue;
            const bare = rest[2..];
            for (pack.event_names) |stem| {
                if (std.mem.eql(u8, bare, idents.eventVariantName(stem))) {
                    diag("script-declared event '{s}' collides with pack '{s}' event {s}.zig — rename one", .{ ev.name, pack.name, stem });
                    return error.ScriptEventCollision;
                }
            }
        }
    }
}

/// Reject a declared EVENT whose name spells a PLUGIN event's qualified
/// union tag (`<plugin_sanitized>__<event>` — `writePluginEventsBlock`'s
/// variant shape; the engine's own `Events` decls arrive in the same list
/// under the `engine` prefix). Plugin `Events` discovery
/// (`discoverPluginEvents`) runs AFTER the declare phase, so this gate
/// can't sit inside `runPhase` beside `checkEventCollisions` — root.zig
/// calls it right after discovery instead. Without it, a declared
/// `box2d__collision_begin` only explodes later inside the generated
/// main.zig's `MergeHookPayloads` comptime duplicate-field check — a
/// terrible error for a user mistake. Same slice-wise compare as the
/// pack gates above: no fixed-size format buffer, no silent skip.
pub fn checkEventPluginCollisions(
    declared: []const DeclaredEvent,
    plugin_events: []const scan.PluginEvent,
) !void {
    for (declared) |ev| {
        for (plugin_events) |pe| {
            if (!std.mem.startsWith(u8, ev.name, pe.plugin_sanitized)) continue;
            const rest = ev.name[pe.plugin_sanitized.len..];
            if (!std.mem.startsWith(u8, rest, "__")) continue;
            if (!std.mem.eql(u8, rest[2..], pe.event_name)) continue;
            diag("script-declared event '{s}' collides with plugin '{s}' event {s} — rename the declaration (plugin events already own the '{s}__' prefix)", .{ ev.name, pe.plugin_import_name, pe.event_name, pe.plugin_sanitized });
            return error.ScriptEventPluginCollision;
        }
    }
}

/// Reject a Zig GAME event (`events/*.zig`, variant name
/// `idents.eventVariantName(stem)`) or PACK event (variant name
/// `<pack>__<ident>`) whose generated union variant spells a PLUGIN
/// event's qualified tag (`<plugin_sanitized>__<event>`). Pre-#630 this
/// collision ALWAYS reached `MergeHookPayloads`' comptime
/// duplicate-field check because every discovered plugin event was
/// folded unconditionally; with consumption filtering (#630) an
/// UNREFERENCED plugin entry is elided first, the duplicate silently
/// vanishes, and the plugin's `@hasField(GameEvents, tag)` emit gate
/// turns ON against the game's same-named payload — the wrong payload
/// type, or a confusing missing-field compile error at the emit helper,
/// instead of a namespace-collision diagnostic. Narrow corner: any REAL
/// consumer of the colliding tag keeps the plugin entry and restores
/// the old loud comptime error — this gate closes the
/// dead-declaration case too, with the declare-phase's pointed voice.
/// root.zig calls it beside `checkEventPluginCollisions`, BEFORE the
/// filter, on the FULL discovery list (collision behavior must be
/// consumption-independent).
pub fn checkGameEventPluginCollisions(
    event_names: []const []const u8,
    pack_scans: []const scan.PackScan,
    plugin_events: []const scan.PluginEvent,
) !void {
    var prefix_buf: [128]u8 = undefined;
    for (plugin_events) |pe| {
        for (event_names) |stem| {
            // The game variant is a single materialized string — peel
            // the plugin prefix slice-wise, same pattern as the gates
            // above (no format buffer, no silent skip).
            const variant = idents.eventVariantName(stem);
            if (!std.mem.startsWith(u8, variant, pe.plugin_sanitized)) continue;
            const rest = variant[pe.plugin_sanitized.len..];
            if (!std.mem.startsWith(u8, rest, "__")) continue;
            if (!std.mem.eql(u8, rest[2..], pe.event_name)) continue;
            diag("game event events/{s}.zig collides with plugin '{s}' event {s} — rename the event file (plugin events already own the '{s}__' prefix)", .{ stem, pe.plugin_import_name, pe.event_name, pe.plugin_sanitized });
            return error.GameEventPluginCollision;
        }
        for (pack_scans) |pack| {
            const prefix = scan.packNamespacePrefix(pack.name, &prefix_buf);
            for (pack.event_names) |stem| {
                // Neither side is materialized here (`<prefix>__<ident>`
                // vs `<sanitized>__<event>`), and a naive component-wise
                // compare would miss `__`-misaligned equal joins — use
                // the virtual-concatenation comparator so the check
                // matches exactly what `MergeHookPayloads` would see.
                if (!qualifiedTagEql(prefix, idents.eventVariantName(stem), pe.plugin_sanitized, pe.event_name)) continue;
                diag("pack '{s}' event {s}.zig collides with plugin '{s}' event {s} — rename one (plugin events already own the '{s}__' prefix)", .{ pack.name, stem, pe.plugin_import_name, pe.event_name, pe.plugin_sanitized });
                return error.GameEventPluginCollision;
            }
        }
    }
}

/// Reject two DISCOVERED plugin events that produce the SAME qualified
/// union tag — two providers whose sanitized names collide (`foo-bar` +
/// `foo_bar`, both declaring `hit`, → `foo_bar__hit` twice). Pre-#630
/// both entries always reached the emitted union and Zig rejected the
/// duplicate field loudly at the decl; with consumption filtering a
/// source naming only ONE dotted form (`foo-bar.hit`) keeps one entry
/// and elides the other — no duplicate, no error, and the elided
/// plugin's `@hasField` emit gate turns ON against the kept plugin's
/// payload. root.zig runs this on the FULL discovery list BEFORE the
/// filter, in EVERY mode (`.all` included — the pointed diagnostic is
/// strictly better than the raw duplicate-field compile error it
/// replaces). Same virtual-concatenation comparator as the game-event
/// gate, so `__`-misaligned equal joins (`foo` + `bar__hit` vs
/// `foo__bar` + `hit`) are caught too.
pub fn checkDuplicatePluginTags(plugin_events: []const scan.PluginEvent) !void {
    for (plugin_events, 0..) |a, i| {
        for (plugin_events[i + 1 ..]) |b| {
            if (!qualifiedTagEql(a.plugin_sanitized, a.event_name, b.plugin_sanitized, b.event_name)) continue;
            diag("plugins '{s}' and '{s}' both produce event tag '{s}__{s}' — rename one; sanitized plugin names must be unique", .{ a.plugin_import_name, b.plugin_import_name, a.plugin_sanitized, a.event_name });
            return error.DuplicatePluginEventTag;
        }
    }
}

/// `a_prefix ++ "__" ++ a_name == b_prefix ++ "__" ++ b_name`, computed
/// over the VIRTUAL concatenations — no allocation, no fixed-size
/// format buffer (the silent-skip-on-overflow trap PR #618 flagged),
/// and exact even when a `__` inside one side's prefix aligns the join
/// differently (`a` + `b__c` vs `a__b` + `c` both spell `a__b__c`).
fn qualifiedTagEql(
    a_prefix: []const u8,
    a_name: []const u8,
    b_prefix: []const u8,
    b_name: []const u8,
) bool {
    const total = a_prefix.len + 2 + a_name.len;
    if (total != b_prefix.len + 2 + b_name.len) return false;
    var i: usize = 0;
    while (i < total) : (i += 1) {
        if (joinedAt(a_prefix, a_name, i) != joinedAt(b_prefix, b_name, i)) return false;
    }
    return true;
}

/// Byte `i` of the virtual string `prefix ++ "__" ++ name`.
fn joinedAt(prefix: []const u8, name: []const u8, i: usize) u8 {
    if (i < prefix.len) return prefix[i];
    if (i < prefix.len + 2) return '_';
    return name[i - prefix.len - 2];
}

// ── The exec slice ───────────────────────────────────────────────────

/// The three paths the tool build uses — the install prefix, its zig
/// cache, and the resulting binary — all ABSOLUTE.
///
/// Absolutized against OUR cwd (PR #598 finding 1) because the `zig build`
/// child runs with cwd = the plugin package: with a relative `output_dir`
/// (the common `--project-root .` CLI shape builds `./.labelle`) the child
/// would resolve `--cache-dir`/`--prefix` relative to the package —
/// installing the tool inside the staged, wiped-per-generate deps copy —
/// while our own post-build `dirExists(tool_path)` check resolves the same
/// spelling against OUR cwd, so the build "succeeds" yet the tool is never
/// found (DeclareToolBuildFailed, only for relative project roots).
/// `output_dir` always exists by the time the declare phase runs (deps
/// were staged under it), so realpath is available; the absolute
/// `tool_path` also keeps the in-process cache and the later exec
/// cwd-independent.
const ToolPaths = struct {
    prefix: []const u8,
    zig_cache: []const u8,
    tool_path: []const u8,

    fn deinit(self: ToolPaths, allocator: std.mem.Allocator) void {
        allocator.free(self.prefix);
        allocator.free(self.zig_cache);
        allocator.free(self.tool_path);
    }
};

fn declareToolPaths(allocator: std.mem.Allocator, output_dir: []const u8, runner: DeclareRunner) !ToolPaths {
    const output_abs = try std.Io.Dir.cwd().realPathFileAlloc(config.globalIo(), output_dir, allocator);
    defer allocator.free(output_abs);
    const prefix = try std.fs.path.join(allocator, &.{ output_abs, "declare-tool" });
    errdefer allocator.free(prefix);
    const zig_cache = try std.fs.path.join(allocator, &.{ prefix, "zig-cache" });
    errdefer allocator.free(zig_cache);
    var exe_buf: [96]u8 = undefined;
    const exe_name = if (builtin.os.tag == .windows)
        std.fmt.bufPrint(&exe_buf, "{s}.exe", .{runner.step_name}) catch return error.NameTooLong
    else
        runner.step_name;
    const tool_path = try std.fs.path.join(allocator, &.{ prefix, "bin", exe_name });
    return .{ .prefix = prefix, .zig_cache = zig_cache, .tool_path = tool_path };
}

/// Resolve (building if needed) `runner`'s declare tool for the scripting
/// plugin package at `pkg_dir`, installing under `<output_dir>/declare-tool/`
/// (one shared prefix — the per-row exes coexist by name). Returns a path
/// valid for the rest of the process (override, or the threadlocal cache
/// buffer). See the module doc's exec-slice section for the build+cache
/// mechanics.
fn ensureDeclareTool(allocator: std.mem.Allocator, pkg_dir: []const u8, output_dir: []const u8, runner: DeclareRunner) ![]const u8 {
    if (declare_tool_override) |p| return p;

    // Capability probe, per row. The runner lives in the plugin package's
    // `runner.tool_dir` (labelle-scripting ships `tools/declare` from
    // v0.2.0, `tools/declare-ruby` from v0.9.0 — each in `.paths`); an
    // older pinned plugin simply doesn't ship the row's dir — and that
    // must stay a WORKING project (scripts run, none declare), not a
    // generate failure, or upgrading the assembler breaks every existing
    // scripting pin. runPhase turns this error into a note + phase skip.
    //
    // A RELATIVE `pkg_dir` is fine here (unlike `output_dir` below): the
    // probe and the spawn's `.cwd` are both resolved against OUR cwd, so
    // every consumer of the spelling agrees. (`tool_dir` keeps its `/` on
    // Windows — the `CONTRACT_DTS_REL` precedent in the transpile phase.)
    const marker = try std.fs.path.join(allocator, &.{ pkg_dir, runner.tool_dir });
    defer allocator.free(marker);
    if (!cache.dirExists(marker)) return error.DeclareToolAbsent;

    if (cached_tool_len > 0 and
        std.mem.eql(u8, cached_pkg[0..cached_pkg_len], pkg_dir) and
        std.mem.eql(u8, cached_step[0..cached_step_len], runner.step_name) and
        cache.dirExists(cached_tool[0..cached_tool_len]))
    {
        return cached_tool[0..cached_tool_len];
    }

    // Cache dir + install prefix OUTSIDE the (wiped-per-generate) deps
    // copy — this is what makes re-generates warm; see the module doc.
    // Absolute (never output_dir-relative): the child's cwd is `pkg_dir`,
    // not ours — see `declareToolPaths`.
    const paths = declareToolPaths(allocator, output_dir, runner) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            diag("could not resolve the declare-tool install dir under {s}: {s}", .{ output_dir, @errorName(err) });
            return error.DeclareToolBuildFailed;
        },
    };
    defer paths.deinit(allocator);

    const io = config.globalIo();
    const result = std.process.run(allocator, io, .{
        .argv = &.{ "zig", "build", runner.step_name, "--cache-dir", paths.zig_cache, "--prefix", paths.prefix },
        .cwd = .{ .path = pkg_dir },
    }) catch |err| {
        diag("could not run `zig build {s}` in {s}: {s}", .{ runner.step_name, pkg_dir, @errorName(err) });
        return error.DeclareToolBuildFailed;
    };
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    switch (result.term) {
        .exited => |code| if (code != 0) {
            relayChildStderr(result.stderr);
            diag("`zig build {s}` failed (exit {d}) in {s}", .{ runner.step_name, code, pkg_dir });
            return error.DeclareToolBuildFailed;
        },
        else => {
            relayChildStderr(result.stderr);
            diag("`zig build {s}` terminated abnormally in {s}", .{ runner.step_name, pkg_dir });
            return error.DeclareToolBuildFailed;
        },
    }

    if (!cache.dirExists(paths.tool_path)) {
        diag("`zig build {s}` succeeded but {s} is missing", .{ runner.step_name, paths.tool_path });
        return error.DeclareToolBuildFailed;
    }
    if (pkg_dir.len > cached_pkg.len or paths.tool_path.len > cached_tool.len or runner.step_name.len > cached_step.len)
        return error.NameTooLong;
    @memcpy(cached_pkg[0..pkg_dir.len], pkg_dir);
    cached_pkg_len = pkg_dir.len;
    @memcpy(cached_step[0..runner.step_name.len], runner.step_name);
    cached_step_len = runner.step_name.len;
    @memcpy(cached_tool[0..paths.tool_path.len], paths.tool_path);
    cached_tool_len = paths.tool_path.len;
    return cached_tool[0..cached_tool_len];
}

/// Locate the scripting plugin package to build the tool from: the staged
/// `<output>/deps/labelle-<name>/` copy (the exact package the game
/// builds against), falling back to the cache/local resolution when deps
/// staging fell back. Caller frees. Pub: the transpile phase
/// (`scripting_transpile.zig`) resolves the SAME plugin package to read
/// its shipped `contract/labelle.d.ts` — one resolution, no drift.
pub fn resolvePluginPackageDir(
    allocator: std.mem.Allocator,
    plugins: []const config.PluginDep,
    plugin_name: []const u8,
    output_dir: []const u8,
    project_dir: []const u8,
) ![]const u8 {
    var link_buf: [256]u8 = undefined;
    const link_name = std.fmt.bufPrint(&link_buf, "labelle-{s}", .{plugin_name}) catch
        return error.NameTooLong;
    const staged = try std.fs.path.join(allocator, &.{ output_dir, "deps", link_name });
    if (cache.dirExists(staged)) return staged;
    allocator.free(staged);

    for (plugins) |plugin| {
        if (std.mem.eql(u8, plugin.name, plugin_name))
            return cache.resolvePlugin(allocator, plugin, project_dir);
    }
    diag("scripting plugin '{s}' not found among the project's plugins", .{plugin_name});
    return error.DeclareToolBuildFailed;
}

/// Exec the declare tool over the collected language sources and parse
/// its stdout as the schema. A nonzero exit relays the tool's stderr (the
/// file-and-name-bearing declaration error) and fails generation.
///
/// `script_files` are the collection's TARGET-RELATIVE paths (the
/// `EmbedScript.file` column — `components/hunger.rb` declarations first,
/// then the script dir's files); the argv joins `target_dir/<file>`
/// directly, so ordering-prefix stripping in the registered stems never
/// desyncs the tool's input. The runner handles multi-file input and
/// duplicate detection with first-declared-in attribution — BOTH sources
/// feed one schema.
///
/// Relative-path audit (PR #598 finding 1): unlike the tool BUILD, this
/// spawn sets no `.cwd` — the child inherits OURS — so a relative
/// `target_dir` in the script argv (and a relative `tool_path`) resolves
/// exactly where our own checks resolved it. No absolutization needed.
/// Exec the declare tool over the collected sources and return its RAW
/// stdout (the schema JSON, owned by the caller). `cache_dir`, when set, is
/// passed as a leading `--cache-dir <dir>` argument — the rev-17 invocation
/// contract for a tool that stages a persistent per-project workspace (a
/// native probe's cargo target-dir). The hardcoded lua/ruby tools take no
/// cache dir, so `runDeclareTool` passes null and their argv is unchanged.
fn execDeclareTool(
    allocator: std.mem.Allocator,
    tool_path: []const u8,
    target_dir: []const u8,
    script_files: []const []const u8,
    cache_dir: ?[]const u8,
) ![]u8 {
    var argv: std.ArrayList([]const u8) = .empty;
    // Borrowed argv entries: tool_path, plus the `--cache-dir <dir>` pair
    // when present. Only the joined script paths (from `owned_start` on) are
    // owned by us and freed here.
    const owned_start: usize = if (cache_dir != null) 3 else 1;
    defer {
        if (argv.items.len > owned_start) for (argv.items[owned_start..]) |p| allocator.free(p);
        argv.deinit(allocator);
    }
    try argv.ensureTotalCapacity(allocator, script_files.len + owned_start);
    argv.appendAssumeCapacity(tool_path);
    if (cache_dir) |cd| {
        argv.appendAssumeCapacity("--cache-dir");
        argv.appendAssumeCapacity(cd);
    }
    for (script_files) |file_name| {
        const p = try std.fs.path.join(allocator, &.{ target_dir, file_name });
        argv.appendAssumeCapacity(p);
    }

    const io = config.globalIo();
    const result = std.process.run(allocator, io, .{ .argv = argv.items }) catch |err| {
        diag("could not run the declare tool {s}: {s}", .{ tool_path, @errorName(err) });
        return error.ScriptDeclarationFailed;
    };
    defer allocator.free(result.stderr);
    switch (result.term) {
        .exited => |code| if (code != 0) {
            allocator.free(result.stdout);
            relayChildStderr(result.stderr);
            diag("script component declarations failed (declare tool exit {d})", .{code});
            return error.ScriptDeclarationFailed;
        },
        else => {
            allocator.free(result.stdout);
            relayChildStderr(result.stderr);
            diag("the declare tool terminated abnormally", .{});
            return error.ScriptDeclarationFailed;
        },
    }
    return result.stdout;
}

/// Exec the declare tool (no cache dir — the hardcoded lua/ruby path) and
/// parse its stdout as the schema. See `execDeclareTool` for the
/// relative-path audit (PR #598 finding 1): this spawn sets no `.cwd`, so a
/// relative `target_dir` in the argv resolves against OUR cwd, as our own
/// checks did.
fn runDeclareTool(
    allocator: std.mem.Allocator,
    tool_path: []const u8,
    target_dir: []const u8,
    script_files: []const []const u8,
) !Schema {
    const out = try execDeclareTool(allocator, tool_path, target_dir, script_files, null);
    defer allocator.free(out);
    return parseSchema(allocator, out);
}

// ── Phase orchestration (called from root.zig's generate) ────────────

pub const PhaseOptions = struct {
    plugins: []const config.PluginDep,
    plugin_name: []const u8,
    language: []const u8,
    /// TARGET-RELATIVE collected language files (extension included) —
    /// the collection's `EmbedScript.file` column: `components/*.<ext>`
    /// declarations FIRST, then `events/*.<ext>` declarations, then the
    /// script dir's files (subdir paths joined with `/` for legacy-dir
    /// collections). All feed the runner — in-script chunk-scope
    /// declarations remain legal.
    script_files: []const []const u8,
    /// The `events/*.<ext>` declaration files (labelle-engine#772) — a
    /// SUBSET of `script_files` (already in the runner argv), carried
    /// separately so the events gates can fire up front and point at
    /// them: the `events_min_pin` floor, the no-runner-row hard error,
    /// and the declares-nothing error. Empty when the project has no
    /// events-dir language files (every gate is then a no-op).
    event_files: []const []const u8 = &.{},
    output_dir: []const u8,
    target_dir: []const u8,
    project_dir: []const u8,
    /// Game-root component stems (collision gate).
    component_names: []const []const u8,
    /// Game-root event stems — `events/*.zig` scan (event collision gate).
    event_names: []const []const u8 = &.{},
    /// Pack scans (collision gates against `<pack>__<Pascal>` component
    /// fields and `<pack>__<ident>` event variants).
    pack_scans: []const scan.PackScan,
};

/// Run the whole declare phase for an active scripting splice: try the
/// generic `.languages` capability path FIRST (the #619 dispatch flip — the
/// primary path for every language whose resolved manifest declares a row),
/// then fall back to the language's FROZEN `DECLARE_RUNNERS` row, gate the
/// events floor (labelle-engine#772), build (or reuse) the runner, extract
/// the schema,
/// gate collisions, and write the generated `scripting_components.zig` /
/// `scripting_events.zig` into the target. Returns the owned Schema when
/// at least one component OR event was declared (the caller threads
/// `schema.components`/`schema.events` onto the splice and keeps the
/// Schema alive through main.zig emission), null for every no-op shape
/// (no collected files at all; a language without a runner row —
/// typescript; files but no declarations). Every no-op shape also deletes
/// stale generated files left by a previously-declaring project state.
///
/// The events GATES are hard errors, never skips — `events/*.<ext>` files
/// exist only to declare events, so every shape that can't deliver them
/// must fail generate pointing at the files (the runtime alternative is a
/// missing-method error at game boot, far from the cause):
///   - no runner row for the language (typescript) → the files can never
///     declare anything;
///   - resolved pin below the row's `events_min_pin` (or the whole tool
///     dir absent) → the preludes predate `Labelle.event`;
///   - the runner ran but the schema carries no events → the files
///     declare nothing (almost certainly an authoring mistake — the
///     v0.10.0+ preludes always record `Labelle.event`).
pub fn runPhase(allocator: std.mem.Allocator, opts: PhaseOptions) !?Schema {
    if (opts.script_files.len == 0) {
        removeStaleGeneratedFiles(allocator, opts.target_dir);
        return null;
    }

    // Generic `.languages` declare path (RFC-LANGUAGE-PLUGINS rev 17 §7 +
    // the Migration bullet): the resolved plugin manifest's `.languages`
    // capability row is the PRIMARY declare path for EVERY language — the
    // assembler reads the row generically (build `.declare.tool` via `zig
    // build`, run it with a persistent `--cache-dir` + the declaration
    // files, hash-and-skip when unchanged), learning nothing
    // language-specific. This is the #619 dispatch flip: it is attempted
    // first for lua/ruby/rust alike, NOT only for languages absent from the
    // hardcoded `DECLARE_RUNNERS` table. A manifest that carries a
    // `.languages` declare row for the language wins here; one that predates
    // `.languages` (or has no declare row for it) returns `.not_applicable`
    // and falls through to the table below — which is now a FROZEN FALLBACK
    // for pins predating capability rows, never the primary path when a row
    // exists. So a new language needs only a `.languages` row + tool, zero
    // assembler changes (the litmus test).
    switch (try runGenericDeclarePhase(allocator, opts)) {
        .handled => |maybe_schema| return maybe_schema,
        .not_applicable => {},
    }

    // Runner-row gate (see `DECLARE_RUNNERS`): a language without a
    // declare runner must SKIP, not run another language's runner over
    // foreign sources. Note-level stderr line + the same stale-file
    // cleanup as the other no-op shapes, so a project switching languages
    // leaves no orphaned generated file. Events-dir files flip the skip
    // into the hard error documented above.
    const runner = declareRunner(opts.language) orelse {
        if (opts.event_files.len > 0) {
            diag(
                "script-declared events are not supported for \"{s}\" — no declare runner exists for it, so these events/ files can never declare a game event (keep Zig events/*.zig for this language):",
                .{opts.language},
            );
            diagFileList(opts.event_files);
            return error.ScriptEventsUnsupported;
        }
        diag(
            "script-declared components are not yet supported for \"{s}\" — skipping the declare phase ({s} scripts still run, they just can't declare components)",
            .{ opts.language, opts.language },
        );
        removeStaleGeneratedFiles(allocator, opts.target_dir);
        return null;
    };

    // Events floor (labelle-engine#772): a resolved pin BELOW the row's
    // `events_min_pin` ships preludes that predate `Labelle.event` — the
    // declare tool would silently record nothing and the game would fail
    // at BOOT with a missing-method error. Fail up front, before the tool
    // build, naming the floor and the files. Local pins and non-semver
    // refs satisfy the floor (see `DeclareRunner.events_min_pin`).
    if (opts.event_files.len > 0) {
        if (pluginDep(opts.plugins, opts.plugin_name)) |dep| {
            if (!dep.isLocal() and semverBelow(dep.version, runner.events_min_pin)) {
                diag(
                    "events/*{s} declaration files need labelle-scripting >= {s} (`Labelle.event`), but the project pins {s} — bump the pin or remove the files:",
                    .{ runner.extension, runner.events_min_pin, dep.version },
                );
                diagFileList(opts.event_files);
                return error.ScriptEventsPinTooOld;
            }
        }
    }

    const pkg_dir = try resolvePluginPackageDir(
        allocator,
        opts.plugins,
        opts.plugin_name,
        opts.output_dir,
        opts.project_dir,
    );
    defer allocator.free(pkg_dir);

    const tool_path = ensureDeclareTool(allocator, pkg_dir, opts.output_dir, runner) catch |err| switch (err) {
        error.DeclareToolAbsent => {
            if (opts.event_files.len > 0) {
                diag(
                    "the pinned scripting plugin ships no {s} declare tool (no {s} in the package), but the project declares events in events/ files — script-declared events need labelle-scripting >= {s}:",
                    .{ opts.language, runner.tool_dir, runner.events_min_pin },
                );
                diagFileList(opts.event_files);
                return error.ScriptEventsPinTooOld;
            }
            diag(
                "the pinned scripting plugin ships no {s} declare tool (no {s} in the package) — script-declared components are disabled this generate; pin labelle-scripting >= {s} to use component declarations",
                .{ opts.language, runner.tool_dir, runner.min_pin },
            );
            removeStaleGeneratedFiles(allocator, opts.target_dir);
            return null;
        },
        else => return err,
    };
    const schema = try runDeclareTool(
        allocator,
        tool_path,
        opts.target_dir,
        opts.script_files,
    );
    return finalizeSchema(allocator, opts, schema, runner.extension);
}

/// The shared declare-phase tail, run for BOTH the hardcoded-runner path
/// and the generic `.languages` path (rev 17): the events-none gate, the
/// declares-nothing no-op, the collision checks, and the
/// `scripting_components.zig` / `scripting_events.zig` renders. Takes
/// OWNERSHIP of `schema` — it is deinited on the empty no-op and on any
/// error, and returned to the caller otherwise. `events_ext` is the
/// language's source extension (`.rb`, `.rs`) for the events-none message.
fn finalizeSchema(
    allocator: std.mem.Allocator,
    opts: PhaseOptions,
    schema_in: Schema,
    events_ext: []const u8,
) !?Schema {
    var schema = schema_in;
    errdefer schema.deinit();

    // events/ files that declare NOTHING are a pointed error, not a
    // silent no-op: the dir exists to declare events, and the v0.10.0+
    // preludes record every `Labelle.event` — an empty yield means the
    // author wrote something else (or nothing) into a declarations file.
    // AGGREGATE over the events dir, deliberately not per-file: the
    // schema carries no file attribution, and re-running the tool
    // per-file to get one would false-fail legitimate projects (chunks
    // share one VM — an events file may reference a constant an earlier
    // components/events file defined, and alone it raises NameError).
    if (opts.event_files.len > 0 and schema.events.len == 0) {
        diag(
            "the project's events/*{s} file(s) declare no events — `HungerFeed = Labelle.event \"hunger__feed\", entity: Labelle.id, ...` is the declaration shape; a declaration-less events file is almost certainly a mistake:",
            .{events_ext},
        );
        diagFileList(opts.event_files);
        return error.ScriptEventsNoneDeclared;
    }

    if (schema.components.len == 0 and schema.events.len == 0) {
        schema.deinit();
        removeStaleGeneratedFiles(allocator, opts.target_dir);
        return null;
    }

    try checkCollisions(schema.components, opts.component_names, opts.pack_scans);
    try checkEventCollisions(schema.events, opts.event_names, opts.pack_scans);

    if (schema.components.len > 0) {
        var rendered: std.Io.Writer.Allocating = .init(allocator);
        defer rendered.deinit();
        try renderComponentsFile(schema.components, &rendered.writer);
        try scanner.writeFile(opts.target_dir, GENERATED_FILENAME, rendered.writer.buffered());
    } else {
        // Events-only project state: a stale components file from a
        // previously component-declaring state must not linger.
        removeStaleFile(allocator, opts.target_dir, GENERATED_FILENAME);
    }

    if (schema.events.len > 0) {
        var rendered: std.Io.Writer.Allocating = .init(allocator);
        defer rendered.deinit();
        try renderEventsFile(schema.events, &rendered.writer);
        try scanner.writeFile(opts.target_dir, GENERATED_EVENTS_FILENAME, rendered.writer.buffered());
    } else {
        removeStaleFile(allocator, opts.target_dir, GENERATED_EVENTS_FILENAME);
    }

    return schema;
}

// ── Generic `.languages` declare path (RFC-LANGUAGE-PLUGINS rev 17) ───

/// Per-declaration-file read cap for the input digest (a hand-written
/// schema file — megabytes means something is wrong).
const MAX_DECL_BYTES = 4 * 1024 * 1024;
/// Cap on the cached schema JSON re-read on a skip hit.
const MAX_SCHEMA_BYTES = 16 * 1024 * 1024;
/// Cap on the declare-tool binary read folded into the skip key. Generous —
/// a Debug native-probe exe is a handful of MB; over the cap folds a read
/// error (forcing a safe re-run), never a silent stale hit.
const MAX_TOOL_BYTES = 256 * 1024 * 1024;

/// The outcome of `runGenericDeclarePhase`: either it drove the generic
/// path (`.handled`, carrying the final schema or null for a no-op/skip),
/// or the language has no `.languages` declare row so the caller falls
/// through to the hardcoded `DECLARE_RUNNERS` table's skip/hard-error.
const GenericOutcome = union(enum) {
    not_applicable,
    handled: ?Schema,
};

/// Run the declare phase for a language via the resolved plugin manifest's
/// `.languages` capability row (rev 17) — the GENERIC path rust flows.
/// Reads the row's `.declare` capability, gates events by the
/// self-describing `.events` flag (no version table), builds the tool via
/// `zig build <.tool>` (the same `ensureDeclareTool` path every runner
/// uses), and runs it with a persistent `--cache-dir` + the declaration
/// files, hashing the inputs to skip a re-run when unchanged. Returns
/// `.not_applicable` when the language has no such row (fall through).
fn runGenericDeclarePhase(allocator: std.mem.Allocator, opts: PhaseOptions) !GenericOutcome {
    // Package resolution / manifest load failures fall through as
    // `.not_applicable` rather than erroring: a language that turns out to
    // have no `.languages` declare row must skip CLEANLY even when the
    // plugin setup is degenerate (the runner-row gate's long-standing
    // "no-runner language, tool machinery untouched" invariant — a
    // typescript project with no staged package must not fail here). A real
    // rust project resolves its scripting package fine and proceeds; only a
    // project whose scripting splice is already broken falls through, and
    // then the table below degrades it to the same graceful skip.
    const pkg_dir = resolvePluginPackageDir(
        allocator,
        opts.plugins,
        opts.plugin_name,
        opts.output_dir,
        opts.project_dir,
    ) catch return .not_applicable;
    defer allocator.free(pkg_dir);

    var manifest = (plugin_manifest.loadFromDir(allocator, pkg_dir, opts.plugin_name) catch return .not_applicable) orelse
        return .not_applicable;
    defer manifest.deinit();

    const row = manifest.languageRow(opts.language) orelse return .not_applicable;
    const declare = row.declare orelse return .not_applicable;

    // ".rs" spelling for messages (finalizeSchema's events-none note),
    // in the leading-dot form the hardcoded rows' `.extension` uses. rev 19
    // A1 pins `.extensions` to the authored dot-spelled form (".rs"), but
    // this NORMALIZES either spelling — a dotless legacy `"rs"` gets a dot
    // prepended, a dotted ".rs" is taken verbatim — so the migration is
    // forgiving. Stack-lived: every use is within this frame (before the
    // `manifest.deinit` defer).
    var ext_buf: [32]u8 = undefined;
    const dotted_ext = blk: {
        if (row.extensions.len == 0) break :blk "";
        const raw = row.extensions[0];
        if (raw.len > 0 and raw[0] == '.') break :blk raw;
        if (raw.len + 1 >= ext_buf.len) break :blk "";
        break :blk std.fmt.bufPrint(&ext_buf, ".{s}", .{raw}) catch "";
    };

    // Events capability gate — the rev-17 self-describing capability that
    // replaces the hardcoded `events_min_pin` table: events/ files need the
    // row's `.declare.events = true`, else they can never declare.
    if (opts.event_files.len > 0 and !declare.events) {
        diag(
            "script-declared events are not supported by the pinned scripting plugin's \"{s}\" language row (its `.declare` capability has no `.events = true`) — these events/ files can never declare a game event:",
            .{opts.language},
        );
        diagFileList(opts.event_files);
        return error.ScriptEventsUnsupported;
    }

    // The generic tool build reuses the same `zig build <step> --prefix
    // <output>/declare-tool` machinery as the hardcoded rows — the step
    // name AND installed exe name are `.declare.tool`, the capability probe
    // dir is `.declare.dir`. min/events pins are unused on this path (the
    // capability is self-describing), so they stay empty.
    const synth = DeclareRunner{
        .language = opts.language,
        .step_name = declare.tool,
        .tool_dir = declare.dir,
        .extension = dotted_ext,
        .min_pin = "",
        .events_min_pin = "",
    };
    const tool_path = ensureDeclareTool(allocator, pkg_dir, opts.output_dir, synth) catch |err| switch (err) {
        error.DeclareToolAbsent => {
            if (opts.event_files.len > 0) {
                diag(
                    "the pinned scripting plugin ships no \"{s}\" declare tool ({s} absent), but the project declares events in events/ files:",
                    .{ opts.language, declare.dir },
                );
                diagFileList(opts.event_files);
                return error.ScriptEventsUnsupported;
            }
            diag(
                "the pinned scripting plugin ships no \"{s}\" declare tool ({s} absent) — script-declared components are disabled this generate",
                .{ opts.language, declare.dir },
            );
            removeStaleGeneratedFiles(allocator, opts.target_dir);
            return .{ .handled = null };
        },
        else => return err,
    };

    // The persistent per-project cache dir (rev 17): under the survives-
    // generate `<output>/declare-tool/`, so the tool's own workspace (a
    // native probe's cargo target-dir) stays warm across generates. Opaque
    // to us — we only hand it over.
    const cache_dir = try genericProbeCacheDir(allocator, opts.output_dir, declare.tool);
    defer allocator.free(cache_dir);

    const schema = try acquireSchemaWithSkip(allocator, opts, tool_path, cache_dir);
    return .{ .handled = try finalizeSchema(allocator, opts, schema, dotted_ext) };
}

/// `<output>/declare-tool/<tool>-cache` (absolute) — the persistent
/// per-project workspace handed to a `.languages` declare tool as
/// `--cache-dir`. Under the same survives-generate prefix as the built tool
/// exes; caller frees.
fn genericProbeCacheDir(allocator: std.mem.Allocator, output_dir: []const u8, tool: []const u8) ![]const u8 {
    const output_abs = try std.Io.Dir.cwd().realPathFileAlloc(config.globalIo(), output_dir, allocator);
    defer allocator.free(output_abs);
    const sub = try std.fmt.allocPrint(allocator, "{s}-cache", .{tool});
    defer allocator.free(sub);
    return std.fs.path.join(allocator, &.{ output_abs, "declare-tool", sub });
}

/// Acquire the schema for the generic path, hashing the declaration inputs
/// to SKIP re-invoking the tool when unchanged (rev 17 invariant 1: the
/// declaration files alone determine the schema, so editing a gameplay
/// script never re-extracts — for the native family, gameplay scripts are
/// staged for the compiler and are not in `script_files` at all). On a hit
/// the cached schema JSON is re-parsed; on a miss the tool runs and its raw
/// JSON + the input digest are cached (best-effort — a cache write failure
/// never fails generate).
fn acquireSchemaWithSkip(
    allocator: std.mem.Allocator,
    opts: PhaseOptions,
    tool_path: []const u8,
    cache_dir: []const u8,
) !Schema {
    const io = config.globalIo();
    const cwd = std.Io.Dir.cwd();

    const skip_dir = try std.fs.path.join(allocator, &.{ cache_dir, ".assembler-skip" });
    defer allocator.free(skip_dir);
    const hash_path = try std.fs.path.join(allocator, &.{ skip_dir, "inputs.sha256" });
    defer allocator.free(hash_path);
    const json_path = try std.fs.path.join(allocator, &.{ skip_dir, "schema.json" });
    defer allocator.free(json_path);

    const digest = try declInputsDigestHex(allocator, tool_path, opts.target_dir, opts.script_files);
    defer allocator.free(digest);

    // Skip hit: stored digest matches AND the cached JSON is readable.
    // Any read miss / mismatch just falls through to a fresh run.
    if (cwd.readFileAlloc(io, hash_path, allocator, .limited(128))) |stored| {
        defer allocator.free(stored);
        if (std.mem.eql(u8, std.mem.trim(u8, stored, " \r\n"), digest)) {
            if (cwd.readFileAlloc(io, json_path, allocator, .limited(MAX_SCHEMA_BYTES))) |json| {
                defer allocator.free(json);
                return parseSchema(allocator, json);
            } else |_| {}
        }
    } else |_| {}

    const out = try execDeclareTool(allocator, tool_path, opts.target_dir, opts.script_files, cache_dir);
    defer allocator.free(out);
    // Best-effort cache write — correctness never depends on it.
    cwd.createDirPath(io, skip_dir) catch {};
    cwd.writeFile(io, .{ .sub_path = json_path, .data = out }) catch {};
    cwd.writeFile(io, .{ .sub_path = hash_path, .data = digest }) catch {};
    return parseSchema(allocator, out);
}

/// SHA-256 of the resolved TOOL identity + the declaration inputs (each a
/// path + its bytes), hex-encoded. The tool binary's bytes are folded in
/// FIRST so the skip key is tied to the exact declare tool that produced the
/// cached schema: a scripting pin bump (or a local plugin checkout change)
/// rebuilds a different exe — a different digest — forcing a re-run even when
/// the declaration files are byte-identical, so a plugin upgrade can never
/// leave stale generated components/events (codex #622). Path is folded in
/// so a rename/reorder is a change; an unreadable input (or an unreadable
/// tool) folds its error name (never spuriously matches a prior good run —
/// the tool run then surfaces the real error). Caller frees.
fn declInputsDigestHex(
    allocator: std.mem.Allocator,
    tool_path: []const u8,
    target_dir: []const u8,
    script_files: []const []const u8,
) ![]u8 {
    const io = config.globalIo();
    const cwd = std.Io.Dir.cwd();
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    // Tool identity first: the exact binary the cached schema came from.
    hasher.update(tool_path);
    hasher.update(&.{0});
    if (cwd.readFileAlloc(io, tool_path, allocator, .limited(MAX_TOOL_BYTES))) |bytes| {
        defer allocator.free(bytes);
        hasher.update(bytes);
    } else |err| {
        hasher.update(@errorName(err));
    }
    hasher.update(&.{0});
    for (script_files) |file_name| {
        hasher.update(file_name);
        hasher.update(&.{0});
        const p = try std.fs.path.join(allocator, &.{ target_dir, file_name });
        defer allocator.free(p);
        if (cwd.readFileAlloc(io, p, allocator, .limited(MAX_DECL_BYTES))) |bytes| {
            defer allocator.free(bytes);
            hasher.update(bytes);
        } else |err| {
            hasher.update(@errorName(err));
        }
        hasher.update(&.{0});
    }
    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    hasher.final(&digest);
    const hex = std.fmt.bytesToHex(digest, .lower);
    return allocator.dupe(u8, &hex);
}

/// The project's `plugins` entry named `plugin_name`, or null. The events
/// floor gate reads its pin (`version` + `isLocal`).
fn pluginDep(plugins: []const config.PluginDep, plugin_name: []const u8) ?config.PluginDep {
    for (plugins) |p| {
        if (std.mem.eql(u8, p.name, plugin_name)) return p;
    }
    return null;
}

/// True when `version` is a parseable semver STRICTLY below `floor`.
/// Anything unparseable — branch refs, an empty version (registry
/// default), local paths — returns false: for those the capability
/// probes / the tool itself are the only authority, exactly how the
/// existing `min_pin` handling treats them.
fn semverBelow(version: []const u8, floor: []const u8) bool {
    const v = std.SemanticVersion.parse(version) catch return false;
    const f = std.SemanticVersion.parse(floor) catch return false;
    return v.order(f) == .lt;
}

/// Best-effort cleanup of BOTH stale generated files (a project whose
/// declarations were all removed): nothing imports them anymore, but a
/// lingering generated file misleads readers of the target dir.
fn removeStaleGeneratedFiles(allocator: std.mem.Allocator, target_dir: []const u8) void {
    removeStaleFile(allocator, target_dir, GENERATED_FILENAME);
    removeStaleFile(allocator, target_dir, GENERATED_EVENTS_FILENAME);
}

fn removeStaleFile(allocator: std.mem.Allocator, target_dir: []const u8, filename: []const u8) void {
    const io = config.globalIo();
    const path = std.fs.path.join(allocator, &.{ target_dir, filename }) catch return;
    defer allocator.free(path);
    std.Io.Dir.cwd().deleteFile(io, path) catch {};
}

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;

/// The pinned example schema from the ticket (whitespace-insensitive JSON).
const example_schema =
    \\{ "components": [ { "name": "Hunger", "persist": "persistent",
    \\    "fields": [ {"name":"level","type":"f32","default":1.0},
    \\                {"name":"starving","type":"bool","default":false} ] } ] }
;

test "parseSchema: the ticket's example parses into the typed model" {
    var schema = try parseSchema(testing.allocator, example_schema);
    defer schema.deinit();
    try testing.expectEqual(@as(usize, 1), schema.components.len);
    const comp = schema.components[0];
    try testing.expectEqualStrings("Hunger", comp.name);
    try testing.expectEqual(Persist.persistent, comp.persist);
    try testing.expectEqual(@as(usize, 2), comp.fields.len);
    try testing.expectEqualStrings("level", comp.fields[0].name);
    try testing.expectEqual(@as(f64, 1.0), comp.fields[0].default.f32);
    try testing.expectEqualStrings("starving", comp.fields[1].name);
    try testing.expectEqual(false, comp.fields[1].default.bool);
}

test "parseSchema: persist defaults to persistent; transient parses; every v1 type lands" {
    var schema = try parseSchema(testing.allocator,
        \\{"components":[{"name":"Kitchen","persist":"transient","fields":[
        \\  {"name":"heat","type":"u32","default":7},
        \\  {"name":"owner","type":"entity","default":0},
        \\  {"name":"pos","type":"vec2","default":{"x":4.0,"y":-2}},
        \\  {"name":"label","type":"str","default":"a\"b"},
        \\  {"name":"n","type":"i32","default":-3}
        \\]},{"name":"Marker","fields":[]}]}
    );
    defer schema.deinit();
    try testing.expectEqual(@as(usize, 2), schema.components.len);
    const kitchen = schema.components[0];
    try testing.expectEqual(Persist.transient, kitchen.persist);
    try testing.expectEqual(@as(u32, 7), kitchen.fields[0].default.u32);
    try testing.expectEqual(@as(u64, 0), kitchen.fields[1].default.entity);
    try testing.expectEqual(@as(f64, 4.0), kitchen.fields[2].default.vec2.x);
    try testing.expectEqual(@as(f64, -2.0), kitchen.fields[2].default.vec2.y);
    try testing.expectEqualStrings("a\"b", kitchen.fields[3].default.str);
    try testing.expectEqual(@as(i32, -3), kitchen.fields[4].default.i32);
    // Field-less + persist-less component: the schema default.
    try testing.expectEqual(Persist.persistent, schema.components[1].persist);
    try testing.expectEqual(@as(usize, 0), schema.components[1].fields.len);
}

test "parseSchema: enums (and any unknown type) are rejected LOUDLY, not guessed" {
    try testing.expectError(error.ScriptSchemaInvalid, parseSchema(testing.allocator,
        \\{"components":[{"name":"Mood","fields":[{"name":"state","type":"enum","default":"happy"}]}]}
    ));
    try testing.expectError(error.ScriptSchemaInvalid, parseSchema(testing.allocator,
        \\{"components":[{"name":"Mood","fields":[{"name":"state","type":"f64","default":1}]}]}
    ));
}

test "parseSchema: malformed documents reject (bad JSON, bad names, ranges, duplicates, reserved Vec2)" {
    const bad_cases = [_][]const u8{
        "not json at all",
        \\{"components":[{"name":"","fields":[]}]}
        ,
        \\{"components":[{"name":"Has Space","fields":[]}]}
        ,
        \\{"components":[{"name":"Vec2","fields":[]}]}
        ,
        \\{"components":[{"name":"A","fields":[]},{"name":"A","fields":[]}]}
        ,
        \\{"components":[{"name":"A","fields":[{"name":"x","type":"i32","default":1},{"name":"x","type":"i32","default":2}]}]}
        ,
        \\{"components":[{"name":"A","persist":"forever","fields":[]}]}
        ,
        \\{"components":[{"name":"A","fields":[{"name":"n","type":"i32","default":3000000000}]}]}
        ,
        \\{"components":[{"name":"A","fields":[{"name":"n","type":"u32","default":-1}]}]}
        ,
        \\{"components":[{"name":"A","fields":[{"name":"n","type":"i32"}]}]}
        ,
        \\{"components":[{"name":"A","fields":[{"name":"p","type":"vec2","default":{"x":1}}]}]}
        ,
    };
    for (bad_cases) |case| {
        try testing.expectError(error.ScriptSchemaInvalid, parseSchema(testing.allocator, case));
    }
}

test "parseSchema: reserved names reject — keyword/primitive fields, the generated `save` decl, keyword/primitive components" {
    // Every name below passes the char-class identifier check yet is
    // reserved (PR #598 finding 1): keywords break generated code in any
    // position, primitives break decl position (`pub const type = struct`
    // is "name shadows primitive") and are reserved for fields too, and
    // `save` collides with the decl every generated struct carries.
    const reserved_cases = [_][]const u8{
        // Field named the `type` primitive.
        \\{"components":[{"name":"A","fields":[{"name":"type","type":"f32","default":0}]}]}
        ,
        // Fields named Zig keywords → `error: i32 = 0,` is a parse error.
        \\{"components":[{"name":"A","fields":[{"name":"error","type":"i32","default":0}]}]}
        ,
        \\{"components":[{"name":"A","fields":[{"name":"align","type":"u32","default":0}]}]}
        ,
        // Field named `save` → collides with the generated Saveable decl.
        \\{"components":[{"name":"A","fields":[{"name":"save","type":"bool","default":false}]}]}
        ,
        // Component named the `type` primitive → "name shadows primitive".
        \\{"components":[{"name":"type","fields":[]}]}
        ,
        // Component named a Zig keyword → `pub const error = struct` fails.
        \\{"components":[{"name":"error","fields":[]}]}
        ,
        // `_` is the discard token, not an identifier — component or field.
        \\{"components":[{"name":"_","fields":[]}]}
        ,
        \\{"components":[{"name":"A","fields":[{"name":"_","type":"f32","default":0}]}]}
        ,
    };
    for (reserved_cases) |case| {
        try testing.expectError(error.ScriptSchemaInvalid, parseSchema(testing.allocator, case));
    }
    // The gate is exact — a name merely CONTAINING a keyword still passes.
    var schema = try parseSchema(testing.allocator,
        \\{"components":[{"name":"ErrorLog","fields":[{"name":"save_count","type":"u32","default":0},{"name":"type_name","type":"str","default":""}]}]}
    );
    schema.deinit();
}

test "parseSchema: f32 defaults beyond f32 range reject at generate time (the declare tool's F32_MAX gate, mirrored)" {
    // The schema carries f64 — without the gate a runner emitting 1e100
    // passes validation and the generated `x: f32 = 1e100` fails at COMPILE
    // time instead (PR #598 finding 3). f32 fields and both vec2 axes gate.
    const overflow_cases = [_][]const u8{
        \\{"components":[{"name":"A","fields":[{"name":"level","type":"f32","default":1e100}]}]}
        ,
        \\{"components":[{"name":"A","fields":[{"name":"level","type":"f32","default":-1e100}]}]}
        ,
        \\{"components":[{"name":"A","fields":[{"name":"pos","type":"vec2","default":{"x":1e100,"y":0}}]}]}
        ,
        \\{"components":[{"name":"A","fields":[{"name":"pos","type":"vec2","default":{"x":0,"y":-1e100}}]}]}
        ,
    };
    for (overflow_cases) |case| {
        try testing.expectError(error.ScriptSchemaInvalid, parseSchema(testing.allocator, case));
    }
    // The tool-side golden's boundary values still pass: 3.4e38 (the
    // labelle-scripting#5 byte-exact pass case) and the F32_MAX constant
    // itself (the gate is strictly greater-than).
    var schema = try parseSchema(testing.allocator,
        \\{"components":[{"name":"A","fields":[
        \\  {"name":"big","type":"f32","default":3.4e38},
        \\  {"name":"edge","type":"f32","default":3.4028235e38},
        \\  {"name":"pos","type":"vec2","default":{"x":3.4e38,"y":-3.4e38}}
        \\]}]}
    );
    defer schema.deinit();
    try testing.expectEqual(@as(f64, 3.4e38), schema.components[0].fields[0].default.f32);
    try testing.expectEqual(@as(f64, 3.4e38), schema.components[0].fields[2].default.vec2.x);
    try testing.expectEqual(@as(f64, -3.4e38), schema.components[0].fields[2].default.vec2.y);
}

/// Render `components` into a caller-freed buffer.
fn renderForTest(components: []const DeclaredComponent) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    errdefer aw.deinit();
    try renderComponentsFile(components, &aw.writer);
    var arr = aw.toArrayList();
    errdefer arr.deinit(testing.allocator);
    return arr.toOwnedSlice(testing.allocator);
}

/// Run Zig's front-end (parse → AstGen) over `src` and fail on any parse
/// or AstGen-level compile error — the same gate `main_template.zig` uses
/// (imports stay unresolved, so no engine/core checkout is needed).
fn expectAstGenOk(src: []const u8) !void {
    const src_z = try testing.allocator.dupeZ(u8, src);
    defer testing.allocator.free(src_z);
    var ast = try std.zig.Ast.parse(testing.allocator, src_z, .zig);
    defer ast.deinit(testing.allocator);
    if (ast.errors.len != 0) {
        std.debug.print("expectAstGenOk: {d} parse error(s)\n", .{ast.errors.len});
        return error.AstGenParseError;
    }
    var zir = try std.zig.AstGen.generate(testing.allocator, ast);
    defer zir.deinit(testing.allocator);
    if (zir.hasCompileErrors()) {
        std.debug.print("expectAstGenOk: AstGen reported compile errors\n", .{});
        return error.AstGenCompileError;
    }
}

test "renderComponentsFile: schema → struct golden (canonical Saveable shape) + AstGen" {
    var schema = try parseSchema(testing.allocator, example_schema);
    defer schema.deinit();
    const got = try renderForTest(schema.components);
    defer testing.allocator.free(got);

    const golden =
        "pub const Hunger = struct {\n" ++
        "    pub const save = @import(\"labelle-core\").Saveable(.saveable, @This(), .{});\n" ++
        "\n" ++
        "    level: f32 = 1,\n" ++
        "    starving: bool = false,\n" ++
        "};\n\n";
    try testing.expect(std.mem.endsWith(u8, got, golden));
    // No vec2 fields → no Vec2 backing decl.
    try testing.expect(std.mem.indexOf(u8, got, "Vec2") == null);
    try expectAstGenOk(got);
}

test "renderComponentsFile: transient policy, entity_refs, str escaping, vec2 backing decl + AstGen" {
    var schema = try parseSchema(testing.allocator,
        \\{"components":[
        \\ {"name":"Assignment","persist":"transient","fields":[
        \\   {"name":"worker","type":"entity","default":0},
        \\   {"name":"station","type":"entity","default":0},
        \\   {"name":"label","type":"str","default":"a\"b\\c"},
        \\   {"name":"spot","type":"vec2","default":{"x":1.5,"y":-2}},
        \\   {"name":"slots","type":"u32","default":4}]},
        \\ {"name":"Dead","persist":"transient","fields":[]}
        \\]}
    );
    defer schema.deinit();
    const got = try renderForTest(schema.components);
    defer testing.allocator.free(got);

    // Policy + the core Stored idiom: entity fields are u64 ids listed in
    // .entity_refs (field order preserved).
    try testing.expect(std.mem.indexOf(u8, got, "    pub const save = @import(\"labelle-core\").Saveable(.transient, @This(), .{\n" ++
        "        .entity_refs = &.{\"worker\", \"station\"},\n" ++
        "    });\n") != null);
    try testing.expect(std.mem.indexOf(u8, got, "    worker: u64 = 0,\n") != null);
    // str defaults escape as Zig string literals.
    try testing.expect(std.mem.indexOf(u8, got, "    label: []const u8 = \"a\\\"b\\\\c\",\n") != null);
    // vec2 fields ride the emitted-once backing struct.
    try testing.expect(std.mem.indexOf(u8, got, "pub const Vec2 = struct { x: f32 = 0, y: f32 = 0 };") != null);
    try testing.expect(std.mem.indexOf(u8, got, "    spot: Vec2 = .{ .x = 1.5, .y = -2 },\n") != null);
    try testing.expect(std.mem.indexOf(u8, got, "    slots: u32 = 4,\n") != null);
    // Zero-field marker still carries its Saveable decl.
    try testing.expect(std.mem.indexOf(u8, got, "pub const Dead = struct {\n" ++
        "    pub const save = @import(\"labelle-core\").Saveable(.transient, @This(), .{});\n" ++
        "};\n") != null);
    try expectAstGenOk(got);
}

test "declareToolPaths: a RELATIVE output dir absolutizes against OUR cwd (never the plugin package's)" {
    // The `zig build` child runs with cwd = the plugin package, so every
    // path it receives must already be absolute — a relative `output_dir`
    // (the `--project-root .` CLI shape) previously produced
    // package-relative `--prefix`/`--cache-dir` while our post-build
    // existence check resolved the same spelling against OUR cwd (PR #598
    // finding 1). The spawn itself isn't exercised here — building the
    // real tool needs `zig` on PATH + a network lua fetch, exactly what
    // the suite must not depend on — so the pin sits on the path helper
    // the spawn consumes.
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    // `testing.tmpDir` always creates `.zig-cache/tmp/<sub>` under the
    // test cwd — its cwd-RELATIVE spelling is exactly the shape that broke.
    var rel_buf: [64]u8 = undefined;
    const rel = try std.fmt.bufPrint(&rel_buf, ".zig-cache/tmp/{s}", .{&tmp.sub_path});

    const paths = try declareToolPaths(testing.allocator, rel, declareRunner("lua").?);
    defer paths.deinit(testing.allocator);

    try testing.expect(std.fs.path.isAbsolute(paths.prefix));
    try testing.expect(std.fs.path.isAbsolute(paths.zig_cache));
    try testing.expect(std.fs.path.isAbsolute(paths.tool_path));

    // And they resolve to the SAME place our own cwd-relative checks do.
    const abs = try std.Io.Dir.cwd().realPathFileAlloc(config.globalIo(), rel, testing.allocator);
    defer testing.allocator.free(abs);
    const expected_prefix = try std.fs.path.join(testing.allocator, &.{ abs, "declare-tool" });
    defer testing.allocator.free(expected_prefix);
    const expected_cache = try std.fs.path.join(testing.allocator, &.{ expected_prefix, "zig-cache" });
    defer testing.allocator.free(expected_cache);
    try testing.expectEqualStrings(expected_prefix, paths.prefix);
    try testing.expectEqualStrings(expected_cache, paths.zig_cache);
    try testing.expect(std.mem.startsWith(u8, paths.tool_path, expected_prefix));
    try testing.expect(std.mem.indexOf(u8, paths.tool_path, "labelle-declare") != null);

    // The per-row exe name lands in the path — ruby's binary is its OWN,
    // in the SAME shared prefix (the rows coexist by name).
    const ruby_paths = try declareToolPaths(testing.allocator, rel, declareRunner("ruby").?);
    defer ruby_paths.deinit(testing.allocator);
    try testing.expectEqualStrings(expected_prefix, ruby_paths.prefix);
    try testing.expect(std.mem.indexOf(u8, ruby_paths.tool_path, "labelle-declare-ruby") != null);
}

test "checkCollisions: game components, packs, and the VideoComponent built-in all gate" {
    const declared = [_]DeclaredComponent{
        .{ .name = "Hunger", .persist = .persistent, .fields = &.{} },
    };
    // Clean set: no collision.
    try checkCollisions(&declared, &.{ "worker", "room_state" }, &.{});
    // Game component with the same Pascal name (components/hunger.zig).
    try testing.expectError(
        error.ScriptComponentCollision,
        checkCollisions(&declared, &.{"hunger"}, &.{}),
    );
    // Built-in.
    const video = [_]DeclaredComponent{
        .{ .name = "VideoComponent", .persist = .persistent, .fields = &.{} },
    };
    try testing.expectError(error.ScriptComponentCollision, checkCollisions(&video, &.{}, &.{}));
    // Pack-namespaced field: citizens pack's counter.zig → citizens__Counter.
    const packish = [_]DeclaredComponent{
        .{ .name = "citizens__Counter", .persist = .persistent, .fields = &.{} },
    };
    const pack = scan.PackScan{
        .name = "citizens",
        .import_prefix = "packs/citizens",
        .component_names = &.{"counter"},
        .event_names = &.{},
        .prefab_names = &.{},
    };
    try testing.expectError(
        error.ScriptComponentCollision,
        checkCollisions(&packish, &.{}, &.{pack}),
    );
    // Long-name pin for the slice-wise pack compare (PR #618 review made
    // this loop buffer-free like the event check's; unlike there, the old
    // component buffer could never actually overflow — both operands are
    // 128-capped transforms — so this locks equivalence, not a bug fix).
    const long_pack = "p" ** 100;
    const long_stem = "e" ** 120; // pathToPascal → "E" + "e"*119, under its 128 cap
    const long_packish = [_]DeclaredComponent{
        .{ .name = long_pack ++ "__E" ++ ("e" ** 119), .persist = .persistent, .fields = &.{} },
    };
    const long_pack_scan = scan.PackScan{
        .name = long_pack,
        .import_prefix = "packs/" ++ long_pack,
        .component_names = &.{long_stem},
        .event_names = &.{},
        .prefab_names = &.{},
    };
    try testing.expectError(
        error.ScriptComponentCollision,
        checkCollisions(&long_packish, &.{}, &.{long_pack_scan}),
    );
}

test "DECLARE_RUNNERS: row selection — lua + ruby rows with their step/tool/extension; non-listed languages have none" {
    const lua = declareRunner("lua").?;
    try testing.expectEqualStrings("labelle-declare", lua.step_name);
    try testing.expectEqualStrings("tools/declare", lua.tool_dir);
    try testing.expectEqualStrings(".lua", lua.extension);
    try testing.expectEqualStrings("0.2.0", lua.min_pin);
    // `Labelle.event`/`Labelle.id` shipped in scripting v0.10.0 for BOTH
    // rows (one release, one contract — labelle-engine#772 slice 1).
    try testing.expectEqualStrings("0.10.0", lua.events_min_pin);

    // ruby (labelle-scripting PR #21 / v0.9.0): its OWN exe + step so the
    // capability probe stays per-row filesystem presence and a unified
    // exe never compiles both VMs into every generate.
    const ruby = declareRunner("ruby").?;
    try testing.expectEqualStrings("labelle-declare-ruby", ruby.step_name);
    try testing.expectEqualStrings("tools/declare-ruby", ruby.tool_dir);
    try testing.expectEqualStrings(".rb", ruby.extension);
    try testing.expectEqualStrings("0.9.0", ruby.min_pin);
    try testing.expectEqualStrings("0.10.0", ruby.events_min_pin);

    // Non-listed languages: runPhase's pointed skip (typescript's
    // declarations arrive later via a d.ts-side runner; go/csharp have no
    // scripting integration rows at all).
    try testing.expect(declareRunner("typescript") == null);
    try testing.expect(declareRunner("go") == null);
    try testing.expect(declareRunner("cobol") == null);

    // Distinct step names + tool dirs across rows (two rows share one
    // plugin package and one install prefix — collisions would alias the
    // built binaries and the capability probes).
    for (DECLARE_RUNNERS, 0..) |a, i| {
        for (DECLARE_RUNNERS[i + 1 ..]) |b| {
            try testing.expect(!std.mem.eql(u8, a.step_name, b.step_name));
            try testing.expect(!std.mem.eql(u8, a.tool_dir, b.tool_dir));
            try testing.expect(!std.mem.eql(u8, a.extension, b.extension));
        }
    }
}

test "runPhase: a splice without a runner row (typescript) skips cleanly — null, stale file dropped, tool machinery untouched" {
    const allocator = testing.allocator;
    const tio = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    // A stale generated file from a previous declaring project state: the
    // skip must clean it up exactly like the other no-op shapes.
    try tmp.dir.createDirPath(tio, "target");
    {
        var f = try tmp.dir.createFile(tio, "target/" ++ GENERATED_FILENAME, .{});
        defer f.close(tio);
        try f.writeStreamingAll(tio, "pub const Stale = struct {};\n");
    }
    const root = try tmp.dir.realPathFileAlloc(tio, ".", allocator);
    defer allocator.free(root);
    const target = try tmp.dir.realPathFileAlloc(tio, "target", allocator);
    defer allocator.free(target);

    // Deliberately hostile opts: an EMPTY plugin list, no override, no
    // staged deps — every step past the gate would error. typescript has
    // neither a hardcoded `DECLARE_RUNNERS` row NOR a `.languages` declare
    // row it could reach here (the generic probe's package resolution +
    // manifest load fall through as `.not_applicable` on this degenerate
    // setup), so it returns null without spawning any tool over .js.
    var opts = PhaseOptions{
        .plugins = &.{},
        .plugin_name = "scripting",
        .language = "typescript",
        .script_files = &.{"scripts/behavior.js"},
        .output_dir = root,
        .target_dir = target,
        .project_dir = root,
        .component_names = &.{},
        .pack_scans = &.{},
    };
    try testing.expect((try runPhase(allocator, opts)) == null);
    try testing.expectError(
        error.FileNotFound,
        tmp.dir.access(tio, "target/" ++ GENERATED_FILENAME, .{}),
    );

    // Negative controls: the SAME opts with a FROZEN-TABLE language reach
    // the tool machinery and error. With no staged package the generic path
    // falls through as `.not_applicable` (nothing to resolve), so dispatch
    // lands on the `DECLARE_RUNNERS` fallback, whose package resolution then
    // fails on the empty plugin list — the typescript skip above is the
    // no-row outcome, not an accident of the hostile opts. Both rows, so
    // ruby's selection is pinned end-to-start too.
    opts.language = "lua";
    opts.script_files = &.{"scripts/behavior.lua"};
    try testing.expectError(error.DeclareToolBuildFailed, runPhase(allocator, opts));
    opts.language = "ruby";
    opts.script_files = &.{"components/hunger.rb"};
    try testing.expectError(error.DeclareToolBuildFailed, runPhase(allocator, opts));
}

test "DECLARE_RUNNERS: per-row capability probe — the ruby tool dir arms ruby only; lua stays gated by tools/declare" {
    // ensureDeclareTool's probe is filesystem presence of the ROW's
    // tool_dir. A package shipping ONLY tools/declare-ruby (hypothetical
    // future pin shape) must not arm the lua runner, and vice versa —
    // exercised through runPhase against a staged package dir, stopping
    // at the step AFTER the probe (the `zig build` spawn fails in this
    // build.zig-less fixture, proving the probe PASSED; DeclareToolAbsent
    // proving it failed).
    const allocator = testing.allocator;
    const tio = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    // Stage the package where resolvePluginPackageDir looks first: the
    // output's deps copy (out/deps/labelle-scripting).
    try tmp.dir.createDirPath(tio, "out/deps/labelle-scripting/tools/declare-ruby");
    try tmp.dir.createDirPath(tio, "target");
    const root = try tmp.dir.realPathFileAlloc(tio, ".", allocator);
    defer allocator.free(root);
    const out = try tmp.dir.realPathFileAlloc(tio, "out", allocator);
    defer allocator.free(out);
    const target = try tmp.dir.realPathFileAlloc(tio, "target", allocator);
    defer allocator.free(target);

    var opts = PhaseOptions{
        .plugins = &.{},
        .plugin_name = "scripting",
        .language = "ruby",
        .script_files = &.{"components/hunger.rb"},
        .output_dir = out,
        .target_dir = target,
        .project_dir = root,
        .component_names = &.{},
        .pack_scans = &.{},
    };
    // ruby: probe PASSES (tools/declare-ruby exists) → the build attempt
    // is next, and fails in this build.zig-less package. NOT a skip.
    try testing.expectError(error.DeclareToolBuildFailed, runPhase(allocator, opts));

    // lua against the SAME package: tools/declare is absent → graceful
    // skip (null), exactly the old-pin path.
    opts.language = "lua";
    opts.script_files = &.{"scripts/behavior.lua"};
    try testing.expect((try runPhase(allocator, opts)) == null);
}

// ── Events (labelle-engine#772) ──────────────────────────────────────

/// The cross-runner golden's events shape (labelle-scripting PR #25,
/// v0.10.0): fields tool-sorted, u64 from `Labelle.id`, a payloadless
/// event, NO persist key.
const events_schema =
    \\{"components":[{"name":"Hunger","persist":"persistent","fields":[
    \\   {"name":"level","type":"f32","default":0.875},
    \\   {"name":"owner","type":"u64","default":0}]}],
    \\ "events":[
    \\   {"name":"hunger__feed","fields":[
    \\     {"name":"amount","type":"f32","default":0.5},
    \\     {"name":"at","type":"vec2","default":{"x":-1.5,"y":3}},
    \\     {"name":"entity","type":"u64","default":0},
    \\     {"name":"reason","type":"str","default":"why \"now\""},
    \\     {"name":"urgent","type":"bool","default":false}]},
    \\   {"name":"wave__spawned","fields":[]}]}
;

test "parseSchema: the v0.10.0 events array parses — u64 (Labelle.id) lands in components AND events; absent key is empty" {
    var schema = try parseSchema(testing.allocator, events_schema);
    defer schema.deinit();

    // u64 in a COMPONENT field (Labelle.id is legal there too — without
    // the FieldType row, every v0.10.0 component schema carrying it
    // would fail generate).
    try testing.expectEqual(@as(usize, 1), schema.components.len);
    try testing.expectEqual(@as(u64, 0), schema.components[0].fields[1].default.u64);
    try testing.expectEqualStrings("u64", zigFieldTypeName(schema.components[0].fields[1].default));

    try testing.expectEqual(@as(usize, 2), schema.events.len);
    const feed = schema.events[0];
    try testing.expectEqualStrings("hunger__feed", feed.name);
    try testing.expectEqual(@as(usize, 5), feed.fields.len);
    try testing.expectEqualStrings("amount", feed.fields[0].name);
    try testing.expectEqual(@as(f64, 0.5), feed.fields[0].default.f32);
    try testing.expectEqual(@as(u64, 0), feed.fields[2].default.u64);
    try testing.expectEqualStrings("why \"now\"", feed.fields[3].default.str);
    // Payloadless event: legal (a pure signal).
    try testing.expectEqualStrings("wave__spawned", schema.events[1].name);
    try testing.expectEqual(@as(usize, 0), schema.events[1].fields.len);

    // Absent "events" key (every pre-v0.10.0 schema) → empty, no error.
    var old = try parseSchema(testing.allocator, example_schema);
    defer old.deinit();
    try testing.expectEqual(@as(usize, 0), old.events.len);
}

test "parseSchema: event rejections — dups, bad names, keyword names, Pascal fold-collisions, reserved Vec2" {
    const bad_cases = [_][]const u8{
        // Duplicate event names.
        \\{"components":[],"events":[{"name":"hit","fields":[]},{"name":"hit","fields":[]}]}
        ,
        // Not an identifier.
        \\{"components":[],"events":[{"name":"has space","fields":[]}]}
        ,
        // Zig keyword as the union variant.
        \\{"components":[],"events":[{"name":"error","fields":[]}]}
        ,
        // Zig primitive.
        \\{"components":[],"events":[{"name":"u32","fields":[]}]}
        ,
        // Pascal fold-collision: a__b and a_b both render `pub const AB`.
        \\{"components":[],"events":[{"name":"a__b","fields":[]},{"name":"a_b","fields":[]}]}
        ,
        // Pascal lands on the reserved Vec2 backing decl.
        \\{"components":[],"events":[{"name":"vec_2","fields":[]}]}
        ,
        // All-underscore name → empty Pascal (no struct name).
        \\{"components":[],"events":[{"name":"__","fields":[]}]}
        ,
        // Event field named a keyword.
        \\{"components":[],"events":[{"name":"hit","fields":[{"name":"error","type":"i32","default":0}]}]}
        ,
        // Event field u64 default must be a non-negative integer.
        \\{"components":[],"events":[{"name":"hit","fields":[{"name":"who","type":"u64","default":-1}]}]}
        ,
        // "events" must be an array.
        \\{"components":[],"events":{}}
        ,
        // Duplicate event FIELDS.
        \\{"components":[],"events":[{"name":"hit","fields":[{"name":"x","type":"i32","default":1},{"name":"x","type":"i32","default":2}]}]}
        ,
    };
    for (bad_cases) |case| {
        try testing.expectError(error.ScriptSchemaInvalid, parseSchema(testing.allocator, case));
    }

    // Controls: an event may share a COMPONENT's name (separate
    // namespaces — the ticket's contract), and an event field may spell
    // `save` (events render no member decls, unlike components).
    var schema = try parseSchema(testing.allocator,
        \\{"components":[{"name":"Hunger","fields":[]}],
        \\ "events":[{"name":"Hunger","fields":[{"name":"save","type":"bool","default":false}]}]}
    );
    schema.deinit();
}

test "renderEventsFile: golden (ticket example, fields tool-sorted) + payloadless + vec2 backing + AstGen" {
    var schema = try parseSchema(testing.allocator, events_schema);
    defer schema.deinit();

    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    try renderEventsFile(schema.events, &aw.writer);
    const got = aw.writer.buffered();

    // The ticket's event, byte-exact rows: plain struct, NO Saveable
    // (events are never saved), u64 id field, escaped str default.
    try testing.expect(std.mem.indexOf(u8, got, "pub const HungerFeed = struct {\n" ++
        "    amount: f32 = 0.5,\n" ++
        "    at: Vec2 = .{ .x = -1.5, .y = 3 },\n" ++
        "    entity: u64 = 0,\n" ++
        "    reason: []const u8 = \"why \\\"now\\\"\",\n" ++
        "    urgent: bool = false,\n" ++
        "};\n") != null);
    try testing.expect(std.mem.indexOf(u8, got, "Saveable") == null);
    // Payloadless event → the one-line empty struct zig fmt writes.
    try testing.expect(std.mem.indexOf(u8, got, "pub const WaveSpawned = struct {};\n") != null);
    // vec2 fields ride the emitted-once backing struct.
    try testing.expect(std.mem.indexOf(u8, got, "pub const Vec2 = struct { x: f32 = 0, y: f32 = 0 };") != null);
    try expectAstGenOk(got);

    // No vec2 anywhere → no backing decl (the emission stays minimal).
    var lean = try parseSchema(testing.allocator,
        \\{"components":[],"events":[{"name":"ping","fields":[{"name":"n","type":"u32","default":1}]}]}
    );
    defer lean.deinit();
    var lean_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer lean_aw.deinit();
    try renderEventsFile(lean.events, &lean_aw.writer);
    try testing.expect(std.mem.indexOf(u8, lean_aw.writer.buffered(), "Vec2") == null);
    try expectAstGenOk(lean_aw.writer.buffered());
}

test "renderComponentsFile: a u64 (Labelle.id) component field renders `u64 = <default>` + AstGen" {
    var schema = try parseSchema(testing.allocator,
        \\{"components":[{"name":"Ship","fields":[{"name":"pilot","type":"u64","default":7}]}]}
    );
    defer schema.deinit();
    const got = try renderForTest(schema.components);
    defer testing.allocator.free(got);
    try testing.expect(std.mem.indexOf(u8, got, "    pilot: u64 = 7,\n") != null);
    // Unlike `entity`, a plain u64 is NOT an entity ref — no save remap.
    try testing.expect(std.mem.indexOf(u8, got, "entity_refs") == null);
    try expectAstGenOk(got);
}

test "checkEventCollisions: game events (variant = file basename) and pack events gate; components don't" {
    const declared = [_]DeclaredEvent{
        .{ .name = "hunger__feed", .fields = &.{} },
    };
    // Clean set: no collision.
    try checkEventCollisions(&declared, &.{ "door_opened", "combat/hit" }, &.{});
    // Game events/hunger__feed.zig — same variant name.
    try testing.expectError(
        error.ScriptEventCollision,
        checkEventCollisions(&declared, &.{"hunger__feed"}, &.{}),
    );
    // Subdir stems collide on their BASENAME (that's the variant the
    // union emits — `writeEventImportsBlock`'s eventVariantName).
    try testing.expectError(
        error.ScriptEventCollision,
        checkEventCollisions(&declared, &.{"gameplay/hunger__feed"}, &.{}),
    );
    // Pack event: citizens pack's feed.zig → citizens__feed.
    const packish = [_]DeclaredEvent{
        .{ .name = "citizens__feed", .fields = &.{} },
    };
    const pack = scan.PackScan{
        .name = "citizens",
        .import_prefix = "packs/citizens",
        .component_names = &.{},
        .event_names = &.{"feed"},
        .prefab_names = &.{},
    };
    try testing.expectError(
        error.ScriptEventCollision,
        checkEventCollisions(&packish, &.{}, &.{pack}),
    );
    // An event sharing a COMPONENT's registry name is legal — different
    // namespaces; `checkEventCollisions` never sees component names.
    try checkEventCollisions(&declared, &.{}, &.{pack});

    // Pathologically long names: `<pack>__<variant>` at 302 bytes — past
    // the old 280-byte format buffer whose overflow `catch continue`d,
    // silently SKIPPING the collision (PR #618 review; reachable because
    // the event variant is an unbounded slice of the stem). The slice-wise
    // compare has no length ceiling, so the gate still fires.
    const long_pack = "p" ** 100;
    const long_stem = "e" ** 200;
    const long_declared = [_]DeclaredEvent{
        .{ .name = long_pack ++ "__" ++ long_stem, .fields = &.{} },
    };
    const long_pack_scan = scan.PackScan{
        .name = long_pack,
        .import_prefix = "packs/" ++ long_pack,
        .component_names = &.{},
        .event_names = &.{long_stem},
        .prefab_names = &.{},
    };
    try testing.expectError(
        error.ScriptEventCollision,
        checkEventCollisions(&long_declared, &.{}, &.{long_pack_scan}),
    );
    // Same-length near miss (last byte differs) passes — the slice logic
    // matches exactly, it doesn't over-match on the pack prefix.
    const long_near_miss = [_]DeclaredEvent{
        .{ .name = long_pack ++ "__" ++ ("e" ** 199) ++ "x", .fields = &.{} },
    };
    try checkEventCollisions(&long_near_miss, &.{}, &.{long_pack_scan});
}

test "checkEventPluginCollisions: a declared event spelling a plugin's qualified tag gates (incl. engine + sanitized names); near misses pass" {
    // Entries shaped exactly like `discoverPluginEvents` builds them —
    // the same literal constructor the manifest plugin_events tests use.
    const entries = [_]scan.PluginEvent{
        .{ .plugin_import_name = "box2d", .plugin_sanitized = "box2d", .event_name = "collision_begin" },
        .{ .plugin_import_name = "labelle-physics", .plugin_sanitized = "labelle_physics", .event_name = "impact" },
        .{ .plugin_import_name = "engine", .plugin_sanitized = "engine", .event_name = "tick" },
    };

    // The motivating case: the declared name IS the plugin union tag —
    // without this gate it only explodes inside MergeHookPayloads'
    // comptime duplicate-field check in the generated main.zig.
    const declared = [_]DeclaredEvent{
        .{ .name = "box2d__collision_begin", .fields = &.{} },
    };
    try testing.expectError(
        error.ScriptEventPluginCollision,
        checkEventPluginCollisions(&declared, &entries),
    );
    // Hyphenated plugin: the tag uses the SANITIZED prefix.
    const sanitized = [_]DeclaredEvent{
        .{ .name = "labelle_physics__impact", .fields = &.{} },
    };
    try testing.expectError(
        error.ScriptEventPluginCollision,
        checkEventPluginCollisions(&sanitized, &entries),
    );
    // Engine events are discovered alongside plugins (labelle-engine#578)
    // and gate identically.
    const engineish = [_]DeclaredEvent{
        .{ .name = "engine__tick", .fields = &.{} },
    };
    try testing.expectError(
        error.ScriptEventPluginCollision,
        checkEventPluginCollisions(&engineish, &entries),
    );

    // Near misses all pass: the bare event name, a single-underscore
    // join, a prefix-only truncation, and a different plugin prefix.
    const clean = [_]DeclaredEvent{
        .{ .name = "collision_begin", .fields = &.{} },
        .{ .name = "box2d_collision_begin", .fields = &.{} },
        .{ .name = "box2d__collision", .fields = &.{} },
        .{ .name = "box3d__collision_begin", .fields = &.{} },
    };
    try checkEventPluginCollisions(&clean, &entries);
    // No plugin events discovered → nothing can collide.
    try checkEventPluginCollisions(&declared, &.{});
}

test "checkGameEventPluginCollisions: a game/pack event spelling a plugin tag gates BEFORE the #630 filter; near misses pass" {
    const entries = [_]scan.PluginEvent{
        .{ .plugin_import_name = "box2d", .plugin_sanitized = "box2d", .event_name = "collision_begin" },
        .{ .plugin_import_name = "engine", .plugin_sanitized = "engine", .event_name = "tick" },
    };

    // The motivating case (#631 codex): `events/box2d__collision_begin.zig`
    // — with no consumer anywhere the plugin entry would be elided and
    // the collision silently vanish; this gate fires on the FULL list.
    try testing.expectError(
        error.GameEventPluginCollision,
        checkGameEventPluginCollisions(&.{"box2d__collision_begin"}, &.{}, &entries),
    );
    // Engine tags gate identically, and a subdir stem's variant
    // (`eventVariantName` = basename slice) is what's compared.
    try testing.expectError(
        error.GameEventPluginCollision,
        checkGameEventPluginCollisions(&.{"combat/engine__tick"}, &.{}, &entries),
    );

    // Pack event whose namespaced variant spells the tag: a pack that
    // sanitizes to `box2d` shipping `collision_begin.zig` produces the
    // exact `box2d__collision_begin` union variant.
    const pack = scan.PackScan{
        .name = "box2d",
        .import_prefix = "packs/box2d",
        .component_names = &.{},
        .event_names = &.{"collision_begin"},
        .prefab_names = &.{},
    };
    try testing.expectError(
        error.GameEventPluginCollision,
        checkGameEventPluginCollisions(&.{}, &.{pack}, &entries),
    );

    // Misaligned `__` join (virtual-concat comparator): pack `box2d__x`
    // + event `y` spells `box2d__x__y`, the same variant as a plugin
    // `box2d` event `x__y` — component-wise comparison would miss it.
    const misaligned_entries = [_]scan.PluginEvent{
        .{ .plugin_import_name = "box2d", .plugin_sanitized = "box2d", .event_name = "x__y" },
    };
    const misaligned_pack = scan.PackScan{
        .name = "box2d__x",
        .import_prefix = "packs/box2d__x",
        .component_names = &.{},
        .event_names = &.{"y"},
        .prefab_names = &.{},
    };
    try testing.expectError(
        error.GameEventPluginCollision,
        checkGameEventPluginCollisions(&.{}, &.{misaligned_pack}, &misaligned_entries),
    );

    // Near misses pass: bare name, single-underscore join, truncation,
    // different prefix, and a pack with a same-name EVENT under a
    // different pack prefix.
    try checkGameEventPluginCollisions(&.{ "collision_begin", "box2d_collision_begin", "box2d__collision", "box3d__collision_begin" }, &.{}, &entries);
    const other_pack = scan.PackScan{
        .name = "physics",
        .import_prefix = "packs/physics",
        .component_names = &.{},
        .event_names = &.{"collision_begin"},
        .prefab_names = &.{},
    };
    try checkGameEventPluginCollisions(&.{}, &.{other_pack}, &entries);
    // Empty discovery → nothing can collide.
    try checkGameEventPluginCollisions(&.{"box2d__collision_begin"}, &.{}, &.{});
}

test "checkDuplicatePluginTags: sanitized-name collisions on the same event gate; distinct prefixes with the same event pass" {
    // The motivating pair (#631 codex): `foo-bar` and `foo_bar` both
    // sanitize to `foo_bar`, both declare `hit` → identical qualified
    // tag `foo_bar__hit`. Under filtering, one consumed dotted form
    // would keep one entry and silently elide the other.
    const colliding = [_]scan.PluginEvent{
        .{ .plugin_import_name = "foo-bar", .plugin_sanitized = "foo_bar", .event_name = "hit" },
        .{ .plugin_import_name = "foo_bar", .plugin_sanitized = "foo_bar", .event_name = "hit" },
    };
    try testing.expectError(
        error.DuplicatePluginEventTag,
        checkDuplicatePluginTags(&colliding),
    );

    // Misaligned `__` join: plugin `foo` event `bar__hit` vs plugin
    // `foo-bar` event `hit` — both spell `foo__bar__hit`. The
    // virtual-concat comparator catches what a component-wise compare
    // would miss.
    const misaligned = [_]scan.PluginEvent{
        .{ .plugin_import_name = "foo", .plugin_sanitized = "foo", .event_name = "bar__hit" },
        .{ .plugin_import_name = "foo-bar", .plugin_sanitized = "foo__bar", .event_name = "hit" },
    };
    try testing.expectError(
        error.DuplicatePluginEventTag,
        checkDuplicatePluginTags(&misaligned),
    );

    // Same EVENT name under distinct sanitized prefixes is the normal,
    // legal shape (box2d.hit + physics.hit) — no gate.
    const distinct = [_]scan.PluginEvent{
        .{ .plugin_import_name = "box2d", .plugin_sanitized = "box2d", .event_name = "hit" },
        .{ .plugin_import_name = "physics", .plugin_sanitized = "physics", .event_name = "hit" },
        .{ .plugin_import_name = "box2d", .plugin_sanitized = "box2d", .event_name = "miss" },
    };
    try checkDuplicatePluginTags(&distinct);
    // Empty / single-entry lists trivially pass.
    try checkDuplicatePluginTags(&.{});
}

test "semverBelow: parseable pins compare against the floor; local/branch/empty pins satisfy it" {
    try testing.expect(semverBelow("0.9.0", "0.10.0"));
    try testing.expect(semverBelow("0.9.9", "0.10.0"));
    try testing.expect(!semverBelow("0.10.0", "0.10.0"));
    try testing.expect(!semverBelow("0.11.2", "0.10.0"));
    try testing.expect(!semverBelow("1.0.0", "0.10.0"));
    // Unparseable pins (branch refs, the empty registry default) never
    // trip the floor — the capability probes stay the authority, exactly
    // like `min_pin`.
    try testing.expect(!semverBelow("main", "0.10.0"));
    try testing.expect(!semverBelow("", "0.10.0"));
}

test "runPhase events gates: no-runner language and below-floor pins are HARD errors naming the files; floor pins pass the gate" {
    const allocator = testing.allocator;
    const tio = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    // Stage the package where resolvePluginPackageDir looks first so the
    // at-floor CONTROL below sails past the gate into the tool machinery
    // (probe passes, the build fails in this build.zig-less fixture).
    try tmp.dir.createDirPath(tio, "out/deps/labelle-scripting/tools/declare-ruby");
    try tmp.dir.createDirPath(tio, "target");
    const root = try tmp.dir.realPathFileAlloc(tio, ".", allocator);
    defer allocator.free(root);
    const out = try tmp.dir.realPathFileAlloc(tio, "out", allocator);
    defer allocator.free(out);
    const target = try tmp.dir.realPathFileAlloc(tio, "target", allocator);
    defer allocator.free(target);

    const old_pin = [_]config.PluginDep{
        .{ .name = "scripting", .repo = "github.com/labelle-toolkit/labelle-scripting", .version = "0.9.0" },
    };
    var opts = PhaseOptions{
        .plugins = &old_pin,
        .plugin_name = "scripting",
        .language = "ruby",
        .script_files = &.{"events/hunger__feed.rb"},
        .event_files = &.{"events/hunger__feed.rb"},
        .output_dir = out,
        .target_dir = target,
        .project_dir = root,
        .component_names = &.{},
        .pack_scans = &.{},
    };
    // Below the 0.10.0 floor → pointed error BEFORE any tool machinery
    // (the staged package above is never consulted — a build attempt
    // would have failed with DeclareToolBuildFailed instead).
    try testing.expectError(error.ScriptEventsPinTooOld, runPhase(allocator, opts));

    // At the floor → the gate passes and the phase proceeds into the
    // tool build (which fails in this build.zig-less fixture) — proving
    // the error above came from the version gate, not the machinery.
    const floor_pin = [_]config.PluginDep{
        .{ .name = "scripting", .repo = "github.com/labelle-toolkit/labelle-scripting", .version = "0.10.0" },
    };
    opts.plugins = &floor_pin;
    try testing.expectError(error.DeclareToolBuildFailed, runPhase(allocator, opts));

    // A LOCAL pin satisfies the floor the same way (the tree is the
    // authority): same downstream DeclareToolBuildFailed, never the
    // pin error.
    const local_pin = [_]config.PluginDep{
        .{ .name = "scripting", .repo = "local:../labelle-scripting", .version = "0.9.0" },
    };
    opts.plugins = &local_pin;
    try testing.expectError(error.DeclareToolBuildFailed, runPhase(allocator, opts));

    // The whole tool dir absent (pin < 0.9.0 shapes) — the components
    // path degrades to a skip, but events files make it the SAME hard
    // pin error (an events/*.rb can never work on that pin).
    const lua_absent = [_]config.PluginDep{
        .{ .name = "scripting", .repo = "local:../labelle-scripting" },
    };
    opts.plugins = &lua_absent;
    opts.language = "lua";
    opts.script_files = &.{"events/hunger__feed.lua"};
    opts.event_files = &.{"events/hunger__feed.lua"};
    try testing.expectError(error.ScriptEventsPinTooOld, runPhase(allocator, opts));

    // No runner row at all (typescript): events files are a pointed
    // UNSUPPORTED error, not the components-style silent skip.
    opts.language = "typescript";
    opts.script_files = &.{"events/hunger__feed.js"};
    opts.event_files = &.{"events/hunger__feed.js"};
    try testing.expectError(error.ScriptEventsUnsupported, runPhase(allocator, opts));
}

/// Write a fake declare tool (a POSIX sh script echoing `schema_json`)
/// and return its absolute path. CI runs ubuntu+macos only — the same
/// posture as the transpile tests' `#!/bin/sh` fixtures.
fn writeFakeDeclareTool(
    allocator: std.mem.Allocator,
    tmp: *testing.TmpDir,
    schema_json: []const u8,
) ![]const u8 {
    const tio = testing.io;
    {
        var f = try tmp.dir.createFile(tio, "fake-declare.sh", .{});
        defer f.close(tio);
        var buf: [2048]u8 = undefined;
        const body = try std.fmt.bufPrint(&buf, "#!/bin/sh\nprintf '%s' '{s}'\n", .{schema_json});
        try f.writeStreamingAll(tio, body);
        try f.setPermissions(tio, .executable_file);
    }
    // realPathFileAlloc returns [:0]u8 — dupe to plain []u8 so the caller
    // can `allocator.free` without the sentinel-byte size mismatch (the
    // `resolveLocalPath` precedent).
    const p = try tmp.dir.realPathFileAlloc(tio, "fake-declare.sh", allocator);
    defer allocator.free(p);
    return allocator.dupe(u8, p);
}

test "runPhase: events-dir files that declare NO events are a pointed error (fake tool, components-only schema)" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const allocator = testing.allocator;
    const tio = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(tio, "target");
    const root = try tmp.dir.realPathFileAlloc(tio, ".", allocator);
    defer allocator.free(root);
    const target = try tmp.dir.realPathFileAlloc(tio, "target", allocator);
    defer allocator.free(target);

    const tool = try writeFakeDeclareTool(allocator, &tmp, "{\"components\":[]}");
    defer allocator.free(tool);
    declare_tool_override = tool;
    defer declare_tool_override = null;

    const local_pin = [_]config.PluginDep{
        .{ .name = "scripting", .repo = "local:../labelle-scripting" },
    };
    const opts = PhaseOptions{
        .plugins = &local_pin,
        .plugin_name = "scripting",
        .language = "ruby",
        .script_files = &.{"events/empty.rb"},
        .event_files = &.{"events/empty.rb"},
        .output_dir = root,
        .target_dir = target,
        .project_dir = root,
        .component_names = &.{},
        .pack_scans = &.{},
    };
    try testing.expectError(error.ScriptEventsNoneDeclared, runPhase(allocator, opts));
}

test "runPhase: the generic .languages path declares for rust (staged manifest row + fake tool, hash-skip cache written)" {
    // The rev-17 native declare lane (rust #774): a language ABSENT from the
    // hardcoded DECLARE_RUNNERS table declares via the resolved plugin
    // manifest's `.languages` capability row. Drives the whole generic path —
    // manifest load → row + `.declare` capability → tool (the override seam
    // stands in for `zig build labelle-declare-rs`) → hash-and-skip → exec →
    // the SHARED finalize tail rendering scripting_components.zig.
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const allocator = testing.allocator;
    const tio = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(tio, "target/components");

    // A STAGED plugin package (what resolvePluginPackageDir finds first,
    // <output>/deps/labelle-<name>) carrying the rust `.languages` row.
    try tmp.dir.createDirPath(tio, "deps/labelle-scripting");
    {
        var f = try tmp.dir.createFile(tio, "deps/labelle-scripting/plugin.labelle", .{});
        defer f.close(tio);
        try f.writeStreamingAll(tio,
            \\.{
            \\    .name = "scripting",
            \\    .manifest_version = 1,
            \\    .languages = .{
            \\        .{ .name = "rust", .extensions = .{"rs"}, .kind = .native,
            \\           .module_root = "mod.rs",
            \\           .declare = .{ .tool = "labelle-declare-rs", .dir = "tools/declare-rs", .events = true } },
            \\    },
            \\}
        );
    }
    // A declaration file — the input hash reads it (the fake tool ignores
    // argv and prints a fixed schema).
    {
        var f = try tmp.dir.createFile(tio, "target/components/hunger.rs", .{});
        defer f.close(tio);
        try f.writeStreamingAll(tio, "labelle::component! { Hunger { level: f32 = 0.5 } }\n");
    }

    const root = try tmp.dir.realPathFileAlloc(tio, ".", allocator);
    defer allocator.free(root);
    const target = try tmp.dir.realPathFileAlloc(tio, "target", allocator);
    defer allocator.free(target);

    const tool = try writeFakeDeclareTool(
        allocator,
        &tmp,
        "{\"components\":[{\"name\":\"Hunger\",\"persist\":\"persistent\",\"fields\":[{\"name\":\"level\",\"type\":\"f32\",\"default\":0.5}]}]}",
    );
    defer allocator.free(tool);
    declare_tool_override = tool;
    defer declare_tool_override = null;

    const local_pin = [_]config.PluginDep{
        .{ .name = "scripting", .repo = "local:../labelle-scripting" },
    };
    const opts = PhaseOptions{
        .plugins = &local_pin,
        .plugin_name = "scripting",
        .language = "rust",
        .script_files = &.{"components/hunger.rs"},
        .output_dir = root,
        .target_dir = target,
        .project_dir = root,
        .component_names = &.{},
        .pack_scans = &.{},
    };

    var schema = (try runPhase(allocator, opts)) orelse return error.TestExpectedSchema;
    defer schema.deinit();
    try testing.expectEqual(@as(usize, 1), schema.components.len);
    try testing.expectEqualStrings("Hunger", schema.components[0].name);

    // The SHARED finalize tail rendered the components file at the target root.
    const generated = try tmp.dir.readFileAlloc(tio, "target/" ++ GENERATED_FILENAME, allocator, .limited(1 << 20));
    defer allocator.free(generated);
    try testing.expect(std.mem.indexOf(u8, generated, "Hunger") != null);

    // Hash-and-skip: the tool's raw JSON + the input digest were cached under
    // the persistent <output>/declare-tool/<tool>-cache/.assembler-skip.
    try tmp.dir.access(tio, "declare-tool/labelle-declare-rs-cache/.assembler-skip/schema.json", .{});
    try tmp.dir.access(tio, "declare-tool/labelle-declare-rs-cache/.assembler-skip/inputs.sha256", .{});
}

test "runPhase: the #619 dispatch flip — a FROZEN-TABLE language (lua) prefers its `.languages` row over DECLARE_RUNNERS" {
    // The declare slice's dispatch flip: lua/ruby are still in the frozen
    // `DECLARE_RUNNERS` table (the fallback for pins predating `.languages`),
    // but a resolved manifest that carries a lua `.languages` declare row now
    // wins — `runPhase` tries the generic path FIRST for every language, not
    // only those absent from the table. Proven by the artifact ONLY the
    // generic path leaves: the persistent `<output>/declare-tool/<tool>-cache`
    // (the rev-17 `--cache-dir`). The table path (`runDeclareTool`) passes no
    // cache dir and writes nothing there, so its presence pins that lua took
    // the generic branch — the flip, not the fallback.
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const allocator = testing.allocator;
    const tio = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(tio, "target/components");

    // A staged package carrying the EMBEDDED lua row (same `.declare` shape a
    // native language uses — the whole point of the migration).
    try tmp.dir.createDirPath(tio, "deps/labelle-scripting");
    {
        var f = try tmp.dir.createFile(tio, "deps/labelle-scripting/plugin.labelle", .{});
        defer f.close(tio);
        try f.writeStreamingAll(tio,
            \\.{
            \\    .name = "scripting",
            \\    .manifest_version = 1,
            \\    .languages = .{
            \\        .{ .name = "lua", .extensions = .{"lua"}, .kind = .embedded,
            \\           .declare = .{ .tool = "labelle-declare", .dir = "tools/declare", .events = true } },
            \\    },
            \\}
        );
    }
    {
        var f = try tmp.dir.createFile(tio, "target/components/hunger.lua", .{});
        defer f.close(tio);
        try f.writeStreamingAll(tio, "labelle.component(\"Hunger\", { level = 0.5 })\n");
    }

    const root = try tmp.dir.realPathFileAlloc(tio, ".", allocator);
    defer allocator.free(root);
    const target = try tmp.dir.realPathFileAlloc(tio, "target", allocator);
    defer allocator.free(target);

    const tool = try writeFakeDeclareTool(
        allocator,
        &tmp,
        "{\"components\":[{\"name\":\"Hunger\",\"persist\":\"persistent\",\"fields\":[{\"name\":\"level\",\"type\":\"f32\",\"default\":0.5}]}]}",
    );
    defer allocator.free(tool);
    declare_tool_override = tool;
    defer declare_tool_override = null;

    const local_pin = [_]config.PluginDep{
        .{ .name = "scripting", .repo = "local:../labelle-scripting" },
    };
    const opts = PhaseOptions{
        .plugins = &local_pin,
        .plugin_name = "scripting",
        .language = "lua",
        .script_files = &.{"components/hunger.lua"},
        .output_dir = root,
        .target_dir = target,
        .project_dir = root,
        .component_names = &.{},
        .pack_scans = &.{},
    };

    var schema = (try runPhase(allocator, opts)) orelse return error.TestExpectedSchema;
    defer schema.deinit();
    try testing.expectEqual(@as(usize, 1), schema.components.len);
    try testing.expectEqualStrings("Hunger", schema.components[0].name);

    // The GENERIC path's tell: the persistent per-project cache dir, named
    // after the lua tool. The table path never creates it.
    try tmp.dir.access(tio, "declare-tool/labelle-declare-cache/.assembler-skip/schema.json", .{});
    try tmp.dir.access(tio, "declare-tool/labelle-declare-cache/.assembler-skip/inputs.sha256", .{});
}

test "runPhase: the generic skip cache invalidates when the declare TOOL changes (codex #622 — no stale schema on a plugin bump)" {
    // The skip cache is keyed on the tool binary's bytes + the declaration
    // inputs. A scripting pin bump ships a DIFFERENT declare tool that can
    // yield a different schema for byte-identical declaration files; the
    // cache must NOT reuse the old schema.json. Modelled by rewriting the
    // (override) tool between two generates with UNCHANGED inputs: run 1
    // caches schema X, run 2's tool emits schema Y, and run 2 must return Y.
    // Without the tool identity in the skip key this test returns X (stale).
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const allocator = testing.allocator;
    const tio = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(tio, "target/components");
    try tmp.dir.createDirPath(tio, "deps/labelle-scripting");
    {
        var f = try tmp.dir.createFile(tio, "deps/labelle-scripting/plugin.labelle", .{});
        defer f.close(tio);
        try f.writeStreamingAll(tio,
            \\.{
            \\    .name = "scripting",
            \\    .manifest_version = 1,
            \\    .languages = .{
            \\        .{ .name = "rust", .extensions = .{"rs"}, .kind = .native,
            \\           .module_root = "mod.rs",
            \\           .declare = .{ .tool = "labelle-declare-rs", .dir = "tools/declare-rs", .events = true } },
            \\    },
            \\}
        );
    }
    {
        var f = try tmp.dir.createFile(tio, "target/components/hunger.rs", .{});
        defer f.close(tio);
        try f.writeStreamingAll(tio, "labelle::component! { Hunger { level: f32 = 0.5 } }\n");
    }
    const root = try tmp.dir.realPathFileAlloc(tio, ".", allocator);
    defer allocator.free(root);
    const target = try tmp.dir.realPathFileAlloc(tio, "target", allocator);
    defer allocator.free(target);

    const local_pin = [_]config.PluginDep{
        .{ .name = "scripting", .repo = "local:../labelle-scripting" },
    };
    const opts = PhaseOptions{
        .plugins = &local_pin,
        .plugin_name = "scripting",
        .language = "rust",
        .script_files = &.{"components/hunger.rs"},
        .output_dir = root,
        .target_dir = target,
        .project_dir = root,
        .component_names = &.{},
        .pack_scans = &.{},
    };

    // Run 1: tool emits a "Hunger" component. Caches schema X.
    {
        const tool_x = try writeFakeDeclareTool(
            allocator,
            &tmp,
            "{\"components\":[{\"name\":\"Hunger\",\"persist\":\"persistent\",\"fields\":[]}]}",
        );
        defer allocator.free(tool_x);
        declare_tool_override = tool_x;
        defer declare_tool_override = null;
        var schema = (try runPhase(allocator, opts)) orelse return error.TestExpectedSchema;
        defer schema.deinit();
        try testing.expectEqualStrings("Hunger", schema.components[0].name);
    }

    // Run 2: the (rewritten) tool now emits a DIFFERENT component name, with
    // the declaration file untouched. A tool-blind skip key would return the
    // stale "Hunger"; the tool-bytes-keyed digest forces a re-run → "Stamina".
    {
        const tool_y = try writeFakeDeclareTool(
            allocator,
            &tmp,
            "{\"components\":[{\"name\":\"Stamina\",\"persist\":\"persistent\",\"fields\":[]}]}",
        );
        defer allocator.free(tool_y);
        declare_tool_override = tool_y;
        defer declare_tool_override = null;
        var schema = (try runPhase(allocator, opts)) orelse return error.TestExpectedSchema;
        defer schema.deinit();
        try testing.expectEqual(@as(usize, 1), schema.components.len);
        try testing.expectEqualStrings("Stamina", schema.components[0].name);
    }
}

test "runPhase: declared events land in the Schema + scripting_events.zig; collisions with events/*.zig gate; stale cleanup" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const allocator = testing.allocator;
    const tio = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(tio, "target");
    const root = try tmp.dir.realPathFileAlloc(tio, ".", allocator);
    defer allocator.free(root);
    const target = try tmp.dir.realPathFileAlloc(tio, "target", allocator);
    defer allocator.free(target);

    const tool = try writeFakeDeclareTool(
        allocator,
        &tmp,
        "{\"components\":[],\"events\":[{\"name\":\"hunger__feed\",\"fields\":[{\"name\":\"amount\",\"type\":\"f32\",\"default\":0.5},{\"name\":\"entity\",\"type\":\"u64\",\"default\":0}]}]}",
    );
    defer allocator.free(tool);
    declare_tool_override = tool;
    defer declare_tool_override = null;

    const local_pin = [_]config.PluginDep{
        .{ .name = "scripting", .repo = "local:../labelle-scripting" },
    };
    var opts = PhaseOptions{
        .plugins = &local_pin,
        .plugin_name = "scripting",
        .language = "ruby",
        .script_files = &.{"events/hunger__feed.rb"},
        .event_files = &.{"events/hunger__feed.rb"},
        .output_dir = root,
        .target_dir = target,
        .project_dir = root,
        .component_names = &.{},
        .pack_scans = &.{},
    };

    var schema = (try runPhase(allocator, opts)) orelse return error.TestExpectedSchema;
    // Components empty, ONE event — the events-only project state. The
    // caller (root.zig) threads `schema.events` onto the splice.
    try testing.expectEqual(@as(usize, 0), schema.components.len);
    try testing.expectEqual(@as(usize, 1), schema.events.len);
    try testing.expectEqualStrings("hunger__feed", schema.events[0].name);

    // The generated events file landed at the target root; the
    // components file did NOT (nothing declared one).
    const generated = try tmp.dir.readFileAlloc(tio, "target/" ++ GENERATED_EVENTS_FILENAME, allocator, .limited(1 << 20));
    defer allocator.free(generated);
    try testing.expect(std.mem.indexOf(u8, generated, "pub const HungerFeed = struct {\n" ++
        "    amount: f32 = 0.5,\n" ++
        "    entity: u64 = 0,\n" ++
        "};\n") != null);
    try testing.expectError(
        error.FileNotFound,
        tmp.dir.access(tio, "target/" ++ GENERATED_FILENAME, .{}),
    );
    schema.deinit();

    // A Zig events/hunger__feed.zig with the SAME variant name → the
    // collision gate fires (both would emit the `hunger__feed` union
    // row).
    opts.event_names = &.{"hunger__feed"};
    try testing.expectError(error.ScriptEventCollision, runPhase(allocator, opts));
    opts.event_names = &.{};

    // Declarations all removed (no collected files at all) → the no-op
    // shape drops the stale generated events file.
    opts.script_files = &.{};
    opts.event_files = &.{};
    try testing.expect((try runPhase(allocator, opts)) == null);
    try testing.expectError(
        error.FileNotFound,
        tmp.dir.access(tio, "target/" ++ GENERATED_EVENTS_FILENAME, .{}),
    );
}
