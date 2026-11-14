package test_pads_api

import "base:runtime"
import "core:strings"
import "core:testing"
import "core:thread"

import pa "../../apps/pads/api"

@(private)
Heard :: struct {
	transport, history: int,
	last_index:         i64,
}

@(private)
heard :: proc "c" (api: ^pa.Api, topic: pa.Topic, index: i64, user: rawptr) {
	h := (^Heard)(user)
	#partial switch topic {
	case .Transport: h.transport += 1
	case .History:   h.history += 1
	}
	h.last_index = index
}

@(test)
changes_arrive_once_a_frame_coalesced :: proc(t: ^testing.T) {
	r := rig_make(t, "changes")
	defer rig_destroy(r)
	api := &r.api
	h: Heard
	sub, res := pa.subscribe(api, .Transport, -1, heard, &h)
	testing.expect(t, res == .Ok && sub != 0, "subscribed")
	hsub, _ := pa.subscribe(api, .History, -1, heard, &h)
	// Three tempo changes in a frame: heard once, after the frame.
	pa.transport_set_tempo(api, 100)
	pa.transport_set_tempo(api, 110)
	pa.transport_set_tempo(api, 120.5)
	testing.expect_value(t, h.transport, 0)
	frame(r)
	testing.expect_value(t, h.transport, 1)
	testing.expect_value(t, h.history, 1)
	testing.expect_value(t, h.last_index, -1)
	// Nothing changed: nothing heard (the playhead moving isn't a change).
	pa.transport_play(api)
	render(r, 256)
	frame(r)
	testing.expect_value(t, h.transport, 2) // (started)
	render(r, 4096)
	frame(r)
	testing.expect_value(t, h.transport, 2)
	pa.transport_stop(api)
	render(r, 256)
	frame(r)
	testing.expect_value(t, h.transport, 3) // (stopped)
	// An undo is a history change and a transport one.
	pa.history_undo(api)
	frame(r)
	testing.expect_value(t, h.history, 2)
	testing.expect_value(t, h.transport, 4)
	// Gone: not heard.
	testing.expect_value(t, pa.unsubscribe(api, sub), pa.Result.Ok)
	testing.expect_value(t, pa.unsubscribe(api, sub), pa.Result.Not_Found)
	pa.transport_set_loop(api, false)
	frame(r)
	testing.expect_value(t, h.transport, 4)
	testing.expect_value(t, h.history, 3)
	pa.unsubscribe(api, hsub)
	// Topics not reported yet, and no callback.
	_, res = pa.subscribe(api, .Pad, -1, heard, &h)
	testing.expect_value(t, res, pa.Result.Unsupported)
	_, res = pa.subscribe(api, .Transport, -1, nil, nil)
	testing.expect_value(t, res, pa.Result.Invalid_Argument)
}

@(private)
Posted_Tempo :: struct {
	api:  ^pa.Api,
	done: bool,
}

@(test)
calls_posted_from_another_thread_run_at_the_next_frame :: proc(t: ^testing.T) {
	r := rig_make(t, "post")
	defer rig_destroy(r)
	api := &r.api
	p := Posted_Tempo{api = api}
	th := thread.create_and_start_with_poly_data(&p, proc(p: ^Posted_Tempo) {
		pa.api_post(p.api, proc "c" (api: ^pa.Api, user: rawptr) {
			pa_set_tempo_c(api, 150)
			(^Posted_Tempo)(user).done = true
		}, p)
	})
	thread.join(th)
	thread.destroy(th)
	testing.expect(t, !p.done, "not until the frame")
	frame(r)
	testing.expect(t, p.done, "ran")
	testing.expect_value(t, r.core.m.project.bpm, 150)
	testing.expect_value(t, pa.api_post(api, nil, nil), pa.Result.Invalid_Argument)
}

// (A posted call is C-callable: it calls through the table.)
@(private)
pa_set_tempo_c :: proc "c" (api: ^pa.Api, bpm: f64) {
	context = runtime.default_context()
	pa.api_table(api).transport_set_tempo(api, bpm)
}

