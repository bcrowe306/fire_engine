/*
Pads' own surface for Ableton Push 2, linked into Pads (nothing to
install): its display over USB with Pads' views on it, its pads, encoders
and buttons, in modes laid out as Live lays them out
(docs/design/push2.md). From Ableton's published interface
(github.com/Ableton/push-interface); fire-surface's push2_odin is the
host-neutral example it grew from.

- **Mix** (Mix): the eight pads in view, a page each of volumes, pans
  and sends (the upper row picks the page); the lower row selects a pad,
  or mutes or solos it while Mute or Solo is held.
- **Device** (Device): the selected pad's device, a bank of eight
  parameters a page (the upper row picks the bank), the lower row picks
  the device in its chain; the display shows the device as Pads draws it
  (its envelope, filter, pitch or LFOs, whichever the bank is about).
- Touching an encoder lights its column on the display, its value large.
- Pads: Note (Pads' note modes on the 8x8 grid: Scale's layouts, Chords'
  degrees by variations, Progressions' chords and their voicings; again:
  the next of the three; the display Pads' Harmony view; Shift + Layout:
  Scale's next layout), Layout (drum pads; again: Velocity), Session (Pads' pads in their colours, or its sequences
  with the launcher on the display, each press of Session the other:
  grid.odin); the arrows page the display's view (◀ ▶) and step its
  items (▲ ▼); Page ◀ ▶ scroll the grid (Clip's steps, Song) or step the
  pad (Shift: the sequence); the transport;
  the touch strip bends pitch.
- Browse, Clip: Pads' browser and sequencer on the display (mirror.odin).
*/
package pads_push2

import "base:runtime"
import "core:fmt"
import "core:math"
import "core:path/filepath"

import abi "fsurf:abi"
import kit "fsurf:surface"
import pa "../../api"

// Controls (Ableton's Push2-map.json).
CC_TAP :: 3
CC_METRONOME :: 9
CC_TEMPO :: 14
CC_SWING :: 15
CC_LOWER :: 20 // 20-27
CC_MASTER_BUTTON :: 28
CC_STOP :: 29
CC_SCENE :: 36 // 36 (1/4, bottom) - 43 (1/32t, top)
CC_LEFT :: 44
CC_RIGHT :: 45
CC_UP :: 46
CC_DOWN :: 47
CC_SELECT :: 48
CC_SHIFT :: 49
CC_NOTE :: 50
CC_SESSION :: 51
CC_OCTAVE_DOWN :: 54
CC_OCTAVE_UP :: 55
CC_REPEAT :: 56
CC_LAYOUT :: 31
CC_MUTE :: 60
CC_SOLO :: 61
CC_PAGE_LEFT :: 62
CC_PAGE_RIGHT :: 63
CC_TRACK_ENCODER :: 71 // 71-78
CC_MASTER_ENCODER :: 79
CC_PLAY :: 85
CC_RECORD :: 86
CC_UPPER :: 102 // 102-109
CC_DEVICE :: 110
CC_MIX :: 112
CC_BROWSE :: 111
CC_CLIP :: 113
CC_UNDO :: 119
NOTE_TOUCH :: 0 // 0-7 the track encoders', 8 master, 9 swing, 10 tempo
NOTE_STRIP_TOUCH :: 12

// Colour indices of the RGB LEDs: the palette set in the hello. 1-24:
// hues (clips); 25, 26: the selected pad's colour, dim and full; 100 on:
// the surface's own.
OFF :: 0
HUES :: 24
TRACK_DIM :: 25
TRACK :: 26
DIM_WHITE :: 100
ORANGE :: 101
DIM_ORANGE :: 102
GREEN :: 103
DIM_GREEN :: 104
RED :: 105
DIM_RED :: 106
BLUE :: 107
DIM_BLUE :: 108
YELLOW :: 109
PURPLE :: 110
WHITE :: 112

// Brightness of the white LEDs: their value picks a white palette entry
// (as an RGB LED's does a colour). Dim and half have entries of their own
// (the hello sets them): the clip hues (1-24) and the grid's colours (30-93)
// rewrite the default ones, white 0 for the grid's.
W_OFF :: 0
W_DIM :: 115
W_HALF :: 114
W_ON :: 127

PALETTE :: [?]struct { index: u8, rgb: u32, white: u8 }{
	{DIM_WHITE, 0x282828, 16}, {ORANGE, 0xff7800, 64}, {DIM_ORANGE, 0x3c1c00, 16},
	{GREEN, 0x00ff00, 64}, {DIM_GREEN, 0x003200, 16}, {RED, 0xff0000, 64}, {DIM_RED, 0x3c0000, 16},
	{BLUE, 0x0050ff, 64}, {DIM_BLUE, 0x000f3c, 16}, {YELLOW, 0xffc800, 64}, {PURPLE, 0xa03cff, 64},
	{WHITE, 0xffffff, 127},
	{W_HALF, 0x404040, 64}, {W_DIM, 0x101010, 20},
}

MIDI_MODE_LIVE :: [?]u8{0xF0, 0x00, 0x21, 0x1D, 0x01, 0x01, 0x0A, 0x00, 0xF7}
MIDI_MODE_USER :: [?]u8{0xF0, 0x00, 0x21, 0x1D, 0x01, 0x01, 0x0A, 0x01, 0xF7}
REAPPLY_PALETTE :: [?]u8{0xF0, 0x00, 0x21, 0x1D, 0x01, 0x01, 0x05, 0xF7}
// Set Aftertouch Mode: polyphonic (each pad its own pressure: Perform's effects).
AFTERTOUCH_POLY :: [?]u8{0xF0, 0x00, 0x21, 0x1D, 0x01, 0x01, 0x1E, 0x01, 0xF7}
DISPLAY_BRIGHTNESS :: [?]u8{0xF0, 0x00, 0x21, 0x1D, 0x01, 0x01, 0x08, 0x7F, 0x01, 0xF7}
TOUCH_STRIP_DEFAULT :: [?]u8{0xF0, 0x00, 0x21, 0x1D, 0x01, 0x01, 0x17, 0x68, 0xF7}

