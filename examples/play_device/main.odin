/*
Plays a graph through the default audio device for two seconds: a 220 Hz tone
source node → gain → the device's first two output channels. Shows opening a
device, wiring a graph into its callback, and polling device events.

	odin run examples/play_device -collection:fire=f_engine

With FIRE_EXAMPLE_FAKE=1 it uses the simulated driver instead (no sound card
needed; this is how CI runs it).
*/
package play_device

import "core:fmt"
import "core:math"
import "core:mem"
import "core:os"
import "core:time"

import "fire:backend"
import "fire:backend/fake"
import "fire:core"
import "fire:dsp"
import "fire:graph"

BLOCK :: 512

main :: proc() {
	// 1. A driver: the platform's (see platform_*.odin), or the fake one.
	use_fake := os.get_env("FIRE_EXAMPLE_FAKE", context.temp_allocator) != ""
	fake_driver: ^fake.Fake
	driver: ^backend.Driver
	if use_fake {
		fake_driver = fake.create(fake.default_config())
		driver = fake.driver(fake_driver)
	} else {
		driver = platform_driver()
		if driver == nil {
			fmt.eprintln("no audio driver on this platform")
			return
		}
	}
	defer backend.driver_destroy(driver)

	// 2. Open the default output device: two channels, default rate and size.
	dev: backend.Device
	backend.device_init(&dev, driver)
	defer backend.device_destroy(&dev)
	if err := backend.device_open(&dev, {output_channels = {0, 1}}, BLOCK); err != .None {
		fmt.eprintln("device_open:", err)
		return
	}
	format := dev.format
	fmt.printfln("%s: %.0f Hz, %d-frame buffers", driver.name, format.sample_rate, format.buffer_frames)

	// 3. A graph at the device's rate: tone → gain → OUTPUT.
	settings := graph.default_settings(format.sample_rate, BLOCK)
	settings.input_channels = 0
	g, _ := graph.create(settings)
	defer graph.destroy(g)
	tone, _ := graph.add_node(g, tone_create(220), 0, 1)
	gain, _ := graph.add_node(g, dsp.gain_create(), 1, 1)
	graph.connect(g, tone, 0, gain, 0)
	graph.connect(g, gain, 0, graph.OUTPUT, 0)
	graph.connect(g, gain, 0, graph.OUTPUT, 1)
	graph.set_param(g, gain, dsp.GAIN_PARAM_DB, -18)
	graph.commit(g)

	// 4. The device calls this on its audio thread for every block.
	callback := backend.Device_Callback {
		process = proc(user: rawptr, block: ^backend.Io_Block) {
			ctx := core.Process_Context{inputs = block.inputs, outputs = block.outputs, frames = block.frames}
			graph.process((^graph.Graph)(user), &ctx)
		},
		user = g,
	}
	if err := backend.device_start(&dev, callback); err != .None {
		fmt.eprintln("device_start:", err)
		return
	}

	// 5. Run for two seconds, handling device events on this thread.
	for _ in 0 ..< 20 {
		if use_fake {
			fake.run(fake_driver, int(0.1 * format.sample_rate) / format.buffer_frames)
		} else {
			time.sleep(100 * time.Millisecond)
		}
		for e in backend.device_poll_event(&dev) {
			fmt.println("device event:", e.kind)
			if e.kind == .Device_Lost do return
		}
	}
	backend.device_stop(&dev)
	stats := backend.device_stats(&dev)
	fmt.printfln("%d callbacks, %d xruns, peak load %.1f%%", stats.callbacks, stats.xruns, stats.peak_load * 100)
}

// --- a minimal source node -------------------------------------------------------

// A sine oscillator: no inputs, one output.
Tone :: struct {
	freq:        f64,
	phase:       f64,
	sample_rate: f64,
}

tone_vtable := core.Node_VTable {
	prepare = proc(self: rawptr, cfg: core.Prepare_Config, a: mem.Allocator) -> core.Error {
		(^Tone)(self).sample_rate = cfg.sample_rate
		return .None
	},
	process = proc(self: rawptr, ctx: ^core.Process_Context) {
		t := (^Tone)(self)
		for &s in ctx.outputs[0] {
			s = f32(math.sin(2 * math.PI * t.phase))
			t.phase = math.mod(t.phase + t.freq / t.sample_rate, 1)
		}
	},
	destroy = proc(self: rawptr, a: mem.Allocator) { free(self, a) },
}

tone_create :: proc(freq: f64) -> core.Node {
	t := new(Tone)
	t.freq = freq
	return core.node_make(&tone_vtable, t, context.allocator)
}
