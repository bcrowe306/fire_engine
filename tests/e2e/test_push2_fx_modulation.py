"""Chorus, Flanger and Phaser on Push 2's display (docs/design/push2-fx-modulation.md):
each in an effect slot, as a Perform effect and on the synth's Effects tab,
its banks named, every bank's every knob turning its parameter (choices
too), Perform's Intensity first in every bank, the synth tab's picker and
On; Mute + Device and Delete + Device on a slot; the display saved for
every bank; the panel's drawing time printed."""

import os

import pytest

from push2_fx import DEVICE, Device, bank, banks, draw_us, in_slot, moves, on_synth, pads, plug, press, save, turn, view  # noqa: F401

MUTE, DELETE = 0x3C, 0x76
LOWER = 20  # the lower row's first button (CC 20..27)


def fx_id(effect, field):
    """A synth effect's parameter id (synth.effect_param: 700 + effect × 32 + field)."""
    return 700 + effect * 32 + field


CHORUS, FLANGER, PHASER = 0, 6, 7  # (fx.Effect)

# Each device: its banks, and each bank's knobs: (bank, column, parameter, direction)
# (down for those whose default is their top). Rate's column is the free rate's
# (Hz); with Sync on a division, the same knob turns Tempo.
DEVICES = {
    "chorus": {
        "effect": CHORUS,
        "banks": ["Main", "Delays"],
        "knobs": [
            (0, 0, fx_id(CHORUS, 3), +1),   # Rate (Hz)
            (0, 1, fx_id(CHORUS, 9), +1),   # Depth
            (0, 2, fx_id(CHORUS, 1), -1),   # Voices (a choice; 4 at first)
            (0, 3, fx_id(CHORUS, 5), +1),   # Feedback
            (0, 4, fx_id(CHORUS, 6), +1),   # Mix
            (1, 0, fx_id(CHORUS, 10), +1),  # Delay 1
            (1, 1, fx_id(CHORUS, 11), +1),  # Delay 2
            (1, 2, fx_id(CHORUS, 7), +1),   # Cutoff
            (1, 3, fx_id(CHORUS, 8), -1),   # Spread (1 at first)
        ],
        "sync": (0, 5, fx_id(CHORUS, 2)), "rate": (0, 0), "tempo": fx_id(CHORUS, 4), "on": fx_id(CHORUS, 0),
    },
    "flanger": {
        "effect": FLANGER,
        "banks": ["Main"],
        "knobs": [
            (0, 0, fx_id(FLANGER, 2), +1),  # Rate (Hz)
            (0, 1, fx_id(FLANGER, 7), +1),  # Depth
            (0, 2, fx_id(FLANGER, 4), +1),  # Center
            (0, 3, fx_id(FLANGER, 5), +1),  # Feedback
            (0, 4, fx_id(FLANGER, 6), -1),  # Mix (0.5, its top, at first)
            (0, 6, fx_id(FLANGER, 8), +1),  # Offset
        ],
        "sync": (0, 5, fx_id(FLANGER, 1)), "rate": (0, 0), "tempo": fx_id(FLANGER, 3), "on": fx_id(FLANGER, 0),
    },
    "phaser": {
        "effect": PHASER,
        "banks": ["Main", "LFO"],
        "knobs": [
            (0, 0, fx_id(PHASER, 2), +1),   # Rate (Hz)
            (0, 1, fx_id(PHASER, 8), +1),   # Depth
            (0, 2, fx_id(PHASER, 6), +1),   # Center
            (0, 3, fx_id(PHASER, 4), +1),   # Feedback
            (0, 4, fx_id(PHASER, 7), +1),   # Blend
            (0, 5, fx_id(PHASER, 5), -1),   # Mix (1 at first)
            (1, 1, fx_id(PHASER, 2), +1),   # Rate again, beside Sync
            (1, 2, fx_id(PHASER, 9), +1),   # Offset
        ],
        "sync": (1, 0, fx_id(PHASER, 1)), "rate": (1, 1), "tempo": fx_id(PHASER, 3), "on": fx_id(PHASER, 0),
    },
}


def step(pid):
    """Encoder steps that surely move parameter `pid` (a choice: one, three detents)."""
    return 3


