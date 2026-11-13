#+build darwin
package app

import "fire:backend"
import fc "fire:core"
import "fire:midi"
import coremidi "fire:midi/coremidi"
import "fire:backend/coreaudio"

// The drivers macOS has (the first, its default).
@(private)
platform_drivers := []Driver_Choice{{id = "coreaudio", name = "CoreAudio"}}

// Makes the platform's driver `id` ("": the default).
@(private)
platform_driver :: proc(id: string) -> (^backend.Driver, fc.Error) {
	switch id {
	case "", "coreaudio": return coreaudio.create(), .None
	}
	return nil, .Invalid_Argument
}

@(private)
platform_midi :: proc() -> (^midi.Driver, fc.Error) {
	return coremidi.create()
}
