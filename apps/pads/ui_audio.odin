package pads

import "core:fmt"
import "core:math"

import app "app:core"
import "app:ui"
import pm "model"
import im "deps:imgui"

// The Sequence view's Audio tab: the selected audio track's part in the
// current sequence, large. Click a region to select it, drag it to move it,
// its ends to trim it, the squares at its top corners for its fades; drag
// across empty space (or Shift-drag anywhere) to select a range of beats;
// a click places the cursor (where Split and Paste act). The tools above
// act on the range, else the region, else the whole part. Nothing touches
// the recorded files (Consolidate writes a new one).

// The Audio tab's state.
Audio_View :: struct {
	region:   int,    // the selected region (-1: none)
	range:    [2]f64, // a range of beats selected (none when [1] <= [0])
	cursor:   f64,    // where Split and Paste act
	drag:     Audio_Drag,
	grab:     f64,    // the beat a drag began at
	orig:     pm.Region, // the region as it began
	orig_i:   int,       // ... its index in `base`
	base:     pm.Audio_Part, // the part as it began
	clip:     pm.Audio_Clipboard,
	has_clip: bool,
	pad_was, slot_was: int,
}

// What a drag in the Audio tab does.
Audio_Drag :: enum u8 {None, Move, Trim_Start, Trim_End, Fade_In, Fade_Out, Range}

// Peaks of a take for drawing: the lowest and highest frame of each
// PEAK_BUCKET frames (the channels together).
Peaks :: struct {
	frames: i64,
	lo, hi: []f32,
}

PEAK_BUCKET :: 128

// The peaks of sample `id` (read once, kept by path), or nil.
take_peaks_of :: proc(a: ^App, id: app.Id) -> ^Peaks {
	s := app.store_get(&a.m.project.samples, id)
	if s == nil do return nil
	if pk, ok := &a.take_peaks[s.path]; ok do return pk
	if len(a.take_peaks) > 64 do take_peaks_clear(a)
	au, err := pm.read_audio(s.path, context.temp_allocator)
	if err != .None || len(au.channels) == 0 do return nil
	n := len(au.channels[0])
	buckets := (n + PEAK_BUCKET - 1) / PEAK_BUCKET
	pk := Peaks{frames = i64(n), lo = make([]f32, buckets), hi = make([]f32, buckets)}
	for b in 0 ..< buckets {
		lo, hi: f32 = 0, 0
		for c in au.channels do for v in c[b * PEAK_BUCKET:min((b + 1) * PEAK_BUCKET, n)] {
			lo, hi = min(lo, v), max(hi, v)
		}
		pk.lo[b], pk.hi[b] = lo, hi
	}
	a.take_peaks[s.path] = pk
	return &a.take_peaks[s.path]
}

// Lets go of every take's peaks.
take_peaks_clear :: proc(a: ^App) {
	for _, pk in a.take_peaks {
		delete(pk.lo)
		delete(pk.hi)
	}
	clear(&a.take_peaks)
}

