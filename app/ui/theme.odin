package ui

import im "deps:imgui"

// A colour, as linear 0..1 RGBA.
Color :: [4]f32

// A theme's design tokens: every colour and size the UI draws with comes
// from here, so a theme is one value and switching is one call
// (`theme_apply`). Sizes are in logical points.
Theme :: struct {
	name:        string,
	// Surfaces, from the back.
	bg:          Color, // window background
	surface:     Color, // panels, cards
	raised:      Color, // controls at rest (frames, buttons)
	hover:       Color, // controls under the mouse
	pressed:     Color,
	border:      Color, // hairlines between areas
	// Content.
	text:        Color,
	text_dim:    Color, // secondary text, disabled
	accent:      Color, // the one strong colour: selection, focus, active
	accent_text: Color, // text on the accent
	// Signals.
	ok, warn, danger: Color,
	// Shape.
	radius:      f32, // controls
	radius_big:  f32, // windows and popups
	pad:         im.Vec2, // inside controls
	gap:         im.Vec2, // between controls
	window_pad:  im.Vec2,
	border_size: f32, // around controls; 0 = flat: told apart by colour, not lines
	window_border: f32, // around windows and panels
}

// The default theme: dark, flat, a single blue accent.
theme_dark :: proc() -> Theme {
	return {
		name        = "Dark",
		bg          = rgb(0x17181c),
		surface     = rgb(0x1f2026),
		raised      = rgb(0x2a2c33),
		hover       = rgb(0x34363f),
		pressed     = rgb(0x3e414b),
		border      = rgb(0x2c2e35),
		text        = rgb(0xe8e9ed),
		text_dim    = rgb(0x8b8e99),
		accent      = rgb(0x4f8cff),
		accent_text = rgb(0xffffff),
		ok          = rgb(0x3ccf7a),
		warn        = rgb(0xf2b33d),
		danger      = rgb(0xf0555a),
		radius      = 6,
		radius_big  = 10,
		pad         = {10, 6},
		gap         = {8, 8},
		window_pad  = {14, 12},
		border_size = 0,
		window_border = 0,
	}
}

// The light variant of the default theme.
theme_light :: proc() -> Theme {
	t := theme_dark()
	t.name = "Light"
	t.bg = rgb(0xf4f5f7)
	t.surface = rgb(0xffffff)
	t.raised = rgb(0xe3e6eb)
	t.hover = rgb(0xd8dce3)
	t.pressed = rgb(0xccd1d9)
	t.border = rgb(0xd6dae1)
	t.text = rgb(0x1d1f24)
	t.text_dim = rgb(0x6b6f7a)
	t.accent = rgb(0x2f6fe8)
	t.window_border = 1 // white panels on a near-white background need a hairline
	return t
}

