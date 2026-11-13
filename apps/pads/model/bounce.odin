package pads_model

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"

import app "app:core"
import "fire:audiofile"

// Bouncing: what some pads or a bus play in the current sequence,
// rendered offline (as an export) onto a new pad (`bounce_to_pad`); or a
// pad's sound in each sequence it plays in, onto a new audio track that
// plays it there instead, the pad muted (`bounce_in_place_begin`).

// The first empty pad after pad `from` (round), or -1.
next_empty_pad :: proc(p: ^Project, from: int) -> int {
	for k in 1 ..= PADS do if i := (from + k) % PADS; i != from && !pad_used(p, i) do return i
	return -1
}

// Starts bouncing the current sequence, once, with only pads `pads`
// heard (after their faders and sends; main's effects and fader aren't
// in it), onto a new sample on the next empty pad after the first of
// them. Step it with `export_step`; `export_finish` puts it there (one
// undo step, "Bounce to Pad"). False if nothing to bounce or no room.
bounce_pads :: proc(m: ^Model, x: ^Export, pads: bit_set[0 ..< PADS; u128]) -> bool {
	p := &m.project
	first, count := -1, 0
	for i in pads do if pad_used(p, i) {
		if first < 0 do first = i
		count += 1
	}
	if first < 0 do return false
	label := fmt.tprintf("Bounce %s", pad_label(first)) if count == 1 else fmt.tprintf("Bounce %d pads", count)
	return bounce_begin(m, x, {kind = .Pads, pads = pads, dry = true}, first, label)
}

// Starts bouncing the current sequence, once, as bus `b` (0-based) sounds
// (the pads on it, through its effects), onto a new sample on the next
// empty pad (as `bounce_pads`).
bounce_bus :: proc(m: ^Model, x: ^Export, b: int) -> bool {
	p := &m.project
	if b < 0 || b >= p.bus_count do return false
	any := false
	for _, i in p.pads do if int(p.pads[i].bus) == b + 1 && pad_used(p, i) do any = true
	if !any do return false
	return bounce_begin(m, x, {kind = .Bus, index = b + 1, dry = true}, PADS - 1, fmt.tprintf("Bounce %s", bus_name(p, b + 1)))
}

@(private)
bounce_begin :: proc(m: ^Model, x: ^Export, solo: Export_Solo, after: int, label: string) -> bool {
	p := &m.project
	to := next_empty_pad(p, after)
	if to < 0 do return false
	dir, _ := filepath.join({p.dir, "samples"}, context.temp_allocator)
	os.make_directory_all(dir)
	path := unique_path(dir, strings.concatenate({label, " - ", sequence_name(p, p.slot), ".wav"}, context.temp_allocator))
	defer delete(path)
	if !export_begin(m, x, {source = .Sequence, encoding = .Float32, tail = 0}, path, solo) do return false
	x.to_pad = to
	x.bounce = strings.clone("Bounce to Pad")
	x.label = strings.clone(label)
	return true
}

// Whether pad `pad` can be bounced in place: a sound (not an audio pad,
// not frozen) with notes somewhere, and an empty pad for its track.
can_bounce_in_place :: proc(p: ^Project, pad: int) -> bool {
	return can_freeze(p, pad) && next_empty_pad(p, pad) >= 0
}

// Starts bouncing pad `pad` in place: its sound (its device through its
// inserts, before its fader) rendered for each sequence it plays in, as a
// freeze is. `export_finish` makes the next empty pad an audio track with
// those renderings as its takes, its fader, bus, sends and cue as the
// pad's, and mutes the pad (one undo step, "Bounce in Place"). False if it
// can't be.
bounce_in_place_begin :: proc(m: ^Model, x: ^Export, pad: int) -> bool {
	p := &m.project
	if !can_bounce_in_place(p, pad) do return false
	if !freeze_begin(m, x, pad, "Bounce") do return false
	x.freeze, x.in_place = -1, pad
	return true
}

// [export_finish] The new audio track with the renderings, the pad muted.
@(private)
bounce_in_place_finish :: proc(m: ^Model, x: ^Export) {
	p := &m.project
	pad := x.in_place
	if len(x.files) != len(x.passes) do return
	to := next_empty_pad(p, pad)
	if to < 0 do return
	src := p.pads[pad]
	app.begin(&m.history, "Bounce in Place")
	defer app.end(&m.history)
	track := default_pad()
	track.kind = .Audio
	set_pad_name(&track, fmt.tprintf("%s (bounced)", pad_name(&src) if pad_name(&src) != "" else pad_label(pad)))
	// What follows the tap: the fader, the routing. (Its pan, EQ and
	// inserts are in the rendering.)
	track.volume, track.bus, track.sends, track.cue = src.volume, src.bus, src.sends, src.cue
	track.color = src.color
	track.monitor = .Off
	set_pad(m, to, .Whole, "Bounce in Place", track)
	for f, k in x.files {
		r, err := audiofile.open(f)
		if err != .None do continue
		info := audiofile.info(r)
		audiofile.close(r)
		slot := x.passes[k].slot
		set_clip(m, slot, to, "Bounce in Place", {sample = add_sample(m, f, info), bpm = sequence_tempo(p, slot)})
	}
	src.mute = true
	set_pad(m, pad, .Mute, "Bounce in Place", src)
	x.made = to
	sync(&m.engine)
}
