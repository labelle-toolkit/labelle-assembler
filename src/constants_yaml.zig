//! The strict-subset YAML parser for `constants/*.yaml` (RFC-CONSTANTS §2).
//!
//! Hand-written on purpose — RFC-CONSTANTS Open Question 1, resolved: the
//! subset is small enough that a parser is less code than a dependency, and it
//! makes the subset enforceable by construction. There is no path through this
//! code that *silently* applies YAML 1.1 implicit typing, because none of it
//! is implemented: `no` as a bare scalar is not a boolean here, it is a build
//! error telling the author to write `false` or `"no"`.
//!
//! Supported: block mappings, nesting by indentation, scalars, `#` comments,
//! blank lines. Everything else is rejected *by name* — anchors, aliases,
//! tags, multi-document markers, flow collections, sequences — so the error
//! says what was written, not "syntax error".
//!
//! Scalars keep their SOURCE TEXT. `5.0` is emitted as `5.0` and `5` as `5`,
//! which is what makes the generated declarations comptime_float vs
//! comptime_int — the distinction RFC-CONSTANTS §1.1's scalar-kind rule needs.
const std = @import("std");
const Allocator = std.mem.Allocator;

pub const ScalarKind = enum { int, float, bool, string };

pub const Scalar = struct {
    kind: ScalarKind,
    /// For int/float/bool: the literal exactly as written, emitted verbatim.
    /// For string: the *unquoted, unescaped* content.
    text: []const u8,
    line: usize,
    /// Set when a game override replaced this scalar: the overriding file,
    /// so an unused-constant warning points at the line someone actually
    /// wrote. Null = the value is from its own file.
    src: ?[]const u8 = null,
};

pub const Node = union(enum) {
    mapping: *Mapping,
    scalar: Scalar,
};

/// Insertion-ordered, so the generated file lists constants in the order the
/// YAML declares them and a diff of the YAML reads like a diff of the output.
pub const Mapping = struct {
    entries: std.ArrayList(Entry) = .empty,

    pub const Entry = struct {
        key: []const u8,
        line: usize,
        node: Node,
    };

    pub fn get(self: *const Mapping, key: []const u8) ?*const Node {
        for (self.entries.items) |*e| {
            if (std.mem.eql(u8, e.key, key)) return &e.node;
        }
        return null;
    }
};

pub const Error = struct {
    line: usize,
    msg: []const u8,
};

pub const ParseResult = union(enum) {
    root: Mapping,
    fail: Error,
};

/// Parses one file. Everything is allocated from `arena` — the caller owns an
/// arena whose lifetime covers the use of the tree, and nothing here is freed
/// individually. On failure the message is also arena-allocated.
pub fn parse(arena: Allocator, source: []const u8) Allocator.Error!ParseResult {
    var p = Parser{ .arena = arena, .source = source };
    return p.run();
}