// Draws pad `pad`'s part in `slot` in the rectangle lo..hi, beats
// `beat0`..`beat0 + beats` across: each region (later ones over earlier)
// its waveform, as it plays (gain, fades, reversed, muted dim). With
// `boxes`, each region a box with its fades and their handles, region
// `sel` outlined.
draw_part :: proc(a: ^App, dl: ^im.DrawList, slot, pad: int, lo, hi: im.Vec2, beat0, beats: f64, color: ui.Color, boxes := false, sel := -1) {
	p := &a.m.project
	t := ui.theme()
	x := pm.part_of(p, slot, pad)
	if x.count == 0 || beats <= 0 do return
	bw := f64(hi.x - lo.x) / beats
	bpm := p.clips[slot][pad].bpm
	if bpm <= 0 do bpm = pm.sequence_tempo(p, slot)
	mid := (lo.y + hi.y) / 2
	half := (hi.y - lo.y) / 2 * 0.92
	im.DrawList_PushClipRect(dl, lo, hi, true)
	defer im.DrawList_PopClipRect(dl)
	// A track with its own loop: its loop again each time round (faded),
	// the first pass the one to edit.
	loop := pm.part_beats(p, slot, pad)
	whole := pm.seq_beats(p, p.sequences[slot])
	passes := 1 if loop >= whole - 1e-9 else int(math.ceil(whole / loop - 1e-9))
	for pass in 0 ..< passes do for r, i in x.regions[:x.count] {
		if pass > 0 && r.at >= loop - 1e-9 do continue
		off := f64(pass) * loop
		end := min(pm.region_end(p, slot, pad, &x, r), loop if passes > 1 else math.F64_MAX) + off
		end = min(end, whole) if passes > 1 else end
		rx0 := lo.x + f32((r.at + off - beat0) * bw)
		rx1 := lo.x + f32((end - beat0) * bw)
		if rx1 < lo.x || rx0 > hi.x || rx1 <= rx0 do continue
		c := color if !r.mute else ui.mix(color, t.text_dim, 0.7)
		if pass > 0 do c = ui.mix(t.inset, c, 0.55)
		// (Its box hides what is under it: it is what is heard there.)
		im.DrawList_AddRectFilled(dl, {rx0, lo.y}, {rx1, hi.y}, ui.col(ui.mix(t.inset, c, 0.22 if boxes else 0.12)), 3 if boxes else 0)
		pk := take_peaks_of(a, x.takes[r.take])
		if pk != nil {
			fpb := pm.frames_per_beat_of(p, slot, pad, x.takes[r.take])
			amp := f32(math.pow(10, f64(r.gain) / 20))
			ink := ui.col(ui.mix(c, t.text, 0.15))
			for px := max(rx0, lo.x); px < min(rx1, hi.x); px += 1 {
				b0 := beat0 + f64(px - lo.x) / bw - off
				b1 := b0 + 1 / bw
				f0 := (b0 - r.at) * fpb
				f1 := (b1 - r.at) * fpb
				a0, a1 := f64(r.start) + f0, f64(r.start) + f1
				if r.reverse do a0, a1 = f64(r.end) - f1, f64(r.end) - f0
				k0 := clamp(int(a0) / PEAK_BUCKET, 0, len(pk.lo) - 1)
				k1 := clamp(int(a1) / PEAK_BUCKET, k0, len(pk.lo) - 1)
				vlo, vhi: f32
				for k in k0 ..= k1 do vlo, vhi = min(vlo, pk.lo[k]), max(vhi, pk.hi[k])
				secs_in := (b0 - r.at) * 60 / bpm
				secs_out := (end - off - b0) * 60 / bpm
				env: f64 = 1
				if r.fade_in > 0 do env = min(env, secs_in / f64(r.fade_in))
				if r.fade_out > 0 do env = min(env, secs_out / f64(r.fade_out))
				g := amp * f32(clamp(env, 0, 1))
				y0 := mid - clamp(vhi * g, -1, 1) * half
				y1 := mid - clamp(vlo * g, -1, 1) * half
				im.DrawList_AddLine(dl, {px + 0.5, y0}, {px + 0.5, max(y1, y0 + 1)}, ink)
			}
		}
		if !boxes || pass > 0 do continue
		// Its fades, as lines from silence, and their handles.
		secs_beat := 60 / bpm
		fi := f32(f64(r.fade_in) / secs_beat * bw)
		fo := f32(f64(r.fade_out) / secs_beat * bw)
		line := ui.col(ui.with_alpha(t.text, 0.7))
		if fi > 1 do im.DrawList_AddLine(dl, {rx0, hi.y}, {rx0 + fi, lo.y}, line, 1.5)
		if fo > 1 do im.DrawList_AddLine(dl, {rx1 - fo, lo.y}, {rx1, hi.y}, line, 1.5)
		hs: f32 = 7
		im.DrawList_AddRectFilled(dl, {rx0 + fi - hs / 2, lo.y}, {rx0 + fi + hs / 2, lo.y + hs}, ui.col(t.text))
		im.DrawList_AddRectFilled(dl, {rx1 - fo - hs / 2, lo.y}, {rx1 - fo + hs / 2, lo.y + hs}, ui.col(t.text))
		if i == sel do im.DrawList_AddRect(dl, {rx0, lo.y}, {rx1, hi.y}, ui.col(t.accent), 3, 2)
		else do im.DrawList_AddRect(dl, {rx0, lo.y}, {rx1, hi.y}, ui.col(ui.with_alpha(c, 0.8)), 3)
		if r.reverse || r.mute || r.gain != 0 {
			label := fmt.ctprintf("%s%s%s", "◀ " if r.reverse else "", "muted " if r.mute else "", fmt.tprintf("%+.1f dB", r.gain) if r.gain != 0 else "")
			im.DrawList_AddText(dl, {rx0 + 6, hi.y - im.GetFontSize() - 4}, ui.col(t.text_dim), label)
		}
	}
}

