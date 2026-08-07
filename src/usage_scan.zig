//! Usage scanning for generated accessor namespaces (RFC-CONSTANTS §5,
//! RFC-I18N §3.1) — the shared pass §6 of the constants RFC calls for,
//! parameterised by module name and root symbol so `C` today and `K` later
//! are one implementation.
//!
//! The question it answers: which `<Root>.<path>` accessors does this game's
//! source actually reach? The answer drives *warnings only* — a tuning value
//! nothing reads is either dead or a rename that missed a call site — and a
//! warning that can be wrong teaches people to ignore the lint, so the design
//! is conservative in exactly one direction: **when in doubt, mark used.**
//!
//! The ruling this implements (recorded in both RFCs): a path chain that stops
//! at an interior node marks the whole subtree used. That is what makes
//! ordinary aliasing sound with no dataflow analysis at all:
//!
//!     const cfg = C.decay.hunger;   // chain ends at interior -> subtree used
//!     ... cfg.rate ...              // needs no tracking; already covered
//!
//! Escapes widen the same way. A recognised root passed as a value (`foo(C)`),
//! or a binding of the module this scanner cannot follow, marks everything
//! used. The scanner can under-report dead constants; it cannot suppress a
//! warning that should not be suppressed — there are none — nor fire on a
//! constant that is actually read.
const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Config = struct {
    /// The module the root is imported from: `@import("<module_name>")`.
    module_name: []const u8 = "constants",
    /// The declaration on that module scripts access: `.C` / `.K`.
    root_symbol: []const u8 = "C",
};

/// Accumulated over every scanned file, then queried per leaf.
pub const Marks = struct {
    arena: Allocator,
    /// Exact dotted paths seen used, e.g. "decay.hunger.rate".
    exact: std.StringHashMap(void),
    /// Dotted prefixes widened to "whole subtree used", e.g. "decay.hunger".
    prefixes: std.StringHashMap(void),
    /// A root escaped in a way the scanner cannot follow: everything is used.
    all: bool = false,

    pub fn init(arena: Allocator) Marks {
        return .{
            .arena = arena,
            .exact = std.StringHashMap(void).init(arena),
            .prefixes = std.StringHashMap(void).init(arena),
        };
    }

    /// Whether the leaf at `path` (dotted, root-relative) is covered.
    pub fn covers(self: *const Marks, path: []const u8) bool {
        if (self.all) return true;
        if (self.exact.contains(path)) return true;
        var it = self.prefixes.keyIterator();
        while (it.next()) |kp| {
            const p = kp.*;
            if (std.mem.startsWith(u8, path, p) and (path.len == p.len or path[p.len] == '.')) {
                return true;
            }
        }
        return false;
    }
};

/// Scans one file's source, accumulating into `marks`.
///
/// Recognised, in one pass over comment- and string-stripped text:
///   @import("<mod>").<Root>.a.b       inline chain
///   const X = @import("<mod>").<Root>; X is a root name for the rest of the file
///   const X = @import("<mod>");       X.<Root>.a.b chains; `const Y = X.<Root>;`
///   const Y = X.a.b;                  (X a known root) chain rule at the binding
/// A known root (or module name) in any position this cannot parse widens to
/// `all` — the conservative direction.
pub fn scanSource(marks: *Marks, cfg: Config, source: []const u8) Allocator.Error!void {
    const arena = marks.arena;

    // Names bound to the root namespace ("C-roots"). Zig declarations are
    // order-independent -- a function above the file-level
    // `const C = @import(...)` may use C -- so the file is scanned twice:
    // the first pass exists only to discover root bindings, the second marks
    // uses with the full table in hand. Marks are sets, so anything the
    // discovery pass already recorded is recorded again harmlessly.
    var roots = std.StringHashMap(void).init(arena);
    var discovery = Marks.init(arena);
    try scanPass(&discovery, cfg, source, &roots);
    // An escape seen in pass one is real regardless of binding order.
    if (discovery.all) marks.all = true;
    try scanPass(marks, cfg, source, &roots);
}

