// Space: Delay, Reverb, Comb on a controller's display (docs/design/push2-devices.md):
// not built yet (the generic panel draws).
package pads

// Draws `p` (one of this family's devices): whether it did.
@(private)
fx_panel_space :: proc(p: ^Fx_Panel) -> bool {
	_ = p
	return false
}
