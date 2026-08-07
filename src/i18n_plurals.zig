//! Plural categories and per-locale plural rules for RFC-I18N phase 4.
//!
//! The RFC's phase table says: "Plurals — CLDR categories
//! (`zero`/`one`/`two`/`few`/`many`/`other`) as a nested key convention with
//! per-locale category sets." This file is the CLDR side of that sentence:
//! the category vocabulary, the per-language rule table, and which categories
//! each rule can actually select for a cardinal integer count.
//!
//! Scope is deliberately minimal (the RFC names no languages): a handful of
//! rule families covering the common shapes, an easily extended tag table,
//! and `one`/`other` as the default for languages the table does not know.
//! CLDR's own root default is `other`-only, but nearly every language a game
//! ships that CLDR-root would cover is CJK-family and listed explicitly here;
//! for everything else `one`/`other` is right far more often than not, and a
//! wrong guess degrades to grammar, never to a missing string (the fallback
//! chain in i18n_phase backfills every slot).
//!
//! Rules classify the ABSOLUTE INTEGER value of the count. Fractional counts
//! are out of scope -- `tp`/`tpf` take integers, matching the RFC's non-goal
//! of locale-aware number formatting.
//!
//! NOTE: `select` here and `selectCat` in the emitted module
//! (i18n_phase.emitPluralRuntime) implement the same rules and must stay in
//! lockstep -- the unit tests below are the executable spec for both.
const std = @import("std");

/// The six CLDR plural categories, in CLDR's canonical order. The integer
/// value is the per-key variant-table index in the generated module.
pub const Category = enum(u3) {
    zero,
    one,
    two,
    few,
    many,
    other,

    pub const count = 6;

    pub fn fromName(name: []const u8) ?Category {
        inline for (@typeInfo(Category).@"enum".fields) |f| {
            if (std.mem.eql(u8, name, f.name)) return @enumFromInt(f.value);
        }
        return null;
    }
};

/// A rule family: the function from a cardinal integer count to a category.
/// One enum value per distinct CLDR rule SHAPE this ships, not per language
/// -- languages sharing a shape share a rule (en/de/es... are all .one_other).
pub const Rule = enum {
    /// No plural distinction: ja, zh, ko, th, vi, id, ms.
    other_only,
    /// one at exactly 1: en, de, es, it, nl, sv, ... (and the default).
    one_other,
    /// one at 0 and 1: fr, pt (CLDR: i = 0..1).
    one_from_zero,
    /// ru/uk/be: one (n%10=1, n%100!=11), few (n%10=2..4, n%100!=12..14),
    /// many (the rest, 0 included). CLDR's `other` is fraction-only there,
    /// unreachable for integer counts.
    east_slavic,
    /// pl: like east_slavic but `one` is exactly 1.
    polish,
    /// cs/sk: one (1), few (2..4), other (the rest). CLDR's `many` is
    /// fraction-only there, unreachable for integer counts.
    czech_slovak,
    /// ar: all six categories.
    arabic,
};

/// Language (primary subtag) -> rule. Extend by adding a row; anything
/// unlisted is `.one_other` (see the module doc for why not CLDR-root).
const tag_rules = [_]struct { lang: []const u8, rule: Rule }{
    .{ .lang = "ja", .rule = .other_only },
    .{ .lang = "zh", .rule = .other_only },
    .{ .lang = "ko", .rule = .other_only },
    .{ .lang = "th", .rule = .other_only },
    .{ .lang = "vi", .rule = .other_only },
    .{ .lang = "id", .rule = .other_only },
    .{ .lang = "ms", .rule = .other_only },
    .{ .lang = "fr", .rule = .one_from_zero },
    .{ .lang = "pt", .rule = .one_from_zero },
    .{ .lang = "ru", .rule = .east_slavic },
    .{ .lang = "uk", .rule = .east_slavic },
    .{ .lang = "be", .rule = .east_slavic },
    .{ .lang = "pl", .rule = .polish },
    .{ .lang = "cs", .rule = .czech_slovak },
    .{ .lang = "sk", .rule = .czech_slovak },
    .{ .lang = "ar", .rule = .arabic },
};

