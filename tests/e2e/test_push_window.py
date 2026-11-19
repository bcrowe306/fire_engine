"""Push 2 on Screen (View > Push 2 on Screen, --virtual-push2): with no
Push 2 plugged in, Pads starts its own on a port no device uses, drawn in
a window and played with the mouse: its buttons reach the surface as the
device's MIDI (Play plays, Browse shows Pads' browser on its display), a
right-click holds a button, the tempo encoder dragged changes the tempo,
a pad played; closing the window stops it, opening it starts it again."""

import os

import pytest

from pads import ROOT, Pads


@pytest.fixture
def pads(request):
    out = os.path.join(ROOT, ".build", "app", "e2e", request.node.name)
    p = Pads(out_dir=out, extra=["--virtual-push2"], size=None)
    p.cmd("size 1500 1000")
    yield p
    p.close()


def push2(pads):
    """The surfaces running ("0 Push 2: Active on Virtual"...)."""
    return pads.cmd("surface list")


def wait_for(pads, test, frames=120):
    for _ in range(frames // 5):
        if test():
            return True
        pads.wait(5)
    return test()


def test_push_2_on_screen_starts_with_no_controller_and_plays(pads):
    assert wait_for(pads, lambda: "Push 2: Active on Virtual" in push2(pads))
    pads.cmd('expect_item "Push2 Play"')
    pads.cmd("surface monitor on")
    # Play: the transport plays; Stop stops it.
    pads.cmd('click_item "Push2 Play"')
    assert wait_for(pads, lambda: pads.api("transport_state")["playing"])
    pads.cmd('click_item "Push2 Stop"')
    assert wait_for(pads, lambda: not pads.api("transport_state")["playing"])
    # Browse: Pads' browser on its display (a picture of the window).
    pads.cmd('click_item "Push2 Browse"')
    pads.wait(30)
    shot = pads.screenshot("push_window_browse")
    assert os.path.getsize(shot) > 0
    # The tempo encoder dragged up: faster (touched while dragged).
    before = pads.api("transport_state")["bpm"]
    pads.cmd('drag_by "Push2 Tempo Encoder" 0 -60')
    assert wait_for(pads, lambda: pads.api("transport_state")["bpm"] > before)
    # A pad played (the bottom left: note 36), and what reached the surface.
    pads.cmd('click_item "Push2 Pads 7,0"')
    pads.wait(5)
    said = pads.cmd("surface monitor show")
    assert "in  200  90 24" in said and "in  200  80 24" in said  # (pressed and let go)
    assert "in  200  90 0A 7F" in said and "in  200  90 0A 00" in said  # (the tempo encoder touched, let go)


def incoming(pads):
    """What reached the surface (the monitor's "in" lines; "out": its lights)."""
    return "\n".join(l for l in pads.cmd("surface monitor show").splitlines() if l.startswith("in "))


def test_a_right_click_holds_a_button_until_clicked_again(pads):
    assert wait_for(pads, lambda: "Push 2: Active on Virtual" in push2(pads))
    pads.cmd("surface monitor on")
    pads.cmd('click_item "Push2 Shift" right')
    pads.wait(5)
    said = incoming(pads)
    assert "B0 31 7F" in said and "B0 31 00" not in said  # (Shift held)
    pads.cmd('click_item "Push2 Shift"')
    pads.wait(5)
    said = incoming(pads)
    assert "B0 31 00" in said and said.count("B0 31 7F") == 1  # (let go: nothing pressed)


def test_its_lights_are_what_the_surface_sends(pads):
    assert wait_for(pads, lambda: "Push 2: Active on Virtual" in push2(pads))
    pads.cmd("surface monitor on")
    pads.cmd('click_item "Push2 Play"')
    pads.wait(10)
    out = [l for l in pads.cmd("surface monitor show").splitlines() if l.startswith("out 200")]
    assert any("B0 55" in l for l in out)  # (Play's light, on the window's port)
    pads.cmd('click_item "Push2 Stop"')


def test_fill_and_full_screen_and_esc_back_to_a_window(pads):
    assert wait_for(pads, lambda: "Push 2: Active on Virtual" in push2(pads))
    pads.cmd('click_item "push window fill"')  # Fill: Pads' window
    pads.wait(5)
    pads.cmd('click_item "Push2 Play"')  # (still played)
    assert wait_for(pads, lambda: pads.api("transport_state")["playing"])
    pads.cmd('click_item "push window full screen"')  # over the whole screen
    pads.wait(10)
    pads.cmd("key esc")  # back to a window
    pads.wait(10)
    pads.cmd('click_item "Push2 Stop"')
    assert wait_for(pads, lambda: not pads.api("transport_state")["playing"])
    assert "Push 2: Active on Virtual" in push2(pads)


def test_closing_the_window_stops_it_and_opening_starts_it(pads):
    assert wait_for(pads, lambda: "Push 2: Active on Virtual" in push2(pads))
    pads.cmd("action push_window")
    assert wait_for(pads, lambda: "Push 2" not in push2(pads))
    pads.cmd('expect_no_item "Push2 Play"')
    pads.cmd("action push_window")
    assert wait_for(pads, lambda: "Push 2: Active on Virtual" in push2(pads))
    pads.cmd('expect_item "Push2 Play"')