const Parser = struct {
    arena: Allocator,
    source: []const u8,
    pos: usize = 0,
    line_no: usize = 0,

    const Line = struct {
        indent: usize,
        content: []const u8, // comment-stripped, trailing-space-trimmed
        no: usize,
        has_tab: bool = false,
    };

    fn fail(self: *Parser, line: usize, comptime fmt: []const u8, args: anytype) Allocator.Error!ParseResult {
        return .{ .fail = .{ .line = line, .msg = try std.fmt.allocPrint(self.arena, fmt, args) } };
    }

    fn run(self: *Parser) Allocator.Error!ParseResult {
        // Stack of open mappings, outermost first. Levels hold the indent of
        // the KEYS in that mapping (root keys are at indent 0).
        var stack: std.ArrayList(struct { indent: usize, map: *Mapping }) = .empty;
        const root_storage = try self.arena.create(Mapping);
        root_storage.* = .{};
        try stack.append(self.arena, .{ .indent = 0, .map = root_storage });
        // When the previous line opened a mapping (`key:` with no value), the
        // next content line must be its first, deeper-indented child.
        var pending: ?struct { key_line: usize, min_indent: usize } = null;

        while (try self.nextLine()) |ln| {
            if (ln.has_tab) {
                return self.fail(ln.no, "tab in indentation -- YAML forbids tabs, and they are invisible; use spaces", .{});
            }
            if (pending) |p| {
                if (ln.indent <= p.min_indent) {
                    return self.fail(p.key_line, "this key opens a nested block, but nothing is indented under it", .{});
                }
                pending = null;
            }

            // Close mappings until the top of the stack matches this indent.
            // A level still at maxInt is a just-opened mapping awaiting its
            // first child -- never popped here; it is pinned below instead.
            while (stack.items.len > 1 and
                stack.items[stack.items.len - 1].indent != std.math.maxInt(usize) and
                ln.indent < stack.items[stack.items.len - 1].indent)
            {
                _ = stack.pop();
            }
            const top = stack.items[stack.items.len - 1];
            if (ln.indent != top.indent) {
                if (top.indent == std.math.maxInt(usize)) {
                    // First child of a just-opened mapping pins its indent.
                    stack.items[stack.items.len - 1].indent = ln.indent;
                } else {
                    return self.fail(ln.no, "indentation of {d} spaces matches no open block", .{ln.indent});
                }
            }

            // Reject the constructs the subset excludes, by name.
            if (std.mem.startsWith(u8, ln.content, "- ") or std.mem.eql(u8, ln.content, "-")) {
                return self.fail(ln.no, "sequences are not supported in constants files (RFC-CONSTANTS §2; tiered values are Open Question 3)", .{});
            }
            if (std.mem.startsWith(u8, ln.content, "---")) {
                return self.fail(ln.no, "multi-document YAML ('---') is not supported in constants files", .{});
            }

            const colon = std.mem.indexOfScalar(u8, ln.content, ':') orelse {
                return self.fail(ln.no, "expected 'key:' or 'key: value', found '{s}'", .{ln.content});
            };
            const key = std.mem.trim(u8, ln.content[0..colon], " \t");
            if (!isIdentifier(key)) {
                return self.fail(ln.no, "'{s}' is not a valid constant name: names become Zig identifiers ([A-Za-z_][A-Za-z0-9_]*)", .{key});
            }
            if (top.map.get(key) != null) {
                return self.fail(ln.no, "duplicate key '{s}' in the same block", .{key});
            }
            const key_owned = try self.arena.dupe(u8, key);

            // Tabs are forbidden in indentation but valid SEPARATION after
            // the colon; trimming only spaces shipped a literal tab in the value.
            const rest = std.mem.trim(u8, ln.content[colon + 1 ..], " \t");
            if (rest.len == 0) {
                // Opens a nested mapping. The child lives behind a stable
                // pointer in the arena; the entry's node references it, so a
                // later resize of the parent's entries list cannot move it.
                const child = try self.arena.create(Mapping);
                child.* = .{};
                try top.map.entries.append(self.arena, .{
                    .key = key_owned,
                    .line = ln.no,
                    .node = .{ .mapping = child },
                });
                // Indent unknown until the first child pins it.
                try stack.append(self.arena, .{ .indent = std.math.maxInt(usize), .map = child });
                pending = .{ .key_line = ln.no, .min_indent = ln.indent };
                continue;
            }

            switch (try self.classify(rest, ln.no)) {
                .ok => |sc| try top.map.entries.append(self.arena, .{ .key = key_owned, .line = ln.no, .node = .{ .scalar = sc } }),
                .err => |e| return .{ .fail = e },
            }
        }

        if (pending) |p| {
            return self.fail(p.key_line, "this key opens a nested block, but the file ends before anything is indented under it", .{});
        }
        return .{ .root = root_storage.* };
    }

    /// Reads the next content-bearing line: skips blanks and comment-only
    /// lines, strips inline comments, rejects tabs. Pins the indent of the
    /// first child of a just-opened mapping (see `run`).
    fn nextLine(self: *Parser) Allocator.Error!?Line {
        while (self.pos < self.source.len) {
            const start = self.pos;
            const nl = std.mem.indexOfScalarPos(u8, self.source, start, '\n') orelse self.source.len;
            self.pos = if (nl < self.source.len) nl + 1 else self.source.len;
            self.line_no += 1;

            var raw = self.source[start..nl];
            if (raw.len > 0 and raw[raw.len - 1] == '\r') raw = raw[0 .. raw.len - 1];

            var indent: usize = 0;
            while (indent < raw.len and raw[indent] == ' ') indent += 1;
            if (indent < raw.len and raw[indent] == '\t') {
                // A tab in the indent is YAML's classic silent killer; loud here.
                // Encode as a "line" the caller will fail on via classify? No —
                // simplest honest path: treat as content and let run() reject the
                // missing colon... that would mislead. Return a sentinel line the
                // caller cannot misread: handled by rejecting here through a
                // scalar-shaped error is not possible, so tabs surface as an
                // impossible indent instead.
                return .{ .indent = indent, .content = raw[indent..], .no = self.line_no, .has_tab = true };
            }

            const stripped = stripComment(raw[indent..]);
            const content = std.mem.trimEnd(u8, stripped, " ");
            if (content.len == 0) continue;

            return .{ .indent = indent, .content = content, .no = self.line_no };
        }
        return null;
    }

    const Classified = union(enum) { ok: Scalar, err: Error };

    fn classify(self: *Parser, text: []const u8, line: usize) Allocator.Error!Classified {
        const failc = struct {
            fn f(arena: Allocator, l: usize, comptime fmt: []const u8, args: anytype) Allocator.Error!Classified {
                return .{ .err = .{ .line = l, .msg = try std.fmt.allocPrint(arena, fmt, args) } };
            }
        }.f;

        // Quoted → string, content unescaped (double) or '' -> ' (single,
        // YAML's one single-quote escape). A value that STARTS with a quote
        // but does not close it is an authoring typo, not a bare string --
        // accepting it would ship the quote as data.
        if (text.len >= 2 and text[0] == '"' and text[text.len - 1] == '"') {
            switch (try unescapeDouble(self.arena, text[1 .. text.len - 1], line)) {
                .ok => |s| return .{ .ok = .{ .kind = .string, .text = s, .line = line } },
                .err => |e| return .{ .err = e },
            }
        }
        if (text.len >= 2 and text[0] == '\'' and text[text.len - 1] == '\'') {
            const inner = text[1 .. text.len - 1];
            // `''` inside single quotes is YAML's escaped apostrophe.
            const decoded = try std.mem.replaceOwned(u8, self.arena, inner, "''", "'");
            return .{ .ok = .{ .kind = .string, .text = decoded, .line = line } };
        }
        if (text[0] == '"' or text[0] == '\'') {
            return failc(self.arena, line, "unterminated quoted string", .{});
        }

        // The named rejections, before anything can be misread.
        if (text[0] == '&' or text[0] == '*') {
            return failc(self.arena, line, "YAML anchors/aliases ('&', '*') are not supported in constants files", .{});
        }
        if (std.mem.startsWith(u8, text, "!!") or text[0] == '!') {
            return failc(self.arena, line, "YAML tags ('!') are not supported in constants files", .{});
        }
        if (text[0] == '{' or text[0] == '[') {
            return failc(self.arena, line, "flow collections ('{{…}}', '[…]') are not supported in constants files", .{});
        }
        if (text[0] == '|' or text[0] == '>') {
            return failc(self.arena, line, "block scalars ('|', '>') are not supported in constants files; use a quoted string", .{});
        }
        if (isForbiddenSpecialFloat(text)) {
            return failc(self.arena, line, "'{s}' is YAML's infinity/NaN spelling, which no constant kind carries. Quote it if the text is meant", .{text});
        }
        if (isForbiddenNull(text)) {
            return failc(self.arena, line, "'{s}' is YAML's null, and constants have no null kind. Quote it if the text is meant: \"{s}\"", .{ text, text });
        }
        if (isForbiddenBool(text)) {
            return failc(self.arena, line, "'{s}' is ambiguous in YAML (1.1 reads it as a boolean). Write true/false, or quote it: \"{s}\"", .{ text, text });
        }
        if (std.mem.eql(u8, text, "true") or std.mem.eql(u8, text, "false")) {
            return .{ .ok = .{ .kind = .bool, .text = try self.arena.dupe(u8, text), .line = line } };
        }
        if (matchInt(text)) {
            return .{ .ok = .{ .kind = .int, .text = try self.arena.dupe(u8, text), .line = line } };
        }
        if (matchFloat(text)) {
            return .{ .ok = .{ .kind = .float, .text = try self.arena.dupe(u8, text), .line = line } };
        }
        // Number-shaped but matching neither pattern: refuse rather than
        // silently make it a string, because `1_000`, `.5`, `0x10`, `12:30`
        // and `0755` are exactly the silent-typing traps §2 lists.
        if (looksNumeric(text)) {
            return failc(self.arena, line, "'{s}' is not an accepted numeric literal (-?digits or -?digits.digits, optional e-exponent). Quote it if it is meant as a string", .{text});
        }
        // A bare scalar with a colon inside is more likely a mistake (the
        // 12:30 shape) than a string; require quotes. '#' is NOT in this
        // guard: without preceding whitespace it is ordinary data
        // (icon#selected), and with it the comment stripper already cut it.
        if (std.mem.indexOfScalar(u8, text, ':') != null) {
            return failc(self.arena, line, "'{s}' contains YAML syntax characters; quote it if it is meant as a string", .{text});
        }
        return .{ .ok = .{ .kind = .string, .text = try self.arena.dupe(u8, text), .line = line } };
    }
};

