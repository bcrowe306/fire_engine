package pads_model

import fc "fire:core"
import "fire:fx"

// Factory effect presets: an effect's settings by name, in the Library
// under their effect (Effects), loaded into a slot as one undo step.

// A factory effect preset: its effect, its settings (the others at their
// defaults), its key's filters, and what it does.
Effect_Preset :: struct {
	name:    string,
	kind:    Effect_Kind,
	info:    string,
	params:  []Slot_Param,
	key_hpf: f32,
	key_lpf: f32,
}

// SuperFilter's parameters, shorter.
@(private = "file") TYPE :: fx.SF_PARAM_TYPE
@(private = "file") CIRCUIT :: fx.SF_PARAM_CIRCUIT
@(private = "file") FREQ :: fx.SF_PARAM_FREQ_HZ
@(private = "file") RES :: fx.SF_PARAM_RESONANCE
@(private = "file") MORPH :: fx.SF_PARAM_MORPH
@(private = "file") SLOPE :: fx.SF_PARAM_SLOPE
@(private = "file") DRIVE :: fx.SF_PARAM_DRIVE_DB
@(private = "file") LFO :: fx.SF_PARAM_LFO_AMOUNT
@(private = "file") HZ :: fx.SF_PARAM_LFO_RATE_HZ
@(private = "file") MODE :: fx.SF_PARAM_LFO_MODE
@(private = "file") DIV :: fx.SF_PARAM_LFO_DIVISION
@(private = "file") SIXTEENTHS :: fx.SF_PARAM_LFO_SIXTEENTHS
@(private = "file") WAVE :: fx.SF_PARAM_LFO_WAVE
@(private = "file") STEREO :: fx.SF_PARAM_LFO_STEREO
@(private = "file") PHASE :: fx.SF_PARAM_LFO_PHASE_DEG
@(private = "file") SPIN :: fx.SF_PARAM_LFO_SPIN_HZ
@(private = "file") ENV :: fx.SF_PARAM_ENV_AMOUNT
@(private = "file") ATTACK :: fx.SF_PARAM_ENV_ATTACK_MS
@(private = "file") RELEASE :: fx.SF_PARAM_ENV_RELEASE_MS
@(private = "file") HOLD :: fx.SF_PARAM_ENV_HOLD
@(private = "file") MIX :: fx.SF_PARAM_MIX

// The factory effect presets, by effect.
EFFECT_PRESETS := [?]Effect_Preset {
	{name = "Wobble 1/8", kind = .Super_Filter, info = "A resonant low-pass swung by a synced sine, eighths", params = {
		{TYPE, 0}, {CIRCUIT, 1}, {FREQ, 400}, {RES, 0.55}, {SLOPE, 1}, {LFO, 0.45}, {MODE, 1}, {DIV, 9}, {WAVE, 0},
	}},
	{name = "Wobble 1/4 Triplet", kind = .Super_Filter, info = "A ladder low-pass on a triangle, quarter-note triplets", params = {
		{TYPE, 0}, {CIRCUIT, 3}, {FREQ, 300}, {RES, 0.6}, {LFO, 0.5}, {MODE, 3}, {DIV, 8}, {WAVE, 1},
	}},
	{name = "Duck to Kick", kind = .Super_Filter, info = "Closes as the key hits (choose the kick in Sidechain): its body through the key's high cut", key_lpf = 150, params = {
		{TYPE, 0}, {CIRCUIT, 1}, {FREQ, 12_000}, {RES, 0.1}, {LFO, 0}, {ENV, -0.7}, {ATTACK, 1}, {RELEASE, 180}, {HOLD, 1},
	}},
	{name = "DJ Sweep", kind = .Super_Filter, info = "One knob: low-pass to the left, high-pass to the right, flat in the middle", params = {
		{TYPE, 6}, {FREQ, 632}, {RES, 0.3}, {LFO, 0},
	}},
	{name = "Talk Box", kind = .Super_Filter, info = "Vowels drifting on a slow, smooth random LFO", params = {
		{TYPE, 8}, {MORPH, 0.3}, {RES, 0.7}, {LFO, 0.12}, {MODE, 0}, {HZ, 0.3}, {WAVE, 6},
	}},
	{name = "Comb Shimmer", kind = .Super_Filter, info = "A comb drifting slowly, the sides apart, half wet", params = {
		{TYPE, 7}, {FREQ, 800}, {MORPH, 0.75}, {LFO, 0.08}, {MODE, 0}, {HZ, 0.2}, {STEREO, 0}, {PHASE, 90}, {MIX, 0.6},
	}},
	{name = "Random Steps", kind = .Super_Filter, info = "A dirty low-pass on a new random value every sixteenth", params = {
		{TYPE, 0}, {CIRCUIT, 2}, {FREQ, 900}, {RES, 0.45}, {DRIVE, 6}, {LFO, 0.35}, {MODE, 1}, {DIV, 10}, {WAVE, 5},
	}},
	{name = "Slow Pad Sweep", kind = .Super_Filter, info = "A clean 24 dB low-pass opening and closing over four bars", params = {
		{TYPE, 0}, {CIRCUIT, 0}, {FREQ, 800}, {RES, 0.35}, {SLOPE, 1}, {LFO, 0.4}, {MODE, 4}, {SIXTEENTHS, 64}, {WAVE, 0},
	}},
	{name = "Auto-Wah", kind = .Super_Filter, info = "A band-pass opened by how hard it is played", params = {
		{TYPE, 2}, {CIRCUIT, 1}, {FREQ, 350}, {RES, 0.6}, {LFO, 0}, {ENV, 0.55}, {ATTACK, 5}, {RELEASE, 120},
	}},
	{name = "Stereo Spin", kind = .Super_Filter, info = "Each side's cutoff on its own rate: they drift apart and back", params = {
		{TYPE, 0}, {CIRCUIT, 1}, {FREQ, 1200}, {RES, 0.4}, {LFO, 0.3}, {MODE, 0}, {HZ, 0.5}, {STEREO, 1}, {SPIN, 0.15},
	}},
}

// A slot holding factory effect preset `p`, on.
effect_preset_slot :: proc(p: Effect_Preset) -> Effect_Slot {
	s := new_effect(p.kind)
	for x in p.params do slot_set(&s, fc.Param_Id(x.id), x.value)
	s.key_hpf, s.key_lpf = p.key_hpf, p.key_lpf
	return s
}
