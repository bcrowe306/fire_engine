// ProVerb's reference analysis: reads the probe's renders (and its jobs)
// and writes what was measured as JSON: per job, the decay time in octave
// bands, the echo density's build-up, the first reflections, the stereo
// correlation, a tone's spread, the level and the first arrival. The same
// measures ProVerb's own tests take (`fire:testkit`).
//
//   odin run scripts/proverb_probe/analyze -collection:fire=f_engine -- .build/proverb_ref tests/proverb/reference.json
package proverb_analyze

import "core:encoding/json"
import "core:fmt"
import "core:math"
import "core:os"

import kit "fire:testkit"

Job :: struct {
	name:    string,
	params:  map[string]f64,
	signal:  string,
	seconds: f64,
}

BANDS :: [7]f64{125, 250, 500, 1000, 2000, 4000, 8000}

Measured :: struct {
	name:        string,
	params:      map[string]f64,
	signal:      string,
	rt60:        [7]f64, // s, at BANDS
	rt60_wide:   f64,
	density_50:  f64, // ms to an echo density of 0.5 (−1: never)
	density_90:  f64, // and 0.9
	density_ms:  []f64, // the density every 5 ms over the first 300
	early:       []kit.Reflection, // the first 100 ms's 12 loudest peaks (left)
	correlation: f64, // left against right, 50 ms to 1 s
	spread_hz:   f64, // a 1 kHz tone's tail's spread (sine jobs)
	level_db:    f64, // the wet's RMS over its first second (dB)
	first_ms:    f64, // the first frame within 40 dB of the peak
	band_db:     [7]f64, // each band's energy, first second (dB)
}

main :: proc() {
	if len(os.args) < 3 {
		fmt.eprintln("usage: analyze RENDER_DIR OUT.json")
		os.exit(1)
	}
	dir, out_path := os.args[1], os.args[2]
	data, rerr := os.read_entire_file_from_path(fmt.tprintf("%s/jobs.json", dir), context.allocator)
	if rerr != nil {
		fmt.eprintln("no jobs.json in", dir)
		os.exit(1)
	}
	jobs: []Job
	if err := json.unmarshal(data, &jobs); err != nil {
		fmt.eprintln("jobs.json:", err)
		os.exit(1)
	}
	results := make([dynamic]Measured)
	for j in jobs {
		b, err := kit.wav_read(fmt.tprintf("%s/%s.wav", dir, j.name))
		if err != nil {
			fmt.eprintln(j.name, err)
			continue
		}
		sr := b.sample_rate
		l, r := b.channels[0], b.channels[1]
		mono := make([]f32, len(l))
		for v, i in l do mono[i] = 0.5 * (v + r[i])
		m := Measured{name = j.name, params = j.params, signal = j.signal}
		if j.signal == "impulse" || j.signal == "noise" {
			bands := BANDS
			for hz, k in bands {
				m.rt60[k] = kit.band_decay_time(mono, sr, hz)
				band := kit.octave_band(mono[:min(len(mono), int(sr))], sr, hz, context.temp_allocator)
				e := 0.0
				for v in band do e += f64(v) * f64(v)
				m.band_db[k] = 10 * math.log10(max(e, 1e-30))
			}
			m.rt60_wide = kit.decay_time(mono, sr)
			d := kit.echo_density(l[:min(len(l), int(0.3 * sr) + 960)], sr)
			m.density_ms = d[:min(len(d), 60)]
			m.density_50, m.density_90 = -1, -1
			for v, k in d {
				if m.density_50 < 0 && v >= 0.5 do m.density_50 = f64(k) * 5
				if m.density_90 < 0 && v >= 0.9 do m.density_90 = f64(k) * 5
			}
			m.early = kit.early_peaks(l, sr, 100, 12)
			a, z := int(0.05 * sr), min(int(1.0 * sr), len(l))
			m.correlation = kit.correlation(l[a:z], r[a:z])
			s2 := 0.0
			for v in mono[:min(len(mono), int(sr))] do s2 += f64(v) * f64(v)
			m.level_db = 10 * math.log10(max(s2 / sr, 1e-30))
			peak: f32 = 0
			for v in mono do peak = max(peak, abs(v))
			for v, i in mono do if abs(v) >= peak * 0.01 {
				m.first_ms = f64(i) * 1000 / sr
				break
			}
		} else {
			// A tone of a second, then its tail: how it spreads.
			a, z := int(1.05 * sr), min(int(1.05 * sr) + 32_768, len(mono))
			m.spread_hz = kit.spectral_spread(mono[a:z], sr, 1000)
			m.correlation = kit.correlation(l[a:z], r[a:z])
		}
		append(&results, m)
		fmt.printfln("%-18s rt60 %.2f s (125 Hz %.2f, 8 kHz %.2f), density 0.9 at %.0f ms, corr %.2f, spread %.1f Hz, first %.1f ms, level %.1f dB",
			m.name, m.rt60_wide, m.rt60[0], m.rt60[6], m.density_90, m.correlation, m.spread_hz, m.first_ms, m.level_db)
	}
	out, merr := json.marshal(results[:], {pretty = true, use_spaces = true, spaces = 1})
	if merr != nil {
		fmt.eprintln("json:", merr)
		os.exit(1)
	}
	if werr := os.write_entire_file(out_path, out); werr != nil {
		fmt.eprintln("could not write", out_path)
		os.exit(1)
	}
	fmt.println("wrote", out_path, len(results), "measurements")
}