fn stripComment(s: []const u8) []const u8 {
    var in_double = false;
    var in_single = false;
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        const c = s[i];
        if (in_double) {
            if (c == '\\') i += 1 else if (c == '"') in_double = false;
        } else if (in_single) {
            if (c == '\'') in_single = false;
        } else switch (c) {
            '"' => in_double = true,
            '\'' => in_single = true,
            // YAML starts a comment only when '#' begins the line or follows
            // whitespace. `id: icon#selected` is a value with a hash in it,
            // not a comment -- cutting there silently truncated the value.
            '#' => if (i == 0 or s[i - 1] == ' ' or s[i - 1] == '\t') return s[0..i],
            else => {},
        }
    }
    return s;
}

fn isIdentifier(s: []const u8) bool {
    if (s.len == 0) return false;
    if (!std.ascii.isAlphabetic(s[0]) and s[0] != '_') return false;
    for (s[1..]) |c| {
        if (!std.ascii.isAlphanumeric(c) and c != '_') return false;
    }
    return true;
}

fn isForbiddenBool(s: []const u8) bool {
    const forbidden = [_][]const u8{ "no", "No", "NO", "yes", "Yes", "YES", "on", "On", "ON", "off", "Off", "OFF", "True", "TRUE", "False", "FALSE" };
    for (forbidden) |f| {
        if (std.mem.eql(u8, s, f)) return true;
    }
    return false;
}

