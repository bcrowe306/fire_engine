package test_app_ui

import "core:image/png"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"

import "app:ui"
import kit "fire:testkit"

// Windowed UI tests run as a program on the main thread (macOS allows
// windows nowhere else): see apps/ui_tests. These need no window.

shot_dir :: proc(name: string) -> string {
	dir, _ := filepath.join({kit.artifacts_root(), "app_ui", name}, context.temp_allocator)
	return dir
}

// What the PNG writer writes, Odin's PNG reader reads back unchanged.
@(test)
png_round_trips :: proc(t: ^testing.T) {
	w, h := 7, 3
	pixels := make([]u8, w * h * 4, context.temp_allocator)
	for &b, i in pixels do b = u8(i * 13)
	dir := shot_dir("png")
	os.make_directory_all(dir)
	path, _ := filepath.join({dir, "tiny.png"}, context.temp_allocator)
	testing.expect(t, ui.png_write(path, pixels, w, h) == nil)
	data, _ := os.read_entire_file(path, context.temp_allocator)
	img, err := png.load_from_bytes(data)
	testing.expect_value(t, err, nil)
	if err == nil {
		defer png.destroy(img)
		testing.expect_value(t, img.width, w)
		testing.expect_value(t, img.height, h)
		testing.expect_value(t, img.channels, 4)
		got := img.pixels.buf[:]
		same := len(got) == len(pixels)
		for b, i in pixels do same &&= i < len(got) && got[i] == b
		testing.expect(t, same, "same pixels")
	}
}

// What a person is told when the window can't open: nothing when nothing
// failed; with no GPU driver, what's wrong, what fixes it, and SDL's words.
@(test)
a_failed_platform_says_why :: proc(t: ^testing.T) {
	p: ui.Platform
	testing.expect_value(t, ui.platform_failure_text(&p, "Pads"), "")
	p.failed = .Gpu
	copy(p.failed_why[:], "SDL_CreateGPUDevice: No supported SDL_GPU backend found!")
	msg := ui.platform_failure_text(&p, "Pads")
	testing.expectf(t, strings.has_prefix(msg, "Pads can't draw its window"), "%q", msg)
	testing.expectf(t, strings.contains(msg, "graphics driver") && strings.contains(msg, "mesa-vulkan-drivers"), "%q", msg)
	testing.expectf(t, strings.has_suffix(msg, "Details: SDL_CreateGPUDevice: No supported SDL_GPU backend found!"), "%q", msg)
	p.failed = .Window
	testing.expectf(t, strings.has_prefix(ui.platform_failure_text(&p, "Pads"), "Pads can't open its window."), "%q", ui.platform_failure_text(&p, "Pads"))
}

// Lines broken at spaces to a width, paragraphs kept.
@(test)
text_wraps_at_spaces :: proc(t: ^testing.T) {
	testing.expect_value(t, ui.wrap_text("one two three four", 9), "one two\nthree\nfour")
	testing.expect_value(t, ui.wrap_text("a b\n\nc", 10), "a b\n\nc")
	testing.expect_value(t, ui.wrap_text("unbreakable-word x", 5), "unbreakable-word\nx")
}
