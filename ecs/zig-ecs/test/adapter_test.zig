const std = @import("std");
const testing = std.testing;
const Adapter = @import("ecs");

const Entity = Adapter.Entity;
const Position = struct { x: f32 = 0, y: f32 = 0 };
const Health = struct { current: f32 = 100, max: f32 = 100 };
const Tag = struct { label: u32 = 0 };

test "createEntity and entityExists" {
    var ecs = Adapter.init(testing.allocator);
    defer ecs.deinit();

    const e = ecs.createEntity();
    try testing.expect(ecs.entityExists(e));
    try testing.expectEqual(@as(usize, 1), ecs.entityCount());
}

test "destroyEntity removes entity" {
    var ecs = Adapter.init(testing.allocator);
    defer ecs.deinit();

    const e = ecs.createEntity();
    ecs.destroyEntity(e);
    try testing.expect(!ecs.entityExists(e));
    try testing.expectEqual(@as(usize, 0), ecs.entityCount());
}

test "addComponent and getComponent" {
    var ecs = Adapter.init(testing.allocator);
    defer ecs.deinit();

    const e = ecs.createEntity();
    ecs.addComponent(e, Position{ .x = 10, .y = 20 });

    const pos = ecs.getComponent(e, Position);
    try testing.expect(pos != null);
    try testing.expectEqual(@as(f32, 10), pos.?.x);
    try testing.expectEqual(@as(f32, 20), pos.?.y);
}

test "removeComponent removes component" {
    var ecs = Adapter.init(testing.allocator);
    defer ecs.deinit();

    const e = ecs.createEntity();
    ecs.addComponent(e, Tag{ .label = 42 });
    try testing.expect(ecs.hasComponent(e, Tag));

    ecs.removeComponent(e, Tag);
    try testing.expect(!ecs.hasComponent(e, Tag));
}

test "getComponent returns null for destroyed entity" {
    var ecs = Adapter.init(testing.allocator);
    defer ecs.deinit();

    const e = ecs.createEntity();
    ecs.addComponent(e, Position{ .x = 5, .y = 5 });
    ecs.destroyEntity(e);

    try testing.expectEqual(@as(?*Position, null), ecs.getComponent(e, Position));
}

test "view returns only alive entities" {
    var ecs = Adapter.init(testing.allocator);
    defer ecs.deinit();

    const e1 = ecs.createEntity();
    ecs.addComponent(e1, Tag{ .label = 1 });
    const e2 = ecs.createEntity();
    ecs.addComponent(e2, Tag{ .label = 2 });
    const e3 = ecs.createEntity();
    ecs.addComponent(e3, Tag{ .label = 3 });

    ecs.destroyEntity(e2);

    var count: usize = 0;
    var v = ecs.view(.{Tag}, .{});
    defer v.deinit();
    while (v.next()) |entity| {
        try testing.expect(ecs.entityExists(entity));
        count += 1;
    }
    try testing.expectEqual(@as(usize, 2), count);
}

test "destroyEntity then create leaves only new entity alive" {
    var ecs = Adapter.init(testing.allocator);
    defer ecs.deinit();

    const e1 = ecs.createEntity();
    ecs.destroyEntity(e1);
    const e2 = ecs.createEntity();

    try testing.expect(ecs.entityExists(e2));
    try testing.expect(!ecs.entityExists(e1));
    try testing.expectEqual(@as(usize, 1), ecs.entityCount());
}

test "multiple components on same entity" {
    var ecs = Adapter.init(testing.allocator);
    defer ecs.deinit();

    const e = ecs.createEntity();
    ecs.addComponent(e, Position{ .x = 1, .y = 2 });
    ecs.addComponent(e, Health{ .current = 50, .max = 100 });
    ecs.addComponent(e, Tag{ .label = 99 });

    try testing.expect(ecs.hasComponent(e, Position));
    try testing.expect(ecs.hasComponent(e, Health));
    try testing.expect(ecs.hasComponent(e, Tag));

    ecs.destroyEntity(e);

    try testing.expect(!ecs.hasComponent(e, Position));
    try testing.expect(!ecs.hasComponent(e, Health));
    try testing.expect(!ecs.hasComponent(e, Tag));
}

test "view after destroyEntity returns clean results" {
    var ecs = Adapter.init(testing.allocator);
    defer ecs.deinit();

    var entities: [10]Entity = undefined;
    for (&entities, 0..) |*e, i| {
        e.* = ecs.createEntity();
        ecs.addComponent(e.*, Position{ .x = @floatFromInt(i), .y = 0 });
        ecs.addComponent(e.*, Tag{ .label = @intCast(i) });
    }

    for (entities, 0..) |e, i| {
        if (i % 2 == 1) ecs.destroyEntity(e);
    }

    var v = ecs.view(.{Tag}, .{});
    defer v.deinit();
    var count: usize = 0;
    while (v.next()) |entity| {
        try testing.expect(ecs.entityExists(entity));
        const tag = ecs.getComponent(entity, Tag).?;
        try testing.expect(tag.label % 2 == 0);
        count += 1;
    }
    try testing.expectEqual(@as(usize, 5), count);
}

