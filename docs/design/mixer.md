# The Mixer: tidier strips, accurate meters

Status: built (all four steps). Limits for later: the cue has no meter; a K scale colours the meters, but the marks stay the fader's dB; a strip shows one dynamics effect's gain reduction (its first).

## Decisions (asked, 2026-11-12)

1. **The Mixer keeps the top area** (the bottom area stays, showing the
   selected strip's chain), tidied: names never cut off, no gap between
   the pads' strips and the buses, main pinned at the right.
2. **The strips' sections are each optional**, by a toggle icon in the
   Mixer's bar, lit when on and grey when off: **Inserts** (each effect
   a chip: click opens it in the bottom area, drag to reorder, + for an
   empty slot), **EQ** (a small curve; click opens the EQ below),
   **Sends** (a bar a bus in use, not tiny knobs), **I/O** (its MIDI in
   and where it goes). Saved with the app's settings.
3. **Strips switch between narrow and wide** (about 56 and 86 points).
4. **Accurate metering, visual feedback first**:
   - every strip: the peak bar with the RMS inside it, a held peak line,
     the highest peak as a number (click to reset), a clip light;
   - a strip with a compressor or limiter: its **gain reduction** as a
     bar beside its meter;
   - main: **loudness** (EBU R128: momentary, short-term, integrated
     with a reset) and **true peak**, a **phase correlation** bar (-1 to
     +1) and a **stereo view** (goniometer), in a column beside main.
5. **Meter settings in Settings** (not in the Mixer): the scale (dBFS
   -60..+6, or K-12, K-14, K-20), peak or RMS emphasis, the peak hold
   time and the fall rate. Defaults: dBFS, instant attack, a fall of
   about 24 dB a second, a 2 s hold; marks at 0, -6, -12, -24, -48.

## Changed after (asked, 2026-11-13)

- Wide strips wider (112 points, from 86); the I/O dropdowns and Mute,
  Solo and Arm taller (24 points) while the Mixer has the height.
- The pads area folded: a bigger pan knob, the sends as knobs (three a
  row on a wide strip); unfolded, the send bars as before.

## The engine

- `fire:dsp` gets a **loudness meter** (K-weighting, 400 ms momentary
  and 3 s short-term windows, gated integrated loudness, 4× oversampled
  true peak) and a **stereo analyser** (correlation, and a decimated
  ring of L/R pairs for the goniometer); both tested through
  `testkit.render` (finite output, no rt allocations, block-size
  invariance, and against known signals: a -23 LUFS reference tone, a
  mono signal's correlation of +1, an inverted one's -1).
- Main's chain gets both after its fader (read by the UI, like the
  meters now).
- The compressor and limiter report their gain reduction (an atomic the
  UI reads), per insert.

## Order of work

1. **The meters' engine**: the loudness meter and stereo analyser in
   `fire:dsp` with their tests; on main; gain reduction from the
   compressor and limiter.
2. **Settings**: the meter scale, emphasis, hold and fall.
3. **The strips**: the toggles and narrow/wide; insert chips, the EQ
   curve, send bars, I/O; names, no gap, main pinned; the meters (peak,
   RMS, hold, max, clip, gain reduction); main's column (loudness, true
   peak, correlation, the stereo view).
4. **Tests and docs**: e2e tests, a drive script with screenshots, the
   guides, cloud tests at the end.