// A Set LED Color Palette Entry command.
palette_entry :: proc "contextless" (index: u8, rgb: u32, white: u8) -> [17]u8 {
	r, g, b := u8(rgb >> 16), u8(rgb >> 8), u8(rgb)
	return {0xF0, 0x00, 0x21, 0x1D, 0x01, 0x01, 0x03, index, r & 0x7F, r >> 7, g & 0x7F, g >> 7, b & 0x7F, b >> 7, white & 0x7F, white >> 7, 0xF7}
}

// The clip palette, by index, for the launcher's stopped clips.
clip_palette: [HUES + 1]kit.RGB

// The surface's state.
Push2 :: struct {
	pads_api:      ^pa.Table_V1, // fire.pads (nil in a host without it)
	encoders:      [8]^kit.Control,
	upper, lower:  [8]^kit.Control,
	key_grid:      ^Grid, // Note: Pads' note modes (Scale, Chords, Progressions: their cells)
	harmony_enc:   int,          // Note's Harmony view shown: the encoders' mode before it
	harmony_kind:  pa.View_Kind, // ... and the view
	device:        ^kit.Device,
	volumes, pans: ^kit.Mixer,
	sends:         [MIX_SENDS]^kit.Mixer,
	selected:      ^kit.Component, // the master encoder: Main's level
	enc_modes:     ^kit.Modes, // the encoders: a mix page, or the device
	pad_modes:     ^kit.Modes,
	shift:         ^kit.Modifier,
	mute_held, solo_held: bool,
	mix_told:      [2]bool, // Shift and Delete, as Pads' Mix view was told
	browse_told:   bool,    // Shift, as Pads' browser was told
	start_shown:   bool,
	extras:        ^kit.Component, // the side buttons not a mode's (extras.odin)
	extra_down:    map[string]u64, // when each was pressed (ns; 0: up): long presses
	accent_was:    bool, // Accent before a press (held long: back to it on release)
	push_settings: Push_Settings, // the Push's own (setup.odin)
	setup_open:    bool,
	setup_before:  int, // the encoders' mode before the settings showed
	setup_turn:    [4]int, // detents toward a choice's next step
	settings_before: int, // Pads' Settings shown: the encoders' mode and the view before
	settings_kind:   pa.View_Kind,
	sides:         [dynamic]^kit.Control, // the buttons along the sides (Shift's hints light them)
	rec_was_playing: bool, // Record pressed: whether it played (held: back to that)
	steps:         Steps, // Clip's pads (steps.odin)
	steps_grid:    ^Grid,
	pads_before:   int, // Clip's pads shown: the pads' mode before    // Pads' project manager, as last seen (Browse while it shows)
	lights:        Transport_Lights, // the transport's lights, in time (transport.odin)
	transport:     ^kit.Component,
	mix_page:      int, // the encoders' page in Mix (a Mix_Page, or a send)
	touched:       [11]bool, // the encoders touched now (8 track, master, swing, tempo)
	events:        map[^kit.Component]proc(c: ^kit.Component, e: kit.Event), // the components' own, wrapped
	view:          []u8, // Pads' view's newest frame (RGBA)
	view_frame:    i64,
	track_colour:  u32,
	banks:         ^kit.Component, // Device's banks on the upper row
	device_follow: ^kit.Component,
	enc_before:    int,          // the encoders' mode before Session's Sequences showed the launcher
	kind_before:   pa.View_Kind, // ... and the view
	mirror_kind:   pa.View_Kind, // the view of Pads' Device, Browse and Clip show (mirror.odin)
	mode_buttons:  ^kit.Component,
	dialog_modes:  ^kit.Modes, // a dialog in the window: its choices on the lower row (mirror.odin)
	dialog_open:   bool,
	watch:         ^kit.Component, // Pads watched: its dialog
	delete_held:   bool, // Delete held: a pad pressed is cleared
	delete_used:   bool, // a pad (or step) pressed while Delete was held (let go unused in Clip: the selected notes deleted)
	repeat:        Repeat_Hold, // Repeat (Pads' note repeat): held, latched, a pad played meanwhile
	select_held, dup_held: bool, // Select, Duplicate held (Perform's sequence pads: go to, copy)
	scenes:        [8]^kit.Control, // the scene buttons beside the grid (0 at the top)
	dev_bank:      int, // Device's bank (0: the Overview, when there is one)
	bank_first:    int, // the upper row's first bank (more than eight)
	bank_of:       [3]int, // the pad, device (and whether empty) the bank is of
	pad_grid, seq_grid: ^Grid, // Session: Pads' pads, its sequences (grid.odin)
	session_button: ^kit.Component,
	song_grid:     ^Grid, // Song (Master): the sequences (song.odin)
	song_button:   ^kit.Component,
	song_told:     bool, // Shift, as Pads' Song view was told
	pad_page:      int, // Session's pads: 64 a page
	render:        Renderer, // the pads' lights (render.odin)
	x, y:          f32, // setup: where the next side button goes
}

// Hello: the palettes, the backlight, the touch strip, then User mode (the
// one command with a reply, last).
HELLO_ENTRIES :: len(PALETTE) + HUES + 2
hello_messages: [HELLO_ENTRIES + 5][]u8
hello_bytes: [HELLO_ENTRIES][17]u8
live := MIDI_MODE_LIVE
user := MIDI_MODE_USER
reapply := REAPPLY_PALETTE
poly_pressure := AFTERTOUCH_POLY
backlight := DISPLAY_BRIGHTNESS
strip := TOUCH_STRIP_DEFAULT

