#+build windows
package app

import "fire:backend"
import "fire:backend/wasapi"

@(private)
platform_driver :: proc() -> ^backend.Driver {
	d, _ := wasapi.create()
	return d
}
