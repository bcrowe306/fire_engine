// Drive: Distortion, Ring mod, Saturation, Bit-crusher on a controller's display (docs/design/push2-devices.md):
// not built yet (the generic panel draws).
package pads

// Draws `p` (one of this family's devices): whether it did.
@(private)
fx_panel_drive :: proc(p: ^Fx_Panel) -> bool {
	_ = p
	return false
}