// Pads' surface's id.
ID :: "org.fire_engine.pads.push2"

spec := kit.Spec{
	id          = ID,
	name        = "Push 2",
	vendor      = "Pads",
	version     = "0.1.0",
	url         = "https://github.com/bcrowe306/fire_engine",
	description = "Ableton Push 2 in Pads: its display with Pads' views, modes as Live lays them out",
	ports       = {{
		role    = "main",
		inputs  = {"mac:Ableton Push 2 User Port", "win:MIDIIN2 (Ableton Push 2)*", "linux:Ableton Push 2*:1"},
		outputs = {"mac:Ableton Push 2 User Port", "win:MIDIOUT2 (Ableton Push 2)*", "linux:Ableton Push 2*:1"},
	}},
	required_extensions = {"fsurf.daw"},
	devices     = {{role = "display", transport = .Usb_Bulk, vendor_id = 0x2982, product_id = 0x1967, interface = 0, endpoint_out = 0x01}},
	displays    = {{name = "Main", width = 960, height = 160, format = .Bgr565, fps = 30, device = 0}},
	width       = 378, // millimetres, for tools (as the device: PLACES)
	height      = 305,
	goodbye     = {live[:]},
	setup       = setup,
	on_destroy  = proc(cs: ^kit.Control_Surface) {
		p := (^Push2)(cs.user)
		kit.skin_destroy(cs.skin)
		delete(p.events)
		delete(p.extra_down)
		delete(p.sides)
		delete(p.view)
		free(p)
	},
}

library := kit.Library{specs = {&spec}}

// The library's entry, linked into Pads (`surfaces_add_static`).
@(export = false, link_name = "pads_push2_entry")
fsurf_entry := abi.Entry{
	fsurf_version = abi.VERSION,
	init          = proc "c" (path: cstring) -> bool {
		context = runtime.default_context()
		n := 0
		for p in PALETTE {
			hello_bytes[n] = palette_entry(p.index, p.rgb, p.white)
			n += 1
		}
		for h in 0 ..< HUES {
			c := kit.hsv_to_rgb(f64(h) * 360 / HUES, 1, 1)
			clip_palette[h + 1] = c
			hello_bytes[n] = palette_entry(u8(h + 1), kit.rgb_to_hex(c), 64)
			n += 1
		}
		hello_bytes[n] = palette_entry(TRACK_DIM, 0x000f3c, 16)
		hello_bytes[n + 1] = palette_entry(TRACK, 0x0050ff, 64)
		for &b, i in hello_bytes do hello_messages[i] = b[:]
		hello_messages[HELLO_ENTRIES] = reapply[:]
		hello_messages[HELLO_ENTRIES + 1] = backlight[:]
		hello_messages[HELLO_ENTRIES + 2] = strip[:]
		hello_messages[HELLO_ENTRIES + 3] = user[:]
		hello_messages[HELLO_ENTRIES + 4] = poly_pressure[:]
		spec.hello = hello_messages[:]
		return kit.library_init(&library)
	},
	deinit        = proc "c" () { kit.library_deinit(&library) },
	get_factory   = proc "c" (id: cstring) -> rawptr { return kit.library_factory(&library, id) },
}

// What lights show: palette indices (RGB) and brightness (white).
SKIN :: []struct { name: string, value: u8 }{
	{"Transport.Play.On", GREEN}, {"Transport.Play.Off", DIM_GREEN},
	{"Transport.Stop.On", WHITE}, {"Transport.Stop.Off", DIM_WHITE},
	{"Transport.Record.On", RED}, {"Transport.Record.Off", DIM_RED},
	{"Transport.Metronome.On", W_ON}, {"Transport.Metronome.Off", W_DIM}, {"Transport.Tap.Off", W_DIM},
	{"Mode.On", W_ON}, {"Mode.Off", W_DIM}, {"Shift.On", W_ON}, {"Shift.Off", W_DIM}, {"Repeat.On", W_ON}, {"Repeat.Off", W_DIM},
	{"Drum.Pad", TRACK_DIM}, {"Drum.Hit", TRACK}, {"Repeat.Pad", PURPLE}, {"Repeat.Hit", WHITE},
	{"Keyboard.Root", TRACK}, {"Keyboard.In_Scale", DIM_WHITE}, {"Keyboard.Out_Of_Scale", OFF}, {"Keyboard.Playing", GREEN},
	{"Session.Clip.Empty", OFF}, {"Session.Clip.Stopped", DIM_ORANGE}, {"Session.Clip.Playing", GREEN},
	{"Session.Clip.Queued", YELLOW}, {"Session.Clip.Recording", RED}, {"Session.Clip.Record_Queued", DIM_RED},
	{"Session.Clip.Stopping", ORANGE}, {"Session.Scene.On", DIM_WHITE}, {"Session.Scene.Off", OFF},
	{"Navigation.On", W_ON}, {"Navigation.Off", W_OFF}, {"Device.Bank.On", W_ON}, {"Device.Bank.Off", W_OFF},
	{"Mixer.Select.On", WHITE}, {"Mixer.Select.Off", DIM_WHITE}, {"Mixer.Select.None", OFF},
	{"Mixer.Mute.On", ORANGE}, {"Mixer.Mute.Off", DIM_ORANGE}, {"Mixer.Mute.None", OFF},
	{"Mixer.Solo.On", BLUE}, {"Mixer.Solo.Off", DIM_BLUE}, {"Mixer.Solo.None", OFF},
	{"App.On", W_HALF}, {"App.Off", W_DIM},
}

