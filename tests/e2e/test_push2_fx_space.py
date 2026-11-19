"""Space on Push 2 (docs/design/push2-fx-space.md): Delay, Reverb and Comb
each with its picture and named banks, wherever it can be: an effect
slot, a Perform effect (Intensity first in every bank), the synth's
Effects tab (its picker first, On on the lower row's last). Every bank's
every knob moves its parameter; the display saved for each bank."""

import os

from push2_fx import bank, banks, draw_us, in_perform, in_slot, moves, on_synth, pads, press, save, turn, view  # noqa: F401 (pads: its fixture)

# The synth's effect parameters (synth.effect_param: 700 + 32 × the effect + its field).
DELAY = 700 + 32 * 2
D_ON, D_STYLE, D_SYNC, D_HZ, D_TEMPO, D_HZ_R, D_TEMPO_R, D_FEEDBACK, D_WET, D_CUTOFF, D_SPREAD = range(DELAY, DELAY + 11)
REVERB = 700 + 32 * 8
R_ON, R_WET, R_DECAY, R_SIZE, R_PRE, R_LO_CUT, R_HI_CUT, R_LO_SHELF, R_LO_GAIN, R_HI_SHELF, R_HI_GAIN, R_CHORUS, R_RATE = range(REVERB, REVERB + 13)
# The comb's (dsp.COMB_PARAM_*).
C_HZ, C_FEEDBACK, C_MIX = 1, 2, 3

LOWER = 20  # the lower row's first button (CC)
MUTE, DELETE, DEVICE = 0x3C, 0x76, 0x6E
CHOICE = 3  # detents a choice's step takes

# Each bank's knobs: (column, parameter, detents); a knob that is a time
# turned up for longer (its rate down) has a check of its own.
LONGER = (lambda before, after: after < before)
DELAY_ECHOES = [(0, D_TEMPO, CHOICE), (1, D_FEEDBACK, 10), (2, D_WET, 10), (4, D_STYLE, CHOICE), (5, D_TEMPO_R, CHOICE)]
DELAY_ECHOES_FREE = [(0, D_HZ, 10, LONGER), (5, D_HZ_R, 10, LONGER)]  # (Sync: Free)
DELAY_TONE = [(0, D_CUTOFF, 10), (1, D_SPREAD, -10)]
REVERB_ROOM = [(0, R_DECAY, 10), (1, R_SIZE, 10), (2, R_PRE, 10), (3, R_WET, 10), (4, R_CHORUS, 10), (5, R_RATE, 10)]
REVERB_TONE = [(0, R_LO_CUT, 10), (1, R_HI_CUT, -10), (2, R_LO_SHELF, 10), (3, R_LO_GAIN, -10), (4, R_HI_SHELF, 10), (5, R_HI_GAIN, -10)]
COMB = [(0, C_HZ, 10), (1, C_FEEDBACK, 10), (2, C_MIX, 10)]


def knobs(pads, d, knobs, lead=0):
    for k in knobs:
        col, pid, steps = k[:3]
        moves(pads, d, col + lead, pid, steps, k[3] if len(k) > 3 else None)


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


def on_and_removed(pads, d):
    """Mute + Device: off and on again; Delete + Device: removed."""
    held(pads, MUTE, lambda: press(pads, DEVICE))
    assert pads.api("effect_state", s=d.slot)["on"] is False
    save(pads, f"{pads.api('effect_name', s=d.slot).lower()}_off")
    held(pads, MUTE, lambda: press(pads, DEVICE))
    assert pads.api("effect_state", s=d.slot)["on"] is True
    held(pads, DELETE, lambda: press(pads, DEVICE))
    assert pads.api("effect_state", s=d.slot)["kind"] == 0


def delay_banks(pads, d, name, lead=0, perform=False):
    assert banks(pads) == 2
    assert d.get(D_SYNC) == 1  # (Tempo: the time a division)
    knobs(pads, d, DELAY_ECHOES, lead)
    if perform:
        intensity_on_column_0(pads)
    save(pads, f"{name}_echoes")
    moves(pads, d, 3 + lead, D_SYNC, -CHOICE)  # Free: the times in ms
    assert d.get(D_SYNC) == 0
    knobs(pads, d, DELAY_ECHOES_FREE, lead)
    save(pads, f"{name}_echoes_free")
    bank(pads, 1)
    knobs(pads, d, DELAY_TONE, lead)
    if perform:
        intensity_on_column_0(pads)
    save(pads, f"{name}_tone")
    # The lower row: its styles (Ping-pong now, from the dropdown).
    bank(pads, 0)
    assert view(pads)["lit"] & 0xF == 1 << 2, view(pads)
    press(pads, LOWER + 3)  # Mid ping-pong
    pads.wait(4)
    assert d.get(D_STYLE) == 3
    press(pads, LOWER + 0)  # Mono: one time both sides
    pads.wait(4)
    assert d.get(D_STYLE) == 0
    save(pads, f"{name}_mono")


