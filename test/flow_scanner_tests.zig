//! Shim that re-exports per-domain flow_scanner test sections so a
//! single `zspec.runAll` dispatcher walks them all. The split per-domain
//! files under `test/flow_scanner/` are the canonical location for new
//! tests — this file just stitches them together so the overall test
//! count matches the pre-split layout (issue #185).

const std = @import("std");
const zspec = @import("zspec");

test {
    zspec.runAll(@This());
}

// Each new test belongs in one of the per-domain files below. Add a
// `pub const NewSection = struct { test "..." {} };` there and re-export
// it here with `pub const NewSection = @import("flow_scanner/<file>").NewSection;`.

const discovery = @import("flow_scanner/discovery_tests.zig");
pub const FlowScanner = discovery.FlowScanner;
pub const FlowSortOrder = discovery.FlowSortOrder;
pub const FlowEventHandlerMarker = discovery.FlowEventHandlerMarker;
pub const CustomNodeRegistry = discovery.CustomNodeRegistry;

const integration = @import("flow_scanner/integration_tests.zig");
pub const AllScriptsIntegration = integration.AllScriptsIntegration;
pub const GameModuleBinding = integration.GameModuleBinding;

const plugin_events = @import("flow_scanner/plugin_events_tests.zig");
pub const PluginEvents = plugin_events.PluginEvents;

const handler_wiring = @import("flow_scanner/handler_wiring_tests.zig");
pub const FlowHandlerWiring = handler_wiring.FlowHandlerWiring;

const plugin_nodes = @import("flow_scanner/plugin_nodes_tests.zig");
pub const PluginFlowNodesAndPinStyles = plugin_nodes.PluginFlowNodesAndPinStyles;

const flow_decls = @import("flow_scanner/flow_decls_tests.zig");
pub const FlowDeclsDiscovery = flow_decls.FlowDeclsDiscovery;

const coercions = @import("flow_scanner/coercions_tests.zig");
pub const PluginCoercionsDiscovery = coercions.PluginCoercionsDiscovery;
