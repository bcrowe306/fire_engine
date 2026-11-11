package pads_model

import "core:math"

import fc "fire:core"
import "fire:dsp"
import "fire:fx"
import "fire:synth"

// The effects slots play with the synth's algorithms: the kinds that have
// a twin among the synth's nine run its node (`synth.effect_node_create`),
// their settings its parameters' plain values. The app's own low-, high-
// and band-pass, saturation and bit-crusher became the synth's filter and
// distortion: slots saved with them (or with a twin's old settings) are
// converted to the nearest settings when a project loads.

// The synth effect a kind plays (false: one of the app's own, or none).
synth_twin :: proc(k: Effect_Kind) -> (fx.Effect, bool) {
	#partial switch k {
	case .Compressor: return .Compressor, true
	case .Delay:      return .Delay, true
	case .Reverb:     return .Reverb, true
	case .Chorus:     return .Chorus, true
	case .Flanger:    return .Flanger, true
	case .Phaser:     return .Phaser, true
	case .Distortion: return .Distortion, true
	case .Eq:         return .Eq, true
	case .Filter:     return .Filter, true
	}
	return {}, false
}

// Whether a kind is one no longer made (converted when read).
effect_kind_legacy :: proc(k: Effect_Kind) -> bool {
	#partial switch k {
	case .Low_Pass, .High_Pass, .Band_Pass, .Saturation, .Bitcrush: return true
	}
	return false
}

// Whether slot `s` holds settings of the app's old effects (a legacy
// kind, or a twin's kind with the old parameters).
slot_is_legacy :: proc(s: Effect_Slot) -> bool {
	if effect_kind_legacy(s.kind) do return true
	if _, ok := synth_twin(s.kind); !ok do return false
	s := s
	for p in s.params[:s.count] do if !synth.is_effect_param(p.id) do return true
	return false
}

// The key (a filter's cutoff unit) at `hz`.
@(private)
hz_key :: proc(hz: f32) -> f32 { return 69 + 12 * math.log2(max(hz, 1) / 440) }

