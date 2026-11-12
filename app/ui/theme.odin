package ui

import "core:math"

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
	inset:       Color, // the main content (the panels in the middle): a shade under `surface`, set apart
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
	control_h:   f32, // a control's height in points (0: the font's height plus `pad.y` twice); `set_density` sets it
}

// How large controls are: a control's height is `DENSITY_HEIGHT` of it.
// Compact suits a mouse on a small screen; Touch, a finger.
Density :: enum u8 {
	Compact,
	Comfortable,
	Touch,
}

// A control's height, in points, at each density.
DENSITY_HEIGHT := [Density]f32{.Compact = 28, .Comfortable = 34, .Touch = 44}

// The sizes text comes in: headings (a panel's or a device's title), body
// (names, lists, values read), labels (under knobs, in dense rows) and
// captions (units, hints).
Text_Size :: enum u8 {
	Heading,
	Body,
	Label,
	Caption,
}

// Each text size in points.
TEXT_SIZE := [Text_Size]f32{.Heading = 18, .Body = 15, .Label = 13, .Caption = 11}

// Draws what follows at text size `size` (in the current font); pair with
// `text_pop`.
text_push :: proc(size: Text_Size) {
	im.PushFontFloat(nil, TEXT_SIZE[size])
}

// Ends a `text_push`.
text_pop :: proc() {
	im.PopFont()
}

