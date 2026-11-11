package synth

import "base:intrinsics"
import "core:fmt"

import "fire:core"
import "fire:fx"

// The effects' parameters: a block of ids each (`effect_param(.Delay,
// Delay_Field.Feedback)`). They are the synth's, not a voice's: macros,
// the wheels and the newest voice's modulators move them.

// The chorus's parameters.
Chorus_Field :: enum u16 {On, Voices, Sync, Hz, Tempo, Feedback, Wet, Cutoff, Spread, Depth, Delay_1, Delay_2}
// The compressor's parameters (the bands: low, band, high).
Compressor_Field :: enum u16 {
	On, Bands, Attack, Release, Mix,
	Low_Upper, Low_Lower, Low_Upper_Ratio, Low_Lower_Ratio, Low_Gain,
	Band_Upper, Band_Lower, Band_Upper_Ratio, Band_Lower_Ratio, Band_Gain,
	High_Upper, High_Lower, High_Upper_Ratio, High_Lower_Ratio, High_Gain,
}
// The delay's parameters (`Hz` and `Tempo` the left side's, or both).
Delay_Field :: enum u16 {On, Style, Sync, Hz, Tempo, Hz_Right, Tempo_Right, Feedback, Wet, Cutoff, Spread}
// The distortion's parameters.
Distortion_Field :: enum u16 {On, Type, Drive, Mix, Filter_Order, Cutoff, Resonance, Blend}
// The EQ's parameters (low, band, high).
Eq_Field :: enum u16 {
	On,
	Low_Mode, Low_Cutoff, Low_Gain, Low_Resonance,
	Band_Mode, Band_Cutoff, Band_Gain, Band_Resonance,
	High_Mode, High_Cutoff, High_Gain, High_Resonance,
}
// The filter effect's parameters.
Fx_Filter_Field :: enum u16 {
	On, Model, Style, Cutoff, Resonance, Drive, Blend, Mix, Gain,
	Formant_X, Formant_Y, Formant_Transpose, Formant_Resonance, Formant_Spread, Comb_Offset,
}
// The flanger's parameters.
Flanger_Field :: enum u16 {On, Sync, Hz, Tempo, Center, Feedback, Wet, Depth, Offset}
// The phaser's parameters.
Phaser_Field :: enum u16 {On, Sync, Hz, Tempo, Feedback, Wet, Center, Blend, Depth, Offset}
// The reverb's parameters.
Reverb_Field :: enum u16 {On, Wet, Decay, Size, Delay, Pre_Low, Pre_High, Low_Cutoff, Low_Gain, High_Cutoff, High_Gain, Chorus, Chorus_Hz}

@(private) FX_BASE :: 700
@(private) FX_STRIDE :: 32

// The id of effect `e`'s parameter `f` (a field of its own enum).
effect_param :: #force_inline proc "contextless" (e: fx.Effect, f: $T) -> core.Param_Id where intrinsics.type_is_enum(T) {
	return core.Param_Id(FX_BASE + int(e) * FX_STRIDE + int(f))
}

// Whether `id` is an effect's.
is_effect_param :: #force_inline proc "contextless" (id: core.Param_Id) -> bool {
	return int(id) >= FX_BASE && int(id) < PARAM_SLOTS
}

// The names effects go by, in parameter names and on screen.
EFFECT_NAMES := [fx.Effect]string{.Chorus = "Chorus", .Compressor = "Compressor", .Delay = "Delay", .Distortion = "Distortion", .Eq = "EQ", .Filter = "FX Filter", .Flanger = "Flanger", .Phaser = "Phaser", .Reverb = "Reverb"}

