package test_app_core

import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"

import app "app:core"

// An INI file read, changed and written: values typed and quoted where
// they need it, sections and keys added at the end, and a person's
// comments (and lines it can't read) kept where they were.
@(test)
ini_round_trip_keeps_comments :: proc(t: ^testing.T) {
	text := `# Pads settings
[audio]
# the card
output = Studio Card
rate = 48000

; look
[appearance]
zoom = 1.25
dark = yes
name = "  spaced  "
what is this
`
	ini := app.ini_parse(text)
	defer app.ini_destroy(&ini)
	testing.expect_value(t, app.ini_int(&ini, "audio", "rate", 0), 48000)
	testing.expect_value(t, app.ini_f64(&ini, "appearance", "zoom", 1), 1.25)
	testing.expect_value(t, app.ini_bool(&ini, "appearance", "dark", false), true)
	v, _ := app.ini_get(&ini, "appearance", "name")
	testing.expect_value(t, v, "  spaced  ")
	testing.expect_value(t, app.ini_int(&ini, "audio", "missing", 7), 7)
	app.ini_set_int(&ini, "audio", "buffer", 256)
	app.ini_set_bool(&ini, "midi", "clock_out", true)
	app.ini_set(&ini, "audio", "output", "Other # Card")
	out := app.ini_text(&ini, context.temp_allocator)
	for want in ([]string{"# Pads settings\n[audio]", "# the card\noutput = \"Other # Card\"", "buffer = 256", "; look\n[appearance]", "name = \"  spaced  \"", "# what is this", "[midi]\nclock_out = true"}) {
		testing.expectf(t, strings.contains(out, want), "has %q in:\n%s", want, out)
	}
	// Read back: the same values.
	again := app.ini_parse(out)
	defer app.ini_destroy(&again)
	v2, _ := app.ini_get(&again, "audio", "output")
	testing.expect_value(t, v2, "Other # Card")
	testing.expect_value(t, app.ini_bool(&again, "midi", "clock_out", false), true)
	app.ini_remove(&again, "audio", "buffer")
	testing.expect_value(t, app.ini_int(&again, "audio", "buffer", -1), -1)
}

// Saved whole (through a temporary file) and loaded; a missing file loads
// empty; the user's folder is where the platform keeps settings.
@(test)
ini_save_and_load :: proc(t: ^testing.T) {
	dir, _ := os.make_directory_temp("", "ini_test", context.temp_allocator)
	defer os.remove_all(dir)
	path, _ := filepath.join({dir, "sub", "settings.ini"}, context.temp_allocator)
	empty, ok := app.ini_load(path)
	testing.expect(t, ok && len(empty.sections) == 0, "no file: empty")
	app.ini_destroy(&empty)
	ini: app.Ini
	app.ini_set_f64(&ini, "audio", "rate", 44100)
	testing.expect(t, app.ini_save(&ini, path), "saved")
	app.ini_destroy(&ini)
	testing.expect(t, !os.exists(strings.concatenate({path, ".tmp"}, context.temp_allocator)), "no temporary left")
	back, ok2 := app.ini_load(path)
	defer app.ini_destroy(&back)
	testing.expect(t, ok2 && app.ini_f64(&back, "audio", "rate", 0) == 44100, "loaded")
	folder := app.user_config_folder("Pads", context.temp_allocator)
	when ODIN_OS == .Darwin do testing.expectf(t, strings.has_suffix(folder, "Library/Application Support/Pads"), "%s", folder)
	when ODIN_OS == .Linux do testing.expectf(t, strings.has_suffix(folder, "pads"), "%s", folder)
	when ODIN_OS == .Windows do testing.expectf(t, strings.has_suffix(folder, "Pads"), "%s", folder)
	p, portable := app.settings_file_path("Pads", "settings.ini", context.temp_allocator)
	testing.expect(t, !portable && strings.has_prefix(p, folder), "not portable: the user's folder")
}