// The range the Audio tab's tools act on: the range selected, else the
// selected region's, else the whole sequence.
@(private)
audio_span :: proc(a: ^App, slot, pad: int, length: f64) -> (lo, hi: f64) {
	av := &a.seq.aud
	if av.range[1] > av.range[0] do return av.range[0], av.range[1]
	x := pm.part_of(&a.m.project, slot, pad)
	if av.region >= 0 && av.region < x.count {
		r := x.regions[av.region]
		return r.at, pm.region_end(&a.m.project, slot, pad, &x, r)
	}
	return 0, length
}

// The Audio tab's tools, in the mode bar: Split, Cut, Copy, Paste, Delete,
// Crop; Normalize, Reverse, Mute; the takes; Spread Takes, Consolidate.
draw_audio_tools :: proc(a: ^App) {
	m := &a.m
	av := &a.seq.aud
	slot, pad := m.project.slot, a.selected
	if m.project.pads[pad].kind != .Audio do return
	length := pm.seq_beats(&m.project, pm.current_sequence(m))
	x := pm.part_of(&m.project, slot, pad)
	has := x.count > 0
	ri := av.region // (as the frame began: a tool below may change the selection)
	region := ri >= 0 && ri < x.count
	lo, hi := audio_span(a, slot, pad, length)
	bar :: proc(first: bool) {
		if !first do im.SameLine(0, 2)
	}
	if ui.icon_button(ui.ICON_SPLIT, "Split (Cmd+T): at the cursor, or the range's ends", disabled = !has) do audio_split(a)
	ui.name("audio split")
	im.SameLine(0, 2)
	if ui.icon_button(ui.ICON_SCISSORS, "Cut (Cmd+X): the range, or the region", disabled = !has) do audio_cut(a, true)
	ui.name("audio cut")
	im.SameLine(0, 2)
	if ui.icon_button(ui.ICON_COPY, "Copy (Cmd+C): the range, or the region", disabled = !has) do audio_copy(a)
	ui.name("audio copy")
	im.SameLine(0, 2)
	if ui.icon_button(ui.ICON_CLIPBOARD_PASTE, "Paste (Cmd+V): at the cursor", disabled = !av.has_clip) do audio_paste(a)
	ui.name("audio paste")
	im.SameLine(0, 2)
	if ui.icon_button(ui.ICON_TRASH_2, "Delete: the range (silence there), or the region", disabled = !has) do audio_cut(a, false)
	ui.name("audio delete")
	im.SameLine(0, 2)
	if ui.icon_button(ui.ICON_CROP, "Crop: keep only the range, or the region", disabled = !has || (!region && av.range[1] <= av.range[0])) {
		pm.crop_to(m, slot, pad, lo, hi)
		av.region, av.range = -1, {}
	}
	ui.name("audio crop")
	im.SameLine(0, 12)
	if ui.icon_button(ui.ICON_SIGNAL_HIGH, "Normalize: the region's loudest at 0 dB", disabled = !region) do pm.normalize_region(m, slot, pad, ri)
	ui.name("audio normalize")
	im.SameLine(0, 2)
	if ui.icon_button(ui.ICON_FLIP_HORIZONTAL, "Reverse: the region backwards", on = region && x.regions[ri].reverse, disabled = !region) {
		r := x.regions[ri]
		r.reverse = !r.reverse
		pm.set_region(m, slot, pad, ri, "Reverse", r)
		app.seal(&m.history)
	}
	ui.name("audio reverse")
	im.SameLine(0, 2)
	all_muted := has
	for r in x.regions[:x.count] do if !r.mute do all_muted = false
	if ui.icon_button(ui.ICON_VOLUME_X, "Mute (0): the region silent (what is under it isn't heard either); the range's regions, or with none chosen the whole clip", on = (region && x.regions[ri].mute) || (!region && all_muted), disabled = !has) do audio_mute(a)
	ui.name("audio mute")
	im.SameLine(0, 12)
	// The takes: one for the range (comping), the region's, or everywhere.
	ui.flow(96, 2)
	im.SetNextItemWidth(96)
	if ui.combo("##takes", fmt.ctprintf("Takes: %d", x.take_count)) {
		if x.take_count == 0 do im.TextDisabled("No takes yet: arm it and record")
		for k in 0 ..< x.take_count {
			s := app.store_get(&m.project.samples, x.takes[k])
			name := s.name if s != nil else "?"
			if im.Selectable(fmt.ctprintf("Take %d · %s · from beat %.2f###take%d", k + 1, name, x.take_at[k] + 1, k)) {
				pm.use_take(m, slot, pad, k, lo, hi)
			}
		}
		im.EndCombo()
	}
	ui.name("audio takes")
	if im.IsItemHovered() do im.SetTooltip("Each pass recorded: pick one for the range (comping), the region, or the whole part")
	im.SameLine(0, 2)
	if ui.icon_button(ui.ICON_ROWS_3, "Spread Takes: each take after the first onto a track of its own (doubling)", disabled = x.take_count < 2) {
		made := pm.spread_takes(m, slot, pad)
		if len(made) > 0 do ui.toast(&a.ws.toasts, .Success, fmt.tprintf("%d take%s onto %s…", len(made), "" if len(made) == 1 else "s", pm.pad_label(made[0])))
		else do ui.toast(&a.ws.toasts, .Warning, "No empty pad for the takes")
	}
	ui.name("audio spread")
	im.SameLine(0, 2)
	if ui.icon_button(ui.ICON_COMBINE, "Consolidate: the part as it plays written as a new take", disabled = !has) {
		if pm.consolidate(m, slot, pad) do av.region, av.range = 0, {}
	}
	ui.name("audio consolidate")
	im.SameLine(0, 12)
	warp := int(x.warp)
	ui.flow(150, 2)
	if ui.segmented("audio warp", {"Repitch", "Stretch"}, &warp) {
		pm.set_part_warp(m, slot, pad, pm.Clip_Warp(warp), x.transpose)
		app.seal(&m.history)
	}
	if im.IsItemHovered() do im.SetTooltip("At another tempo: faster or slower with its pitch (Repitch), or its pitch kept (Stretch; and transposed)")
	if x.warp == .Stretch {
		im.SameLine(0, 4)
		tr := f64(x.transpose)
		if e := ui.number_drag("audio transpose", &tr, -24, 24, 1, 1, "%+.0f st", 64); e.changed do pm.set_part_warp(m, slot, pad, x.warp, f32(tr))
		else if e.ended do app.seal(&m.history)
	}
	im.SameLine(0, 12)
	// The track's own loop (polymeter), here as in the Notes grid's row menu.
	{
		cur := pm.part_beats(&m.project, slot, pad)
		lb := cur
		e := ui.number_drag("audio loop", &lb, 0.25, length, 0.25, 1.0 / 16, "Loop %.4g" if cur < length - 1e-9 else "Loop: off", 90)
		if e.changed do pm.set_track_loop(m, slot, pad, lb)
		if e.ended do app.seal(&m.history)
		if im.IsItemHovered() do im.SetTooltip("The track's own loop: its first beats again each time round, to the sample (drag to the sequence's length: off)")
	}
	im.SameLine(0, 12)
	draw_grid_controls(a, quantize = false)
	_ = bar
}

