#+build linux, freebsd, openbsd, netbsd
package app

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:time"

// [move_to_trash] The freedesktop Trash ($XDG_DATA_HOME/Trash, else
// ~/.local/share/Trash): the file into `files/`, a `.trashinfo` beside it
// in `info/` saying where it was and when, so a file manager can put it
// back. (On the home's file system; elsewhere, it isn't moved.)
@(private)
platform_trash :: proc(path: string) -> bool {
	data := os.get_env("XDG_DATA_HOME", context.temp_allocator)
	if data == "" {
		home := os.get_env("HOME", context.temp_allocator)
		if home == "" do return false
		data, _ = filepath.join({home, ".local", "share"}, context.temp_allocator)
	}
	trash, _ := filepath.join({data, "Trash"}, context.temp_allocator)
	files, _ := filepath.join({trash, "files"}, context.temp_allocator)
	info, _ := filepath.join({trash, "info"}, context.temp_allocator)
	for d in ([]string{files, info}) do if os.make_directory_all(d) != nil && !os.is_dir(d) do return false
	abs, _ := filepath.abs(path, context.temp_allocator)
	base := filepath.base(abs)
	name := base
	for n := 2; ; n += 1 {
		f, _ := filepath.join({files, name}, context.temp_allocator)
		i, _ := filepath.join({info, strings.concatenate({name, ".trashinfo"}, context.temp_allocator)}, context.temp_allocator)
		if !os.exists(f) && !os.exists(i) {
			now, _ := time.time_to_rfc3339(time.now(), 0, false, context.temp_allocator)
			stamp := now[:19] if len(now) >= 19 else now // (YYYY-MM-DDThh:mm:ss)
			text := fmt.tprintf("[Trash Info]\nPath=%s\nDeletionDate=%s\n", url_path(abs), stamp)
			if os.write_entire_file(i, transmute([]u8)text) != nil do return false
			if os.rename(abs, f) != nil {
				os.remove(i)
				return false
			}
			return true
		}
		name = fmt.tprintf("%s.%d", base, n)
	}
}

// `path` with what a URL can't hold percent-encoded (as .trashinfo wants).
@(private = "file")
url_path :: proc(path: string) -> string {
	b := strings.builder_make(context.temp_allocator)
	for c in transmute([]u8)path {
		switch c {
		case 'A' ..= 'Z', 'a' ..= 'z', '0' ..= '9', '-', '_', '.', '~', '/': strings.write_byte(&b, c)
		case: fmt.sbprintf(&b, "%%%02X", c)
		}
	}
	return strings.to_string(b)
}
