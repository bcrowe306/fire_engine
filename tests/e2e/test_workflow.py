"""Pads' everyday flow: the project page (File > Projects: Save, Rename, All
Projects searched, Duplicate, Move to Trash, New Empty), a pad's device
remembered when you come back to it, the Library's effect presets folded
under their effect, a device's presets from its own header."""

import os

import pytest


def test_the_project_page_manages_projects(app):
    app.api("project_save_quick")  # (into the projects folder: the test's own, in temp)
    app.wait(2)
    app.api("ui_set_start_page", open=True)
    app.wait(3)
    app.expect_item("start save")
    app.screenshot("projects_page")
    # Duplicate a project from the projects folder's list (the open one is in it if saved there).
    rows = [i for i in app.items("start project ") if i["label"].endswith(" duplicate")]
    if not rows:
        pytest.skip("no project in the projects folder to duplicate here")
    name = rows[0]["label"][len("start project "):-len(" duplicate")]
    app.click(rows[0]["label"])
    app.wait(2)
    app.click("Duplicate")
    app.wait(3)
    dup = name + " copy"
    app.expect_item(f"start project {dup}")
    # Search narrows the list.
    app.click("start search")
    app.type(dup)
    app.wait(2)
    labels = [i["label"] for i in app.items("start project ") if not i["label"].endswith((" duplicate", " trash"))]
    assert all(dup in l for l in labels), labels
    # Move the copy to the Trash.
    app.click(f"start project {dup} trash")
    app.wait(2)
    app.click("Move to Trash")
    app.wait(3)
    app.expect_no_item(f"start project {dup}")
    # New Empty Project: a new one, the page closed.
    app.click("start empty")
    app.wait(3)
    assert not app.api("ui_start_page")


def test_a_pad_remembers_its_device(app, fixtures):
    app.cmd(f"load 0 {os.path.join(fixtures, 'loop.wav')}")
    app.cmd(f"load 1 {os.path.join(fixtures, 'loop.wav')}")
    app.cmd("select 0")
    app.cmd("insert 0 0 procomp")
    app.cmd("edit_fx pad 0 0")
    app.wait(3)
    assert app.state()["device"] == "Slot"
    app.cmd("select 1")
    app.wait(3)
    assert app.state()["device"] == "Instrument"  # (pad 1's first time: its sound)
    app.cmd("select 0")
    app.wait(3)
    st = app.state()
    assert st["device"] == "Slot" and st["device_slot"] == 0, st


def test_effect_presets_fold_and_load_from_the_device(app, fixtures):
    app.cmd(f"load 0 {os.path.join(fixtures, 'loop.wav')}")
    app.cmd("select 0")
    app.wait(2)
    app.click("category Effects", window="browser")
    app.reveal("device ProVerb", "browser", over="device SuperFilter", tries=60)
    app.expect_no_item("device Grand Hall", window="browser")  # (folded)
    app.click("device ProVerb", window="browser")
    app.reveal("device Grand Hall", "browser", over="device ProVerb", tries=60)
    app.click("device ProVerb", window="browser")
    app.expect_no_item("device Grand Hall", window="browser")  # (folded again)
    # The device's own Presets, on its header.
    app.cmd("insert 0 0 proverb")
    app.cmd("edit_fx pad 0 0")
    app.wait(3)
    app.click("fx presets", window="detail")
    app.click("fx preset folder Halls")  # (ProVerb's by category)
    app.click("fx preset Grand Hall")
    app.wait(2)
    slot = {"place": "Insert", "index": 0, "slot": 0}
    assert app.api("effect_get_param", s=slot, id=20) == 9  # (its mode: Grand Hall)
    assert app.api("history_undo_name") == "Load Preset"
    app.screenshot("device_presets")
