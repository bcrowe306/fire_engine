# Sequence editing: a Notes tab and an Automation tab

Status: step 1 built (the two tabs, the Automation view with today's targets); steps 2–5 under way.

The Sequence view gets two tabs, each with the whole view for what it
edits and the tools for it at the top:

- **Notes** (the default): notes, and under the grid a lane for each
  note's velocity, its chance, or a MIDI CC.
- **Automation**: one automation at a time, full height, as points joined
  by lines and curves, over the notes drawn grey (for timing only).

## Decisions (asked)

1. **Two tabs**, Notes and Automation; all tools and settings at the top,
   the tab's own tools in it. **Notes is the default**; the tab chosen is
   **remembered** while you move around the app (other views, other
   sequences, other pads) and saved with the project's view.
2. **The Notes lane**: velocity, chance and MIDI CC, per note row (CC as
   stepped values, as a MIDI lane). **A new note's chance is 100%**.
3. **What can be automated**: a pad's sound (sampler, synth), a pad's
   effects, the mixer (volume, pan, sends), buses and main and their
   effects, and plug-in parameters.
4. **Adding an automation**, all four ways: from the menu (a track, then
   a parameter); touching a control while learning; right-clicking any
   knob, **Automate**; recording knob moves while playing. **Recording
   knob moves is explicitly switched on** (off by default; nothing is
   written by turning a knob otherwise).
5. **Only the selected automation is drawn** (others are in the menu).
   (Not answered; this is the simpler default and can change.)

## What there is now

- `Auto_Point {pad, param: Lane_Param, beat, value, curve}`: a pad's lane
  of one of 15 parameters (volume, pitch, the EQ's three bands, cutoff,
  resonance, eight plug-in parameters), drawn in the Sequence view's
  lane under the grid.
- The engine already plays curves: `fire:clip`'s automation clips have
  segment shapes (linear, step, curve with a tension), and Pads' points
  carry `curve`. Each pad has three automation players (voice, EQ,
  fader).
- A new note's chance is already 1 (100%); a test will keep it so.

## The design

### The view

- Above the grid, one line for the sequence (name, length, ×2, swing),
  then the tabs and the tab's tools:
  - **Notes**: Select, Draw, Erase, Move; snap; Quantize, input quantize;
    hear rows; Drums | Piano roll. The lane under the grid (slim, its top
    edge dragged): its name picks **Velocity**, **Chance**, or a **CC**
    (a number, named where it is a known one: 1 Mod wheel, 7 Volume, 10
    Pan, 11 Expression, 74 Cutoff...), and **+ CC…** adds one.
  - **Automation**: the automation menu (what is automated in this
    sequence, then **+ New automation…** and **Touch a control**); Select,
    Points, Line, Curve, Erase; snap; **Show notes**. The value scale at
    the left in the parameter's units; the point under the mouse shows
    its time and value.
- The notes under the curve: every row's notes in grey at 20% (a drum
  sequence as rows squeezed to the height; a piano roll as itself), not
  clickable.

### Targets

An automation's target becomes general:

```
Auto_Target :: struct {
	track:  Track_Ref,     // a pad, a bus, main, the performance effects
	device: Device_Ref,    // the instrument, an insert slot, the EQ, the strip
	param:  Param_Id,      // the device's parameter (as its node knows it)
}
```

- A pad's sound: the sampler's and synth's parameters (by id).
- A pad's effects: each insert's parameters.
- The mixer: a strip's volume, pan, and each send's level.
- Buses and main: the same, and their effects.
- Plug-ins: any parameter (not only eight), by the plug-in's id.
- Today's `Lane_Param` lanes read into these targets (a new project file
  version; old files open as they did).

The engine gets an automation player for each target used (made when an
automation is added, freed when it is cleared), instead of three fixed
ones a pad; the audio thread work stays the clip player's.

### Adding and recording

- **Menu**: a track, then its devices, then a parameter (searchable).
- **Touch a control**: the menu's entry arms learning; the next knob or
  slider moved anywhere becomes the automation (Escape cancels).
- **Right-click a knob**: **Automate** (or **Show automation** when it
  has one): opens the Automation tab on it.
- **Recording knob moves**: a lit button beside Rec, **Automation**
  (off by default). With it on and recording, a knob moved writes points
  along the move (thinned to the shape), over what was there for as long
  as it is held (touch); with it off, knobs only change the sound.

### MIDI CC in the Notes lane

- CC events per note row (a pad), stepped, at the grid's resolution or
  drawn freely; sent with the pad's notes to its MIDI out and to a
  plug-in instrument; a sampler or synth pad has no CC input, so its CC
  lane offers to become an automation instead (later: a MIDI map).

## Order of work

1. **Tabs and layout**: the two tabs, every tool and setting at the top,
   the slim lane; Notes the default; the tab remembered and saved; the
   chance default kept (test). The Automation tab with today's targets,
   the notes dimmed under the curve, point/line/curve tools, the menu
   with today's lanes and New. (Uses what the model has.)
2. **General targets**: `Auto_Target`, the engine's players per target,
   the file format (v28) with old lanes read in; the menu's track →
   device → parameter list for the sound, effects, mixer, buses, main and
   plug-ins.
3. **Right-click Automate** and **Touch a control**.
4. **Recording knob moves**: the Automation arm button, touch writing,
   thinning; undo as one step a pass.
5. **MIDI CC lanes** in the Notes tab: the model, the file format, MIDI
   out and plug-in instruments.

Each step: model tests, e2e tests, a drive script with screenshots, the
Pads guide, and cloud tests at the end.