// Makes `t` the current ImGui style, its sizes scaled by `scale` (logical
// points to ImGui units: 1 where the OS scales for us, as on macOS).
theme_apply :: proc(t: Theme, scale: f32 = 1) {
	s := im.GetStyle()
	s.WindowPadding = t.window_pad
	s.FramePadding = t.pad
	s.ItemSpacing = t.gap
	s.ItemInnerSpacing = {t.gap.x * 0.75, t.gap.y * 0.75}
	s.CellPadding = {t.pad.x * 0.6, t.pad.y * 0.6}
	s.IndentSpacing = 18
	s.ScrollbarSize = 12
	s.GrabMinSize = 10
	s.WindowRounding = t.radius_big
	s.ChildRounding = t.radius
	s.PopupRounding = t.radius
	s.FrameRounding = t.radius
	s.ScrollbarRounding = 12
	s.GrabRounding = t.radius
	s.TabRounding = t.radius
	s.WindowBorderSize = t.window_border
	s.ChildBorderSize = t.window_border
	s.PopupBorderSize = 1
	s.FrameBorderSize = t.border_size
	s.TabBorderSize = 0
	s.TabBarBorderSize = 1
	s.TabBarOverlineSize = 0
	s.WindowTitleAlign = {0, 0.5}
	s.WindowMenuButtonPosition = .None
	s.SeparatorTextBorderSize = 1
	s.DockingSeparatorSize = 2

	c := s
	set :: proc(s: ^im.Style, col: im.Col, v: Color) { s.Colors[int(col)] = transmute(im.Vec4)v }
	set(c, .Text, t.text)
	set(c, .TextDisabled, t.text_dim)
	set(c, .WindowBg, t.surface)
	set(c, .ChildBg, {0, 0, 0, 0})
	set(c, .PopupBg, t.surface)
	set(c, .Border, t.border)
	set(c, .BorderShadow, {0, 0, 0, 0})
	set(c, .FrameBg, t.raised)
	set(c, .FrameBgHovered, t.hover)
	set(c, .FrameBgActive, t.pressed)
	set(c, .TitleBg, t.surface)
	set(c, .TitleBgActive, t.surface)
	set(c, .TitleBgCollapsed, t.surface)
	set(c, .MenuBarBg, t.surface)
	set(c, .ScrollbarBg, {0, 0, 0, 0})
	set(c, .ScrollbarGrab, t.raised)
	set(c, .ScrollbarGrabHovered, t.hover)
	set(c, .ScrollbarGrabActive, t.pressed)
	set(c, .CheckMark, t.accent_text)
	set(c, .CheckboxSelectedBg, t.accent)
	set(c, .SliderGrab, t.accent)
	set(c, .SliderGrabActive, lighten(t.accent, 0.12))
	set(c, .Button, t.raised)
	set(c, .ButtonHovered, t.hover)
	set(c, .ButtonActive, t.pressed)
	set(c, .Header, t.raised)
	set(c, .HeaderHovered, t.hover)
	set(c, .HeaderActive, t.pressed)
	set(c, .Separator, t.border)
	set(c, .SeparatorHovered, t.accent)
	set(c, .SeparatorActive, t.accent)
	set(c, .ResizeGrip, {0, 0, 0, 0})
	set(c, .ResizeGripHovered, with_alpha(t.accent, 0.5))
	set(c, .ResizeGripActive, t.accent)
	set(c, .InputTextCursor, t.text)
	set(c, .Tab, t.surface)
	set(c, .TabHovered, t.hover)
	set(c, .TabSelected, t.raised)
	set(c, .TabSelectedOverline, t.accent)
	set(c, .TabDimmed, t.surface)
	set(c, .TabDimmedSelected, t.raised)
	set(c, .TabDimmedSelectedOverline, {0, 0, 0, 0})
	set(c, .DockingPreview, with_alpha(t.accent, 0.4))
	set(c, .DockingEmptyBg, t.bg)
	set(c, .PlotLines, t.accent)
	set(c, .PlotLinesHovered, lighten(t.accent, 0.12))
	set(c, .PlotHistogram, t.accent)
	set(c, .PlotHistogramHovered, lighten(t.accent, 0.12))
	set(c, .TableHeaderBg, t.raised)
	set(c, .TableBorderStrong, t.border)
	set(c, .TableBorderLight, t.border)
	set(c, .TableRowBg, {0, 0, 0, 0})
	set(c, .TableRowBgAlt, with_alpha(t.text, 0.03))
	set(c, .TextLink, t.accent)
	set(c, .TextSelectedBg, with_alpha(t.accent, 0.35))
	set(c, .TreeLines, t.border)
	set(c, .DragDropTarget, t.accent)
	set(c, .DragDropTargetBg, with_alpha(t.accent, 0.12))
	set(c, .UnsavedMarker, t.warn)
	set(c, .NavCursor, t.accent)
	set(c, .NavWindowingHighlight, t.accent)
	set(c, .NavWindowingDimBg, {0, 0, 0, 0.4})
	set(c, .ModalWindowDimBg, {0, 0, 0, 0.5})

	if scale != 1 {
		im.Style_ScaleAllSizes(s, scale)
		s.FontScaleDpi = scale
	}
}

// ImGui's vector type for colours.
Vec4 :: im.Vec4

// `0xRRGGBB` as an opaque colour.
rgb :: proc "contextless" (hex: u32) -> Color {
	return {f32((hex >> 16) & 0xff) / 255, f32((hex >> 8) & 0xff) / 255, f32(hex & 0xff) / 255, 1}
}

// `c` with alpha `a`.
with_alpha :: proc "contextless" (c: Color, a: f32) -> Color {
	return {c.r, c.g, c.b, a}
}

// `c` moved `amount` (0..1) towards white.
lighten :: proc "contextless" (c: Color, amount: f32) -> Color {
	return {c.r + (1 - c.r) * amount, c.g + (1 - c.g) * amount, c.b + (1 - c.b) * amount, c.a}
}
