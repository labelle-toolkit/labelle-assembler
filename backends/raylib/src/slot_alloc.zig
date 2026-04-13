//! Slot-reuse allocator for the raylib audio backend.
//!
//! Extracted from `audio.zig` so the pure allocation policy can be
//! unit-tested without importing `raylib` (which would drag the
//! raylib native library into the test binary).
//!
//! Policy:
//!   1. Scan `slots[1..next_id]` for a recycled (null) entry. Return
//!      the first one found — this recovers IDs freed by `unload*`.
//!   2. Otherwise use `next_id` itself if it's still within capacity,
//!      growing the high-water mark by 1. Caller bumps `next_id`
//!      after a successful insert.
//!   3. Otherwise return null — every slot is live and capacity is
//!      reached.
//!
//! Slot 0 is reserved as "no sound" (the engine's AudioInterface
//! contract treats id 0 as invalid), so the scan starts at index 1.
//!
//! The pre-fix raylib audio.zig only ever incremented `next_id`, so
//! after `capacity` load/unload cycles every ID was burned and no
//! further sounds could load. This matches what the bgfx and sdl
//! backends already do; see their `findFree{Sound,Music}Slot`
//! helpers for prior art.
const std = @import("std");

/// Find an id to use for a new slot. `slots[0]` is never returned.
/// `next_id` is the current high-water mark (first unused index).
/// The capacity is `slots.len` — taking it from the slice avoids the
/// footgun of a caller passing a separate `capacity` that disagrees
/// with the array size and ending up with an out-of-bounds id.
pub fn findFreeSlot(comptime T: type, slots: []const ?T, next_id: u32) ?u32 {
    // Scan for a recycled slot in [1, next_id).
    var i: u32 = 1;
    while (i < next_id) : (i += 1) {
        if (slots[i] == null) return i;
    }
    // No recycled slot — grow the high-water mark if there's room.
    if (next_id < slots.len) return next_id;
    return null;
}

// ── Tests ────────────────────────────────────────────────────────────

const testing = std.testing;

// Use u32 as the test payload type so tests don't need to import a
// real resource type. The allocator is generic over T; the choice is
// irrelevant to the behaviour under test.

test "findFreeSlot: empty state hands out id 1" {
    const slots = [_]?u32{null} ** 4;
    try testing.expectEqual(@as(?u32, 1), findFreeSlot(u32, &slots, 1));
}

test "findFreeSlot: monotonic fast path (no recycled slots)" {
    // Two slots already live at 1 and 2, next_id=3. Should return 3.
    var slots = [_]?u32{null} ** 4;
    slots[1] = 100;
    slots[2] = 200;
    try testing.expectEqual(@as(?u32, 3), findFreeSlot(u32, &slots, 3));
}

test "findFreeSlot: recycles the first freed slot before growing" {
    // Slot 1 is freed, slot 2 is live, next_id=3. Should return 1,
    // not 3 — recycling beats growing.
    var slots = [_]?u32{null} ** 4;
    slots[2] = 200;
    try testing.expectEqual(@as(?u32, 1), findFreeSlot(u32, &slots, 3));
}

test "findFreeSlot: recycles a freed middle slot" {
    // Slots 1, 3 live, slot 2 freed, next_id=4. Should return 2.
    var slots = [_]?u32{null} ** 8;
    slots[1] = 100;
    slots[3] = 300;
    try testing.expectEqual(@as(?u32, 2), findFreeSlot(u32, &slots, 4));
}

test "findFreeSlot: picks the lowest freed slot when multiple are free" {
    // Slots 2 and 4 freed, slots 1 and 3 live, next_id=5. Should
    // return 2 (lowest free index).
    var slots = [_]?u32{null} ** 8;
    slots[1] = 100;
    slots[3] = 300;
    try testing.expectEqual(@as(?u32, 2), findFreeSlot(u32, &slots, 5));
}

test "findFreeSlot: recycling at next_id-1 is treated as a free slot in range" {
    // Slot 3 is the most recent freed slot, 1 and 2 live, next_id=4.
    // Scan of [1, 4) finds 3 as free → return 3.
    var slots = [_]?u32{null} ** 8;
    slots[1] = 100;
    slots[2] = 200;
    try testing.expectEqual(@as(?u32, 3), findFreeSlot(u32, &slots, 4));
}

test "findFreeSlot: full high-water, room to grow" {
    // All slots in [1, next_id) are live, next_id=4, slots.len=8.
    // No recycled slot — grow to 4.
    var slots = [_]?u32{null} ** 8;
    slots[1] = 100;
    slots[2] = 200;
    slots[3] = 300;
    try testing.expectEqual(@as(?u32, 4), findFreeSlot(u32, &slots, 4));
}

test "findFreeSlot: full high-water, capacity reached → null" {
    // All slots in [1, 4) live and next_id == slots.len → can't grow.
    var slots = [_]?u32{null} ** 4;
    slots[1] = 100;
    slots[2] = 200;
    slots[3] = 300;
    try testing.expectEqual(@as(?u32, null), findFreeSlot(u32, &slots, 4));
}

test "findFreeSlot: capacity=1 always returns null (slot 0 reserved)" {
    const slots = [_]?u32{null};
    // With slots.len=1 and next_id=1, the scan range is empty and
    // the grow check fails — no usable slot.
    try testing.expectEqual(@as(?u32, null), findFreeSlot(u32, &slots, 1));
}

test "findFreeSlot: regression lock for #11" {
    // The raylib backend used to burn 255 IDs after 255 load/unload
    // cycles because it only incremented next_sound_id. With slot
    // recycling, the same scenario repeatedly hands out id 1.
    var slots = [_]?u32{null} ** 4;
    var next_id: u32 = 1;

    // Load + unload, 10 times. With the old bug, next_id would
    // reach 11 and eventually the allocator would return null. With
    // the fix, id stays at 1 every iteration.
    var cycle: u32 = 0;
    while (cycle < 10) : (cycle += 1) {
        const id = findFreeSlot(u32, &slots, next_id) orelse {
            try testing.expect(false); // Should never run out.
            return;
        };
        try testing.expectEqual(@as(u32, 1), id);
        slots[id] = 42;
        if (id == next_id) next_id += 1;
        // Unload.
        slots[id] = null;
    }
}