// The buttons with nothing to do yet: the surface's all the same (none
// reaches Pads as a note), and shown by tools.
OTHER_BUTTONS :: []struct { cc: u8, name: string, left: bool }{
	{35, "Convert", true}, {117, "Double Loop", true}, {116, "Quantize", true},
	{87, "New", true}, {90, "Fixed Length", true}, {89, "Automate", true},
	{30, "Setup", false}, {59, "User", false}, {52, "Add Device", false}, {53, "Add Track", false},
{57, "Accent", false},
	{58, "Scale", false},
}

SCENE_NAMES := [8]string{"1/32t", "1/32", "1/16t", "1/16", "1/8t", "1/8", "1/4t", "1/4"}

setup :: proc(cs: ^kit.Control_Surface) -> bool {
	p := new(Push2)
	cs.user = p
	p.events = make(map[^kit.Component]proc(c: ^kit.Component, e: kit.Event))
	p.pads_api = (^pa.Table_V1)(kit.extension(cs, pa.EXTENSION_NAME, pa.VERSION))
	p.view = make([]u8, 960 * 160 * 4)
	skin := kit.skin_make()
	for v in SKIN do kit.skin_set(skin, v.name, v.value)
	for v in SKIN do for c in PALETTE do if c.index == v.value do kit.skin_set_display(skin, v.name, c.rgb)
	kit.set_skin(cs, skin)

	// ── The hardware, placed as on the device (millimetres) ──
	for i in 0 ..< 8 {
		p.encoders[i] = kit.touch_encoder(cs, "Encoder", kit.bind_cc(u8(CC_TRACK_ENCODER + i)), kit.bind_note(u8(NOTE_TOUCH + i)))
		kit.place(p.encoders[i], 73 + f32(i) * 29.2, 5.5, 14, 14)
		p.upper[i] = kit.button(cs, "Upper", kit.bind_cc(u8(CC_UPPER + i)))
		kit.place(p.upper[i], 68.5 + f32(i) * 29.2, 28, 25.5, 10)
		p.lower[i] = kit.button(cs, "Lower", kit.bind_cc(u8(CC_LOWER + i)))
		kit.place(p.lower[i], 68.5 + f32(i) * 29.2, 101.5, 25.5, 10)
	}
	master := kit.touch_encoder(cs, "Master Encoder", kit.bind_cc(CC_MASTER_ENCODER), kit.bind_note(NOTE_TOUCH + 8))
	kit.place(master, 347.5, 5.5, 14, 14)
	tempo := kit.touch_encoder(cs, "Tempo Encoder", kit.bind_cc(CC_TEMPO), kit.bind_note(NOTE_TOUCH + 10))
	kit.place(tempo, 7.5, 5.5, 14, 14)
	swing := kit.touch_encoder(cs, "Swing Encoder", kit.bind_cc(CC_SWING), kit.bind_note(NOTE_TOUCH + 9))
	kit.place(swing, 37.5, 5.5, 14, 14)
	strip := kit.button(cs, "Touch Strip", kit.bind_note(NOTE_STRIP_TOUCH)) // (its touch; its pitch bend passes)
	kit.place(strip, 39, 121, 15, 173)
	pads := kit.matrix_make(cs, "Pads", 8, 8, proc(row, col: int) -> kit.Binding {
		return kit.bind_note(u8(36 + (7 - row) * 8 + col)) // 36 at the bottom left
	})
	kit.place_matrix(pads, 68.5, 121, 25.5, 18.3, gap = 3.75)
	for i in 0 ..< 8 {
		p.scenes[i] = kit.button(cs, SCENE_NAMES[i], kit.bind_cc(u8(CC_SCENE + 7 - i)))
		kit.place(p.scenes[i], 310, 121 + f32(i) * 22.05, 18, 18.3)
	} // (Perform: the launcher's rows)
	p.x, p.y = 34, 96

	// ── The transport, Undo, the tempo ──
	transport := kit.transport_make(cs)
	kit.layer_bind(transport.layer, "tap", side(cs, "Tap Tempo", CC_TAP, true))
	kit.layer_bind(transport.layer, "metronome", side(cs, "Metronome", CC_METRONOME, true))
	kit.layer_bind(transport.layer, "stop", side(cs, "Stop", CC_STOP, true))
	kit.layer_bind(transport.layer, "record", side(cs, "Record", CC_RECORD, true))
	// Shift + Record: save the project, wherever Pads is (an untitled one
	// into the projects folder); a message says so.
	p.events[transport] = transport.on_event
	transport.on_event = proc(c: ^kit.Component, e: kit.Event) {
		p := (^Push2)(c.cs.user)
		if e.slot == "tap" && (e.kind == .Press || e.kind == .Release) do p.lights.tap_held = e.kind == .Press
		// Record or Metronome held: their press undone, Pads' Recording or
		// Transport dialog instead; Shift + Metronome: Transport; Shift +
		// Play: Loop on or off.
		if t := p.pads_api; t != nil {
			if e.kind == .Press && e.slot == "record" {
				tr: pa.Transport_State
				t.transport_state(t.api, &tr)
				p.rec_was_playing = tr.playing
			}
			if e.kind == .Hold && (e.slot == "record" || e.slot == "metronome") && !p.shift.held {
				if f := p.events[c]; f != nil do f(c, {kind = .Press, control = e.control, slot = e.slot}) // (back as it was)
				if e.slot == "record" && !p.rec_was_playing do t.transport_stop(t.api) // (Record started it: stopped again)
				name := "recording" if e.slot == "record" else "transport"
				t.ui_show(t.api, cstring(raw_data(name)), i64(len(name)))
				return
			}
			if p.shift.held && e.slot == "metronome" {
				if e.kind == .Press {
					name := "transport"
					t.ui_show(t.api, cstring(raw_data(name)), i64(len(name)))
				}
				return
			}
			if p.shift.held && e.slot == "play" {
				if e.kind == .Press {
					tr: pa.Transport_State
					t.transport_state(t.api, &tr)
					t.transport_set_loop(t.api, !tr.loop)
					msg := "Loop on: it goes round" if !tr.loop else "Loop off: it plays once and stops"
					t.ui_message_show(t.api, .Info, cstring(raw_data(msg)), i64(len(msg)))
				}
				return
			}
		}
		if t := p.pads_api; t != nil && e.slot == "record" && p.shift.held {
			if e.kind != .Press do return
			dir: [1024]u8
			n: i64
			if t.project_save_quick(t.api, &dir[0], len(dir), &n) == .Ok {
				name := filepath.stem(string(dir[:min(int(n), len(dir))]))
				msg := fmt.tprintf("Saved %s", name)
				t.ui_message_show(t.api, .Success, cstring(raw_data(msg)), i64(len(msg)))
			} else {
				msg := "Could not save the project"
				t.ui_message_show(t.api, .Error, cstring(raw_data(msg)), i64(len(msg)))
			}
			return
		}
		if f := p.events[c]; f != nil do f(c, e)
	}
	kit.layer_bind(transport.layer, "play", side(cs, "Play", CC_PLAY, true))
	lights := transport_lights_setup(cs, p, transport)
	app := kit.app_make(cs)
	undo := side(cs, "Undo", CC_UNDO, true)
	kit.layer_bind(app.layer, "undo", undo)
	redo := kit.app_make(cs, "Redo", priority = 1) // under Shift
	kit.layer_bind(redo.layer, "redo", undo)
	tempo_c := kit.component_make(cs, "Tempo")
	kit.layer_bind(tempo_c.layer, "tempo", tempo)
	tempo_c.on_event = proc(c: ^kit.Component, e: kit.Event) {
		if e.kind != .Delta do return
		p := (^Push2)(c.cs.user)
		t := kit.daw_get(c.cs, .Tempo)
		step := 0.1 if p.shift.held else 1.0 // (Shift: fine, a tenth of a BPM)
		kit.daw_set(c.cs, .Tempo, 0, 0, clamp(math.round((t + f64(e.delta) * step) / step) * step, 20, 999))
	}
	swing_c := swing_setup(cs, swing) // (extras.odin)

	// ── The encoders and the rows: Mix and Device (modes.odin) ──
	p.shift = kit.modifier_make(cs, "Shift", side(cs, "Shift", CC_SHIFT, false), {redo, shift_hints_setup(cs)})
	page_lc, page_rc := side(cs, "Page <", CC_PAGE_LEFT, false), side(cs, "Page >", CC_PAGE_RIGHT, false)
	modes_setup(cs, p, master, side(cs, "Mix", CC_MIX, false), side(cs, "Device", CC_DEVICE, false), side(cs, "Browse", CC_BROWSE, false), side(cs, "Clip", CC_CLIP, false),
		page_lc, page_rc, side(cs, "Mute", CC_MUTE, true), side(cs, "Solo", CC_SOLO, true))

	// ── The pads: Note, Layout (drums), Session ──
	p.key_grid = grid_make(cs, "Keys", pads, .Keys)
	// Octave Up/Down: the key's octave up or down (-3..3: Scale's grid
	// and the chords move with it).
	octave := kit.component_make(cs, "Octave")
	octave_up, octave_down := side(cs, "Octave Up", CC_OCTAVE_UP, false), side(cs, "Octave Down", CC_OCTAVE_DOWN, false)
	kit.layer_bind(octave.layer, "up", octave_up)
	kit.layer_bind(octave.layer, "down", octave_down)
	octave.on_owned = proc(c: ^kit.Component, slot: string, control: ^kit.Control) {
		t := (^Push2)(c.cs.user).pads_api
		ks: pa.Key_Info
		if t != nil do t.key_state(t.api, &ks)
		on := ks.octave < 3 if slot == "up" else ks.octave > -3
		kit.light_value(control, W_ON if on else W_DIM)
	}
	octave.on_event = proc(c: ^kit.Component, e: kit.Event) {
		if e.kind != .Press do return
		p := (^Push2)(c.cs.user)
		t := p.pads_api
		if t == nil do return
		ks: pa.Key_Info
		t.key_state(t.api, &ks)
		t.key_set_octave(t.api, clamp(ks.octave + (1 if e.slot == "up" else -1), -3, 3))
		kit.redraw_owned(c)
		render(p)
		invalidate(c.cs)
	}
	drums := kit.drum_pads_make(cs, "Drum", pads)
	drums.channel = pa.PADS_CHANNEL // (the pads only: not an armed synth's keys)
	repeat := kit.note_repeat_make(cs, "Note Repeat", pads, rate = 0.25, priority = 1)
	repeat_c := side(cs, "Repeat", CC_REPEAT, false)
	repeat_button := kit.modifier_make(cs, "Repeat", repeat_c, {repeat})
	p.repeat.pads = pads
	// Select and Duplicate: held, what a pad press does (Perform: go to a
	// sequence, copy it).
	held := kit.component_make(cs, "Select Duplicate")
	kit.layer_bind(held.layer, "select", side(cs, "Select", CC_SELECT, false))
	kit.layer_bind(held.layer, "duplicate", side(cs, "Duplicate", 88, true))
	held.on_owned = proc(c: ^kit.Component, slot: string, control: ^kit.Control) {
		p := (^Push2)(c.cs.user)
		kit.light_value(control, W_ON if (p.select_held if slot == "select" else p.dup_held) else W_DIM)
	}
	held.on_event = proc(c: ^kit.Component, e: kit.Event) {
		if e.kind != .Press && e.kind != .Release do return
		p := (^Push2)(c.cs.user)
		if e.slot == "select" {
			p.select_held = e.kind == .Press
			// Clip: told to the sequencer (the cursor's note kept or let go;
			// with Shift, every note of the pad).
			if p.select_held && p.mirror_kind == .Sequencer {
				press(p, .Sequencer, .Select, true)
				press(p, .Sequencer, .Select, false)
			}
		} else {
			p.dup_held = e.kind == .Press
			if !p.dup_held do steps_forget_copy(p)
		}
		if p.steps_grid != nil && p.steps_grid.active do for x in p.steps_grid.pads.controls do if kit.owns(p.steps_grid, x) do grid_route(p.steps_grid, x)
		kit.redraw_owned(c)
	}
	pads_mode, seq_mode := grid_setup(cs, p, pads, side(cs, "Session", CC_SESSION, false), octave_up, octave_down)
	renderer := render_setup(cs, p, pads) // (the grids' lights: render.odin)
	nav := arrows_setup(cs, side(cs, "Left", CC_LEFT, false), side(cs, "Right", CC_RIGHT, false), side(cs, "Up", CC_UP, false), side(cs, "Down", CC_DOWN, false))
	p.pad_modes = kit.modes_make(cs, "Pads")
	kit.modes_add(p.pad_modes, "note", {p.key_grid, octave}, side(cs, "Note", CC_NOTE, false))
	if p.pads_api != nil do kit.modes_add(p.pad_modes, "drum", {drums}, side(cs, "Layout", CC_LAYOUT, false)) // (Repeat: Pads' note repeat, in every mode)
	else do kit.modes_add(p.pad_modes, "drum", {drums, &repeat_button.component}, side(cs, "Layout", CC_LAYOUT, false))
	kit.modes_add(p.pad_modes, "pads", pads_mode)
	kit.modes_add(p.pad_modes, "sequences", seq_mode)
	p.song_grid = grid_make(cs, "Song Sequences", pads, .Song)
	song_parts := make([]^kit.Component, 2)
	song_parts[0], song_parts[1] = p.song_grid, song_lanes_setup(cs, p)
	kit.modes_add(p.pad_modes, "song", song_parts)
	p.steps_grid = grid_make(cs, "Clip Steps", pads, .Steps)
	p.steps.held = -1
	steps_forget_copy(p)
	steps_parts := make([]^kit.Component, 2)
	steps_parts[0], steps_parts[1] = p.steps_grid, steps_scenes_setup(cs, p)
	kit.modes_add(p.pad_modes, "steps", steps_parts)
	velocity_parts := make([]^kit.Component, 1)
	velocity_parts[0] = grid_make(cs, "Velocity Pads", pads, .Velocity)
	kit.modes_add(p.pad_modes, "velocity", velocity_parts)
	// Layout pressed again (in its drums): Velocity mode; in it: the drums.
	// Note pressed again: the next note mode (Scale, Chords, Progressions);
	// Shift + Layout in Note: Scale's next layout (Layout alone stays the
	// drums, Velocity).
	p.events[&p.pad_modes.component] = p.pad_modes.on_event
	p.pad_modes.on_event = proc(c: ^kit.Component, e: kit.Event) {
		p := (^Push2)(c.cs.user)
		cur := kit.modes_current(p.pad_modes)
		if e.kind == .Press && e.slot == "drum" && cur == "note" && p.shift.held {
			if t := p.pads_api; t != nil {
				ks: pa.Key_Info
				t.key_state(t.api, &ks)
				t.key_set_layout(t.api, pa.Grid_Layout((int(ks.layout) + 1) % len(pa.Grid_Layout)))
				render(p)
				invalidate(c.cs)
			}
			return
		}
		if e.kind == .Press && e.slot == "drum" && cur == "drum" {
			kit.modes_select(p.pad_modes, kit.modes_find(p.pad_modes, "velocity"))
			return
		}
		if e.kind == .Press && e.slot == "note" && cur == "note" {
			if t := p.pads_api; t != nil {
				perf: pa.Perform_State
				t.perform_state(t.api, &perf)
				next: pa.Play_Mode = .Chords
				#partial switch perf.play_mode {
				case .Chords:       next = .Progressions
				case .Progressions: next = .Scale
				}
				t.perform_set_play_mode(t.api, next)
				harmony_show(p)
				render(p)
				invalidate(c.cs)
			}
			return
		}
		if f := p.events[c]; f != nil do f(c, e)
	}
	song_b := song_button_setup(cs, p, side(cs, "Master", CC_MASTER_BUTTON, false))
	kit.modes_select(p.pad_modes, kit.modes_find(p.pad_modes, "pads"))
	p.pad_modes.on_change = proc(m: ^kit.Modes, from, to: int) {
		p := (^Push2)(m.cs.user)
		// Note is Pads' note modes (Scale unless the window plays Chords or
		// Progressions), the display their Harmony view; leaving it, Pads
		// mode again, the display what it showed before.
		if t := p.pads_api; t != nil {
			perf: pa.Perform_State
			t.perform_state(t.api, &perf)
			note := kit.modes_current(m) == "note"
			velocity := kit.modes_current(m) == "velocity"
			switch {
			case note && !(perf.play_mode == .Scale || perf.play_mode == .Chords || perf.play_mode == .Progressions):
				t.perform_set_play_mode(t.api, .Scale)
				app_show(p, "pads")
			case velocity && perf.play_mode != .Velocity:
				t.perform_set_play_mode(t.api, .Velocity)
				app_show(p, "pads")
			case !note && !velocity && perf.play_mode != .Pads:
				t.perform_set_play_mode(t.api, .Pads)
			}
			// Velocity mode: Layout lit orange (its own light back after).
			for b in p.sides do if b.name == "Layout" {
				if velocity do kit.light_hold(b, ORANGE)
				else do kit.light_release(b)
			}
		}
		// Leaving Song: the display what it showed before.
		if from >= 0 && from < len(m.modes) && m.modes[from].name == "song" && kit.modes_current(p.enc_modes) == "song" {
			p.mirror_kind = p.kind_before
			kit.modes_select(p.enc_modes, p.enc_before)
			if p.mode_buttons != nil do kit.redraw_owned(p.mode_buttons)
		}
		// Note: the Harmony view on the display (after Song gave its back).
		if kit.modes_current(m) == "note" do harmony_show(p)
		else do harmony_leave(p)
		kit.redraw_owned(p.session_button)
		if p.song_button != nil do kit.redraw_owned(p.song_button)
		invalidate(m.cs)
	}
	// Delete: held, a pad pressed is cleared (its pads sound nothing then).
	del := kit.component_make(cs, "Delete")
	kit.layer_bind(del.layer, "delete", side(cs, "Delete", 118, true))
	del.on_owned = proc(c: ^kit.Component, slot: string, control: ^kit.Control) {
		kit.light_value(control, W_ON if (^Push2)(c.cs.user).delete_held else W_DIM)
	}
	del.on_event = proc(c: ^kit.Component, e: kit.Event) {
		if e.kind != .Press && e.kind != .Release do return
		p := (^Push2)(c.cs.user)
		p.delete_held = e.kind == .Press
		// Clip: a tap (no pad cleared with it) deletes the selected notes.
		if p.delete_held do p.delete_used = false
		else if !p.delete_used && p.mirror_kind == .Sequencer {
			press(p, .Sequencer, .Delete, true)
			press(p, .Sequencer, .Delete, false)
		}
		if p.pad_grid.active do for x in p.pad_grid.pads.controls do if kit.owns(p.pad_grid, x) do grid_route(p.pad_grid, x)
		kit.redraw_owned(c)
	}
	others := make(map[string]^kit.Control, context.temp_allocator)
	for b in OTHER_BUTTONS do others[b.name] = side(cs, b.name, b.cc, b.left)
	extras := extras_setup(cs, p, others)
	kit.modes_add(p.enc_modes, "setup", {setup_setup(cs, p)}) // (Shift + Setup: setup.odin)

	// The selected pad's colour on the drums and the keyboard's roots.
	colour := kit.component_make(cs, "Pad Colour")
	colour.daw_topics = {.Tracks}
	colour.on_daw = proc(c: ^kit.Component, e: abi.Daw_Event) { track_colour(c.cs) }
	colour.on_activate = proc(c: ^kit.Component) { track_colour(c.cs) }

	dialog_setup(cs, p)

	// The display (screen.odin).
	screen := screen_setup(cs)
	// Touching an encoder: shown on the display (their owners' events wrapped).
	for c in ([?]^kit.Component{p.volumes, p.pans, p.device, p.selected, tempo_c, swing_c}) do watch_touch(p, c)
	for s in p.sends do watch_touch(p, s)

	kit.ring_setup(cs, 8, 8)
	for c in ([?]^kit.Component{transport, app, &p.shift.component, tempo_c, swing_c, p.selected, nav, &p.enc_modes.component, &p.pad_modes.component, p.session_button, song_b, p.device_follow, &p.dialog_modes.component, p.watch, del, colour, screen, renderer, held, lights, extras}) do kit.surface_add(cs, c)
	if p.pads_api != nil do kit.surface_add(cs, grid_page_setup(cs, page_lc, page_rc))
	if p.pads_api != nil do kit.surface_add(cs, repeat_setup(cs, repeat_c)) // (Pads' grid and pads; without Pads, Page ◀ ▶ are Device's banks)
	modes_start(p)
	return true
}

