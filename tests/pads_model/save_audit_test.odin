package test_pads_model

import "base:runtime"
import "core:fmt"
import "core:reflect"
import "core:strings"
import "core:testing"

import fc "fire:core"
import pm "../../apps/pads/model"

// Every setting a project keeps survives a save and a load. Each plain
// field (numbers, switches, choices, nested and in arrays) of the
// project's settings, a pad, a sequence's settings and a bus is set to a
// random value, twice, each time saved and loaded: a field that comes
// back the same both times, though it went in different, is one the file
// doesn't keep. (Ids, text, lists and pointers are left alone: other
// tests cover those.)
@(test)
every_setting_saves :: proc(t: ^testing.T) {
	missing := make(map[string]int, allocator = context.temp_allocator)
	got: [2]map[string]string
	for run in 0 ..< 2 {
		r := rig_make(t, fmt.tprintf("save_audit_%d", run))
		m := &r.m
		audit_run = run
		p := &m.project
		scramble(&p.pads[5], "pad")
		p.pads[5].kind = .Sampler
		scramble(&p.sequences[3].bars, "seq.bars")
		scramble(&p.sequences[3].swing, "seq.swing")
		scramble(&p.sequences[3].swing_grid, "seq.grid")
		scramble(&p.buses[1], "bus")
		scramble(&p.main, "main")
		scramble(&p.transport, "transport")
		scramble(&p.perform, "perform")
		scramble(&p.perf_intensity, "perf_intensity")
		scramble(&p.switch_at, "switch_at")
		scramble(&p.launch_hold, "launch_hold")
		scramble(&p.bpm, "bpm")
		scramble(&p.midi_map, "midi_map")
		scramble(&p.view, "view")
		scramble(&p.slot, "slot")
		scramble(&p.song_mode, "song_mode")
		scramble(&p.bus_count, "bus_count")
		scramble(&p.perf_fx[2].on, "perf_fx.on")
		scramble(&p.song, "song")
		p.song.count = 4
		scramble(&p.sequences[3].color, "seq.color")
		scramble(&p.sequences[3].bpm, "seq.bpm")
		testing.expect_value(t, pm.model_save(m), fc.Error.None)
		r2 := rig_make(t, fmt.tprintf("save_audit_load_%d", run))
		testing.expect_value(t, pm.model_load(&r2.m, p.dir), fc.Error.None)
		q := &r2.m.project
		got[run] = make(map[string]string, allocator = context.temp_allocator)
		collect(&got[run], "pad", q.pads[5])
		collect(&got[run], "bus", q.buses[1])
		collect(&got[run], "main", q.main)
		collect(&got[run], "transport", q.transport)
		collect(&got[run], "perform", q.perform)
		collect(&got[run], "perf_intensity", q.perf_intensity)
		collect(&got[run], "switch_at", q.switch_at)
		collect(&got[run], "launch_hold", q.launch_hold)
		collect(&got[run], "seq.bars", q.sequences[3].bars)
		collect(&got[run], "seq.swing", q.sequences[3].swing)
		collect(&got[run], "seq.grid", q.sequences[3].swing_grid)
		collect(&got[run], "midi_map", q.midi_map)
		collect(&got[run], "view", q.view)
		collect(&got[run], "slot", q.slot)
		collect(&got[run], "song_mode", q.song_mode)
		collect(&got[run], "bus_count", q.bus_count)
		collect(&got[run], "song", q.song)
		collect(&got[run], "seq.color", q.sequences[3].color)
		collect(&got[run], "seq.bpm", q.sequences[3].bpm)
		rig_destroy(r2)
		rig_destroy(r)
	}
	for k, v in got[0] do if got[1][k] == v do missing[k] += 1
	keys := make([dynamic]string, context.temp_allocator)
	for k in missing {
		if strings.has_prefix(k, "pad.synth") do continue // (synth patches: their own test)
		if strings.contains(k, ".label[") do continue     // (text)
		// Song steps past its length aren't kept, by design.
		if strings.has_prefix(k, "song.steps[") && !(strings.has_prefix(k, "song.steps[0]") || strings.has_prefix(k, "song.steps[1]") || strings.has_prefix(k, "song.steps[2]") || strings.has_prefix(k, "song.steps[3]")) do continue
		// Not settings (where main goes; the arpeggiator's random seed), or
		// clamped to a range both test values fall outside (they read back
		// as its bound): tempos (40..300), cutoffs (20 Hz..), count-in (..2 bars).
		switch {
		case k == "main.dest", k == "perform.arp.seed", strings.has_suffix(k, ".bpm"), k == "pad.voice.cutoff", k == "transport.count_in":
			continue
		}
		append(&keys, k)
	}
	for k in keys do testing.expectf(t, false, "not kept by a save: %s (%s both times)", k, got[0][k])
}

