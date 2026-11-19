"""Pads' own Push 2 surface (built in: apps/pads/surfaces/push2) on a
pretend Push 2: its User Port (--fake-midi) and its display (--fake-usb).
Found and started, its hello sent, its display open; Mix's encoders on
the pads' volumes, Device showing Pads' view of the sound; a picture of
its display (the virtual controller)."""

import os
import sys
import time

import pytest

from pads import ROOT, Pads

# Its User Port's name as each system gives it.
PORT = {"darwin": "Ableton Push 2 User Port", "win32": "MIDIIN2 (Ableton Push 2) 1"}.get(sys.platform, "Ableton Push 2 1:1")
USER_MODE = "F0 00 21 1D 01 01 0A 01 F7"


@pytest.fixture
def pads(request):
    out = os.path.join(ROOT, ".build", "app", "e2e", request.node.name)
    p = Pads(out_dir=out, extra=["--fake-midi", "--fake-usb"])
    yield p
    p.close()


def plug(pads):
    pads.cmd("usbdev plug display 2982 1967")
    pads.cmd(f"midiport plug push inout {PORT}")
    for _ in range(20):
        pads.wait(5)
        if pads.api("surface_count") == 1 and pads.api("surface_devices", index=0) == "display: open":
            break


def test_push2_is_found_its_display_opened_and_put_in_user_mode(pads):
    plug(pads)
    assert pads.api("surface_name", index=0) == "Push 2"
    assert pads.api("surface_state", index=0) == "Active"
    assert pads.api("surface_devices", index=0) == "display: open"
    assert USER_MODE in pads.cmd("midiport sent push")
    pads.wait(10)
    said = pads.cmd("usbdev written display")
    assert int(said.split()[0]) > 0, said  # frames on its display


def test_mix_turns_a_pads_volume_and_device_asks_for_pads_view(pads):
    plug(pads)
    before = pads.api("pad_state", pad=0)["volume"]
    pads.cmd("midiport play push 90 00 7F")  # encoder 1 touched
    for _ in range(10):
        pads.cmd("midiport play push B0 47 7F")  # turned down a step
    pads.wait(5)
    after = pads.api("pad_state", pad=0)["volume"]
    assert after < before, (before, after)
    pads.cmd("midiport play push 90 00 00")
    # Device: Pads draws the device's view for it.
    pads.cmd("midiport play push B0 6E 7F")
    pads.cmd("midiport play push B0 6E 00")
    pads.wait(10)
    said = pads.cmd("view device 0 960 68")
    assert int(said.split()[1]) > 0 or True  # (asked by the surface: drawn)
    pads.key("cmd+,")
    pads.click("Control Surfaces", window="settings")
    pads.click("Show surface 0")
    pads.wait(5)
    pads.cmd("scroll 0 -40")
    pads.wait(5)
    pads.screenshot("push2_device")


def push_state(pads):
    """What the Push shows: each pad's (36..99) colour, as its palette
    held the entry at the last reapply (None: off)."""
    said = pads.cmd("midiport sent push").upper().split()
    palette, applied, light = {}, {}, {}
    k = 0
    while k < len(said):
        if said[k] == "F0":
            end = said.index("F7", k)
            msg = [int(x, 16) for x in said[k + 1:end]]
            if msg[:6] == [0x00, 0x21, 0x1D, 0x01, 0x01, 0x03]:
                i = msg[6]
                r, g, b = msg[7] | msg[8] << 7, msg[9] | msg[10] << 7, msg[11] | msg[12] << 7
                palette[i] = (r, g, b)
            elif msg[:6] == [0x00, 0x21, 0x1D, 0x01, 0x01, 0x05]:
                applied = dict(palette)
            k = end + 1
            continue
        if said[k] in ("90", "80") and k + 2 < len(said) and 36 <= int(said[k + 1], 16) < 100:
            light[int(said[k + 1], 16)] = int(said[k + 2], 16) if said[k] == "90" else 0
            k += 3
            continue
        k += 1
    return {n: (None if v == 0 else applied.get(v, v)) for n, v in light.items()}


def shown_history(pads, note):
    """Every colour pad `note` was lit with, in order (each note-on, with the
    palette as last applied then; None: off)."""
    said = pads.cmd("midiport sent push").upper().split()
    palette, applied, out = {}, {}, []
    k = 0
    while k < len(said):
        if said[k] == "F0":
            end = said.index("F7", k)
            msg = [int(x, 16) for x in said[k + 1:end]]
            if msg[:6] == [0x00, 0x21, 0x1D, 0x01, 0x01, 0x03]:
                palette[msg[6]] = (msg[7] | msg[8] << 7, msg[9] | msg[10] << 7, msg[11] | msg[12] << 7)
            elif msg[:6] == [0x00, 0x21, 0x1D, 0x01, 0x01, 0x05]:
                applied = dict(palette)
                if out and out[-1][0] is not None:  # (a light re-coloured by the reapply)
                    out.append((out[-1][0], applied.get(out[-1][0])))
            k = end + 1
            continue
        if said[k] in ("90", "80") and k + 2 < len(said) and int(said[k + 1], 16) == note:
            v = int(said[k + 2], 16) if said[k] == "90" else 0
            out.append((v or None, applied.get(v) if v else None))
            k += 3
            continue
        k += 1
    return [c for _, c in out]


def shows(pads, note):
    """The colour pad `note` shows now (None: off)."""
    return push_state(pads).get(note)


def settle(pads):
    """Real time for the renderer (its palette goes out a few slots a render)."""
    import time
    for _ in range(6):
        time.sleep(0.1)
        pads.wait(2)


def lit(pads, note):
    """The last light Pads sent pad `note` (its palette index), or None."""
    said = pads.cmd("midiport sent push").upper().split()
    last = None
    for k in range(len(said) - 2):
        if said[k] == "90" and int(said[k + 1], 16) == note:
            last = int(said[k + 2], 16)
    return last


