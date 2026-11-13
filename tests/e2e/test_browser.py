"""The browser, used as a person uses it: the tree, navigation, favourites,
search, the preview, and dragging samples onto pads."""

import os


def open_library(app, library):
    app.browse(library)
    app.click("Drums", window="browser")
    app.click("Kicks", window="browser")


def test_dragging_a_sample_onto_a_pad_loads_it(app, library):
    # The crash that started this harness: a drag from the browser.
    open_library(app, library)
    app.drag("Kick 808.wav", "pad A1", from_window="browser")
    assert app.pad(0)["name"] == "Kick 808"
    app.drag("Closed Hat.wav", "pad A2", from_window="browser")
    assert app.pad(1)["name"] == "Closed Hat"
    assert app.state()["undo"] == "Load Sample"


def test_dragging_a_search_result_onto_a_pad(app, library):
    app.browse(library)
    app.click("##search", window="browser")
    app.type("loop")
    s = app.until(lambda s: s["browser"]["search_done"] and s["browser"]["results"], what="search results")
    assert s["browser"]["results"] == [os.path.join("Loops", "Loop 120.wav")]
    app.drag(os.path.join("Loops", "Loop 120.wav"), "pad A3", from_window="browser")
    assert app.pad(2)["name"] == "Loop 120"


def test_the_tree_opens_folders_in_place_and_double_click_goes_in(app, library):
    app.browse(library)
    assert app.state()["browser"]["rows"] == ["Drums", "Loops"]
    app.click("Drums", window="browser")
    assert app.state()["browser"]["rows"] == ["Drums", "  Kicks", "  Closed Hat.wav", "Loops"]
    app.click("Drums", window="browser")  # closes
    assert app.state()["browser"]["rows"] == ["Drums", "Loops"]
    app.click("Loops", window="browser", double=True)
    s = app.state()["browser"]
    assert os.path.basename(s["root"]) == "Loops" and s["rows"] == ["Loop 120.wav"]


def test_back_forward_up_and_the_path(app, library):
    app.browse(library)
    app.click("Loops", window="browser", double=True)
    app.click("Up a folder (Backspace)", window="browser")
    assert os.path.basename(app.state()["browser"]["root"]) == "library"
    app.click("Back", window="browser")
    assert os.path.basename(app.state()["browser"]["root"]) == "Loops"
    app.click("Forward", window="browser")
    assert os.path.basename(app.state()["browser"]["root"]) == "library"
    # A part of the path opens that folder.
    app.click("fixtures", window="browser")
    assert os.path.basename(app.state()["browser"]["root"]) == "fixtures"


def test_keyboard_moves_and_previews(app, library):
    open_library(app, library)
    app.click("Kick 808.wav", window="browser")
    s = app.state()["browser"]
    assert s["selected"].endswith("Kick 808.wav") and s["preview"] == s["selected"]  # auto-play played it
    app.key("down")
    assert app.state()["browser"]["selected"].endswith("Closed Hat.wav")
    app.key("down")  # Loops: a folder
    app.key("right")
    assert "  Loop 120.wav" in app.state()["browser"]["rows"]
    app.key("left")
    assert "  Loop 120.wav" not in app.state()["browser"]["rows"]
    app.key("up")
    app.key("enter")  # loads Closed Hat onto the selected pad
    assert app.pad(0)["name"] == "Closed Hat"


def test_preview_buttons(app, library):
    app.browse(library)
    app.click("Loops", window="browser")
    app.click("Auto-play: on (selecting a sample plays it)", window="browser")
    assert not app.state()["browser"]["auto_play"]
    app.click("Loop 120.wav", window="browser")  # two seconds: long enough to stop
    assert not app.state()["browser"]["previewing"]  # auto-play is off
    app.click("Play the selected sample", window="browser")
    assert app.state()["browser"]["previewing"]
    app.expect_item("Stop the preview", window="browser")  # the icon turned to stop
    app.click("Stop the preview", window="browser")
    app.until(lambda s: not s["browser"]["previewing"], what="the preview to stop")
    app.click("Auto-play: off", window="browser")
    assert app.state()["browser"]["auto_play"]


def test_favourites_from_the_star_and_the_tab(app, library):
    app.browse(library)
    app.click("Add this folder to favourites", window="browser")
    s = app.state()["browser"]
    assert s["favorites"] == ["Documents", "Project", "library"]
    app.click("tab Documents", window="browser")
    assert app.state()["browser"]["tab"] == 0
    app.click("tab library", window="browser")
    s = app.state()["browser"]
    assert s["tab"] == 2 and os.path.basename(s["root"]) == "library"
    # Right-click the tab: remove it.
    app.click("tab library", window="browser", right=True)
    app.click("Remove")
    assert app.state()["browser"]["favorites"] == ["Documents", "Project"]


def test_loading_onto_the_selected_or_the_next_empty_pad(app, library, fixtures):
    """Enter (or the foot's first button) loads onto the selected pad;
    Shift+Enter (or the second) onto the next empty one."""
    app.cmd(f"load 0 {os.path.join(fixtures, 'kick.wav')}")
    app.cmd("select 0")
    open_library(app, library)
    app.click("Kick 808.wav", window="browser")
    app.key("shift+enter")  # A1 is used: the next empty is A2
    assert app.pad(1)["name"] == "Kick 808"
    assert app.pad(0)["name"] == "kick"
    app.click("Closed Hat.wav", window="browser")
    app.click("load to the next empty pad", window="browser")
    assert app.pad(2)["name"] == "Closed Hat"
    app.click("Kick 808.wav", window="browser")
    app.click("load to the selected pad", window="browser")
    assert app.pad(0)["name"].startswith("Kick 808"), app.pad(0)["name"]  # replaced on A1, the selected pad (a second copy: "Kick 808 2")
    app.key("cmd+z")
    assert app.pad(0)["name"] == "kick"


def test_the_arrow_keys_keep_the_selection_in_view(app, fixtures, tmp_path):
    # A folder longer than the list: arrowed down to its last file, then
    # back up to its first, the selected row stays on screen (between the
    # Folders section's header and the preview below the list).
    import shutil
    for k in range(60):
        shutil.copy(os.path.join(fixtures, "kick.wav"), tmp_path / f"take {k:02}.wav")
    app.browse(str(tmp_path))
    app.click("take 00.wav")

    def rect(label):
        found = [i["rect"] for i in app.items(label) if i["label"] == label]
        return found[0] if found else None

    def in_view(name):
        r, bottom = rect(name), rect("load to the selected pad")
        assert r is not None, f"{name} not drawn"
        return r[3] <= bottom[1] + 1, (r, bottom)

    for _ in range(59):
        app.key("down")
    app.wait(2)
    assert app.state()["browser"]["selected"].endswith("take 59.wav")
    ok, why = in_view("take 59.wav")
    assert ok, why
    for _ in range(59):
        app.key("up")
    app.wait(2)
    r = rect("take 00.wav")
    assert r is not None, "take 00.wav scrolled back into view"
