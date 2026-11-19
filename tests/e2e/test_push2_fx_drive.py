"""Distortion and Ring mod on Push 2's display (docs/design/push2-fx-drive.md),
and the old projects' Saturation and Bit-crusher (distortions once read):
each in an effect slot and as a Perform effect, the Distortion also on the
synth's Effects tab; its banks named, every bank's every knob turning its
parameter (choices too), Perform's Intensity first in every bank, the synth
tab's picker and On; Mute + Device and Delete + Device on a slot; the
display saved for every bank; the panel's drawing time printed."""

import os

import pytest

from push2_fx import DEVICE, Device, bank, banks, draw_us, in_perform, in_slot, moves, on_synth, pads, plug, press, save, turn, view  # noqa: F401

MUTE, DELETE = 0x3C, 0x76
LOWER = 20  # the lower row's first button (CC 20..27)
DISTORTION = 3  # (fx.Effect)


def dist(field):
    """The distortion's parameter (synth.effect_param: 700 + effect × 32 + field)."""
    return 700 + DISTORTION * 32 + field


ON, TYPE, DRIVE, MIX, FILTER, CUTOFF, RESONANCE, BLEND = (dist(f) for f in range(8))
RING_HZ, RING_MIX = 1, 2  # (dsp.RING_PARAM_*)

# Each device: its banks, and each bank's knobs: (bank, column, parameter,
# direction) (down for those whose default is their top).
DEVICES = {
    "distortion": {
        "banks": ["Main"],
        "knobs": [
            (0, 0, DRIVE, +1),
            (0, 1, TYPE, +1),       # a choice: Soft clip, then Hard clip
            (0, 2, MIX, -1),        # (1 at first)
            (0, 3, FILTER, +1),     # a choice: No filter, then Filter before
            (0, 4, CUTOFF, +1),
            (0, 5, RESONANCE, +1),
            (0, 6, BLEND, +1),
        ],
    },
    "ring": {
        "banks": ["Main"],
        "knobs": [
            (0, 0, RING_HZ, +1),   # (440 Hz at first)
            (0, 1, RING_MIX, -1),  # (1 at first)
        ],
    },
}


def every_knob(pads, d, kind, lead, where, intensity=None):
    """Every bank shown, its knobs turned and checked, the display saved;
    draw time printed. `intensity`: Perform's effect number (its Intensity
    on column 0 of every bank)."""
    spec = DEVICES[kind]
    assert banks(pads) == len(spec["banks"]), view(pads)
    for b, name in enumerate(spec["banks"]):
        bank(pads, b)
        save(pads, f"{where}_{name.lower()}")
        if intensity is not None:
            before = pads.state()["perf_intensity"][intensity]
            turn(pads, 0, -6)
            after = pads.state()["perf_intensity"][intensity]
            assert after < before, (b, before, after)
        for kb, col, pid, sign in spec["knobs"]:
            if kb == b:
                moves(pads, d, lead + col, pid, sign * 3)
        save(pads, f"{where}_{name.lower()}_turned")
    last, most = draw_us(pads)
    print(f"DRAW {kind} {where}: last {last:.0f} us, most {most:.0f} us")
    assert 0 < last < 5000, (last, most)


def held(pads, cc, then):
    pads.cmd(f"midiport play push B0 {cc:02X} 7F")
    then()
    pads.cmd(f"midiport play push B0 {cc:02X} 00")
    pads.wait(8)


def mute_and_delete(pads, d, where):
    """Mute + Device: off, then on; Delete + Device: removed."""
    state = lambda: pads.api("effect_state", s=d.slot)
    assert state()["on"] is True
    held(pads, MUTE, lambda: press(pads, DEVICE))
    assert state()["on"] is False
    save(pads, f"{where}_off")
    held(pads, MUTE, lambda: press(pads, DEVICE))
    assert state()["on"] is True
    held(pads, DELETE, lambda: press(pads, DEVICE))
    assert state()["kind"] == 0


def playing(pads, where):
    """The pad held (its sample through the slot): the display with the
    output's spectrum on it."""
    pads.until(lambda s: s["pads"][0]["ready"], what="loop.wav decoded")
    pads.cmd("hit 0")
    pads.wait(20)
    save(pads, f"{where}_playing")
    pads.cmd("release 0")
    pads.wait(3)


