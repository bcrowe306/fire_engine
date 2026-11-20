"""The devices' panels' test kit (push2_fx.py): a device in a slot, on the
synth's Effects tab and in Perform, shown on the Push by its family's
panel, its knobs turned, its drawing timed."""

import os

from push2_fx import Device, bank, banks, draw_us, in_perform, in_slot, knobs_shown, moves, on_synth, pads, save, view  # noqa: F401


def test_a_slot_effect_on_its_familys_panel(pads, fixtures):
    d = in_slot(pads, "cutter", sample=os.path.join(fixtures, "loop.wav"))
    assert banks(pads) >= 1
    assert pads.api("effect_name", s=d.slot) == "Cutter"
    moves(pads, d, 0, 1, 10, check=lambda before, after: after < before)  # (its Rate, CUTTER_PARAM_BEATS: faster, fewer beats)
    save(pads, "kit_slot")
    last, most = draw_us(pads)
    assert 0 < last <= most  # (its family's panel drew, and was timed)


def test_a_synth_effect_on_its_tab(pads):
    d = on_synth(pads, "delay")
    assert banks(pads) >= 1
    save(pads, "kit_synth")
    assert isinstance(d, Device)


def test_a_perform_effect_with_its_intensity(pads):
    in_perform(pads, "comb")
    assert banks(pads) >= 1
    bank(pads, 0)
    assert view(pads)["page"] == 0
    save(pads, "kit_perform")


# --- what moves a knob besides its encoder, on the knobs a family draws itself ---

def insert(pid, slot=0):
    return {"track": "Pad", "index": 0, "device": "Insert", "slot": slot, "param": pid}


def automated(pads, ref, values):
    """Parameter `ref` given automation in the current sequence (a point a
    beat, `values`), the transport playing it."""
    for beat, v in enumerate(values):
        pads.api("sequence_add_point", slot=0, ref=ref, beat=beat, value=v, curve=0)
    pads.api("transport_play")
    pads.wait(20)


def test_hand_drawn_knobs_show_automation_playing(pads, fixtures):
    """The Gate's Attack (its own knob: times in ratios) and the delay's free
    Time (its own: a rate drawn as the time it makes, turned the other way)
    show automation playing as fx_knob's knobs do: the live mark, where the
    lane has the parameter along the knob as it turns."""
    in_slot(pads, "gate", sample=os.path.join(fixtures, "loop.wav"))
    assert knobs_shown(pads)[2]["label"] == "Attack" and not knobs_shown(pads)[2]["live"]
    automated(pads, insert(4), [1, 1, 1, 1])  # GATE_PARAM_ATTACK_MS: 1 ms (0.05..100 ms, in ratios)
    k = knobs_shown(pads)[2]
    assert k["live"], k
    assert abs(k["live_at"] - 0.394) < 0.03, k  # ln(1 / 0.05) / ln(100 / 0.05)
    assert not knobs_shown(pads)[0]["live"]  # (Threshold: not automated)
    save(pads, "rings_gate_attack")
    pads.api("transport_stop")
    # The delay (a twin of the synth's) in the next slot, Sync: Free, its
    # Time automated at a quarter of its rate's range (-2..9, log2 Hz):
    # three quarters of the way along the knob (longer to the right).
    DELAY = 700 + 32 * 2
    D_SYNC, D_HZ = DELAY + 2, DELAY + 3
    pads.cmd("insert 0 1 delay")
    pads.cmd("edit_fx pad 0 1")
    pads.wait(8)
    d = Device(pads, "slot", {"place": "Insert", "index": 0, "slot": 1}, 0)
    d.set(D_SYNC, 0)
    automated(pads, insert(D_HZ, slot=1), [0.75, 0.75])
    k = knobs_shown(pads)[0]
    assert k["label"] == "Time" and k["live"], k
    assert abs(k["live_at"] - 0.75) < 0.03, k
    save(pads, "rings_delay_time")
    pads.api("transport_stop")


def test_hand_drawn_knobs_mark_the_synths_modulation(pads):
    """On the synth's Effects tab a route into a parameter is marked under
    its knob's bar (the window's ring, as a line in the source's colour):
    on the Distortion's Drive (its family's own knob) and Mix (fx_knob's)."""
    on_synth(pads, "distortion")
    shown = knobs_shown(pads)
    assert shown[1]["label"] == "Drive" and shown[3]["label"] == "Mix", shown
    assert shown[1]["marks"] == 0 and shown[3]["marks"] == 0
    pads.click("show sources", window="detail")
    pads.drag("mod LFO 1", "Drive", to_window="detail")
    pads.drag("mod Env 2", "Mix", to_window="detail")
    routes = pads.pad(0)["synth"]["routes"]
    assert [r["dest"] for r in routes] == ["Distortion Drive", "Distortion Mix"], routes
    pads.cmd("hit 0")
    pads.wait(10)
    shown = knobs_shown(pads)
    assert shown[1]["marks"] == 1 and shown[3]["marks"] == 1, shown
    save(pads, "rings_synth_routes")
    pads.cmd("release 0")