fn matchInt(s: []const u8) bool {
    var t = s;
    if (t.len > 0 and t[0] == '-') t = t[1..];
    if (t.len == 0) return false;
    // No leading zeros (octal trap), except "0" itself.
    if (t.len > 1 and t[0] == '0') return false;
    for (t) |c| if (!std.ascii.isDigit(c)) return false;
    return true;
}

fn isForbiddenSpecialFloat(s: []const u8) bool {
    var t = s;
    if (t.len > 0 and (t[0] == '-' or t[0] == '+')) t = t[1..];
    const forbidden = [_][]const u8{ ".inf", ".Inf", ".INF", ".nan", ".NaN", ".NAN" };
    for (forbidden) |f| {
        if (std.mem.eql(u8, t, f)) return true;
    }
    return false;
}

fn isForbiddenNull(s: []const u8) bool {
    const forbidden = [_][]const u8{ "null", "Null", "NULL", "~" };
    for (forbidden) |f| {
        if (std.mem.eql(u8, s, f)) return true;
    }
    return false;
}

fn matchFloat(s: []const u8) bool {
    var t = s;
    if (t.len > 0 and t[0] == '-') t = t[1..];
    const dot = std.mem.indexOfScalar(u8, t, '.') orelse {
        // Exponent-only spelling: digits[eE][+-]digits, no dot. `1e3` is a
        // float by any reading, and the diagnostic already advertises an
        // optional exponent.
        const e = std.mem.indexOfAny(u8, t, "eE") orelse return false;
        const mant = t[0..e];
        if (mant.len == 0 or (mant.len > 1 and mant[0] == '0')) return false;
        for (mant) |c| if (!std.ascii.isDigit(c)) return false;
        var exp = t[e + 1 ..];
        if (exp.len > 0 and (exp[0] == '+' or exp[0] == '-')) exp = exp[1..];
        if (exp.len == 0) return false;
        for (exp) |ec| if (!std.ascii.isDigit(ec)) return false;
        return true;
    };
    const int_part = t[0..dot];
    var frac = t[dot + 1 ..];
    if (int_part.len == 0 or frac.len == 0) return false;
    if (int_part.len > 1 and int_part[0] == '0') return false;
    for (int_part) |c| if (!std.ascii.isDigit(c)) return false;
    // Optional exponent after the fraction digits.
    var saw_digit = false;
    var i: usize = 0;
    while (i < frac.len) : (i += 1) {
        const c = frac[i];
        if (std.ascii.isDigit(c)) {
            saw_digit = true;
            continue;
        }
        if ((c == 'e' or c == 'E') and saw_digit) {
            var exp = frac[i + 1 ..];
            if (exp.len > 0 and (exp[0] == '+' or exp[0] == '-')) exp = exp[1..];
            if (exp.len == 0) return false;
            for (exp) |ec| if (!std.ascii.isDigit(ec)) return false;
            return true;
        }
        return false;
    }
    return saw_digit;
}

