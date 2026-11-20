"""Tone on Push 2 (docs/design/push2-fx-tone.md): the EQ and the Filter each
with its response and named banks, wherever it can be: an effect slot, a
Perform effect (Intensity first in every bank), the synth's Effects tab
(its picker first, On on the lower row's last); old projects' Low-, High-
and Band-pass as Filters; the pad's own EQ (EQ On on the lower row). Every
bank's every knob moves its parameter; the display saved for each bank."""

import os

from push2_fx import _select_pad, bank, banks, draw_us, in_perform, in_slot, knobs_shown, moves, on_synth, pads, plug, press, save, turn, view  # noqa: F401 (pads: its fixture)

# The synth's effect parameters (synth.effect_param: 700 + 32 × the effect + its field).
EQ = 700 + 32 * 4
EQ_ON = EQ


def eq(band, field):
    """The EQ's band `band` (0 low, 1 band, 2 high), field 0 mode, 1 cutoff, 2 gain, 3 resonance."""
    return EQ + 1 + band * 4 + field


FILTER = 700 + 32 * 5
(F_ON, F_MODEL, F_STYLE, F_CUTOFF, F_RES, F_DRIVE, F_BLEND, F_MIX, F_GAIN,
 F_VX, F_VY, F_TRANSPOSE, F_FRES, F_SPREAD, F_COMB) = range(FILTER, FILTER + 15)

LOWER = 20  # the lower row's first button (CC)
MUTE, DELETE, DEVICE = 0x3C, 0x76, 0x6E
CHOICE = 3  # detents a choice's step takes

# Each bank's knobs: (column, parameter, detents).
EQ_BANDS = [(0, eq(0, 1), 10), (1, eq(0, 2), 10), (2, eq(1, 1), 10), (3, eq(1, 2), -10), (4, eq(2, 1), -10), (5, eq(2, 2), 10)]


def eq_band(b):
    return [(0, eq(b, 1), 10 if b < 2 else -10), (1, eq(b, 2), 10), (2, eq(b, 3), 10), (3, eq(b, 0), CHOICE)]


FILTER_MAIN = [(0, F_CUTOFF, -10), (1, F_RES, 10), (4, F_BLEND, 10), (5, F_DRIVE, 10), (6, F_MIX, -10), (2, F_MODEL, CHOICE), (3, F_STYLE, CHOICE)]
FILTER_SHAPE = [(0, F_GAIN, 10), (1, F_COMB, 10), (2, F_VX, 10), (3, F_VY, -10), (4, F_TRANSPOSE, 10), (5, F_FRES, 10), (6, F_SPREAD, 10)]


def knobs(pads, d, knobs, lead=0):
    for col, pid, steps in knobs:
        moves(pads, d, col + lead, pid, steps)


def intensity_on_column_0(pads):
    before = pads.state()["perf_intensity"][0]
    turn(pads, 0, -10)
    after = pads.state()["perf_intensity"][0]
    assert after < before, (before, after)
    turn(pads, 0, 10)


def on_last(pads, d, pid):
    """The synth tab's On (the lower row's last) switches the effect; left on."""
    pads.wait(8)  # (the tab drawn with its On before it's pressed)
    before = d.get(pid)
    press(pads, LOWER + 7)
    pads.wait(4)
    assert d.get(pid) == 1 - before
    if d.get(pid) == 0:
        press(pads, LOWER + 7)
        pads.wait(4)
    assert d.get(pid) == 1


def playing(pads, name):
    """The display saved with pad A1 sounding (its spectrum on the picture)."""
    pads.until(lambda s: s["pads"][0]["ready"], what="loop.wav decoded")
    pads.cmd("hit 0")
    pads.wait(20)
    assert pads.pad(0)["level"] > 0
    save(pads, name)


def held(pads, cc, then):
    pads.cmd(f"midiport play push B0 {cc:02X} 7F")
    then()
    pads.cmd(f"midiport play push B0 {cc:02X} 00")
    pads.wait(8)


def on_and_removed(pads, d, name):
    """Mute + Device: off and on again; Delete + Device: removed."""
    held(pads, MUTE, lambda: press(pads, DEVICE))
    assert pads.api("effect_state", s=d.slot)["on"] is False
    save(pads, f"{name}_off")
    held(pads, MUTE, lambda: press(pads, DEVICE))
    assert pads.api("effect_state", s=d.slot)["on"] is True
    held(pads, DELETE, lambda: press(pads, DEVICE))
    assert pads.api("effect_state", s=d.slot)["kind"] == 0


def lower_lit(pads, mask=0x7F):
    return view(pads)["lit"] & mask


