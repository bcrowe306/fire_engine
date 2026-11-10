package imgui

// Fire Engine: bindings for ImGui's DockBuilder (from imgui_internal.h,
// whose C API `task deps` generates into the same library), for laying out
// docked windows in code. Not part of odin-imgui; the rest of this package
// is. ImGui marks this API as not yet stable.

@(default_calling_convention = "c")
foreign imguilib {
	@(link_name = "ImGui_DockBuilderAddNode")
	DockBuilderAddNode :: proc(node_id: ID = 0, flags: DockNodeFlags = {}) -> ID ---
	@(link_name = "ImGui_DockBuilderRemoveNode")
	DockBuilderRemoveNode :: proc(node_id: ID) ---
	@(link_name = "ImGui_DockBuilderSetNodePos")
	DockBuilderSetNodePos :: proc(node_id: ID, pos: Vec2) ---
	@(link_name = "ImGui_DockBuilderSetNodeSize")
	DockBuilderSetNodeSize :: proc(node_id: ID, size: Vec2) ---
	@(link_name = "ImGui_DockBuilderSplitNode")
	DockBuilderSplitNode :: proc(node_id: ID, split_dir: Dir, size_ratio_for_node_at_dir: f32, out_id_at_dir: ^ID, out_id_at_opposite_dir: ^ID) -> ID ---
	@(link_name = "ImGui_DockBuilderDockWindow")
	DockBuilderDockWindow :: proc(window_name: cstring, node_id: ID) ---
	@(link_name = "ImGui_DockBuilderFinish")
	DockBuilderFinish :: proc(node_id: ID) ---
	@(link_name = "ImGui_DockBuilderGetNode")
	DockBuilderGetNode :: proc(node_id: ID) -> rawptr ---
	// A bar along one side of `viewport` (the menu bar is one): the space
	// docked windows get shrinks by it. End it with End().
	@(link_name = "ImGui_BeginViewportSideBar")
	BeginViewportSideBar :: proc(name: cstring, viewport: ^Viewport, dir: Dir, size: f32, window_flags: WindowFlags) -> bool ---
}
