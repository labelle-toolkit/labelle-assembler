//! The `labelle.hook-routes/v1` data model — labelle-assembler#724, child
//! of the hooks epic labelle-engine#854.
//!
//! This file is THE schema. Every JSON key the inspector emits is a field
//! name here, in this declaration order, because both the writer
//! (`render.writeJson`, via `std.json.Stringify`) and the reader
//! (`hook_routes.parseReport`, via `std.json.parseFromSliceLeaky`) reflect
//! over these types. There is no second place a key can drift from.
//!
//! ## Why this shape
//!
//! The epic's friction is *"finding final event names, listeners and
//! delivery paths currently requires inspecting generated code or adding
//! ad hoc logging"*, and labelle-engine#858 (opt-in tracing) will want to
//! correlate a runtime trace against a static route. Three properties
//! follow from that:
//!
//!   * **`Receiver.id` is the join key.** It is the identity #723
//!     established (`docs/design/hook-handler-ordering.md` §2.2): the
//!     receiver's source path relative to the generated target root,
//!     minus `.zig`. #858's trace labels the same string, so a trace line
//!     and a report row can be joined without a lookup table.
//!   * **`Event.tag` is the join key for events.** Not the on-disk stem,
//!     not the dotted JSONC form — the FINAL generated union tag
//!     (`pulse`, `citizens__needs_low`, `box2d__collision_begin`). That
//!     is the string `MergeHooks.emit` switches on and therefore the one
//!     a runtime trace can print.
//!   * **Nothing claims more than the assembler knows.** Every derived
//!     fact carries its resolution state (`handlers_resolved`,
//!     `Payload.resolved`, `Resolution`, `UnmatchedHandler.reason`) so a
//!     consumer can tell "no listeners" from "could not tell". §2.4 of
//!     the ordering design splits guaranteed from incidental ordering;
//!     this model keeps that split visible rather than flattening it into
//!     a single confident list.
//!
//! ## What the shape deliberately does NOT say
//!
//! `MergeHooks` takes ONE receiver tuple and walks it in tuple order for
//! every event (design doc §2.1). There is no per-event receiver list, so
//! `Event.listeners` is a FILTER over the one global sequence, and each
//! listener carries the `order` it holds in `Report.receivers` — the
//! global index, not a per-event rank. A consumer that sorts listeners by
//! their `order` recovers the real dispatch sequence for that event; a
//! consumer that treats the per-event array as an independently ordered
//! list gets the same answer, which is the point. What it must NOT infer
//! is that the order was chosen *for that event* — moving a receiver
//! moves it for every event it handles.

const std = @import("std");

/// Schema identifier, emitted as the first key of every report. Follows
/// the repo's sidecar convention (`labelle.manifest/v1` in
/// `manifest/json.zig`). Bump the version segment on any BREAKING key
/// change; additive keys do not bump it, and every reader must therefore
/// tolerate unknown keys (`parseReport` passes
/// `.ignore_unknown_fields = true`).
pub const SCHEMA = "labelle.hook-routes/v1";

/// Sidecar filename, written into `<game>/.labelle/` next to
/// `manifest.json` and `flow_catalog.json`. Project-level rather than
/// per-target: the receiver tuple and the event universe are derived from
/// `project.labelle` + the convention dirs, neither of which varies by
/// graphics backend.
pub const ROUTES_FILENAME = "hook_routes.json";

/// Which discovery group a receiver came from. Mirrors
/// `codegen/blocks/hooks.zig:ReceiverKind` one-for-one — it is a separate
/// declaration only so the JSON model does not drag the codegen module
/// into every consumer.
pub const ReceiverKind = enum { root_hook, pack_hook, flow_handler };

/// Where an event's declaration lives.
///
///   * `game`   — `<game>/events/<stem>.zig`.
///   * `pack`   — `<pack>/events/<stem>.zig`; the generated tag carries
///                the invisible `<pack>__` prefix (#440).
///   * `plugin` — a `pub const <name> = struct` inside a plugin's
///                `pub const Events` block (RFC-PLUGIN-EVENTS phase 1).
///   * `engine` — the same mechanism, but on labelle-engine's own
///                `Events` block (`engine__*`, labelle-engine#578).
///   * `engine_hook` — a variant of `engine.HookPayload(Entity)`, the
///                base union `AllHookPayloads` merges everything else
///                into (`game_init`, `frame_start`, `entity_created`, …).
///                These are dispatched by the engine itself, not emitted
///                by game code.
///   * `script` — declared from a scripting language
///                (labelle-engine#772); payload struct is generated into
///                `scripting_events.zig`.
pub const EventOwner = enum { game, pack, plugin, engine, engine_hook, script };

