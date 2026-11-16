// Pads' views for controllers' displays (fire.pads `view_frame`, Push 2's
// display): each view a surface asks for, drawn offscreen after the
// window's frame with Pads' widgets and theme, its pixels handed back to
// the API (a frame later).
package pads

import "core:fmt"

import "app:ui"
import pa "api"
import pm "model"
import im "deps:imgui"
import "fire:sampler"

// An offscreen UI for one view a surface wants (kind, page and size).
@(private)
View_Draw :: struct {
	key:  [4]i64, // kind, page, width, height
	off:  ui.Offscreen,
	put:  int, // the offscreen frames handed to the API
	used: bool,
}

// What a view's drawing is given.
@(private)
View_Ctx :: struct {
	a:    ^App,
	want: pa.View_Request,
}

// After the window's frame: the views surfaces want, drawn; their finished
// frames handed to the API. Views no longer wanted are let go.
views_render :: proc(a: ^App) {
	wants := pa.views_wanted(&a.api)
	for v in a.views do v.used = false
	for w in wants {
		key := [4]i64{i64(w.kind), w.page, w.width, w.height}
		v: ^View_Draw
		for x in a.views do if x.key == key do v = x
		if v == nil {
			v = new(View_Draw)
			v.key = key
			if !ui.offscreen_init(&v.off, &a.platform) {
				free(v)
				continue
			}
			append(&a.views, v)
		}
		v.used = true
		if px, pw, ph, n := ui.offscreen_pixels(&v.off); px != nil && n > v.put && i64(pw) == w.width && i64(ph) == w.height {
			pa.views_put(&a.api, w.index, px)
			v.put = n
		}
		ctx := View_Ctx{a = a, want = w}
		ui.offscreen_draw(&v.off, int(w.width), int(w.height), proc(user: rawptr) {
			ctx := (^View_Ctx)(user)
			view_draw(ctx.a, ctx.want)
		}, &ctx)
	}
	for i := len(a.views) - 1; i >= 0; i -= 1 do if !a.views[i].used {
		ui.offscreen_destroy(&a.views[i].off)
		free(a.views[i])
		ordered_remove(&a.views, i)
	}
}

// Lets every view's offscreen UI go (before the platform).
views_destroy :: proc(a: ^App) {
	for v in a.views {
		ui.offscreen_destroy(&v.off)
		free(v)
	}
	delete(a.views)
}

// Draws a view, filling the offscreen window.
@(private)
view_draw :: proc(a: ^App, w: pa.View_Request) {
	size := im.Vec2{f32(w.width), f32(w.height)}
	switch w.kind {
	case .Device: view_device(a, int(w.page), size)
	case .Mixer, .Sequencer, .Clip, .Browser: view_soon(w.kind, size)
	}
}

// A view not drawn yet: its name, centred.
@(private)
view_soon :: proc(kind: pa.View_Kind, size: im.Vec2) {
	text := fmt.ctprintf("%v", kind)
	ts := im.CalcTextSize(text)
	im.SetCursorPos({(size.x - ts.x) / 2, (size.y - ts.y) / 2})
	im.TextDisabled("%s", text)
}

// The selected pad's sound, as the device tabs draw it (their plots, without
// the knobs: the controller's encoders and its display's labels are those).
// Page 0: the amp envelope; 1: the filter (its response and envelope); 2:
// the pitch envelope; 3: the LFOs' traces.
@(private)
view_device :: proc(a: ^App, page: int, size: im.Vec2) {
	m := &a.m
	if a.selected < 0 || a.selected >= len(m.project.pads) do return
	pad := m.project.pads[a.selected]
	if pad.kind != .Sampler && pad.kind != .Slicer {
		view_soon(.Device, size)
		return
	}
	v := pad.voice
	live, secs := live_of(a)
	color := ui.rgb(pad.color)
	gap: f32 = 8
	switch page {
	case 1:
		sr := a.host.graph.settings.sample_rate if a.host.graph.settings.sample_rate > 0 else 48_000
		curves := make([dynamic]ui.Plot_Curve, context.temp_allocator)
		dim := ui.mix(ui.PLOT_BG, color, 0.55)
		setting := response_db(v.filter, v.steep, f64(v.cutoff), f64(v.resonance), sr)
		if v.filter == .Off {
			append(&curves, ui.Plot_Curve{db = setting, color = dim, width = 1.5})
		} else if live.sounding || abs(live.cutoff - f64(v.cutoff)) > 0.5 {
			append(&curves, ui.Plot_Curve{db = setting, color = dim, width = 1.5})
			append(&curves, ui.Plot_Curve{db = response_db(v.filter, v.steep, live.cutoff, live.resonance, sr), color = color, fill = true, width = 2.5})
		} else {
			append(&curves, ui.Plot_Curve{db = setting, color = color, fill = true, width = 2.5})
		}
		handle := [2]f32{ui.freq_x(v.cutoff), v.resonance * 24}
		resp_w := size.x * 0.62
		ui.response_plot("view filter", curves[:], &handle, {resp_w, size.y})
		im.SameLine(0, gap)
		fa := v.filter_adsr
		sign, env_c := env_depth(v.filter_env, color)
		ui.adsr_plot("view filter env", &fa, {size.x - resp_w - gap, size.y}, env_c, f32(live.filter_env) if live.sounding else -1, secs, sign)
	case 2:
		pa_ := v.pitch_adsr
		sign, env_c := env_depth(v.pitch_env / 12, color)
		ui.adsr_plot("view pitch env", &pa_, size, env_c, f32(live.pitch_env) if live.sounding else -1, secs, sign)
	case 3:
		st := &a.device
		if st.trace_pad != a.selected do st^ = {trace_pad = a.selected}
		colors := [2]ui.Color{color, ui.rgb(0xf5a623)}
		col_w := (size.x - gap) / 2
		for k in 0 ..< sampler.LFOS {
			if k > 0 do im.SameLine(0, gap)
			ui.trace_plot(fmt.ctprintf("view lfo %d", k), st.trace[k][:], st.trace_head, shape_points(v.lfos[k].shape, 64), {col_w, size.y}, colors[k])
		}
	case:
		adsr := [4]f32{pad.attack, v.decay, v.sustain, pad.release}
		ui.adsr_plot("view amp env", &adsr, size, color, f32(live.amp) if live.sounding else -1, secs)
	}
	_ = pm.Pad_Kind.Sampler
}
