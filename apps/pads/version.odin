package pads

import "core:fmt"

import "app:ui"
import im "deps:imgui"

// Pads' version, and the commit and date it was built from (given by the
// build: -define:PADS_COMMIT=... -define:PADS_DATE=...).
PADS_VERSION :: "0.1.0-dev"
PADS_COMMIT :: #config(PADS_COMMIT, "unknown")
PADS_DATE :: #config(PADS_DATE, "")

// The version as one line: "0.1.0-dev (ab12cd3, 2026-11-11)".
version_text :: proc() -> string {
	if PADS_DATE != "" do return fmt.tprintf("%s (%s, %s)", PADS_VERSION, PADS_COMMIT, PADS_DATE)
	return fmt.tprintf("%s (%s)", PADS_VERSION, PADS_COMMIT)
}

// The About box's state.
About_State :: struct {
	open: bool,
}

// The About box: what Pads is, its version and commit, and the licences
// of what it is built from.
draw_about :: proc(a: ^App) {
	if a.about.open {
		im.OpenPopup("About Pads")
		a.about.open = false
	}
	im.SetNextWindowSize({460, 0}, .Appearing)
	if !im.BeginPopupModal("About Pads", nil, {.AlwaysAutoResize, .NoSavedSettings}) do return
	defer im.EndPopup()
	f := a.platform.fonts
	im.PushFontFloat(f.bold, 22)
	im.Text("Pads")
	im.PopFont()
	im.Text("%s", fmt.ctprintf("Version %s", PADS_VERSION))
	im.TextDisabled("%s", fmt.ctprintf("Built from %s%s", PADS_COMMIT, fmt.tprintf(", %s", PADS_DATE) if PADS_DATE != "" else ""))
	im.Spacing()
	im.TextWrapped("A pad sampler, sequencer and song arranger on the Fire Engine audio engine. A development release: things will change, and some will break.")
	im.Spacing()
	im.SeparatorText("Licences")
	im.TextWrapped("Pads is free software under the GNU General Public License, version 3 or later. The Fire Engine and its app layer are MIT. Built with SDL3 (zlib), Dear ImGui (MIT), the CLAP headers (MIT), the Open Sans (OFL) and Lucide (ISC) fonts and, when present, Ableton Link (GPL-2.0-or-later). Their licences are in the package's LICENSES folder.")
	im.Spacing()
	if im.Button("Copy version") do im.SetClipboardText(fmt.ctprintf("Pads %s", version_text()))
	ui.name("copy version")
	im.SameLine()
	if im.Button("Close") || im.IsKeyPressed(.Escape) do im.CloseCurrentPopup()
	ui.name("about close")
}
