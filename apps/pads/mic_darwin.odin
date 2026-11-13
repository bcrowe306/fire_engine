package pads

import "core:dynlib"

// Whether the system lets Pads take audio from a microphone or interface
// (macOS asks once; denied, every input is silence and nothing says so).
Mic_Access :: enum u8 {
	Unknown,   // the system doesn't say (or this isn't macOS)
	Not_Asked, // not yet: it asks the first time an input opens
	Denied,    // refused (or restricted): System Settings > Privacy & Security > Microphone
	Granted,
}

@(private = "file")
mic_state: struct {
	lib:     dynlib.Library,
	tried:   bool,
	send:    rawptr, // objc_msgSend
	cls:     rawptr,
	status:  rawptr,
	media:   rawptr, // the NSString "soun" (AVMediaTypeAudio)
}

// The microphone permission as the system has it now (AVFoundation's
// authorization status for audio).
mic_access :: proc() -> Mic_Access {
	st := &mic_state
	if !st.tried {
		st.tried = true
		lib, ok := dynlib.load_library("/System/Library/Frameworks/AVFoundation.framework/AVFoundation")
		if !ok do return .Unknown
		st.lib = lib
		rt, rok := dynlib.load_library("/usr/lib/libobjc.A.dylib")
		if !rok do return .Unknown
		st.send, _ = dynlib.symbol_address(rt, "objc_msgSend")
		gc, _ := dynlib.symbol_address(rt, "objc_getClass")
		sr, _ := dynlib.symbol_address(rt, "sel_registerName")
		if st.send == nil || gc == nil || sr == nil do return .Unknown
		objc_getClass := cast(proc "c" (name: cstring) -> rawptr)gc
		sel_registerName := cast(proc "c" (name: cstring) -> rawptr)sr
		st.cls = objc_getClass("AVCaptureDevice")
		st.status = sel_registerName("authorizationStatusForMediaType:")
		// AVMediaTypeAudio is the NSString "soun": made, kept.
		ns := objc_getClass("NSString")
		mk := sel_registerName("stringWithUTF8String:")
		if ns != nil && st.send != nil {
			make_str := cast(proc "c" (self, op: rawptr, s: cstring) -> rawptr)st.send
			st.media = make_str(ns, mk, "soun")
			retain := cast(proc "c" (self, op: rawptr) -> rawptr)st.send
			retain(st.media, sel_registerName("retain"))
		}
	}
	if st.send == nil || st.cls == nil || st.media == nil do return .Unknown
	ask := cast(proc "c" (self, op, media: rawptr) -> int)st.send
	switch ask(st.cls, st.status, st.media) {
	case 0: return .Not_Asked
	case 1, 2: return .Denied
	case 3: return .Granted
	}
	return .Unknown
}