/// Whether the variant survives into the generated `GameEvents` union.
///
///   * `active`     — emitted normally.
///   * `elided`     — discovered but dropped because nothing consumes it
///                    (labelle-assembler#630). NOT an error: an
///                    intentionally unobserved event is a normal state.
///   * `force_kept` — unconsumed, but kept anyway because the PROVIDER
///                    emits the tag with a raw union literal, so eliding
///                    it would break the provider's own compile.
pub const EventStatus = enum { active, elided, force_kept };

/// How an emission reaches handlers. A property of the CALL SITE, not of
/// the event: the same event may be emitted both ways from different
/// places, which is why this sits on `Emitter` and not on `Event`.
///
///   * `buffered` — `game.emit(...)`; appended to the frame's event
///                  buffer and delivered at `dispatchEvents` (end of
///                  frame).
///   * `sync`     — `game.emitSync(...)`; dispatched immediately, on the
///                  caller's stack, ahead of anything already buffered.
pub const Delivery = enum { buffered, sync };

/// One field of an event payload struct, as written in source.
pub const PayloadField = struct {
    name: []const u8,
    zig_type: []const u8,
};

/// An event's payload struct, where the assembler can see it.
///
/// `resolved = false` is a first-class answer, not a failure: a plugin
/// event's payload lives inside the plugin's `Events` block and is
/// already published per-plugin in `flow_catalog.json`, so this report
/// names the type and points there rather than re-walking it.
pub const Payload = struct {
    /// The Zig type the generated union variant refers to, when known.
    zig_type: ?[]const u8 = null,
    fields: []const PayloadField = &.{},
    resolved: bool = false,
};

/// One receiver's appearance in one event's route. `order` is its index
/// in `Report.receivers` — the GLOBAL tuple position, since there is no
/// per-event ordering to report (see the file header).
pub const Listener = struct {
    receiver: []const u8,
    order: usize,
};

/// A statically discovered emission call site.
///
/// Found by a source scan for `emit(.{ .<tag>` / `emitSync(.{ .<tag>`
/// over the generated target tree, so it sees literal call sites and
/// nothing else. A computed emit (`@unionInit` with a runtime tag, a
/// helper that forwards a `GameEvents` value) is invisible to it — which
/// is why an empty `emitters` array means "no literal call site found",
/// never "this event is never emitted". `Report.resolution` says so in
/// the report itself.
pub const Emitter = struct {
    /// Target-relative path of the file holding the call.
    site: []const u8,
    delivery: Delivery,
};

/// One hook receiver, in dispatch order.
pub const Receiver = struct {
    /// Index in the generated `MergeHooks` receiver tuple. `MergeHooks`
    /// walks the tuple in this order for EVERY event.
    order: usize,
    /// The stable identity (#723 §2.2): source path minus `.zig`.
    id: []const u8,
    kind: ReceiverKind,
    /// Owning pack name for `pack_hook`, else null.
    pack: ?[]const u8 = null,
    /// Target-relative source path — `id` + `.zig`. Spelled out so a
    /// consumer never has to know that relationship.
    source: []const u8,
    /// The Zig type placed in the receiver tuple (`AnimationHooks`,
    /// `FlowEventHandler`, …).
    zig_type: []const u8,
    /// Resolved dispatch rank; higher runs earlier, `0` is the
    /// undeclared bucket.
    rank: i32,
    /// True when `project.labelle`'s `.hooks.order` named this receiver.
    /// Distinguishes "rank 0 because declared so" from "rank 0 because
    /// nothing was declared".
    rank_declared: bool,
    /// Position in the DEFAULT sequence, before ranks were applied.
    /// Together with `rank` this explains WHY the receiver sits where it
    /// does, rather than only reporting that it does.
    baseline: usize,
    /// Event tags this receiver declares a handler for, in source order.
    /// The dispatch rule is `@hasDecl(Receiver, @tagName(tag))` with a
    /// two-parameter function decl (labelle-core `dispatcher.zig`), so
    /// these are the `pub fn <tag>(self, payload)` members found in the
    /// source.
    handlers: []const []const u8,
    /// False when the receiver's source could not be read or parsed, in
    /// which case `handlers` is empty because nothing was learned — not
    /// because the receiver handles nothing.
    handlers_resolved: bool,
};

/// A `pub fn <name>(self, payload)` on a receiver that matched no event
/// the assembler could enumerate.
///
/// This is NOT automatically a bug report. `reason` says which it is.
pub const UnmatchedHandler = struct {
    receiver: []const u8,
    handler: []const u8,
    reason: Reason,

    pub const Reason = enum {
        /// The engine's `HookPayload` variant list could not be read, so
        /// a lifecycle handler (`game_init`, `frame_start`, …) cannot be
        /// matched. Says nothing about the handler's validity.
        engine_payload_unresolved,
        /// The engine payload WAS resolved and no event of any kind
        /// carries this tag. `MergeHooks` rejects this at compile time
        /// with "Handler 'x' doesn't match any event", so seeing it here
        /// means the generated game will not build.
        unknown_event,
    };
};

