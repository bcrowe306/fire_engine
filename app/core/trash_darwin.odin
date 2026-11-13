#+build darwin
package app

import "core:dynlib"
import "core:path/filepath"
import "core:strings"

@(private = "file")
trash_state: struct {
	tried:   bool,
	send:    rawptr, // objc_msgSend
	manager: rawptr, // [NSFileManager defaultManager]
	trash:   rawptr, // trashItemAtURL:resultingItemURL:error:
	url_cls: rawptr, // NSURL
	url:     rawptr, // fileURLWithPath:
	str_cls: rawptr, // NSString
	str:     rawptr, // stringWithUTF8String:
}

// [move_to_trash] NSFileManager's trashItemAtURL:resultingItemURL:error:
// (the Finder can put it back).
@(private)
platform_trash :: proc(path: string) -> bool {
	st := &trash_state
	if !st.tried {
		st.tried = true
		if _, ok := dynlib.load_library("/System/Library/Frameworks/Foundation.framework/Foundation"); !ok do return false
		rt, ok := dynlib.load_library("/usr/lib/libobjc.A.dylib")
		if !ok do return false
		st.send, _ = dynlib.symbol_address(rt, "objc_msgSend")
		gc, _ := dynlib.symbol_address(rt, "objc_getClass")
		sr, _ := dynlib.symbol_address(rt, "sel_registerName")
		if st.send == nil || gc == nil || sr == nil do return false
		get_class := cast(proc "c" (name: cstring) -> rawptr)gc
		sel := cast(proc "c" (name: cstring) -> rawptr)sr
		msg0 := cast(proc "c" (self, op: rawptr) -> rawptr)st.send
		st.manager = msg0(get_class("NSFileManager"), sel("defaultManager"))
		st.trash = sel("trashItemAtURL:resultingItemURL:error:")
		st.url_cls, st.url = get_class("NSURL"), sel("fileURLWithPath:")
		st.str_cls, st.str = get_class("NSString"), sel("stringWithUTF8String:")
	}
	if st.manager == nil || st.url_cls == nil || st.str_cls == nil do return false
	abs, _ := filepath.abs(path, context.temp_allocator)
	msg1 := cast(proc "c" (self, op, arg: rawptr) -> rawptr)st.send
	s := msg1(st.str_cls, st.str, rawptr(strings.clone_to_cstring(abs, context.temp_allocator)))
	if s == nil do return false
	url := msg1(st.url_cls, st.url, s)
	if url == nil do return false
	trash := cast(proc "c" (self, op, url, out, err: rawptr) -> bool)st.send
	return trash(st.manager, st.trash, url, nil, nil)
}