// Mutes (or unmutes) the selected region; with a range, the regions in
// it; with neither, the whole clip: each silent, what is under it too. A
// mix of muted and not: all muted. One undo step, "Mute".
@(private)
audio_mute :: proc(a: ^App) {
	m := &a.m
	av := &a.seq.aud
	slot, pad := m.project.slot, a.selected
	x := pm.part_of(&m.project, slot, pad)
	if x.count == 0 do return
	which := make([dynamic]int, context.temp_allocator)
	switch {
	case av.range[1] > av.range[0]:
		for r, k in x.regions[:x.count] do if r.at < av.range[1] && pm.region_end(&m.project, slot, pad, &x, r) > av.range[0] do append(&which, k)
	case av.region >= 0 && av.region < x.count:
		append(&which, av.region)
	case:
		for k in 0 ..< x.count do append(&which, k)
	}
	if len(which) == 0 do return
	to := false
	for k in which do if !x.regions[k].mute do to = true
	app.seal(&m.history)
	app.begin(&m.history, "Mute" if to else "Unmute")
	for k in which {
		r := x.regions[k]
		r.mute = to
		pm.set_region(m, slot, pad, k, "Mute" if to else "Unmute", r)
	}
	app.end(&m.history)
	app.seal(&m.history)
}

// Splits at the range's ends, else the cursor.
@(private)
audio_split :: proc(a: ^App) {
	m := &a.m
	av := &a.seq.aud
	slot, pad := m.project.slot, a.selected
	if av.range[1] > av.range[0] {
		app.begin(&m.history, "Split")
		pm.split_at(m, slot, pad, av.range[0])
		pm.split_at(m, slot, pad, av.range[1])
		app.end(&m.history)
	} else {
		pm.split_at(m, slot, pad, av.cursor)
	}
	av.region = pm.region_at(&m.project, slot, pad, av.cursor)
}

