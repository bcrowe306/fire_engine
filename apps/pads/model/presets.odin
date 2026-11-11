package pads_model

import "core:math"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"

import app "app:core"
import fc "fire:core"
import "fire:fx"
import "fire:synth"

// Synth presets: a patch whole (with any of the project's own wavetables
// it plays, embedded), in a file of our own (`PRESET_EXT`), and a bank
// built in. A preset loaded onto a pad is one undo step.

// A preset file's extension.
PRESET_EXT :: ".fsyn"
// Chunk tag of a preset file.
PRESET_TAG :: fc.Tag{'P', 'S', 'Y', 'N'}
// Version of the preset chunk this version writes.
PRESET_VERSION :: 1

// A preset as read: its patch, and the wavetables of its own it carries
// (for the oscillators that play one).
Preset :: struct {
	patch:   Synth_Patch,
	docs:    [synth.OSCS]Wave_Doc,
	has_doc: [synth.OSCS]bool,
}

// A built-in preset: its name, its kind, and how it is made.
Builtin_Preset :: struct {
	name:     string,
	category: string,
	make:     proc(p: ^Synth_Patch),
}

// The name of the preset synth pad `index` came from ("" if none).
synth_preset_name :: proc(m: ^Model, index: int) -> string {
	b := &m.project.pads[index].synth.preset
	return strings.truncate_to_byte(string(b[:]), 0)
}

// Saves synth pad `index`'s patch as preset `name` in folder `dir` (made
// if it is missing), and names the pad's patch after it. Returns its path.
preset_save :: proc(m: ^Model, index: int, dir: string, name: string) -> (path: string, err: fc.Error) {
	if name == "" do return "", .Invalid_Argument
	if !os.is_dir(dir) && os.make_directory_all(dir) != nil do return "", .Device_Error
	sy := m.project.pads[index].synth
	sy.preset = {}
	copy(sy.preset[:len(sy.preset) - 1], name)
	w: fc.State_Writer
	fc.state_writer_init(&w, context.temp_allocator)
	fc.begin_chunk(&w, PRESET_TAG, PRESET_VERSION)
	fc.write_u32(&w, PROJECT_VERSION) // (the patch as this project version writes it)
	write_synth_patch(&w, &sy)
	for src in sy.tables {
		d := app.store_get(&m.project.wave_docs, src.table) if src.table != 0 else nil
		fc.write_bool(&w, d != nil)
		if d != nil {
			x := d^
			x.sample = 0 // (its sound stays in the project: audio keyframes go silent)
			write_wave_doc(&w, &x)
		}
	}
	fc.end_chunk(&w)
	data := fc.state_writer_bytes(&w) or_return
	path, _ = filepath.join({dir, strings.concatenate({safe_file_name(name), PRESET_EXT}, context.temp_allocator)}, context.temp_allocator)
	if os.write_entire_file(path, data) != nil do return "", .Device_Error
	// The pad now names it (not an undo step: the sound is the same).
	m.project.pads[index].synth.preset = sy.preset
	return path, .None
}

// A name made safe as a file name (no separators or reserved marks).
safe_name :: proc(name: string) -> string { return safe_file_name(name) }

@(private)
safe_file_name :: proc(name: string) -> string {
	b := strings.builder_make(context.temp_allocator)
	for r in name do strings.write_rune(&b, '-' if strings.contains_rune("/\\:*?\"<>|", r) else r)
	return strings.trim_space(strings.to_string(b))
}

// Reads the preset at `path`.
preset_read :: proc(path: string) -> (pr: Preset, err: fc.Error) {
	data, rerr := os.read_entire_file(path, context.temp_allocator)
	if rerr != nil do return {}, .Device_Error
	r := fc.state_reader(data)
	c, ok := fc.read_chunk(&r)
	if !ok || c.tag != PRESET_TAG || c.version > PRESET_VERSION do return {}, .Invalid_Data
	cr := fc.chunk_reader(c)
	version := fc.read_u32(&cr)
	if version > PROJECT_VERSION do return {}, .Invalid_Data
	read_synth_patch(&cr, version, nil, &pr.patch)
	pr.patch.set = true
	for k in 0 ..< synth.OSCS {
		pr.has_doc[k] = fc.read_bool(&cr)
		if pr.has_doc[k] do read_wave_doc(&cr, &pr.docs[k])
	}
	return pr, .None
}

