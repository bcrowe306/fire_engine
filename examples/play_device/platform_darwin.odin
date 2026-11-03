#+build darwin
package play_device

import "fire:backend"
import "fire:backend/coreaudio"

platform_driver :: proc() -> ^backend.Driver {
	return coreaudio.create()
}
