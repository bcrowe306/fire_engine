package pads

import "core:fmt"

import "app:ui"
import im "deps:imgui"

// The tabs beside the pads in the bottom panel: what the selected pad is.
Detail_Tab :: enum u8 {
	Sample,
	Pad,
	Effects,
	Perform,
}

// The bottom panel's state: its tab, and how wide the pads are.
Detail_State :: struct {
	tab:        Detail_Tab,
	show:       int, // frames left to bring `tab` to the front (0: the user's choice stands)
	pads_width: f32, // 0: as wide as the pads are tall
}

DETAIL_NAMES := [Detail_Tab]string{.Sample = "Sample", .Pad = "Pad", .Effects = "Effects", .Perform = "Perform"}
DETAIL_ICONS := [Detail_Tab]string{.Sample = ui.ICON_AUDIO_WAVEFORM, .Pad = ui.ICON_SLIDERS_HORIZONTAL, .Effects = ui.ICON_WAND_SPARKLES, .Perform = ui.ICON_KEYBOARD_MUSIC}

// Width of the divider between the pads and the tabs.
@(private) DIVIDER :: 9

// Brings tab `tab` of the bottom panel to the front (and the panel).
show_detail :: proc(a: ^App, tab: Detail_Tab) {
	a.detail.tab, a.detail.show = tab, 2
	ui.panel_focus(&a.ws, "detail")
}

// The bottom panel, as Ableton's detail view: the pad grid on the left,
// the selected pad on the right in tabs (its sample, its settings, its
// effects, how it plays). The divider between them drags.
draw_detail :: proc(user: rawptr) {
	a := (^App)(user)
	st := &a.detail
	t := ui.theme()
	avail := im.GetContentRegionAvail()
	// The pads: a square grid as tall as the panel, unless dragged wider or narrower.
	header := im.GetFrameHeight() + im.GetStyle().ItemSpacing.y * 2
	auto := avail.y - header + 24
	w := st.pads_width if st.pads_width > 0 else auto
	w = clamp(w, 260, max(avail.x * 0.6, 260))
	if im.BeginChild("##pads", {w, avail.y}, {}, {.NoScrollbar, .NoScrollWithMouse}) do draw_pads(a)
	im.EndChild()

	// The divider.
	im.SameLine(0, 0)
	pos := im.GetCursorScreenPos()
	im.InvisibleButton("##divider", {DIVIDER, avail.y})
	hot := im.IsItemHovered() || im.IsItemActive()
	if hot do im.SetMouseCursor(.ResizeEW)
	if im.IsItemActive() do st.pads_width = w + im.GetIO().MouseDelta.x
	if im.IsItemHovered() && im.IsMouseDoubleClicked(.Left) do st.pads_width = 0
	dl := im.GetWindowDrawList()
	x := pos.x + DIVIDER / 2
	im.DrawList_AddLine(dl, {x, pos.y + 4}, {x, pos.y + avail.y - 4}, ui.col(t.accent if hot else t.border), 2 if hot else 1)

	// The selected pad's tabs.
	im.SameLine(0, 0)
	im.PushStyleVarVec2(.WindowPadding, {im.GetStyle().WindowPadding.x, 0})
	if im.BeginChild("##detail", {0, avail.y}, {.AlwaysUseWindowPadding}) {
		if im.BeginTabBar("##detail_tabs") {
			for tab in Detail_Tab {
				flags: im.TabItemFlags
				if st.show > 0 && st.tab == tab do flags += {.SetSelected}
				label := fmt.ctprintf("%s  %s###%s", DETAIL_ICONS[tab], DETAIL_NAMES[tab], DETAIL_NAMES[tab])
				if im.BeginTabItem(label, nil, flags) {
					if st.show == 0 do st.tab = tab
					if im.BeginChild("##tab", {0, 0}) {
						switch tab {
						case .Sample:  draw_sample(a)
						case .Pad:     draw_inspector(a)
						case .Effects: draw_effect(a)
						case .Perform: draw_perform(a)
						}
					}
					im.EndChild()
					im.EndTabItem()
				}
			}
			im.EndTabBar()
		}
	}
	im.EndChild()
	im.PopStyleVar()
	if st.show > 0 do st.show -= 1
}