def perform_default(pads, n):
    """Perform's effect `n` as a new project has it (no perf_fx: the old
    kinds made distortions by `new_effect`), shown on the Push."""
    plug(pads)
    pads.wait(10)
    pads.cmd(f"edit_fx perf {n}")
    press(pads, DEVICE)
    pads.wait(8)
    pads.cmd(f"edit_fx perf {n}")
    pads.wait(5)
    return Device(pads, "perf", {"place": "Perf", "index": n, "slot": 0})


@pytest.mark.parametrize("kind", list(DEVICES))
def test_push2_drive_in_a_slot(pads, fixtures, kind):
    d = in_slot(pads, kind, sample=os.path.join(fixtures, "loop.wav"))
    assert pads.api("effect_name", s=d.slot) == ("Distortion" if kind == "distortion" else "Ring mod")
    every_knob(pads, d, kind, 0, f"{kind}_slot")
    if kind == "distortion":  # (the filter on: after the curve, a band-pass)
        d.set(FILTER, 2)
        d.set(BLEND, 1)
        d.set(DRIVE, 18)
        save(pads, f"{kind}_slot_filter_after")
    playing(pads, f"{kind}_slot")
    mute_and_delete(pads, d, f"{kind}_slot")


@pytest.mark.parametrize("old", ["saturation", "bitcrusher"])
def test_push2_old_drive_slots_are_distortions(pads, fixtures, old):
    """An old project's Saturation or Bit-crusher: read as the Distortion
    (pm.convert_slot, as `insert` makes one), its panel the Distortion's."""
    d = in_slot(pads, old, sample=os.path.join(fixtures, "loop.wav"))
    assert pads.api("effect_name", s=d.slot) == "Distortion"
    if old == "saturation":
        assert round(d.get(TYPE)) == 0 and abs(d.get(DRIVE) - 6) < 0.01  # soft clip at its drive
    else:
        assert round(d.get(TYPE)) == 4  # bit crush
    assert banks(pads) == 1
    save(pads, f"{old}_slot_main")
    moves(pads, d, 0, DRIVE, +3)
    save(pads, f"{old}_slot_turned")
    if old == "bitcrusher":  # the down-sampler, its hold
        d.set(TYPE, 5)
        save(pads, f"{old}_slot_down_sample")
    last, most = draw_us(pads)
    print(f"DRAW {old} slot: last {last:.0f} us, most {most:.0f} us")
    assert 0 < last < 5000, (last, most)


@pytest.mark.parametrize("kind", list(DEVICES))
def test_push2_drive_in_perform(pads, kind):
    d = in_perform(pads, kind)
    every_knob(pads, d, kind, 1, f"{kind}_perform", intensity=0)


@pytest.mark.parametrize("n,name", [(9, "bitcrusher"), (10, "ring"), (15, "saturation")])
def test_push2_drive_in_a_new_projects_perform(pads, n, name):
    """A new project's Perform effects 10, 11 and 16: its Bit-crusher and
    Saturation (distortions now) and its Ring mod."""
    d = perform_default(pads, n)
    kind = "ring" if name == "ring" else "distortion"
    assert pads.api("effect_name", s=d.slot) == ("Ring mod" if kind == "ring" else "Distortion")
    every_knob(pads, d, kind, 1, f"{name}_perform{n}", intensity=n)


def test_push2_distortion_on_the_synth(pads):
    d = on_synth(pads, "distortion")
    every_knob(pads, d, "distortion", 1, "distortion_synth")
    # On: the lower row's last button.
    assert round(d.get(ON)) == 0
    press(pads, LOWER + 7)
    pads.wait(4)
    assert round(d.get(ON)) == 1
    save(pads, "distortion_synth_on")
    # The picker (column 0 of every bank): the chain's next effect (the EQ),
    # whose own knobs then take the encoders; and back.
    turn(pads, 0, 3)
    before = d.get(DRIVE)
    turn(pads, 1, 5)
    assert d.get(DRIVE) == before  # (not the distortion's Drive any more)
    turn(pads, 0, -3)
    moves(pads, d, 1, DRIVE, 3)  # its own again
