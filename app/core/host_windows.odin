#+build windows
package app

import "fire:backend"
import fc "fire:core"
import "fire:midi"
import winmm "fire:midi/winmm"
import "fire:backend/wasapi"

@(private)
platform_driver :: proc() -> ^backend.Driver {
	d, _ := wasapi.create()
	return d
}

@(private)
platform_midi :: proc() -> (^midi.Driver, fc.Error) {
	return winmm.create()
}