@(private)
build_fx_params :: proc() {
	add :: param_add
	name :: proc(e: fx.Effect, s: string) -> string { return fmt.aprintf("%s %s", EFFECT_NAMES[e], s) }
	sync_max := f32(len(fx.Sync) - 1)
	{
		e :: fx.Effect.Chorus
		c :: proc(f: Chorus_Field) -> core.Param_Id { return effect_param(e, f) }
		add(c(.On), name(e, "On"), 0, 1, 0, .Indexed, false)
		add(c(.Voices), name(e, "Voices"), 1, 4, 4, .Indexed, false)
		add(c(.Sync), name(e, "Sync"), 0, sync_max, 0, .Indexed, false)
		add(c(.Hz), name(e, "Frequency"), -8, 3, -3, .Exponential, false)
		add(c(.Tempo), name(e, "Tempo"), 0, 12, 4, .Indexed, false)
		add(c(.Feedback), name(e, "Feedback"), -0.95, 0.95, 0.4, poly = false)
		add(c(.Wet), name(e, "Mix"), 0, 1, 0.5, poly = false)
		add(c(.Cutoff), name(e, "Cutoff"), 8, 136, 60, poly = false)
		add(c(.Spread), name(e, "Spread"), 0, 1, 1, poly = false)
		add(c(.Depth), name(e, "Depth"), 0, 1, 0.5, poly = false)
		add(c(.Delay_1), name(e, "Delay 1"), -10, -5.5, -9, .Exponential, false)
		add(c(.Delay_2), name(e, "Delay 2"), -10, -5.5, -7, .Exponential, false)
	}
	{
		e :: fx.Effect.Compressor
		c :: proc(f: Compressor_Field) -> core.Param_Id { return effect_param(e, f) }
		add(c(.On), name(e, "On"), 0, 1, 0, .Indexed, false)
		add(c(.Bands), name(e, "Bands"), 0, f32(len(fx.Compressor_Bands) - 1), 0, .Indexed, false)
		add(c(.Attack), name(e, "Attack"), 0, 1, 0.5, poly = false)
		add(c(.Release), name(e, "Release"), 0, 1, 0.5, poly = false)
		add(c(.Mix), name(e, "Mix"), 0, 1, 1, poly = false)
		bands := [3]string{"Low", "Band", "High"}
		def := fx.COMPRESSOR_DEFAULTS
		for b in 0 ..< 3 {
			at := int(Compressor_Field.Low_Upper) + b * 5
			id :: proc(at, k: int) -> core.Param_Id { return effect_param(e, Compressor_Field(at + k)) }
			add(id(at, 0), fmt.aprintf("Compressor %s Upper Threshold", bands[b]), -80, 0, def.band[b].upper_db, poly = false, unit = .Decibels)
			add(id(at, 1), fmt.aprintf("Compressor %s Lower Threshold", bands[b]), -80, 0, def.band[b].lower_db, poly = false, unit = .Decibels)
			add(id(at, 2), fmt.aprintf("Compressor %s Upper Ratio", bands[b]), 0, 1, def.band[b].upper_ratio, poly = false)
			add(id(at, 3), fmt.aprintf("Compressor %s Lower Ratio", bands[b]), -1, 1, def.band[b].lower_ratio, poly = false)
			add(id(at, 4), fmt.aprintf("Compressor %s Gain", bands[b]), -30, 30, def.band[b].gain_db, poly = false, unit = .Decibels)
		}
	}
	{
		e :: fx.Effect.Delay
		d :: proc(f: Delay_Field) -> core.Param_Id { return effect_param(e, f) }
		add(d(.On), name(e, "On"), 0, 1, 0, .Indexed, false)
		add(d(.Style), name(e, "Style"), 0, f32(len(fx.Delay_Style) - 1), 1, .Indexed, false)
		add(d(.Sync), name(e, "Sync"), 0, sync_max, 1, .Indexed, false)
		add(d(.Hz), name(e, "Frequency"), -2, 9, 2, .Exponential, false)
		add(d(.Tempo), name(e, "Tempo"), 0, 12, 9, .Indexed, false)
		add(d(.Hz_Right), name(e, "Frequency Right"), -2, 9, 2, .Exponential, false)
		add(d(.Tempo_Right), name(e, "Tempo Right"), 0, 12, 9, .Indexed, false)
		add(d(.Feedback), name(e, "Feedback"), -1, 1, 0.5, poly = false)
		add(d(.Wet), name(e, "Mix"), 0, 1, 0.3334, poly = false)
		add(d(.Cutoff), name(e, "Cutoff"), 8, 136, 60, poly = false)
		add(d(.Spread), name(e, "Spread"), 0, 1, 1, poly = false)
	}
	{
		e :: fx.Effect.Distortion
		d :: proc(f: Distortion_Field) -> core.Param_Id { return effect_param(e, f) }
		add(d(.On), name(e, "On"), 0, 1, 0, .Indexed, false)
		add(d(.Type), name(e, "Type"), 0, f32(len(fx.Distortion_Type) - 1), 0, .Indexed, false)
		add(d(.Drive), name(e, "Drive"), -30, 30, 0, poly = false, unit = .Decibels)
		add(d(.Mix), name(e, "Mix"), 0, 1, 1, poly = false)
		add(d(.Filter_Order), name(e, "Filter"), 0, 2, 0, .Indexed, false)
		add(d(.Cutoff), name(e, "Cutoff"), 8, 136, 80, poly = false)
		add(d(.Resonance), name(e, "Resonance"), 0, 1, 0.5, poly = false)
		add(d(.Blend), name(e, "Blend"), 0, 2, 0, poly = false)
	}
	{
		e :: fx.Effect.Eq
		bands := [3]string{"Low", "Band", "High"}
		def := fx.EQ_DEFAULTS
		add(effect_param(e, Eq_Field.On), name(e, "On"), 0, 1, 0, .Indexed, false)
		for b in 0 ..< 3 {
			at := int(Eq_Field.Low_Mode) + b * 4
			id :: proc(at, k: int) -> core.Param_Id { return effect_param(e, Eq_Field(at + k)) }
			add(id(at, 0), fmt.aprintf("EQ %s Mode", bands[b]), 0, 1, 0, .Indexed, false)
			add(id(at, 1), fmt.aprintf("EQ %s Cutoff", bands[b]), 8, 136, def.bands[b].cutoff, poly = false)
			add(id(at, 2), fmt.aprintf("EQ %s Gain", bands[b]), -15, 15, 0, poly = false, unit = .Decibels)
			add(id(at, 3), fmt.aprintf("EQ %s Resonance", bands[b]), 0, 1, def.bands[b].resonance, poly = false)
		}
	}
	{
		e :: fx.Effect.Filter
		f :: proc(x: Fx_Filter_Field) -> core.Param_Id { return effect_param(e, x) }
		add(f(.On), name(e, "On"), 0, 1, 0, .Indexed, false)
		add(f(.Model), name(e, "Model"), 0, f32(len(fx.Filter_Model) - 1), 0, .Indexed, false)
		add(f(.Style), name(e, "Style"), 0, 5, 0, .Indexed, false)
		add(f(.Cutoff), name(e, "Cutoff"), 8, 136, 60, poly = false)
		add(f(.Resonance), name(e, "Resonance"), 0, 1, 0.5, poly = false)
		add(f(.Drive), name(e, "Drive"), 0, 20, 0, poly = false, unit = .Decibels)
		add(f(.Blend), name(e, "Blend"), 0, 2, 0, poly = false)
		add(f(.Mix), name(e, "Mix"), 0, 1, 1, poly = false)
		add(f(.Gain), name(e, "Shelf Gain"), -15, 15, 0, poly = false, unit = .Decibels)
		add(f(.Formant_X), name(e, "Formant X"), 0, 1, 0.5, poly = false)
		add(f(.Formant_Y), name(e, "Formant Y"), 0, 1, 0.5, poly = false)
		add(f(.Formant_Transpose), name(e, "Formant Transpose"), -12, 12, 0, poly = false)
		add(f(.Formant_Resonance), name(e, "Formant Resonance"), 0.3, 1, 0.85, poly = false)
		add(f(.Formant_Spread), name(e, "Formant Spread"), -1, 1, 0, poly = false)
		add(f(.Comb_Offset), name(e, "Comb Offset"), 0, 84, 42, poly = false)
	}
	{
		e :: fx.Effect.Flanger
		f :: proc(x: Flanger_Field) -> core.Param_Id { return effect_param(e, x) }
		add(f(.On), name(e, "On"), 0, 1, 0, .Indexed, false)
		add(f(.Sync), name(e, "Sync"), 0, sync_max, 0, .Indexed, false)
		add(f(.Hz), name(e, "Frequency"), -8, 3, 1, .Exponential, false)
		add(f(.Tempo), name(e, "Tempo"), 0, 12, 6, .Indexed, false)
		add(f(.Center), name(e, "Center"), 8, 136, 64, poly = false)
		add(f(.Feedback), name(e, "Feedback"), -1, 1, 0.5, poly = false)
		add(f(.Wet), name(e, "Mix"), 0, 0.5, 0.5, poly = false)
		add(f(.Depth), name(e, "Depth"), 0, 1, 0.5, poly = false)
		add(f(.Offset), name(e, "Offset"), 0, 1, 0.3333, poly = false)
	}
	{
		e :: fx.Effect.Phaser
		f :: proc(x: Phaser_Field) -> core.Param_Id { return effect_param(e, x) }
		add(f(.On), name(e, "On"), 0, 1, 0, .Indexed, false)
		add(f(.Sync), name(e, "Sync"), 0, sync_max, 0, .Indexed, false)
		add(f(.Hz), name(e, "Frequency"), -8, 3, -3, .Exponential, false)
		add(f(.Tempo), name(e, "Tempo"), 0, 12, 4, .Indexed, false)
		add(f(.Feedback), name(e, "Feedback"), 0, 1, 0.5, poly = false)
		add(f(.Wet), name(e, "Mix"), 0, 1, 1, poly = false)
		add(f(.Center), name(e, "Center"), 8, 136, 80, poly = false)
		add(f(.Blend), name(e, "Blend"), 0, 2, 1, poly = false)
		add(f(.Depth), name(e, "Depth"), 0, 48, 24, poly = false)
		add(f(.Offset), name(e, "Offset"), 0, 1, 0.3333, poly = false)
	}
	{
		e :: fx.Effect.Reverb
		f :: proc(x: Reverb_Field) -> core.Param_Id { return effect_param(e, x) }
		add(f(.On), name(e, "On"), 0, 1, 0, .Indexed, false)
		add(f(.Wet), name(e, "Mix"), 0, 1, 0.25, poly = false)
		add(f(.Decay), name(e, "Decay"), -3.32, 6.64, 0, .Exponential, false)
		add(f(.Size), name(e, "Size"), 0, 1, 0.5, poly = false)
		add(f(.Delay), name(e, "Pre-Delay"), 0, 0.3, 0, poly = false)
		add(f(.Pre_Low), name(e, "Low Cut"), 0, 130, 0, poly = false)
		add(f(.Pre_High), name(e, "High Cut"), 0, 130, 110, poly = false)
		add(f(.Low_Cutoff), name(e, "Low Shelf Cutoff"), 0, 130, 0, poly = false)
		add(f(.Low_Gain), name(e, "Low Shelf Gain"), -6, 0, 0, poly = false, unit = .Decibels)
		add(f(.High_Cutoff), name(e, "High Shelf Cutoff"), 0, 130, 90, poly = false)
		add(f(.High_Gain), name(e, "High Shelf Gain"), -6, 0, -1, poly = false, unit = .Decibels)
		add(f(.Chorus), name(e, "Chorus"), 0, 1, 0.05, poly = false)
		add(f(.Chorus_Hz), name(e, "Chorus Frequency"), -8, 3, -2, .Exponential, false)
	}
}

