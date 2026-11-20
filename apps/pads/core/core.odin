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
	rec:       pm.Recording, // recording a sample into a pad
	sample_holding: int,     // the pad recording while it is held (-1: none); letting it go stops it
	// How the pads play (see perform.odin).
	selected:  int,          // the selected pad: what the keys, the note modes and Velocity play, and the editors show
	slice:     int,          // a slicer's selected slice (its page's settings, a controller's slice pads)
	song_edit: Song_Edit,    // editing the song (the window's Song tab and a controller's: one state)
	bank:      int,          // the bank the pads show (Scale: a range of notes; Chords: of degrees)
	play_mode: pm.Play_Mode,
	keys:      pm.Keys,      // the project key, Scale's octave, the chords' voicing (saved with the project)
	progression: pm.Progression, // the one Progressions mode plays (saved with the project)
	voicing:   [pm.PADS]pm.Chord_Notes, // the last chord each pad played (voice leading leads the next from it)
	chord_played: Chord_Played, // the last chord the note modes played, from any grid (a display shows it)
	presses:   int,          // chord presses so far (each one's number: what its release ends)
	pads_bank: int,          // the bank the pads were on before a note mode moved it
	job:       Job,          // an export under way (export.odin)
	browser:   pm.Browser,   // the Library's browser: favourites, the folder tree, the selection, the search
	transport: Transport,    // the transport's own state (tap tempo, Stop pressed twice)
	files:     Files,        // the project's place, the recent projects, Pads' folders
	launch:    Launch_Live,  // the Perform tab's live state: its launcher window, held pads and effects (launch.odin)
	hooks:     Hooks,        // what the app does around the core's actions
	registry:  Settings,     // the app's settings, by name
	why:       [256]u8,      // why the last action failed (`why`)
	why_len:   int,
}

// Editing the song: the cursor (where a controller adds a clip), the
// selected lane and clip, the eight lanes a controller shows, the length a
// clip added gets. Not part of the project (not undone).
Song_Edit :: struct {
	cursor:     f64, // song beats
	lane:       int,
	first_lane: int, // 0 or 8
	clip:       int, // the selected clip plus 1 (0: none)
	length:     f64, // beats a clip added at the cursor plays (0: its sequence's length)
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
	pm.set_key_mask(&c.m.engine, pm.key_mask(c.keys)) // (the arpeggiators' In key)
	if pm.tap_start_due(&t.taps, t.clock) {
		if _, playing := pm.timeline_beat(&c.m.engine); !playing do pm.play(&c.m.engine)
	}
}
