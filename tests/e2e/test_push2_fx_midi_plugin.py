"""The pad's MIDI effects and CLAP plug-ins on Push 2's display
(docs/design/push2-fx-midi-plugin.md): the MIDI effects' two banks (Repeat,
Arpeggiator), every knob moving its setting (the dropdowns too), the lower
row turning repeat, the arpeggiator and latch on and off, a gate's turn
one undo step; a plug-in in a pad's effect slot and as a pad's instrument,
its banks (by module, else by number), the first and last knob of each
moving its parameter, Open Editor on the lower row, Mute + Device and
Delete + Device on a slot. The display saved for every bank, playing, with
notes held, with an encoder touched; the panels' drawing time printed.
Plug-ins need the test plug-ins (./scripts/clap.sh); those tests skip
without them."""

import os
import re

import pytest

from pads import ROOT
from push2_fx import DEVICE, Device, _select_pad, _show, bank, banks, draw_us, moves, pads, plug, press, save, turn, value, view  # noqa: F401

MUTE, DELETE = 0x3C, 0x76
LOWER = 20  # the lower row's first button (CC 20..27)
CHOICE = 3  # encoder moves a dropdown takes a step
CLAP = os.path.join(ROOT, ".build", "clap")
WET_MIX = 0x7F00  # (dsp.WET_PARAM_MIX)
RATES = ["Quarter", "Eighth", "Eighth_Triplet", "Sixteenth", "Sixteenth_Triplet", "Thirty_Second", "Thirty_Second_Triplet"]
MODES = ["Up", "Down", "Up_Down", "Random", "As_Played"]


def report(pads, name):
    last, most = draw_us(pads)
    print(f"DRAW {name}: last {last:.0f} us, most {most:.0f} us")
    with open(os.path.join(pads.out_dir, "draw_us.txt"), "a") as f:
        f.write(f"{name}: {last:.0f} us (most {most:.0f} us)\n")
    assert 0 < last < 5000, (name, last, most)


def held(pads, cc, then):
    pads.cmd(f"midiport play push B0 {cc:02X} 7F")
    then()
    pads.cmd(f"midiport play push B0 {cc:02X} 00")
    pads.wait(8)


def touched(pads, encoder, steps, name):
    """Encoder `encoder` touched and turned `steps`, the display saved while
    it's held (the plug-in's picture shows its parameter large), let go."""
    pads.cmd(f"midiport play push 90 {encoder:02X} 7F")
    for _ in range(abs(steps)):
        pads.cmd(f"midiport play push B0 {0x47 + encoder:02X} {'01' if steps > 0 else '7F'}")
        pads.wait(1)
    save(pads, name)
    pads.cmd(f"midiport play push 90 {encoder:02X} 00")
    pads.wait(3)


def playing(pads, name):
    pads.api("transport_play")
    pads.wait(30)
    save(pads, f"{name}_playing")
    pads.api("transport_stop")
    pads.wait(5)


# --- MIDI effects ------------------------------------------------------------------------------


def midi_fx(pads, pad=0):
    return pads.api("sequence_midi_fx", pad=pad)


def show_midi(pads, fixtures):
    plug(pads)
    pads.api("pad_load_sample", pad=0, path=os.path.join(fixtures, "loop.wav"))
    _select_pad(pads, 0)
    _show(pads)
    pads.api("ui_show", name="midi")
    pads.wait(5)


def changes(pads, encoder, steps, field, more):
    """Encoder `encoder` turned `steps` changes the MIDI effects' `field` the
    way `more(before, after)` says."""
    before = midi_fx(pads)[field]
    turn(pads, encoder, steps)
    after = midi_fx(pads)[field]
    assert more(before, after), (encoder, field, before, after)


def index_up(names):
    return lambda x, y: names.index(y) > names.index(x)


def index_down(names):
    return lambda x, y: names.index(y) < names.index(x)


