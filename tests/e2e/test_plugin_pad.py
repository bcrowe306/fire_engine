"""A CLAP instrument on a pad: found by a scan, dragged from the Library
onto a pad, played through the mixer, given a lane (one undo
step). Saving its state: tests/pads_model. Needs the test plug-ins
(./scripts/clap.sh); skips without them."""

import os

import pytest

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
CLAP = os.path.join(ROOT, ".build", "clap")


@pytest.fixture
def scanned(app):
    if not os.path.exists(os.path.join(CLAP, "FireTest.clap")):
        pytest.skip("no test plug-ins (./scripts/clap.sh)")
    app.cmd(f"plugin_folder {CLAP}")
    app.cmd("scan_plugins")
    app.until(lambda s: s["plugins"] >= 2, frames=300, what="the scan")
    return app


def test_plugin_instrument_dragged_onto_a_pad(scanned):
    app = scanned
    app.library_find("fire test sine")
    app.wait(3)
    app.drag("device Fire Test Sine", "pad A1", to_window="detail")
    p = app.pad(0)
    assert p["kind"] == "Plugin", p["kind"]
    assert app.state()["undo"] == "Plug-in Instrument"
    app.cmd("select 0")
    app.wait(5)
    app.cmd("expect plugin loaded")
    app.expect_item("change instrument")
    app.expect_item("plugin editor")
    # A note through it.
    app.cmd("note 0 0 4 1")
    app.panel("Mixer")
    app.cmd("play")
    app.wait(30)
    app.cmd("expect level pad 0 above -12")
    app.cmd("stop")
    # Its lane.
    app.cmd("plugin_lane 1 9")
    assert app.state()["undo"] == "Automate Parameter"
    app.key("cmd+z")
    assert app.state()["undo"] != "Automate Parameter"
    app.screenshot("plugin_pad")
