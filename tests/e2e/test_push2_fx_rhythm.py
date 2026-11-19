"""Cutter, Stutter and Pitch shift on Push 2's display (docs/design/push2-fx-rhythm.md):
each in a pad's effect slot and as a Perform effect, its bank named, every
knob turning its parameter (the divisions' dropdowns too), Perform's
Intensity first; Mute + Device and Delete + Device on a slot; the stutter's
Repeat (hold) button; the display saved stopped, playing and (Perform) held;
the panel's drawing time printed."""

import os

import pytest

from push2_fx import DEVICE, bank, banks, draw_us, in_perform, in_slot, moves, pads, press, save, turn, view  # noqa: F401

MUTE, DELETE = 0x3C, 0x76
LOWER = 20  # the lower row's first button (CC 20..27)

# Each device: its banks, and each bank's knobs: (column, parameter id, steps)
# (- for those whose default is their top, or that turn the other way).
DEVICES = {
    "cutter": {
        "banks": ["Gate"],
        "knobs": [(0, 1, 3), (1, 2, 10), (2, 3, -10)],  # Rate (faster: fewer beats), Duty, Depth (1 at first)
        "rate_faster": True,
    },
    "stutter": {
        "banks": ["Repeat"],
        "knobs": [(0, 1, 3)],  # Length (longer)
    },
    "pitch": {
        "banks": ["Shift"],
        "knobs": [(0, 1, 10), (1, 2, 10), (2, 3, -10)],  # Pitch (+12 at first), Window, Mix (1 at first)
    },
}


def check(pid, steps, kind):
    """How parameter `pid` should move for `steps`: the cutter's Rate turns
    to fewer beats (faster) as it turns right."""
    if kind == "cutter" and pid == 1:
        return (lambda x, y: y < x) if steps > 0 else (lambda x, y: y > x)
    return None if steps > 0 else (lambda x, y: y < x)


def held(pads, cc, then):
    pads.cmd(f"midiport play push B0 {cc:02X} 7F")
    then()
    pads.cmd(f"midiport play push B0 {cc:02X} 00")
    pads.wait(8)


def every_knob(pads, d, kind, where, lead=0):
    spec = DEVICES[kind]
    assert banks(pads) == len(spec["banks"]), view(pads)
    for b, name in enumerate(spec["banks"]):
        bank(pads, b)
        save(pads, f"{kind}_{where}_{name.lower()}")
        if lead:  # Perform: Intensity on column 0 of every bank
            before = pads.state()["perf_intensity"][0]
            turn(pads, 0, -6)
            assert pads.state()["perf_intensity"][0] < before, (b, before)
        for col, pid, steps in spec["knobs"]:
            moves(pads, d, lead + col, pid, steps, check=check(pid, steps, kind))
            moves(pads, d, lead + col, pid, -steps, check=check(pid, -steps, kind))  # (and back)


def report(pads, name):
    last, most = draw_us(pads)
    print(f"DRAW {name}: last {last:.0f} us, most {most:.0f} us")
    with open(os.path.join(pads.out_dir, "draw_us.txt"), "a") as f:
        f.write(f"{name}: {last:.0f} us (most {most:.0f} us)\n")
    assert 0 < last < 5000, (name, last, most)


def playing(pads, name):
    """The display saved while the transport plays (twice: it moves)."""
    pads.api("transport_play")
    pads.wait(30)
    save(pads, f"{name}_playing")
    pads.wait(17)
    save(pads, f"{name}_playing_later")
    pads.api("transport_stop")
    pads.wait(5)


def perform(pads, kind):
    """`kind` as Perform's first effect, shown on the Push. (Shown again once
    the Push has settled on the selected pad's chain, which replaces it.)"""
    d = in_perform(pads, kind)
    pads.wait(8)
    pads.cmd("edit_fx perf 0")
    pads.wait(8)
    return d


@pytest.mark.parametrize("kind", list(DEVICES))
def test_push2_rhythm_in_a_slot(pads, fixtures, kind):
    d = in_slot(pads, kind, sample=os.path.join(fixtures, "loop.wav"))
    assert pads.api("effect_state", s=d.slot)["kind"] != 0
    every_knob(pads, d, kind, "slot")
    pads.cmd("hit 0")
    playing(pads, f"{kind}_slot")
    report(pads, f"{kind} (slot)")
    state = lambda: pads.api("effect_state", s=d.slot)
    if kind == "stutter":  # Repeat (hold): on while held, off when let go
        pads.cmd(f"midiport play push B0 {LOWER:02X} 7F")
        pads.wait(4)
        assert state()["on"] is True
        pads.cmd(f"midiport play push B0 {LOWER:02X} 00")
        pads.wait(4)
        assert state()["on"] is False
        pads.api("transport_play")
        pads.cmd(f"midiport play push B0 {LOWER:02X} 7F")
        pads.wait(40)
        assert state()["on"] is True
        save(pads, "stutter_slot_repeating")
        pads.cmd(f"midiport play push B0 {LOWER:02X} 00")
        pads.api("transport_stop")
        pads.wait(4)
        assert state()["on"] is False
        held(pads, MUTE, lambda: press(pads, DEVICE))  # (on again, as at first)
    pads.cmd("release 0")
    assert state()["on"] is True
    held(pads, MUTE, lambda: press(pads, DEVICE))  # Mute + Device: off
    assert state()["on"] is False
    save(pads, f"{kind}_slot_off")
    held(pads, MUTE, lambda: press(pads, DEVICE))  # and on again
    assert state()["on"] is True
    held(pads, DELETE, lambda: press(pads, DEVICE))  # Delete + Device: removed
    assert state()["kind"] == 0


@pytest.mark.parametrize("kind", list(DEVICES))
def test_push2_rhythm_in_perform(pads, kind):
    d = perform(pads, kind)
    every_knob(pads, d, kind, "perform", lead=1)
    # Held (as its pad holds it), at its own intensity, while the transport plays.
    turn(pads, 0, 20)
    turn(pads, 0, -90)  # (an intensity about a half: its own setting shows beside)
    pads.api("transport_play")
    pads.cmd("perf 0 on")
    pads.wait(40)
    save(pads, f"{kind}_perform_held")
    pads.cmd("perf 0 off")
    pads.wait(10)
    save(pads, f"{kind}_perform_playing")
    pads.api("transport_stop")
    report(pads, f"{kind} (Perform)")
