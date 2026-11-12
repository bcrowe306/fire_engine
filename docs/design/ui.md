# Pads design system

Status: decided 2026-11-12; the first part built (`app/ui`: densities
and `set_density`, the text sizes, `set_accent`, lit-button `toggle`,
`value_bar`; Pads: the control-size setting, the accent from the selected
pad, Rec in red that blinks). Not yet: the rest of Pads' ImGui drags and
sliders as value bars (Sensitivity, Gate, voices...), headings at 18 and
captions at 11 across the panels (knobs, the toolbar and the pad bar use
the sizes so far), Touch in layouts B and C (not built).

The rules every Pads screen follows; the layouts and the redesign's order are in
[ui-audit.md](ui-audit.md).

## Sizes

- **Control height by layout**: layout D uses **34 pt** (Comfortable);
  layout B, the Stages layout and touch devices use **44 pt** (Touch).
  Compact (28 pt, today's size) stays available.
- **Adjustable later**: a size setting (Compact, Comfortable, Touch, or a
  scale) overrides the layout's default; every size below scales with it.
- Spacing steps: 4, 8, 12, 16, 24 pt (times the scale). Inside a control
  8–12 pt across; between controls 8 pt; between groups 16 pt; around a
  panel 12 pt.
- Hit area is never smaller than the control's height in either
  direction (an icon button is square).
- **Bars are slimmer**: the toolbar's controls are 30 pt (40 at Touch)
  and flat, a shade off the bar rather than raised from it;
  rows of controls are laid out with `ui.Flex` (each item centred in the
  row's height).

## Text

Four sizes, two weights (regular, medium):

| Size | Use |
|---|---|
| 18 | Headings: a panel's or a device's title |
| 15 | Body: names, lists, menu items, values you read |
| 13 | Labels: under knobs, on buttons in dense rows, column headers |
| 11 | Captions: units, hints, the status bar's detail |

Secondary text uses the dim colour, never a smaller size alone.

## Colour

- Surfaces as now (background, surface, inset, raised, hover, pressed),
  dark by default, light as the alternative.
- **The pads area's accent is its pad's colour**: in the pads, the
  sound's devices and effects and the channel strip, selection, focus,
  the active tab, a value's arc and lit buttons take the colour of the
  pad shown, so that area says which pad you are on. The rest of the
  window (toolbar, Library, the views) keeps the theme's accent.
  (Decided 2026-11-12, after a first build where the whole window took
  it.)
  - Text on the accent picks white or near-black, whichever reads better
    against that colour.
  - A pad colour too dark or too light against the surfaces is shifted
    (lightness only, hue kept) until it reads; the pad itself keeps its
    true colour.
  - With no pad selected (or one without a colour), the accent is the
    default blue.
- Signals stay fixed whatever the accent: record and danger red, warning
  amber, OK green. A red pad's accent must still be told apart from
  record: record also shows its icon and, while recording, blinks.

## Controls

- **Knobs (arc, as now)** for sound: anything you turn while listening
  (volume, pan, cutoff, envelope times, sends). Label under it (13),
  value under that (13, or 11 for units); the arc is drawn in the accent.
- **Value bars** for settings and compact entry and display: lengths,
  swing, sensitivity, voice counts, BPM, anything set once rather than
  played, and wherever a row of knobs would not fit. Label left, value
  right, both inside the bar; drag across or type.
- **Lit buttons for on/off**: the label is the button; lit (accent tint
  and border) when on. They replace the switch-and-label toggles.
- **Segmented choices** for 2–5 options seen at once (one-shot, gate,
  loop, hold); a menu for more.
- **Buttons**: a label, or an icon with a label; icon-only only for the
  transport and universally known actions (play, stop, undo), and those
  have a tooltip and a name for tests.
- Nothing only works on hover, and every drag has a tap alternative
  (choose, then place), for touch.
