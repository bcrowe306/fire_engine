package pads_model

import fc "fire:core"
import "fire:fx"

// Factory effect presets: an effect's settings by name, in the Library
// under their effect (Effects), loaded into a slot as one undo step.

// A factory effect preset: its effect, its settings (the others at their
// defaults), its key's filters, and what it does.
Effect_Preset :: struct {
	name:     string,
	kind:     Effect_Kind,
	info:     string,
	category: string, // its group in the device's Presets menu ("" none: ProVerb's have them)
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

// ProEq's parameters, shorter: band n's (1..8) first id in set A (PB*)
// or B (PBB*), plus a field's offset.
@(private = "file") PB1 :: fc.Param_Id(6)
@(private = "file") PB2 :: PB1 + 6
@(private = "file") PB3 :: PB1 + 12
@(private = "file") PB4 :: PB1 + 18
@(private = "file") PB5 :: PB1 + 24
@(private = "file") PB6 :: PB1 + 30
@(private = "file") PB7 :: PB1 + 36
@(private = "file") PB8 :: PB1 + 42
@(private = "file") PBB1 :: PB1 + 48
@(private = "file") PBB7 :: PB7 + 48
@(private = "file") F_ON :: 0
@(private = "file") F_TYPE :: 1
@(private = "file") F_SLOPE :: 2
@(private = "file") F_HZ :: 3
@(private = "file") F_DB :: 4
@(private = "file") F_Q :: 5
// ProEq's band types and slopes, as numbers.
@(private = "file") T_BELL :: 2
@(private = "file") T_BAND :: 6
@(private = "file") T_TILT :: 7
@(private = "file") S_24 :: 1

// ProComp's parameters, shorter.
@(private = "file") C_TH :: fx.PC_PARAM_THRESHOLD_DB
@(private = "file") C_RATIO :: fx.PC_PARAM_RATIO
@(private = "file") C_ATT :: fx.PC_PARAM_ATTACK_MS
@(private = "file") C_REL :: fx.PC_PARAM_RELEASE_MS
@(private = "file") C_AUTO :: fx.PC_PARAM_AUTO
@(private = "file") C_KNEE :: fx.PC_PARAM_KNEE_DB
@(private = "file") C_LOOK :: fx.PC_PARAM_LOOKAHEAD
@(private = "file") C_MODE :: fx.PC_PARAM_MODE
@(private = "file") C_MAKEUP :: fx.PC_PARAM_MAKEUP
@(private = "file") C_OUT :: fx.PC_PARAM_OUTPUT_DB
@(private = "file") C_MIX :: fx.PC_PARAM_MIX
@(private = "file") C_EQ :: fx.PC_PARAM_EQ_ON
@(private = "file") C_EQ_TYPE :: fx.PC_PARAM_EQ_TYPE
@(private = "file") C_EQ_HZ :: fx.PC_PARAM_EQ_HZ
@(private = "file") C_EQ_Q :: fx.PC_PARAM_EQ_Q

// ProSaturator's parameters, shorter, and its types as numbers.
@(private = "file") S_TYPE :: fx.PS_PARAM_TYPE
@(private = "file") S_DRIVE :: fx.PS_PARAM_DRIVE_DB
@(private = "file") S_COLOR :: fx.PS_PARAM_COLOR
@(private = "file") S_FREQ :: fx.PS_PARAM_FREQ_HZ
@(private = "file") S_WIDTH :: fx.PS_PARAM_WIDTH
@(private = "file") S_DEPTH :: fx.PS_PARAM_DEPTH
@(private = "file") S_BASE :: fx.PS_PARAM_BASE
@(private = "file") S_SOFT :: fx.PS_PARAM_SOFT_CLIP
@(private = "file") S_OUT :: fx.PS_PARAM_OUTPUT_DB
@(private = "file") S_MIX :: fx.PS_PARAM_MIX
@(private = "file") S_QUALITY :: fx.PS_PARAM_QUALITY
@(private = "file") S_WS_DRIVE :: fx.PS_PARAM_WS_DRIVE
@(private = "file") S_WS_DEPTH :: fx.PS_PARAM_WS_DEPTH
@(private = "file") S_WS_PERIOD :: fx.PS_PARAM_WS_PERIOD
@(private = "file") S_WS_LIN :: fx.PS_PARAM_WS_LIN

// ProVerb's parameters, shorter.
@(private = "file") V_MIX :: fx.PV_PARAM_MIX
@(private = "file") V_PRE :: fx.PV_PARAM_PREDELAY_MS
@(private = "file") V_DECAY :: fx.PV_PARAM_DECAY_S
@(private = "file") V_CUT :: fx.PV_PARAM_HIGH_CUT_HZ
@(private = "file") V_DEPTH :: fx.PV_PARAM_DEPTH
@(private = "file") V_ESIZE :: fx.PV_PARAM_EARLY_SIZE
@(private = "file") V_SEND :: fx.PV_PARAM_EARLY_SEND
@(private = "file") V_LSIZE :: fx.PV_PARAM_LATE_SIZE
@(private = "file") V_MODD :: fx.PV_PARAM_LATE_MOD_DEPTH
@(private = "file") V_BASS :: fx.PV_PARAM_BASS_MULT
@(private = "file") V_HIGH :: fx.PV_PARAM_HIGH_MULT
@(private = "file") V_HX :: fx.PV_PARAM_HIGH_XOVER_HZ
@(private = "file") V_MODE :: fx.PV_PARAM_MODE
@(private = "file") V_ECROSS :: fx.PV_PARAM_EARLY_CROSS
@(private = "file") V_EMODR :: fx.PV_PARAM_EARLY_MOD_RATE
@(private = "file") V_EMODD :: fx.PV_PARAM_EARLY_MOD_DEPTH
@(private = "file") V_LCROSS :: fx.PV_PARAM_LATE_CROSS
@(private = "file") V_LMODR :: fx.PV_PARAM_LATE_MOD_RATE
@(private = "file") V_BX :: fx.PV_PARAM_BASS_XOVER_HZ
@(private = "file") V_DIFF :: fx.PV_PARAM_DIFFUSION

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
	{name = "Clean Low End", kind = .Pro_Eq, info = "A 24 dB low cut at 30 Hz: the rumble gone, the rest as it was", params = {
		{PB1 + F_ON, 1}, {PB1 + F_SLOPE, S_24}, {PB1 + F_HZ, 30},
	}},
	{name = "Kick Punch", kind = .Pro_Eq, info = "Sub weight, the boxiness out, the beater forward", params = {
		{PB1 + F_ON, 1}, {PB1 + F_SLOPE, S_24}, {PB1 + F_HZ, 25},
		{PB2 + F_TYPE, T_BELL}, {PB2 + F_HZ, 60}, {PB2 + F_DB, 3}, {PB2 + F_Q, 1.2},
		{PB3 + F_HZ, 350}, {PB3 + F_DB, -4}, {PB3 + F_Q, 1.4},
		{PB5 + F_HZ, 3500}, {PB5 + F_DB, 3}, {PB5 + F_Q, 1.5},
	}},
	{name = "Snare Body and Crack", kind = .Pro_Eq, info = "Its body at 200 Hz, less ring, the crack at 5 kHz", params = {
		{PB1 + F_ON, 1}, {PB1 + F_HZ, 80},
		{PB3 + F_HZ, 200}, {PB3 + F_DB, 3}, {PB3 + F_Q, 1.2},
		{PB4 + F_HZ, 900}, {PB4 + F_DB, -2},
		{PB5 + F_HZ, 5000}, {PB5 + F_DB, 4}, {PB5 + F_Q, 1},
	}},
	{name = "Vocal Presence", kind = .Pro_Eq, info = "The lows cut, less mud, presence at 3 kHz and a little air", params = {
		{PB1 + F_ON, 1}, {PB1 + F_SLOPE, S_24}, {PB1 + F_HZ, 90},
		{PB3 + F_HZ, 250}, {PB3 + F_DB, -2}, {PB3 + F_Q, 1},
		{PB5 + F_HZ, 3000}, {PB5 + F_DB, 3}, {PB5 + F_Q, 0.9},
		{PB7 + F_HZ, 10_000}, {PB7 + F_DB, 2},
	}},
	{name = "De-mud", kind = .Pro_Eq, info = "A cut at 300 Hz, where a mix clouds over", params = {
		{PB3 + F_HZ, 300}, {PB3 + F_DB, -5}, {PB3 + F_Q, 1.2},
	}},
	{name = "Air", kind = .Pro_Eq, info = "A gentle high shelf at 12 kHz", params = {
		{PB7 + F_HZ, 12_000}, {PB7 + F_DB, 4},
	}},
	{name = "Telephone", kind = .Pro_Eq, info = "Only the band a phone carries: 300 Hz to 3.4 kHz", params = {
		{PB1 + F_ON, 1}, {PB1 + F_SLOPE, S_24}, {PB1 + F_HZ, 300},
		{PB4 + F_TYPE, T_BAND}, {PB4 + F_HZ, 1500}, {PB4 + F_Q, 0.8},
		{PB8 + F_ON, 1}, {PB8 + F_SLOPE, S_24}, {PB8 + F_HZ, 3400},
	}},
	{name = "Mid/Side Widen", kind = .Pro_Eq, info = "M/S: the mid's lows cleaned, the side's lows cut and its highs lifted", params = {
		{fx.PE_PARAM_MODE, 2},
		{PB1 + F_ON, 1}, {PB1 + F_SLOPE, S_24}, {PB1 + F_HZ, 40},
		{PBB1 + F_ON, 1}, {PBB1 + F_SLOPE, S_24}, {PBB1 + F_HZ, 200},
		{PBB7 + F_HZ, 8000}, {PBB7 + F_DB, 4},
	}},
	{name = "Master Polish", kind = .Pro_Eq, info = "A gentle tilt up through 1 kHz, a low cut and a touch of air", params = {
		{PB1 + F_ON, 1}, {PB1 + F_SLOPE, S_24}, {PB1 + F_HZ, 25},
		{PB4 + F_TYPE, T_TILT}, {PB4 + F_HZ, 1000}, {PB4 + F_DB, 1.5},
		{PB7 + F_HZ, 12_000}, {PB7 + F_DB, 1},
	}},
	{name = "Hi-Hat Tame", kind = .Pro_Eq, info = "Its lows cut, the hiss at 8 kHz down, the top rolled off", params = {
		{PB1 + F_ON, 1}, {PB1 + F_HZ, 300},
		{PB6 + F_TYPE, T_BELL}, {PB6 + F_HZ, 8000}, {PB6 + F_DB, -4}, {PB6 + F_Q, 2},
		{PB8 + F_ON, 1}, {PB8 + F_HZ, 14_000},
	}},
	{name = "Glue Bus", kind = .Pro_Comp, info = "2:1, a slow attack and an auto release: a mix held together", params = {
		{C_TH, -18}, {C_RATIO, 2}, {C_ATT, 30}, {C_AUTO, 1}, {C_KNEE, 6}, {C_MAKEUP, 1},
	}},
	{name = "Drum Punch", kind = .Pro_Comp, info = "4:1 with a 10 ms attack: the hit through, the body squeezed", params = {
		{C_TH, -20}, {C_RATIO, 4}, {C_ATT, 10}, {C_REL, 80}, {C_KNEE, 3}, {C_MAKEUP, 1},
	}},
	{name = "Vocal Leveler", kind = .Pro_Comp, info = "3:1 on the RMS level: an even voice", params = {
		{C_TH, -24}, {C_RATIO, 3}, {C_ATT, 5}, {C_REL, 150}, {C_MODE, 1}, {C_KNEE, 9}, {C_MAKEUP, 1},
	}},
	{name = "Kick Duck", kind = .Pro_Comp, info = "Ducks hard when the key hits (choose the kick in Sidechain)", params = {
		{C_TH, -30}, {C_RATIO, 8}, {C_ATT, 1}, {C_REL, 180}, {C_KNEE, 0},
	}},
	{name = "Parallel Smash", kind = .Pro_Comp, info = "Crushed flat and fast, a third of it mixed under the dry", params = {
		{C_TH, -36}, {C_RATIO, 100}, {C_ATT, 0.5}, {C_REL, 60}, {C_KNEE, 0}, {C_MAKEUP, 1}, {C_MIX, 0.35},
	}},
	{name = "Bass Control", kind = .Pro_Comp, info = "4:1 looking 1 ms ahead: no note jumps out", params = {
		{C_TH, -22}, {C_RATIO, 4}, {C_ATT, 3}, {C_REL, 120}, {C_LOOK, 1}, {C_MAKEUP, 1},
	}},
	{name = "Gentle Master", kind = .Pro_Comp, info = "1.5:1 with a soft knee and an auto release, a decibel or two", params = {
		{C_TH, -14}, {C_RATIO, 1.5}, {C_ATT, 30}, {C_AUTO, 1}, {C_KNEE, 12}, {C_MAKEUP, 1},
	}},
	{name = "Snare Snap", kind = .Pro_Comp, info = "Expand under its body: the ring between hits turned down", params = {
		{C_TH, -28}, {C_RATIO, 3}, {C_ATT, 0.5}, {C_REL, 60}, {C_MODE, 2}, {C_KNEE, 6},
	}},
	{name = "Pumping 4/4", kind = .Pro_Comp, info = "A deep duck with a long release, breathing on the beat (choose the kick in Sidechain)", params = {
		{C_TH, -34}, {C_RATIO, 10}, {C_ATT, 2}, {C_REL, 400}, {C_KNEE, 3}, {C_OUT, 2},
	}},
	{name = "De-ess", kind = .Pro_Comp, info = "Listens through a band-pass at 6.5 kHz: only the esses pressed", params = {
		{C_TH, -30}, {C_RATIO, 6}, {C_ATT, 0.5}, {C_REL, 60}, {C_EQ, 1}, {C_EQ_TYPE, 1}, {C_EQ_HZ, 6500}, {C_EQ_Q, 2},
	}},
	{name = "Warm Bus", kind = .Pro_Saturator, info = "Analog Clip, a little driven: warmth and a softer top", params = {
		{S_TYPE, 0}, {S_DRIVE, 4}, {S_OUT, -2}, {S_QUALITY, 1},
	}},
	{name = "Tube Glow", kind = .Pro_Saturator, info = "Tube's even harmonics, soft clipped at the end", params = {
		{S_TYPE, 7}, {S_DRIVE, 9}, {S_SOFT, 1}, {S_OUT, -5}, {S_QUALITY, 1},
	}},
	{name = "Tape Kiss", kind = .Pro_Saturator, info = "Tape, gently: rounder and a touch darker", params = {
		{S_TYPE, 8}, {S_DRIVE, 6}, {S_OUT, -3},
	}},
	{name = "Bass Weight", kind = .Pro_Saturator, info = "Bass Shaper with its lows pushed into the curve", params = {
		{S_TYPE, 2}, {S_DRIVE, 8}, {S_COLOR, 1}, {S_BASE, 0.5}, {S_OUT, -4}, {S_QUALITY, 1},
	}},
	{name = "Fuzz", kind = .Pro_Saturator, info = "Hard Curve, driven a long way, soft clipped", params = {
		{S_TYPE, 4}, {S_DRIVE, 30}, {S_SOFT, 1}, {S_OUT, -12}, {S_QUALITY, 2},
	}},
	{name = "Fold Lead", kind = .Pro_Saturator, info = "Sinoid Fold: past the top the wave folds back, metallic", params = {
		{S_TYPE, 5}, {S_DRIVE, 14}, {S_SOFT, 1}, {S_OUT, -6}, {S_QUALITY, 2},
	}},
	{name = "Digital Crunch", kind = .Pro_Saturator, info = "Digital Clip with no oversampling: hard and aliased", params = {
		{S_TYPE, 6}, {S_DRIVE, 18}, {S_OUT, -14},
	}},
	{name = "Presence Drive", kind = .Pro_Saturator, info = "Medium Curve with 3 kHz pushed into it: bite without more top", params = {
		{S_TYPE, 3}, {S_DRIVE, 10}, {S_COLOR, 1}, {S_FREQ, 3000}, {S_WIDTH, 0.4}, {S_DEPTH, 0.8}, {S_OUT, -6}, {S_QUALITY, 1},
	}},
	{name = "Parallel Grit", kind = .Pro_Saturator, info = "Hard Curve, crushed, 30 % under the dry", params = {
		{S_TYPE, 4}, {S_DRIVE, 24}, {S_MIX, 0.3}, {S_OUT, -8}, {S_QUALITY, 1},
	}},
	{name = "Shaper Bells", kind = .Pro_Saturator, info = "The Waveshaper's sine part up: bell-like overtones", params = {
		{S_TYPE, 9}, {S_DRIVE, 6}, {S_WS_DRIVE, 0.5}, {S_WS_LIN, 0.6}, {S_WS_DEPTH, 0.5}, {S_WS_PERIOD, 0.3}, {S_SOFT, 1}, {S_OUT, -4}, {S_QUALITY, 2},
	}},
	{name = "Drum Room", kind = .Proverb, category = "Drums", info = "A tight room on a send: the kit in a space, not a wash", params = {
		{V_MIX, 1}, {V_MODE, 5}, {V_DECAY, 0.7}, {V_PRE, 5}, {V_LSIZE, 0.3}, {V_ESIZE, 0.2}, {V_DEPTH, 0.35}, {V_HIGH, 0.6},
	}},
	{name = "Vocal Plate-ish", kind = .Proverb, category = "Vocals", info = "Bright and smooth, a little predelay to keep the words clear", params = {
		{V_MIX, 1}, {V_MODE, 2}, {V_DECAY, 1.8}, {V_PRE, 40}, {V_LSIZE, 0.45}, {V_DEPTH, 0.75}, {V_CUT, 11_000}, {V_HIGH, 0.7},
	}},
	{name = "Big Room", kind = .Proverb, category = "Rooms", info = "The first mode as it comes: a large, natural room", params = {
		{V_MIX, 1}, {V_MODE, 0}, {V_DECAY, 2}, {V_PRE, 10},
	}},
	{name = "Chamber", kind = .Proverb, category = "Chambers", info = "A wide chamber, warm, the early part forward", params = {
		{V_MIX, 1}, {V_MODE, 3}, {V_DECAY, 2.4}, {V_PRE, 15}, {V_DEPTH, 0.45}, {V_BASS, 1.2}, {V_HIGH, 0.45},
	}},
	{name = "Grand Hall", kind = .Proverb, category = "Halls", info = "A long hall, dark at the top, slow to bloom", params = {
		{V_MIX, 1}, {V_MODE, 9}, {V_DECAY, 4.5}, {V_PRE, 30}, {V_LSIZE, 0.85}, {V_DEPTH, 0.8}, {V_HIGH, 0.35}, {V_HX, 5000},
	}},
	{name = "Ambience", kind = .Proverb, category = "Ambiences", info = "Hardly a tail: space around a sound without a reverb you hear", params = {
		{V_MIX, 0.4}, {V_MODE, 10}, {V_DECAY, 0.4}, {V_PRE, 0}, {V_LSIZE, 0.15}, {V_DEPTH, 0.3}, {V_ESIZE, 0.1},
	}},
	{name = "Dark Room", kind = .Proverb, category = "Dark", info = "The treble gone early: a soft, wooden room", params = {
		{V_MIX, 1}, {V_MODE, 4}, {V_DECAY, 1.5}, {V_HIGH, 0.2}, {V_HX, 3000}, {V_CUT, 5000},
	}},
	{name = "Long Pad Space", kind = .Proverb, category = "Big Spaces", info = "Twelve seconds, moving: pads and drones turned to air", params = {
		{V_MIX, 1}, {V_MODE, 11}, {V_DECAY, 12}, {V_PRE, 60}, {V_LSIZE, 1}, {V_DEPTH, 0.95}, {V_MODD, 0.9}, {V_HIGH, 0.5},
	}},
	{name = "Small Booth", kind = .Proverb, category = "Rooms", info = "A small, close space: the early reflections almost all of it", params = {
		{V_MIX, 1}, {V_MODE, 7}, {V_DECAY, 0.5}, {V_DEPTH, 0.2}, {V_ESIZE, 0.15}, {V_LSIZE, 0.1},
	}},
	{name = "Early Bloom", kind = .Proverb, category = "Effects", info = "A large early space sent into the tail: it swells before it fades", params = {
		{V_MIX, 1}, {V_MODE, 6}, {V_DECAY, 3}, {V_ESIZE, 0.8}, {V_SEND, 0.3}, {V_DEPTH, 0.6},
	}},
	// ProVerb's own library, by kind of space (its own settings, made here).
	{name = "Living Room", kind = .Proverb, category = "Rooms", info = "A furnished room: short, soft, close", params = {
		{V_MIX, 1}, {V_MODE, 1}, {V_DECAY, 0.8}, {V_PRE, 4}, {V_LSIZE, 0.25}, {V_ESIZE, 0.25}, {V_DEPTH, 0.45}, {V_HIGH, 0.45}, {V_HX, 4500},
	}},
	{name = "Studio A", kind = .Proverb, category = "Rooms", info = "A tracking room: even, a little bright, never in the way", params = {
		{V_MIX, 1}, {V_MODE, 0}, {V_DECAY, 1.1}, {V_PRE, 8}, {V_LSIZE, 0.4}, {V_ESIZE, 0.35}, {V_DEPTH, 0.5}, {V_HIGH, 0.65}, {V_CUT, 12_000},
	}},
	{name = "Wood Room", kind = .Proverb, category = "Rooms", info = "Panelled walls: warm, the treble taken early", params = {
		{V_MIX, 1}, {V_MODE, 4}, {V_DECAY, 1.3}, {V_PRE, 6}, {V_LSIZE, 0.35}, {V_BASS, 1.15}, {V_HIGH, 0.3}, {V_HX, 3500}, {V_CUT, 7000},
	}},
	{name = "Glass Room", kind = .Proverb, category = "Rooms", info = "Hard surfaces: bright and lively, the early part wide", params = {
		{V_MIX, 1}, {V_MODE, 2}, {V_DECAY, 1.4}, {V_PRE, 3}, {V_LSIZE, 0.35}, {V_ESIZE, 0.4}, {V_ECROSS, 0.6}, {V_HIGH, 0.9}, {V_CUT, 15_000},
	}},
	{name = "Stone Chamber", kind = .Proverb, category = "Chambers", info = "An echo chamber of stone: dense, long in the middle", params = {
		{V_MIX, 1}, {V_MODE, 3}, {V_DECAY, 3}, {V_PRE, 12}, {V_LSIZE, 0.55}, {V_DIFF, 0.9}, {V_BASS, 1.1}, {V_HIGH, 0.55},
	}},
	{name = "Tiled Chamber", kind = .Proverb, category = "Chambers", info = "Small and reflective: a chamber with a sheen", params = {
		{V_MIX, 1}, {V_MODE, 3}, {V_DECAY, 1.9}, {V_PRE, 8}, {V_LSIZE, 0.4}, {V_ESIZE, 0.3}, {V_HIGH, 0.85}, {V_HX, 7000},
	}},
	{name = "Warm Chamber", kind = .Proverb, category = "Chambers", info = "A chamber for strings and keys: round, the top rolled off", params = {
		{V_MIX, 1}, {V_MODE, 3}, {V_DECAY, 2.6}, {V_PRE, 18}, {V_LSIZE, 0.5}, {V_BASS, 1.3}, {V_BX, 300}, {V_HIGH, 0.35}, {V_CUT, 8000},
	}},
	{name = "Concert Hall", kind = .Proverb, category = "Halls", info = "A seated hall: a clear front, a long even tail", params = {
		{V_MIX, 1}, {V_MODE, 9}, {V_DECAY, 2.8}, {V_PRE, 25}, {V_LSIZE, 0.75}, {V_DEPTH, 0.65}, {V_HIGH, 0.5}, {V_HX, 6000}, {V_MODD, 0.4},
	}},
	{name = "Small Hall", kind = .Proverb, category = "Halls", info = "A recital hall: intimate, still a hall", params = {
		{V_MIX, 1}, {V_MODE, 6}, {V_DECAY, 1.9}, {V_PRE, 15}, {V_LSIZE, 0.55}, {V_DEPTH, 0.55}, {V_HIGH, 0.55},
	}},
	{name = "Bright Hall", kind = .Proverb, category = "Halls", info = "A hall with its air kept: for vocals and acoustic guitars", params = {
		{V_MIX, 1}, {V_MODE, 6}, {V_DECAY, 2.4}, {V_PRE, 30}, {V_LSIZE, 0.7}, {V_HIGH, 0.85}, {V_CUT, 14_000}, {V_MODD, 0.5},
	}},
	{name = "Opera House", kind = .Proverb, category = "Halls", info = "Big and dark-velvet: a slow, wide bloom", params = {
		{V_MIX, 1}, {V_MODE, 9}, {V_DECAY, 3.6}, {V_PRE, 35}, {V_LSIZE, 0.9}, {V_DEPTH, 0.75}, {V_BASS, 1.2}, {V_HIGH, 0.3}, {V_HX, 4000}, {V_LCROSS, 0.6},
	}},
	{name = "Cathedral", kind = .Proverb, category = "Big Spaces", info = "Stone and height: seven seconds, the bass held longest", params = {
		{V_MIX, 1}, {V_MODE, 9}, {V_DECAY, 7}, {V_PRE, 50}, {V_LSIZE, 1}, {V_DEPTH, 0.85}, {V_BASS, 1.4}, {V_HIGH, 0.35}, {V_HX, 4500},
	}},
	{name = "Hangar", kind = .Proverb, category = "Big Spaces", info = "Metal and air: a huge, late, slightly hard space", params = {
		{V_MIX, 1}, {V_MODE, 11}, {V_DECAY, 6}, {V_PRE, 80}, {V_LSIZE, 1}, {V_DEPTH, 0.9}, {V_HIGH, 0.7}, {V_DIFF, 0.6},
	}},
	{name = "Canyon", kind = .Proverb, category = "Big Spaces", info = "Far walls: a long predelay, then a wide, open tail", params = {
		{V_MIX, 1}, {V_MODE, 11}, {V_DECAY, 5}, {V_PRE, 220}, {V_LSIZE, 0.95}, {V_DEPTH, 0.95}, {V_HIGH, 0.45}, {V_LCROSS, 0.8},
	}},
	{name = "Stadium", kind = .Proverb, category = "Big Spaces", info = "An open arena: late, diffuse, the low end long", params = {
		{V_MIX, 1}, {V_MODE, 6}, {V_DECAY, 4.5}, {V_PRE, 120}, {V_LSIZE, 1}, {V_DEPTH, 0.9}, {V_BASS, 1.5}, {V_HIGH, 0.4},
	}},
	{name = "Air", kind = .Proverb, category = "Ambiences", info = "Only the sense of a space: a sound no longer dry", params = {
		{V_MIX, 0.35}, {V_MODE, 10}, {V_DECAY, 0.3}, {V_LSIZE, 0.1}, {V_ESIZE, 0.1}, {V_DEPTH, 0.2}, {V_HIGH, 0.7},
	}},
	{name = "Room Tone", kind = .Proverb, category = "Ambiences", info = "A dead room's few reflections: glue for a mix", params = {
		{V_MIX, 0.5}, {V_MODE, 7}, {V_DECAY, 0.5}, {V_PRE, 2}, {V_ESIZE, 0.2}, {V_LSIZE, 0.15}, {V_DEPTH, 0.25}, {V_HIGH, 0.5},
	}},
	{name = "Wide Ambience", kind = .Proverb, category = "Ambiences", info = "Width more than length: the sides opened up", params = {
		{V_MIX, 0.6}, {V_MODE, 11}, {V_DECAY, 0.7}, {V_ESIZE, 0.3}, {V_ECROSS, 0.8}, {V_LCROSS, 0.9}, {V_DEPTH, 0.35},
	}},
	{name = "Velvet", kind = .Proverb, category = "Dark", info = "A dark, smooth tail: the treble gone, the body kept", params = {
		{V_MIX, 1}, {V_MODE, 8}, {V_DECAY, 2.5}, {V_PRE, 20}, {V_LSIZE, 0.6}, {V_HIGH, 0.15}, {V_HX, 2500}, {V_CUT, 4000}, {V_MODD, 0.6},
	}},
	{name = "Basement", kind = .Proverb, category = "Dark", info = "Low ceiling, concrete: boomy and dull", params = {
		{V_MIX, 1}, {V_MODE, 4}, {V_DECAY, 1.2}, {V_PRE, 3}, {V_LSIZE, 0.3}, {V_BASS, 1.6}, {V_BX, 250}, {V_HIGH, 0.2}, {V_CUT, 3500},
	}},
	{name = "Night Hall", kind = .Proverb, category = "Dark", info = "A long hall heard from outside: distant, muffled", params = {
		{V_MIX, 1}, {V_MODE, 9}, {V_DECAY, 4}, {V_PRE, 60}, {V_LSIZE, 0.85}, {V_DEPTH, 0.95}, {V_HIGH, 0.2}, {V_CUT, 3000},
	}},
	{name = "Snare Room", kind = .Proverb, category = "Drums", info = "Bright, short, wide: a snare's crack in a room", params = {
		{V_MIX, 1}, {V_MODE, 5}, {V_DECAY, 0.9}, {V_PRE, 8}, {V_LSIZE, 0.3}, {V_ESIZE, 0.3}, {V_HIGH, 0.75}, {V_BASS, 0.7},
	}},
	{name = "Kick Space", kind = .Proverb, category = "Drums", info = "No low end in the reverb: the kick stays tight", params = {
		{V_MIX, 1}, {V_MODE, 7}, {V_DECAY, 0.6}, {V_LSIZE, 0.2}, {V_BASS, 0.5}, {V_BX, 400}, {V_HIGH, 0.5},
	}},
	{name = "Overheads", kind = .Proverb, category = "Drums", info = "Cymbals with a ceiling over them: airy, not washy", params = {
		{V_MIX, 1}, {V_MODE, 2}, {V_DECAY, 1.2}, {V_PRE, 15}, {V_LSIZE, 0.4}, {V_HIGH, 0.6}, {V_BASS, 0.6}, {V_CUT, 12_000},
	}},
	{name = "Short Gate", kind = .Proverb, category = "Gated", info = "A burst of reflections, then nothing: an eighties snare", params = {
		{V_MIX, 1}, {V_MODE, 5}, {V_DECAY, 0.25}, {V_ESIZE, 0.6}, {V_SEND, 0}, {V_DEPTH, 0.1}, {V_DIFF, 1},
	}},
	{name = "Fat Gate", kind = .Proverb, category = "Gated", info = "A big early space cut short: body without a tail", params = {
		{V_MIX, 1}, {V_MODE, 3}, {V_DECAY, 0.35}, {V_ESIZE, 0.9}, {V_DEPTH, 0.15}, {V_BASS, 1.2}, {V_HIGH, 0.5},
	}},
	{name = "Lead Vocal", kind = .Proverb, category = "Vocals", info = "Predelay to keep the words in front, a smooth, bright tail", params = {
		{V_MIX, 1}, {V_MODE, 6}, {V_DECAY, 1.6}, {V_PRE, 70}, {V_LSIZE, 0.5}, {V_DEPTH, 0.8}, {V_BASS, 0.7}, {V_HIGH, 0.7}, {V_MODD, 0.5},
	}},
	{name = "Backing Vocals", kind = .Proverb, category = "Vocals", info = "Pushes a stack back and wide", params = {
		{V_MIX, 1}, {V_MODE, 11}, {V_DECAY, 2.2}, {V_PRE, 20}, {V_LSIZE, 0.6}, {V_DEPTH, 0.75}, {V_LCROSS, 0.8}, {V_HIGH, 0.55},
	}},
	{name = "Shimmer-less Pad", kind = .Proverb, category = "Effects", info = "Slow, chorused and endless: for pads to sit in", params = {
		{V_MIX, 1}, {V_MODE, 11}, {V_DECAY, 20}, {V_PRE, 40}, {V_LSIZE, 1}, {V_DEPTH, 1}, {V_MODD, 1}, {V_LMODR, 0.3}, {V_HIGH, 0.6},
	}},
	{name = "Seasick", kind = .Proverb, category = "Effects", info = "The modulation turned up: a tail that wobbles in pitch", params = {
		{V_MIX, 1}, {V_MODE, 2}, {V_DECAY, 3}, {V_LSIZE, 0.7}, {V_MODD, 1}, {V_LMODR, 2.5}, {V_EMODD, 1}, {V_EMODR, 3},
	}},
	{name = "Frozen", kind = .Proverb, category = "Effects", info = "A minute and a half: almost holds what it is given", params = {
		{V_MIX, 1}, {V_MODE, 9}, {V_DECAY, 90}, {V_LSIZE, 1}, {V_DEPTH, 1}, {V_BASS, 1}, {V_HIGH, 0.8}, {V_MODD, 0.5},
	}},
	{name = "Telephone Room", kind = .Proverb, category = "Effects", info = "A narrow band in a small room: lo-fi space", params = {
		{V_MIX, 1}, {V_MODE, 7}, {V_DECAY, 0.9}, {V_LSIZE, 0.25}, {V_BASS, 0.5}, {V_BX, 800}, {V_CUT, 2800}, {V_HIGH, 0.4},
	}},
}

// A slot holding factory effect preset `p`, on.
effect_preset_slot :: proc(p: Effect_Preset) -> Effect_Slot {
	s := new_effect(p.kind)
	for x in p.params do slot_set(&s, fc.Param_Id(x.id), x.value)
	s.key_hpf, s.key_lpf = p.key_hpf, p.key_lpf
	return s
}
