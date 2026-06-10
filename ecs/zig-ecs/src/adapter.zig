/// zig-ecs adapter — satisfies the labelle-core Ecs(Impl) contract.
/// Wraps prime31/zig-ecs (EnTT port) with the required interface.
const std = @import("std");
const builtin = @import("builtin");
const zig_ecs = @import("zig-ecs");

const is_debug = builtin.mode == .Debug;

/// External entity type — plain u32 for engine compatibility.
pub const Entity = u32;

/// Internal zig-ecs entity type (packed struct, 32 bits).
const InternalEntity = zig_ecs.Entity;

const Self = @This();

/// Debug-only: panic with a clear message when an invalid entity
/// is passed to a mutating ECS method. In release builds this is
/// a no-op — the underlying zig-ecs asserts are stripped anyway.
fn assertValid(self: *Self, entity: Entity, comptime operation: []const u8) void {
    if (comptime is_debug) {
        if (!self.inner.valid(toInternal(entity))) {
            std.debug.print("{s} on invalid entity {d}\n", .{ operation, entity });
            @panic(operation ++ " on invalid entity");
        }
    }
}

inner: zig_ecs.Registry,
entity_count: usize,
alive_entities: std.ArrayListUnmanaged(Entity),
alloc: std.mem.Allocator,
/// Unique per-adapter id, used to validate the per-component-type storage
/// cache (`cachedStorage`). Keying the cache on this id rather than on
/// `&self.inner` makes it immune to a registry being deinit'd and a new one
/// allocated at the *same address* — that new adapter gets a fresh id, so
/// the stale cached storage pointer is never returned.
/// u32 (not u64): wasm32 baseline can't do 64-bit atomics (the `fetchAdd`
/// below), and 4B unique ids per process is far more than enough for a
/// cache-validation key. See labelle-engine#618.
instance_id: u32,

/// Monotonic source for `instance_id`. Starts at 1 so the cache's `id == 0`
/// sentinel never matches a live adapter.
var next_instance_id: std.atomic.Value(u32) = .init(1);

fn toInternal(entity: Entity) InternalEntity {
    return @bitCast(entity);
}

fn toExternal(entity: InternalEntity) Entity {
    return @bitCast(entity);
}

pub fn init(allocator: std.mem.Allocator) Self {
    return .{
        .inner = zig_ecs.Registry.init(allocator),
        .entity_count = 0,
        .alive_entities = .empty,
        .alloc = allocator,
        .instance_id = next_instance_id.fetchAdd(1, .monotonic),
    };
}

pub fn deinit(self: *Self) void {
    self.alive_entities.deinit(self.alloc);
    self.inner.deinit();
}

pub fn createEntity(self: *Self) Entity {
    const entity = self.inner.create();
    self.entity_count += 1;
    const ext = toExternal(entity);
    self.alive_entities.append(self.alloc, ext) catch @panic("OOM");
    return ext;
}

pub fn destroyEntity(self: *Self, entity: Entity) void {
    self.assertValid(entity, "destroyEntity");
    const ie = toInternal(entity);
    if (!self.inner.valid(ie)) return;
    self.inner.destroy(ie);
    self.entity_count -= 1;
    for (self.alive_entities.items, 0..) |e, idx| {
        if (e == entity) {
            _ = self.alive_entities.swapRemove(idx);
            break;
        }
    }
}

pub fn entityExists(self: *Self, entity: Entity) bool {
    return self.inner.valid(toInternal(entity));
}

pub fn entityCount(self: *Self) usize {
    return self.entity_count;
}

/// Zero-sized marker components (`struct {}`) are a legitimate ECS
/// pattern — a tag with no payload. zig-ecs's `component_storage`
/// registers a typed instance array and emits a 16+-frame-deep
/// `@compileError("This method is not available to zero-sized
/// components")` the moment anything touches `tryGet`/`get`. But the
/// underlying sparse-set side of the storage (add / contains / remove /
/// data) is fine for empty structs — `addOrReplace` already special-
/// cases them. This adapter bypasses the typed-payload path entirely
/// for `@sizeOf(T) == 0` and uses only the sparse-set primitives, so
/// `pub const Marker = struct {};` flows through the engine without
/// any padding workaround (#57).
///
/// For `getComponent` on a zero-sized type there is no real instance
/// to return — every value of `T` is identical. We return a pointer
/// to a comptime-known empty singleton so the engine's query layer
/// (which holds `*T` in its result tuples) stays happy.
fn emptySingleton(comptime T: type) *T {
    comptime std.debug.assert(@sizeOf(T) == 0);
    const S = struct {
        var value: T = .{};
    };
    return &S.value;
}

