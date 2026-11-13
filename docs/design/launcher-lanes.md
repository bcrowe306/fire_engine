# Launcher lanes

Status: built (decisions taken 2026-11-13). Not yet: an 8 × 8 window, lane mute/solo, follow actions, scene names, controller mapping.

## What there is now

- The launcher (pattern mode, the Perform tab) has **4 lanes**, and a
  sequence's lane is **where its pad sits**: the column of the 4 × 4
  bank (`launch_col(slot) = slot % 4`). Sequences 1, 5, 9, 13 (and 17,
  21… in the other banks) share lane 1, whatever they hold.
- Each lane plays one sequence at a time; a launch replaces its lane's
  sequence at the launch quantize; a row launches its four together.
- Record to Song writes lane k onto song lane k.
- So to put a bass line beside a drum loop you have to know which slot
  numbers are in which column, and a lane holds at most 4 sequences a bank.

## Decisions (asked, 2026-11-13)

1. **A lane per sequence.** Each sequence has its lane (and its place in
   it), set from its menu or by dragging it to another column. Lanes are
   columns; each lists its own sequences top to bottom.
2. **8 lanes by default; changeable per project** on the grid: a lane's
   header renames it, colours it, deletes it; a + adds one (up to 16).
   Saved with the project; new projects start with 8 (a setting).
3. **The 4 × 4 layout stays** (pad controllers are 4 × 4 or 8 × 8): the
   grid is a window of 4 lanes by 4 rows over all the lanes, moved by the
   bank buttons or arrows (lanes across, rows down), outlined on an
   overview. The hardware pads and the computer's Keys show the same
   window.
4. **Rows are scenes**: row k launches each lane's k-th sequence together.
5. **A pad played by more than one lane** plays from both (as in a DAW),
   and is marked on the sequence pads.

## The model

- `Project.lanes: Lanes`: each sequence's `Seq_Place` (lane, row), the
  lanes (`Launch_Lane`: name, colour) and their count (default 8, a
  setting for new projects) — one value, so an edit is one undo step.
- `launch_col(slot)` becomes the sequence's lane; `Launcher.cols` grows to
  MAX_LANES (16).
- A lane's sequences: those with that lane, by row. Rows are compacted
  when a sequence moves out (no holes), so row k is a scene.
- **Migration** (project file v37): an older project's sequences get
  lane `slot % 4` and row `slot / 4` (what they played as before), and
  4 lanes named Lane 1–4; nothing sounds different.
- Edits, each one undo step: `move_sequence(slot, lane, row)` (drag
  within or across lanes), `add_lane`, `delete_lane` (its sequences go to
  the lane before: asked first if it has any), `set_lane` (name, colour),
  `new_sequence_in(lane)` (the + at a lane's end: the first empty slot).

## The UI

- **Perform's Sequences grid**: 4 × 4 (or 8 × 8: a setting, for 8 × 8
  controllers) cells of the window; above each column its lane's header
  (name, colour, a stop button, its menu); a small **overview** beside it:
  every lane as a thin column of its sequences, the window outlined (click
  or drag it to move the window). Arrows (and Alt + arrow keys) move the
  window by a lane or a row; the bank buttons by a whole window.
- A sequence pad: drag it to another cell (another lane, another row:
  its lane's others move up or down); its menu has **Move to lane ▸**.
  The empty cell after a lane's last is its **+**.
- **Stop** per lane (its header), Stop All as now; a row's scene button
  at its right (launch the row).
- The toolbar's previous/next sequence go through the lanes in order (a
  lane's rows, then the next lane's).
- The Sequence view's sequence menu shows the lane: "Bass · lane 2".
- A pad played by sequences in two lanes: a small mark on both sequence
  pads, and a tooltip naming the other lane.

## What I think was missing (to settle as we go)

- **Song lanes follow launcher lanes**: Record to Song writes launcher
  lane k onto song lane k, named after it (song lanes made as needed).
- **Lane mute / solo** in the launcher (mute a lane without stopping it,
  so it comes back in time) — cheap with the lane header.
- **Follow actions** (what plays after a sequence ends: the next row, any
  row, stop) — common in clip launchers; later, but the model should
  leave room (a per-sequence field).
- **Scene names and tempos** (a row's name; a row may set the tempo when
  launched) — later.
- **MIDI mapping of the window** for controllers (note → cell), and
  feedback (the controller's pads lit as the screen's) — the window is
  what makes this simple; the controller layer comes later.
- **The 64-sequence limit**: lanes share the 64 slots; a + is disabled
  when none is free (and says so).
- **Per-track loops** (audio plan step 6) are unaffected: they are inside
  a sequence.

## Order of work

1. The model, migration, file v37; model tests (launch per lane, scenes,
   moving, migration of an old project sounds the same).
2. The Perform grid as a window, lane headers, overview, drag to move.
3. Hardware and Keys through the window; Record to Song naming.
4. e2e tests, a drive script with screenshots, the guides.

## The two tweaks with it (built first)

- **Quantize and input quantize follow note repeat**: while note repeat is
  on, input quantize and the Quantize button use the repeat's rate (1/32,
  triplets…), and the repeated notes themselves are never moved (they are
  on their grid already; only the first, played hit is quantized).
- **Note Repeat in the toolbar**: a global switch, MPC-style (whatever
  pad you hold repeats at the toolbar's rate and gate), and a dropdown
  beside it (rate, gate). A pad's own repeat still works while the
  toolbar's is off.
