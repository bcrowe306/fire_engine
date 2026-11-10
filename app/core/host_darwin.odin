#+build darwin
package app

import "fire:backend"
import "fire:backend/coreaudio"

@(private)
platform_driver :: proc() -> ^backend.Driver {
	return coreaudio.create()
}
