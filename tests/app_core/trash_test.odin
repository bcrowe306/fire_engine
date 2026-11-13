package test_app_core

import "core:os"
import "core:path/filepath"
import "core:testing"

import app "app:core"
import kit "fire:testkit"

@(private = "file")
scratch :: proc(name: string) -> string {
	dir, _ := filepath.join({kit.artifacts_root(), "app_core", name}, context.temp_allocator)
	os.remove_all(dir)
	os.make_directory_all(dir)
	return dir
}

// Redirected (a test, a run with its own preferences): into that folder,
// a name taken given another.
@(test)
the_trash_can_be_redirected :: proc(t: ^testing.T) {
	dir := scratch("trash_redirect")
	bin, _ := filepath.join({dir, "bin"}, context.temp_allocator)
	app.trash_redirect(bin)
	defer app.trash_redirect("")
	for _ in 0 ..< 2 {
		f, _ := filepath.join({dir, "take.wav"}, context.temp_allocator)
		_ = os.write_entire_file(f, {1, 2, 3})
		testing.expect(t, app.move_to_trash(f), "moved")
		testing.expect(t, !os.exists(f), "gone from where it was")
	}
	entries, _ := os.read_all_directory_by_path(bin, context.temp_allocator)
	testing.expect_value(t, len(entries), 2)
	missing, _ := filepath.join({dir, "nothing.wav"}, context.temp_allocator)
	testing.expect(t, !app.move_to_trash(missing), "a file that isn't there")
}
