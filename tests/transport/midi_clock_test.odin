package test_transport

import "core:math"
import "core:testing"

import "fire:core"
import "fire:graph"
import tb "fire:timebase"
import "fire:transport"

Sent :: struct {
	frame: i64,
	bytes: [3]u8,
}

// A graph holding one MIDI clock node, run under `c`; collects what it sends.
Clock_Rig :: struct {
	g:      ^graph.Graph,
	buf:    []core.Event,
	sent:   [dynamic]Sent,
	frame:  i64,
}

rig_make :: proc(settings: transport.Midi_Clock_Settings) -> (r: Clock_Rig) {
	st := graph.default_settings(SR, 4096)
	st.workers = 0
	r.g, _ = graph.create(st)
	id, _ := graph.add_node(r.g, transport.midi_clock_create(settings), 0, 0)
	graph.connect_events(r.g, id, graph.OUTPUT)
	graph.commit(r.g)
	r.buf = make([]core.Event, 4096)
	return
}

rig_destroy :: proc(r: ^Clock_Rig) {
	graph.destroy(r.g)
	delete(r.buf)
	delete(r.sent)
}

rig_run :: proc(r: ^Clock_Rig, c: ^transport.Clock, total: int, block := 512) {
	for done := 0; done < total; {
		n := min(block, total - done)
		w := core.Event_Writer{buffer = r.buf}
		ctx := core.Process_Context{frames = n, events_out = &w}
		transport.process(c, &ctx, proc(user: rawptr, seg: ^core.Process_Context) {
			graph.process((^graph.Graph)(user), seg)
		}, r.g)
		for e in core.event_writer_events(&w) {
			raw := e.payload.(core.Midi_Raw)
			append(&r.sent, Sent{r.frame + i64(e.offset), raw.bytes})
		}
		r.frame += i64(n)
		done += n
	}
}

@(test)
midi_clock_ticks_on_the_grid :: proc(t: ^testing.T) {
	c := new_clock(120)
	defer transport.destroy(c)
	r := rig_make({})
	defer rig_destroy(&r)
	rig_run(&r, c, 48_000, 333)
	testing.expect_value(t, len(r.sent), 48) // 2 beats × 24
	for s, i in r.sent {
		testing.expect_value(t, s.bytes[0], transport.MIDI_CLOCK)
		testing.expect_value(t, s.frame, i64(i * 1000)) // a 24th of a beat at 120 BPM, 48 kHz
	}
}

@(test)
midi_clock_follows_a_timeline :: proc(t: ^testing.T) {
	c := new_clock(120)
	defer transport.destroy(c)
	song, _ := transport.add_timeline(c)
	r := rig_make({follow = song})
	defer rig_destroy(&r)

	rig_run(&r, c, 30_000) // stopped: no ticks
	testing.expect_value(t, len(r.sent), 0)

	transport.set_loop(c, song, 0, 2)
	transport.play(c, song, tb.Quantize.Bar) // grid 4, frame 96 000
	rig_run(&r, c, 100_000)                  // to frame 130 000, before the wrap
	if !testing.expect(t, len(r.sent) >= 2) do return
	testing.expect_value(t, r.sent[0], Sent{96_000, {transport.MIDI_START, 0, 0}})
	testing.expect_value(t, r.sent[1], Sent{96_000, {transport.MIDI_CLOCK, 0, 0}})
	ticks := 0
	for s in r.sent do if s.bytes[0] == transport.MIDI_CLOCK {
		testing.expect_value(t, s.frame, 96_000 + i64(ticks) * 1000)
		ticks += 1
	}
	testing.expect_value(t, ticks, 34) // frames 96 000 ..= 129 000

	// The loop wraps at song beat 2 = frame 144 000: Stop, position 0, Continue.
	n := len(r.sent)
	rig_run(&r, c, 20_000)
	wrap := []Sent{{144_000, {transport.MIDI_STOP, 0, 0}}, {144_000, {transport.MIDI_SONG_POSITION, 0, 0}}, {144_000, {transport.MIDI_CONTINUE, 0, 0}}, {144_000, {transport.MIDI_CLOCK, 0, 0}}}
	found := false
	for i in n ..< len(r.sent) - 3 do if r.sent[i].frame == 144_000 {
		found = true
		for w, k in wrap do testing.expect_value(t, r.sent[i + k], w)
		break
	}
	testing.expect(t, found, "nothing sent at the wrap")

	transport.stop(c, song)
	transport.clear_loop(c, song)
	transport.locate(c, song, 2.5) // sixteenth 10
	rig_run(&r, c, 1000)
	testing.expect_value(t, r.sent[len(r.sent) - 1].bytes[0], transport.MIDI_STOP)
	transport.play(c, song)
	n = len(r.sent)
	rig_run(&r, c, 1000)
	testing.expect_value(t, r.sent[n].bytes, [3]u8{transport.MIDI_SONG_POSITION, 10, 0})
	testing.expect_value(t, r.sent[n + 1].bytes[0], transport.MIDI_CONTINUE)
}