// The presets in folder `dir`: their names, in order (temporary allocator).
preset_list :: proc(dir: string) -> []string {
	out := make([dynamic]string, context.temp_allocator)
	h, err := os.open(dir)
	if err != nil do return nil
	defer os.close(h)
	infos, _ := os.read_dir(h, -1, context.temp_allocator)
	for fi in infos do if strings.has_suffix(fi.name, PRESET_EXT) do append(&out, strings.trim_suffix(fi.name, PRESET_EXT))
	slice.sort(out[:])
	return out[:]
}

// Puts preset `pr` on synth pad `index` (its wavetables added to the
// project): one undo step.
preset_apply :: proc(m: ^Model, index: int, pr: ^Preset) {
	app.begin(&m.history, "Load Preset")
	defer app.end(&m.history)
	patch := pr.patch
	for k in 0 ..< synth.OSCS {
		patch.tables[k].table = 0
		if !pr.has_doc[k] do continue
		d := pr.docs[k]
		wave_gen += 1
		d.gen = wave_gen
		id := app.new_id(&m.project.ids)
		app.execute(&m.history, {vtable = &add_wave_doc_vtable, data = new_clone(Add_Wave_Doc{id, d}), name = "Load Preset"})
		patch.tables[k] = {table = id}
	}
	pad := m.project.pads[index]
	pad.kind = .Synth
	pad.synth = patch
	set_pad(m, index, .Synth, "Load Preset", pad)
}

// Puts built-in preset `k` on synth pad `index`: one undo step.
preset_apply_builtin :: proc(m: ^Model, index: int, k: int) {
	if k < 0 || k >= len(BUILTIN_PRESETS) do return
	pr: Preset
	pr.patch = default_synth_patch()
	BUILTIN_PRESETS[k].make(&pr.patch)
	copy(pr.patch.preset[:len(pr.patch.preset) - 1], BUILTIN_PRESETS[k].name)
	preset_apply(m, index, &pr)
}

// --- the built-in bank ---------------------------------------------------------------------------

@(private = "file")
pv :: proc(p: ^Synth_Patch, id: fc.Param_Id, v: f32) {
	if spec := synth.param_spec(id); spec != nil do p.values[id] = clamp(v, spec.min, spec.max)
}

// A time in seconds as an envelope's (or glide's) plain value.
@(private = "file")
secs :: proc(s: f32) -> f32 { return math.pow(s, 0.25) }

@(private = "file")
route :: proc(p: ^Synth_Patch, r: synth.Route) {
	if p.route_count >= synth.MAX_ROUTES do return
	p.routes[p.route_count] = r
	p.route_count += 1
}

@(private = "file")
table :: proc(p: ^Synth_Patch, osc: int, t: synth.Builtin_Table) { p.tables[osc] = {builtin = u8(t)} }

@(private = "file")
fx_on :: proc(p: ^Synth_Patch, e: fx.Effect) { pv(p, synth.effect_param(e, synth.Chorus_Field.On), 1) }

@(private = "file")
amp :: proc(p: ^Synth_Patch, attack, decay, sustain, release: f32) {
	e :: synth.env_param
	pv(p, e(1, .Attack), secs(attack))
	pv(p, e(1, .Decay), secs(decay))
	pv(p, e(1, .Sustain), sustain)
	pv(p, e(1, .Release), secs(release))
}

