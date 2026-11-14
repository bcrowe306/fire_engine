// Pads' state and actions, without a window: the model (the project and
// its engine), and the app's own state around it as it moves out of the
// UI, module by module (see docs/design/api.md). The API (`apps/pads/api`)
// and the UI (package `pads`) both import it; it imports no ImGui.
package pads_core

import app "app:core"
import pm "../model"

// The app's state that isn't drawing: what the API acts on. Pads' `App`
// embeds it (`using`), so the UI reads it as before.
Core :: struct {
	bus:       app.Bus,
	host:      app.Host,
	m:         pm.Model,
	capture:   pm.Capture,   // recording into the sequence (Rec)
	transport: Transport,    // the transport's own state (tap tempo, Stop pressed twice)
	files:     Files,        // the project's place, the recent projects, Pads' folders
	hooks:     Hooks,        // what the app does around the core's actions
	registry:  Settings,     // the app's settings, by name
	why:       [256]u8,      // why the last action failed (`why`)
	why_len:   int,
}

// The transport's state beside the project's settings.
Transport :: struct {
	taps:       pm.Tap_Tempo,
	clock:      f64, // seconds of frames (what taps are timed by: frames, so a script's are steady)
	tapped:     f64, // when Tap was last pressed (for its flash)
	stopped_at: f64, // when Stop was last pressed (a second press soon after silences everything)
	silences:   int, // times every voice was silenced (for tests)
}

// Advances the app's clock by `dt` seconds (a frame) and does what is due:
// a tap-tempo start. Control thread, once a frame.
tick :: proc(c: ^Core, dt: f64) {
	t := &c.transport
	t.clock += dt
	if pm.tap_start_due(&t.taps, t.clock) {
		if _, playing := pm.timeline_beat(&c.m.engine); !playing do pm.play(&c.m.engine)
	}
}
