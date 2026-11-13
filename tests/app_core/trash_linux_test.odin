#+build linux
package test_app_core

import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"

import app "app:core"
import kit "fire:testkit"

// Linux: the freedesktop Trash, here under a data folder of the test's
// own (XDG_DATA_HOME): the file in files/, where it was in info/.
@(test)
the_freedesktop_trash :: proc(t: ^testing.T) {
	dir, _ := filepath.join({kit.artifacts_root(), "app_core", "trash_xdg"}, context.temp_allocator)
	os.remove_all(dir)
	os.make_directory_all(dir)
	data, _ := filepath.join({dir, "data"}, context.temp_allocator)
	old := os.get_env("XDG_DATA_HOME", context.temp_allocator)
	os.set_env("XDG_DATA_HOME", data)
	defer os.set_env("XDG_DATA_HOME", old)
	f, _ := filepath.join({dir, "my take.wav"}, context.temp_allocator)
	_ = os.write_entire_file(f, {1, 2, 3})
	testing.expect(t, app.move_to_trash(f), "moved")
	in_trash, _ := filepath.join({data, "Trash", "files", "my take.wav"}, context.temp_allocator)
	info, _ := filepath.join({data, "Trash", "info", "my take.wav.trashinfo"}, context.temp_allocator)
	testing.expect(t, os.exists(in_trash), "in files/")
	text, _ := os.read_entire_file(info, context.temp_allocator)
	testing.expect(t, strings.contains(string(text), "Path=") && strings.contains(string(text), "my%20take.wav"), "where it was, encoded")
	testing.expect(t, strings.contains(string(text), "DeletionDate="), "when")
}
