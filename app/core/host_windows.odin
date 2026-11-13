#+build windows
package app

import "fire:backend"
import fc "fire:core"
import "fire:midi"
import winmm "fire:midi/winmm"
import "fire:backend/asio"
import "fire:backend/wasapi"

// The drivers Windows has (the first, its default): ASIO only in builds
// that include it (`-define:FIRE_ASIO=true`).
@(private)
platform_drivers := []Driver_Choice{{id = "wasapi", name = "WASAPI"}, {id = "asio", name = "ASIO", needs = "" if asio.ENABLED else "this build has no ASIO (-define:FIRE_ASIO=true)"}}

// Makes the platform's driver `id` ("": the default).
@(private)
platform_driver :: proc(id: string) -> (^backend.Driver, fc.Error) {
	switch id {
	case "", "wasapi": return wasapi.create()
	case "asio":       return asio.create()
	}
	return nil, .Invalid_Argument
}

@(private)
platform_midi :: proc() -> (^midi.Driver, fc.Error) {
	return winmm.create()
}