/// Presence check that works for both sized and zero-sized component
/// types. zig-ecs's `tryGet` compile-errors for `@sizeOf(T) == 0`, so
/// for zero-sized types we drop down to the sparse-set `contains`
/// primitive which is safe (see #57). `contains` already does its own
/// version check internally (equivalent to `valid(ie)`), so there's no
/// need for an explicit gate here — and for sized types `contains` is
/// cheaper than `tryGet != null` because it skips the instance-pointer
/// calculation. `inline` keeps the call site tight inside View.next().
/// Resolve the storage for component type `T`, memoizing the pointer per
/// `T` (perf, #509). `Registry.assure(T)` re-hashes a *comptime-constant*
/// type id into a HashMap on EVERY component access to find a storage
/// pointer that never changes for a given `T` over the registry's lifetime
/// — profiling a 100-worker scene showed this `assure` HashMap path as the
/// single biggest per-tick CPU cost (the `HashMapUnmanaged(u32,*anyopaque)`
/// + Wyhash family). The cache drops it ~96%, going straight to the
/// sparse-set lookup, and lifted Debug FPS ~+8% median / +24% at the dips.
///
/// `Cache` is a per-`T`, **threadlocal** static (one instantiation per
/// component type, one copy per thread). Threadlocal is what keeps this
/// race-free: the original `assure` map lives on the per-registry
/// `self.components`, but a plain process-wide static would be shared across
/// every adapter and thread — so any concurrent ECS access (e.g. a worker
/// thread) would race on it. Per-thread storage removes the race entirely
/// while staying far cheaper than the HashMap probe; each thread just
/// re-resolves once per `T` on first touch.
///
/// The cache is validated against `self.instance_id`, not `&self.inner`, so
/// a registry recreated at a reused address (new adapter → new id) cleanly
/// misses and re-resolves rather than returning a freed storage pointer.
inline fn cachedStorage(self: *Self, comptime T: type) @TypeOf(self.inner.assure(T)) {
    const StoragePtr = @TypeOf(self.inner.assure(T));
    const Cache = struct {
        threadlocal var ptr: ?StoragePtr = null;
        threadlocal var id: u32 = 0;
    };
    if (Cache.ptr) |p| {
        if (Cache.id == self.instance_id) return p;
    }
    const s = self.inner.assure(T);
    Cache.ptr = s;
    Cache.id = self.instance_id;
    return s;
}

inline fn storageContains(self: *Self, comptime T: type, ie: InternalEntity) bool {
    return self.cachedStorage(T).contains(ie);
}

pub fn addComponent(self: *Self, entity: Entity, component: anytype) void {
    self.assertValid(entity, "addComponent(" ++ @typeName(@TypeOf(component)) ++ ")");
    self.inner.addOrReplace(toInternal(entity), component);
}

pub fn getComponent(self: *Self, entity: Entity, comptime T: type) ?*T {
    if (comptime @sizeOf(T) == 0) {
        return if (self.storageContains(T, toInternal(entity))) emptySingleton(T) else null;
    }
    return self.cachedStorage(T).tryGet(toInternal(entity));
}

pub fn hasComponent(self: *Self, entity: Entity, comptime T: type) bool {
    return self.storageContains(T, toInternal(entity));
}

pub fn removeComponent(self: *Self, entity: Entity, comptime T: type) void {
    self.assertValid(entity, "removeComponent(" ++ @typeName(T) ++ ")");
    self.inner.remove(T, toInternal(entity));
}

/// View type — iterates matching entities, converting to external Entity.
///
/// The underlying storage for the first include component is borrowed
/// directly via `basicView(T).data()`, which hands back the dense entity
/// slice owned by the zig-ecs registry. Iteration walks that slice
/// backwards (matching the old `reverseIterator` order) without
/// copying or allocating anything — the pre-refactor adapter
/// materialised the whole result list into a fresh `ArrayList` on
/// every `view()` call, which dominated per-frame allocator pressure
/// for systems that loop via views (#13).
///
/// For multi-include / exclude views, the adapter reimplements the
/// filter loop inline at `next()` time via `storageContains`, which
/// dispatches to `tryGet` for sized types and to the sparse-set
/// `contains` primitive for zero-sized marker components (see #57).
/// This avoids zig-ecs's `MultiView.Iterator`, which stores a self
/// pointer (`view: *Self`) back into its originating `MultiView`
/// struct — returning the iterator from `view()` would leave that
/// pointer dangling after return-by-value.
pub fn View(comptime _includes: anytype, comptime _excludes: anytype) type {
    comptime validateComponentTuple(_includes);
    comptime validateComponentTuple(_excludes);
    comptime std.debug.assert(_includes.len >= 1);
    return struct {
        backend: *Self,
        /// Dense entity slice from the first include type's storage.
        /// Walked backwards via `index` to mirror `reverseIterator`.
        /// Stable: owned by the registry, not by this struct.
        entities: []const InternalEntity,
        index: usize,

        const ViewSelf = @This();
        const is_single = _includes.len == 1 and _excludes.len == 0;

        pub fn next(self: *ViewSelf) ?Entity {
            while (self.index > 0) {
                self.index -= 1;
                const internal = self.entities[self.index];
                const external = toExternal(internal);

                if (comptime !is_single) {
                    // Candidate must have every *other* include component.
                    // First include is already satisfied — it's the one
                    // whose storage we're iterating.
                    var has_all = true;
                    inline for (1.._includes.len) |i| {
                        const T = _includes[i];
                        if (!storageContains(self.backend, T, internal)) {
                            has_all = false;
                            break;
                        }
                    }
                    if (!has_all) continue;

                    // And must not have any excluded component.
                    var any_excluded = false;
                    inline for (0.._excludes.len) |i| {
                        const T = _excludes[i];
                        if (storageContains(self.backend, T, internal)) {
                            any_excluded = true;
                            break;
                        }
                    }
                    if (any_excluded) continue;
                }

                return external;
            }
            return null;
        }

        /// No-op retained for API compatibility — the old view
        /// implementation owned a heap buffer that needed freeing.
        pub fn deinit(_: *ViewSelf) void {}
    };
}