// Slot `s` (of the app's old effects) as the synth effect nearest it.
convert_slot :: proc(s: Effect_Slot) -> Effect_Slot {
	if !slot_is_legacy(s) do return s
	v :: proc(s: Effect_Slot, id: fc.Param_Id, def: f32) -> f32 { return slot_value(s, id, def) }
	out: Effect_Slot
	put :: proc(o: ^Effect_Slot, e: fx.Effect, f: $T, x: f32) {
		id := synth.effect_param(e, f)
		if spec := synth.param_spec(id); spec != nil do slot_set(o, id, clamp(x, spec.min, spec.max))
	}
	#partial switch s.kind {
	case .Low_Pass, .High_Pass, .Band_Pass:
		out = new_effect(.Filter)
		f :: synth.Fx_Filter_Field
		put(&out, .Filter, f.Model, f32(fx.Filter_Model.Digital))
		blend: f32 = 0 if s.kind == .Low_Pass else (2 if s.kind == .High_Pass else 1)
		put(&out, .Filter, f.Blend, blend)
		put(&out, .Filter, f.Cutoff, hz_key(v(s, dsp.FILTER_PARAM_CUTOFF_HZ, 1000)))
		put(&out, .Filter, f.Resonance, clamp((v(s, dsp.FILTER_PARAM_Q, 0.707) - 0.5) / 10, 0, 1))
	case .Saturation:
		out = new_effect(.Distortion)
		d :: synth.Distortion_Field
		put(&out, .Distortion, d.Drive, v(s, dsp.SATURATION_PARAM_DRIVE_DB, 6))
		put(&out, .Distortion, d.Mix, v(s, dsp.SATURATION_PARAM_MIX, 100) / 100)
	case .Bitcrush:
		out = new_effect(.Distortion)
		d :: synth.Distortion_Field
		bits := v(s, dsp.BITCRUSH_PARAM_BITS, 8)
		put(&out, .Distortion, d.Type, f32(fx.Distortion_Type.Bit_Crush))
		put(&out, .Distortion, d.Drive, math.sqrt(math.pow(2, 1 - bits)) * 60 - 30) // (its step: 2^(1-bits))
		put(&out, .Distortion, d.Mix, v(s, dsp.BITCRUSH_PARAM_MIX, 1))
	case .Compressor:
		out = new_effect(.Compressor)
		c :: synth.Compressor_Field
		put(&out, .Compressor, c.Bands, f32(fx.Compressor_Bands.One))
		put(&out, .Compressor, c.Band_Upper, v(s, dsp.COMPRESSOR_PARAM_THRESHOLD_DB, -20))
		put(&out, .Compressor, c.Band_Upper_Ratio, 1 - 1 / max(v(s, dsp.COMPRESSOR_PARAM_RATIO, 4), 1))
		put(&out, .Compressor, c.Band_Lower, -80)
		put(&out, .Compressor, c.Band_Lower_Ratio, 0)
		put(&out, .Compressor, c.Band_Gain, v(s, dsp.COMPRESSOR_PARAM_MAKEUP_DB, 0))
		// Times as the band's base (1.4 and 28 ms) times e^(8x - 4).
		put(&out, .Compressor, c.Attack, (math.ln(max(v(s, dsp.COMPRESSOR_PARAM_ATTACK_MS, 10), 0.01) / 1.4) + 4) / 8)
		put(&out, .Compressor, c.Release, (math.ln(max(v(s, dsp.COMPRESSOR_PARAM_RELEASE_MS, 100), 0.01) / 28) + 4) / 8)
		put(&out, .Compressor, c.Mix, v(s, dsp.COMPRESSOR_PARAM_MIX, 100) / 100)
	case .Delay:
		out = new_effect(.Delay)
		d :: synth.Delay_Field
		if v(s, dsp.DELAY_PARAM_SYNC, 0) > 0.5 {
			// The nearest tempo division to its beats.
			cycles := 1 / max(v(s, dsp.DELAY_PARAM_BEATS, 0.75), 0.001)
			ratios := fx.TEMPO_RATIOS
			best := 1
			for r, k in ratios do if k > 0 && abs(math.log2(r / cycles)) < abs(math.log2(ratios[best] / cycles)) do best = k
			put(&out, .Delay, d.Sync, f32(fx.Sync.Tempo))
			put(&out, .Delay, d.Tempo, f32(best))
			put(&out, .Delay, d.Tempo_Right, f32(best))
		} else {
			hz := 1000 / max(v(s, dsp.DELAY_PARAM_TIME_MS, 375), 1)
			put(&out, .Delay, d.Sync, f32(fx.Sync.Free))
			put(&out, .Delay, d.Hz, math.log2(hz))
			put(&out, .Delay, d.Hz_Right, math.log2(hz))
		}
		put(&out, .Delay, d.Style, f32(fx.Delay_Style.Ping_Pong if v(s, dsp.DELAY_PARAM_PING_PONG, 0) > 0.5 else fx.Delay_Style.Stereo))
		put(&out, .Delay, d.Feedback, v(s, dsp.DELAY_PARAM_FEEDBACK, 40) / 100)
		put(&out, .Delay, d.Wet, v(s, dsp.DELAY_PARAM_MIX, 35) / 100)
		lo, hi := hz_key(v(s, dsp.DELAY_PARAM_LOW_CUT_HZ, 20)), hz_key(v(s, dsp.DELAY_PARAM_HIGH_CUT_HZ, 12_000))
		put(&out, .Delay, d.Cutoff, (lo + hi) / 2)
		put(&out, .Delay, d.Spread, (hi - lo) / 2 / 96)
	case .Reverb:
		out = new_effect(.Reverb)
		r :: synth.Reverb_Field
		put(&out, .Reverb, r.Size, v(s, dsp.REVERB_PARAM_SIZE, 50) / 100)
		put(&out, .Reverb, r.Decay, math.log2(max(v(s, dsp.REVERB_PARAM_DECAY_S, 2), 0.1)))
		put(&out, .Reverb, r.Delay, v(s, dsp.REVERB_PARAM_PREDELAY_MS, 10) / 1000)
		put(&out, .Reverb, r.Wet, v(s, dsp.REVERB_PARAM_MIX, 30) / 100)
		put(&out, .Reverb, r.High_Gain, -6 * (1 - v(s, dsp.REVERB_PARAM_HF_DECAY, 50) / 100))
		put(&out, .Reverb, r.Chorus, v(s, dsp.REVERB_PARAM_MODULATION, 30) / 100 * 0.3)
	case .Chorus:
		out = new_effect(.Chorus)
		c :: synth.Chorus_Field
		delay := max(v(s, dsp.MOD_PARAM_DELAY_MS, 12), 1) / 1000
		put(&out, .Chorus, c.Sync, f32(fx.Sync.Free))
		put(&out, .Chorus, c.Hz, math.log2(max(v(s, dsp.MOD_PARAM_RATE_HZ, 0.8), 0.004)))
		put(&out, .Chorus, c.Depth, v(s, dsp.MOD_PARAM_DEPTH, 3) / 10)
		put(&out, .Chorus, c.Delay_1, math.log2(delay))
		put(&out, .Chorus, c.Delay_2, math.log2(delay * 2))
		put(&out, .Chorus, c.Wet, v(s, dsp.MOD_PARAM_MIX, 50) / 100)
		put(&out, .Chorus, c.Voices, v(s, dsp.MOD_PARAM_VOICES, 2))
	case .Flanger:
		out = new_effect(.Flanger)
		f :: synth.Flanger_Field
		put(&out, .Flanger, f.Sync, f32(fx.Sync.Free))
		put(&out, .Flanger, f.Hz, math.log2(max(v(s, dsp.MOD_PARAM_RATE_HZ, 0.25), 0.004)))
		put(&out, .Flanger, f.Depth, v(s, dsp.MOD_PARAM_DEPTH, 2) / 10)
		put(&out, .Flanger, f.Center, hz_key(1000 / max(v(s, dsp.MOD_PARAM_DELAY_MS, 1), 0.1)))
		put(&out, .Flanger, f.Feedback, v(s, dsp.MOD_PARAM_FEEDBACK, 50) / 100)
		put(&out, .Flanger, f.Wet, v(s, dsp.MOD_PARAM_MIX, 50) / 200)
	case .Phaser:
		out = new_effect(.Phaser)
		f :: synth.Phaser_Field
		lo, hi := hz_key(v(s, dsp.MOD_PARAM_MIN_HZ, 200)), hz_key(v(s, dsp.MOD_PARAM_MAX_HZ, 3000))
		put(&out, .Phaser, f.Sync, f32(fx.Sync.Free))
		put(&out, .Phaser, f.Hz, math.log2(max(v(s, dsp.MOD_PARAM_RATE_HZ, 0.5), 0.004)))
		put(&out, .Phaser, f.Center, (lo + hi) / 2)
		put(&out, .Phaser, f.Depth, (hi - lo) / 2 * v(s, dsp.MOD_PARAM_DEPTH, 100) / 100)
		put(&out, .Phaser, f.Feedback, abs(v(s, dsp.MOD_PARAM_FEEDBACK, 0)) / 100)
		put(&out, .Phaser, f.Wet, v(s, dsp.MOD_PARAM_MIX, 50) / 100)
	case:
		return s
	}
	out.on = s.on
	return out
}
