//! Custom game event for the scripting smoke: the Lua behavior emits
//! `lua_ping` on tick 2 (`labelle.emit("lua_ping", { n = 2 })` → the
//! Script Runtime Contract's `labelle_event_emit` parses this struct from
//! JSON and buffers it on the REAL engine bus) and observes it back on
//! tick 3 through the subscribe/poll drain — proving emit AND receive
//! round-trip through `GameEvents`, not a mock.
pub const LuaPing = struct { n: i32 };
