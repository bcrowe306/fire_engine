# Push 2: the other devices' panels (plan, 2026-11-19)

Sampler, Slicer, the synth's tabs, SuperFilter, ProSaturator, ProEq,
ProComp and ProVerb have panels of their own on Push 2's display: a picture
of what the device does to the sound, named banks of knobs placed by hand
(◀ ▶ page them, the page strip names them), choices as dropdowns (`ctl_box`
▾), the lower row only the device's own choices (On: Mute + Device; Remove:
Delete + Device). Everything else still goes through the generic path in
`ctl_effect`: the window's small picture (`draw_effect_view`), or for the
synth's effects only a line of text, and every parameter in order, eight a
bank. This plan gives the rest the same treatment.

**Push 2 only.** Pads' window doesn't change in this round. The pictures
are written so the window can use them later (a proc that draws into a size
it's given, no Push-only state), which is what superfilter.md's "Later: the
other devices" asked for; switching the window over is a later step.

## Scope

| Family | Devices |
|---|---|
| Dynamics | Compressor, Gate, Limiter |
| Modulation | Chorus, Flanger, Phaser |
| Space | Delay, Reverb, Comb |
| Drive | Distortion, Ring mod, Saturation*, Bit-crusher* |
| Rhythm and pitch | Cutter, Stutter, Pitch shift |
| Tone | EQ, Filter, Low-pass*, High-pass*, Band-pass*, the pad's EQ |
| MIDI and plug-ins | the pad's MIDI effects (repeat, arpeggiator, latch), CLAP plug-ins (their parameters in banks, restyled) |

\* Old projects' effects: no longer offered in Add, still loaded from old
projects.

- **The synth's effects** (Distortion, Compressor, Delay, Reverb, Chorus,
  Flanger, Phaser: `synth_twin`) use the same panel in an effect slot and on
  the synth's Effects tab. On that tab the effect picker and On stay where
  they are: knob 1 of every bank.
- **Perform's effects:** Intensity is knob 1 of every bank, the effect's
  own after it.

## The groundwork (one step, on main, before the families)

So the families never edit the same lines:

1. **`ui_ctl_fx.odin`:** `Fx_Panel`, what a panel is given: the view
   context, the target (a slot, a synth's effect, a Perform effect), the
   plot, and one way to read and set a parameter whichever it is (slot
   param, synth param, Intensity), with undo and automation as the knobs
   have now. Helpers: `fx_knob`, `fx_choice`, `fx_banks` (named banks; knob
   1 of each kept for Intensity or the synth's picker when there is one).
   A family's own knobs (times in ratios, a cutoff in Hz) go through
   `fx_ring_knob`, so they show what `fx_knob`'s do besides the encoder:
   automation playing (the live mark on the bar, where the lane has it as
   the knob turns: `Knob_Map`) and, on the synth's tab, its modulation
   routes (`ctl_route_marks`: a line under the bar in the source's colour,
   the envelope's or LFO's place on it while a note sounds), the bar's form
   of the window's rings. The knobs drawn, their labels, values and marks
   are in the state (`ctl_knobs`) for the tests.
2. **The dispatch:** `ctl_effect`, the synth's Effects tab, `ctl_eq` and
   `ctl_midi` ask `fx_panel(...) -> bool` first, which calls one proc per
   family (`fx_panel_dynamics`, `fx_panel_modulation`, ...), each in its own
   file (`ui_ctl_fx_<family>.odin`) and a stub returning false (the generic
   path) until its family is built.
3. **The test kit:** `tests/e2e/push2_fx.py`, helpers to put a device in a
   slot, on the synth's Effects tab, in Perform, turn its banks' encoders,
   check the parameter moved and save the display (`display_png`); and a
   draw-time probe (the panel's drawing, timed, in the e2e log).

## Each family (a subagent, its own worktree and branch)

- Its file `apps/pads/ui_ctl_fx_<family>.odin` only (plus its pictures in
  the same file or `ui_fxpic_<family>.odin`); its tests in
  `tests/e2e/test_push2_fx_<family>.py`. Nothing else, unless it says why.
- **Per device:** a picture of what it does that moves with its knobs and,
  where it's cheap, the signal (a compressor's curve with the level on it
  and the gain reduction; a delay's echoes on a time line; a phaser's
  notches sweeping); banks named for what they do; every parameter on a
  knob; choices as dropdowns; the lower row for the device's own choices
  only.
- **Checked:** e2e on the encoders (every bank, every knob moves its
  parameter; block-size and undo as the others), the display saved for
  every bank and looked at, the panel's draw time on this Mac, `task
  app:test` and the family's e2e passing at both opt levels, docs (a
  section per device in docs/design/push2.md).
- **Then:** its branch, its screenshots, a summary to review. After review
  and changes: merged into main (one commit a family) and pushed.

**Order:** three families at a time (the e2e runs are heavy): Dynamics,
Modulation, Space; then Drive, Rhythm and pitch, Tone; then MIDI and
plug-ins.

## Not in this round

- Pads' window panels (later, from these pictures).
- Profiling on the cloud machines (this Mac only).
- A real Push 2 check (none plugged in): the virtual Push 2 and the
  display images.
