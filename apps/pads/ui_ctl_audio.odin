// The sequencer's Audio tab on a controller's display (Push 2's Clip, the
// upper row's third tab): the selected audio track's part in the current
// sequence, its regions over its takes (the selected one ringed), the
// playhead. The knobs: the region, its place, its start and end, its gain,
// a take to play over it (Use Take), the part's warp and transpose. The
// lower row: Split (at the playhead while playing, else the region's
// middle), Delete, Mute, Use Take, Consolidate.
package pads

import "core:fmt"
import "core:math"

import app "app:core"
import "app:ui"
import pa "api"
import pm "model"
import im "deps:imgui"

@(private)
ctl_audio :: proc(ctx: ^View_Ctx, full: im.Vec2, plot: im.Vec2) {
	a := ctx.a
	m := &a.m
	p := &m.project
	slot := p.slot
	pad := a.selected
	if p.pads[pad].kind != .Audio {
		ctl_message(fmt.tprintf("%s isn't an audio track: select one (or make one: Add Track, then its input in Mix)", pm.pad_label(pad)), plot)
		return
	}
	length := pm.seq_beats(p, pm.current_sequence(m))
	ps, _ := pa.audio_part(&a.api, i64(slot), i64(pad))
	x := pm.part_of(p, slot, pad)
	grid := pm.grid_beats(a.seq.grid)
	sel := clamp(a.ctl.audio_region, 0, max(int(ps.regions) - 1, 0))
	// The picture.
	{
		t := ui.theme()
		dl := im.GetWindowDrawList()
		o := im.GetWindowPos()
		lo := im.Vec2{o.x + 2, o.y + CTL_PLOT_Y}
		hi := im.Vec2{o.x + plot.x - 4, o.y + CTL_PLOT_Y + plot.y}
		im.DrawList_AddRectFilled(dl, lo, hi, ui.col(ui.PLOT_BG), 3)
		draw_part(a, dl, slot, pad, lo, hi, 0, length, ui.rgb(p.pads[pad].color), boxes = true, sel = sel if ps.regions > 0 else -1)
		if beat, playing := pm.position(&m.engine); playing && length > 0 {
			hx := lo.x + f32(math.mod(beat, length) / length) * (hi.x - lo.x)
			im.DrawList_AddLine(dl, {hx, lo.y}, {hx, hi.y}, ui.col(t.text), 1)
		}
		if ps.regions == 0 {
			ui.text_push(.Label)
			msg: cstring = "No takes yet: arm the track (Mix) and record"
			im.DrawList_AddText(dl, {lo.x + ((hi.x - lo.x) - im.CalcTextSize(msg).x) / 2, lo.y + (hi.y - lo.y) / 2 - 8}, ui.col(t.text_dim), msg)
			ui.text_pop()
			return
		}
	}
	// The region.
	names := make([]string, ps.regions, context.temp_allocator)
	for k in 0 ..< int(ps.regions) {
		r := x.regions[k]
		names[k] = fmt.tprintf("%d · %s", k + 1, ctl_beat_name(p, r.at))
	}
	if k, _ := ctl_choice(ctx, 0, 8, "Region", names, sel, plot); k >= 0 do sel = k
	a.ctl.audio_region = sel
	r := x.regions[sel]
	end := pm.region_end(p, slot, pad, &x, r)
	// Its place, start and end (the grid's steps), gain.
	if k, en := ctl_value_box(ctx, 1, "Position", ctl_beat_name(p, r.at), CTL_STEP, plot); k != 0 || en {
		if k != 0 do pa.audio_move_region(&a.api, i64(slot), i64(pad), i64(sel), clamp(r.at + f64(k) * grid, 0, length))
		if en do app.seal(&m.history)
	}
	if k, en := ctl_value_box(ctx, 2, "Start", ctl_beat_name(p, r.at), CTL_STEP, plot); k != 0 || en {
		if k != 0 do pa.audio_trim_region(&a.api, i64(slot), i64(pad), i64(sel), clamp(r.at + f64(k) * grid, 0, end - grid), false)
		if en do app.seal(&m.history)
	}
	if k, en := ctl_value_box(ctx, 3, "End", ctl_beat_name(p, end), CTL_STEP, plot); k != 0 || en {
		if k != 0 do pa.audio_trim_region(&a.api, i64(slot), i64(pad), i64(sel), clamp(end + f64(k) * grid, r.at + grid, length), true)
		if en do app.seal(&m.history)
	}
	rg, _ := pa.audio_region(&a.api, i64(slot), i64(pad), i64(sel))
	if k, en := ctl_value_box(ctx, 4, "Gain", fmt.tprintf("%+.1f dB", rg.gain_db), 1.0 / 160, plot); k != 0 || en {
		if k != 0 {
			rg.gain_db = clamp(rg.gain_db + f32(k) * 0.5, -48, 12)
			pa.audio_set_region(&a.api, i64(slot), i64(pad), i64(sel), rg)
		}
		if en do app.seal(&m.history)
	}
	// A take to play over the region (Use Take).
	tnames := make([]string, ps.takes, context.temp_allocator)
	for k in 0 ..< int(ps.takes) do tnames[k] = fmt.tprintf("Take %d", k + 1)
	a.ctl.audio_take = clamp(a.ctl.audio_take, 0, max(int(ps.takes) - 1, 0))
	if ps.takes > 0 {
		if k, _ := ctl_choice(ctx, 5, 8, "Take", tnames, a.ctl.audio_take, plot); k >= 0 do a.ctl.audio_take = k
	}
	// The part's warp and transpose.
	if k, _ := ctl_choice(ctx, 6, 8, "Warp", []string{"Repitch", "Stretch"}, int(ps.warp), plot); k >= 0 && pa.Audio_Warp(k) != ps.warp {
		pa.audio_set_warp(&a.api, i64(slot), i64(pad), pa.Audio_Warp(k), ps.transpose)
	}
	if ps.warp == .Stretch {
		if k, en := ctl_value_box(ctx, 7, "Transpose", fmt.tprintf("%+.0f st", ps.transpose), CTL_STEP, plot); k != 0 || en {
			if k != 0 do pa.audio_set_warp(&a.api, i64(slot), i64(pad), ps.warp, clamp(ps.transpose + f32(k), -24, 24))
			if en do app.seal(&m.history)
		}
	}
	// The lower row.
	if pr, _ := ctl_button(ctx, 0, "Split", false, full); pr {
		at := (r.at + end) / 2
		if beat, playing := pm.position(&m.engine); playing do at = math.mod(beat, length)
		pa.audio_split(&a.api, i64(slot), i64(pad), math.round(at / grid) * grid)
	}
	if pr, _ := ctl_button(ctx, 1, "Delete", false, full); pr {
		pa.audio_delete_region(&a.api, i64(slot), i64(pad), i64(sel))
		a.ctl.audio_region = max(sel - 1, 0)
	}
	if pr, _ := ctl_button(ctx, 2, "Mute", rg.mute, full); pr {
		rg.mute = !rg.mute
		pa.audio_set_region(&a.api, i64(slot), i64(pad), i64(sel), rg)
	}
	if ps.takes > 0 {
		if pr, _ := ctl_button(ctx, 3, "Use Take", false, full); pr do pa.audio_use_take(&a.api, i64(slot), i64(pad), i64(a.ctl.audio_take), r.at, end)
	}
	if pr, _ := ctl_button(ctx, 4, "Consolidate", false, full); pr {
		if pa.audio_consolidate(&a.api, i64(slot), i64(pad)) == .Busy do ui.toast(&a.ws.toasts, .Warning, "A take is still being rendered: try again in a moment")
	}
}