fn looksNumeric(s: []const u8) bool {
    // A sign or dot may precede more sign/dot before the first digit
    // (`-.5`, `+.5`): strip up to two of them so those spellings hit the
    // numeric-literal error rather than silently becoming strings.
    var t = s;
    var strip: usize = 0;
    while (strip < 2 and t.len > 0 and (t[0] == '-' or t[0] == '+' or t[0] == '.')) : (strip += 1) t = t[1..];
    return t.len > 0 and std.ascii.isDigit(t[0]);
}

const Unescaped = union(enum) { ok: []const u8, err: Error };

fn unescapeDouble(arena: Allocator, s: []const u8, line: usize) Allocator.Error!Unescaped {
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        if (s[i] == '\\' and i + 1 < s.len) {
            i += 1;
            const decoded: u8 = switch (s[i]) {
                'n' => '\n',
                't' => '\t',
                'r' => '\r',
                '\\' => '\\',
                '"' => '"',
                // Anything else (\u, \0, \x...) would be silently corrupted by
                // dropping the slash -- `"é"` became `u00e9`. Loud.
                else => return .{ .err = .{ .line = line, .msg = try std.fmt.allocPrint(arena, "unsupported escape '\\{c}' -- this subset knows \\n \\t \\r \\\\ \\\". Write the character directly", .{s[i]}) } },
            };
            try out.append(arena, decoded);
        } else {
            try out.append(arena, s[i]);
        }
    }
    return .{ .ok = try out.toOwnedSlice(arena) };
}

// ---------------------------------------------------------------------------
// tests
// ---------------------------------------------------------------------------

const testing = std.testing;

fn parseOk(arena: Allocator, src: []const u8) !Mapping {
    const r = try parse(arena, src);
    switch (r) {
        .root => |m| return m,
        .fail => |e| {
            std.debug.print("unexpected parse failure line {d}: {s}\n", .{ e.line, e.msg });
            return error.TestUnexpectedResult;
        },
    }
}

fn parseErr(arena: Allocator, src: []const u8) !Error {
    const r = try parse(arena, src);
    switch (r) {
        .root => return error.TestUnexpectedResult,
        .fail => |e| return e,
    }
}

