//! Game-script CustomNode source for the flows-smoke end-to-end fixture
//! (labelle-assembler#240). Exports a `pub const FlowNodes` block with a
//! single void `log`-style node so the assembler's phase-2 FlowNodes
//! walk discovers it, promotes this file to a NAMED build module
//! (`script__logger`, #240 Gap 2), and lowers a `CustomNode` reference
//! in `custom.flow.jsonc` to
//! `game.PluginFlowNodes.logger__log_i32.impl(game, <arg0>)`.
//!
//! The whole point of the fixture is to prove that path COMPILES — the
//! shim must expose `PluginFlowNodes` (Gap 1) and this file must live in
//! exactly one module despite being reached by BOTH `AllScripts` (root
//! module, for the `setup` hook below) AND the shim's `PluginFlowNodes`
//! (game module). Without the named-module promotion the generated code
//! errors with "file exists in modules 'root' and 'game'".

const std = @import("std");

/// A regular game-script hook — its mere presence makes `AllScripts`
/// path-import this file into the root module, which is exactly the
/// half of the dual-module conflict the named-module promotion resolves.
pub fn setup(game: anytype) void {
    _ = game;
}

/// Void (command) flow node. `engine.core` re-exports labelle-core,
/// where the `flow.FlowNode` factory lives.
///
/// Signature note: flow-codegen lowers a `CustomNode` to
/// `game.PluginFlowNodes.<qualified>.impl(game, <pins...>)`, where
/// `<qualified>` is the FlowNode struct VALUE. Zig resolves `value.impl(...)`
/// via UFCS and binds that struct value to `impl`'s first parameter (it
/// must be `anytype` to accept it). So the first param here is the
/// UFCS-bound FlowNode receiver (unused), the second is the
/// codegen-threaded `game`, and the rest are the positional input pins.
/// Collapsing that leading receiver into the call shape is flow-codegen's
/// remaining work (flow-codegen#20) — this fixture's job is to prove the
/// assembler-side MODULE WIRING (#240 Gaps 1+2) compiles, which requires
/// the named-module promotion + shim `PluginFlowNodes` this PR adds.
fn flowLogI32(_node: anytype, game: anytype, value: i32) void {
    _ = _node;
    _ = game;
    std.debug.print("logger.log_i32: {d}\n", .{value});
}

pub const FlowNodes = struct {
    pub const log_i32 = engine.core.flow.FlowNode(.{
        .impl = flowLogI32,
        .docs = "Print a labeled integer to the debug console.",
        .pins = .{
            .value = .{ .label = "Value" },
        },
    });
};

const engine = @import("labelle-engine");