/// What the assembler could and could not resolve for this report. Read
/// this before drawing a conclusion from an empty array anywhere else.
pub const Resolution = struct {
    /// True when `engine.HookPayload`'s variant list was read from the
    /// resolved engine package. False ⇒ lifecycle events are absent from
    /// `events` and their handlers land in `unmatched_handlers` with
    /// `reason = engine_payload_unresolved`.
    engine_hook_payload: bool,
    /// True when the emission-site scan ran. Even when true it sees only
    /// literal `emit(.{ .<tag>` / `emitSync(.{ .<tag>` call sites — see
    /// `Emitter`.
    emit_sites_scanned: bool,
    /// Number of `.zig` files the emission scan read.
    emit_sites_files_scanned: usize,
    /// True when the emit scan stopped at its file cap. A report with this
    /// set is INCOMPLETE: "no emit site found" for a tag may mean "not
    /// looked for" (#724 review).
    emit_sites_truncated: bool = false,
    /// Files the scan could not read. Same caveat as `emit_sites_truncated`
    /// — these are holes, not evidence of absence.
    emit_sites_unreadable: usize = 0,
};

/// The ordering contract this report describes, restated in the report so
/// a consumer reading only the JSON cannot mistake a receiver-scoped
/// order for a per-event one.
pub const Ordering = struct {
    /// True when `project.labelle` declares a non-empty `.hooks.order`.
    /// When false the sequence below is the DISCOVERY-driven default —
    /// still exact, but "incidental" in the design doc's §2.4 sense.
    declared: bool,
    /// Always `"receiver"`. Ordering is a property of the receiver, not
    /// of the (receiver, event) pair.
    scope: []const u8 = "receiver",
    /// Path (in the assembler repo) to the contract this order obeys.
    contract: []const u8 = "docs/design/hook-handler-ordering.md",
};

/// One event, with the receivers it reaches and the call sites that emit
/// it.
pub const Event = struct {
    /// The FINAL generated union tag — what `MergeHooks.emit` switches on
    /// and what a runtime trace prints. Pack events carry their
    /// `<pack>__` prefix here; plugin and engine events carry theirs.
    tag: []const u8,
    /// The bare declared name, without any qualification prefix.
    name: []const u8,
    owner: EventOwner,
    /// The owning realm's name: `"game"`, a pack name, a plugin name, or
    /// `"engine"`.
    owner_name: []const u8,
    /// Target-relative source path of the declaration, when it is a file
    /// the assembler scanned.
    source: ?[]const u8 = null,
    payload: Payload = .{},
    /// True when the payload struct declares `pub const consumable =
    /// true`. On a consumable event `MergeHooks.emit` STOPS at the first
    /// listener returning `true`, so order decides whether a later
    /// listener runs at all — not merely when.
    /// `false` = the event declares no `consumable` (core's notification
    /// path — a definite answer, not a guess). `true`/`false` = a literal
    /// decl. `null` = UNKNOWN: a decl exists but its initialiser is not a
    /// literal this pass evaluates, or the payload could not be read.
    /// Core EVALUATES the decl, so a null may still be consumable at
    /// runtime (#726 review rev 2).
    consumable: ?bool = null,
    status: EventStatus = .active,
    /// Receivers declaring a handler for this tag, in dispatch order.
    listeners: []const Listener = &.{},
    /// Statically discovered emission call sites (see `Emitter`).
    emitters: []const Emitter = &.{},
    /// Free-form explanations attached to this event — why it was
    /// elided, why its payload is unresolved, and so on.
    notes: []const []const u8 = &.{},
};

/// The whole report. Field order here is the JSON key order.
pub const Report = struct {
    /// The generation token this report was produced under (#724 review).
    /// Compared against `.labelle/generation`; a mismatch or absence means
    /// the report describes an OLDER generate than the one on disk. Null
    /// only for a legacy sidecar written before the marker existed.
    generation: ?[]const u8 = null,
    schema: []const u8 = SCHEMA,
    /// The assembler that produced it.
    assembler_version: []const u8,
    /// `project.labelle`'s `.name`.
    project: []const u8,
    ordering: Ordering,
    resolution: Resolution,
    /// Every hook receiver, in the order `MergeHooks` walks them.
    receivers: []const Receiver,
    /// Every event the assembler can enumerate, sorted by `tag` so the
    /// output is stable across runs and platforms.
    events: []const Event,
    unmatched_handlers: []const UnmatchedHandler = &.{},

    /// Look up a receiver by its `id`. Linear — receiver counts are in
    /// the tens.
    pub fn receiverById(self: Report, id: []const u8) ?Receiver {
        for (self.receivers) |r| {
            if (std.mem.eql(u8, r.id, id)) return r;
        }
        return null;
    }

    /// Look up an event by its final union `tag`.
    pub fn eventByTag(self: Report, tag: []const u8) ?Event {
        for (self.events) |e| {
            if (std.mem.eql(u8, e.tag, tag)) return e;
        }
        return null;
    }
};