test "flat mapping keeps source text and kinds" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const m = try parseOk(a,
        \\# how long building takes
        \\build_time: 5.0
        \\deconstruct_time: 4
        \\enabled: true
        \\label: bare words are a string
        \\quoted: "a: quoted #string"
    );
    try testing.expectEqual(@as(usize, 5), m.entries.items.len);
    try testing.expectEqual(ScalarKind.float, m.get("build_time").?.scalar.kind);
    try testing.expectEqualStrings("5.0", m.get("build_time").?.scalar.text);
    try testing.expectEqual(ScalarKind.int, m.get("deconstruct_time").?.scalar.kind);
    try testing.expectEqualStrings("4", m.get("deconstruct_time").?.scalar.text);
    try testing.expectEqual(ScalarKind.bool, m.get("enabled").?.scalar.kind);
    try testing.expectEqual(ScalarKind.string, m.get("label").?.scalar.kind);
    try testing.expectEqualStrings("a: quoted #string", m.get("quoted").?.scalar.text);
}

test "nesting maps to nested mappings, insertion order kept" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const m = try parseOk(a,
        \\hunger:
        \\  rate: 0.02
        \\  yellow_threshold: 0.5
        \\health:
        \\  drain_rate: 0.0   # DISABLED
    );
    try testing.expectEqual(@as(usize, 2), m.entries.items.len);
    try testing.expectEqualStrings("hunger", m.entries.items[0].key);
    const hunger = m.get("hunger").?.mapping;
    try testing.expectEqualStrings("0.02", hunger.get("rate").?.scalar.text);
    const health = m.get("health").?.mapping;
    try testing.expectEqualStrings("0.0", health.get("drain_rate").?.scalar.text);
}

test "the YAML 1.1 traps are named errors, not silent values" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    {
        const e = try parseErr(a, "enabled: no\n");
        try testing.expect(std.mem.indexOf(u8, e.msg, "ambiguous") != null);
        try testing.expectEqual(@as(usize, 1), e.line);
    }
    { // sexagesimal reads as a colon inside a bare scalar
        const e = try parseErr(a, "delay: 12:30\n");
        try testing.expect(std.mem.indexOf(u8, e.msg, "numeric literal") != null);
    }
    { // octal-looking
        const e = try parseErr(a, "id: 0755\n");
        try testing.expect(std.mem.indexOf(u8, e.msg, "numeric literal") != null);
    }
    { // version-number float truncation trap: 1.20 is a fine float literal for
        // us (emitted verbatim), so this parses — the trap YAML has does not
        // exist when the text is preserved.
        const m = try parseOk(a, "version: 1.20\n");
        try testing.expectEqualStrings("1.20", m.get("version").?.scalar.text);
    }
}

test "rejected constructs are named" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    try testing.expect(std.mem.indexOf(u8, (try parseErr(a, "xs:\n  - 1\n")).msg, "sequences") != null);
    try testing.expect(std.mem.indexOf(u8, (try parseErr(a, "a: &anchor 1\n")).msg, "anchors") != null);
    try testing.expect(std.mem.indexOf(u8, (try parseErr(a, "a: !!str 5\n")).msg, "tags") != null);
    try testing.expect(std.mem.indexOf(u8, (try parseErr(a, "a: {b: 1}\n")).msg, "flow") != null);
    try testing.expect(std.mem.indexOf(u8, (try parseErr(a, "---\na: 1\n")).msg, "multi-document") != null);
}

test "structural errors carry the offending line" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    { // duplicate keys
        const e = try parseErr(a, "a: 1\na: 2\n");
        try testing.expectEqual(@as(usize, 2), e.line);
        try testing.expect(std.mem.indexOf(u8, e.msg, "duplicate") != null);
    }
    { // non-identifier key
        const e = try parseErr(a, "build-time: 5.0\n");
        try testing.expect(std.mem.indexOf(u8, e.msg, "identifier") != null);
    }
    { // opened block with nothing under it
        const e = try parseErr(a, "hunger:\nother: 1\n");
        try testing.expectEqual(@as(usize, 1), e.line);
        try testing.expect(std.mem.indexOf(u8, e.msg, "nothing is indented") != null);
    }
    { // dangling open at EOF
        const e = try parseErr(a, "hunger:\n");
        try testing.expect(std.mem.indexOf(u8, e.msg, "file ends") != null);
    }
    { // dedent to an indent no block uses
        const e = try parseErr(a, "a:\n    x: 1\n  y: 2\n");
        try testing.expect(std.mem.indexOf(u8, e.msg, "matches no open block") != null);
    }
}

