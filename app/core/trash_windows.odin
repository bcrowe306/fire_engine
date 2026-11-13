#+build windows
package app

import "core:path/filepath"
import win "core:sys/windows"
import "core:unicode/utf16"

// [move_to_trash] SHFileOperationW, FO_DELETE with FOF_ALLOWUNDO: the
// Recycle Bin, no dialogs.
@(private)
platform_trash :: proc(path: string) -> bool {
	abs, _ := filepath.abs(path, context.temp_allocator)
	// A list of paths, each ended by a 0, the list by another.
	w := make([]u16, len(abs) * 2 + 2, context.temp_allocator)
	n := utf16.encode_string(w, abs)
	w[n], w[n + 1] = 0, 0
	op := win.SHFILEOPSTRUCTW {
		wFunc  = win.FO_DELETE,
		pFrom  = raw_data(w),
		fFlags = win.FILEOP_FLAGS(win.FOF_ALLOWUNDO | win.FOF_NO_UI),
	}
	return win.SHFileOperationW(&op) == 0 && !bool(op.fAnyOperationsAborted)
}