// Effect parameter values to read: plain values by id (`PARAM_SLOTS` of
// them) and, optionally, the effects' modulation (from `FX_BASE` on).
@(private)
Fx_Values :: struct {
	values: []f32,
	mod:    []f32,
}

// [rt] An effect parameter's value: its plain value and its modulation,
// put through its curve.
@(private)
fvalue :: #force_inline proc "contextless" (s: ^Fx_Values, id: core.Param_Id) -> f32 {
	spec := param_spec(id)
	if spec == nil do return 0
	m: f32 = s.mod[int(id) - FX_BASE] if s.mod != nil else 0
	return param_curve(spec, s.values[id] + m)
}

// [rt] The chain's settings from plain parameter values (by id, as a
// patch holds them), the effects in `order`, synced to `bpm`: what a
// synth with those values runs (less its modulation).
effect_chain_params :: proc "contextless" (values: []f32, order: [len(fx.Effect)]fx.Effect, bpm: f64) -> fx.Chain_Params {
	v := Fx_Values{values = values}
	return chain_params_of(&v, order, bpm)
}

// [rt] The chain's settings now: the patch's order, each effect from
// its parameters and their modulation.
@(private)
chain_params :: proc "contextless" (s: ^Synth) -> fx.Chain_Params {
	v := Fx_Values{values = s.values[:], mod = s.fx_mod[:]}
	return chain_params_of(&v, s.patch.fx_order if s.patch != nil else fx.CHAIN_ORDER, s.bpm)
}