// Copies the range (or the region) to the Audio tab's clipboard.
@(private)
audio_copy :: proc(a: ^App) {
	m := &a.m
	av := &a.seq.aud
	slot, pad := m.project.slot, a.selected
	lo, hi := audio_span(a, slot, pad, pm.seq_beats(&m.project, pm.current_sequence(m)))
	av.clip = pm.copy_range(m, slot, pad, lo, hi)
	av.has_clip = av.clip.count > 0
}

// Cut (copied first) or Delete: the range goes silent; a region selected
// (no range) goes.
@(private)
audio_cut :: proc(a: ^App, copying: bool) {
	m := &a.m
	av := &a.seq.aud
	slot, pad := m.project.slot, a.selected
	if copying do audio_copy(a)
	if av.range[1] > av.range[0] {
		pm.delete_range(m, slot, pad, av.range[0], av.range[1], "Cut" if copying else "Delete")
	} else if av.region >= 0 {
		pm.delete_region(m, slot, pad, av.region)
	}
	av.region = -1
}

@(private)
audio_paste :: proc(a: ^App) {
	m := &a.m
	av := &a.seq.aud
	if !av.has_clip do return
	slot, pad := m.project.slot, a.selected
	if pm.paste_at(m, slot, pad, av.clip, av.cursor) {
		av.range = {av.cursor, av.cursor + av.clip.length}
		av.region = -1
	}
}

