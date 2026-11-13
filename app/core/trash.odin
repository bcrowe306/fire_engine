package app

import "core:os"
import "core:path/filepath"
import "core:strings"

@(private = "file")
trash_instead: string

// Moves file or folder `path` to the system's Trash (the Recycle Bin, the
// freedesktop Trash), from where the user can put it back. False if it
// couldn't. With `trash_redirect` set, it moves into that folder instead
// (tests, and a run with its own preferences, keep the user's Trash out
// of it).
move_to_trash :: proc(path: string) -> bool {
	if !os.exists(path) do return false
	if trash_instead != "" {
		if os.make_directory_all(trash_instead) != nil && !os.is_dir(trash_instead) do return false
		dest, _ := filepath.join({trash_instead, filepath.base(path)}, context.temp_allocator)
		for n := 2; os.exists(dest); n += 1 {
			ext := filepath.ext(path)
			stem := strings.trim_suffix(filepath.base(path), ext)
			dest, _ = filepath.join({trash_instead, strings.concatenate({stem, " ", trash_itoa(n), ext}, context.temp_allocator)}, context.temp_allocator)
		}
		return os.rename(path, dest) == nil
	}
	return platform_trash(path)
}

// Makes `move_to_trash` move into folder `dir` instead of the system's
// Trash ("": the system's again).
trash_redirect :: proc(dir: string) {
	delete(trash_instead)
	trash_instead = strings.clone(dir)
}

@(private = "file")
trash_itoa :: proc(n: int) -> string {
	buf: [20]u8
	i := len(buf)
	for v := n; ; v /= 10 {
		i -= 1
		buf[i] = u8('0' + v % 10)
		if v < 10 do break
	}
	return strings.clone(string(buf[i:]), context.temp_allocator)
}