// A button down a side of the pads: the left column, or the right one.
@(private)
side :: proc(cs: ^kit.Control_Surface, name: string, cc: u8, left: bool) -> ^kit.Control {
	p := (^Push2)(cs.user)
	b := kit.button(cs, name, kit.bind_cc(cc))
	append(&p.sides, b)
	for at in PLACES do if at.name == name {
		kit.place(b, at.x, at.y, at.w, at.h)
		return b
	}
	if left {
		kit.place(b, 8, p.y, 40, 8)
		p.y += 11
	} else {
		kit.place(b, 326, p.x, 46, 8)
		p.x += 11
	}
	return b
}

// Where each button around the pads is on the device (millimetres from
// its top left; as on Push 2 itself), for tools (Pads' Push 2 on Screen).
@(private)
PLACES := [?]struct { name: string, x, y, w, h: f32 }{
	{"Tap Tempo", 6, 28, 25, 10}, {"Metronome", 31.5, 28, 25.5, 10},
	{"Setup", 335, 28, 18, 10}, {"User", 354, 28, 18, 10},
	{"Delete", 6, 51, 18, 18}, {"Undo", 6, 70, 18, 18},
	{"Add Device", 310, 51, 18, 18}, {"Add Track", 310, 70, 18, 18},
	{"Device", 335, 51, 18, 18}, {"Mix", 354, 51, 18, 18}, {"Browse", 335, 70, 18, 18}, {"Clip", 354, 70, 18, 18},
	{"Mute", 6, 101.5, 16, 10}, {"Solo", 22.5, 101.5, 16.5, 10}, {"Stop", 39.5, 101.5, 17, 10},
	{"Master", 310, 101.5, 18, 10},
	{"Up", 344, 102, 19, 9}, {"Down", 344, 129, 19, 9}, {"Left", 335, 110.5, 9, 19}, {"Right", 363, 110.5, 9, 19},
	{"Convert", 6, 121, 18, 17}, {"Double Loop", 6, 139.5, 18, 17}, {"Quantize", 6, 158, 18, 17},
	{"Duplicate", 6, 180, 18, 17}, {"New", 6, 198.5, 18, 17},
	{"Fixed Length", 6, 220, 18, 17}, {"Automate", 6, 238.5, 18, 14.5},
	{"Record", 6, 255, 18, 18}, {"Play", 6, 276, 18, 18},
	{"Repeat", 335, 187, 18, 18}, {"Accent", 354, 187, 18, 18},
	{"Scale", 335, 210, 18, 11}, {"Layout", 354, 210, 18, 11}, {"Note", 335, 221.5, 18, 16.5}, {"Session", 354, 221.5, 18, 16.5},
	{"Octave Up", 344, 243, 19, 9}, {"Octave Down", 344, 271, 19, 9}, {"Page <", 335, 252, 9, 19}, {"Page >", 363, 252, 9, 19},
	{"Shift", 335, 284, 18, 10}, {"Select", 354, 284, 18, 10},
}

