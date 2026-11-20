"""The dynamics' panels on Push 2 (docs/design/push2-fx-dynamics.md):
Compressor, Gate and Limiter in a pad's slot, in Perform, and the
Compressor on the synth's Effects tab. Every bank's every knob moves its
parameter; Perform's Intensity is on the first encoder of every bank; the
synth tab keeps its picker and On; Mute + Device and Delete + Device still
turn the device off and remove it. The display is saved for every bank."""

import os
import re

from push2_fx import bank, banks, draw_us, in_perform, in_slot, moves, on_synth, pads, press, save, turn, value  # noqa: F401

# The synth's compressor's parameters (synth.effect_param(.Compressor, f):
# 700 + 32 * its index among the effects + its field).
C = 732
C_ON, C_BANDS, C_ATTACK, C_RELEASE, C_MIX = C, C + 1, C + 2, C + 3, C + 4


def c_band(b):
    """Band `b`'s (0 low, 1 band, 2 high) Upper, Lower, Upper Ratio, Lower Ratio, Gain."""
    at = C + 5 + 5 * b
    return at, at + 1, at + 2, at + 3, at + 4


# Each bank's knobs in order: (parameter id, which way to turn it from its default).
def compressor_banks():
    out = [[(C_BANDS, 3), (C_ATTACK, 10), (C_RELEASE, 10), (C_MIX, -10)]]
    for b in range(3):
        up, lo, up_r, lo_r, gain = c_band(b)
        out.append([(up, 10), (up_r, -10 if b == 2 else 10), (lo, 10), (lo_r, 10), (gain, 10)])
    return out


GATE = [[(1, 10), (2, -10), (4, 10), (5, 10), (6, 10), (7, 10), (3, -10)]]  # Threshold, Range, Attack, Hold, Release, Hysteresis, Ratio
LIMITER = [[(2, 10), (1, -10), (3, 10)]]  # Input, Ceiling, Release

MUTE, DELETE = 0x3C, 0x76


def held(pads, cc, then):
    pads.cmd(f"midiport play push B0 {cc:02X} 7F")
    then()
    pads.cmd(f"midiport play push B0 {cc:02X} 00")
    pads.wait(8)


def every_knob(pads, d, layout, name, lead=0, extra=None):
    """Each bank of `layout` shown, its knobs turned (after the lead's
    columns), the display saved; `extra(b)` checks more on bank `b`."""
    for b, knobs in enumerate(layout):
        bank(pads, b)
        save(pads, f"{name}_{b}")
        for col, (pid, steps) in enumerate(knobs):
            moves(pads, d, lead + col, pid, steps, check=None if steps > 0 else (lambda x, y: y < x))
        if extra:
            extra(b)


def ms(text):
    """A time as read ("1.4 ms", "28 ms", "1.25 s") in ms."""
    m = re.fullmatch(r"([\d.]+) (ms|s)", text)
    assert m, text
    return float(m.group(1)) * (1000 if m.group(2) == "s" else 1)


def compressor_times(pads, d, name, lead=0):
    """Main's Attack and Release read as times (the middle band's: 1.4 ms
    and 28 ms at their defaults), and turn in ratios: 14 detents (e^(8 x
    14/160) = 2.0) about double them."""
    bank(pads, 0)
    for col, pid, at_default in ((1, C_ATTACK, 1.4), (2, C_RELEASE, 28)):
        d.set(pid, 0.5)
        assert abs(ms(value(pads, lead + col)) - at_default) < 0.06 * at_default, value(pads, lead + col)
        turn(pads, lead + col, 14)
        ratio = ms(value(pads, lead + col)) / at_default
        assert 1.8 < ratio < 2.2, (col, value(pads, lead + col))
        turn(pads, lead + col, -28)
        ratio = ms(value(pads, lead + col)) / at_default
        assert 0.45 < ratio < 0.56, (col, value(pads, lead + col))
    save(pads, f"{name}_times")


def check_intensity(pads):
    def check(b):
        before = pads.state()["perf_intensity"][0]
        turn(pads, 0, -10)
        assert pads.state()["perf_intensity"][0] < before, b
    return check


def on_and_remove(pads, d):
    """Mute + Device turns it off and on; Delete + Device removes it."""
    assert pads.api("effect_state", s=d.slot)["on"] is True
    held(pads, MUTE, lambda: press(pads, 0x6E))
    assert pads.api("effect_state", s=d.slot)["on"] is False
    save(pads, f"{pads.api('effect_name', s=d.slot).lower()}_off")
    held(pads, MUTE, lambda: press(pads, 0x6E))
    assert pads.api("effect_state", s=d.slot)["on"] is True
    held(pads, DELETE, lambda: press(pads, 0x6E))
    assert pads.api("effect_state", s=d.slot)["kind"] == 0