def test_push2_midi_effects(pads, fixtures):
    show_midi(pads, fixtures)
    assert banks(pads) == 2, view(pads)
    assert view(pads)["buttons"] & 0x7 == 0x7  # Repeat, Arpeggiator, Latch
    save(pads, "midi_repeat_off")
    # Repeat: Rate (a dropdown, 1/4 .. 1/32 T), Gate.
    bank(pads, 0)
    changes(pads, 0, CHOICE, "repeat_rate", index_up(RATES))
    changes(pads, 0, -CHOICE, "repeat_rate", index_down(RATES))
    changes(pads, 1, -10, "repeat_gate", lambda x, y: y < x)
    changes(pads, 1, 10, "repeat_gate", lambda x, y: y > x)
    # A gate's turn is one undo step.
    before = midi_fx(pads)["repeat_gate"]
    turn(pads, 1, -12)
    assert midi_fx(pads)["repeat_gate"] < before
    pads.api("history_undo")
    pads.wait(3)
    assert abs(midi_fx(pads)["repeat_gate"] - before) < 1e-6, (before, midi_fx(pads))
    # The lower row: Repeat on.
    press(pads, LOWER + 0)
    pads.wait(4)
    assert midi_fx(pads)["repeat"] is True
    assert view(pads)["lit"] & 0x7 == 0x1
    save(pads, "midi_repeat")
    turn(pads, 0, CHOICE)  # (1/8 T)
    pads.cmd("hit 0")
    playing(pads, "midi_repeat")
    pads.cmd("release 0")
    # Arpeggiator: Mode, Rate, Octaves (dropdowns), Gate.
    bank(pads, 1)
    save(pads, "midi_arp_off")
    changes(pads, 0, CHOICE, "arp_mode", index_up(MODES))
    changes(pads, 0, -CHOICE, "arp_mode", index_down(MODES))
    changes(pads, 1, CHOICE, "arp_rate", index_up(RATES))
    changes(pads, 1, -CHOICE, "arp_rate", index_down(RATES))
    changes(pads, 2, CHOICE, "arp_octaves", lambda x, y: y == x + 1)
    changes(pads, 2, -CHOICE, "arp_octaves", lambda x, y: y == x - 1)
    changes(pads, 3, 10, "arp_gate", lambda x, y: y > x)
    changes(pads, 3, -10, "arp_gate", lambda x, y: y < x)
    press(pads, LOWER + 1)
    pads.wait(4)
    assert midi_fx(pads)["arp"] is True
    press(pads, LOWER + 2)
    pads.wait(4)
    assert midi_fx(pads)["arp_latch"] is True
    assert view(pads)["lit"] & 0x7 == 0x7
    save(pads, "midi_arp_demo")  # (a demo chord: none played yet; repeat plays not, the arp does)
    turn(pads, 2, CHOICE)  # 2 octaves
    turn(pads, 0, 2 * CHOICE)  # Up & Down
    save(pads, "midi_arp_updown")
    report(pads, "MIDI effects")
    press(pads, LOWER + 2)
    pads.wait(4)
    assert midi_fx(pads)["arp_latch"] is False
    press(pads, LOWER + 0)
    pads.wait(4)
    assert midi_fx(pads)["repeat"] is False
    press(pads, LOWER + 1)
    pads.wait(4)
    assert midi_fx(pads)["arp"] is False
    # Mute + Device, Delete + Device: the MIDI page stays (an effect's only).
    held(pads, DELETE, lambda: press(pads, DEVICE))
    assert pads.state()["device"] == "Midi", pads.state()["device"]


def test_push2_arp_walks_the_notes_held(pads, fixtures):
    show_midi(pads, fixtures)
    pads.api("sequence_set_midi_fx", pad=0, fx=dict(midi_fx(pads), arp=True, arp_octaves=2, arp_mode="Up"))
    bank(pads, 1)
    # Scale mode: the Push's pads play the selected pad's notes.
    pads.api("perform_set_play_mode", mode="Scale")
    pads.wait(10)
    keys = [k for k in range(64) if pads.api("perform_key", key=k)["playable"]]
    root = next(k for k in keys if pads.api("perform_key", key=k)["root"])
    chord = [36 + k for k in (root, keys[keys.index(root) + 2], keys[keys.index(root) + 4])]
    for n in chord:
        pads.cmd(f"midiport play push 90 {n:02X} 64")
    pads.api("transport_play")
    pads.wait(30)
    save(pads, "midi_arp_held")
    for n in chord:
        pads.cmd(f"midiport play push 80 {n:02X} 00")
    pads.wait(60)
    save(pads, "midi_arp_last_played")
    pads.api("transport_stop")
    report(pads, "MIDI effects (held)")