fn scanPass(marks: *Marks, cfg: Config, source: []const u8, roots: *std.StringHashMap(void)) Allocator.Error!void {
    const arena = marks.arena;

    var it = Tokenizer{ .source = source };
    while (it.next()) |tok| {
        // `@import("<mod>")` — classify what follows.
        if (tok.kind == .import and std.mem.eql(u8, tok.text, cfg.module_name)) {
            try consumeAfterModule(marks, cfg, &it, arena, roots);
            continue;
        }
        if (tok.kind != .ident) continue;

        if (roots.contains(tok.text)) {
            try consumeChainOrBinding(marks, &it, arena, roots);
            continue;
        }

        // `const X =` — remember the name so the RHS handlers above can bind
        // it. We peek rather than track state: when the RHS is one of ours,
        // the handler needs the name, so stash the most recent binding target.
        if (std.mem.eql(u8, tok.text, "pub")) {
            it.saw_pub = true;
            continue;
        }
        if (std.mem.eql(u8, tok.text, "const") or std.mem.eql(u8, tok.text, "var")) {
            const was_pub = it.saw_pub;
            it.saw_pub = false;
            if (it.nextIdent()) |name| {
                if (it.consumeEquals()) {
                    it.pending_binding = name;
                    it.pending_is_pub = was_pub;
                    // The RHS handlers above consume this. Any identifier that
                    // arrives first (a function call, another variable) breaks
                    // the direct-binding shape and clears it below -- which is
                    // what makes `const x = f(C);` an escape (widen) rather
                    // than a false root alias.
                    continue;
                }
            }
            continue;
        }

        // Any other identifier between `=` and a root breaks the binding shape.
        it.pending_binding = null;
        it.saw_pub = false;
    }
}

/// After `@import("<mod>")`: either `.C<chain>` (inline use / root binding) or
/// a bare module binding (`const m = @import("<mod>");`).
fn consumeAfterModule(
    marks: *Marks,
    cfg: Config,
    it: *Tokenizer,
    arena: Allocator,
    roots: *std.StringHashMap(void),
) Allocator.Error!void {
    if (!it.consumeDot()) {
        // `@import("<mod>")` used bare. If it is being bound, the name becomes
        // a module alias... but tracking module aliases through a second table
        // costs little and the binding target is at hand:
        if (it.takePendingBinding()) |_| {
            // A module alias: subsequent `<name>.C.x` chains would need the
            // modules table -- which scanSource keeps. Rather than thread it
            // here, be conservative: a module bound to a name we then track
            // loosely could miss uses, and missing uses breaks the sound
            // direction. Widen.
            marks.all = true;
            return;
        }
        marks.all = true; // module value escaped somewhere unparseable
        return;
    }
    const sym = it.nextIdent() orelse {
        marks.all = true;
        return;
    };
    if (!std.mem.eql(u8, sym, cfg.root_symbol)) return; // @import("mod").other
    try consumeChainOrBinding(marks, it, arena, roots);
}

/// Positioned right after a root name (or `...<mod>").C`): walk the `.ident`
/// chain. Three outcomes:
///   - the whole statement was `const X = <root><chain>;` -> X becomes a root
///     (empty chain) or the chain marks per the interior rule
///   - a chain followed by more source -> exact/interior mark
///   - no chain and not a binding -> the root escaped as a value -> all
fn consumeChainOrBinding(
    marks: *Marks,
    it: *Tokenizer,
    arena: Allocator,
    roots: *std.StringHashMap(void),
) Allocator.Error!void {
    var parts: std.ArrayList([]const u8) = .empty;
    while (it.consumeDot()) {
        const ident = it.nextIdent() orelse break;
        try parts.append(arena, ident);
    }

    if (parts.items.len == 0) {
        // Bare root. `const X = C;` re-roots the whole namespace under X --
        // but `pub const X = C;` re-exports it to files this per-file scan
        // cannot see into, so a pub re-export is a cross-file escape: widen.
        if (it.takePendingBinding()) |name| {
            if (it.pending_is_pub) marks.all = true;
            try roots.put(try arena.dupe(u8, name), {});
        } else {
            marks.all = true; // passed as a value / unparseable
        }
        return;
    }

    const path = try std.mem.join(arena, ".", parts.items);
    if (it.takePendingBinding()) |name| {
        // `const cfg = C.decay.hunger;` -- the interior rule at the binding
        // site: the subtree is used, cfg itself needs no tracking. (If the
        // path is actually a leaf, prefix-covering a leaf is the same as an
        // exact mark.) The bound name is deliberately NOT a new root: its
        // subsequent uses are already covered by the widening.
        _ = name;
        try marks.prefixes.put(path, {});
        return;
    }
    // Plain use. Whether this lands on a leaf or an interior node is the
    // registry's question, not the scanner's: record it as an exact mark AND
    // a prefix mark, which makes `C.decay.hunger` in expression position
    // cover the subtree exactly as the ruling requires.
    try marks.exact.put(path, {});
    try marks.prefixes.put(path, {});
}

