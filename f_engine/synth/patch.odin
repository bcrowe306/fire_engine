package synth

import "fire:core"

// What a synth plays besides its parameters: its routes, its LFO shapes,
// its wavetables and sample. Made on the control thread and handed to
// the node whole (`synth_set_patch`); read-only once handed over.

// The most modulation routes a patch has.
MAX_ROUTES :: 64

// A modulation source.
Mod_Source :: enum u8 {
	None,
	Env_1, Env_2, Env_3, Env_4, Env_5, Env_6,
	Lfo_1, Lfo_2, Lfo_3, Lfo_4, Lfo_5, Lfo_6, Lfo_7, Lfo_8,
	Random_1, Random_2, Random_3, Random_4, // (milestone 3: silent until then)
	Macro_1, Macro_2, Macro_3, Macro_4,
	Velocity,       // the note's, 0..1
	Note,           // the key, 0 (C-2) .. 1 (G8)
	Note_In_Octave, // 0 at C, rising to 1 at the next C
	Aftertouch,
	Mod_Wheel,
	Pitch_Wheel,    // -1..1
	Stereo,         // 1 on the left, -1 on the right (offsets the sides)
	Random,         // a value per note, 0..1
}

// Whether a source belongs to a voice (envelopes, voice LFOs, the note)
// rather than to the whole synth.
mod_source_poly :: proc "contextless" (s: Mod_Source) -> bool {
	#partial switch s {
	case .Macro_1, .Macro_2, .Macro_3, .Macro_4, .Mod_Wheel, .Pitch_Wheel, .Aftertouch, .None: return false
	}
	return true
}

// A route: `source` moves `dest` by `amount` (a share of its range, -1..1)
// through a curve (`power`, as envelope curves). Bipolar sources swing
// both ways about the middle; stereo routes move the right side the
// other way; bypassed routes do nothing.
Route :: struct {
	source:  Mod_Source,
	dest:    core.Param_Id,
	amount:  f32,
	power:   f32,
	bipolar: bool,
	stereo:  bool,
	bypass:  bool,
}

// The rest of a patch (see above). Its tables and sample belong to
// whoever made the patch; they must outlive it.
Patch :: struct {
	routes:      [MAX_ROUTES]Route,
	route_count: int,
	shapes:      [LFOS]Lfo_Shape,
	tables:      [OSCS]^Wavetable,
	sample:      ^Sample,
	// Each LFO's shape rendered, and the envelopes and LFOs some route
	// uses (filled by `patch_prepare`; the rest aren't run).
	shape_tables: [LFOS][LFO_RESOLUTION]f32,
	used_envs:    bit_set[0 ..< ENVS],
	used_lfos:    bit_set[0 ..< LFOS],
	// Parameter values to take with the patch (by id), when `has_values`:
	// every parameter set at once, beyond what parameter events can carry
	// in one block.
	values:       [PARAM_SLOTS]f32,
	has_values:   bool,
}

// Control thread. Renders a patch's LFO shapes (call after changing them,
// before handing it over).
patch_prepare :: proc(p: ^Patch) {
	for i in 0 ..< LFOS do lfo_shape_render(&p.shapes[i], p.shape_tables[i][:])
	p.used_envs, p.used_lfos = {0}, {}
	for r in p.routes[:p.route_count] {
		#partial switch r.source {
		case .Env_1 ..= .Env_6: p.used_envs += {int(r.source) - int(Mod_Source.Env_1)}
		case .Lfo_1 ..= .Lfo_8: p.used_lfos += {int(r.source) - int(Mod_Source.Lfo_1)}
		}
	}
}

// Control thread. A patch with triangle LFOs and no routes, tables or
// sample (give it tables to make sound).
patch_default :: proc() -> (p: Patch) {
	for i in 0 ..< LFOS do p.shapes[i] = lfo_preset(.Triangle)
	patch_prepare(&p)
	return
}

// Adds a route to `p` (false if it has as many as it can).
patch_add_route :: proc(p: ^Patch, r: Route) -> bool {
	if p.route_count >= MAX_ROUTES do return false
	p.routes[p.route_count] = r
	p.route_count += 1
	return true
}