// The built-in presets (each kind together).
BUILTIN_PRESETS := [?]Builtin_Preset {
	{"Init", "Basic", proc(p: ^Synth_Patch) {}},
	{"Supersaw Lead", "Lead", proc(p: ^Synth_Patch) {
		o :: synth.osc_param
		pv(p, o(1, .Unison), 7)
		pv(p, o(1, .Detune), 5)
		pv(p, synth.filter_param(1, .Cutoff), 96)
		pv(p, synth.filter_param(1, .Resonance), 0.2)
		amp(p, 0.005, 1, 0.8, 0.25)
		fx_on(p, .Delay)
		pv(p, synth.effect_param(.Delay, synth.Delay_Field.Wet), 0.18)
		fx_on(p, .Reverb)
		pv(p, synth.effect_param(.Reverb, synth.Reverb_Field.Wet), 0.2)
	}},
	{"Pluck", "Keys", proc(p: ^Synth_Patch) {
		f :: synth.filter_param
		pv(p, f(1, .Cutoff), 48)
		pv(p, f(1, .Resonance), 0.3)
		pv(p, synth.env_param(2, .Attack), 0)
		pv(p, synth.env_param(2, .Decay), secs(0.25))
		pv(p, synth.env_param(2, .Sustain), 0)
		route(p, {source = .Env_2, dest = f(1, .Cutoff), amount = 0.45})
		amp(p, 0.002, 0.45, 0, 0.2)
		fx_on(p, .Delay)
		pv(p, synth.effect_param(.Delay, synth.Delay_Field.Style), f32(fx.Delay_Style.Ping_Pong))
		pv(p, synth.effect_param(.Delay, synth.Delay_Field.Wet), 0.2)
	}},
	{"Glass Bell", "Keys", proc(p: ^Synth_Patch) {
		o :: synth.osc_param
		table(p, 0, .Sine)
		pv(p, o(1, .Warp), f32(synth.Osc_Warp.Fm_A))
		pv(p, o(1, .Warp_Amount), 0.3)
		pv(p, o(2, .On), 1)
		table(p, 1, .Sine)
		pv(p, o(2, .Transpose), 19)
		pv(p, o(2, .Level), 0.35)
		pv(p, synth.filter_param(1, .On), 0)
		amp(p, 0.001, 2.2, 0, 1.6)
		fx_on(p, .Reverb)
		pv(p, synth.effect_param(.Reverb, synth.Reverb_Field.Wet), 0.3)
	}},
	{"Retro Keys", "Keys", proc(p: ^Synth_Patch) {
		table(p, 0, .Square_Pwm)
		pv(p, synth.osc_param(1, .Frame), 0.3)
		pv(p, synth.filter_param(1, .Cutoff), 82)
		amp(p, 0.004, 0.6, 0.5, 0.3)
		fx_on(p, .Chorus)
		fx_on(p, .Eq)
	}},
	{"Sub Bass", "Bass", proc(p: ^Synth_Patch) {
		o :: synth.osc_param
		table(p, 0, .Sine)
		pv(p, o(2, .On), 1)
		table(p, 1, .Saw)
		pv(p, o(2, .Level), 0.3)
		pv(p, synth.global_param(.Mono), 2)
		pv(p, synth.global_param(.Glide), secs(0.05))
		pv(p, synth.global_param(.Transpose), -12)
		pv(p, synth.filter_param(1, .Cutoff), 62)
		amp(p, 0.003, 1, 1, 0.08)
		fx_on(p, .Compressor)
	}},
	{"Wobble Bass", "Bass", proc(p: ^Synth_Patch) {
		f :: synth.filter_param
		pv(p, synth.osc_param(1, .Unison), 3)
		pv(p, synth.osc_param(1, .Detune), 2)
		pv(p, synth.global_param(.Transpose), -12)
		pv(p, f(1, .Model), f32(fx.Filter_Model.Ladder))
		pv(p, f(1, .Cutoff), 52)
		pv(p, f(1, .Resonance), 0.55)
		pv(p, synth.lfo_param(1, .Tempo), 9) // 1/8
		route(p, {source = .Lfo_1, dest = f(1, .Cutoff), amount = 0.4})
		fx_on(p, .Distortion)
		pv(p, synth.effect_param(.Distortion, synth.Distortion_Field.Drive), 12)
	}},
	{"Warm Pad", "Pad", proc(p: ^Synth_Patch) {
		o :: synth.osc_param
		table(p, 0, .Basic_Shapes)
		pv(p, o(1, .Frame), 0.4)
		pv(p, o(1, .Unison), 5)
		pv(p, o(1, .Detune), 3)
		pv(p, o(2, .On), 1)
		table(p, 1, .Vowels)
		pv(p, o(2, .Level), 0.45)
		pv(p, o(2, .Transpose), 12)
		pv(p, synth.filter_param(1, .Cutoff), 72)
		amp(p, 0.9, 1, 1, 1.6)
		pv(p, synth.lfo_param(1, .Rate), 0)
		pv(p, synth.lfo_param(1, .Hz), -2) // a cycle each 4 s
		route(p, {source = .Lfo_1, dest = synth.filter_param(1, .Cutoff), amount = 0.12, bipolar = true})
		fx_on(p, .Chorus)
		fx_on(p, .Reverb)
		pv(p, synth.effect_param(.Reverb, synth.Reverb_Field.Decay), 1.5)
		pv(p, synth.effect_param(.Reverb, synth.Reverb_Field.Wet), 0.35)
	}},
	{"Vowel Choir", "Pad", proc(p: ^Synth_Patch) {
		o :: synth.osc_param
		table(p, 0, .Vowels)
		pv(p, o(1, .Unison), 4)
		pv(p, o(1, .Detune), 2.5)
		pv(p, synth.lfo_param(1, .Rate), 0)
		pv(p, synth.lfo_param(1, .Hz), -2.3)
		route(p, {source = .Lfo_1, dest = o(1, .Frame), amount = 1})
		pv(p, synth.filter_param(1, .Cutoff), 100)
		amp(p, 0.6, 1, 1, 1.2)
		fx_on(p, .Chorus)
		fx_on(p, .Reverb)
		pv(p, synth.effect_param(.Reverb, synth.Reverb_Field.Wet), 0.4)
	}},
	{"Lorenz Drone", "Pad", proc(p: ^Synth_Patch) {
		o :: synth.osc_param
		table(p, 0, .Harmonic_Sweep)
		pv(p, synth.random_param(1, .Style), f32(synth.Random_Style.Lorenz))
		pv(p, synth.random_param(1, .Rate), 0)
		pv(p, synth.random_param(1, .Hz), -1)
		route(p, {source = .Random_1, dest = o(1, .Frame), amount = 1})
		pv(p, o(2, .On), 1)
		table(p, 1, .Saw)
		pv(p, o(2, .Transpose), -12)
		pv(p, o(2, .Level), 0.35)
		pv(p, synth.random_param(2, .Rate), 0)
		pv(p, synth.random_param(2, .Hz), -0.5)
		route(p, {source = .Random_2, dest = synth.filter_param(1, .Cutoff), amount = 0.2, bipolar = true})
		pv(p, synth.filter_param(1, .Cutoff), 78)
		amp(p, 1.5, 1, 1, 2.5)
		fx_on(p, .Reverb)
		pv(p, synth.effect_param(.Reverb, synth.Reverb_Field.Decay), 2.5)
		pv(p, synth.effect_param(.Reverb, synth.Reverb_Field.Wet), 0.45)
	}},
	{"Shepard Rise", "FX", proc(p: ^Synth_Patch) {
		o :: synth.osc_param
		pv(p, o(1, .Spectral_Morph), f32(synth.Spectral_Morph.Shepard_Tone))
		pv(p, o(1, .Spectral_Amount), 0)
		pv(p, synth.lfo_param(1, .Rate), 0)
		pv(p, synth.lfo_param(1, .Hz), -1)
		route(p, {source = .Lfo_1, dest = o(1, .Spectral_Amount), amount = 1})
		pv(p, synth.filter_param(1, .Cutoff), 90)
		amp(p, 0.3, 1, 1, 0.8)
		fx_on(p, .Reverb)
	}},
	{"Noise Sweep", "FX", proc(p: ^Synth_Patch) {
		pv(p, synth.osc_param(1, .On), 0)
		pv(p, synth.sample_param(.On), 1)
		f :: synth.filter_param
		pv(p, f(1, .Cutoff), 40)
		pv(p, f(1, .Resonance), 0.6)
		pv(p, synth.env_param(2, .Attack), secs(2))
		pv(p, synth.env_param(2, .Sustain), 1)
		route(p, {source = .Env_2, dest = f(1, .Cutoff), amount = 0.55})
		amp(p, 0.5, 1, 1, 1)
		fx_on(p, .Phaser)
	}},
}
