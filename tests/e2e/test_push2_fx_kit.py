"""The devices' panels' test kit (push2_fx.py) on the generic panel (a
family not built yet): a device in a slot, on the synth's Effects tab and
in Perform, shown on the Push, its knobs turned."""

import os

from push2_fx import Device, bank, banks, draw_us, in_perform, in_slot, moves, on_synth, pads, save, view  # noqa: F401


def test_a_slot_effect_on_the_generic_panel(pads, fixtures):
    d = in_slot(pads, "comb", sample=os.path.join(fixtures, "loop.wav"))
    assert banks(pads) >= 1
    assert pads.api("effect_name", s=d.slot) == "Comb"
    moves(pads, d, 0, 1, 10)  # (the Comb's first: its frequency, COMB_PARAM_HZ)
    save(pads, "kit_slot")
    assert tuple(draw_us(pads)) == (0, 0)  # (no family panel drawn yet)


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