// Notes an encoder's touch (its column lit on the display), then hands the
// event on to the component's own handler.
@(private)
watch_touch :: proc(p: ^Push2, c: ^kit.Component) {
	if c == nil do return
	p.events[c] = c.on_event
	c.on_event = proc(c: ^kit.Component, e: kit.Event) {
		p := (^Push2)(c.cs.user)
		if e.kind == .Touch || e.kind == .Untouch {
			for x, i in p.encoders do if x == e.control do p.touched[i] = e.kind == .Touch
			name := e.control.name
			if name == "Master Encoder" do p.touched[8] = e.kind == .Touch
			if name == "Swing Encoder" do p.touched[9] = e.kind == .Touch
			if name == "Tempo Encoder" do p.touched[10] = e.kind == .Touch
			invalidate(c.cs)
		}
		if f := p.events[c]; f != nil do f(c, e)
	}
}

// Palette entries 25 (dim) and 26 as the selected pad's colour, when it changed.
@(private)
track_colour :: proc(cs: ^kit.Control_Surface) {
	p := (^Push2)(cs.user)
	if cs.daw == nil do return
	c := u32(kit.daw_get(cs, .Track_Color, kit.selected_track(cs))) & 0xFFFFFF
	if c == 0 do c = 0x0050ff
	if c == p.track_colour do return
	p.track_colour = c
	rgb := kit.rgb_from_hex(c)
	dim := kit.rgb_to_hex({rgb.r / 5, rgb.g / 5, rgb.b / 5})
	a, b := palette_entry(TRACK_DIM, dim, 16), palette_entry(TRACK, c, 64)
	kit.send(cs, a[:])
	kit.send(cs, b[:])
	kit.send(cs, reapply[:])
}

