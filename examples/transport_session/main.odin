/*
Two ways of making music on one clock: a looping arrangement that sets the
tempo (with a tempo change in it), and a clip launched on the next bar while
it plays. A metronome node clicks on every grid beat, accenting downbeats,
and logs what it sees. Renders 12 seconds offline and prints the log.

	odin run examples/transport_session -collection:fire=f_engine
*/
package transport_session

import "core:fmt"
import "core:mem"

import "fire:core"
import "fire:graph"
import tb "fire:timebase"
import "fire:transport"

SAMPLE_RATE :: 48_000.0
BLOCK :: 512

// --- a node that follows the clock -------------------------------------------------------

// Clicks on every grid beat (louder on downbeats) and logs the timelines it
// follows. Nodes read the clock from ctx.transport.
Metronome :: struct {
	song, clip: core.Timeline_Id,
	phase:      int, // frames into the current click; -1 = silent
	accent:     bool,
	log:        [dynamic]string, // written on the audio thread only in this offline example
}

metronome_vtable := core.Node_VTable {
	prepare = proc(self: rawptr, cfg: core.Prepare_Config, a: mem.Allocator) -> core.Error { return .None },
	process = metronome_process,
	destroy = proc(self: rawptr, a: mem.Allocator) {},
}

CLICK_FRAMES :: 480 // 10 ms

metronome_process :: proc(self: rawptr, ctx: ^core.Process_Context) {
	m := (^Metronome)(self)
	t := ctx.transport
	// The clock splits blocks where timelines start, stop or wrap, so flags
	// always refer to frame 0 of this call.
	song := core.transport_timeline(t, m.song)
	clip := core.transport_timeline(t, m.clip)
	if song != nil && .Wrapped in song.flags {
		append(&m.log, fmt.aprintf("%6.3f s  song loops back to beat %.0f", seconds(t), f64(song.position)))
	}
	if clip != nil && .Started in clip.flags {
		append(&m.log, fmt.aprintf("%6.3f s  clip starts (bar %d of the song)", seconds(t), t.bar + 1))
	}
	if .Tempo_Changed in t.flags {
		append(&m.log, fmt.aprintf("%6.3f s  tempo is now %.0f BPM", seconds(t), t.tempo_bpm))
	}

	// The next whole grid beat due, and where it falls in this call.
	next := core.transport_next_multiple(t, 1)
	click_at := core.transport_offset_of(t, next)
	out := ctx.outputs[0]
	for i in 0 ..< ctx.frames {
		if i == click_at {
			m.phase = 0
			// A downbeat is a whole number of bars from the bar start.
			bars := f64(next - t.bar_start) / tb.beats_per_bar(t.meter)
			m.accent = bars == f64(int(bars))
			next += 1
			click_at = core.transport_offset_of(t, next)
		}
		out[i] = 0
		if m.phase >= 0 && m.phase < CLICK_FRAMES {
			out[i] = (m.accent ? 0.8 : 0.4) * f32(1 - f64(m.phase) / CLICK_FRAMES)
			m.phase += 1
		}
	}
}

seconds :: proc(t: ^core.Transport) -> f64 {
	return f64(t.frame) / t.sample_rate
}

// --- the session ---------------------------------------------------------------------------

main :: proc() {
	// 1. A clock: the grid starts at 120 BPM in 4/4.
	clock, err := transport.create(transport.default_settings(SAMPLE_RATE))
	if err != .None {
		fmt.eprintln("transport.create:", err)
		return
	}
	defer transport.destroy(clock)

	// 2. An arrangement with a tempo map: 120 BPM, 90 from bar 3. It leads,
	//    so its map sets the tempo while it plays, and it loops 4 bars.
	tempo_map: tb.Tempo_Map
	tb.tempo_map_init(&tempo_map, 120)
	defer tb.tempo_map_destroy(&tempo_map)
	tb.tempo_map_set_tempo(&tempo_map, 8, 90)
	song, _ := transport.add_timeline(clock, &tempo_map)
	transport.set_leader(clock, song)
	transport.set_loop(clock, song, 0, 16)
	transport.play(clock, song)

	// 3. A clip: its own timeline, launched later on the next bar line.
	clip, _ := transport.add_timeline(clock)

	// 4. A graph with the metronome, run by the clock.
	settings := graph.default_settings(SAMPLE_RATE, BLOCK)
	settings.input_channels, settings.output_channels = 0, 1
	settings.workers = 0
	g, _ := graph.create(settings)
	defer graph.destroy(g)
	metronome := Metronome{song = song, clip = clip, phase = -1}
	defer {
		for line in metronome.log do delete(line)
		delete(metronome.log)
	}
	id, _ := graph.add_node(g, core.node_make(&metronome_vtable, &metronome, context.allocator), 0, 1)
	graph.connect(g, id, 0, graph.OUTPUT, 0)
	graph.commit(g)

	// 5. Render 12 seconds, launching the clip after 1.3 s.
	out := make([]f32, BLOCK)
	defer delete(out)
	outs := [][]f32{out}
	clicks, prev := 0, f32(0)
	for frame := 0; frame < int(12 * SAMPLE_RATE); frame += BLOCK {
		if frame <= int(1.3 * SAMPLE_RATE) && int(1.3 * SAMPLE_RATE) < frame + BLOCK {
			transport.play(clock, clip, tb.Quantize.Bar)
		}
		ctx := core.Process_Context{outputs = outs, frames = BLOCK}
		transport.process(clock, &ctx, proc(user: rawptr, seg: ^core.Process_Context) {
			graph.process((^graph.Graph)(user), seg)
		}, g)
		for s in out {
			if s != 0 && prev == 0 do clicks += 1
			prev = s
		}
	}

	for line in metronome.log do fmt.println(line)
	pos, _, _ := transport.timeline_status(clock, song)
	fmt.printf("after 12 s: %d clicks, song at beat %.2f, tempo %.0f BPM\n", clicks, f64(pos), transport.status(clock).tempo_bpm)
}
