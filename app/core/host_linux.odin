#+build linux
package app

import "fire:backend"
import "fire:backend/alsa"

@(private)
platform_driver :: proc() -> ^backend.Driver {
	return alsa.create()
}