// The Audio tab: the selected region's fades, gain and pan; the ruler; the
// part, large.
draw_audio_view :: proc(a: ^App, length, snap: f64) {
	m := &a.m
	p := &m.project
	av := &a.seq.aud
	t := ui.theme()
	slot, pad := p.slot, a.selected
	if av.pad_was != pad || av.slot_was != slot {
		av.region, av.range, av.cursor, av.drag = -1, {}, 0, .None
		av.pad_was, av.slot_was = pad, slot
	}
	if p.pads[pad].kind != .Audio {
		im.TextDisabled("%s isn't an audio track. Select one, or:", fmt.ctprintf("%s", pm.pad_label(pad)))
		im.SameLine()
		if im.Button(fmt.ctprintf("Make %s an audio track", pm.pad_label(pad))) do pm.set_pad_kind(m, pad, .Audio)
		ui.name("make audio track")
		return
	}
	x := pm.part_of(p, slot, pad)
	if av.region >= x.count do av.region = -1
	bpm := p.clips[slot][pad].bpm
	if bpm <= 0 do bpm = pm.sequence_tempo(p, slot)
	// The region's settings.
	name := pm.pad_name(&p.pads[pad])
	im.Text("%s", fmt.ctprintf("%s %s", pm.pad_label(pad), name))
	im.SameLine(0, 16)
	if av.region >= 0 {
		r := x.regions[av.region]
		field :: proc(a: ^App, id: cstring, label: cstring, v: ^f32, lo, hi, step: f64, format: cstring, undo: string) -> bool {
			f := f64(v^)
			e := ui.value_bar(id, label, &f, lo, hi, step, step / 10, format, 120)
			if e.changed do v^ = f32(f)
			if e.ended do app.seal(&a.m.history)
			im.SameLine(0, 6)
			return e.changed
		}
		changed := false
		changed |= field(a, "region fade in", "Fade in", &r.fade_in, 0, 4, 0.01, "%.2f s", "Fade In")
		changed |= field(a, "region fade out", "Fade out", &r.fade_out, 0, 4, 0.01, "%.2f s", "Fade Out")
		changed |= field(a, "region gain", "Gain", &r.gain, -48, 24, 0.5, "%+.1f dB", "Region Gain")
		changed |= field(a, "region pan", "Pan", &r.pan, -1, 1, 0.05, "%+.2f", "Region Pan")
		if changed do pm.set_region(m, slot, pad, av.region, "Region", r)
		im.NewLine()
	} else if x.count == 0 {
		im.TextDisabled("Nothing in this sequence yet: arm the track and record, or paste.")
	} else {
		im.TextDisabled("Click a region to change it; drag across to select a range.")
	}

	avail := im.GetContentRegionAvail()
	pos := im.GetCursorScreenPos()
	RULER :: 18
	size := im.Vec2{avail.x, max(avail.y, 80)}
	dl := im.GetWindowDrawList()
	lo := im.Vec2{pos.x, pos.y + RULER}
	hi := im.Vec2{pos.x + size.x, pos.y + size.y}
	bw := f64(size.x) / max(length, 1e-6)
	xof :: proc(b, bw: f64, x0: f32) -> f32 { return x0 + f32(b * bw) }
	// The ruler: bars and beats.
	im.DrawList_AddRectFilled(dl, pos, {hi.x, lo.y}, ui.col(t.surface))
	bar := pm.bar_beats(p)
	for b := 0.0; b <= length + 1e-9; b += 1 {
		xx := xof(b, bw, pos.x)
		major := math.mod(b, bar) < 1e-9
		im.DrawList_AddLine(dl, {xx, lo.y - (10 if major else 5)}, {xx, lo.y}, ui.col(ui.with_alpha(t.text, 0.5 if major else 0.25)))
		if major do im.DrawList_AddText(dl, {xx + 3, pos.y + 1}, ui.col(t.text_dim), fmt.ctprintf("%d", int(b / bar) + 1))
	}
	// The lane and the grid.
	im.DrawList_AddRectFilled(dl, lo, hi, ui.col(ui.WAVE_BG))
	if snap > 0 do for b := snap; b < length; b += snap {
		xx := xof(b, bw, pos.x)
		major := math.mod(b, 1) < 1e-9
		im.DrawList_AddLine(dl, {xx, lo.y}, {xx, hi.y}, ui.col(ui.with_alpha(t.text, 0.10 if major else 0.04)))
	}
	im.DrawList_AddLine(dl, {lo.x, (lo.y + hi.y) / 2}, {hi.x, (lo.y + hi.y) / 2}, ui.col(ui.with_alpha(t.text, 0.08)))
	// The range under the regions.
	if av.range[1] > av.range[0] {
		im.DrawList_AddRectFilled(dl, {xof(av.range[0], bw, pos.x), lo.y}, {xof(av.range[1], bw, pos.x), hi.y}, ui.col(ui.with_alpha(t.accent, 0.18)))
	}
	draw_part(a, dl, slot, pad, lo, hi, 0, length, ui.rgb(p.pads[pad].color), boxes = true, sel = av.region)
	draw_live_audio(a, dl, pad, lo, hi, 0, length) // (recording: what comes in, as it comes)
	// Its track's own loop: the end marked, what follows (its loop again) dimmed.
	if loop := pm.part_beats(p, slot, pad); loop < length - 1e-9 {
		lx := xof(loop, bw, pos.x)
		im.DrawList_AddRectFilled(dl, {lx, lo.y}, hi, ui.col(ui.with_alpha(t.bg, 0.35)))
		im.DrawList_AddLine(dl, {lx, pos.y}, {lx, hi.y}, ui.col(t.warn), 2)
		im.DrawList_AddText(dl, {lx + 4, pos.y + 1}, ui.col(t.warn), fmt.ctprintf("loop %g", loop))
	}
	if av.range[1] > av.range[0] {
		for b in av.range do im.DrawList_AddLine(dl, {xof(b, bw, pos.x), lo.y}, {xof(b, bw, pos.x), hi.y}, ui.col(t.accent), 1.5)
	}
	// The cursor and the playhead.
	im.DrawList_AddLine(dl, {xof(av.cursor, bw, pos.x), pos.y}, {xof(av.cursor, bw, pos.x), hi.y}, ui.col(ui.with_alpha(t.text, 0.6)), 1)
	if beat, playing := pm.position(&m.engine); playing {
		im.DrawList_AddLine(dl, {xof(beat, bw, pos.x), pos.y}, {xof(beat, bw, pos.x), hi.y}, ui.col(t.accent), 2)
	}

	// The mouse.
	im.SetCursorScreenPos(pos)
	im.InvisibleButton("##audio", size, {.MouseButtonLeft})
	ui.name("audio editor")
	io := im.GetIO()
	mouse := io.MousePos
	at := clamp(f64(mouse.x - pos.x) / bw, 0, length)
	snapped :: proc(b, snap: f64) -> f64 { return math.round(b / snap) * snap if snap > 0 else b }
	// What is under the mouse: a fade handle, an end, a region.
	hit := -1
	what := Audio_Drag.None
	for i := x.count - 1; i >= 0 && hit < 0; i -= 1 {
		r := x.regions[i]
		rx0 := xof(r.at, bw, pos.x)
		rx1 := xof(pm.region_end(p, slot, pad, &x, r), bw, pos.x)
		if mouse.x < rx0 - 3 || mouse.x > rx1 + 3 || mouse.y < lo.y || mouse.y > hi.y do continue
		hit = i
		fi := f32(f64(r.fade_in) * bpm / 60 * bw)
		fo := f32(f64(r.fade_out) * bpm / 60 * bw)
		switch {
		case mouse.y < lo.y + 10 && abs(mouse.x - (rx0 + fi)) < 6: what = .Fade_In
		case mouse.y < lo.y + 10 && abs(mouse.x - (rx1 - fo)) < 6: what = .Fade_Out
		case abs(mouse.x - rx0) < 5: what = .Trim_Start
		case abs(mouse.x - rx1) < 5: what = .Trim_End
		case:                         what = .Move
		}
	}
	shift := io.KeyShift
	if im.IsItemHovered() && av.drag == .None {
		#partial switch what {
		case .Trim_Start, .Trim_End: im.SetMouseCursor(.ResizeEW)
		case .Fade_In, .Fade_Out:    im.SetMouseCursor(.Hand)
		case .Move:                  if !shift do im.SetMouseCursor(.ResizeAll)
		}
	}
	if im.IsItemActivated() {
		av.grab = at
		av.base = x
		if shift || hit < 0 {
			av.drag = .Range
			av.range = {snapped(at, snap), snapped(at, snap)}
			av.region = -1
		} else {
			av.drag = what
			av.region = hit
			av.orig, av.orig_i = x.regions[hit], hit
			av.range = {}
		}
	}
	if im.IsItemActive() && av.drag != .None && im.IsMouseDragging(.Left, 2) {
		#partial switch av.drag {
		case .Range:
			b := snapped(at, snap)
			g := snapped(av.grab, snap)
			av.range = {min(g, b), max(g, b)}
		case .Move:
			to := snapped(av.orig.at + (at - av.grab), snap)
			pm.move_region(m, slot, pad, av.orig_i, to, &av.base)
			// (Moved, it is the top one: the last.)
			av.region = pm.part_of(p, slot, pad).count - 1
		case .Trim_Start, .Trim_End:
			end := av.drag == .Trim_End
			edge := pm.region_end(p, slot, pad, &av.base, av.orig) if end else av.orig.at
			pm.trim_region(m, slot, pad, av.orig_i, snapped(edge + (at - av.grab), snap), end, &av.base)
		case .Fade_In, .Fade_Out:
			r := pm.part_of(p, slot, pad).regions[av.region]
			end := pm.region_end(p, slot, pad, &x, r)
			secs := f32(max((at - r.at) if av.drag == .Fade_In else (end - at), 0) * 60 / bpm)
			span := f32((end - r.at) * 60 / bpm)
			if av.drag == .Fade_In do r.fade_in = clamp(secs, 0, span - r.fade_out)
			else do r.fade_out = clamp(secs, 0, span - r.fade_in)
			pm.set_region(m, slot, pad, av.region, "Fade In" if av.drag == .Fade_In else "Fade Out", r)
		}
	}
	if im.IsItemDeactivated() {
		if !dragged_since_press(2) {
			// A click: the cursor there (and the region under it, or none).
			av.cursor = snapped(at, snap)
			if av.drag == .Range do av.range = {}
		}
		av.drag = .None
		app.seal(&m.history)
	}
	// Keys, while the view has the keyboard.
	if a.seq.focused && !io.WantTextInput {
		cmd := io.KeyCtrl // (Cmd on a Mac: ImGui's Mac behaviour)
		if cmd && im.IsKeyPressed(.T, false) do audio_split(a) // (not S: a pad key)
		if cmd && im.IsKeyPressed(.X, false) do audio_cut(a, true)
		if cmd && im.IsKeyPressed(.C, false) do audio_copy(a)
		if cmd && im.IsKeyPressed(.V, false) do audio_paste(a)
		if (im.IsKeyPressed(.Delete, false) || im.IsKeyPressed(.Backspace, false)) && !cmd do audio_cut(a, false)
		if (im.IsKeyPressed(._0, false) || im.IsKeyPressed(.Keypad0, false)) && !cmd && !io.KeyAlt do audio_mute(a)
		if im.IsKeyPressed(.Escape, false) do av.region, av.range = -1, {}
	}
}