/// The minimal lexer this needs: identifiers, `@import("...")`, dots and
/// equals, with comments and string/char literals skipped so a mention of
/// `C.x` in either never counts as use.
const Tokenizer = struct {
    source: []const u8,
    i: usize = 0,
    /// Set when `const <name> =` was just seen; consumed by the first
    /// RHS handler that wants it.
    pending_binding: ?[]const u8 = null,
    /// Whether that binding was `pub` -- a pub re-export of the root is
    /// visible to OTHER files this per-file scanner cannot see into.
    pending_is_pub: bool = false,
    /// Set when the last returned identifier was `pub`, so the following
    /// const/var can record visibility.
    saw_pub: bool = false,

    const Token = struct {
        kind: enum { ident, import },
        /// For .ident the identifier; for .import the imported module name.
        text: []const u8,
    };

    fn takePendingBinding(self: *Tokenizer) ?[]const u8 {
        const b = self.pending_binding;
        self.pending_binding = null;
        return b;
    }

    fn next(self: *Tokenizer) ?Token {
        while (self.i < self.source.len) {
            self.skipIgnorable();
            if (self.i >= self.source.len) return null;
            const c = self.source[self.i];

            if (c == '@') {
                if (self.matchImport()) |mod| return .{ .kind = .import, .text = mod };
                self.i += 1;
                continue;
            }
            if (isIdentStart(c)) {
                const start = self.i;
                // A preceding '.' means this is a member access of something
                // else (`foo.C`) -- never a root occurrence. The dot was
                // consumed as ignorable? No: dots are not ignorable; we only
                // land here when the previous token loop did not consume the
                // dot, so guard by looking back.
                const prev = if (start == 0) @as(u8, 0) else self.source[start - 1];
                self.i = endOfIdent(self.source, start);
                if (prev == '.' or prev == '@') continue;
                const text = self.source[start..self.i];
                // `pending_binding` survives only across the tokens of one
                // statement shape; any identifier that is not part of the
                // recognised RHS clears it further down via overwrite.
                return .{ .kind = .ident, .text = text };
            }
            if (c == ';') self.pending_binding = null;
            self.i += 1;
        }
        return null;
    }

    /// Consumes `.` (with surrounding whitespace/comments) if present.
    fn consumeDot(self: *Tokenizer) bool {
        self.skipIgnorable();
        if (self.i < self.source.len and self.source[self.i] == '.') {
            // `..` (ranges) and `.{` are not member access.
            if (self.i + 1 < self.source.len and (self.source[self.i + 1] == '.' or self.source[self.i + 1] == '{')) return false;
            self.i += 1;
            return true;
        }
        return false;
    }

    fn consumeEquals(self: *Tokenizer) bool {
        self.skipIgnorable();
        if (self.i < self.source.len and self.source[self.i] == '=' and
            (self.i + 1 >= self.source.len or self.source[self.i + 1] != '='))
        {
            self.i += 1;
            return true;
        }
        return false;
    }

    fn nextIdent(self: *Tokenizer) ?[]const u8 {
        self.skipIgnorable();
        if (self.i >= self.source.len or !isIdentStart(self.source[self.i])) return null;
        const start = self.i;
        self.i = endOfIdent(self.source, start);
        return self.source[start..self.i];
    }

    fn matchImport(self: *Tokenizer) ?[]const u8 {
        // Tolerates whitespace around the parens (`@import ("x")`) -- legal
        // Zig even if zig fmt would collapse it, and a scanner that requires
        // formatted source under-marks, the forbidden direction.
        var j = self.i;
        const kw = "@import";
        if (!std.mem.startsWith(u8, self.source[j..], kw)) return null;
        j += kw.len;
        while (j < self.source.len and (self.source[j] == ' ' or self.source[j] == '\t' or self.source[j] == '\n' or self.source[j] == '\r')) j += 1;
        if (j >= self.source.len or self.source[j] != '(') return null;
        j += 1;
        while (j < self.source.len and (self.source[j] == ' ' or self.source[j] == '\t' or self.source[j] == '\n' or self.source[j] == '\r')) j += 1;
        if (j >= self.source.len or self.source[j] != '"') return null;
        const name_start = j + 1;
        const end = std.mem.indexOfScalarPos(u8, self.source, name_start, '"') orelse return null;
        var k = end + 1;
        while (k < self.source.len and (self.source[k] == ' ' or self.source[k] == '\t' or self.source[k] == '\n' or self.source[k] == '\r')) k += 1;
        if (k >= self.source.len or self.source[k] != ')') return null;
        self.i = k + 1;
        return self.source[name_start..end];
    }

    fn skipIgnorable(self: *Tokenizer) void {
        while (self.i < self.source.len) {
            const c = self.source[self.i];
            if (c == ' ' or c == '\t' or c == '\r' or c == '\n') {
                self.i += 1;
            } else if (c == '/' and self.i + 1 < self.source.len and self.source[self.i + 1] == '/') {
                while (self.i < self.source.len and self.source[self.i] != '\n') self.i += 1;
            } else if (c == '"') {
                self.i += 1;
                while (self.i < self.source.len) {
                    if (self.source[self.i] == '\\') {
                        self.i += 2;
                    } else if (self.source[self.i] == '"') {
                        self.i += 1;
                        break;
                    } else self.i += 1;
                }
            } else if (c == '\'') {
                self.i += 1;
                while (self.i < self.source.len) {
                    if (self.source[self.i] == '\\') {
                        self.i += 2;
                    } else if (self.source[self.i] == '\'') {
                        self.i += 1;
                        break;
                    } else self.i += 1;
                }
            } else if (c == '\\' and self.i + 1 < self.source.len and self.source[self.i + 1] == '\\') {
                // multiline string literal line: skip to EOL
                while (self.i < self.source.len and self.source[self.i] != '\n') self.i += 1;
            } else break;
        }
    }
};

