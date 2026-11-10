#+build linux
package app

import "fire:backend"
import fc "fire:core"
import "fire:midi"
import alsa_midi "fire:midi/alsa"
import "fire:backend/alsa"

@(private)
platform_driver :: proc() -> ^backend.Driver {
	return alsa.create()
}

@(private)
platform_midi :: proc() -> (^midi.Driver, fc.Error) {
	return alsa_midi.create()
}
