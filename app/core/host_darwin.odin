#+build darwin
package app

import "fire:backend"
import fc "fire:core"
import "fire:midi"
import coremidi "fire:midi/coremidi"
import "fire:backend/coreaudio"

@(private)
platform_driver :: proc() -> ^backend.Driver {
	return coreaudio.create()
}

@(private)
platform_midi :: proc() -> (^midi.Driver, fc.Error) {
	return coremidi.create()
}