// The default theme: dark, flat, a single blue accent.
theme_dark :: proc() -> Theme {
	return {
		name        = "Dark",
		bg          = rgb(0x17181c),
		surface     = rgb(0x1f2026),
		inset       = rgb(0x1a1b20),
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
	t.inset = rgb(0xedeff3)
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

// A dark theme with a blue cast and a violet accent.
theme_midnight :: proc() -> Theme {
	t := theme_dark()
	t.name = "Midnight"
	t.bg = rgb(0x0f1220)
	t.surface = rgb(0x161a2c)
	t.inset = rgb(0x121527)
	t.raised = rgb(0x21263d)
	t.hover = rgb(0x2a304b)
	t.pressed = rgb(0x343b5a)
	t.border = rgb(0x262b44)
	t.text = rgb(0xe4e6f2)
	t.text_dim = rgb(0x8a8fae)
	t.accent = rgb(0x8b7cff)
	return t
}

// A neutral grey dark theme with an orange accent.
theme_graphite :: proc() -> Theme {
	t := theme_dark()
	t.name = "Graphite"
	t.bg = rgb(0x1b1b1b)
	t.surface = rgb(0x242424)
	t.inset = rgb(0x1f1f1f)
	t.raised = rgb(0x303030)
	t.hover = rgb(0x3a3a3a)
	t.pressed = rgb(0x444444)
	t.border = rgb(0x333333)
	t.text = rgb(0xebebeb)
	t.text_dim = rgb(0x949494)
	t.accent = rgb(0xff8a3d)
	t.accent_text = rgb(0x1b1b1b)
	return t
}

// A warm light theme, like paper, with a teal accent.
theme_paper :: proc() -> Theme {
	t := theme_light()
	t.name = "Paper"
	t.bg = rgb(0xf3efe7)
	t.surface = rgb(0xfbf8f2)
	t.inset = rgb(0xefe9df)
	t.raised = rgb(0xe6dfd2)
	t.hover = rgb(0xdcd4c5)
	t.pressed = rgb(0xd1c8b7)
	t.border = rgb(0xdbd2c3)
	t.text = rgb(0x2b2620)
	t.text_dim = rgb(0x7a7166)
	t.accent = rgb(0x1f8a83)
	return t
}

// The themes the app comes with, by name.
theme_presets :: proc() -> [5]Theme {
	return {theme_dark(), theme_light(), theme_midnight(), theme_graphite(), theme_paper()}
}

// A colour of a theme, by name: for settings files and editors.
Theme_Color :: struct {
	name:  string,
	color: ^Color,
}

// The colours of `t` that make it up, by name (pointers into `t`).
theme_colors :: proc(t: ^Theme) -> [14]Theme_Color {
	return {
		{"bg", &t.bg}, {"surface", &t.surface}, {"inset", &t.inset}, {"raised", &t.raised},
		{"hover", &t.hover}, {"pressed", &t.pressed}, {"border", &t.border}, {"text", &t.text},
		{"text_dim", &t.text_dim}, {"accent", &t.accent}, {"accent_text", &t.accent_text},
		{"ok", &t.ok}, {"warn", &t.warn}, {"danger", &t.danger},
	}
}

// Whether `t` is a dark theme (light text on a dark background).
theme_is_dark :: proc(t: Theme) -> bool {
	return 0.3 * t.bg.r + 0.59 * t.bg.g + 0.11 * t.bg.b < 0.5
}

// Makes `t` the current ImGui style, its sizes scaled by `scale` (logical
// points to ImGui units: 1 where the OS scales for us, as on macOS).
theme_apply :: proc(t: Theme, scale: f32 = 1) {
	s := im.GetStyle()
	s.WindowPadding = t.window_pad
	s.FramePadding = t.pad
	if t.control_h > 0 do s.FramePadding.y = max((t.control_h - FONT_SIZE) / 2, 2)
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
	s.DockingNodeHasCloseButton = false // each tab has its own

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
	set(c, .Button, t.raised)
	set(c, .ButtonHovered, t.hover)
	set(c, .ButtonActive, t.pressed)
	set(c, .Header, t.raised)
	set(c, .HeaderHovered, t.hover)
	set(c, .HeaderActive, t.pressed)
	set(c, .Separator, t.border)
	set(c, .ResizeGrip, {0, 0, 0, 0})
	set(c, .InputTextCursor, t.text)
	set(c, .Tab, t.surface)
	set(c, .TabHovered, t.hover)
	set(c, .TabSelected, t.raised)
	set(c, .TabDimmed, t.surface)
	set(c, .TabDimmedSelected, t.raised)
	set(c, .TabDimmedSelectedOverline, {0, 0, 0, 0})
	set(c, .DockingEmptyBg, t.bg)
	set(c, .TableHeaderBg, t.raised)
	set(c, .TableBorderStrong, t.border)
	set(c, .TableBorderLight, t.border)
	set(c, .TableRowBg, {0, 0, 0, 0})
	set(c, .TableRowBgAlt, with_alpha(t.text, 0.03))
	set(c, .TreeLines, t.border)
	set(c, .UnsavedMarker, t.warn)
	set(c, .NavWindowingDimBg, {0, 0, 0, 0.4})
	set(c, .ModalWindowDimBg, {0, 0, 0, 0.5})
	theme_apply_accent(t)

	if scale != 1 {
		im.Style_ScaleAllSizes(s, scale)
		s.FontScaleDpi = scale
	}
}

// Sets the ImGui colours drawn in the accent from `t.accent` (and
// `accent_text`): what `set_accent` changes, every frame if need be.
@(private)
theme_apply_accent :: proc(t: Theme) {
	c := im.GetStyle()
	set :: proc(s: ^im.Style, col: im.Col, v: Color) { s.Colors[int(col)] = transmute(im.Vec4)v }
	set(c, .CheckMark, t.accent_text)
	set(c, .CheckboxSelectedBg, t.accent)
	set(c, .SliderGrab, t.accent)
	set(c, .SliderGrabActive, lighten(t.accent, 0.12))
	set(c, .SeparatorHovered, t.accent)
	set(c, .SeparatorActive, t.accent)
	set(c, .ResizeGripHovered, with_alpha(t.accent, 0.5))
	set(c, .ResizeGripActive, t.accent)
	set(c, .TabSelectedOverline, t.accent)
	set(c, .DockingPreview, with_alpha(t.accent, 0.4))
	set(c, .PlotLines, t.accent)
	set(c, .PlotLinesHovered, lighten(t.accent, 0.12))
	set(c, .PlotHistogram, t.accent)
	set(c, .PlotHistogramHovered, lighten(t.accent, 0.12))
	set(c, .TextLink, t.accent)
	set(c, .TextSelectedBg, with_alpha(t.accent, 0.35))
	set(c, .DragDropTarget, t.accent)
	set(c, .DragDropTargetBg, with_alpha(t.accent, 0.12))
	set(c, .NavCursor, t.accent)
	set(c, .NavWindowingHighlight, t.accent)
}

// How much brighter the lighter of `a` and `b` is (WCAG's contrast ratio,
// 1 to 21).
contrast :: proc "contextless" (a, b: Color) -> f32 {
	la, lb := luminance(a), luminance(b)
	return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
}

// `c`'s relative luminance (0 black to 1 white), as WCAG defines it.
luminance :: proc "contextless" (c: Color) -> f32 {
	lin :: proc "contextless" (v: f32) -> f32 {
		return v / 12.92 if v <= 0.04045 else math.pow((v + 0.055) / 1.055, 2.4)
	}
	return 0.2126 * lin(c.r) + 0.7152 * lin(c.g) + 0.0722 * lin(c.b)
}

// `c` made usable as the accent on `surface`: moved towards white (on a
// dark surface) or black (on a light one) until it stands out from it by
// a contrast of 3 (its hue kept); and the text that reads on it, white or
// near-black.
accent_for :: proc "contextless" (c, surface: Color) -> (accent, text: Color) {
	accent = {c.r, c.g, c.b, 1}
	dark := luminance(surface) < 0.5
	for _ in 0 ..< 20 {
		if contrast(accent, surface) >= 3 do break
		accent = lighten(accent, 0.1) if dark else darken(accent, 0.1)
	}
	white, ink := Color{1, 1, 1, 1}, rgb(0x15161a)
	text = white if contrast(white, accent) >= contrast(ink, accent) else ink
	return
}

// `c` moved `amount` (0..1) towards black.
darken :: proc "contextless" (c: Color, amount: f32) -> Color {
	return {c.r * (1 - amount), c.g * (1 - amount), c.b * (1 - amount), c.a}
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
