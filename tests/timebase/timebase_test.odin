package test_timebase

import "core:math"
import "core:testing"

import tb "fire:timebase"
import kit "fire:testkit"

@(test)
samples_seconds_round_trip :: proc(t: ^testing.T) {
	for s in ([]tb.Sample_Time{0, 1, 47999, 48000, 1 << 40}) {
		secs := tb.samples_to_seconds(s, 48000)
		testing.expect_value(t, tb.seconds_to_samples(secs, 48000), s)
	}
}

@(test)
ticks_round_trip :: proc(t: ^testing.T) {
	testing.expect_value(t, tb.beats_to_ticks(1.5), tb.Ticks(1440))
	testing.expect_value(t, tb.ticks_to_beats(240), tb.Beats(0.25))
	testing.expect_value(t, tb.beats_to_ticks(tb.ticks_to_beats(12345, 480), 480), tb.Ticks(12345))
}

@(test)
constant_tempo :: proc(t: ^testing.T) {
	m: tb.Tempo_Map
	tb.tempo_map_init(&m, 120)
	defer tb.tempo_map_destroy(&m)

	kit.expect_near(t, f64(tb.beats_to_seconds(&m, 4)), 2.0, 1e-12, "4 beats @120")
	kit.expect_near(t, f64(tb.seconds_to_beats(&m, 1.5)), 3.0, 1e-12, "1.5 s @120")
	testing.expect_value(t, tb.beats_to_samples(&m, 1, 48000), tb.Sample_Time(24000))
}

@(test)
tempo_change :: proc(t: ^testing.T) {
	m: tb.Tempo_Map
	tb.tempo_map_init(&m, 120)
	defer tb.tempo_map_destroy(&m)
	tb.tempo_map_set_tempo(&m, 4, 60) // 4 beats @120 = 2 s, then 60 bpm

	kit.expect_near(t, f64(tb.beats_to_seconds(&m, 6)), 4.0, 1e-12, "2 s + 2 beats @60")
	kit.expect_near(t, f64(tb.seconds_to_beats(&m, 4.0)), 6.0, 1e-12, "inverse")
	kit.expect_near(t, tb.tempo_at(&m, 5), 60, 1e-12, "tempo after change")
}

// A linear ramp has a closed form; check it against brute-force integration.
@(test)
tempo_ramp_matches_numeric_integration :: proc(t: ^testing.T) {
	m: tb.Tempo_Map
	tb.tempo_map_init(&m, 100)
	defer tb.tempo_map_destroy(&m)
	tb.tempo_map_set_tempo(&m, 0, 100, ramp_to = 200)
	tb.tempo_map_set_tempo(&m, 8, 200)

	steps := 1_000_000
	db := 8.0 / f64(steps)
	secs := 0.0
	for i in 0 ..< steps {
		b := (f64(i) + 0.5) * db
		secs += 60.0 / (100 + 100 * b / 8) * db
	}
	kit.expect_near(t, f64(tb.beats_to_seconds(&m, 8)), secs, 1e-9, "ramp duration")
	kit.expect_near(t, tb.tempo_at(&m, 4), 150, 1e-12, "mid-ramp tempo")

	for b in ([]f64{0, 0.25, 3.3, 7.99, 8, 12.5}) {
		back := tb.seconds_to_beats(&m, tb.beats_to_seconds(&m, tb.Beats(b)))
		kit.expect_near(t, f64(back), b, 1e-9, "ramp round trip")
	}
}

@(test)
bbt_with_meter_change :: proc(t: ^testing.T) {
	m: tb.Tempo_Map
	tb.tempo_map_init(&m, 120, {4, 4})
	defer tb.tempo_map_destroy(&m)
	tb.tempo_map_set_meter(&m, 2, {7, 8}) // bars 0,1 in 4/4 (8 beats), then 7/8 (3.5 beats/bar)

	testing.expect_value(t, tb.beats_to_bbt(&m, 0), tb.Bar_Beat_Tick{0, 0, 0})
	testing.expect_value(t, tb.beats_to_bbt(&m, 5.5), tb.Bar_Beat_Tick{1, 1, 480})
	testing.expect_value(t, tb.beats_to_bbt(&m, 8), tb.Bar_Beat_Tick{2, 0, 0})
	// 8 + 3.5 + 1.0 beats = bar 3, two eighth-notes in
	testing.expect_value(t, tb.beats_to_bbt(&m, 12.5), tb.Bar_Beat_Tick{3, 2, 0})

	for b in ([]f64{0, 1.25, 7.75, 8, 9.5, 11.5, 20.125}) {
		bbt := tb.beats_to_bbt(&m, tb.Beats(b))
		kit.expect_near(t, f64(tb.bbt_to_beats(&m, bbt)), b, 1e-9, "bbt round trip")
	}
	_ = math.PI
}
