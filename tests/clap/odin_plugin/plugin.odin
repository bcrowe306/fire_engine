// CLAP plug-ins made with fire:clap/sdk from fire:dsp nodes, for
// tests/clap: built by scripts/clap.sh into .build/clap/FireOdin.clap.
package fire_odin_plugins

import "fire:clap/sdk"
import "fire:core"
import "fire:dsp"
import c "fire:sys/clap"

defs := [?]sdk.Plugin_Def {
	{id = "dev.fire-engine.odin.gain", name = "Fire Gain", vendor = "Fire Engine", version = "1.0",
	 features = {"audio-effect", "utility"}, inputs = 2, outputs = 2,
	 make = proc() -> core.Node { return dsp.gain_create() }},
	{id = "dev.fire-engine.odin.synth", name = "Fire Synth", vendor = "Fire Engine", version = "1.0",
	 features = {"instrument", "synthesizer"}, outputs = 2, notes_in = true,
	 make = proc() -> core.Node { return dsp.synth_create(8) }},
	{id = "dev.fire-engine.odin.limiter", name = "Fire Limiter", vendor = "Fire Engine", version = "1.0",
	 features = {"audio-effect", "limiter"}, inputs = 2, outputs = 2,
	 make = proc() -> core.Node { return dsp.limiter_create(5) }},
	{id = "dev.fire-engine.odin.delay", name = "Fire Delay", vendor = "Fire Engine", version = "1.0",
	 features = {"audio-effect", "delay"}, inputs = 2, outputs = 2,
	 make = proc() -> core.Node { return dsp.delay_create() }},
}

@(export, link_name = "clap_entry")
clap_entry := c.Plugin_Entry{c.VERSION, init, sdk.entry_deinit, sdk.entry_get_factory}

init :: proc "c" (path: cstring) -> bool {
	return sdk.entry_init(defs[:])
}