def sidechain(pads, d, b):
    """The Sidechain bank: Source (a second pad), Key HPF, Listen."""
    bank(pads, b)
    save(pads, f"{pads.api('effect_name', s=d.slot).lower()}_sidechain_itself")
    turn(pads, 0, 3)  # Source: the next (pad A2)
    key = pads.api("effect_key", s=d.slot)
    assert key["kind"] == "Pad" and key["index"] == 1, key
    turn(pads, 1, 10)  # Key HPF
    assert pads.api("effect_key", s=d.slot)["hpf_hz"] > 0
    turn(pads, 2, 3)  # Listen
    assert pads.api("effect_key", s=d.slot)["listen"] is True
    save(pads, f"{pads.api('effect_name', s=d.slot).lower()}_sidechain_keyed")
    turn(pads, 2, -3)
    assert pads.api("effect_key", s=d.slot)["listen"] is False
    turn(pads, 0, -3)
    assert pads.api("effect_key", s=d.slot)["kind"] == "None"


def slot_with_key(pads, fixtures, kind):
    sample = os.path.join(fixtures, "loop.wav")
    pads.api("pad_load_sample", pad=1, path=sample)  # (pad A2: a key to listen to)
    return in_slot(pads, kind, sample=sample)


def perform(pads, kind):
    """Effect `kind` as Perform's first, shown on the Push. (The kit's
    in_perform shows it before the Push has settled on the selected pad's
    chain, which then replaces it: shown again once it has.)"""
    d = in_perform(pads, kind)
    pads.wait(8)
    pads.cmd("edit_fx perf 0")
    pads.wait(8)
    return d


def report(pads, name):
    last, most = draw_us(pads)
    with open(os.path.join(pads.out_dir, "draw_us.txt"), "w") as f:  # (look: the panel's drawing time)
        f.write(f"{name}: {last:.0f} µs (most {most:.0f} µs)\n")
    assert 0 < last < 20_000, (name, last, most)


# --- Compressor --------------------------------------------------------------------------------

def test_push2_compressor_in_a_slot(pads, fixtures):
    d = slot_with_key(pads, fixtures, "compressor")
    assert banks(pads) == 5  # Main, Low, Band, High, Sidechain
    pads.cmd("hit 0")
    pads.wait(30)
    every_knob(pads, d, compressor_banks(), "compressor")
    compressor_times(pads, d, "compressor")
    sidechain(pads, d, 4)
    report(pads, "compressor (slot)")
    pads.cmd("release 0")
    bank(pads, 0)
    on_and_remove(pads, d)


def test_push2_compressor_in_perform(pads):
    d = perform(pads, "compressor")
    assert banks(pads) == 4  # (no sidechain)
    every_knob(pads, d, compressor_banks(), "compressor_perform", lead=1, extra=check_intensity(pads))
    compressor_times(pads, d, "compressor_perform", lead=1)
    report(pads, "compressor (Perform)")


def test_push2_compressor_on_the_synths_effects_tab(pads):
    d = on_synth(pads, "compressor")
    assert banks(pads) == 4
    d.set(C_ON, 1)
    every_knob(pads, d, compressor_banks(), "compressor_synth", lead=1)
    compressor_times(pads, d, "compressor_synth", lead=1)
    report(pads, "compressor (synth)")
    # On: the lower row's last button.
    bank(pads, 0)
    press(pads, 27)
    pads.wait(4)
    assert d.get(C_ON) < 0.5
    press(pads, 27)
    pads.wait(4)
    assert d.get(C_ON) > 0.5
    # The picker, the first encoder of every bank: the next effect (its own panel).
    bank(pads, 2)
    turn(pads, 0, 3)
    pads.wait(4)
    assert banks(pads) != 4 or pads.api("view_state", kind="Device", page=0)["page"] == 0


# --- Gate --------------------------------------------------------------------------------------

def test_push2_gate_in_a_slot(pads, fixtures):
    d = slot_with_key(pads, fixtures, "gate")
    assert banks(pads) == 2  # Main, Sidechain
    pads.cmd("hit 0")
    pads.wait(30)
    every_knob(pads, d, GATE, "gate")
    sidechain(pads, d, 1)
    report(pads, "gate (slot)")
    pads.cmd("release 0")
    bank(pads, 0)
    on_and_remove(pads, d)


def test_push2_gate_in_perform(pads):
    d = perform(pads, "gate")
    assert banks(pads) == 1
    every_knob(pads, d, GATE, "gate_perform", lead=1, extra=check_intensity(pads))


# --- Limiter -----------------------------------------------------------------------------------

def test_push2_limiter_in_a_slot(pads, fixtures):
    d = in_slot(pads, "limiter", sample=os.path.join(fixtures, "loop.wav"))
    assert banks(pads) == 1
    d.set(2, 18)  # (Input up: it limits while it plays)
    pads.cmd("hit 0")
    pads.wait(60)
    save(pads, "limiter_playing")
    d.set(2, 0)
    every_knob(pads, d, LIMITER, "limiter")
    report(pads, "limiter (slot)")
    pads.cmd("release 0")
    on_and_remove(pads, d)


def test_push2_limiter_in_perform(pads):
    d = perform(pads, "limiter")
    assert banks(pads) == 1
    every_knob(pads, d, LIMITER, "limiter_perform", lead=1, extra=check_intensity(pads))