/// The rule for a BCP-47 tag. Only the primary language subtag decides --
/// pt and pt-BR pluralise alike -- and the match is case-insensitive, like
/// every other tag comparison in the i18n pipeline.
pub fn ruleForTag(tag: []const u8) Rule {
    const dash = std.mem.indexOfScalar(u8, tag, '-') orelse tag.len;
    const lang = tag[0..dash];
    for (tag_rules) |row| {
        if (std.ascii.eqlIgnoreCase(row.lang, lang)) return row.rule;
    }
    return .one_other;
}

/// Which categories `rule` can select for some integer count -- the
/// "per-locale category set" of the RFC's phasing line. Coverage warnings
/// use this: a locale missing a REACHABLE variant has a player-visible gap;
/// providing an unreachable one is harmless and stays silent.
pub fn reachable(rule: Rule) [Category.count]bool {
    var r = [_]bool{false} ** Category.count;
    switch (rule) {
        .other_only => r[@intFromEnum(Category.other)] = true,
        .one_other, .one_from_zero => {
            r[@intFromEnum(Category.one)] = true;
            r[@intFromEnum(Category.other)] = true;
        },
        .east_slavic, .polish => {
            r[@intFromEnum(Category.one)] = true;
            r[@intFromEnum(Category.few)] = true;
            r[@intFromEnum(Category.many)] = true;
        },
        .czech_slovak => {
            r[@intFromEnum(Category.one)] = true;
            r[@intFromEnum(Category.few)] = true;
            r[@intFromEnum(Category.other)] = true;
        },
        .arabic => r = [_]bool{true} ** Category.count,
    }
    return r;
}

/// The category for an absolute integer count under `rule`. The build-time
/// twin of the generated module's `selectCat`; the tests below pin both.
pub fn select(rule: Rule, n: u64) Category {
    return switch (rule) {
        .other_only => .other,
        .one_other => if (n == 1) .one else .other,
        .one_from_zero => if (n <= 1) .one else .other,
        .east_slavic => blk: {
            const m10 = n % 10;
            const m100 = n % 100;
            if (m10 == 1 and m100 != 11) break :blk .one;
            if (m10 >= 2 and m10 <= 4 and !(m100 >= 12 and m100 <= 14)) break :blk .few;
            break :blk .many;
        },
        .polish => blk: {
            if (n == 1) break :blk .one;
            const m10 = n % 10;
            const m100 = n % 100;
            if (m10 >= 2 and m10 <= 4 and !(m100 >= 12 and m100 <= 14)) break :blk .few;
            break :blk .many;
        },
        .czech_slovak => if (n == 1) .one else if (n >= 2 and n <= 4) .few else .other,
        .arabic => blk: {
            if (n == 0) break :blk .zero;
            if (n == 1) break :blk .one;
            if (n == 2) break :blk .two;
            const m100 = n % 100;
            if (m100 >= 3 and m100 <= 10) break :blk .few;
            if (m100 >= 11 and m100 <= 99) break :blk .many;
            break :blk .other;
        },
    };
}

// ---------------------------------------------------------------------------
// tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "the primary subtag decides the rule; unknown languages default to one/other" {
    try testing.expectEqual(Rule.one_other, ruleForTag("en"));
    try testing.expectEqual(Rule.one_other, ruleForTag("de-AT"));
    try testing.expectEqual(Rule.one_from_zero, ruleForTag("pt-BR"));
    try testing.expectEqual(Rule.one_from_zero, ruleForTag("fr"));
    try testing.expectEqual(Rule.east_slavic, ruleForTag("ru"));
    try testing.expectEqual(Rule.other_only, ruleForTag("ja"));
    try testing.expectEqual(Rule.arabic, ruleForTag("ar-EG"));
    // Case-insensitive, like every other tag comparison in the pipeline.
    try testing.expectEqual(Rule.one_from_zero, ruleForTag("PT-br"));
    // Unlisted: the documented default.
    try testing.expectEqual(Rule.one_other, ruleForTag("eo"));
}

