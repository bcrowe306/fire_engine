#+build linux
package app

import "fire:backend"
import fc "fire:core"
import "fire:midi"
import alsa_midi "fire:midi/alsa"
import "fire:backend/alsa"
import "fire:backend/jack"

// The drivers Linux has (the first, its default): JACK when libjack is
// installed (also PipeWire's).
@(private)
platform_drivers := []Driver_Choice{{id = "alsa", name = "ALSA"}, {id = "jack", name = "JACK"}}

// Makes the platform's driver `id` ("": the default).
@(private)
platform_driver :: proc(id: string) -> (^backend.Driver, fc.Error) {
	switch id {
	case "", "alsa": return alsa.create(), .None
	case "jack":     return jack.create()
	}
	return nil, .Invalid_Argument
}

@(private)
platform_midi :: proc() -> (^midi.Driver, fc.Error) {
	return alsa_midi.create()
}