test "double destroyEntity is safe in release mode" {
    if (comptime @import("builtin").mode == .Debug) return;
    var ecs = Adapter.init(testing.allocator);
    defer ecs.deinit();

    const e = ecs.createEntity();
    ecs.addComponent(e, Tag{ .label = 1 });
    ecs.destroyEntity(e);

    ecs.destroyEntity(e);

    try testing.expectEqual(@as(usize, 0), ecs.entityCount());
    try testing.expect(!ecs.entityExists(e));
}

test "hasComponent returns false for destroyed entity" {
    var ecs = Adapter.init(testing.allocator);
    defer ecs.deinit();

    const e = ecs.createEntity();
    ecs.addComponent(e, Tag{ .label = 1 });
    ecs.addComponent(e, Position{ .x = 5, .y = 10 });
    ecs.destroyEntity(e);

    try testing.expect(!ecs.hasComponent(e, Tag));
    try testing.expect(!ecs.hasComponent(e, Position));
}

test "addComponent replaces existing component" {
    var ecs = Adapter.init(testing.allocator);
    defer ecs.deinit();

    const e = ecs.createEntity();
    ecs.addComponent(e, Tag{ .label = 1 });
    try testing.expectEqual(@as(u32, 1), ecs.getComponent(e, Tag).?.label);

    ecs.addComponent(e, Tag{ .label = 99 });
    try testing.expectEqual(@as(u32, 99), ecs.getComponent(e, Tag).?.label);
}

test "query excludes destroyed entities" {
    var ecs = Adapter.init(testing.allocator);
    defer ecs.deinit();

    const e1 = ecs.createEntity();
    ecs.addComponent(e1, Tag{ .label = 1 });
    const e2 = ecs.createEntity();
    ecs.addComponent(e2, Tag{ .label = 2 });

    ecs.destroyEntity(e1);

    var q = ecs.query(.{Tag});
    defer q.deinit(testing.allocator);
    var count: usize = 0;
    while (q.next()) |result| {
        try testing.expect(ecs.entityExists(result.entity));
        try testing.expectEqual(@as(u32, 2), result.comp_0.label);
        count += 1;
    }
    try testing.expectEqual(@as(usize, 1), count);
}

test "destroy and recreate cycle preserves integrity" {
    var ecs = Adapter.init(testing.allocator);
    defer ecs.deinit();

    for (0..50) |i| {
        const e = ecs.createEntity();
        ecs.addComponent(e, Tag{ .label = @intCast(i) });
        ecs.addComponent(e, Position{ .x = @floatFromInt(i), .y = 0 });
        ecs.destroyEntity(e);
    }

    try testing.expectEqual(@as(usize, 0), ecs.entityCount());

    for (0..10) |i| {
        const e = ecs.createEntity();
        ecs.addComponent(e, Tag{ .label = @intCast(i + 100) });
        try testing.expect(ecs.entityExists(e));
        try testing.expectEqual(@as(u32, @intCast(i + 100)), ecs.getComponent(e, Tag).?.label);
    }
    try testing.expectEqual(@as(usize, 10), ecs.entityCount());
}

// ── Regression tests for #13 ─────────────────────────────────────────
//
// The pre-fix adapter materialised every view into a heap-allocated
// ArrayList on each call. The replacement holds a borrowed slice into
// zig-ecs storage and reimplements multi-include filtering inline.
// Locks the new behaviour across single-include, multi-include, and
// exclude cases.