test "deeper nesting and dedent back to root" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const m = try parseOk(a,
        \\a:
        \\  b:
        \\    c: 1
        \\  d: 2
        \\e: 3
    );
    const b = m.get("a").?.mapping.get("b").?.mapping;
    try testing.expectEqualStrings("1", b.get("c").?.scalar.text);
    try testing.expectEqualStrings("2", m.get("a").?.mapping.get("d").?.scalar.text);
    try testing.expectEqualStrings("3", m.get("e").?.scalar.text);
}

test "review findings: the silent-corruption cases are loud now" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    { // a hash inside a value is data, not a comment (needs whitespace before #)
        const m = try parseOk(a, "id: icon#selected\nnote: value # real comment\n");
        try testing.expectEqualStrings("icon#selected", m.get("id").?.scalar.text);
        try testing.expectEqualStrings("value", m.get("note").?.scalar.text);
    }
    { // tab in indentation names itself
        const e = try parseErr(a, "a:\n\tb: 1\n");
        try testing.expect(std.mem.indexOf(u8, e.msg, "tab") != null);
    }
    { // unterminated quote is a typo, not a string
        const e = try parseErr(a, "label: \"ready\n");
        try testing.expect(std.mem.indexOf(u8, e.msg, "unterminated") != null);
    }
    { // null spellings have no kind here
        const e = try parseErr(a, "target: null\n");
        try testing.expect(std.mem.indexOf(u8, e.msg, "null") != null);
        const e2 = try parseErr(a, "target: ~\n");
        try testing.expect(std.mem.indexOf(u8, e2.msg, "null") != null);
    }
    { // '' decodes to a single apostrophe
        const m = try parseOk(a, "label: 'it''s ready'\n");
        try testing.expectEqualStrings("it's ready", m.get("label").?.scalar.text);
    }
    { // unknown double-quote escapes refuse instead of corrupting
        const e = try parseErr(a, "label: \"caf\\u00e9\"\n");
        try testing.expect(std.mem.indexOf(u8, e.msg, "unsupported escape") != null);
    }
    { // exponent-only floats are floats
        const m = try parseOk(a, "rate: 1e3\nsmall: 2E-2\n");
        try testing.expectEqual(ScalarKind.float, m.get("rate").?.scalar.kind);
        try testing.expectEqual(ScalarKind.float, m.get("small").?.scalar.kind);
    }
    { // signed leading-dot numerics hit the numeric error, not the string path
        const e = try parseErr(a, "x: -.5\n");
        try testing.expect(std.mem.indexOf(u8, e.msg, "numeric literal") != null);
    }
    { // block scalar indicators are named
        const e = try parseErr(a, "message: |\n");
        try testing.expect(std.mem.indexOf(u8, e.msg, "block scalars") != null);
    }
    { // a tab AFTER the colon is separation, not value content
        const m = try parseOk(a, "label:\tready\n");
        try testing.expectEqualStrings("ready", m.get("label").?.scalar.text);
    }
    { // YAML's infinity/NaN spellings have no kind here
        const e = try parseErr(a, "x: .inf\n");
        try testing.expect(std.mem.indexOf(u8, e.msg, "infinity") != null);
        const e2 = try parseErr(a, "y: -.Inf\n");
        try testing.expect(std.mem.indexOf(u8, e2.msg, "infinity") != null);
        const e3 = try parseErr(a, "z: .nan\n");
        try testing.expect(std.mem.indexOf(u8, e3.msg, "infinity") != null);
    }
}

test "negative numbers and exponents" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const m = try parseOk(a,
        \\a: -4
        \\b: -0.5
        \\c: 1.5e3
        \\d: 2.0E-2
    );
    try testing.expectEqual(ScalarKind.int, m.get("a").?.scalar.kind);
    try testing.expectEqual(ScalarKind.float, m.get("b").?.scalar.kind);
    try testing.expectEqual(ScalarKind.float, m.get("c").?.scalar.kind);
    try testing.expectEqual(ScalarKind.float, m.get("d").?.scalar.kind);
}