// Whether the mouse dragged further than `px` since the button went down.
@(private)
dragged_since_press :: proc(px: f32) -> bool {
	d := im.GetMouseDragDelta(.Left, 0)
	return abs(d.x) > px || abs(d.y) > px
}

// --- what is being recorded, drawn as it comes in ---------------------------------------------

// A frame's level on an armed audio track's input while recording: where
// the sequence was then (beats into it), and its peak.
Live_Peak :: struct {
	beat: f64,
	peak: f32,
}

// Each frame: while recording, each armed audio track's input level where
// the sequence is (what the take will hold, as a strip of levels: a peak
// a frame, from the meters already read, so it costs nothing on the
// audio thread); a new pass starts it again; stopped, it is let go (the
// take, folded in, shows instead).
live_audio_frame :: proc(a: ^App) {
	m := &a.m
	beat, playing := pm.position(&m.engine)
	recording := a.capture.armed && playing && beat >= 0
	for i in 0 ..< pm.PADS {
		l := &a.live_audio[i]
		if !recording || m.project.pads[i].kind != .Audio || !pm.track_armed(m, i) {
			if len(l) > 0 do clear(l)
			continue
		}
		if len(l) > 0 && beat < l[len(l) - 1].beat - 1e-6 do clear(l) // (round again: a new pass)
		append(l, Live_Peak{beat, input_peak(a, i)})
	}
}

