#+build linux
package play_device

import "fire:backend"
import "fire:backend/alsa"

platform_driver :: proc() -> ^backend.Driver {
	return alsa.create()
}