# --- plug-ins ----------------------------------------------------------------------------------


@pytest.fixture
def clap_lib():
    if not os.path.exists(os.path.join(CLAP, "FireOdin.clap")) or not os.path.exists(os.path.join(CLAP, "FireTest.clap")):
        pytest.skip("no test plug-ins (./scripts/clap.sh)")
    return CLAP


class Instrument(Device):
    """A plug-in as pad `pad`'s instrument."""

    def get(self, pid):
        return self.pads.api("param_get", ref={"track": "Pad", "index": self.pad, "device": "Sound", "param": pid})


def params_of(pads, ref):
    """The device's parameters in order, as the panel has them (not the
    wet mix Pads gives every effect): (id, stepped, min, max)."""
    out = []
    for k in range(pads.api("param_count", ref=ref)):
        r = pads.api("param_at", ref=ref, index=k)
        if r["param"] == WET_MIX:
            continue
        info = pads.api("param_info", ref=r)
        out.append((r["param"], info["stepped"], info["min"], info["max"]))
    return out


def turns(pads, d, encoder, param):
    """Encoder `encoder` moves `param` (one way or, at its end, the other)."""
    pid, stepped, lo, hi = param
    steps = CHOICE if stepped else 12
    before = d.get(pid)
    if before >= hi:
        steps = -steps
    moves(pads, d, encoder, pid, steps)
    moves(pads, d, encoder, pid, -steps)  # (and back)


def every_bank(pads, d, params, names, where):
    assert banks(pads) == len(names), (view(pads), names)
    for b, name in enumerate(names):
        bank(pads, b)
        mine = params[b * 8:(b + 1) * 8]
        save(pads, f"plugin_{where}_{b + 1}")
        turns(pads, d, 0, mine[0])
        turns(pads, d, len(mine) - 1, mine[-1])


def own_texts(pads, d, params, lead=0):
    """Bank 0's knobs read as the plug-in reads them (fire:clap/sdk's
    value_to_text: "350.00 ms", the number to two places and its unit), not
    a bare number; those turned (set on the slot: the first and last) their
    parameter's value now. Its dropdowns are the
    plug-in's step names. Returns the values read."""
    bank(pads, 0)
    shown = []
    for col, (pid, stepped, lo, hi) in enumerate(params[:8 - lead]):
        text = value(pads, lead + col)
        shown.append(text)
        if stepped:
            continue
        m = re.fullmatch(r"(-?\d+\.\d\d)( ms| Hz| dB| %| st|:1)?", text)
        assert m, (col, text)
        if col in (0, len(params[:8 - lead]) - 1):
            assert abs(float(m.group(1)) - d.get(pid)) < 0.006, (col, text, d.get(pid))
    return shown


def wait_loaded(pads):
    for _ in range(40):
        pads.wait(5)
        if view(pads)["pages"] >= 1 and view(pads)["knobs"] > 0:
            return
    raise AssertionError(view(pads))


