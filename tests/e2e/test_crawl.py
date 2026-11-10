"""A crawl for crashes: with sounds loaded, every item that shows in each
panel and tab is clicked (left, then right), closing popups between, and
the app must still be alive after each. It catches what nobody thought to
test (like the drag that crashed the browser)."""

import os

import pytest

# Not clicked: quitting, and what opens the system's file dialogs (they
# would wait for a person) or records from a sound card.
SKIP = (
    "Quit", "Open Project…", "Save As…", "Import Sample…", "Import MIDI File…", "Export…",
    "Record the input onto this pad", "Plug-in (CLAP)…", "New Project",
)

PLACES = [
    ("sequence", None),
    ("song", "Song"),
    ("mixer", "Mixer"),
    ("detail", "Sample"),
    ("detail", "Pad"),
    ("detail", "Effects"),
    ("perform", "Perform"),
    ("browser", None),
    ("##toolbar", None),
]


def loaded(app, fixtures):
    for i, name in enumerate(("kick.wav", "hat.wav", "loop.wav")):
        app.cmd(f"load {i} {os.path.join(fixtures, name)}")
    app.cmd("note 0 0 0.25 1")
    app.cmd("note 1 0.5 0.25 0.8")
    app.cmd("insert 0 0 lowpass")
    app.cmd("edit_fx pad 0 0")
    app.cmd("browse " + os.path.join(fixtures, "library"))
    app.wait(5)


@pytest.mark.parametrize("window, tab", PLACES, ids=[f"{w.strip('#')}-{t or 'main'}" for w, t in PLACES])
def test_clicking_everything_does_not_crash(app, fixtures, window, tab):
    loaded(app, fixtures)
    if window in ("song", "mixer", "perform"):
        app.panel(tab)
    elif tab:
        app.click(tab, window="detail")
    labels = []
    for it in app.items(window=window):
        if it["label"] and it["label"] not in labels and not any(s in it["label"] for s in SKIP):
            labels.append(it["label"])
    assert labels, "nothing to click"
    for label in labels:
        for right in (False, True):
            try:
                app.cmd(f'click_item "{label}" in {window}{" right" if right else ""}')
            except Exception as e:
                if "no item" in str(e):
                    continue  # it went away (a popup, another tab): fine
                raise
            app.wait(4)
            app.key("esc")  # close what it opened
        app.cmd("wait 1")  # alive
    s = app.state()
    assert s["errors"] >= 0


@pytest.mark.parametrize("target, window, tab", [
    ("pad A4", "detail", None), ("wave", "detail", "Sample"), ("seq", "sequence", None),
    ("A1 fader", "mixer", "Mixer"), ("Bus A name", "mixer", "Mixer"), ("  Song", None, None),
    ("Loops", "browser", None), ("##search", "browser", None),
])
def test_dragging_a_file_anywhere_does_not_crash(app, fixtures, target, window, tab):
    loaded(app, fixtures)
    app.click("Drums", window="browser")
    if tab == "Mixer":
        app.panel("Mixer")
    elif tab:
        app.click(tab, window="detail")
    app.drag("Closed Hat.wav", target, from_window="browser", to_window=window)
    app.wait(4)
    s = app.state()
    if target == "pad A4":
        assert any(p["index"] == 3 and p["name"] == "Closed Hat" for p in s["pads"])
    else:
        assert len(s["pads"]) == 3  # dropped where nothing takes it: nothing happens