fn isIdentStart(c: u8) bool {
    return std.ascii.isAlphabetic(c) or c == '_';
}

fn endOfIdent(s: []const u8, start: usize) usize {
    var i = start;
    while (i < s.len and (std.ascii.isAlphanumeric(s[i]) or s[i] == '_')) i += 1;
    return i;
}

// ---------------------------------------------------------------------------
// tests
// ---------------------------------------------------------------------------

const testing = std.testing;

fn scanned(arena: Allocator, source: []const u8) !Marks {
    var m = Marks.init(arena);
    try scanSource(&m, .{}, source);
    return m;
}

test "direct leaf use marks exactly that leaf" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const m = try scanned(arena_state.allocator(),
        \\const C = @import("constants").C;
        \\pub fn f() f32 { return C.decay.hunger.rate; }
    );
    try testing.expect(m.covers("decay.hunger.rate"));
    try testing.expect(!m.covers("decay.hunger.yellow_threshold"));
    try testing.expect(!m.all);
}

test "interior binding widens the subtree -- the alias ruling" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const m = try scanned(arena_state.allocator(),
        \\const C = @import("constants").C;
        \\const cfg = C.decay.hunger;
        \\pub fn f() f32 { return cfg.rate; }
    );
    try testing.expect(m.covers("decay.hunger.rate"));
    try testing.expect(m.covers("decay.hunger.anything_else"));
    try testing.expect(!m.covers("decay.health.drain_rate"));
    try testing.expect(!m.all);
}

