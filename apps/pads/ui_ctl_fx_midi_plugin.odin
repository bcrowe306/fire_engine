// MIDI and plug-ins: the pad's MIDI effects, plug-ins (effects and instruments) on a controller's display (docs/design/push2-devices.md):
// not built yet (the generic panel draws).
package pads

// Draws `p` (one of this family's devices): whether it did.
@(private)
fx_panel_midi_plugin :: proc(p: ^Fx_Panel) -> bool {
	_ = p
	return false
}