test "view: multi-include filter only returns entities with all components" {
    var ecs = Adapter.init(testing.allocator);
    defer ecs.deinit();

    // e1: Position + Health
    const e1 = ecs.createEntity();
    ecs.addComponent(e1, Position{ .x = 1, .y = 1 });
    ecs.addComponent(e1, Health{ .current = 100 });
    // e2: Position only (should be filtered out)
    const e2 = ecs.createEntity();
    ecs.addComponent(e2, Position{ .x = 2, .y = 2 });
    // e3: Health only (should be filtered out)
    const e3 = ecs.createEntity();
    ecs.addComponent(e3, Health{ .current = 50 });
    // e4: Position + Health + Tag (superset — still matches)
    const e4 = ecs.createEntity();
    ecs.addComponent(e4, Position{ .x = 4, .y = 4 });
    ecs.addComponent(e4, Health{ .current = 80 });
    ecs.addComponent(e4, Tag{ .label = 99 });

    var seen_e1 = false;
    var seen_e4 = false;
    var total: usize = 0;

    var v = ecs.view(.{ Position, Health }, .{});
    defer v.deinit();
    while (v.next()) |entity| {
        total += 1;
        try testing.expect(ecs.hasComponent(entity, Position));
        try testing.expect(ecs.hasComponent(entity, Health));
        if (entity == e1) seen_e1 = true;
        if (entity == e4) seen_e4 = true;
        try testing.expect(entity != e2 and entity != e3);
    }

    try testing.expectEqual(@as(usize, 2), total);
    try testing.expect(seen_e1);
    try testing.expect(seen_e4);
}

test "view: exclude filter skips entities that have the excluded component" {
    var ecs = Adapter.init(testing.allocator);
    defer ecs.deinit();

    // Three entities with Tag, one also has Health.
    const e1 = ecs.createEntity();
    ecs.addComponent(e1, Tag{ .label = 1 });
    const e2 = ecs.createEntity();
    ecs.addComponent(e2, Tag{ .label = 2 });
    ecs.addComponent(e2, Health{ .current = 100 });
    const e3 = ecs.createEntity();
    ecs.addComponent(e3, Tag{ .label = 3 });

    // Tag, no Health — should return e1 and e3 only.
    var seen_e1 = false;
    var seen_e3 = false;
    var total: usize = 0;

    var v = ecs.view(.{Tag}, .{Health});
    defer v.deinit();
    while (v.next()) |entity| {
        total += 1;
        try testing.expect(entity != e2);
        try testing.expect(!ecs.hasComponent(entity, Health));
        if (entity == e1) seen_e1 = true;
        if (entity == e3) seen_e3 = true;
    }

    try testing.expectEqual(@as(usize, 2), total);
    try testing.expect(seen_e1);
    try testing.expect(seen_e3);
}

test "view: empty registry returns zero entities without crashing" {
    var ecs = Adapter.init(testing.allocator);
    defer ecs.deinit();

    var v = ecs.view(.{Tag}, .{});
    defer v.deinit();
    var total: usize = 0;
    while (v.next()) |_| total += 1;
    try testing.expectEqual(@as(usize, 0), total);
}

test "view: combined include + exclude respects both filters" {
    var ecs = Adapter.init(testing.allocator);
    defer ecs.deinit();

    // e1: Position + Tag — matches (Position ∧ Tag, no Health)
    const e1 = ecs.createEntity();
    ecs.addComponent(e1, Position{ .x = 1, .y = 1 });
    ecs.addComponent(e1, Tag{ .label = 1 });
    // e2: Position + Tag + Health — excluded (has Health)
    const e2 = ecs.createEntity();
    ecs.addComponent(e2, Position{ .x = 2, .y = 2 });
    ecs.addComponent(e2, Tag{ .label = 2 });
    ecs.addComponent(e2, Health{ .current = 50 });
    // e3: Position only — missing Tag
    const e3 = ecs.createEntity();
    ecs.addComponent(e3, Position{ .x = 3, .y = 3 });
    // e4: Tag only — missing Position (the driving type)
    const e4 = ecs.createEntity();
    ecs.addComponent(e4, Tag{ .label = 4 });

    var v = ecs.view(.{ Position, Tag }, .{Health});
    defer v.deinit();
    var total: usize = 0;
    while (v.next()) |entity| {
        total += 1;
        try testing.expectEqual(e1, entity);
    }
    try testing.expectEqual(@as(usize, 1), total);
}

test "view: does not allocate — can be called repeatedly without leaks" {
    // The old materialising adapter would have allocated a fresh
    // ArrayList buffer on every iteration of the outer loop. With
    // std.testing.allocator's leak detection, any leak would abort
    // the test binary — so just hammering view() in a tight loop is
    // a negative regression lock.
    var ecs = Adapter.init(testing.allocator);
    defer ecs.deinit();

    for (0..20) |i| {
        const e = ecs.createEntity();
        ecs.addComponent(e, Tag{ .label = @intCast(i) });
    }

    var outer: usize = 0;
    while (outer < 100) : (outer += 1) {
        var v = ecs.view(.{Tag}, .{});
        // Deliberately no `defer v.deinit()` — the new view owns
        // no heap memory, so dropping it without deinit must not
        // leak. If it did, testing.allocator would panic at test
        // exit.
        var inner: usize = 0;
        while (v.next()) |_| inner += 1;
        try testing.expectEqual(@as(usize, 20), inner);
    }
}
