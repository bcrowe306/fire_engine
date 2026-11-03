#+build windows
package play_device

import "fire:backend"
import "fire:backend/wasapi"

platform_driver :: proc() -> ^backend.Driver {
	d, _ := wasapi.create()
	return d
}
