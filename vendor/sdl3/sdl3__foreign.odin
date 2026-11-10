package sdl3

// Fire Engine: these bindings are Odin's vendor:sdl3 (see LICENSE-Odin.txt
// and LICENSE-SDL.txt), changed only here, to link the static SDL3 that
// `task deps:sdl3` builds into lib/<os>_<arch>/ (so apps ship as one
// binary), with the system libraries static SDL3 needs.

SDL3_WASM_LIB :: #config(SDL3_WASM_LIB, "env.o")

when ODIN_ARCH == .wasm32 || ODIN_ARCH == .wasm64p32 {
	@(export) foreign import lib { SDL3_WASM_LIB }
} else when ODIN_OS == .Windows {
	@(export) foreign import lib {
		"lib/windows_x86_64/SDL3-static.lib",
		"system:setupapi.lib", "system:winmm.lib", "system:imm32.lib", "system:version.lib",
		"system:ole32.lib", "system:oleaut32.lib", "system:gdi32.lib", "system:user32.lib",
		"system:shell32.lib", "system:advapi32.lib", "system:cfgmgr32.lib", "system:uuid.lib",
	}
} else when ODIN_OS == .Darwin && ODIN_ARCH == .arm64 {
	@(export) foreign import lib {
		"lib/darwin_arm64/libSDL3.a",
		"system:Cocoa.framework", "system:IOKit.framework", "system:CoreVideo.framework",
		"system:CoreAudio.framework", "system:AudioToolbox.framework", "system:Carbon.framework",
		"system:ForceFeedback.framework", "system:GameController.framework", "system:CoreHaptics.framework",
		"system:Metal.framework", "system:QuartzCore.framework", "system:UniformTypeIdentifiers.framework",
		"system:AVFoundation.framework", "system:CoreMedia.framework", "system:iconv",
	}
} else when ODIN_OS == .Darwin {
	@(export) foreign import lib {
		"lib/darwin_amd64/libSDL3.a",
		"system:Cocoa.framework", "system:IOKit.framework", "system:CoreVideo.framework",
		"system:CoreAudio.framework", "system:AudioToolbox.framework", "system:Carbon.framework",
		"system:ForceFeedback.framework", "system:GameController.framework", "system:CoreHaptics.framework",
		"system:Metal.framework", "system:QuartzCore.framework", "system:UniformTypeIdentifiers.framework",
		"system:AVFoundation.framework", "system:CoreMedia.framework", "system:iconv",
	}
} else when ODIN_OS == .Linux && ODIN_ARCH == .arm64 {
	@(export) foreign import lib { "lib/linux_arm64/libSDL3.a", "system:m", "system:dl", "system:pthread", "system:rt" }
} else {
	@(export) foreign import lib { "lib/linux_amd64/libSDL3.a", "system:m", "system:dl", "system:pthread", "system:rt" }
}