def eq_banks(pads, d, name, lead=0, perform=False):
    assert banks(pads) == 4
    # The lower row: its cuts (each band's mode), lit while cut.
    assert lower_lit(pads, 0x7) == 0, view(pads)
    for b in range(3):
        press(pads, LOWER + b)
        pads.wait(4)
        assert d.get(eq(b, 0)) == 1, b
    assert lower_lit(pads, 0x7) == 0x7, view(pads)
    save(pads, f"{name}_cuts")
    for b in range(3):
        press(pads, LOWER + b)
        pads.wait(4)
        assert d.get(eq(b, 0)) == 0, b
    knobs(pads, d, EQ_BANDS, lead)
    if perform:
        intensity_on_column_0(pads)
    save(pads, f"{name}_eq")
    for b in range(3):
        bank(pads, b + 1)
        knobs(pads, d, eq_band(b), lead)  # (its mode last: cut now)
        if perform:
            intensity_on_column_0(pads)
        save(pads, f"{name}_{['low', 'band', 'high'][b]}")
    bank(pads, 0)


def filter_banks(pads, d, name, lead=0, perform=False):
    assert banks(pads) == 2
    # The lower row: the blend's three (an Analog or Digital 12 dB: low-, band-, high-pass).
    for k in (2, 1, 0):
        press(pads, LOWER + k)
        pads.wait(4)
        assert d.get(F_BLEND) == k
        assert lower_lit(pads, 0x7) == 1 << k, view(pads)
    knobs(pads, d, FILTER_MAIN, lead)
    if perform:
        intensity_on_column_0(pads)
    save(pads, f"{name}_filter")
    bank(pads, 1)
    knobs(pads, d, FILTER_SHAPE, lead)
    if perform:
        intensity_on_column_0(pads)
    save(pads, f"{name}_shape")
    bank(pads, 0)
    # The Formant model: its vowel on the picture (bank 2's knobs not bracketed).
    d.set(F_MODEL, 5)
    save(pads, f"{name}_formant")
    d.set(F_MODEL, 6)  # Comb
    save(pads, f"{name}_comb")
    # The style's box: a name short enough to sit beside "Style" ("LH
    # flange +" for "Low/high flange +"); touched, its list the full names.
    style = lead + 3
    assert knobs_shown(pads)[style]["label"] == "Style", knobs_shown(pads)[style]
    assert knobs_shown(pads)[style]["value"] in ("LH comb", "LH flange +", "LH flange −", "Band comb", "Bd flange +", "Bd flange −"), knobs_shown(pads)[style]
    pads.cmd(f"midiport play push 90 {style:02X} 7F")
    pads.wait(4)
    save(pads, f"{name}_comb_styles")
    pads.cmd(f"midiport play push 90 {style:02X} 00")
    pads.wait(3)


# --- EQ ---------------------------------------------------------------------------------------


def test_eq_in_a_slot(pads, fixtures):
    d = in_slot(pads, "eq", sample=os.path.join(fixtures, "loop.wav"))
    assert pads.api("effect_name", s=d.slot) == "EQ"
    eq_banks(pads, d, "eq_slot")
    d.set(eq(0, 2), 9)
    d.set(eq(1, 2), -6)
    d.set(eq(2, 2), 12)
    playing(pads, "eq_slot_playing")
    print("draw µs (eq, slot):", draw_us(pads))
    assert 0 < draw_us(pads)[0] < 5000
    on_and_removed(pads, d, "eq_slot")


def test_eq_on_the_synths_effects_tab(pads):
    d = on_synth(pads, "eq")
    on_last(pads, d, EQ_ON)
    eq_banks(pads, d, "eq_synth", lead=1)
    # The picker first (another effect: its knobs no longer the EQ's).
    turn(pads, 0, CHOICE)
    before = d.get(eq(0, 2))
    turn(pads, 2, 10)
    assert d.get(eq(0, 2)) == before
    turn(pads, 0, -CHOICE)  # back to the EQ
    moves(pads, d, 2, eq(0, 2), 10)
    print("draw µs (eq, synth):", draw_us(pads))


def test_eq_as_a_perform_effect(pads):
    d = in_perform(pads, "eq")
    eq_banks(pads, d, "eq_perform", lead=1, perform=True)


# --- Filter -----------------------------------------------------------------------------------


def test_filter_in_a_slot(pads, fixtures):
    d = in_slot(pads, "filter", sample=os.path.join(fixtures, "loop.wav"))
    assert pads.api("effect_name", s=d.slot) == "FX Filter" or "filter" in pads.api("effect_name", s=d.slot).lower()
    filter_banks(pads, d, "filter_slot")
    d.set(F_MODEL, 0)
    d.set(F_RES, 0.7)
    playing(pads, "filter_slot_playing")
    print("draw µs (filter, slot):", draw_us(pads))
    assert 0 < draw_us(pads)[0] < 5000
    on_and_removed(pads, d, "filter_slot")


