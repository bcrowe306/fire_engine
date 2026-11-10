package sampler

import "core:mem"

import "fire:core"
import "fire:stream"

// Saved-state ID of `sampler_create` nodes (settings and sample map).
SAMPLER_TYPE_ID :: "fire.sampler"

// Chunk tag of a saved sample map.
SAMPLE_MAP_TAG :: core.Tag{'S', 'M', 'A', 'P'}

// Registers the sampler, opening sample files through `streamer` (which
// must outlive the registry). Control thread.
register_types :: proc(reg: ^core.Node_Registry, streamer: ^stream.Streamer) -> core.Error {
	if streamer == nil do return .Invalid_Argument
	return core.register_type(reg, {id = SAMPLER_TYPE_ID, load = load_sampler, data = streamer})
}

// Writes `m` as a SAMPLE_MAP_TAG chunk: each zone with its file's path (see
// `core.write_path`). Nil writes an empty chunk.
write_sample_map :: proc(w: ^core.State_Writer, ctx: ^core.Save_Context, m: ^Sample_Map) {
	core.begin_chunk(w, SAMPLE_MAP_TAG, 1)
	if m != nil {
		core.write_int(w, len(m.zones))
		for z in m.zones {
			core.write_path(w, ctx, z.source.path)
			core.write_u8(w, z.root_key)
			core.write_u8(w, z.key_lo)
			core.write_u8(w, z.key_hi)
			core.write_f32(w, z.vel_lo)
			core.write_f32(w, z.vel_hi)
			core.write_f64(w, z.tune_cents)
			core.write_f64(w, z.gain_db)
			core.write_i64(w, z.start)
			core.write_i64(w, z.end)
			core.write_bool(w, z.loop)
			core.write_i64(w, z.loop_start)
			core.write_i64(w, z.loop_end)
			core.write_bool(w, z.one_shot)
		}
	}
	core.end_chunk(w)
}

// Reads a map written by `write_sample_map` from the reader's next chunk,
// opening each file through `streamer`: a new map with one reference, or
// nil for a saved nil map. `.Invalid_Data` for a malformed chunk;
// `.Device_Error` if a file cannot be opened; `.Invalid_Argument` if a file
// no longer fits its zone.
read_sample_map :: proc(r: ^core.State_Reader, ctx: ^core.Load_Context, streamer: ^stream.Streamer, allocator := context.allocator) -> (m: ^Sample_Map, err: core.Error) {
	ch, ok := core.find_chunk(r, SAMPLE_MAP_TAG)
	if !ok do return nil, .Invalid_Data
	if len(ch.data) == 0 do return nil, .None
	cr := core.chunk_reader(ch)
	count := core.read_int(&cr)
	if count < 0 || count > len(ch.data) / 70 do return nil, .Invalid_Data
	zones := make([]Sample_Zone, count, context.temp_allocator)
	opened := 0
	defer for z in zones[:opened] do stream.source_release(z.source) // the map keeps its own references
	for &z in zones {
		path := core.read_path(&cr, ctx, context.temp_allocator)
		z.root_key, z.key_lo, z.key_hi = core.read_u8(&cr), core.read_u8(&cr), core.read_u8(&cr)
		z.vel_lo, z.vel_hi = core.read_f32(&cr), core.read_f32(&cr)
		z.tune_cents, z.gain_db = core.read_f64(&cr), core.read_f64(&cr)
		z.start, z.end = core.read_i64(&cr), core.read_i64(&cr)
		z.loop = core.read_bool(&cr)
		z.loop_start, z.loop_end = core.read_i64(&cr), core.read_i64(&cr)
		z.one_shot = core.read_bool(&cr)
		if cr.err != .None do return nil, .Invalid_Data
		src, serr := stream.source_open(streamer, path)
		if serr != .None do return nil, .Device_Error
		z.source = src
		opened += 1
	}
	return sample_map_create(zones, allocator)
}

@(private)
save_sampler :: proc(self: rawptr, w: ^core.State_Writer, ctx: ^core.Save_Context) -> core.Error {
	s := (^Sampler)(self)
	core.write_int(w, s.settings.voices)
	core.write_u8(w, u8(s.settings.quality))
	write_sample_map(w, ctx, s.latest)
	return .None
}

@(private)
load_sampler :: proc(data: rawptr, r: ^core.State_Reader, version: u32, ctx: ^core.Load_Context, allocator: mem.Allocator) -> (core.Node, core.Error) {
	settings: Sampler_Settings
	settings.voices = core.read_int(r)
	quality := core.read_u8(r)
	if r.err != .None || int(quality) > int(max(Sampler_Quality)) do return {}, .Invalid_Data
	settings.quality = Sampler_Quality(quality)
	m, err := read_sample_map(r, ctx, (^stream.Streamer)(data), allocator)
	if err != .None do return {}, err
	defer sample_map_release(m) // the sampler takes its own
	node, s := sampler_create(settings, allocator)
	if m != nil {
		if e := sampler_set_map(s, m); e != .None {
			core.node_destroy(&node)
			return {}, e
		}
	}
	return node, .None
}
