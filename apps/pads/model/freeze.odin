package pads_model

import "core:os"
import "core:path/filepath"
import "core:strings"

import app "app:core"
import "fire:audiofile"

// Freezing a pad: its sound (its device through its inserts, before its
// fader, sends and pan) rendered for each sequence it plays in, then
// played instead, as an audio track plays its takes: its device and
// inserts leave the graph (their CPU with them) while its fader, sends
// and route still work. Unfrozen, it is as it was. Flattened, it becomes
// an audio pad with those renderings as its takes.

// The sequences pad `pad` has notes in. Temporary allocator.
freeze_slots :: proc(p: ^Project, pad: int) -> []int {
	out := make([dynamic]int, context.temp_allocator)
	for s, k in p.sequences {
		for n in s.notes do if int(n.pad) == pad {
			append(&out, k)
			break
		}
	}
	return out[:]
}

// Whether pad `pad` can be frozen: a sound (not an audio pad), not
// frozen, with notes somewhere.
can_freeze :: proc(p: ^Project, pad: int) -> bool {
	if pad < 0 || pad >= PADS do return false
	pd := &p.pads[pad]
	return pad_used(p, pad) && pd.kind != .Audio && !pd.frozen && len(freeze_slots(p, pad)) > 0
}

// Starts freezing pad `pad`: an export of its sound, a pass for each
// sequence it plays in (once each, at the sequence's tempo), into the
// project's samples. Step it with `export_step`; `export_finish` puts the
// renderings in and freezes it (one undo step). False if it can't be.
freeze_begin :: proc(m: ^Model, x: ^Export, pad: int) -> bool {
	p := &m.project
	e := &m.engine
	if !can_freeze(p, pad) do return false
	capture_plugin_states(m) // (they come back as they are when unfrozen)
	rate := e.host.graph.settings.sample_rate
	x^ = {settings = {source = .Sequence, encoding = .Float32, rate = rate}, to_pad = -1, freeze = pad, slot_was = p.slot}
	x.passes = make([dynamic]Export_Pass)
	x.files = make([dynamic]string)
	dir, _ := filepath.join({p.dir, "samples"}, context.temp_allocator)
	os.make_directory_all(dir)
	for slot in freeze_slots(p, pad) {
		name := strings.concatenate({"Freeze ", pad_label(pad), " - ", sequence_name(p, slot), ".wav"}, context.temp_allocator)
		path := unique_path(dir, name)
		secs := seq_beats(p, p.sequences[slot]) * 60 / sequence_tempo(p, slot)
		append(&x.passes, Export_Pass{path, {.Freeze, pad}, slot, max(int(secs * rate + 0.5), 1)})
	}
	x.frames = x.passes[0].frames
	export_open(m, x)
	start_pass(m, x)
	return true
}

// [export_finish] The renderings in: each its sequence's, and the pad
// frozen (one undo step).
@(private)
freeze_finish :: proc(m: ^Model, x: ^Export) {
	p := &m.project
	pad := x.freeze
	if len(x.files) != len(x.passes) do return
	app.begin(&m.history, "Freeze")
	defer app.end(&m.history)
	for f, k in x.files {
		r, err := audiofile.open(f)
		if err != .None do return
		info := audiofile.info(r)
		audiofile.close(r)
		slot := x.passes[k].slot
		p.freezes[slot][pad] = {add_sample(m, f, info), sequence_tempo(p, slot)}
	}
	set_frozen(m, pad, true)
	sync(&m.engine)
}

// Freezes or unfreezes pad `pad` (its renderings as they are), undoably.
set_frozen :: proc(m: ^Model, pad: int, frozen: bool) {
	if pad < 0 || pad >= PADS do return
	pd := m.project.pads[pad]
	if pd.frozen == frozen do return
	pd.frozen = frozen
	set_pad(m, pad, .Frozen, "Freeze" if frozen else "Unfreeze", pd)
	app.seal(&m.history)
}

// Flattens frozen pad `pad`: an audio pad whose takes are its
// renderings (its inserts gone: they are in them). One undo step.
flatten :: proc(m: ^Model, pad: int) {
	p := &m.project
	if pad < 0 || pad >= PADS || !p.pads[pad].frozen do return
	app.begin(&m.history, "Flatten to Audio")
	defer app.end(&m.history)
	for slot in 0 ..< SLOTS do if c := p.freezes[slot][pad]; c.sample != 0 do set_clip(m, slot, pad, "Flatten to Audio", c)
	pd := p.pads[pad]
	pd.frozen = false
	pd.kind = .Audio
	pd.inserts = {}
	pd.sample = 0
	set_pad(m, pad, .Whole, "Flatten to Audio", pd)
}
