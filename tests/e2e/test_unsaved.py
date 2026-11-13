"""A new project lives in Pads' unsaved folder (here, under the test's own
--prefs), not the system's temporary one: its files survive Pads
stopping. Saving moves the folder where it is saved (its recordings
with it); leaving it without saving removes it."""

import os


def unsaved(app):
    return os.path.join(app.tmp, "prefs", "Unsaved")


def test_a_new_project_is_in_the_unsaved_folder_and_moves_when_saved(app, fixtures, tmp_path):
    s = app.state()
    assert s["untitled"]
    assert os.path.dirname(s["project_dir"]) == unsaved(app), s["project_dir"]
    assert os.path.basename(s["project_dir"]) == "Untitled.pads"
    app.cmd(f"load 0 {os.path.join(fixtures, 'kick.wav')}")
    first = s["project_dir"]
    kick = os.path.join(first, "Samples", "Imported", "kick.wav")
    assert os.path.exists(kick)
    project = str(tmp_path / "Beat.pads")
    app.cmd(f"save_as {project}")
    s = app.state()
    assert not s["untitled"] and s["project_dir"] == project
    assert not os.path.exists(first), "moved, not copied"
    assert os.path.exists(os.path.join(project, "Samples", "Imported", "kick.wav"))
    assert os.path.exists(os.path.join(project, "project.fire"))


def test_a_project_left_without_saving_is_removed(app, fixtures):
    first = app.state()["project_dir"]
    app.cmd(f"load 0 {os.path.join(fixtures, 'kick.wav')}")
    app.click("File")
    app.click("New Project")  # (a script doesn't ask: Don't Save)
    s = app.state()
    assert s["untitled"] and s["pads"] == []
    assert not os.path.exists(first) or s["project_dir"] == first and not os.path.exists(os.path.join(first, "Samples")), "the one left gone"
    assert os.listdir(unsaved(app)) == [os.path.basename(s["project_dir"])]
    # Quitting from the menu: the open one goes too, once Pads has stopped.
    app.click("File")
    try:
        app.click("Quit")
    except Exception:  # (Pads gone before the click's frames were waited for)
        pass
    assert app.proc.wait(timeout=15) == 0
    assert os.listdir(unsaved(app)) == []
