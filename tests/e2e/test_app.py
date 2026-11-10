"""The rest of the window: menus, the command palette, the theme, undo,
panels, the export dialog, saving and opening projects."""

import os


def test_menus_and_undo(app, fixtures):
    app.cmd(f"load 0 {os.path.join(fixtures, 'kick.wav')}")
    app.click("Edit")
    app.click("Undo")
    assert app.state()["pads"] == []
    app.click("Edit")
    app.click("Redo")
    assert app.pad(0)["name"] == "kick"


def test_the_command_palette_switches_the_theme(app):
    assert app.state()["dark"]
    app.key("cmd+k")
    app.type("light theme")
    app.key("enter")
    assert not app.state()["dark"]
    app.click("View")
    app.click("Light Theme")  # the same action switches back
    assert app.state()["dark"]


def test_panels_close_and_reset(app):
    app.panel("Song")
    app.expect_item("Pattern", window="song")
    app.panel("Sequence")
    app.expect_item("Quantize", window="sequence")
    app.click("View")
    app.click("Reset Layout")
    app.expect_item("pad A1", window="detail")


def test_the_export_dialog(app, fixtures):
    app.cmd(f"load 0 {os.path.join(fixtures, 'kick.wav')}")
    app.cmd("note 0 0 0.25 1")
    app.click("File")
    app.click("Export Audio…")
    app.expect_item("Stems: pads")
    app.click("Stems: pads")
    app.click("24-bit")
    app.click("Cancel")
    app.expect_no_item("Stems: pads")


def test_save_open_and_new(app, fixtures, tmp_path):
    app.cmd(f"load 0 {os.path.join(fixtures, 'kick.wav')}")
    app.cmd("note 0 0 0.25 1")
    project = str(tmp_path / "Beat.pads")
    app.cmd(f"save_as {project}")
    assert os.path.exists(os.path.join(project, "project.fire"))
    app.click("File")
    app.click("New Project")
    assert app.state()["pads"] == []
    app.cmd(f"open {project}")
    app.wait(5)
    s = app.state()
    assert s["pads"][0]["name"] == "kick" and s["notes"] == 1
    out = str(tmp_path / "mix.wav")
    app.cmd(f"export {out}")
    app.until(lambda s: not s["exporting"], what="the export")
    assert os.path.getsize(out) > 1000