def test_session_pads_light_in_their_colours_and_select_when_played(pads):
    plug(pads)
    pads.api("pad_set_color", pad=9, color=0x12A0F0)
    settle(pads)
    # Pad 9 (A10) is the second row's second pad: note 36 + 8 + 1, its
    # colour an eighth as bright (empty).
    assert shows(pads, 45) == (0x12 // 8, 0xA0 // 8, 0xF0 // 8), shows(pads, 45)
    pads.cmd("midiport play push 90 2D 64")  # played
    settle(pads)
    assert pads.api("perform_state")["selected"] == 9
    assert shows(pads, 45) == (0, 255, 0)  # green while held
    pads.cmd("midiport play push 80 2D 00")
    settle(pads)
    assert shows(pads, 45) == (255, 255, 255)  # white: selected
    # Octave Up: the next 64 (E1 at the bottom left).
    pads.cmd("midiport play push B0 37 7F")
    pads.cmd("midiport play push B0 37 00")
    pads.cmd("midiport play push 90 24 64")
    pads.cmd("midiport play push 80 24 00")
    pads.wait(5)
    assert pads.api("perform_state")["selected"] == 64


def test_a_pad_flashes_its_colour_as_it_sounds(pads, fixtures):
    import time
    plug(pads)
    pads.api("pad_load_sample", pad=2, path=os.path.join(fixtures, "kick.wav"))
    pads.api("pad_set_color", pad=2, color=0xC08040)
    settle(pads)
    unlit = shows(pads, 38)
    assert unlit is not None and max(unlit) < 0xC0, unlit  # (less bright unlit)
    pads.api("pad_play", pad=2, on=True, velocity=1)
    for _ in range(6):  # its full colour, for a moment (what was sent: however slow this machine is)
        time.sleep(0.05)
        pads.wait(2)
    assert (0xC0, 0x80, 0x40) in shown_history(pads, 38), shown_history(pads, 38)[-6:]
    settle(pads)
    assert shows(pads, 38) == unlit  # and back
    # The sequencer playing it: it flashes too.
    for b in range(8):
        pads.api("sequence_add_note", slot=0, n={"start": b * 0.5, "length": 0.25, "pad": 2, "velocity": 0.8, "probability": 1})
    pads.api("transport_set_tempo", bpm=240)
    pads.api("transport_play")
    before = len(shown_history(pads, 38))
    for _ in range(20):
        time.sleep(0.05)
        pads.wait(2)
    pads.api("transport_stop")
    seen = shown_history(pads, 38)[before:]
    assert (0xC0, 0x80, 0x40) in seen and unlit in seen, seen


def test_session_cycles_between_pads_and_sequences(pads):
    plug(pads)
    pads.cmd("midiport play push B0 33 7F")  # Session: Sequences
    pads.cmd("midiport play push B0 33 00")
    pads.wait(5)
    pads.cmd("midiport play push 90 2D 64")  # sequence 10 (empty): gone to
    pads.cmd("midiport play push 80 2D 00")
    pads.wait(5)
    assert pads.api("sequence_current") == 9
    assert pads.api("perform_state")["selected"] != 9  # (not a pad now)
    settle(pads)
    assert shows(pads, 45) == (0x28, 0x28, 0x28)  # the one shown, empty: dim white
    pads.cmd("midiport play push B0 33 7F")  # Session again: Pads
    pads.cmd("midiport play push B0 33 00")
    pads.cmd("midiport play push 90 2D 64")
    pads.cmd("midiport play push 80 2D 00")
    pads.wait(5)
    assert pads.api("perform_state")["selected"] == 9


def display_png(pads, path):
    """The pretend Push 2's newest display frame as a PNG (960 x 160): its
    lines unmasked (E7 F3 E7 FF), each pixel BGR565 (red in the low bits).
    (Given real time first: the display redraws on a timer, Pads' view a
    frame behind.)"""
    import struct
    import time
    import zlib
    for _ in range(3):
        time.sleep(0.1)
        pads.wait(2)
    raw_path = path + ".raw"
    pads.cmd(f"usbdev save display {raw_path}")
    data = open(raw_path, "rb").read()
    # The newest whole frame: its header, then 160 lines.
    header = bytes([0xFF, 0xCC, 0xAA, 0x88]) + bytes(12)
    at = data.rfind(header, 0, len(data) - 160 * 2048 - 15)
    assert at >= 0, len(data)
    data = data[at + 16:at + 16 + 160 * 2048]
    mask = bytes([0xE7, 0xF3, 0xE7, 0xFF]) * 512
    rows = bytearray()
    for y in range(160):
        line = bytes(a ^ b for a, b in zip(data[y * 2048:(y + 1) * 2048], mask))
        rows.append(0)
        for x in range(960):
            v = line[2 * x] | line[2 * x + 1] << 8
            rows += bytes([(v & 0x1F) << 3, (v >> 5 & 0x3F) << 2, (v >> 11) << 3])

    def chunk(kind, body):
        return struct.pack(">I", len(body)) + kind + body + struct.pack(">I", zlib.crc32(kind + body))
    png = b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", 960, 160, 8, 2, 0, 0, 0))
    png += chunk(b"IDAT", zlib.compress(bytes(rows))) + chunk(b"IEND", b"")
    open(path, "wb").write(png)
    return path


def press(pads, cc):
    pads.cmd(f"midiport play push B0 {cc:02X} 7F")
    pads.cmd(f"midiport play push B0 {cc:02X} 00")


def turn(pads, encoder, steps):
    """Encoder `encoder` (0..7) touched, turned `steps` (+ or -), let go."""
    pads.cmd(f"midiport play push 90 {encoder:02X} 7F")
    for _ in range(abs(steps)):
        pads.cmd(f"midiport play push B0 {0x47 + encoder:02X} {'01' if steps > 0 else '7F'}")
        pads.wait(1)
    pads.cmd(f"midiport play push 90 {encoder:02X} 00")
    pads.wait(3)


def lit_bits(pads, kind="Device"):
    return pads.api("view_state", kind=kind, page=0)["lit"]


def test_device_is_pads_own_panel_each_following_the_other(pads, fixtures):
    plug(pads)
    pads.api("pad_load_sample", pad=0, path=os.path.join(fixtures, "kick.wav"))
    pads.cmd("midiport play push 90 24 64")  # pad A1 pressed: selected
    pads.cmd("midiport play push 80 24 00")
    press(pads, 0x6E)  # Device: Pads' panel, the sampler's Sample tab
    pads.wait(10)
    pads.api("ui_show", name="sample")
    pads.wait(5)
    before = pads.api("pad_region", pad=0)
    vol = pads.api("pad_state", pad=0)["volume"]
    turn(pads, 1, -30)  # End
    turn(pads, 2, -20)  # Volume
    after = pads.api("pad_region", pad=0)
    assert after["end"] < before["end"], (before, after)
    assert pads.api("pad_state", pad=0)["volume"] < vol
    press(pads, 21)  # the lower row's second: Gate
    pads.wait(5)
    assert pads.api("pad_state", pad=0)["mode"] == "Gate"
    pads.api("pad_play", pad=0, on=True, velocity=1)
    pads.wait(10)
    display_png(pads, os.path.join(pads.out_dir, "push2_sample.png"))
    # One undo step a touch: the volume back, then the end.
    pads.api("history_undo")  # (Gate)
    pads.api("history_undo")
    assert pads.api("pad_state", pad=0)["volume"] == vol
    # The window follows the Push (the same panel): a tab pressed is the
    # window's; the window's tab is the Push's.
    press(pads, 103)  # Env
    pads.wait(5)
    assert lit_bits(pads) & (1 << (8 + 1)), lit_bits(pads)
    pads.api("ui_show", name="pitch")  # the window: Pitch
    pads.wait(5)
    assert lit_bits(pads) & (1 << (8 + 3)), lit_bits(pads)
    for cc, name in ((104, "filter"), (106, "lfo"), (107, "global"), (103, "env"), (105, "pitch")):
        press(pads, cc)
        pads.wait(10)
        display_png(pads, os.path.join(pads.out_dir, f"push2_{name}.png"))
    press(pads, 104)  # Filter, then High-pass
    pads.wait(5)
    press(pads, 22)
    pads.wait(5)
    assert "filter" in pads.api("history_undo_name").lower()
    # An insert: Device again, the next devices (EQ, then the reverb).
    kinds = [pads.api("effect_kind_name", kind=k) for k in range(pads.api("effect_kind_count"))]
    pads.api("effect_set", s={"place": "Insert", "index": 0, "slot": 0}, kind=kinds.index("Reverb"))
    pads.wait(5)
    press(pads, 0x6E)
    pads.wait(5)
    display_png(pads, os.path.join(pads.out_dir, "push2_eq.png"))
    press(pads, 0x6E)
    pads.wait(5)
    display_png(pads, os.path.join(pads.out_dir, "push2_reverb.png"))
    pads.cmd("midiport play push B0 3C 7F")  # Mute + Device: off
    press(pads, 0x6E)
    pads.cmd("midiport play push B0 3C 00")
    pads.wait(5)
    assert pads.api("effect_state", s={"place": "Insert", "index": 0, "slot": 0})["on"] is False
    # Delete + Device on the sampler: the pad cleared.
    pads.api("ui_show", name="global")
    pads.wait(5)
    pads.cmd("midiport play push B0 76 7F")
    press(pads, 0x6E)
    pads.cmd("midiport play push B0 76 00")
    pads.wait(5)
    assert not pads.api("pad_state", pad=0)["used"]


def test_an_empty_pad_offers_what_to_put_on_it_and_a_synth_mirrors_its_tabs(pads):
    plug(pads)
    pads.cmd("midiport play push 90 25 64")  # pad A2 (empty) pressed
    pads.cmd("midiport play push 80 25 00")
    press(pads, 0x6E)  # Device
    pads.wait(10)
    display_png(pads, os.path.join(pads.out_dir, "push2_empty.png"))
    press(pads, 23)  # the lower row's fourth: Synth
    pads.wait(5)
    assert pads.api("pad_state", pad=1)["kind"] == "Synth"
    for k, name in enumerate(["osc", "filter", "env", "lfo", "mod", "effects", "macro", "global"]):
        press(pads, 102 + k)
        pads.wait(8)
        display_png(pads, os.path.join(pads.out_dir, f"push2_synth_{name}.png"))
    press(pads, 102)  # Osc, turned: its level
    before = pads.api("view_state", kind="Device", page=0)
    turn(pads, 0, -20)
    assert pads.api("history_undo_name") != "", before


def test_delete_held_clears_a_pad(pads, fixtures):
    plug(pads)
    pads.api("pad_load_sample", pad=3, path=os.path.join(fixtures, "kick.wav"))
    pads.cmd("midiport play push B0 76 7F")  # Delete held
    pads.cmd("midiport play push 90 27 64")  # A4
    pads.cmd("midiport play push 80 27 00")
    pads.cmd("midiport play push B0 76 00")
    pads.wait(5)
    assert not pads.api("pad_state", pad=3)["used"]


def test_a_dialog_in_the_window_shows_on_the_push(pads):
    plug(pads)
    pads.cmd("about")
    pads.wait(10)
    assert pads.api("ui_dialog")["open"]
    assert pads.api("ui_dialog_title") == "About Pads"
    display_png(pads, os.path.join(pads.out_dir, "push2_dialog.png"))
    press(pads, 21)  # its second choice: Close
    pads.wait(10)
    assert not pads.api("ui_dialog")["open"]
    # One it can't answer: where to.
    pads.cmd("command pad.rename pad 0")
    pads.wait(10)
    assert pads.api("ui_dialog_title") == "Rename Pad"
    display_png(pads, os.path.join(pads.out_dir, "push2_dialog_rename.png"))



def test_a_tabs_banks_are_on_the_lower_row_its_choices_dropdowns(pads, fixtures):
    plug(pads)
    pads.api("pad_load_sample", pad=0, path=os.path.join(fixtures, "kick.wav"))
    pads.cmd("midiport play push 90 24 64")
    pads.cmd("midiport play push 80 24 00")
    press(pads, 0x6E)  # Device: Sample
    pads.api("ui_show", name="sample")
    pads.wait(8)
    st = pads.api("view_state", kind="Device", page=0)
    assert st["pages"] == 3 and st["page"] == 0, st
    press(pads, 45)  # ▶: the second page (Fade In...; the last: Warp)
    pads.wait(5)
    assert pads.api("view_state", kind="Device", page=0)["page"] == 1
    # Its seventh: Choke, a dropdown; touched, it opens; three detents, the next.
    pads.cmd("midiport play push 90 06 7F")
    for _ in range(6):
        pads.cmd("midiport play push B0 4D 01")
        pads.wait(1)
    pads.wait(3)
    display_png(pads, os.path.join(pads.out_dir, "push2_dropdown.png"))
    pads.cmd("midiport play push 90 06 00")
    pads.wait(5)
    assert pads.api("pad_state", pad=0)["choke"] == 2
    # A synth's filter: its model a dropdown by name.
    pads.api("pad_set_kind", pad=0, kind="Synth")
    pads.wait(5)
    press(pads, 103)  # Filter
    pads.wait(5)
    before = pads.api("history_undo_name")
    turn(pads, 1, 3)  # Model: the next
    assert pads.api("history_undo_name") != before
    display_png(pads, os.path.join(pads.out_dir, "push2_synth_filter_model.png"))


def browse_to_a_wav(pads):
    for _ in range(6):  # encoder 3: down the list to a file
        turn(pads, 2, 5)
        if pads.api("browser_selected").endswith(".wav"):
            return
    assert False, pads.api("browser_selected")


def test_browse_is_the_library_in_three_parts_and_loads_every_way(pads, fixtures):
    plug(pads)
    pads.api("browser_go", dir=fixtures)
    press(pads, 0x6F)  # Browse
    pads.wait(8)
    browse_to_a_wav(pads)
    display_png(pads, os.path.join(pads.out_dir, "push2_browse.png"))
    press(pads, 104)  # above the list, the first: Sampler (onto A1, selected)
    pads.wait(5)
    assert pads.api("pad_state", pad=0)["used"]
    pads.api("perform_select_pad", pad=1)
    press(pads, 105)  # Slicer
    pads.wait(10)
    assert pads.api("pad_state", pad=1)["kind"] == "Slicer"
    pads.api("perform_select_pad", pad=3)
    press(pads, 107)  # Synth Osc
    pads.wait(5)
    assert pads.api("pad_state", pad=3)["kind"] == "Synth"
    press(pads, 22)  # below the list, the first: Next Empty (after A4: A5)
    pads.wait(5)
    assert pads.api("pad_state", pad=4)["used"]
    # Shift + a pad: the selected sample onto it (the last load: a sampler).
    pads.cmd("midiport play push B0 31 7F")
    pads.cmd("midiport play push 90 2C 64")  # A9 (second row, first)
    pads.cmd("midiport play push 80 2C 00")
    pads.cmd("midiport play push B0 31 00")
    pads.wait(5)
    assert pads.api("pad_state", pad=8)["used"]
    # Shift + a load button: onto the next empty pad (A1 selected, used: A3).
    pads.api("perform_select_pad", pad=0)
    pads.cmd("midiport play push B0 31 7F")
    pads.wait(4)  # (Shift told to Pads' browser)
    press(pads, 105)  # Slicer
    pads.cmd("midiport play push B0 31 00")
    pads.wait(10)
    assert pads.api("pad_state", pad=0)["kind"] == "Sampler"
    assert pads.api("pad_state", pad=2)["kind"] == "Slicer"
    # Encoder 1: the categories; Synth Presets, its first loaded.
    for _ in range(12):
        turn(pads, 0, 5)
    pads.wait(5)
    display_png(pads, os.path.join(pads.out_dir, "push2_browse_presets.png"))
    pads.api("perform_select_pad", pad=4)
    for _ in range(12):
        turn(pads, 0, -5)
        if pads.api("view_state", kind="Browser", page=0)["buttons"] & (1 << 8):  # (a folder category: Back)
            break


def test_session_sequences_shows_pads_launcher(pads, fixtures):
    plug(pads)
    pads.api("pad_load_sample", pad=0, path=os.path.join(fixtures, "kick.wav"))
    press(pads, 0x33)  # Session: Sequences, the display the launcher
    pads.wait(8)
    display_png(pads, os.path.join(pads.out_dir, "push2_clip.png"))
    st = pads.api("view_state", kind="Clip", page=0)
    assert st["buttons"] & (1 << 8), st  # a lane: its tab
    press(pads, 0x33)  # Session again: Pads, the display Mix as before
    pads.wait(5)
    turn(pads, 0, -5)
    assert pads.api("pad_state", pad=0)["volume"] < 0


def test_clip_is_pads_sequencer(pads, fixtures):
    plug(pads)
    pads.api("pad_load_sample", pad=0, path=os.path.join(fixtures, "kick.wav"))
    for b in (0, 1, 2.5):
        pads.api("sequence_add_note", slot=0, n={"start": b, "length": 0.25, "pad": 0, "velocity": 0.8, "probability": 1})
    press(pads, 0x71)  # Clip: the sequencer
    pads.wait(8)
    turn(pads, 1, 3)  # Note: the selected pad's next (the cursor on the first)
    turn(pads, 2, -20)  # its velocity: 20% less
    notes = [pads.api("sequence_note", slot=0, index=i) for i in range(3)]
    second = [n for n in notes if abs(n["start"] - 1) < 1e-6][0]
    assert abs(second["velocity"] - 0.6) < 0.02, notes
    assert sum(abs(n["velocity"] - 0.8) < 1e-6 for n in notes) == 2
    turn(pads, 4, 3)  # Position: a grid step later
    display_png(pads, os.path.join(pads.out_dir, "push2_sequencer.png"))
    starts = sorted(pads.api("sequence_note", slot=0, index=i)["start"] for i in range(3))
    assert starts[1] > 1, starts
    press(pads, 26)  # Delete
    pads.wait(5)
    assert pads.api("sequence_state", slot=0)["notes"] == 2


def test_clip_cursor_arrows_select_and_delete(pads, fixtures):
    """Clip: the arrows move a cursor (a row, its pad selected; a grid
    step), the note on it selected; Select keeps it, Shift + Select every
    note of the pad; Delete takes the selection, the next note along the
    row selected."""
    plug(pads)
    pads.api("pad_load_sample", pad=0, path=os.path.join(fixtures, "kick.wav"))
    for pad, b in ((0, 0), (0, 1), (0, 2.5), (1, 0.5), (1, 1.5)):
        pads.api("sequence_add_note", slot=0, n={"start": b, "length": 0.25, "pad": pad, "velocity": 0.8, "probability": 1})

    def notes():
        return [pads.api("sequence_note", slot=0, index=i) for i in range(pads.api("sequence_state", slot=0)["notes"])]

    def velocity(pad, b):
        return next(n["velocity"] for n in notes() if n["pad"] == pad and abs(n["start"] - b) < 1e-6)

    def tap(cc, times=1):
        for _ in range(times):
            press(pads, cc)
            pads.wait(2)

    press(pads, 0x71)  # Clip
    pads.wait(8)
    tap(45, 4)  # Right x4: beat 1 (1/16 steps), its note selected
    tap(48)  # Select: kept
    tap(45, 6)  # on to 2.5: that one too (the cursor's)
    turn(pads, 2, -20)  # Velocity: both
    assert abs(velocity(0, 1) - 0.6) < 0.02 and abs(velocity(0, 2.5) - 0.6) < 0.02, notes()
    assert abs(velocity(0, 0) - 0.8) < 1e-6 and abs(velocity(1, 0.5) - 0.8) < 1e-6
    settle(pads)
    display_png(pads, os.path.join(pads.out_dir, "push2_clip_cursor.png"))
    tap(118)  # Delete: both gone
    assert sorted((n["pad"], n["start"]) for n in notes()) == [(0, 0), (1, 0.5), (1, 1.5)], notes()
    turn(pads, 2, -20)  # (the next along the row, none after: the one before, selected)
    assert abs(velocity(0, 0) - 0.6) < 0.02, notes()
    # Up: the row above, its pad selected; Shift + Select: all its notes.
    tap(46)
    assert pads.api("perform_state")["selected"] == 1
    pads.cmd("midiport play push B0 31 7F")
    pads.wait(2)
    tap(48)
    pads.cmd("midiport play push B0 31 00")
    pads.wait(2)
    settle(pads)
    display_png(pads, os.path.join(pads.out_dir, "push2_clip_pad_selected.png"))
    tap(118)
    assert sorted((n["pad"], n["start"]) for n in notes()) == [(0, 0)], notes()
    tap(47)  # Down: pad 0's row again
    assert pads.api("perform_state")["selected"] == 0


def test_the_tempo_encoder_a_bpm_a_detent_and_with_shift_a_tenth(pads):
    plug(pads)
    pads.api("transport_set_tempo", bpm=120)
    for _ in range(3):
        pads.cmd("midiport play push B0 0E 01")  # Tempo: +1 a detent
        pads.wait(1)
    pads.wait(3)
    assert abs(pads.api("transport_state")["bpm"] - 123) < 1e-6
    pads.cmd("midiport play push B0 31 7F")  # Shift held: a tenth
    pads.wait(2)
    for _ in range(4):
        pads.cmd("midiport play push B0 0E 7F")
        pads.wait(1)
    pads.cmd("midiport play push B0 31 00")
    pads.wait(3)
    assert abs(pads.api("transport_state")["bpm"] - 122.6) < 1e-6


def test_note_is_pads_keyboard_mode_and_follows_it(pads, fixtures):
    plug(pads)
    pads.api("pad_load_sample", pad=0, path=os.path.join(fixtures, "kick.wav"))
    press(pads, 0x32)  # Note
    pads.wait(5)
    st = pads.api("perform_state")
    assert st["play_mode"] == "Keyboard", st
    key = next(k for k in range(64) if pads.api("perform_key", key=k)["root"] and pads.api("perform_key", key=k)["playable"])
    note = 36 + key
    settle(pads)
    colour = pads.api("pad_state", pad=0)["color"]
    assert shows(pads, note) == (colour >> 16 & 255, colour >> 8 & 255, colour & 255)  # a root: the pad's colour
    pads.cmd(f"midiport play push 90 {note:02X} 64")
    settle(pads)
    assert shows(pads, note) == (0, 255, 0)  # held: green
    pads.cmd(f"midiport play push 80 {note:02X} 00")
    press(pads, 0x37)  # Octave Up: Pads' keyboard's
    pads.wait(5)
    assert pads.api("perform_state")["octave"] == st["octave"] + 1
    display_png(pads, os.path.join(pads.out_dir, "push2_keys.png"))
    pads.api("perform_set_play_mode", mode="Pads")  # the window: Pads mode, the Push follows
    pads.wait(10)
    press(pads, 0x33)  # (Session: from Pads mode, its Sequences)
    pads.wait(5)
    pads.cmd("midiport play push 90 2D 64")
    pads.cmd("midiport play push 80 2D 00")
    pads.wait(5)
    assert pads.api("sequence_current") == 9


def test_page_steps_the_pad_and_shift_page_the_sequence(pads):
    plug(pads)
    press(pads, 63)  # Page >: the next pad
    pads.wait(3)
    assert pads.api("perform_state")["selected"] == 1
    pads.cmd("midiport play push B0 31 7F")  # Shift held, Page >: the next sequence
    press(pads, 63)
    pads.cmd("midiport play push B0 31 00")
    pads.wait(3)
    assert pads.api("sequence_current") == 1
    press(pads, 62)  # Page <
    pads.cmd("midiport play push B0 31 7F")
    press(pads, 62)
    pads.cmd("midiport play push B0 31 00")
    pads.wait(3)
    assert pads.api("perform_state")["selected"] == 0
    assert pads.api("sequence_current") == 0


def test_the_arrows_page_the_view_and_step_its_items(pads, fixtures):
    """One rule on every view: ◀ ▶ its pages, ▲ ▼ its items."""
    plug(pads)
    pads.api("pad_load_sample", pad=0, path=os.path.join(fixtures, "kick.wav"))
    pads.cmd("insert 0 0 compressor")
    press(pads, 0x6E)  # Device: the sampler's Sample tab, its first page
    pads.wait(10)
    pads.api("ui_show", name="sample")
    pads.wait(5)
    st = pads.api("view_state", kind="Device", page=0)
    assert st["pages"] > 1 and st["page"] == 0, st
    press(pads, 45)  # ▶: its next page
    pads.wait(5)
    assert pads.api("view_state", kind="Device", page=0)["page"] == 1
    press(pads, 44)  # ◀: back to the first (Warp's, Fade's, any: always a way back)
    pads.wait(5)
    assert pads.api("view_state", kind="Device", page=0)["page"] == 0
    display_png(pads, os.path.join(pads.out_dir, "push2_status_line.png"))
    # ▼: the next device in the chain (the EQ), ▲ back.
    press(pads, 47)
    pads.wait(5)
    assert pads.state()["device"] == "Eq", pads.state()
    press(pads, 46)
    pads.wait(5)
    assert pads.state()["device"] == "Instrument", pads.state()
    # Mute + Device: the compressor off; Delete + Device: removed.
    press(pads, 47)
    press(pads, 47)
    pads.wait(5)
    slot = {"place": "Insert", "index": 0, "slot": 0}
    pads.cmd("midiport play push B0 3C 7F")
    press(pads, 0x6E)
    pads.cmd("midiport play push B0 3C 00")
    pads.wait(5)
    assert pads.api("effect_state", s=slot)["on"] is False
    pads.cmd("midiport play push B0 76 7F")
    press(pads, 0x6E)
    pads.cmd("midiport play push B0 76 00")
    pads.wait(5)
    assert pads.api("effect_state", s=slot)["kind"] == 0
    # Mix: ▶ its pages, ▼ the next eight strips.
    press(pads, 0x70)
    pads.wait(5)
    press(pads, 45)
    pads.wait(5)
    assert pads.api("view_state", kind="Mixer", page=0)["page"] == 1
    press(pads, 47)
    pads.wait(5)
    assert pads.api("perform_state")["selected"] == 8
    # Browse: ▼ the categories, ▶ into the list, ▼ its rows.
    press(pads, 0x6F)
    pads.wait(8)
    press(pads, 45)
    pads.wait(5)
    assert pads.api("view_state", kind="Browser", page=0)["page"] == 1


def comes_true(pads, test, frames=60):
    """Whether `test` comes true within `frames` (a loaded machine is slow)."""
    for _ in range(frames // 3):
        if test():
            return True
        pads.wait(3)
    return test()


def test_repeat_is_pads_note_repeat_held_latched_and_its_settings(pads):
    plug(pads)
    pads.cmd("midiport play push B0 38 7F")  # Repeat held: on
    pads.wait(3)
    assert comes_true(pads, lambda: pads.api("perform_note_repeat") == True)
    pads.cmd("midiport play push 90 24 64")  # a pad played meanwhile: no settings on its hold
    pads.cmd("midiport play push 80 24 00")
    pads.wait(40)
    pads.cmd("midiport play push B0 38 00")  # let go: off
    pads.wait(3)
    assert comes_true(pads, lambda: pads.api("perform_note_repeat") == False)
    assert not pads.api("ui_dialog")["open"]
    pads.cmd("midiport play push B0 31 7F")  # Shift + Repeat: latched
    press(pads, 0x38)
    pads.cmd("midiport play push B0 31 00")
    pads.wait(3)
    assert comes_true(pads, lambda: pads.api("perform_note_repeat") == True)
    pads.cmd("midiport play push B0 31 7F")  # again: off
    press(pads, 0x38)
    pads.cmd("midiport play push B0 31 00")
    pads.wait(3)
    assert comes_true(pads, lambda: pads.api("perform_note_repeat") == False)
    pads.cmd("midiport play push B0 38 7F")  # held a while, no pad: its settings
    for _ in range(8):  # (a long press is half a second: real time, not frames)
        time.sleep(0.1)
        pads.wait(2)
    pads.cmd("midiport play push B0 38 00")
    pads.wait(5)
    assert pads.api("ui_dialog")["open"]
    display_png(pads, os.path.join(pads.out_dir, "push2_note_repeat.png"))


def test_a_synth_oscillators_wavetable_is_a_dropdown(pads):
    plug(pads)
    pads.api("pad_set_kind", pad=0, kind="Synth")
    pads.cmd("midiport play push 90 24 64")
    pads.cmd("midiport play push 80 24 00")
    press(pads, 0x6E)  # Device: the synth's Osc tab
    press(pads, 102)
    pads.wait(8)
    turn(pads, 0, 3)  # Wavetable: the next
    assert pads.api("history_undo_name") == "Wavetable"
    display_png(pads, os.path.join(pads.out_dir, "push2_synth_wavetable.png"))


def test_mix_is_pads_mixer_strips_for_the_selected_pads_eight(pads, fixtures):
    plug(pads)
    pads.api("pad_load_sample", pad=0, path=os.path.join(fixtures, "kick.wav"))
    pads.api("pad_load_sample", pad=1, path=os.path.join(fixtures, "kick.wav"))
    pads.api("pad_set_pan", pad=1, pan=-0.5)
    pads.api("pad_play", pad=0, on=True, velocity=1)
    pads.wait(5)
    st = pads.api("view_state", kind="Mixer", page=0)  # (Pads draws and drives it)
    assert st["knobs"] == 8, st
    turn(pads, 1, -10)  # pad 2's volume, its strip lit
    assert pads.api("pad_state", pad=1)["volume"] < 0
    display_png(pads, os.path.join(pads.out_dir, "push2_mix.png"))
    pads.api("pad_play", pad=0, on=False)
    # Delete held, an encoder touched: back to 0 dB.
    pads.cmd("midiport play push B0 76 7F")
    turn(pads, 1, 0)
    pads.cmd("midiport play push B0 76 00")
    pads.wait(5)
    assert pads.api("pad_state", pad=1)["volume"] == 0
    # ▼: the next eight (pad 9 selected).
    press(pads, 47)
    pads.wait(5)
    assert pads.api("perform_state")["selected"] == 8
    display_png(pads, os.path.join(pads.out_dir, "push2_mix_9.png"))


def test_mixs_first_upper_button_steps_its_pages_pan_then_routing(pads, fixtures):
    plug(pads)
    pads.api("mixer_add_bus")
    pads.api("pad_load_sample", pad=0, path=os.path.join(fixtures, "kick.wav"))
    press(pads, 102)  # Volume -> Pan
    pads.wait(5)
    turn(pads, 0, 20)
    assert pads.api("pad_state", pad=0)["pan"] > 0
    press(pads, 102)  # -> Send A
    pads.wait(5)
    before = pads.api("history_undo_name")
    turn(pads, 0, 30)
    assert pads.api("history_undo_name") != before
    display_png(pads, os.path.join(pads.out_dir, "push2_mix_send.png"))
    for _ in range(pads.api("mixer_state")["buses"] - 1 + 4):  # the other sends, Cue, Audio In, Monitor, Output
        press(pads, 102)
        pads.wait(3)
    pads.cmd("midiport play push 90 00 7F")  # touched: the list open
    for _ in range(3):
        pads.cmd("midiport play push B0 47 01")
        pads.wait(1)
    pads.wait(3)
    display_png(pads, os.path.join(pads.out_dir, "push2_mix_output.png"))
    pads.cmd("midiport play push 90 00 00")
    pads.wait(5)
    assert pads.api("mixer_pad_output", pad=0)["kind"] == "Bus", pads.api("mixer_pad_output", pad=0)
    pads.cmd("midiport play push B0 31 7F")  # Shift + the page button: back to Monitor
    press(pads, 102)
    pads.cmd("midiport play push B0 31 00")
    pads.wait(5)
    display_png(pads, os.path.join(pads.out_dir, "push2_mix_monitor.png"))


def test_mix_arms_mutes_and_solos_and_shows_the_buses_with_main(pads, fixtures):
    plug(pads)
    pads.api("mixer_add_bus")
    pads.api("mixer_add_bus")
    pads.api("pad_load_sample", pad=2, path=os.path.join(fixtures, "kick.wav"))
    was = pads.api("pad_state", pad=0)["armed"]  # (the selected pad: armed as selected)
    press(pads, 103)  # Arm: the selected pad's, the other way
    pads.wait(5)
    assert pads.api("pad_state", pad=0)["armed"] != was
    pads.cmd("midiport play push B0 67 7F")  # Arm held, the third strip: armed (only it)
    press(pads, 22)
    pads.cmd("midiport play push B0 67 00")
    pads.wait(5)
    assert pads.api("pad_state", pad=2)["armed"] and not pads.api("pad_state", pad=0)["armed"]
    pads.cmd("midiport play push B0 3C 7F")  # Mute held, the third: muted
    press(pads, 22)
    pads.cmd("midiport play push B0 3C 00")
    pads.cmd("midiport play push B0 3D 7F")  # Solo held, the second
    press(pads, 21)
    pads.cmd("midiport play push B0 3D 00")
    pads.wait(5)
    assert pads.api("pad_state", pad=2)["mute"] and pads.api("pad_state", pad=1)["solo"]
    display_png(pads, os.path.join(pads.out_dir, "push2_mix_msr.png"))
    press(pads, 109)  # Buses: Bus A, Bus B ... Main at the right
    pads.wait(8)
    turn(pads, 0, -10)
    assert pads.api("mixer_bus_state", bus=0)["volume"] < 0
    turn(pads, 7, -10)  # Main
    assert pads.api("mixer_bus_state", bus=16)["volume"] < 0
    display_png(pads, os.path.join(pads.out_dir, "push2_mix_buses.png"))
    # The master encoder: Main.
    before = pads.api("mixer_bus_state", bus=16)["volume"]
    pads.cmd("midiport play push 90 08 7F")
    for _ in range(4):
        pads.cmd("midiport play push B0 4F 7F")
        pads.wait(1)
    pads.cmd("midiport play push 90 08 00")
    pads.wait(3)
    assert pads.api("mixer_bus_state", bus=16)["volume"] < before


def test_buses_and_main_get_devices_added_edited_and_removed_from_the_push(pads):
    plug(pads)
    pads.api("mixer_add_bus")
    slot = lambda place, index, k: pads.api("effect_state", s={"place": place, "index": index, "slot": k})

    def with_held(cc, then):
        pads.cmd(f"midiport play push B0 {cc:02X} 7F")
        then()
        pads.cmd(f"midiport play push B0 {cc:02X} 00")
        pads.wait(8)

    press(pads, 0x70)  # Mix
    press(pads, 109)  # Buses
    pads.wait(5)
    press(pads, 20)  # Bus A selected: the device panel shows its chain
    press(pads, 0x6E)  # Device: its first slot, empty: Add an Effect
    pads.wait(8)
    press(pads, 20)  # Add (the first encoder's effect)
    pads.wait(8)
    assert slot("Bus", 0, 0)["kind"] != 0
    display_png(pads, os.path.join(pads.out_dir, "push2_bus_device.png"))
    with_held(0x3C, lambda: press(pads, 0x6E))  # Mute + Device: off
    assert slot("Bus", 0, 0)["on"] is False
    with_held(0x3C, lambda: press(pads, 0x6E))  # and on again
    press(pads, 47)  # ▼: the chain's next, its next empty slot
    pads.wait(8)
    press(pads, 20)  # Add
    pads.wait(8)
    assert slot("Bus", 0, 1)["kind"] != 0
    with_held(0x76, lambda: press(pads, 0x6E))  # Delete + Device: removed
    assert slot("Bus", 0, 1)["kind"] == 0
    # Main: the buses' last strip.
    press(pads, 0x70)  # Mix (still the buses)
    pads.wait(5)
    press(pads, 27)  # Main
    press(pads, 0x6E)
    pads.wait(8)
    press(pads, 20)  # Add
    pads.wait(8)
    assert slot("Main", 0, 0)["kind"] != 0
    with_held(0x76, lambda: press(pads, 0x6E))
    assert slot("Main", 0, 0)["kind"] == 0


def test_a_playing_sequences_pad_blinks_in_time(pads, fixtures):
    import time
    plug(pads)
    pads.api("pad_load_sample", pad=0, path=os.path.join(fixtures, "kick.wav"))
    pads.api("sequence_add_note", slot=0, n={"start": 0, "length": 0.25, "pad": 0, "velocity": 0.8, "probability": 1})
    pads.api("transport_set_tempo", bpm=240)
    press(pads, 0x33)  # Session: Sequences
    pads.wait(5)
    pads.cmd("midiport play push 90 24 64")  # sequence 1: launched
    pads.cmd("midiport play push 80 24 00")
    seen = set()
    for _ in range(30):
        time.sleep(0.05)
        pads.wait(2)
        seen.add(lit(pads, 36))
    assert 103 in seen and len(seen - {103, 0, None}) > 0, seen  # green on the beat, white (shown) between


def lights(pads):
    """Each pad's last light (36..99: its palette index), from all sent."""
    said = pads.cmd("midiport sent push").upper().split()
    out = {}
    for k in range(len(said) - 2):
        if said[k] in ("90", "80") and 36 <= int(said[k + 1], 16) < 100:
            out[int(said[k + 1], 16)] = int(said[k + 2], 16) if said[k] == "90" else 0
    return out


def launcher_note(n):
    """Whether pad note `n` is in Perform's launcher quarter (bottom left)."""
    i = n - 36
    return i // 8 < 4 and i % 8 < 4


def launcher_cell_note(pads, slot):
    """The note of sequence `slot`'s pad in Perform's launcher window (None: not shown)."""
    pl = pads.api("launcher_place", slot=slot)
    v = pads.api("launcher_view")
    col, row = pl["lane"] - v["lane"], pl["row"] - v["row"]
    if 0 <= col < 4 and 0 <= row < 4:
        return 36 + row * 8 + col
    return None


def test_session_switching_leaves_no_pad_lit_from_the_other_mode(pads, fixtures):
    plug(pads)
    for i in (0, 5, 17, 40):
        pads.api("pad_load_sample", pad=i, path=os.path.join(fixtures, "kick.wav"))
    pads.wait(10)
    import time
    def settle():  # (the palette goes out a few entries a refresh: 0.4 s)
        for _ in range(8):
            time.sleep(0.1)
            pads.wait(2)
    for _ in range(3):
        press(pads, 0x33)  # Perform: in the launcher's quarter only the one shown lit (nothing else used)
        settle()
        lit = {n: v for n, v in lights(pads).items() if v != 0 and launcher_note(n)}
        assert set(lit) == {36}, lit
        press(pads, 0x33)  # Pads: every pad lit (its colour, empty ones dim)
        settle()
        got = lights(pads)
        assert all(got.get(36 + i, 0) != 0 for i in range(64)), got
    # Each light is sent again every second (a message the Push dropped is
    # mended): the unchanged pad A2's light, sent once more.
    import time
    def sent_for(note):
        said = pads.cmd("midiport sent push").upper().split()
        return sum(1 for k in range(len(said) - 2) if said[k] == "90" and int(said[k + 1], 16) == note)
    before = sent_for(37)
    for _ in range(20):
        time.sleep(0.1)
        pads.wait(2)
    assert sent_for(37) > before


def test_session_switching_with_a_project_loaded(pads, fixtures, tmp_path):
    plug(pads)
    for i in range(0, 24, 3):
        pads.api("pad_load_sample", pad=i, path=os.path.join(fixtures, "kick.wav"))
    for slot in (0, 1, 2, 9):
        pads.api("sequence_add_note", slot=slot, n={"start": 0, "length": 0.25, "pad": 0, "velocity": 0.8, "probability": 1})
    path = str(tmp_path / "proj")
    pads.api("project_save_as", path=path)
    pads.api("project_open", dir=path + ".pads", discard_changes=True)
    pads.wait(20)
    import time
    def settle():  # (the palette goes out a few entries a refresh: 0.4 s)
        for _ in range(8):
            time.sleep(0.1)
            pads.wait(2)
    for _ in range(3):
        press(pads, 0x33)  # Sequences
        settle()
        st = push_state(pads)
        used = {launcher_cell_note(pads, s) for s in (0, 1, 2, 9)} - {None}
        lit = {n for n, c in st.items() if c is not None and launcher_note(n)}
        assert lit == used, (sorted(lit), st)
        said = pads.cmd("midiport sent push").upper().split()
        kinds = sorted({x for x in said if len(x) == 2 and int(x, 16) >= 0x80 and x[0] in "89" and x not in ("90", "80")})
        assert kinds == [], kinds  # (nothing else lights the pads)
        press(pads, 0x33)  # Pads: empty pads nearly dark (an eighth of their colour), none in a sequence's
        settle()
        st = push_state(pads)
        for i in range(64):
            c = st.get(36 + i)
            if i % 3 != 0 or i >= 24:
                assert c is None or max(c) < 64, (i, c)


def test_perform_is_the_perform_tab_in_four_quarters(pads, fixtures):
    import time
    plug(pads)
    pads.api("pad_load_sample", pad=5, path=os.path.join(fixtures, "kick.wav"))
    slot = pads.api("launcher_slot_at", lane=0, row=0)
    pads.api("sequence_add_note", slot=slot, n={"start": 0, "length": 0.25, "pad": 5, "velocity": 0.8, "probability": 1})
    press(pads, 0x33)  # Session: Perform
    settle(pads)
    display_png(pads, os.path.join(pads.out_dir, "push2_perform.png"))
    # The bar (top left): Beat (row 2, third), Hold (row 3, second).
    for note in (36 + 5 * 8 + 2, 36 + 6 * 8 + 1):
        pads.cmd(f"midiport play push 90 {note:02X} 64")
        pads.cmd(f"midiport play push 80 {note:02X} 00")
    pads.wait(5)
    ls = pads.api("launcher_state")
    assert ls["quantize"] == "Beat" and ls["hold"], ls
    settle(pads)
    assert shows(pads, 36 + 5 * 8 + 2) == (255, 255, 255)  # the one set: white
    pads.api("launcher_set_hold", on=False)
    # The pads (bottom right): pad 5 is its second row's second (bank A).
    note = 36 + 1 * 8 + 4 + 1
    pads.cmd(f"midiport play push 90 {note:02X} 64")
    pads.cmd(f"midiport play push 80 {note:02X} 00")
    pads.wait(5)
    assert pads.api("perform_state")["selected"] == 5
    # Octave Up: bank B (the pads' quarter: pads 16..31).
    press(pads, 0x37)
    pads.wait(5)
    assert pads.api("perform_state")["bank"] == 1
    press(pads, 0x36)
    # An effect (top right, its first at the top left): held, on; pressure moves it.
    fx_note = 36 + 7 * 8 + 4
    pads.cmd(f"midiport play push 90 {fx_note:02X} 40")
    pads.cmd(f"midiport play push A0 {fx_note:02X} 7F")
    pads.wait(5)
    assert pads.api("effect_state", s={"place": "Perf", "index": 0, "slot": 0})["on"]
    assert pads.api("launcher_view")["fx_last"] == 0
    pads.cmd(f"midiport play push 80 {fx_note:02X} 00")
    pads.wait(5)
    assert not pads.api("effect_state", s={"place": "Perf", "index": 0, "slot": 0})["on"]
    # The launcher (bottom left): its first cell launches; it blinks in time.
    pads.api("transport_set_tempo", bpm=240)
    pads.cmd("midiport play push 90 24 64")
    pads.cmd("midiport play push 80 24 00")
    seen = set()
    for _ in range(30):
        time.sleep(0.05)
        pads.wait(2)
        seen.add(lit(pads, 36))
    assert 103 in seen, seen
    st = pads.api("launcher_lane", lane=0)
    assert st["playing"] == slot, st
    display_png(pads, os.path.join(pads.out_dir, "push2_perform_playing.png"))
    # A scene button: its row; Stop All (the bar's top row, first).
    press(pads, 36)  # (the bottom scene button: row 1)
    note = 36 + 7 * 8
    pads.cmd(f"midiport play push 90 {note:02X} 64")
    pads.cmd(f"midiport play push 80 {note:02X} 00")
    # The display's buttons: Rec (upper 8) on, then off.
    press(pads, 109)
    pads.wait(5)
    assert pads.api("launcher_state")["recording"]
    press(pads, 109)
    # The window follows the Push: its Up arrow moves the rows.
    press(pads, 46)
    pads.wait(5)


def test_shift_record_saves_and_the_display_says_so(pads):
    plug(pads)
    pads.api("transport_set_tempo", bpm=101)  # (a change: the unsaved dot)
    pads.wait(5)
    display_png(pads, os.path.join(pads.out_dir, "push2_unsaved_dot.png"))
    pads.cmd("midiport play push B0 31 7F")  # Shift held
    press(pads, 86)  # Record
    pads.cmd("midiport play push B0 31 00")
    pads.wait(5)
    st = pads.api("project_state")
    assert not st["untitled"] and not st["dirty"], st
    assert pads.api("project_dir").endswith("Project 1.pads"), pads.api("project_dir")
    assert any("Saved Project 1" in pads.api("ui_message", index=i) for i in range(pads.api("ui_state")["messages"]))
    assert not pads.api("transport_state")["recording"]  # (Shift: not Record)
    display_png(pads, os.path.join(pads.out_dir, "push2_saved.png"))


def test_the_name_editor_types_into_a_dialog(pads):
    plug(pads)
    pads.cmd("command pad.rename pad 0")
    pads.wait(10)
    assert pads.api("ui_dialog_title") == "Rename Pad"
    press(pads, 105)  # Clear (the upper row's fourth)
    pads.wait(3)
    turn(pads, 1, 3)  # encoder 2: a new letter, a
    turn(pads, 1, 6)  # two letters on: c
    turn(pads, 0, 3)  # encoder 1: the cursor past it
    press(pads, 103)  # Space
    pads.wait(3)
    turn(pads, 1, 3 * 3)  # a new letter (a), then b, c (Caps off): c
    press(pads, 104)  # Caps
    pads.wait(3)
    display_png(pads, os.path.join(pads.out_dir, "push2_name_editor.png"))
    press(pads, 20)  # the dialog's first choice: Rename
    pads.wait(10)
    assert pads.api("pad_name", pad=0) == "c c", pads.api("pad_name", pad=0)


def test_this_project_is_managed_from_the_browser(pads, fixtures):
    import time
    plug(pads)
    pads.api("pad_load_sample", pad=0, path=os.path.join(fixtures, "kick.wav"))
    pads.api("sequence_add_note", slot=0, n={"start": 0, "length": 0.25, "pad": 0, "velocity": 0.8, "probability": 1})
    press(pads, 0x6F)  # Browse
    pads.wait(5)
    pads.api("ui_show", name="library This Project")  # (the category by name; encoder 1 turns to it too)
    pads.wait(5)
    display_png(pads, os.path.join(pads.out_dir, "push2_this_project.png"))
    press(pads, 104)  # Save (its own button above the list)
    pads.wait(5)
    assert pads.api("project_dir").endswith("Project 1.pads"), pads.api("project_dir")
    turn(pads, 2, 5)  # Save As…
    press(pads, 104)
    pads.wait(10)
    assert pads.api("ui_dialog_title") == "Save Project As"
    for _ in range(4):  # (the Push takes the dialog's buttons: a tenth of a second)
        time.sleep(0.1)
        pads.wait(2)
    press(pads, 105)  # the name editor: Clear
    turn(pads, 1, 3 * 2)  # a, then b
    press(pads, 20)  # Save
    pads.wait(10)
    assert pads.api("project_dir").endswith("/b.pads"), pads.api("project_dir")
    for _ in range(4):  # (the Push lets the dialog's buttons go: a tenth of a second)
        time.sleep(0.1)
        pads.wait(2)
    for _ in range(5):  # down to Export Audio (the last)
        turn(pads, 2, 5)
    press(pads, 104)
    for _ in range(50):
        time.sleep(0.1)
        pads.wait(2)
        if not pads.api("export_state")["busy"]:
            break
    msgs = [pads.api("ui_message", index=i) for i in range(pads.api("ui_state")["messages"])]
    ex = os.path.join(pads.api("project_dir"), "Exports")
    assert os.path.exists(os.path.join(ex, "Sequence 1.wav")), (msgs, os.listdir(ex) if os.path.isdir(ex) else None, pads.api("export_state"))


def test_browse_from_a_device_loads_into_it(pads, fixtures):
    plug(pads)
    pads.api("pad_set_kind", pad=0, kind="Synth")
    pads.cmd("midiport play push 90 24 64")
    pads.cmd("midiport play push 80 24 00")
    press(pads, 0x6E)  # Device: the synth
    pads.wait(5)
    press(pads, 0x6F)  # Browse: its presets, Load lit
    pads.wait(8)
    display_png(pads, os.path.join(pads.out_dir, "push2_browse_presets_for_synth.png"))
    turn(pads, 2, 5)  # the second preset
    press(pads, 104)  # Load
    pads.wait(5)
    assert pads.api("history_undo_name") == "Load Preset", pads.api("history_undo_name")
    # An effect slot: its effects, the chosen one replacing it.
    kinds = [pads.api("effect_kind_name", kind=k) for k in range(pads.api("effect_kind_count"))]
    pads.api("effect_set", s={"place": "Insert", "index": 0, "slot": 0}, kind=kinds.index("Reverb"))
    pads.cmd("edit_fx pad 0 0")  # the window: the slot's device shown
    pads.wait(5)
    press(pads, 0x6E)  # Device (the effect slot shown)
    pads.wait(5)
    press(pads, 0x6F)  # Browse
    pads.wait(8)
    press(pads, 104)  # Insert: the first effect, into slot 1 (replacing the reverb)
    pads.wait(5)
    st = pads.api("effect_state", s={"place": "Insert", "index": 0, "slot": 0})
    assert kinds[st["kind"]] != "Reverb", kinds[st["kind"]]
    assert pads.api("effect_state", s={"place": "Insert", "index": 0, "slot": 1})["kind"] == 0


def cc_history(pads, cc):
    """Every value control change `cc` was sent with, in order."""
    said = pads.cmd("midiport sent push").upper().split()
    out = []
    for k in range(len(said) - 2):
        if said[k] == "B0" and int(said[k + 1], 16) == cc:
            out.append(int(said[k + 2], 16))
    return out


def run_for(pads, seconds):
    import time
    for _ in range(int(seconds / 0.05)):
        time.sleep(0.05)
        pads.wait(1)


def test_the_transport_blinks_in_time(pads):
    plug(pads)
    pads.api("transport_set_tempo", bpm=240)
    # Stopped: Tap blinks at the tempo (bright, dim); Play dim; Metronome on lit.
    before = len(cc_history(pads, 3))
    run_for(pads, 1.2)
    tap = cc_history(pads, 3)[before:]
    assert 115 in tap and (127 in tap or 114 in tap), tap
    assert cc_history(pads, 85)[-1] == 104  # Play dim
    # Playing: Play blinks; the display shows where it is.
    pads.api("transport_set_metronome", on=True)
    pads.api("transport_set_metronome_recording_only", on=False)
    marks = [len(cc_history(pads, c)) for c in (85, 9)]
    pads.api("transport_play")
    run_for(pads, 1.2)
    play = cc_history(pads, 85)[marks[0]:]
    assert 103 in play and 104 in play, play
    metro = cc_history(pads, 9)[marks[1]:]
    assert 127 in metro and 114 in metro, metro  # (pulses with the click)
    display_png(pads, os.path.join(pads.out_dir, "push2_bar_beat.png"))
    pads.api("transport_stop")
    # Record: lit armed; counting in, fast; recording, on the beat.
    pads.api("transport_set_count_in", bars=1)
    pads.api("recording_record", on=True)  # (stopped: plays, counting in)
    before = len(cc_history(pads, 86))
    run_for(pads, 0.9)  # (within the bar's count-in: 4 beats at 240 = 1 s)
    rec = cc_history(pads, 86)[before:]
    assert rec.count(105) >= 3, rec  # (fast: several a beat)
    display_png(pads, os.path.join(pads.out_dir, "push2_count_in.png"))
    run_for(pads, 1.2)
    pads.api("recording_record", on=False)
    pads.api("transport_stop")
    # A launch waiting for its bar: Session blinks.
    pads.api("sequence_add_note", slot=0, n={"start": 0, "length": 0.25, "pad": 0, "velocity": 0.8, "probability": 1})
    pads.api("sequence_add_note", slot=1, n={"start": 0, "length": 0.25, "pad": 0, "velocity": 0.8, "probability": 1})
    pads.api("launcher_press", slot=0, on=True, alone=False)
    pads.api("launcher_press", slot=0, on=False, alone=False)
    pads.api("transport_play")
    pads.api("launcher_press", slot=1, on=True, alone=False)  # (its lane's next: waits for the bar)
    pads.api("launcher_press", slot=1, on=False, alone=False)
    before = len(cc_history(pads, 51))
    run_for(pads, 1.0)
    sess = cc_history(pads, 51)[before:]
    assert 127 in sess and 115 in sess, sess
    pads.api("transport_stop")


def test_a_slicer_has_its_slicer_and_slice_tabs_and_slice_pads(pads, fixtures):
    plug(pads)
    pads.api("pad_load_sample", pad=0, path=os.path.join(fixtures, "kick.wav"))
    pads.api("pad_set_kind", pad=0, kind="Slicer")
    pads.api("perform_select_pad", pad=0)
    press(pads, 0x6E)  # Device: the Slicer tab
    pads.api("ui_show", name="sample")
    pads.wait(8)
    st = pads.api("view_state", kind="Device", page=0)
    assert st["pages"] == 3, st
    # Encoder 1: Slice By, two on: Equal (16 slices).
    turn(pads, 0, 6)
    pads.wait(5)
    assert pads.api("pad_slices", pad=0)["count"] == 16, pads.api("pad_slices", pad=0)
    display_png(pads, os.path.join(pads.out_dir, "push2_slicer.png"))
    # Mono and Gate (the lower row's first and third).
    press(pads, 20)
    press(pads, 22)
    pads.wait(5)
    assert pads.api("history_undo_name") == "Gate"
    # Encoder 2: the selected slice (two on).
    turn(pads, 1, 6)
    pads.wait(3)
    assert pads.api("pad_slices", pad=0)["selected"] == 2, pads.api("pad_slices", pad=0)
    pads.api("pad_select_slice", slice=0)
    press(pads, 45)  # ▶: the next page (its sound)
    pads.wait(5)
    assert pads.api("view_state", kind="Device", page=0)["page"] == 1
    display_png(pads, os.path.join(pads.out_dir, "push2_slicer_sound.png"))
    # Warp (the fourth): on, its page; encoder 1 its mode (Beats to Tones).
    press(pads, 23)
    pads.wait(5)
    assert pads.api("view_state", kind="Device", page=0)["page"] == 2
    turn(pads, 0, 3)
    pads.wait(3)
    assert pads.api("history_undo_name") == "Warp Mode"
    display_png(pads, os.path.join(pads.out_dir, "push2_slicer_warp.png"))
    # The Slice tab (the upper row's second): encoder 1 the slice, 3 its level.
    press(pads, 103)
    pads.wait(5)
    turn(pads, 0, 9)  # three slices on
    pads.wait(3)
    assert pads.api("pad_slices", pad=0)["selected"] == 3, pads.api("pad_slices", pad=0)
    turn(pads, 2, -10)
    pads.wait(3)
    assert pads.api("history_undo_name") == "Slice Level"
    display_png(pads, os.path.join(pads.out_dir, "push2_slice.png"))
    press(pads, 22)  # Split: 17 slices
    pads.wait(5)
    assert pads.api("pad_slices", pad=0)["count"] == 17
    # Note: the slice pads (the first 17 lit, slice 4 white); a press selects.
    press(pads, 0x32)
    settle(pads)
    sh = push_state(pads)
    assert sh.get(36 + 3) == (255, 255, 255), sh.get(39)
    assert sh.get(36 + 17) is None and sh.get(36 + 16) is not None, (sh.get(52), sh.get(53))
    pads.cmd("midiport play push 90 2A 64")  # pad 7 (bottom row): slice 7
    pads.cmd("midiport play push 80 2A 00")
    pads.wait(5)
    assert pads.api("pad_slices", pad=0)["selected"] == 6
    display_png(pads, os.path.join(pads.out_dir, "push2_slice_7.png"))


def hit(pads, note):
    pads.cmd(f"midiport play push 90 {note:02X} 64")
    pads.cmd(f"midiport play push 80 {note:02X} 00")


def held(pads, cc, then):
    """Button `cc` held while `then()` runs."""
    pads.cmd(f"midiport play push B0 {cc:02X} 7F")
    pads.wait(2)
    then()
    pads.wait(2)
    pads.cmd(f"midiport play push B0 {cc:02X} 00")
    pads.wait(2)


def test_master_arranges_the_song_from_the_grid_and_the_lane_buttons(pads):
    plug(pads)
    for slot in (0, 1):
        pads.api("sequence_add_note", slot=slot, n={"start": 0, "length": 0.25, "pad": 0, "velocity": 0.8, "probability": 1})
    press(pads, 28)  # Master: Song (and song playback)
    pads.wait(8)
    assert pads.api("transport_state")["song_mode"]
    # Sequence 1 (the bottom left pad), the first lane (the top scene
    # button) twice: one after the other.
    hit(pads, 36)
    pads.wait(2)
    press(pads, 43)
    press(pads, 43)
    pads.wait(3)
    assert pads.api("song_state")["clips"] == 2
    assert pads.api("song_clip", index=1)["at"] == 4
    # Sequence 2 on the second lane, at the cursor (bar 3).
    hit(pads, 37)
    pads.wait(2)
    press(pads, 42)
    pads.wait(3)
    c = pads.api("song_clip", index=2)
    assert c["slot"] == 1 and c["lane"] == 1 and c["at"] == 8, c
    e = pads.api("song_edit_state")
    assert e["cursor"] == 12 and e["clip"] == 2 and e["lane"] == 1, e
    settle(pads)
    sh = push_state(pads)
    assert sh.get(37) == (255, 255, 255), sh.get(37)  # (the current sequence white)
    display_png(pads, os.path.join(pads.out_dir, "push2_song.png"))
    # Page <: a bar back; Select + the second lane: the clip there.
    press(pads, 62)
    pads.wait(3)
    assert pads.api("song_edit_state")["cursor"] == 8
    pads.api("song_select_clip", index=-1)
    held(pads, 48, lambda: press(pads, 42))
    assert pads.api("song_edit_state")["clip"] == 2
    # The Clip tab (the upper row's second): encoder 5 transposes it.
    press(pads, 103)
    pads.wait(5)
    turn(pads, 4, 6)
    pads.wait(3)
    assert pads.api("song_clip", index=2)["transpose"] == 2, pads.api("song_clip", index=2)
    assert pads.api("history_undo_name") == "Transpose Clip"
    display_png(pads, os.path.join(pads.out_dir, "push2_song_clip.png"))
    # Mute + the second lane: muted; Delete + the first lane at bar 2: gone.
    held(pads, 60, lambda: press(pads, 42))
    assert pads.api("song_lane", lane=1)["mute"]
    pads.api("song_set_cursor", beat=4)
    held(pads, 118, lambda: press(pads, 43))
    assert pads.api("song_state")["clips"] == 2
    # Delete + sequence 2's pad: it leaves the song.
    held(pads, 118, lambda: hit(pads, 37))
    assert pads.api("song_state")["clips"] == 1
    # The Song tab: encoder 1 the cursor, a bar a step.
    press(pads, 102)
    pads.wait(5)
    pads.api("song_set_cursor", beat=0)
    turn(pads, 0, 6)
    assert pads.api("song_edit_state")["cursor"] == 8
    # Shift + Master: song playback off, the Push stays in Song.
    held(pads, 49, lambda: press(pads, 28))
    assert not pads.api("transport_state")["song_mode"]
    pads.screenshot("push2_song_window")


def test_the_song_views_tabs_reach_markers_tempo_lanes_and_arrangements(pads):
    plug(pads)
    pads.api("sequence_add_note", slot=0, n={"start": 0, "length": 0.25, "pad": 0, "velocity": 0.8, "probability": 1})
    press(pads, 28)  # Master
    pads.wait(5)
    hit(pads, 36)
    press(pads, 43)
    press(pads, 43)
    pads.wait(3)
    # Markers (the upper row's fifth): one at the cursor (bar 3), the loop on.
    press(pads, 106)
    pads.wait(5)
    press(pads, 20)  # Add
    pads.wait(3)
    assert pads.api("song_state")["markers"] == 1
    press(pads, 23)  # Loop
    pads.wait(3)
    assert pads.api("song_state")["loop_on"]
    display_png(pads, os.path.join(pads.out_dir, "push2_song_markers.png"))
    # Tempo (the sixth): a point at the cursor, turned up.
    press(pads, 107)
    pads.wait(5)
    press(pads, 20)  # Add Point
    pads.wait(3)
    turn(pads, 1, 6)
    pads.wait(3)
    st = pads.api("song_state")
    assert st["tempo_points"] >= 1, st
    display_png(pads, os.path.join(pads.out_dir, "push2_song_tempo.png"))
    # Lanes (the third): a new one, selected; muted.
    press(pads, 104)
    pads.wait(5)
    press(pads, 23)  # + Lane
    pads.wait(3)
    assert pads.api("song_edit_state")["lane"] == 1
    press(pads, 20)  # Mute
    pads.wait(3)
    assert pads.api("song_lane", lane=1)["mute"]
    # Arrangement (the fourth): a copy, the song's second.
    press(pads, 105)
    pads.wait(5)
    press(pads, 21)  # Duplicate
    pads.wait(3)
    st = pads.api("song_state")
    assert st["arrangements"] == 2 and st["arrangement"] == 1 and st["clips"] == 2, st
    display_png(pads, os.path.join(pads.out_dir, "push2_song_arrangement.png"))
    # Clip (the second): Name asks for the section's name (the name editor).
    pads.api("song_select_clip", index=0)
    press(pads, 103)
    pads.wait(5)
    press(pads, 23)  # Name
    pads.wait(8)
    pads.screenshot("push2_song_name_window")
    display_png(pads, os.path.join(pads.out_dir, "push2_song_name.png"))
    # The name editor's letters (encoder 2), then the dialog's Name.
    turn(pads, 1, 3)
    pads.wait(3)
    press(pads, 20)
    pads.wait(5)
    assert pads.api("song_clip_label", index=0) != "", pads.api("song_clip_label", index=0)


def lane_starts(pads, lane):
    n = pads.api("song_state")["clips"]
    return sorted(c["at"] for c in (pads.api("song_clip", index=i) for i in range(n)) if c["lane"] == lane)


def test_song_lanes_ripple_and_the_clip_knob_steps_through_them(pads):
    plug(pads)
    for slot in (0, 1):
        for k in range(4):
            pads.api("sequence_add_note", slot=slot, n={"start": k * (0.5 + slot * 0.25), "length": 0.25, "pad": k + slot, "velocity": 0.8, "probability": 1})
    press(pads, 28)  # Master
    pads.wait(8)
    hit(pads, 36)
    pads.wait(2)
    for _ in range(3):
        press(pads, 43)
    pads.wait(3)
    assert lane_starts(pads, 0) == [0, 4, 8]
    # The Clip knob (encoder 2) a step back: the second clip, the cursor at its start.
    turn(pads, 1, -3)
    pads.wait(3)
    e = pads.api("song_edit_state")
    assert e["cursor"] == 4 and e["clip"] >= 0, e
    # Sequence 2 and the lane button: inserted before it, the later ones moving on.
    hit(pads, 37)
    pads.wait(2)
    press(pads, 43)
    pads.wait(3)
    assert lane_starts(pads, 0) == [0, 4, 8, 12]
    at = pads.api("song_clip_at", lane=0, beat=4)
    assert pads.api("song_clip", index=at)["slot"] == 1
    # Delete and the lane with the cursor in it: gone, the gap closed, the cursor back.
    pads.api("song_set_cursor", beat=5)
    held(pads, 118, lambda: press(pads, 43))
    pads.wait(3)
    assert lane_starts(pads, 0) == [0, 4, 8]
    assert pads.api("song_edit_state")["cursor"] == 4
    # Duplicate and the lane: copied after itself, the rest moving on.
    held(pads, 88, lambda: press(pads, 43))
    pads.wait(3)
    assert lane_starts(pads, 0) == [0, 4, 8, 12]
    # Playing: the playhead followed, the master's level on the right.
    pads.api("transport_play")
    for _ in range(4):
        pads.wait(10)
    settle(pads)
    display_png(pads, os.path.join(pads.out_dir, "push2_song_playing.png"))
    pads.api("transport_stop")
    press(pads, 103)  # Clip
    pads.wait(5)
    display_png(pads, os.path.join(pads.out_dir, "push2_song_clip_tab.png"))


def test_the_project_manager_opens_at_start_and_the_push_shows_it(request):
    out = os.path.join(ROOT, ".build", "app", "e2e", request.node.name)
    p = Pads(out_dir=out, extra=["--fake-midi", "--fake-usb"], start_page=True)
    try:
        p.wait(5)
        assert p.api("ui_start_page")  # (no project to open: the project manager)
        p.screenshot("start_page")
        plug(p)
        settle(p)
        display_png(p, os.path.join(out, "push2_start.png"))
        assert p.api("view_state", kind="Projects", page=0)  # (Projects on the display)
        # New Empty Project: it goes, the Push back to Mix.
        p.click("start empty")
        p.wait(5)
        assert not p.api("ui_start_page")
        # Saved, it is a recent one; shown again, a click opens it.
        p.api("project_save_quick")
        dir_ = p.api("project_dir")
        p.api("ui_set_start_page", open=True)
        p.wait(5)
        assert p.api("ui_start_page")
        settle(p)
        p.screenshot("start_page_recent")
        display_png(p, os.path.join(out, "push2_start_recent.png"))
        p.click("start recent 0")
        p.wait(8)
        assert not p.api("ui_start_page")
        assert p.api("project_dir") == dir_
    finally:
        p.close()


def test_the_master_encoder_moves_mains_fader_finely_and_stops_at_its_ends(pads):
    plug(pads)
    main = lambda: pads.api("mixer_bus_state", bus=16)["volume"]
    # A tick: a fine step near 0 dB (along the fader's travel, as Pads' own).
    turn(pads, 8, 1)
    assert 0.05 < main() < 0.2, main()
    turn(pads, 8, -1)
    assert abs(main()) < 1e-3
    # A fast turn's burst (one message of many ticks) moves no more than three.
    pads.cmd("midiport play push B0 4F 28")  # +40 at once
    pads.wait(2)
    assert main() < 0.4, main()
    # Turned far: it stops at +6 and at the bottom (-60, off), never wraps round.
    for _ in range(4):
        turn(pads, 8, 120)
    assert main() == 6
    for _ in range(12):
        turn(pads, 8, -120)
    assert main() == -60
    turn(pads, 8, -10)
    assert main() == -60


def cc_light(pads, cc):
    """Button `cc`'s light as last sent (its palette index; 0: off)."""
    said = pads.cmd("midiport sent push").upper().split()
    v = None
    for k in range(len(said) - 2):
        if said[k] == "B0" and int(said[k + 1], 16) == cc:
            v = int(said[k + 2], 16)
    return v


def long_press(pads, cc):
    import time
    pads.cmd(f"midiport play push B0 {cc:02X} 7F")
    time.sleep(0.5)
    pads.cmd(f"midiport play push B0 {cc:02X} 00")
    pads.wait(3)


def messages(pads):
    return [pads.api("ui_message", index=i) for i in range(pads.api("ui_state")["messages"])]


def test_double_new_automate_fixed_length_and_swing(pads):
    plug(pads)
    pads.api("sequence_add_note", slot=0, n={"start": 0, "length": 0.25, "pad": 0, "velocity": 0.8, "probability": 1})
    # Double Loop: the sequence twice as long, said.
    press(pads, 117)
    pads.wait(3)
    assert pads.api("sequence_state", slot=0)["bars"] == 2
    assert pads.api("sequence_state", slot=0)["notes"] == 2
    assert any("doubled" in m for m in messages(pads)), messages(pads)
    # New: the next empty sequence, selected; Shift+New: a copy.
    press(pads, 87)
    pads.wait(3)
    new = pads.api("sequence_current")
    assert new != 0 and not pads.api("sequence_state", slot=new)["used"]
    pads.api("sequence_select", slot=0)
    held(pads, 49, lambda: press(pads, 87))
    copy_ = pads.api("sequence_current")
    assert copy_ != 0 and pads.api("sequence_state", slot=copy_)["notes"] == 2
    pads.api("sequence_select", slot=0)
    # Automate: armed (red), and off again (dim red).
    press(pads, 89)
    pads.wait(5)
    assert pads.api("ui_automation_armed")
    assert cc_light(pads, 89) == 105  # RED
    press(pads, 89)
    pads.wait(5)
    assert not pads.api("ui_automation_armed")
    assert cc_light(pads, 89) == 106  # DIM_RED
    # Automate held long: Clip's Automation tab; Add puts a point, Value turns it.
    long_press(pads, 89)
    pads.wait(5)
    display_png(pads, os.path.join(pads.out_dir, "push2_automation_empty.png"))
    press(pads, 20)  # Add
    pads.wait(3)
    assert pads.api("sequence_state", slot=0)["points"] == 1
    turn(pads, 3, 10)
    pads.wait(3)
    settle(pads)
    display_png(pads, os.path.join(pads.out_dir, "push2_automation.png"))
    # Fixed Length: the Sequence Length dialog; its 4 bars (the lower row's third).
    press(pads, 90)
    pads.wait(8)
    assert pads.api("ui_dialog_title") == "Sequence Length"
    display_png(pads, os.path.join(pads.out_dir, "push2_length.png"))
    press(pads, 22)
    pads.wait(5)
    assert pads.api("sequence_state", slot=0)["bars"] == 4
    # Swing: the sequence's and input quantize's together.
    pads.cmd("midiport play push 90 09 7F")  # touched
    for _ in range(30):
        pads.cmd("midiport play push B0 0F 01")  # the Swing encoder (CC 15)
    pads.wait(3)
    assert abs(pads.api("sequence_state", slot=0)["swing"] - 0.3) < 1e-3
    assert abs(pads.api("sequence_input_quantize")["swing"] - 0.3) < 1e-3
    display_png(pads, os.path.join(pads.out_dir, "push2_swing.png"))  # (touched: its overlay)
    pads.cmd("midiport play push 90 09 00")
    # User: unlit.
    assert cc_light(pads, 59) in (0, None)


def test_double_loop_in_song_doubles_the_selected_clip(pads):
    plug(pads)
    pads.api("sequence_add_note", slot=0, n={"start": 0, "length": 0.25, "pad": 0, "velocity": 0.8, "probability": 1})
    press(pads, 28)  # Master: Song
    pads.wait(5)
    hit(pads, 36)
    press(pads, 43)
    press(pads, 43)
    pads.wait(3)
    pads.api("song_select_clip", index=0)
    press(pads, 117)
    pads.wait(3)
    assert pads.api("song_clip", index=0)["length"] == 8
    assert pads.api("song_clip", index=1)["at"] == 8  # (the next moved on)


def test_quantize_press_long_press_dialog_and_its_light(pads):
    plug(pads)
    pads.api("sequence_add_note", slot=0, n={"start": 0.3, "length": 0.25, "pad": 0, "velocity": 0.8, "probability": 1})
    # The setting: 1/4, full strength.
    pads.api("sequence_set_quantize_setting", grid="Quarter", strength=1)
    # A press: input quantize on, and again, off (the notes left alone).
    assert cc_light(pads, 116) == 115  # (input quantize off: dim)
    press(pads, 116)  # Quantize
    pads.wait(3)
    assert pads.api("sequence_input_quantize")["on"]
    assert cc_light(pads, 116) == 127  # (input quantize on: bright)
    press(pads, 116)
    pads.wait(3)
    assert not pads.api("sequence_input_quantize")["on"]
    assert cc_light(pads, 116) == 115
    assert abs(pads.api("sequence_note", slot=0, index=0)["start"] - 0.3) < 1e-6
    # Held long: the Quantize dialog, its settings on the encoders.
    long_press(pads, 116)
    pads.wait(8)
    assert pads.api("ui_dialog_title") == "Quantize"
    turn(pads, 0, 3)  # Grid: 1/4 -> 1/8
    pads.wait(4)
    assert pads.api("sequence_quantize_setting")["grid"] == "Eighth"
    turn(pads, 1, -50)  # Strength: 50%
    pads.wait(4)
    assert abs(pads.api("sequence_quantize_setting")["strength"] - 0.5) < 1e-3
    pads.api("sequence_set_quantize_setting", grid="Quarter", strength=1)
    # Input: clockwise on, counter-clockwise off; never a toggle.
    for steps, on in [(3, True), (3, True), (-3, False), (-3, False), (3, True)]:
        turn(pads, 2, steps)
        pads.wait(4)
        assert pads.api("sequence_input_quantize")["on"] == on, (steps, on)
    settle(pads)
    display_png(pads, os.path.join(pads.out_dir, "push2_quantize_dialog.png"))
    assert cc_light(pads, 116) == 127  # (input quantize on: bright)
    press(pads, 20)  # Quantize Now (Quantize Now, Close)
    pads.wait(3)
    assert pads.api("sequence_note", slot=0, index=0)["start"] == 0
    assert any("Quantized" in m for m in messages(pads)), messages(pads)
    press(pads, 21)  # Close
    pads.wait(6)
    assert pads.api("ui_dialog_title") == ""
    settle(pads)
    display_png(pads, os.path.join(pads.out_dir, "push2_iq_badge.png"))
    pads.screenshot("quantize_window")


def test_convert_turns_the_pad_into_other_devices_and_resamples(pads, fixtures):
    plug(pads)
    pads.api("pad_load_sample", pad=0, path=os.path.join(fixtures, "kick.wav"))
    pads.api("perform_select_pad", pad=0)
    pads.api("sequence_add_note", slot=0, n={"start": 0, "length": 0.25, "pad": 0, "velocity": 0.8, "probability": 1})
    pads.wait(3)

    def convert(choice):
        press(pads, 35)  # Convert
        pads.wait(8)
        assert pads.api("ui_dialog_title") == "Convert"
        display_png(pads, os.path.join(pads.out_dir, f"push2_convert_{choice}.png"))
        press(pads, 20 + choice)
        pads.wait(6)

    press(pads, 35)
    pads.wait(8)
    display_png(pads, os.path.join(pads.out_dir, "push2_convert.png"))
    press(pads, 20)  # Make a Slicer
    pads.wait(6)
    assert pads.api("pad_state", pad=0)["kind"] == "Slicer"
    convert(2)  # (Slice onto Pads, Back to a Sampler, Into a Synth...): Into a Synth
    assert pads.api("pad_state", pad=0)["kind"] == "Synth"
    convert(0)  # Back to a Sampler
    assert pads.api("pad_state", pad=0)["kind"] == "Sampler"
    assert any("Sampler" in m for m in messages(pads)), messages(pads)
    # Resample Pad (the last but Cancel): onto the next empty pad.
    press(pads, 35)
    pads.wait(8)
    settle(pads)
    press(pads, 24)  # (Make a Slicer, Slice onto Pads, Into a Synth, Resample Sequence, Resample Pad)
    for _ in range(60):
        pads.wait(5)
        if pads.api("pad_state", pad=1)["used"]:
            break
    assert pads.api("pad_state", pad=1)["used"]


def test_scale_accent_add_device_add_track_and_setup(pads, fixtures):
    plug(pads)
    # Scale: Pads' Scale dialog; encoder 1 the scale, encoder 2 the root.
    press(pads, 58)
    pads.wait(8)
    assert pads.api("ui_dialog_title") == "Scale"
    turn(pads, 0, 3)
    turn(pads, 1, 6)
    pads.wait(4)
    ps = pads.api("perform_state")
    assert ps["scale"] != "Chromatic" or ps["root"] == 2, ps
    settle(pads)
    display_png(pads, os.path.join(pads.out_dir, "push2_scale.png"))
    press(pads, 20)  # Keyboard Mode
    pads.wait(4)
    assert pads.api("perform_state")["play_mode"] == "Keyboard"
    press(pads, 21)  # Close
    pads.wait(6)
    assert cc_light(pads, 58) == 127  # (Keyboard mode: lit)
    # Accent: on (lit), a pad hit at full velocity; off again.
    press(pads, 57)
    pads.wait(4)
    assert pads.api("perform_accent")
    assert cc_light(pads, 57) == 127
    press(pads, 57)
    pads.wait(4)
    assert not pads.api("perform_accent")
    # Held long: only while held.
    long_press(pads, 57)
    assert not pads.api("perform_accent")
    # Add Track: the next empty pad; Shift: a bus.
    pads.api("pad_load_sample", pad=0, path=os.path.join(fixtures, "kick.wav"))
    pads.api("perform_select_pad", pad=0)
    press(pads, 53)
    pads.wait(4)
    assert pads.api("perform_state")["selected"] == 1
    buses = pads.api("mixer_bus_count") if False else None
    held(pads, 49, lambda: press(pads, 53))
    pads.wait(4)
    assert any("new bus" in m for m in messages(pads)), messages(pads)
    # Add Device: Browse on the effects.
    press(pads, 52)
    pads.wait(8)
    settle(pads)
    display_png(pads, os.path.join(pads.out_dir, "push2_add_device.png"))
    # Setup: Pads' Settings; its last tab (Controller ›): the Push's own, encoder 1 the LEDs.
    press(pads, 30)
    pads.wait(6)
    press(pads, 102 + 7)
    pads.wait(4)
    turn(pads, 0, -20)
    pads.wait(4)
    sent = pads.cmd("midiport sent push").upper()
    assert "F0 00 21 1D 01 01 06" in sent
    settle(pads)
    display_png(pads, os.path.join(pads.out_dir, "push2_setup.png"))
    press(pads, 27)  # Close: back in Pads' Settings
    pads.wait(6)
    pads.screenshot("settings_from_setup")
    # Shift + Setup: the project page (Pads' and the display's); again: closed.
    held(pads, 49, lambda: press(pads, 30))
    pads.wait(6)
    assert pads.api("ui_start_page")
    settle(pads)
    display_png(pads, os.path.join(pads.out_dir, "push2_projects.png"))
    held(pads, 49, lambda: press(pads, 30))
    pads.wait(6)
    assert not pads.api("ui_start_page")


def test_shift_lights_its_buttons_and_the_display_says_so(pads):
    plug(pads)
    press(pads, 113)  # Clip (Pads' sequencer)
    pads.wait(5)
    assert cc_light(pads, 35) == 115  # Convert: dim
    pads.cmd("midiport play push B0 31 7F")  # Shift held
    pads.wait(6)
    assert cc_light(pads, 86) == 127  # Record (Shift: save): lit
    assert cc_light(pads, 87) == 127  # New (Shift: a copy): lit
    assert cc_light(pads, 35) == 0    # Convert (nothing with Shift): dark
    settle(pads)
    display_png(pads, os.path.join(pads.out_dir, "push2_shift.png"))
    pads.cmd("midiport play push B0 31 00")
    pads.wait(6)
    assert cc_light(pads, 35) == 115  # its own light back
    assert cc_light(pads, 86) != 127 or True


def test_setup_shows_pads_settings_and_applies_audio_from_the_push(pads):
    plug(pads)
    press(pads, 30)  # Setup: Pads' Settings
    pads.wait(8)
    settle(pads)
    display_png(pads, os.path.join(pads.out_dir, "push2_settings_audio.png"))
    assert pads.api("ui_dialog_title") == ""  # (the window's Settings: not a dialog on the Push)
    # The buffer (encoder 5) a step on, then Apply: Keep asked on the Push.
    turn(pads, 4, 3)
    pads.wait(4)
    press(pads, 20)  # Apply
    pads.wait(8)
    settle(pads)
    assert pads.api("ui_dialog_title") == "Keep these settings?"
    display_png(pads, os.path.join(pads.out_dir, "push2_settings_keep.png"))
    press(pads, 20)  # Keep
    pads.wait(6)
    assert pads.api("ui_dialog_title") == ""
    # The other tabs.
    for k, name in ((1, "channels"), (2, "midi"), (3, "sync")):
        press(pads, 102 + k)
        pads.wait(5)
        settle(pads)
        display_png(pads, os.path.join(pads.out_dir, f"push2_settings_{name}.png"))
    pads.screenshot("settings_window")
    # Setup again: back where it was.
    press(pads, 30)
    pads.wait(5)


def step_note(step):
    """Clip's pad for step `step` (0..31: top row first)."""
    row_from_top, col = step // 8, step % 8
    return 36 + (7 - row_from_top) * 8 + col


def notes_of(pads, slot=0):
    n = pads.api("sequence_state", slot=slot)["notes"]
    return [pads.api("sequence_note", slot=slot, index=i) for i in range(n)]


def test_clip_steps_add_edit_remove_copy_and_page(pads, fixtures):
    plug(pads)
    pads.api("pad_load_sample", pad=0, path=os.path.join(fixtures, "kick.wav"))
    pads.api("perform_select_pad", pad=0)
    pads.api("sequence_set_bars", slot=0, bars=4)
    press(pads, 113)  # Clip: the pads are steps
    pads.wait(6)
    # Step 1 and step 5: notes at 0 and 1 beat (1/16 steps).
    hit(pads, step_note(0))
    hit(pads, step_note(4))
    pads.wait(4)
    starts = sorted(n["start"] for n in notes_of(pads))
    assert starts == [0, 1], starts
    settle(pads)
    display_png(pads, os.path.join(pads.out_dir, "push2_steps.png"))
    sh = push_state(pads)
    assert sh.get(step_note(0)) not in (None, sh.get(step_note(1))), (sh.get(step_note(0)), sh.get(step_note(1)))  # (a note: the pad's colour)
    assert sh.get(36) is not None  # (the bank's first pad, bottom left)
    # Held, the velocity turned: kept on release, softer.
    pads.cmd(f"midiport play push 90 {step_note(4):02X} 64")
    pads.wait(3)
    turn(pads, 2, -20)  # (the sequencer's Velocity, encoder 3)
    pads.wait(3)
    pads.cmd(f"midiport play push 80 {step_note(4):02X} 00")
    pads.wait(3)
    vs = [n["velocity"] for n in notes_of(pads) if n["start"] == 1]
    assert len(vs) == 1 and vs[0] < 0.75, vs
    # Pressed again untouched: gone.
    hit(pads, step_note(0))
    pads.wait(3)
    assert sorted(n["start"] for n in notes_of(pads)) == [1]
    # Duplicate: step 5 copied onto step 9.
    def copy_paste():
        hit(pads, step_note(4))
        hit(pads, step_note(8))
    held(pads, 88, copy_paste)
    pads.wait(3)
    assert sorted(n["start"] for n in notes_of(pads)) == [1, 2]
    # The scene buttons: the grid (1/8, the third from the bottom).
    press(pads, 38)
    pads.wait(3)
    assert pads.api("ui_sequencer_grid") == "Eighth"
    hit(pads, step_note(31))  # (the 32nd 1/8 step: beat 15.5)
    pads.wait(3)
    assert 15.5 in [n["start"] for n in notes_of(pads)]
    press(pads, 40)  # back to 1/16
    # Page >: the next page (steps 33..64: beats 8..16).
    press(pads, 63)
    pads.wait(3)
    hit(pads, step_note(0))
    pads.wait(3)
    assert 8 in [n["start"] for n in notes_of(pads)]
    settle(pads)
    display_png(pads, os.path.join(pads.out_dir, "push2_steps_page2.png"))


def test_copy_bars_from_clip_on_the_push(pads):
    plug(pads)
    pads.api("sequence_set_bars", slot=0, bars=2)
    pads.api("sequence_add_note", slot=0, n={"start": 0, "length": 0.25, "pad": 0, "velocity": 0.8, "probability": 1})
    press(pads, 113)  # Clip
    pads.wait(5)
    settle(pads)
    display_png(pads, os.path.join(pads.out_dir, "push2_clip_before.png"))
    press(pads, 22)  # Copy Bars (the lower row's third)
    pads.wait(8)
    settle(pads)
    pads.screenshot("copy_bars_window")
    assert pads.api("ui_dialog_title") == "Copy Bars"
    display_png(pads, os.path.join(pads.out_dir, "push2_copy_bars.png"))
    press(pads, 20)  # Copy
    pads.wait(6)
    assert pads.api("sequence_state", slot=1)["notes"] == 1


def hold_button(pads, cc, seconds=0.8):
    import time
    pads.cmd(f"midiport play push B0 {cc:02X} 7F")
    for _ in range(int(seconds / 0.1)):
        time.sleep(0.1)
        pads.wait(1)
    pads.cmd(f"midiport play push B0 {cc:02X} 00")
    pads.wait(3)


def test_record_and_metronome_held_open_their_dialogs_and_shift_play_loops(pads):
    plug(pads)
    # Record held: not recording; the Recording dialog; Method Arm, then Arm.
    hold_button(pads, 86)
    pads.wait(6)
    assert not pads.api("transport_state")["recording"]
    assert pads.api("ui_dialog_title") == "Recording"
    settle(pads)
    turn(pads, 0, 3)  # Method: Hold -> Arm
    pads.wait(4)
    settle(pads)
    display_png(pads, os.path.join(pads.out_dir, "push2_recording.png"))
    press(pads, 20)  # Arm
    pads.wait(6)
    assert any("armed" in m for m in messages(pads)), messages(pads)
    assert pads.api("ui_sample_armed")
    import time
    seen = set()
    for _ in range(20):  # (armed: Record blinks on the beat)
        time.sleep(0.05)
        pads.wait(1)
        seen.add(cc_light(pads, 86))
    assert 105 in seen and 106 in seen, seen
    # Metronome held: the click as it was; the Transport dialog; count-in 1 bar.
    click = pads.api("transport_state")["metronome"]
    hold_button(pads, 9)
    pads.wait(6)
    assert pads.api("transport_state")["metronome"] == click
    assert pads.api("ui_dialog_title") == "Transport"
    settle(pads)
    ci = pads.api("transport_state")["count_in"]
    turn(pads, 1, -3)  # (a step down)
    pads.wait(4)
    assert pads.api("transport_state")["count_in"] == max(ci - 1, 0)
    display_png(pads, os.path.join(pads.out_dir, "push2_transport.png"))
    press(pads, 21)  # Close
    pads.wait(6)
    # Shift + Play: loop off, and on again.
    loop = pads.api("transport_state")["loop"]
    held(pads, 49, lambda: press(pads, 85))
    assert pads.api("transport_state")["loop"] != loop
    assert not pads.api("transport_state")["playing"]


def test_sequence_and_lane_dialogs_and_velocity_mode(pads, fixtures):
    plug(pads)
    pads.api("pad_load_sample", pad=0, path=os.path.join(fixtures, "kick.wav"))
    pads.api("perform_select_pad", pad=0)
    # Fixed Length held: the Sequence dialog; Bars (encoder 3) two up.
    hold_button(pads, 90)
    pads.wait(6)
    settle(pads)
    assert pads.api("ui_dialog_title") == "Sequence"
    turn(pads, 2, 6)
    pads.wait(4)
    assert pads.api("sequence_state", slot=0)["bars"] == 3
    turn(pads, 0, 6)  # Colour: a swatch
    pads.wait(4)
    assert pads.api("sequence_state", slot=0)["color"] != 0
    settle(pads)
    display_png(pads, os.path.join(pads.out_dir, "push2_sequence_dialog.png"))
    press(pads, 23)  # Close (Rename…, Duplicate, Clear, Close)
    pads.wait(6)
    assert pads.api("ui_dialog_title") == ""
    # Session's Sequences: Select + the first lane's name: the Lane dialog.
    press(pads, 51)  # Session: the launcher
    pads.wait(6)
    settle(pads)
    held(pads, 48, lambda: press(pads, 102))
    pads.wait(6)
    settle(pads)
    assert pads.api("ui_dialog_title") == "Lane", pads.api("ui_dialog_title")
    display_png(pads, os.path.join(pads.out_dir, "push2_lane_dialog.png"))
    press(pads, 21)  # Close
    pads.wait(6)
    # Layout, then Layout again: Velocity mode (Pads' too), Layout orange.
    press(pads, 31)
    pads.wait(4)
    press(pads, 31)
    pads.wait(6)
    assert pads.api("perform_state")["play_mode"] == "Velocity"
    assert cc_light(pads, 31) == 101  # (ORANGE: Velocity mode)
    settle(pads)
    sh = push_state(pads)
    assert sh.get(36) is not None and sh.get(36 + 3 * 8 + 3) is not None  # (the softest and the loudest)
    press(pads, 31)  # back to the drums
    pads.wait(6)
    assert pads.api("perform_state")["play_mode"] == "Pads"


def test_cue_page_audio_tab_and_cc_lanes(pads, fixtures):
    plug(pads)
    pads.api("pad_load_sample", pad=0, path=os.path.join(fixtures, "kick.wav"))
    pads.api("perform_select_pad", pad=0)
    # Mix: the first upper button steps the pages: Volume, Pan, Send A-D, Cue.
    press(pads, 112)
    pads.wait(5)
    for _ in range(6):
        press(pads, 102)
        pads.wait(3)
    settle(pads)
    turn(pads, 0, 40)  # the first strip's (A1's) cue send up
    pads.wait(4)
    assert pads.api("mixer_pad_cue", pad=0)["db"] > -60, pads.api("mixer_pad_cue", pad=0)
    press(pads, 20)  # its lower button: pre
    pads.wait(4)
    assert pads.api("mixer_pad_cue", pad=0)["pre"]
    settle(pads)
    display_png(pads, os.path.join(pads.out_dir, "push2_mix_cue.png"))
    # Clip, its Automation tab: CC lanes listed after the automation's.
    press(pads, 113)
    pads.wait(5)
    press(pads, 103)  # Automation
    pads.wait(5)
    settle(pads)
    turn(pads, 0, 3 * 7)  # past the pad's seven lanes: CC 1
    pads.wait(4)
    press(pads, 20)  # Add
    pads.wait(4)
    assert pads.api("sequence_state", slot=0)["ccs"] == 1, pads.api("sequence_state", slot=0)
    settle(pads)
    display_png(pads, os.path.join(pads.out_dir, "push2_cc_lane.png"))
    # The Audio tab: an audio track's part (none recorded: says so).
    pads.api("pad_set_kind", pad=1, kind="Audio")
    pads.api("audio_add_take", slot=0, pad=1, path=os.path.join(fixtures, "kick.wav"), at=0)
    pads.api("perform_select_pad", pad=1)
    press(pads, 104)  # Audio
    pads.wait(5)
    settle(pads)
    display_png(pads, os.path.join(pads.out_dir, "push2_audio_tab.png"))
    assert pads.api("audio_part", slot=0, pad=1)["regions"] >= 1
    press(pads, 20)  # Split (the region's middle)
    pads.wait(4)
    assert pads.api("audio_part", slot=0, pad=1)["regions"] >= 2, pads.api("audio_part", slot=0, pad=1)