test "one_other and one_from_zero -- the western European shapes" {
    try testing.expectEqual(Category.one, select(.one_other, 1));
    try testing.expectEqual(Category.other, select(.one_other, 0));
    try testing.expectEqual(Category.other, select(.one_other, 2));
    try testing.expectEqual(Category.other, select(.one_other, 21));

    try testing.expectEqual(Category.one, select(.one_from_zero, 0));
    try testing.expectEqual(Category.one, select(.one_from_zero, 1));
    try testing.expectEqual(Category.other, select(.one_from_zero, 2));
}

test "other_only never distinguishes" {
    try testing.expectEqual(Category.other, select(.other_only, 0));
    try testing.expectEqual(Category.other, select(.other_only, 1));
    try testing.expectEqual(Category.other, select(.other_only, 7));
}

test "east_slavic -- the ru/uk/be teens and tens" {
    try testing.expectEqual(Category.one, select(.east_slavic, 1));
    try testing.expectEqual(Category.one, select(.east_slavic, 21));
    try testing.expectEqual(Category.one, select(.east_slavic, 101));
    try testing.expectEqual(Category.many, select(.east_slavic, 11));
    try testing.expectEqual(Category.few, select(.east_slavic, 2));
    try testing.expectEqual(Category.few, select(.east_slavic, 24));
    try testing.expectEqual(Category.many, select(.east_slavic, 12));
    try testing.expectEqual(Category.many, select(.east_slavic, 14));
    try testing.expectEqual(Category.many, select(.east_slavic, 0));
    try testing.expectEqual(Category.many, select(.east_slavic, 5));
    try testing.expectEqual(Category.many, select(.east_slavic, 100));
}

test "polish -- one is exactly 1, few/many follow the slavic bands" {
    try testing.expectEqual(Category.one, select(.polish, 1));
    try testing.expectEqual(Category.many, select(.polish, 21));
    try testing.expectEqual(Category.few, select(.polish, 22));
    try testing.expectEqual(Category.few, select(.polish, 2));
    try testing.expectEqual(Category.many, select(.polish, 12));
    try testing.expectEqual(Category.many, select(.polish, 0));
    try testing.expectEqual(Category.many, select(.polish, 5));
}

test "czech_slovak -- few is 2..4, the rest is other" {
    try testing.expectEqual(Category.one, select(.czech_slovak, 1));
    try testing.expectEqual(Category.few, select(.czech_slovak, 2));
    try testing.expectEqual(Category.few, select(.czech_slovak, 4));
    try testing.expectEqual(Category.other, select(.czech_slovak, 5));
    try testing.expectEqual(Category.other, select(.czech_slovak, 0));
    try testing.expectEqual(Category.other, select(.czech_slovak, 22));
}

test "arabic -- all six categories" {
    try testing.expectEqual(Category.zero, select(.arabic, 0));
    try testing.expectEqual(Category.one, select(.arabic, 1));
    try testing.expectEqual(Category.two, select(.arabic, 2));
    try testing.expectEqual(Category.few, select(.arabic, 3));
    try testing.expectEqual(Category.few, select(.arabic, 103));
    try testing.expectEqual(Category.many, select(.arabic, 11));
    try testing.expectEqual(Category.many, select(.arabic, 99));
    try testing.expectEqual(Category.other, select(.arabic, 100));
    try testing.expectEqual(Category.other, select(.arabic, 102));
}

test "reachable matches what select can produce" {
    // Brute-force the contract over a dense range: every category select
    // returns is reachable, and every reachable category is hit.
    inline for (@typeInfo(Rule).@"enum".fields) |rf| {
        const rule: Rule = @enumFromInt(rf.value);
        const r = reachable(rule);
        var hit = [_]bool{false} ** Category.count;
        var n: u64 = 0;
        while (n <= 500) : (n += 1) {
            const c = select(rule, n);
            try testing.expect(r[@intFromEnum(c)]);
            hit[@intFromEnum(c)] = true;
        }
        try testing.expectEqualSlices(bool, &r, &hit);
    }
}

test "category names round-trip; non-categories do not" {
    try testing.expectEqual(Category.few, Category.fromName("few").?);
    try testing.expectEqual(Category.other, Category.fromName("other").?);
    try testing.expectEqual(@as(?Category, null), Category.fromName("others"));
    try testing.expectEqual(@as(?Category, null), Category.fromName(""));
}
