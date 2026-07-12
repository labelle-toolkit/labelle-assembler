-- behavior.lua — the Phase-1 Lua proof behavior (labelle-engine#739, epic
-- labelle-engine#237): one .lua file driving the REAL engine through the
-- Script Runtime Contract (labelle-engine#749) from the assembler's
-- generated main (labelle-assembler#593 splice + the labelle-null
-- template's bind touchpoint).
--
-- Each observable milestone logs ONE `LUA_<TOKEN>` line (payload facts are
-- encoded IN the token so CI can `grep -oE 'LUA_[A-Z0-9_]+'` and diff the
-- exact ordered sequence). Deterministic over the null backend's default
-- bounded run, LABELLE_NULL_FRAMES=5:
--
--   setup   LUA_INIT               init(): entity created + Position set
--           LUA_DECLARED_LEVEL_0.875   declared-component round-trip (see
--                                       the Hunger declaration below)
--   tick 1  LUA_TICK_1             (subscriptions from chunk load turn
--                                   ACTIVE at this tick's drain boundary)
--   tick 2  LUA_TICK_2, LUA_EMIT_OK    emit lua_ping{n=2} onto the bus
--   tick 3  LUA_ENGINE_TICK_SEEN       first engine__tick arrives (emitted
--                                       by Game.tick, drained tick 2,
--                                       inbox-dispatched at tick start)
--           LUA_EVENT_SEEN_N_2         own lua_ping round-trips back
--           LUA_TICK_3, LUA_MOVED_X_30 Position read-modify-write hit x=30
--   tick 4  LUA_TICK_4
--   tick 5  LUA_TICK_5
--
-- Why the one-frame latencies: subscriptions activate at drain boundaries
-- (no same-tick replay) and handlers run on the NEXT tick's inbox dispatch
-- — see labelle-engine/src/script_contract.zig "Event tap semantics".

local tick = 0
local ball
local engine_tick_seen = false

-- Declare-mode (labelle-assembler#585/#598, scripting v0.2.0): this ONE
-- chunk-scope line is read by two consumers. At BUILD time the real
-- labelle-declare tool (shipped in the plugin's `tools/declare`) extracts
-- it and the assembler codegens a `Hunger` struct into the target's
-- `scripting_components.zig`, registered like any components/*.zig file.
-- At RUNTIME it evaluates to a lightweight ref the Entity methods accept.
-- 0.875 = 7/8, exact in binary floating point at every width en route.
local Hunger = labelle.component("Hunger", { level = 0.875, starving = false })

-- Receive side, registered at chunk load (before init): an ENGINE event
-- that fires every frame in any game shape...
labelle.on("engine__tick", function(ev)
    if not engine_tick_seen then
        engine_tick_seen = true
        labelle.log("LUA_ENGINE_TICK_SEEN frame=" .. ev.frame_number)
    end
end)

-- ...and the game's own custom event (events/lua_ping.zig), emitted by
-- this same script — proving emit + subscribe/poll through one bus.
labelle.on("lua_ping", function(ev)
    labelle.log("LUA_EVENT_SEEN_N_" .. ev.n)
end)

function init()
    ball = Entity.new()
    ball:set("Position", { x = 0, y = 0 })
    labelle.log("LUA_INIT id=" .. labelle.u64str(ball.id))

    -- Declared-component round-trip. "Hunger" resolves in the engine's
    -- by-name registry dispatch ONLY because the build extracted the
    -- declaration above and codegened it. The write is deliberately
    -- PARTIAL — `level` is absent — so the read-back 0.875 can only be
    -- the DECLARED default having traveled schema → codegen → registry →
    -- the contract's parse-with-defaults, through the real ECS and back;
    -- `starving = true` (non-default) proves the written half too. The
    -- token is derived from the get, not a constant.
    if ball:set(Hunger, { starving = true }) then
        local h = ball:get(Hunger)
        if h and h.starving then
            labelle.log("LUA_DECLARED_LEVEL_" .. h.level)
        else
            labelle.log("LUA_DECLARED_READBACK_BAD")
        end
    else
        labelle.log("LUA_DECLARED_SET_FAIL")
    end
end

function update(dt)
    tick = tick + 1
    labelle.log("LUA_TICK_" .. tick)

    -- Move the entity: +10 x per tick through the contract's
    -- component get/set (Position routes through setPosition, so render
    -- dirty-tracking fires exactly as for Zig scripts).
    local pos = ball:get("Position")
    pos.x = pos.x + 10
    ball:set("Position", pos)
    if pos.x == 30 then
        labelle.log("LUA_MOVED_X_30")
    end

    -- Emit on tick 2; the handler above observes it on tick 3.
    if tick == 2 then
        if labelle.emit("lua_ping", { n = 2 }) then
            labelle.log("LUA_EMIT_OK")
        else
            labelle.log("LUA_EMIT_FAIL")
        end
    end
end