def test_filter_on_the_synths_effects_tab(pads):
    d = on_synth(pads, "filter")
    on_last(pads, d, F_ON)
    filter_banks(pads, d, "filter_synth", lead=1)
    print("draw µs (filter, synth):", draw_us(pads))


def test_filter_as_a_perform_effect(pads):
    d = in_perform(pads, "filter")
    filter_banks(pads, d, "filter_perform", lead=1, perform=True)


def test_perform_low_pass_sweeps_as_it_is_pressed(pads):
    """Perform's first effect (a project's Low-pass, a Filter now): held,
    its picture's cutoff where the press has it."""
    plug(pads)
    pads.cmd("edit_fx perf 0")
    pads.wait(10)
    press(pads, DEVICE)
    pads.wait(8)
    pads.cmd("edit_fx perf 0")
    pads.wait(5)
    assert banks(pads) == 2
    assert lower_lit(pads, 0x7) == 1, view(pads)  # (Low-pass)
    save(pads, "perform_low_pass")
    pads.api("effect_hold", index=0, on=True, intensity=0.4)
    pads.wait(4)
    save(pads, "perform_low_pass_held")
    pads.api("effect_hold", index=0, on=False)


def test_old_projects_low_high_and_band_pass_are_filters(pads, fixtures):
    """The old kinds (still known to the shell) go in as Filters: Digital,
    their response by the blend; each its Filter panel."""
    plug(pads)
    pads.api("pad_load_sample", pad=0, path=os.path.join(fixtures, "loop.wav"))
    _select_pad(pads, 0)
    for k, (kind, lit) in enumerate((("lowpass", 1), ("bandpass", 2), ("highpass", 4))):
        pads.cmd(f"insert 0 {k} {kind}")
        pads.cmd(f"edit_fx pad 0 {k}")
        press(pads, DEVICE)
        pads.wait(8)
        pads.cmd(f"edit_fx pad 0 {k}")
        pads.wait(5)
        slot = {"place": "Insert", "index": 0, "slot": k}
        assert pads.api("effect_get_param", s=slot, id=F_MODEL) == 3  # (Digital)
        assert banks(pads) == 2
        assert lower_lit(pads, 0x7) == lit, (kind, view(pads))
        assert draw_us(pads)[0] > 0
        save(pads, f"old_{kind}")


# --- the pad's EQ -----------------------------------------------------------------------------


class PadEq:
    """The pad's EQ: its band gains (dsp.eq_band_param(b, Gain_Db): 100 + 10 b + 4)."""

    def __init__(self, pads, pad=0):
        self.pads, self.pad = pads, pad

    def get(self, pid):
        return self.pads.api("param_get", ref={"track": "Pad", "index": self.pad, "device": "Eq", "param": pid})


def test_the_pads_own_eq(pads, fixtures):
    plug(pads)
    pads.api("pad_load_sample", pad=0, path=os.path.join(fixtures, "loop.wav"))
    _select_pad(pads, 0)
    press(pads, DEVICE)
    pads.wait(8)
    pads.api("ui_show", name="eq")
    pads.wait(5)
    assert pads.state()["device"] == "Eq", pads.state()
    d = PadEq(pads)
    assert banks(pads) == 1
    save(pads, "pad_eq_flat")
    # EQ On (the lower row's first): Mute + Device doesn't turn it off.
    was = pads.pad(0)["eq_on"]
    press(pads, LOWER + 0)
    pads.wait(4)
    assert pads.pad(0)["eq_on"] is (not was)
    if not pads.pad(0)["eq_on"]:
        press(pads, LOWER + 0)
        pads.wait(4)
    assert pads.pad(0)["eq_on"] is True
    assert lower_lit(pads, 0x1) == 1
    held(pads, MUTE, lambda: press(pads, DEVICE))
    assert pads.pad(0)["eq_on"] is True
    for col, pid, steps in ((0, 104, 20), (1, 114, -15), (2, 124, 25)):
        moves(pads, d, col, pid, steps)
    save(pads, "pad_eq")
    playing(pads, "pad_eq_playing")
    print("draw µs (pad eq):", draw_us(pads))
    assert 0 < draw_us(pads)[0] < 5000
    press(pads, LOWER + 0)
    pads.wait(4)
    assert pads.pad(0)["eq_on"] is False
    save(pads, "pad_eq_off")