test "interior use in expression position also widens" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const m = try scanned(arena_state.allocator(),
        \\const C = @import("constants").C;
        \\pub fn f(comptime T: type) T { return pick(C.combat); }
    );
    try testing.expect(m.covers("combat.ship_speed"));
    try testing.expect(!m.covers("decay.hunger.rate"));
}

test "a renamed root works; a re-rooted alias works" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const m = try scanned(arena_state.allocator(),
        \\const K2 = @import("constants").C;
        \\const R = K2;
        \\pub fn f() f32 { return R.decay.hunger.rate; }
    );
    try testing.expect(m.covers("decay.hunger.rate"));
    try testing.expect(!m.all);
}

test "the root escaping as a value widens everything" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const m = try scanned(arena_state.allocator(),
        \\const C = @import("constants").C;
        \\pub fn f() void { dump(C); }
    );
    try testing.expect(m.all);
    try testing.expect(m.covers("anything.at.all"));
}

test "a bare module binding widens (tracked loosely would under-report)" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const m = try scanned(arena_state.allocator(),
        \\const consts = @import("constants");
        \\pub fn f() f32 { return consts.C.decay.hunger.rate; }
    );
    // The module-alias path is deliberately widened rather than tracked.
    try testing.expect(m.covers("decay.hunger.rate"));
}

test "mentions in comments and strings do not count" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const m = try scanned(arena_state.allocator(),
        \\const C = @import("constants").C;
        \\// C.decay.hunger.rate is documented here
        \\const s = "C.combat.ship_speed";
        \\pub fn f() f32 { return C.rooms.build_time; }
    );
    try testing.expect(m.covers("rooms.build_time"));
    try testing.expect(!m.covers("decay.hunger.rate"));
    try testing.expect(!m.covers("combat.ship_speed"));
}

test "member access of an unrelated C is not a root occurrence" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const m = try scanned(arena_state.allocator(),
        \\const C = @import("constants").C;
        \\pub fn f(foo: anytype) f32 { return foo.C.decay + C.rooms.build_time; }
    );
    try testing.expect(m.covers("rooms.build_time"));
    // foo.C.decay must not mark decay: it is somebody else's C.
    try testing.expect(!m.covers("decay"));
}

test "other imports and other symbols on the module are ignored" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const m = try scanned(arena_state.allocator(),
        \\const std = @import("std");
        \\const other = @import("engine").C;
        \\pub fn f() void { _ = std.mem.eql; _ = other.decay; }
    );
    try testing.expect(!m.all);
    try testing.expect(!m.covers("decay"));
}

test "use above the binding still counts -- declarations are order-independent" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const m = try scanned(arena_state.allocator(),
        \\pub fn early() f32 { return C.decay.hunger.rate; }
        \\const C = @import("constants").C;
    );
    try testing.expect(m.covers("decay.hunger.rate"));
    try testing.expect(!m.all);
}

test "whitespace inside the import call is tolerated" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const m = try scanned(arena_state.allocator(),
        \\const C = @import ( "constants" ).C;
        \\pub fn f() f32 { return C.decay.rate; }
    );
    try testing.expect(m.covers("decay.rate"));
}

test "a pub re-export of the root is a cross-file escape" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    // Another file may `@import` this helper and use K through it; this
    // per-file scan cannot see that, so it must widen.
    const m = try scanned(arena_state.allocator(),
        \\pub const K = @import("constants").C;
    );
    try testing.expect(m.all);
}

test "a private root alias does not widen" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const m = try scanned(arena_state.allocator(),
        \\const C = @import("constants").C;
        \\pub fn f() f32 { return C.decay.rate; }
    );
    try testing.expect(!m.all);
    try testing.expect(m.covers("decay.rate"));
}

test "no import, no marks" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const m = try scanned(arena_state.allocator(),
        \\pub fn f(C: u8) u8 { return C; }
    );
    // A local named C without the import is not our root; nothing marks, and
    // crucially `return C;` must not widen.
    try testing.expect(!m.all);
    try testing.expect(!m.covers("decay.hunger.rate"));
}