// Repeat on Pads (its toolbar's note repeat, for every pad held): lit while
// it is on; held, on until let go; Shift + Repeat: latched on, or off; held
// a while with no pad played: its settings (rate, gate) on the display.
Repeat_Hold :: struct {
	pads:     ^kit.Matrix,
	held:     bool, // Repeat down
	momentary: bool, // turned on by this hold (off when let go)
	played:   bool, // a pad pressed while it was held
}

@(private)
repeat_setup :: proc(cs: ^kit.Control_Surface, button: ^kit.Control) -> ^kit.Component {
	c := kit.component_make(cs, "Pads Repeat")
	kit.layer_bind(c.layer, "repeat", button)
	c.on_owned = proc(c: ^kit.Component, slot: string, control: ^kit.Control) {
		t := (^Push2)(c.cs.user).pads_api
		on: bool
		if t != nil do t.perform_note_repeat(t.api, &on)
		kit.light(control, "Repeat.On" if on else "Repeat.Off")
	}
	c.on_activate = proc(c: ^kit.Component) {
		kit.task_every(c.cs, 40, proc(data: rawptr) {
			c := (^kit.Component)(data)
			p := (^Push2)(c.cs.user)
			r := &p.repeat
			if r.held && r.pads != nil do for x in r.pads.controls do if x.pressed do r.played = true
			kit.redraw_owned(c)
		}, c, c)
	}
	c.on_event = proc(c: ^kit.Component, e: kit.Event) {
		p := (^Push2)(c.cs.user)
		t := p.pads_api
		if t == nil do return
		r := &p.repeat
		on: bool
		t.perform_note_repeat(t.api, &on)
		#partial switch e.kind {
		case .Press:
			r.held, r.played, r.momentary = true, false, false
			if p.shift.held {
				t.perform_set_note_repeat(t.api, !on) // (latched, or off)
			} else if !on {
				t.perform_set_note_repeat(t.api, true)
				r.momentary = true
			}
		case .Hold:
			if !r.played && !p.shift.held {
				if r.momentary do t.perform_set_note_repeat(t.api, false)
				r.momentary = false
				app_show(p, "note repeat")
			}
		case .Release:
			if r.momentary do t.perform_set_note_repeat(t.api, false)
			r.held, r.momentary = false, false
		}
		kit.redraw_owned(c)
		invalidate(c.cs)
	}
	return c
}

// Note's display: Pads' Harmony view (the key, the chord playing, the
// progression; the key on the encoders), what it showed before kept for
// when Note is left.
@(private)
harmony_show :: proc(p: ^Push2) {
	if p.pads_api == nil || p.enc_modes == nil do return
	if kit.modes_current(p.enc_modes) == "harmony" do return
	p.harmony_enc, p.harmony_kind = p.enc_modes.current, p.mirror_kind
	p.mirror_kind = .Harmony
	kit.modes_select(p.enc_modes, kit.modes_find(p.enc_modes, "harmony"))
	if p.mode_buttons != nil do kit.redraw_owned(p.mode_buttons)
	invalidate(p.enc_modes.cs)
}

// Note left: the display what it showed before (if it still shows the
// Harmony view).
@(private)
harmony_leave :: proc(p: ^Push2) {
	if p.pads_api == nil || p.enc_modes == nil || kit.modes_current(p.enc_modes) != "harmony" do return
	p.mirror_kind = p.harmony_kind
	kit.modes_select(p.enc_modes, p.harmony_enc)
	if p.mode_buttons != nil do kit.redraw_owned(p.mode_buttons)
	invalidate(p.enc_modes.cs)
}
