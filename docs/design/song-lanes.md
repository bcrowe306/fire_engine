# The Song view: free lanes of clips

Status: built (all three steps). Limits for later: overlapping clips on one lane both play (nothing trims the one underneath); an audio pad's takes play from the topmost lane's clip only; MIDI export writes the tempo lane but not the time signature lane.

Today a song is a chain of steps: one sequence at a time, each repeated
1–16 times. It becomes **lanes of clips**: any sequence on any lane,
placed at any bar and as long as you like, several playing at once (a
drum loop on one lane, a fill or a bass sequence on another).

Later (not this work): an **Arranger playback mode** whose lanes are the
pads (tracks); putting a sequence into the arrangement copies each pad's
notes and events into its lane.

## Decisions (asked, 2026-11-12)

1. **Lanes of clips**, free lanes: any sequence on any lane; a clip plays
   its whole sequence (all its pads).
2. **One tall timeline**: the cards row goes; the lanes fill the view;
   each clip shows its name, its section, a preview of its notes, and
   where its sequence loops round.
3. **The selected clip's settings in a strip under the lanes** (one line,
   full width); the side panel goes.
4. **The bottom area is folded by default** in the Song view (the thin
   bar of 16 pads); unfold it to edit a sound.
5. **A clip is dragged to any length**: it loops its sequence until its
   end (a part loop cut short is fine), by bars (Shift: beats).
6. **Tempo and time signature are song lanes on top** (the tempo lane
   there already; a new time signature lane), for the whole song. Old
   steps' own tempos and meters move into them.
7. **Layout A**: a narrow Sequences list at the Song view's left (drag
   one into a lane), the lanes beside it; the Library stays as it is.
8. **Adding clips**: drag a sequence from the list; with **Draw**, drag
   along a lane to paint the current sequence there; **double-click** a
   lane for the current sequence at that bar, its own length;
   **Alt-drag** a clip to copy it, **Cmd+D** duplicates the selected
   clips after themselves.
9. **A lane's header**: its name (Lane 1, 2... ; double-click to rename)
   and Mute and Solo. (Not answered; chosen as the simpler default.)
10. **A grid behind the clips**: a line every bar by default; zoomed
    out, every 2, 4, 8... bars (the lines kept at least about 24 px
    apart); zoomed in, the beats too. The view zooms in time
    (Cmd+scroll, or pinch; Cmd+0 fits the song).

## The model

```
Song_Lane :: struct { name: [16]u8, mute, solo: bool }
Song_Clip :: struct {
	lane:      u8,
	slot:      u8,   // the sequence
	at:        f64,  // song beat it starts at
	length:    f64,  // beats it plays (loops its part to fill them)
	start:     f64,  // its part: from this beat of the sequence...
	part:      f64,  // ...this many beats (0: to its end)
	phase:     f64,  // beats into its part it begins (its left end trimmed)
	transpose: i8,
	mute:      bool,
	label:     [16]u8, // a section's name, shown on the clip
}
Meter_Point :: struct { bar: int, sig: Time_Sig } // the time signature lane
```

- `Song` keeps its tempo lane, markers and loop range, and gains lanes,
  clips and meter points; its length is the last clip's end.
- **A new file version** (v30): an old chain opens as clips on Lane 1,
  one after another, as long as their repeats; steps' own tempos become
  tempo points (`tempo_lane_from_steps` already does this) and their
  meters meter points. It plays as it did.
- **The plan** (what the sequencer plays) becomes the clips as
  segments, which can overlap; the notes' and automation's clips already
  merge every segment, so overlapping clips play together. A muted or
  unsoloed lane's clips are left out.
- **Recording in song mode** goes into the sequence of the clip under the
  playhead on the topmost lane playing.
- **Audio takes** (an audio pad's recordings in a sequence) play from one
  clip at a time: the topmost lane's. (A limit, for later.)

## Order of work

1. **The model**: lanes, clips, meter points; the plan from clips; v30
   with the chain read in; song length, bars and meters from the new
   lanes; MIDI export and the control commands (`song add`, `song step`
   become clip commands; old drive scripts are updated). Model tests.
2. **The view**: layout A; the song lanes on top (markers, time, tempo);
   the lanes with clips (move, copy, resize either end, select,
   marquee, delete, copy/paste, Cmd+D); the three ways to add; lane
   headers; the grid and zoom; the clip strip; the bottom area folded
   by default in Song.
3. **Tests and docs**: e2e tests, a drive script with screenshots, the
   Pads guide, and cloud tests at the end.
