"""Control surfaces (fire-surface): pretend controllers plugged into pretend
MIDI ports (--fake-midi), the kit's example surfaces (--surface) found and
started, Settings > Control Surfaces, and a surface's virtual controller
played with the mouse."""

import os
import subprocess

import pytest

from pads import ROOT, Pads

FSURF = os.path.join(ROOT, "extern", "fire-surface")
BUILT = os.path.join(FSURF, ".build")
GRID = os.path.join(BUILT, "grid_odin.fsurf")
SCREEN = os.path.join(BUILT, "screen_odin.fsurf")
IDENTITY = "F0 7E 00 06 02 7D 20 01 F7"  # the Grid's answer to "who are you?"


@pytest.fixture(scope="module")
def surfaces():
    """The kit's examples, built in the submodule (once)."""
    if not (os.path.exists(GRID) and os.path.exists(SCREEN)):
        subprocess.run([os.path.join(FSURF, "scripts", "build.sh")], cwd=FSURF, check=True, capture_output=True)
    return ["--fake-midi", "--surface", GRID, "--surface", SCREEN]


@pytest.fixture
def pads(request, surfaces):
    out = os.path.join(ROOT, ".build", "app", "e2e", request.node.name)
    p = Pads(out_dir=out, extra=surfaces)
    yield p
    p.close()


def plug_grid(pads):
    pads.cmd("midiport plug grid inout Grid MIDI")
    pads.wait(3)
    pads.cmd(f"midiport play grid {IDENTITY}")
    pads.wait(3)


def test_a_controller_is_found_started_and_lost(pads):
    assert pads.api("surface_count") == 0
    plug_grid(pads)
    assert pads.api("surface_count") == 1
    assert pads.api("surface_name", index=0) == "Grid (kit example)"
    assert pads.api("surface_state", index=0) == "Active"
    assert pads.api("surface_ports", index=0) == "Grid MIDI"
    # Its hello, and its lights, went out to it.
    pads.cmd("midiport sent grid")
    # Unplugged: it waits; back, it's asked again and starts.
    pads.cmd("midiport unplug grid")
    pads.wait(3)
    assert pads.api("surface_state", index=0) == "Gone"
    plug_grid(pads)
    assert pads.api("surface_state", index=0) == "Active"


def test_its_pads_play_and_its_buttons_are_its_own(pads):
    plug_grid(pads)
    pads.api("surface_monitor", on=True)
    pads.cmd("midiport play grid 99 24 64")  # a pad: drum 36, through to Pads
    pads.cmd("midiport play grid B0 55 7F")  # Play: the surface's
    pads.wait(4)
    lines = [pads.api("surface_monitor_line", i=i) for i in range(pads.api("surface_monitor_count"))]
    assert any("remap" in l and "Pads 3,0 (Drum)" in l for l in lines), lines
    assert any("claim" in l and "Play (Transport)" in l for l in lines), lines
    assert pads.api("transport_state")["playing"]


def test_settings_show_it_and_its_virtual_controller_plays(pads):
    plug_grid(pads)
    pads.key("cmd+,")
    pads.click("Control Surfaces", window="settings")
    pads.expect_item("Stop surface 0")
    pads.click("Show surface 0")
    pads.expect_item("Virtual Play")
    pads.click("Virtual Play")
    pads.wait(4)
    assert pads.api("transport_state")["playing"]
    pads.screenshot("surfaces_page")
    # Stopped from the page: detection off for it (kept); on again.
    pads.click("Stop surface 0")
    pads.wait(2)
    assert pads.api("surface_count") == 0
    pads.api("surface_set_detect", lib=0, k=0, on=True)
    pads.wait(2)
    assert pads.api("surface_count") == 1