def test_push2_plugin_in_a_slot(pads, fixtures, clap_lib):
    plug(pads)
    pads.api("pad_load_sample", pad=0, path=os.path.join(fixtures, "loop.wav"))
    _select_pad(pads, 0)
    slot = {"place": "Insert", "index": 0, "slot": 0}
    pads.api("effect_set_plugin", s=slot, path=os.path.join(clap_lib, "FireOdin.clap"), id="dev.fire-engine.odin.delay", name="Fire Delay")
    pads.cmd("edit_fx pad 0 0")
    _show(pads)
    wait_loaded(pads)
    d = Device(pads, "slot", slot, 0)
    params = params_of(pads, {"track": "Pad", "index": 0, "device": "Insert", "slot": 0, "param": 0})
    assert len(params) == 8, params
    # Never set here: each reads as the plug-in has it (its default), not 0.
    for pid, *_ in params:
        info = pads.api("param_info", ref={"track": "Pad", "index": 0, "device": "Insert", "slot": 0, "param": pid})
        assert abs(pads.api("effect_get_param", s=slot, id=pid) - info["default_value"]) < 1e-9, (pid, info)
    assert any(pads.api("effect_get_param", s=slot, id=pid) != 0 for pid, *_ in params)
    every_bank(pads, d, params, ["1–8"], "delay")
    # Each knob reads as the plug-in reads it (its own text: units), and
    # again as it moves.
    texts = own_texts(pads, d, params)
    assert any(t.endswith(" ms") for t in texts), texts
    first = next(k for k, p in enumerate(params) if not p[1])
    turn(pads, first, 12)
    assert value(pads, first) != texts[first], (value(pads, first), texts[first])
    own_texts(pads, d, params)
    turn(pads, first, -12)
    # A stepped one (Sync: Off / On) is a dropdown.
    sync = next(p for p in params if p[0] == 2)
    assert sync[1] is True
    moves(pads, d, 1, 2, CHOICE, check=lambda x, y: x == 0 and y == 1)
    touched(pads, 0, 20, "plugin_delay_turning")
    save(pads, "plugin_delay_last_turned")
    pads.cmd("hit 0")
    playing(pads, "plugin_delay")
    pads.cmd("release 0")
    report(pads, "plug-in (slot)")
    # The lower row: only its editor (Fire Delay has none: nothing).
    assert view(pads)["buttons"] & 0x7F == 0, view(pads)
    state = lambda: pads.api("effect_state", s=slot)
    assert state()["on"] is True
    held(pads, MUTE, lambda: press(pads, DEVICE))  # Mute + Device: off
    assert state()["on"] is False
    save(pads, "plugin_delay_off")
    held(pads, MUTE, lambda: press(pads, DEVICE))
    assert state()["on"] is True
    held(pads, DELETE, lambda: press(pads, DEVICE))  # Delete + Device: removed
    assert state()["kind"] == 0


def test_push2_plugin_banks_by_module(pads, fixtures, clap_lib):
    plug(pads)
    pads.api("pad_load_sample", pad=0, path=os.path.join(fixtures, "loop.wav"))
    _select_pad(pads, 0)
    slot = {"place": "Insert", "index": 0, "slot": 0}
    pads.api("effect_set_plugin", s=slot, path=os.path.join(clap_lib, "FireTest.clap"), id="dev.fire-engine.test.gain", name="Fire Test Gain")
    pads.cmd("edit_fx pad 0 0")
    _show(pads)
    wait_loaded(pads)
    d = Device(pads, "slot", slot, 0)
    params = params_of(pads, {"track": "Pad", "index": 0, "device": "Insert", "slot": 0, "param": 0})
    assert len(params) == 1, params
    assert banks(pads) == 1
    save(pads, "plugin_gain_main")  # (its module: "Main")
    turns(pads, d, 0, params[0])
    assert value(pads, 0) == f"{d.get(params[0][0]):.1f} dB", value(pads, 0)  # (FireTest's own text: one place, dB)
    report(pads, "plug-in (module)")


def test_push2_plugin_instrument(pads, clap_lib):
    plug(pads)
    _select_pad(pads, 0)
    pads.cmd(f"plugin_pad 0 {os.path.join(clap_lib, 'FireOdin.clap')} dev.fire-engine.odin.synth")
    _show(pads)
    wait_loaded(pads)
    assert pads.state()["device"] == "Instrument", pads.state()["device"]
    d = Instrument(pads, "synth", pad=0)
    params = params_of(pads, {"track": "Pad", "index": 0, "device": "Sound", "slot": 0, "param": 0})
    assert len(params) == 19, params
    every_bank(pads, d, params, ["1–8", "9–16", "17–19"], "synth")
    own_texts(pads, d, params)
    bank(pads, 0)
    touched(pads, 4, 15, "plugin_synth_turning")
    report(pads, "plug-in (instrument)")


def test_push2_plugin_instrument_editor_button(pads, clap_lib):
    plug(pads)
    _select_pad(pads, 0)
    pads.cmd(f"plugin_pad 0 {os.path.join(clap_lib, 'FireTest.clap')} dev.fire-engine.test.sine")
    _show(pads)
    wait_loaded(pads)
    assert banks(pads) == 1
    save(pads, "plugin_sine")
    # Its editor: Open Editor, the lower row's first (headless, it can't open: it says so).
    assert view(pads)["buttons"] & 0x1 == 0x1, view(pads)
    press(pads, LOWER + 0)
    pads.wait(5)
    report(pads, "plug-in (instrument, editor)")
