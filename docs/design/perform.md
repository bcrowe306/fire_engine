# The Perform view: launch, play, effects

Status: built (all five steps). Limits for later: a loop of columns whose lengths have no common multiple within 64 bars drifts at its end; an audio pad's takes play from the leftmost playing column only; the cue level has no meter (only main does).

## Decisions (asked, 2026-11-12)

1. **Perform takes the whole height** (the pads area folds to its bar
   while it shows, as in Song) with **three grids side by side, the same
   size (layout A)**: the sequence launcher, the 16 pads to play, and the
   performance effects; the **main and cue levels** as tall meters at the
   right.
2. **The launcher's columns are lanes**: one sequence per column plays at
   a time, the columns play together (a drum sequence in one, a bass
   sequence in another). A pad launches its sequence in its column at the
   launch quantize; each column has a **Stop**; each row a **launch row**
   arrow (a scene: the row's sequences together); **Stop All**.
3. **Record to Song**: armed, what is launched is written into the Song
   as clips, column k into lane k, from where it starts until it is
   replaced or stopped (one undo step a take).
4. **A sequence pad shows** its notes small, a bar filling across while
   it plays (a queued one counts down to its start), and empty pads
   nearly invisible (a + on hover).
5. **The effects coloured by kind** (filters, rhythm, pitch, space,
   drive), their intensity as a fill.
6. **Note repeat and the arpeggiator leave Perform** and become **MIDI
   effects on a pad**: devices in its chain before its sound, each with
   its own page, saved with the pad. **The play mode** (Pads, Keyboard,
   Velocity) goes with them, at the head of the selected pad's chain.
7. **The MIDI setup** (Learn, MIDI out) goes to **the pad's settings**
   (its track I/O, where its MIDI in is); the status bar keeps the
   activity lights.

## Added after (asked, 2026-11-12)

- **Shift-click** a sequence pad launches it alone (the other columns
  stop then); Option-click goes to it to edit it.
- **Continue**: a launched sequence carries on where the playhead is in
  what played (its column's sequence, else the leading column's: that
  pass so far, modulo the new one's length), for seamless changes.
- The **levels** use the mixer's meter (smoothed, held peaks) and fader.

## The engine: columns playing together

- Pattern mode's plan becomes one segment per playing column, each
  looping its own sequence. Their clip loops over the least common
  multiple of their lengths (whole bars; past 64 bars, each column's
  notes are laid out that far and the loop is that long).
- A launch replaces its column's segment at the launch quantize (End:
  the end of that column's sequence; Bar, Beat, Now); the other columns
  play on. Stop ends the column there. Launching a row queues each of its
  pads in their columns at once.
- The Sequence panel edits the last launched (or clicked) sequence, as
  now; recording into pattern mode records into it.
- Audio takes: each column's sequence's takes play (an audio pad's,
  from the leftmost playing column that has one).

## Order of work

1. **Columns that play together**: the model (what each column plays,
   queued launches, stop), the plan, the engine's switches; row launch
   and Stop All. Model tests.
2. **Record to Song**: the arm, writing clips into lanes, undo. Model
   tests.
3. **MIDI effects on a pad**: Note Repeat and Arpeggiator as devices in
   the pad's chain (per pad, file format), the play mode at its head; the
   MIDI setup (Learn, MIDI out) in the pad's track I/O. Model tests.
4. **The view**: layout A; the launcher (notes, progress, faint empty
   pads, row arrows, column stops, Stop All, Record to Song), the pads,
   the coloured effects with their fill, the meters; the pads area folded
   while it shows.
5. **Tests and docs**: e2e tests, a drive script with screenshots, the
   Pads guide, cloud tests at the end.
