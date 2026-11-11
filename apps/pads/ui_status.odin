package pads

import "core:fmt"
import "core:time"

import app "app:core"
import "app:ui"
import pm "model"
import im "deps:imgui"
import sdl "deps:sdl3"

// The status bar along the bottom of the window: the audio engine (its
// device, rate and buffer, running or not, dropouts), how hard it works,
// MIDI coming in and going out, the track selected, and the newest
// message (click it for the recent ones).

// How tall the status bar is.
STATUS_H :: 26

// The status bar's state.
Status_State :: struct {
	sent, received: u64, // MIDI counts last frame
	in_lit, out_lit: f32, // seconds the lights stay on
	load: f32, // the engine's load, smoothed for reading
}

draw_statusbar :: proc(user: rawptr) {
	a := (^App)(user)
	st := &a.status
	t := ui.theme()
	h := &a.host
	dl := im.GetWindowDrawList()
	im.SetCursorPosY(max((STATUS_H - im.GetFrameHeight()) / 2, 0))
	dot :: proc(c: ui.Color) {
		dl := im.GetWindowDrawList()
		pos := im.GetCursorScreenPos()
		hh := im.GetFrameHeight()
		im.DrawList_AddCircleFilled(dl, {pos.x + 5, pos.y + hh / 2}, 4, ui.col(c))
		im.Dummy({12, hh})
		im.SameLine(0, 4)
	}
	text :: proc(s: string, dim := true) {
		im.AlignTextToFramePadding()
		if dim do im.TextDisabled("%s", fmt.ctprintf("%s", s))
		else do im.TextUnformatted(fmt.ctprintf("%s", s))
	}
	// The engine.
	f := h.format
	state := "Running" if h.running else ("Device lost" if h.lost else "Stopped")
	dot(t.ok if h.running else t.danger)
	device := "System default"
	if h.settings.fake do device = "Simulated device"
	else if id := h.settings.output_device; id != "" {
		device = id
		for d in a.settings.devices do if d.id == id do device = d.name
	}
	text(fmt.tprintf("%s · %s · %.1f kHz · %d frames", state, device, f.sample_rate / 1000, f.buffer_frames), false)
	ui.name("status engine")
	if im.IsItemHovered() do im.SetTooltip("The audio engine (Settings > Audio to change it)")
	if im.IsItemClicked() do a.settings.open, a.settings.page = true, .Audio
	// Its load: a small bar, warmer as it fills.
	im.SameLine(0, 16)
	st.load += (app.host_load(h) - st.load) * 0.1
	{
		pos := im.GetCursorScreenPos()
		w: f32 = 54
		bh := im.GetFrameHeight() * 0.42
		y := pos.y + (im.GetFrameHeight() - bh) / 2
		fill := clamp(st.load, 0, 1)
		c := t.ok if st.load < 0.6 else (t.warn if st.load < 0.9 else t.danger)
		im.DrawList_AddRectFilled(dl, {pos.x, y}, {pos.x + w, y + bh}, ui.col(t.raised), 3)
		im.DrawList_AddRectFilled(dl, {pos.x, y}, {pos.x + w * fill, y + bh}, ui.col(c), 3)
		im.Dummy({w, im.GetFrameHeight()})
		ui.name("status load")
		if im.IsItemHovered() do im.SetTooltip("How much of each audio callback's time the engine takes")
		im.SameLine(0, 6)
		text(fmt.tprintf("CPU %.0f%%", st.load * 100))
	}
	// Delay compensation: how far the output lags (plug-ins' latency).
	if lat := pm.total_latency(&a.m.engine); lat > 0 {
		im.SameLine(0, 12)
		text(fmt.tprintf("PDC %.1f ms", f64(lat) * 1000 / max(f.sample_rate, 1)))
		ui.name("status latency")
		if im.IsItemHovered() do im.SetTooltip("%s", fmt.ctprintf("The effects' latency, made up so every track lines up: %d frames", lat))
	}
	if h.xruns > 0 {
		im.SameLine(0, 12)
		im.AlignTextToFramePadding()
		im.TextColored(transmute(im.Vec4)t.warn, "%s", fmt.ctprintf("%d dropout%s", h.xruns, "" if h.xruns == 1 else "s"))
	}
	// MIDI.
	sent, received := app.host_midi_counts(h)
	dt := im.GetIO().DeltaTime
	st.in_lit = 0.15 if received != st.received else max(st.in_lit - dt, 0)
	st.out_lit = 0.15 if sent != st.sent else max(st.out_lit - dt, 0)
	st.sent, st.received = sent, received
	im.SameLine(0, 18)
	dot(t.ok if st.in_lit > 0 else ui.mix(t.raised, t.text, 0.2))
	text("MIDI in")
	im.SameLine(0, 10)
	dot(t.accent if st.out_lit > 0 else ui.mix(t.raised, t.text, 0.2))
	text("out")
	// The track selected.
	im.SameLine(0, 18)
	i := a.selected
	pad := &a.m.project.pads[i]
	name := pm.pad_name(pad) if pm.pad_used(&a.m.project, i) else ""
	sw := ui.rgb(pad.color)
	dot(sw)
	text(fmt.tprintf("%s%s%s · %s", pm.pad_label(i), " " if name != "" else "", name, pad_device_name(pad.kind) if pm.pad_used(&a.m.project, i) else "empty"), false)
	ui.name("status track")
	if im.IsItemHovered() do im.SetTooltip("The track selected (arrow keys: the pads around it)")
	// The newest message, at the right; click for the recent ones.
	log := a.ws.toasts.log[:]
	if len(log) > 0 {
		e := log[len(log) - 1]
		msg := fmt.tprintf("%s  %s", ago(e.at), e.text)
		mw := im.CalcTextSize(fmt.ctprintf("%s", msg)).x + 20
		im.SameLine(max(im.GetWindowWidth() - mw - 10, im.GetCursorPosX() + 20))
		c := t.danger if e.kind == .Error else (t.warn if e.kind == .Warning else t.text_dim)
		im.AlignTextToFramePadding()
		im.TextColored(transmute(im.Vec4)c, "%s", fmt.ctprintf("%s", msg))
		ui.name("status message")
		if im.IsItemHovered() do im.SetTooltip("Click for the recent messages")
		if im.IsItemClicked() do im.OpenPopup("##log")
		if im.BeginPopup("##log") {
			im.TextDisabled("Messages")
			if a.ws.toasts.log_path != "" {
				im.SameLine()
				if im.SmallButton("Open the log file") do _ = sdl.OpenURL(fmt.ctprintf("file://%s", a.ws.toasts.log_path))
			}
			im.Separator()
			for k := len(log) - 1; k >= max(len(log) - 30, 0); k -= 1 {
				x := log[k]
				kc := t.danger if x.kind == .Error else (t.warn if x.kind == .Warning else t.text)
				im.TextColored(transmute(im.Vec4)kc, "%s", fmt.ctprintf("%s  %s", ago(x.at), x.text))
			}
			im.EndPopup()
		}
	}
}

// How long ago `at` was, briefly ("now", "12 s", "4 min", "2 h").
@(private = "file")
ago :: proc(at: time.Time) -> string {
	d := time.duration_seconds(time.since(at))
	switch {
	case d < 5:    return "now"
	case d < 60:   return fmt.tprintf("%.0f s", d)
	case d < 3600: return fmt.tprintf("%.0f min", d / 60)
	}
	return fmt.tprintf("%.0f h", d / 3600)
}
