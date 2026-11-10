package ui

import im "deps:imgui"

// Open Sans, embedded in the binary (SIL Open Font License; see
// vendor/fonts/OpenSans/OFL.txt).
@(private) OPEN_SANS_REGULAR := #load("../../vendor/fonts/OpenSans/OpenSans-Regular.ttf")
@(private) OPEN_SANS_SEMIBOLD := #load("../../vendor/fonts/OpenSans/OpenSans-SemiBold.ttf")
@(private) OPEN_SANS_BOLD := #load("../../vendor/fonts/OpenSans/OpenSans-Bold.ttf")

// The fonts the theme uses. Sizes are chosen per use with `im.PushFont(f,
// size)`: ImGui (1.92+) renders any size of a loaded font on demand.
Fonts :: struct {
	regular:  ^im.Font, // body text, the default font
	semibold: ^im.Font, // labels, buttons, headings
	bold:     ^im.Font, // titles and big numbers
}

// Base text size in logical points.
FONT_SIZE :: 15

@(private)
fonts_load :: proc(f: ^Fonts) {
	io := im.GetIO()
	add :: proc(atlas: ^im.FontAtlas, data: []u8) -> ^im.Font {
		cfg: im.FontConfig
		// ImFontConfig's C++ defaults (the bindings have no constructor).
		cfg.FontDataOwnedByAtlas = false // the data lives in the binary
		cfg.OversampleH, cfg.OversampleV = 2, 1
		cfg.GlyphMaxAdvanceX = max(f32)
		cfg.RasterizerMultiply = 1
		cfg.RasterizerDensity = 1
		cfg.ExtraSizeScale = 1
		return im.FontAtlas_AddFontFromMemoryTTF(atlas, raw_data(data), i32(len(data)), FONT_SIZE, &cfg, nil)
	}
	f.regular = add(io.Fonts, OPEN_SANS_REGULAR)
	f.semibold = add(io.Fonts, OPEN_SANS_SEMIBOLD)
	f.bold = add(io.Fonts, OPEN_SANS_BOLD)
	io.FontDefault = f.regular
}