@(test)
the_c_table_calls_the_same_procs :: proc(t: ^testing.T) {
	r := rig_make(t, "c_table")
	defer rig_destroy(r)
	tb := pa.api_table(&r.api)
	testing.expect_value(t, tb.size, i64(size_of(pa.Table_V1)))
	testing.expect_value(t, tb.version, i64(1))
	api := tb.api
	testing.expect_value(t, tb.transport_set_tempo(api, 99), pa.Result.Ok)
	testing.expect_value(t, tb.transport_set_tempo(api, 9), pa.Result.Invalid_Argument)
	s: pa.Transport_State
	testing.expect_value(t, tb.transport_state(api, &s), pa.Result.Ok)
	testing.expect_value(t, s.bpm, 99)
	// Strings in (with a length, no NUL needed) and out (cut to the buffer).
	name := "Grouped Tempo!"
	testing.expect_value(t, tb.history_group_begin(api, cstring(raw_data(name)), 13), pa.Result.Ok)
	tb.transport_set_tempo(api, 101)
	testing.expect_value(t, tb.history_group_end(api), pa.Result.Ok)
	buf: [64]u8
	n: i64
	testing.expect_value(t, tb.history_undo_name(api, raw_data(buf[:]), len(buf), &n), pa.Result.Ok)
	testing.expect_value(t, n, 13)
	testing.expect_value(t, string(cstring(raw_data(buf[:]))), "Grouped Tempo")
	small: [5]u8
	tb.history_undo_name(api, raw_data(small[:]), len(small), &n)
	testing.expect_value(t, string(cstring(raw_data(small[:]))), "Grou")
	testing.expect_value(t, n, 13)
	testing.expect_value(t, tb.last_error(api, raw_data(buf[:]), len(buf), &n), pa.Result.Ok)
}

@(test)
remote_calls_are_json_lines :: proc(t: ^testing.T) {
	r := rig_make(t, "remote")
	defer rig_destroy(r)
	api := &r.api
	call :: proc(api: ^pa.Api, line: string) -> string {
		sb := strings.builder_make(context.temp_allocator)
		pa.remote_call(api, line, &sb)
		return strings.to_string(sb)
	}
	testing.expect_value(t, call(api, `{"method": "pads_transport_set_tempo", "args": {"bpm": 133}}`), `{"result": "Ok"}`)
	testing.expect_value(t, r.core.m.project.bpm, 133)
	testing.expect_value(t, call(api, `{"method": "pads_transport_set_metronome_sound", "args": {"sound": "Cowbell"}}`), `{"result": "Ok"}`)
	got := call(api, `{"method": "pads_transport_state"}`)
	testing.expectf(t, strings.contains(got, `"bpm":133`) && strings.contains(got, `"metronome_sound":"Cowbell"`), "a snapshot (%s)", got)
	got = call(api, `{"method": "pads_history_undo_name"}`)
	testing.expect_value(t, got, `{"result": "Ok", "value": "Metronome Sound"}`)
	// Defaults may be left out; wrong ones aren't taken.
	testing.expect_value(t, call(api, `{"method": "pads_transport_play", "args": {"count_in": false}}`), `{"result": "Ok"}`)
	testing.expect_value(t, call(api, `{"method": "pads_transport_stop"}`), `{"result": "Ok"}`)
	testing.expect_value(t, call(api, `{"method": "pads_transport_set_tempo", "args": {"bpm": "fast"}}`), `{"result": "Invalid_Argument", "error": "missing or wrong arguments"}`)
	testing.expect_value(t, call(api, `{"method": "pads_transport_set_tempo", "args": {"bpm": 1}}`), `{"result": "Invalid_Argument", "error": "the tempo is 40..300 BPM"}`)
	testing.expect_value(t, call(api, `{"method": "pads_nothing"}`), `{"result": "Not_Found", "error": "no such method"}`)
	testing.expect_value(t, call(api, `[1, 2]`), `{"result": "Invalid_Argument", "error": "not a JSON object"}`)
	testing.expect(t, len(pa.REMOTE_METHODS) > 20, "the methods listed")
}