// Sets every plain field under `ptr` (of type `T`) to a random value.
// Which run it is: each field gets values that differ between the two.
@(private = "file")
audit_run: int

@(private = "file")
scramble :: proc(ptr: ^$T, path: string) {
	scramble_any(any{ptr, typeid_of(T)}, path)
}

@(private = "file")
scramble_any :: proc(v: any, path: string) {
	ti := runtime.type_info_base(type_info_of(v.id))
	#partial switch info in ti.variant {
	case runtime.Type_Info_Struct:
		for i in 0 ..< info.field_count {
			name := info.names[i]
			if skip_field(name) do continue
			f := reflect.struct_field_value(v, reflect.struct_field_at(v.id, int(i)))
			scramble_any(f, fmt.tprintf("%s.%s", path, name))
		}
	case runtime.Type_Info_Array:
		for k in 0 ..< info.count {
			e := any{rawptr(uintptr(v.data) + uintptr(k * info.elem_size)), info.elem.id}
			scramble_any(e, fmt.tprintf("%s[%d]", path, k))
		}
	case runtime.Type_Info_Enumerated_Array:
		for k in 0 ..< info.count {
			e := any{rawptr(uintptr(v.data) + uintptr(k * info.elem_size)), info.elem.id}
			scramble_any(e, fmt.tprintf("%s[%d]", path, k))
		}
	case runtime.Type_Info_Boolean:
		(^bool)(v.data)^ = audit_run == 0
	case runtime.Type_Info_Float:
		x := 0.23 + f64(audit_run) * 0.31 // (small and positive: inside most ranges)
		switch ti.size {
		case 4: (^f32)(v.data)^ = f32(x)
		case 8: (^f64)(v.data)^ = x
		}
	case runtime.Type_Info_Integer:
		x := 2 + audit_run
		switch ti.size {
		case 1: (^u8)(v.data)^ = u8(x)
		case 2: (^u16)(v.data)^ = u16(x)
		case 4: (^u32)(v.data)^ = u32(x)
		case 8: (^int)(v.data)^ = x
		}
	case runtime.Type_Info_Enum:
		if len(info.values) < 2 do return
		x := info.values[(1 + audit_run) % len(info.values)]
		switch ti.size {
		case 1: (^u8)(v.data)^ = u8(x)
		case 2: (^u16)(v.data)^ = u16(x)
		case 4: (^u32)(v.data)^ = u32(x)
		case 8: (^i64)(v.data)^ = i64(x)
		}
	}
}

// Fields that are not settings (ids, links, sounds, runtime marks).
@(private = "file")
skip_field :: proc(name: string) -> bool {
	switch name {
	case "sample", "id", "ids", "table", "gen", "set", "kind", "plugin_path", "plugin_id", "plugin_name", "name", "count", "params", "routes", "route_count", "slices", "slice_count", "points", "input", "midi_in", "midi_out":
		return true
	}
	return false
}

// Every plain field under `v` by its path, as text.
@(private = "file")
collect :: proc(out: ^map[string]string, path: string, v: $T) {
	v := v
	collect_any(out, path, any{&v, typeid_of(T)})
}

@(private = "file")
collect_any :: proc(out: ^map[string]string, path: string, v: any) {
	ti := runtime.type_info_base(type_info_of(v.id))
	#partial switch info in ti.variant {
	case runtime.Type_Info_Struct:
		for i in 0 ..< info.field_count {
			name := info.names[i]
			if skip_field(name) do continue
			f := reflect.struct_field_value(v, reflect.struct_field_at(v.id, int(i)))
			collect_any(out, fmt.tprintf("%s.%s", path, name), f)
		}
	case runtime.Type_Info_Array:
		for k in 0 ..< info.count do collect_any(out, fmt.tprintf("%s[%d]", path, k), any{rawptr(uintptr(v.data) + uintptr(k * info.elem_size)), info.elem.id})
	case runtime.Type_Info_Enumerated_Array:
		for k in 0 ..< info.count do collect_any(out, fmt.tprintf("%s[%d]", path, k), any{rawptr(uintptr(v.data) + uintptr(k * info.elem_size)), info.elem.id})
	case runtime.Type_Info_Boolean, runtime.Type_Info_Float, runtime.Type_Info_Integer, runtime.Type_Info_Enum:
		out[strings.clone(path, context.temp_allocator)] = fmt.aprint(v, allocator = context.temp_allocator)
	}
}
