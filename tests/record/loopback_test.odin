package test_record

import "core:mem"
import "core:os"
import "core:testing"

import "fire:audiofile"
import "fire:backend"
import "fire:backend/fake"
import "fire:core"
import "fire:graph"
import "fire:record"
import "fire:transport"

// Clicks (one sample of 1.0) on every grid beat.
clicker_vtable := core.Node_VTable {
	prepare = proc(self: rawptr, cfg: core.Prepare_Config, a: mem.Allocator) -> core.Error { return .None },
	process = proc(self: rawptr, ctx: ^core.Process_Context) {
		out := ctx.outputs[0]
		for &x in out do x = 0
		t := ctx.transport
		for beat := core.transport_next_multiple(t, 1); ; beat += 1 {
			at := core.transport_offset_of(t, beat)
			if at >= ctx.frames do break
			out[at] = 1
		}
	},
	destroy = proc(self: rawptr, a: mem.Allocator) {},
}

Loop_Rig :: struct {
	clock: ^transport.Clock,
	graph: ^graph.Graph,
}

// The whole path: a click played through the device comes back through a
// loopback 700 frames later, as the driver reports, and the recorder puts
// it back on the beat it was played on.
@(test)
loopback_takes_land_on_the_beat :: proc(t: ^testing.T) {
	cfg := fake.default_config()
	cfg.loopback_latency = 700
	cfg.input_latency_frames, cfg.output_latency_frames = 300, 400
	fk := fake.create(cfg)
	driver := fake.driver(fk)
	defer backend.driver_destroy(driver)
	dev: backend.Device
	backend.device_init(&dev, driver)
	defer backend.device_destroy(&dev)
	if !testing.expect_value(t, backend.device_open(&dev, {sample_rate = SR, buffer_frames = 256, input_channels = {0}, output_channels = {0}}, 128), core.Error.None) do return

	rig: Loop_Rig
	rig.clock, _ = transport.create(transport.default_settings(SR))
	defer transport.destroy(rig.clock)
	song, _ := transport.add_timeline(rig.clock)
	disk, _ := record.disk_writer_create({manual = true})
	defer record.disk_writer_destroy(disk)
	dir, _ := os.make_directory_temp("", "fire_loopback", context.allocator)
	defer delete(dir)
	defer os.remove_all(dir)

	settings := graph.default_settings(SR, 128)
	settings.input_channels, settings.output_channels, settings.workers = 1, 1, 0
	rig.graph, _ = graph.create(settings)
	defer graph.destroy(rig.graph)
	click, _ := graph.add_node(rig.graph, core.node_make(&clicker_vtable, nil, context.allocator), 0, 1)
	graph.connect(rig.graph, click, 0, graph.OUTPUT, 0)
	node, rec, _ := record.audio_recorder_create(disk, {timeline = song, channels = 1, directory = dir, name = "loop", })
	id, _ := graph.add_node(rig.graph, node, 1, 0)
	graph.connect(rig.graph, graph.INPUT, 0, id, 0)
	graph.commit(rig.graph)

	backend.device_start(&dev, {
		process = proc(user: rawptr, block: ^backend.Io_Block) {
			rig := (^Loop_Rig)(user)
			ctx := core.Process_Context{inputs = block.inputs, outputs = block.outputs, frames = block.frames}
			transport.process(rig.clock, &ctx, proc(user: rawptr, seg: ^core.Process_Context) {
				graph.process((^graph.Graph)(user), seg)
			}, rig.graph)
		},
		user = &rig,
	})
	fake.run(fk, 1) // the timestamps arrive with the first callback
	latency := backend.round_trip_latency_frames(&dev)
	testing.expect_value(t, latency, 700)
	record.audio_recorder_set_latency(rec, latency)
	record.audio_recorder_arm(rec, true)
	transport.play(rig.clock, song, transport.At_Beat(1))
	transport.stop(rig.clock, song, transport.At_Beat(5))
	for _ in 0 ..< 6 * BEAT / 256 {
		fake.run(fk, 1)
		record.disk_writer_service(disk)
	}
	backend.device_stop(&dev)

	takes: [dynamic]record.Take
	defer delete(takes)
	for take in record.audio_recorder_poll(rec) do append(&takes, take)
	defer takes_destroy(takes[:])
	if !testing.expect_value(t, len(takes), 1) do return
	testing.expect_value(t, takes[0].frames, i64(4 * BEAT))
	rd, _ := audiofile.open(takes[0].path, context.temp_allocator)
	defer audiofile.close(rd)
	data := make([]f32, 4 * BEAT, context.temp_allocator)
	audiofile.read(rd, {data}, len(data))
	clicks: [dynamic]int
	defer delete(clicks)
	for x, i in data do if x != 0 do append(&clicks, i)
	// Every click is back on the frame of its beat.
	testing.expectf(t, len(clicks) == 4 && clicks[0] == 0 && clicks[1] == BEAT && clicks[2] == 2 * BEAT && clicks[3] == 3 * BEAT, "clicks at %v, want every %d frames from 0", clicks[:], BEAT)
}

// The probe measures a loopback exactly, whatever the driver reports and
// however the driver's callbacks are sized.
@(test)
probe_measures_the_round_trip :: proc(t: ^testing.T) {
	cfg := fake.default_config()
	cfg.loopback_latency = 1234
	cfg.jitter_min, cfg.jitter_max, cfg.seed = 64, 512, 7
	fk := fake.create(cfg)
	driver := fake.driver(fk)
	defer backend.driver_destroy(driver)
	dev: backend.Device
	backend.device_init(&dev, driver)
	defer backend.device_destroy(&dev)
	if !testing.expect_value(t, backend.device_open(&dev, {sample_rate = SR, buffer_frames = 256, input_channels = {0}, output_channels = {0}}, 128), core.Error.None) do return

	settings := graph.default_settings(SR, 128)
	settings.input_channels, settings.output_channels, settings.workers = 1, 1, 0
	g, _ := graph.create(settings)
	defer graph.destroy(g)
	node, probe, _ := record.latency_probe_create({max_seconds = 0.5})
	id, _ := graph.add_node(g, node, 1, 1)
	graph.connect(g, graph.INPUT, 0, id, 0)
	graph.connect(g, id, 0, graph.OUTPUT, 0)
	graph.commit(g)
	backend.device_start(&dev, {
		process = proc(user: rawptr, block: ^backend.Io_Block) {
			ctx := core.Process_Context{inputs = block.inputs, outputs = block.outputs, frames = block.frames}
			graph.process((^graph.Graph)(user), &ctx)
		},
		user = g,
	})
	fake.run(fk, 3)
	record.latency_probe_start(probe)
	frames, quality: f64
	done := false
	for _ in 0 ..< 1000 {
		fake.run(fk, 1)
		if n, q, ok := record.latency_probe_result(probe); ok {
			frames, quality, done = f64(n), q, true
			break
		}
	}
	backend.device_stop(&dev)
	if !testing.expect(t, done, "the probe never finished") do return
	testing.expect_value(t, frames, 1234)
	testing.expectf(t, quality > 0.999, "quality %v", quality)
}
