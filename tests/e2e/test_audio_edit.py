"""Audio clips by mouse, in the Sequence view's Audio tab: a take on audio
track A2 (its row in the Notes grid shows it), a click placing the cursor
and selecting the region, Split there, a Shift-dragged range deleted (and
undone), a region dragged later, its fade-in handle dragged, Copy and
Paste, Normalize and Reverse, Consolidate; the region's gain typed."""

import os


def take(app, fixtures):
    app.cmd(f"take 1 {os.path.join(fixtures, 'loop.wav')}")
    assert app.state()["undo"] == "Add Take"
    p = app.pad(1)
    assert p["kind"] == "Audio" and p["takes"] == 1 and p["regions"] == 1, p
    app.cmd("lane audio")
    app.wait(3)
    assert app.state()["seq_mode"] == "Audio"


def audio(app):
    return app.state()["audio"]


def test_split_delete_move_fade(app, fixtures):
    take(app, fixtures)
    app.click("audio editor", at=(0.5, 0.6))
    a = audio(app)
    assert a["region"] == 0 and abs(a["cursor"] - 2) < 0.01, a
    app.click("audio split")
    assert app.pad(1)["regions"] == 2
    assert app.state()["undo"] == "Split"
    # A range, Shift-dragged across beat 1..1.5, deleted.
    app.cmd("hold shift")
    app.drag_at("audio editor", (0.25, 0.6), (0.375, 0.6))
    app.cmd("let shift")
    a = audio(app)
    assert abs(a["range"][0] - 1) < 0.01 and abs(a["range"][1] - 1.5) < 0.01, a
    app.click("audio delete")
    assert app.state()["undo"] == "Delete"
    assert app.pad(1)["regions"] == 3, app.pad(1)["regions"]
    app.key("cmd+z")
    assert app.pad(1)["regions"] == 2
    # The first half dragged half a beat later (over the second): beat
    # 0..0.5 is empty, so a click there selects nothing.
    app.drag_at("audio editor", (0.25, 0.7), (0.375, 0.7))
    assert app.state()["undo"] == "Move Region"
    app.click("audio editor", at=(0.06, 0.7))
    assert audio(app)["region"] == -1, audio(app)
    app.click("audio editor", at=(0.2, 0.7))
    assert audio(app)["region"] >= 0
    # The moved region's fade-in handle (its top-left corner, at beat 0.5) dragged in.
    app.drag_at("audio editor", (0.126, 0.08), (0.2, 0.08))
    assert app.state()["undo"] == "Fade In", app.state()["undo"]
    app.screenshot("audio_edited")


def test_copy_paste_normalize_reverse_consolidate(app, fixtures):
    take(app, fixtures)
    app.click("audio editor", at=(0.25, 0.6))  # the region; the cursor at beat 1
    app.click("audio copy")
    assert audio(app)["has_clip"]
    app.click("audio editor", at=(0.5, 0.6))  # the cursor at beat 2
    app.click("audio paste")
    assert app.state()["undo"] == "Paste"
    app.click("audio editor", at=(0.1, 0.6))
    region = audio(app)["region"]
    assert region >= 0
    app.click("audio normalize")
    assert app.state()["undo"] == "Normalize"
    app.click("audio reverse")
    assert app.state()["undo"] == "Reverse"
    app.click("audio consolidate")
    assert app.state()["undo"] == "Consolidate"
    p = app.pad(1)
    assert p["regions"] == 1 and p["takes"] == 2, p
    app.screenshot("audio_consolidated")


def test_a_region_s_gain_and_the_takes_menu(app, fixtures):
    take(app, fixtures)
    app.click("audio editor", at=(0.5, 0.6))
    app.click("region gain", double=True)
    app.type("-6")
    app.key("enter")
    app.until(lambda s: s["undo"] == "Region", what="the gain typed")
    app.click("audio takes")
    app.click("Take 1 · loop · from beat 1.00")
    assert app.state()["undo"] == "Use Take"


def test_the_keys(app, fixtures):
    take(app, fixtures)
    app.click("audio editor", at=(0.25, 0.6))  # the region; the cursor at beat 1
    app.key("cmd+c")
    assert audio(app)["has_clip"]
    app.click("audio editor", at=(0.5, 0.6))
    app.key("cmd+t")  # split at the cursor
    assert app.state()["undo"] == "Split"
    app.key("cmd+v")
    assert app.state()["undo"] == "Paste"


def test_zero_mutes_a_region_or_the_clip(app, fixtures):
    # 0, as for notes: the selected region muted (and back); with none
    # chosen, the whole clip; one undo step each.
    take(app, fixtures)
    app.click("audio editor", at=(0.5, 0.6))
    app.click("audio split")
    assert app.pad(1)["regions"] == 2
    app.click("audio editor", at=(0.75, 0.6))  # the second region
    app.key("0")
    assert app.pad(1)["muted_regions"] == 1 and app.state()["undo"] == "Mute", (app.pad(1), app.state()["undo"])
    app.key("0")
    assert app.pad(1)["muted_regions"] == 0
    app.key("esc")  # nothing chosen: the whole clip
    app.key("0")
    assert app.pad(1)["muted_regions"] == 2
    app.key("cmd+z")
    assert app.pad(1)["muted_regions"] == 0
