"""The devices' panels' test kit (push2_fx.py): a device in a slot, on the
synth's Effects tab and in Perform, shown on the Push by its family's
panel, its knobs turned, its drawing timed."""

import os

from push2_fx import Device, bank, banks, draw_us, in_perform, in_slot, moves, on_synth, pads, save, view  # noqa: F401


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