/// Create a view iterating entities with the given include/exclude filters.
///
/// `view()` does no work beyond a single pointer grab into the
/// registry's storage for `includes[0]`. Iteration cost is paid in
/// `next()`, walking the dense entity slice and (for multi-views)
/// filtering by component membership via `self.inner.tryGet`.
///
/// ## Iteration stability
///
/// The returned `View` borrows a slice directly from the registry
/// storage for the first include component. Adding or removing
/// components of that type during iteration may grow/shrink the
/// underlying storage and invalidate the slice — do not mutate the
/// driving component type while a view over it is live. Mutating
/// *other* component types is fine: the filter loop reads them
/// fresh via `storageContains` on each candidate.
///
/// ## Performance tip: put the sparsest component first
///
/// `includes[0]` drives iteration — the view walks every entity
/// with that component and filters the rest inline. Put the
/// smallest-population component first for the tightest loop.
/// `view(.{Projectile, Position}, .{})` is much faster than
/// `view(.{Position, Projectile}, .{})` in a game with many
/// positioned entities and few projectiles.
pub fn view(self: *Self, comptime includes: anytype, comptime excludes: anytype) View(includes, excludes) {
    const basic = self.inner.basicView(includes[0]);
    const entities = basic.data();
    return .{
        .backend = self,
        .entities = entities,
        .index = entities.len,
    };
}

/// Validates that `components` is a tuple of types.
fn validateComponentTuple(comptime components: anytype) void {
    const info = @typeInfo(@TypeOf(components));
    if (info != .@"struct" or !info.@"struct".is_tuple)
        @compileError("query() expects a tuple of component types, e.g. .{Pos, Vel}");
    inline for (info.@"struct".fields) |field| {
        if (field.type != type)
            @compileError("query() tuple elements must be types, got: " ++ @typeName(field.type));
    }
}

fn QueryResultType(comptime components: anytype) type {
    comptime validateComponentTuple(components);
    const fields_info = @typeInfo(@TypeOf(components)).@"struct".fields;
    var field_names: [fields_info.len + 1][]const u8 = undefined;
    var field_types: [fields_info.len + 1]type = undefined;
    var field_attrs: [fields_info.len + 1]std.builtin.Type.StructField.Attributes = undefined;
    field_names[0] = "entity";
    field_types[0] = Entity;
    field_attrs[0] = .{};
    for (fields_info, 0..) |_, i| {
        const T = components[i];
        const name = std.fmt.comptimePrint("comp_{d}", .{i});
        field_names[i + 1] = name;
        field_types[i + 1] = *T;
        field_attrs[i + 1] = .{};
    }
    return @Struct(.auto, null, &field_names, &field_types, &field_attrs);
}

/// QueryIterator type for this backend.
pub fn QueryIterator(comptime components: anytype) type {
    comptime validateComponentTuple(components);
    return struct {
        backend: *Self,
        entities: std.ArrayListUnmanaged(Entity),
        index: usize,

        const QI = @This();
        pub const Result = QueryResultType(components);

        pub fn next(self_qi: *QI) ?Result {
            while (self_qi.index < self_qi.entities.items.len) {
                const entity = self_qi.entities.items[self_qi.index];
                self_qi.index += 1;

                var has_all = true;
                inline for (@typeInfo(@TypeOf(components)).@"struct".fields, 0..) |_, i| {
                    const T = components[i];
                    if (self_qi.backend.getComponent(entity, T) == null) {
                        has_all = false;
                        break;
                    }
                }
                if (!has_all) continue;

                var result: Result = undefined;
                result.entity = entity;
                inline for (@typeInfo(@TypeOf(components)).@"struct".fields, 0..) |_, i| {
                    const T = components[i];
                    @field(result, std.fmt.comptimePrint("comp_{d}", .{i})) = self_qi.backend.getComponent(entity, T).?;
                }
                return result;
            }
            return null;
        }

        pub fn deinit(self_qi: *QI, allocator: std.mem.Allocator) void {
            self_qi.entities.deinit(allocator);
        }
    };
}

/// Query entities with direct component access.
pub fn query(self: *Self, comptime components: anytype) QueryIterator(components) {
    var entities: std.ArrayListUnmanaged(Entity) = .empty;
    entities.appendSlice(self.alloc, self.alive_entities.items) catch @panic("OOM");
    return .{
        .backend = self,
        .entities = entities,
        .index = 0,
    };
}