def reverb_banks(pads, d, name, lead=0, perform=False):
    assert banks(pads) == 2
    knobs(pads, d, REVERB_ROOM, lead)
    if perform:
        intensity_on_column_0(pads)
    save(pads, f"{name}_room")
    bank(pads, 1)
    knobs(pads, d, REVERB_TONE, lead)
    if perform:
        intensity_on_column_0(pads)
    save(pads, f"{name}_tone")


def test_delay_in_a_slot(pads, fixtures):
    d = in_slot(pads, "delay", sample=os.path.join(fixtures, "loop.wav"))
    delay_banks(pads, d, "delay_slot")
    playing(pads, "delay_slot_playing")
    print("draw µs (delay, slot):", draw_us(pads))
    assert 0 < draw_us(pads)[0] < 5000
    on_and_removed(pads, d)


def test_delay_on_the_synths_effects_tab(pads):
    d = on_synth(pads, "delay")
    # The picker first (another effect: its knobs no longer the delay's), On last.
    on_last(pads, d, D_ON)
    delay_banks(pads, d, "delay_synth", lead=1)
    bank(pads, 0)
    turn(pads, 0, CHOICE)  # the picker: the next in the chain
    before = d.get(D_FEEDBACK)
    turn(pads, 2, 10)
    assert d.get(D_FEEDBACK) == before
    turn(pads, 0, -CHOICE)  # back to the delay
    moves(pads, d, 2, D_FEEDBACK, 10)
    print("draw µs (delay, synth):", draw_us(pads))


def test_delay_as_a_perform_effect(pads):
    d = in_perform(pads, "delay")
    delay_banks(pads, d, "delay_perform", lead=1, perform=True)


def test_reverb_in_a_slot(pads, fixtures):
    d = in_slot(pads, "reverb", sample=os.path.join(fixtures, "loop.wav"))
    reverb_banks(pads, d, "reverb_slot")
    playing(pads, "reverb_slot_playing")
    print("draw µs (reverb, slot):", draw_us(pads))
    assert 0 < draw_us(pads)[0] < 5000
    on_and_removed(pads, d)


def test_reverb_on_the_synths_effects_tab(pads):
    d = on_synth(pads, "reverb")
    on_last(pads, d, R_ON)
    reverb_banks(pads, d, "reverb_synth", lead=1)
    print("draw µs (reverb, synth):", draw_us(pads))


def test_reverb_as_a_perform_effect(pads):
    d = in_perform(pads, "reverb")
    reverb_banks(pads, d, "reverb_perform", lead=1, perform=True)


def test_comb_in_a_slot(pads, fixtures):
    d = in_slot(pads, "comb", sample=os.path.join(fixtures, "loop.wav"))
    assert banks(pads) == 1
    knobs(pads, d, COMB)
    save(pads, "comb_slot")
    # The lower row: its feedback's sign.
    assert view(pads)["lit"] & 0x3 == 1
    press(pads, LOWER + 1)  # Odd harmonics: the feedback upside down
    pads.wait(4)
    assert d.get(C_FEEDBACK) < 0
    save(pads, "comb_slot_odd")
    press(pads, LOWER + 0)
    pads.wait(4)
    assert d.get(C_FEEDBACK) > 0
    playing(pads, "comb_slot_playing")
    print("draw µs (comb, slot):", draw_us(pads))
    assert 0 < draw_us(pads)[0] < 5000
    on_and_removed(pads, d)


def test_comb_as_a_perform_effect(pads):
    d = in_perform(pads, "comb")
    assert banks(pads) == 1
    knobs(pads, d, COMB, lead=1)
    intensity_on_column_0(pads)
    pads.api("effect_hold", index=0, on=True, intensity=0.5)  # held: the picture as hard as it's pressed
    pads.wait(4)
    save(pads, "comb_perform")
    pads.api("effect_hold", index=0, on=False)