def every_knob(pads, d, kind, lead, where, intensity=False):
    """Every bank shown, its knobs turned and checked, the display saved;
    the Sync choice, then Rate turning Tempo; draw time printed."""
    spec = DEVICES[kind]
    assert banks(pads) == len(spec["banks"]), view(pads)
    for b, name in enumerate(spec["banks"]):
        bank(pads, b)
        save(pads, f"{kind}_{where}_{name.lower()}")
        if intensity:  # Perform: Intensity on column 0 of every bank
            before = pads.state()["perf_intensity"][0]
            turn(pads, 0, -6)
            after = pads.state()["perf_intensity"][0]
            assert after < before, (b, before, after)
        for kb, col, pid, sign in spec["knobs"]:
            if kb == b:
                moves(pads, d, lead + col, pid, sign * step(pid))
    # Sync: a choice; on a division, Rate turns Tempo.
    sb, scol, sync = spec["sync"]
    bank(pads, sb)
    moves(pads, d, lead + scol, sync, 3)
    assert round(d.get(sync)) == 1
    rb, rcol = spec["rate"]
    bank(pads, rb)
    save(pads, f"{kind}_{where}_synced")
    moves(pads, d, lead + rcol, spec["tempo"], 3)
    bank(pads, 0)
    last, most = draw_us(pads)
    print(f"DRAW {kind} {where}: last {last:.0f} us, most {most:.0f} us")
    assert 0 < last < 5000, (last, most)


def perform(pads, kind, n=0):
    """`kind` as Perform's effect `n`, shown on the Push. (The kit's
    in_perform presses Device after choosing it, and Device from another
    view shows the selected pad's chain: here Device is pressed first.)"""
    plug(pads)
    pads.cmd(f"perf_fx {n} {kind}")
    press(pads, DEVICE)
    pads.wait(8)
    pads.cmd(f"edit_fx perf {n}")
    pads.wait(8)
    return Device(pads, "perf", {"place": "Perf", "index": n, "slot": 0})


def held(pads, cc, then):
    pads.cmd(f"midiport play push B0 {cc:02X} 7F")
    then()
    pads.cmd(f"midiport play push B0 {cc:02X} 00")
    pads.wait(8)


@pytest.mark.parametrize("kind", list(DEVICES))
def test_push2_modulation_in_a_slot(pads, fixtures, kind):
    d = in_slot(pads, kind, sample=os.path.join(fixtures, "loop.wav"))
    assert pads.api("effect_name", s=d.slot).lower() == kind
    every_knob(pads, d, kind, 0, "slot")
    state = lambda: pads.api("effect_state", s=d.slot)
    assert state()["on"] is True
    held(pads, MUTE, lambda: press(pads, DEVICE))  # Mute + Device: off
    assert state()["on"] is False
    save(pads, f"{kind}_slot_off")
    held(pads, MUTE, lambda: press(pads, DEVICE))  # and on again
    assert state()["on"] is True
    held(pads, DELETE, lambda: press(pads, DEVICE))  # Delete + Device: removed
    assert state()["kind"] == 0


@pytest.mark.parametrize("kind", list(DEVICES))
def test_push2_modulation_in_perform(pads, kind):
    d = perform(pads, kind)
    every_knob(pads, d, kind, 1, "perform", intensity=True)


@pytest.mark.parametrize("kind", list(DEVICES))
def test_push2_modulation_on_the_synth(pads, kind):
    spec = DEVICES[kind]
    d = on_synth(pads, kind)
    every_knob(pads, d, kind, 1, "synth")
    # On: the lower row's last button.
    on = spec["on"]
    assert round(d.get(on)) == 0
    press(pads, LOWER + 7)
    pads.wait(4)
    assert round(d.get(on)) == 1
    save(pads, f"{kind}_synth_on")
    # The picker (column 0 of every bank): the chain's next effect (or the one
    # before), whose own knobs then take the encoders; and back.
    rate = spec["knobs"][0][2]
    d.set(spec["sync"][2], 0)  # (Rate: its Hz again)
    if kind == "chorus":  # (first in the chain: the next is the Compressor)
        turn(pads, 0, 3)
        before = d.get(rate)
        turn(pads, 1, 5)
        assert d.get(rate) == before  # (not the chorus's Rate any more)
        turn(pads, 0, -3)
    else:
        other = "phaser" if kind == "flanger" else "flanger"
        turn(pads, 0, 3 if kind == "flanger" else -3)
        moves(pads, d, 1, DEVICES[other]["knobs"][0][2], 3)
        turn(pads, 0, -3 if kind == "flanger" else 3)
    moves(pads, d, 1, rate, 3)  # its own again