// At a tempo where ticks fall between frames, every tick is sent exactly
// once, on the first frame at or after it, whatever the block sizes.
@(test)
midi_clock_ticks_between_frames :: proc(t: ^testing.T) {
	expected: [dynamic]i64
	defer delete(expected)
	frames_per_tick := SR * 60 / 117.3 / 24
	for k := 0; ; k += 1 {
		f := i64(math.ceil(f64(k) * frames_per_tick - 1e-6))
		if f >= 96_000 do break
		append(&expected, f)
	}
	for block in ([]int{512, 1, 333, 4096}) {
		c := new_clock(117.3)
		r := rig_make({})
		rig_run(&r, c, 96_000, block)
		ok := testing.expectf(t, len(r.sent) == len(expected), "block %d: %d ticks, want %d", block, len(r.sent), len(expected))
		if ok do for s, i in r.sent do if s.frame != expected[i] {
			testing.expectf(t, false, "block %d: tick %d at frame %d, want %d", block, i, s.frame, expected[i])
			break
		}
		rig_destroy(&r)
		transport.destroy(c)
	}
}

// Following a MIDI clock: the tempo from its ticks (steady through ±20
// frames of jitter), the position counted from Start (and from a Song
// Position Pointer), and its Start and Stop passed to the timeline.
@(test)
midi_clock_follower_hears_tempo_position_start_stop :: proc(t: ^testing.T) {
	f: transport.Midi_Clock_Follower
	events: []core.Event
	f.events = &events
	s := transport.midi_clock_follow_sync(&f, {})
	rate := 48_000.0
	tick := rate * 60 / (140 * 24) // frames between ticks at 140 BPM
	block := 512
	next := 0.0 // when the next tick is due
	jitter := [5]f64{0, 20, -15, 8, -20}
	k := 0
	b: transport.Sync_Block
	run :: proc(f: ^transport.Midi_Clock_Follower, s: transport.Sync, events: ^[]core.Event, b: ^transport.Sync_Block, frame, block: int, rate: f64, next: ^f64, tick: f64, jitter: [5]f64, k: ^int, extra: []core.Event = nil) {
		list := make([dynamic]core.Event, context.temp_allocator)
		append(&list, ..extra)
		for next^ < f64(frame + block) {
			at := clamp(next^ + jitter[k^ % 5], f64(frame), f64(frame + block - 1))
			append(&list, core.Event{offset = u32(at) - u32(frame), payload = core.Midi_Raw{bytes = {transport.MIDI_CLOCK, 0, 0}}})
			next^ += tick
			k^ += 1
		}
		events^ = list[:]
		b^ = {frame = tb.Sample_Time(frame), frames = block, sample_rate = rate}
		s.begin_block(s.user, b)
	}
	start := []core.Event{{offset = 0, payload = core.Midi_Raw{bytes = {transport.MIDI_START, 0, 0}}}}
	run(&f, s, &events, &b, 0, block, rate, &next, tick, jitter, &k, start)
	frame := block
	for ; frame < int(rate * 2); frame += block do run(&f, s, &events, &b, frame, block, rate, &next, tick, jitter, &k)
	testing.expectf(t, abs(f.bpm - 140) < 1, "the tempo heard: %v", f.bpm)
	testing.expect(t, b.ok && f.running, "running, setting the clock")
	elapsed := f64(frame - block) / rate * 140 / 60
	testing.expectf(t, abs(f64(b.beat) - elapsed) < 0.1, "where it is: %v (want about %v)", b.beat, elapsed)
	// Stop: passed on; the position holds.
	stop := []core.Event{{offset = 0, payload = core.Midi_Raw{bytes = {transport.MIDI_STOP, 0, 0}}}}
	run(&f, s, &events, &b, frame, block, rate, &next, tick, jitter, &k, stop)
	testing.expect(t, b.start_stop == .Stop && !f.running, "stopped")
	held := b.beat
	frame += block
	run(&f, s, &events, &b, frame, block, rate, &next, tick, jitter, &k)
	testing.expect_value(t, b.beat, held)
	// Song Position Pointer 32 (sixteenths: beat 8), then Continue.
	spp := []core.Event{{offset = 0, payload = core.Midi_Raw{bytes = {transport.MIDI_SONG_POSITION, 32, 0}}}, {offset = 1, payload = core.Midi_Raw{bytes = {transport.MIDI_CONTINUE, 0, 0}}}}
	frame += block
	run(&f, s, &events, &b, frame, block, rate, &next, tick, jitter, &k, spp)
	testing.expect(t, b.start_stop == .Start && f.running, "continued")
	testing.expectf(t, abs(f64(b.beat) - 8) < 0.1, "from beat 8: %v", b.beat)
}
