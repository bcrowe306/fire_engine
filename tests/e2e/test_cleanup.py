"""File > Clean Up Project by mouse: a file the project doesn't use is
offered (ticked) and goes to the Trash (here the test's own, under its
--prefs); a replaced sample is offered unticked; what plays stays."""

import os


def test_clean_up_moves_unused_files_to_the_trash(app, fixtures):
    app.cmd(f"load 0 {os.path.join(fixtures, 'kick.wav')}")
    project = app.state()["project_dir"]
    stray = os.path.join(project, "Samples", "Recorded", "Recording-7.wav")
    os.makedirs(os.path.dirname(stray), exist_ok=True)
    with open(stray, "wb") as f:
        f.write(b"\0" * 4096)
    app.click("File")
    app.click("Clean Up Project…")
    app.expect_item("clean up 1")
    app.expect_no_item("clean up 2")
    app.screenshot("cleanup")
    app.click("move to trash")
    assert not os.path.exists(stray)
    trash = os.path.join(app.tmp, "prefs", "Trash")
    assert os.listdir(trash) == ["Recording-7.wav"]
    assert os.path.exists(os.path.join(project, "Samples", "Imported", "kick.wav")), "what plays stays"
    app.expect_no_item("clean up 1")