@(private)
chain_params_of :: proc "contextless" (s: ^Fx_Values, order: [len(fx.Effect)]fx.Effect, bpm: f64) -> fx.Chain_Params {
	p: fx.Chain_Params
	p.order = order
	for e in fx.Effect do if fvalue(s, effect_param(e, Chorus_Field.On)) > 0 do p.on += {e} // (On is field 0 of each)
	rate :: proc "contextless" (s: ^Fx_Values, sync, hz, tempo: core.Param_Id, bpm: f64) -> f32 {
		return fx.sync_hz(fx.Sync(int(fvalue(s, sync))), fvalue(s, hz), int(fvalue(s, tempo)), bpm)
	}
	{
		c :: proc "contextless" (f: Chorus_Field) -> core.Param_Id { return effect_param(.Chorus, f) }
		p.chorus = {
			voices = int(fvalue(s, c(.Voices))), hz = rate(s, c(.Sync), c(.Hz), c(.Tempo), bpm),
			feedback = fvalue(s, c(.Feedback)), wet = fvalue(s, c(.Wet)), cutoff = fvalue(s, c(.Cutoff)),
			spread = fvalue(s, c(.Spread)), depth = fvalue(s, c(.Depth)), delay = {fvalue(s, c(.Delay_1)), fvalue(s, c(.Delay_2))},
		}
	}
	{
		c :: proc "contextless" (f: Compressor_Field) -> core.Param_Id { return effect_param(.Compressor, f) }
		p.compressor = {
			bands = fx.Compressor_Bands(int(fvalue(s, c(.Bands)))),
			attack = fvalue(s, c(.Attack)), release = fvalue(s, c(.Release)), mix = fvalue(s, c(.Mix)),
		}
		for b in 0 ..< 3 {
			at := int(Compressor_Field.Low_Upper) + b * 5
			p.compressor.band[b] = {
				upper_db = fvalue(s, c(Compressor_Field(at))), lower_db = fvalue(s, c(Compressor_Field(at + 1))),
				upper_ratio = fvalue(s, c(Compressor_Field(at + 2))), lower_ratio = fvalue(s, c(Compressor_Field(at + 3))),
				gain_db = fvalue(s, c(Compressor_Field(at + 4))),
			}
		}
	}
	{
		d :: proc "contextless" (f: Delay_Field) -> core.Param_Id { return effect_param(.Delay, f) }
		style := fx.Delay_Style(int(fvalue(s, d(.Style))))
		left := rate(s, d(.Sync), d(.Hz), d(.Tempo), bpm)
		right := rate(s, d(.Sync), d(.Hz_Right), d(.Tempo_Right), bpm)
		if style == .Mono do right = left
		p.delay = {
			style = style, wet = fvalue(s, d(.Wet)), feedback = fvalue(s, d(.Feedback)), hz = {left, right},
			cutoff = fvalue(s, d(.Cutoff)), spread = fvalue(s, d(.Spread)),
		}
	}
	{
		d :: proc "contextless" (f: Distortion_Field) -> core.Param_Id { return effect_param(.Distortion, f) }
		p.distortion = {
			type = fx.Distortion_Type(int(fvalue(s, d(.Type)))), drive_db = fvalue(s, d(.Drive)), mix = fvalue(s, d(.Mix)),
			order = fx.Filter_Order(int(fvalue(s, d(.Filter_Order)))), cutoff = fvalue(s, d(.Cutoff)),
			resonance = fvalue(s, d(.Resonance)), blend = fvalue(s, d(.Blend)),
		}
	}
	for b in 0 ..< 3 {
		at := int(Eq_Field.Low_Mode) + b * 4
		q :: proc "contextless" (at, k: int) -> core.Param_Id { return effect_param(.Eq, Eq_Field(at + k)) }
		p.eq.bands[b] = {
			mode = fx.Eq_Mode(int(fvalue(s, q(at, 0)))), cutoff = fvalue(s, q(at, 1)),
			gain_db = fvalue(s, q(at, 2)), resonance = fvalue(s, q(at, 3)),
		}
	}
	{
		f :: proc "contextless" (x: Fx_Filter_Field) -> core.Param_Id { return effect_param(.Filter, x) }
		p.filter.filter = {
			model = fx.Filter_Model(int(fvalue(s, f(.Model)))), style = fx.Filter_Style(int(fvalue(s, f(.Style)))),
			cutoff = fvalue(s, f(.Cutoff)), resonance = fvalue(s, f(.Resonance)), drive_db = fvalue(s, f(.Drive)),
			blend = fvalue(s, f(.Blend)), mix = fvalue(s, f(.Mix)), gain_db = fvalue(s, f(.Gain)),
			formant_x = fvalue(s, f(.Formant_X)), formant_y = fvalue(s, f(.Formant_Y)),
			formant_transpose = fvalue(s, f(.Formant_Transpose)), formant_resonance = fvalue(s, f(.Formant_Resonance)),
			formant_spread = fvalue(s, f(.Formant_Spread)), comb_offset = fvalue(s, f(.Comb_Offset)),
		}
	}
	{
		f :: proc "contextless" (x: Flanger_Field) -> core.Param_Id { return effect_param(.Flanger, x) }
		p.flanger = {
			hz = rate(s, f(.Sync), f(.Hz), f(.Tempo), bpm), center = fvalue(s, f(.Center)), feedback = fvalue(s, f(.Feedback)),
			wet = fvalue(s, f(.Wet)), depth = fvalue(s, f(.Depth)), offset = fvalue(s, f(.Offset)),
		}
	}
	{
		f :: proc "contextless" (x: Phaser_Field) -> core.Param_Id { return effect_param(.Phaser, x) }
		p.phaser = {
			hz = rate(s, f(.Sync), f(.Hz), f(.Tempo), bpm), feedback = fvalue(s, f(.Feedback)), wet = fvalue(s, f(.Wet)),
			center = fvalue(s, f(.Center)), blend = fvalue(s, f(.Blend)), depth = fvalue(s, f(.Depth)), offset = fvalue(s, f(.Offset)),
		}
	}
	{
		f :: proc "contextless" (x: Reverb_Field) -> core.Param_Id { return effect_param(.Reverb, x) }
		p.reverb = {
			wet = fvalue(s, f(.Wet)), decay = fvalue(s, f(.Decay)), size = fvalue(s, f(.Size)), delay = fvalue(s, f(.Delay)),
			pre_low = fvalue(s, f(.Pre_Low)), pre_high = fvalue(s, f(.Pre_High)),
			low_cutoff = fvalue(s, f(.Low_Cutoff)), low_gain_db = fvalue(s, f(.Low_Gain)),
			high_cutoff = fvalue(s, f(.High_Cutoff)), high_gain_db = fvalue(s, f(.High_Gain)),
			chorus = fvalue(s, f(.Chorus)), chorus_hz = fvalue(s, f(.Chorus_Hz)),
		}
	}
	return p
}