// Pad `pad`'s input as it is being recorded, over the lane `lo`..`hi`
// showing beats `beat0`.. (`beats` across): its level a bar a frame, in
// the record colour.
draw_live_audio :: proc(a: ^App, dl: ^im.DrawList, pad: int, lo, hi: im.Vec2, beat0, beats: f64) {
	l := a.live_audio[pad]
	if len(l) < 2 || beats <= 0 do return
	t := ui.theme()
	w := hi.x - lo.x
	mid := (lo.y + hi.y) / 2
	half := (hi.y - lo.y) / 2 - 1
	x_of :: proc(b, beat0, beats: f64, x0, w: f32) -> f32 { return x0 + f32((b - beat0) / beats) * w }
	x0 := x_of(l[0].beat, beat0, beats, lo.x, w)
	x1 := x_of(l[len(l) - 1].beat, beat0, beats, lo.x, w)
	im.DrawList_AddRectFilled(dl, {max(x0, lo.x), lo.y}, {min(x1, hi.x), hi.y}, ui.col(ui.with_alpha(t.danger, 0.12)), 2)
	for k in 1 ..< len(l) {
		xa := x_of(l[k - 1].beat, beat0, beats, lo.x, w)
		xb := x_of(l[k].beat, beat0, beats, lo.x, w)
		if xb < lo.x || xa > hi.x do continue
		// (dB to the bar's height: -48 dB at nothing.)
		db := 20 * math.log10(max(l[k].peak, 1e-6))
		h := half * clamp((db + 48) / 48, 0, 1)
		im.DrawList_AddRectFilled(dl, {max(xa, lo.x), mid - h}, {min(max(xb, xa + 1), hi.x), mid + h}, ui.col(ui.with_alpha(t.danger, 0.85)))
	}
}
