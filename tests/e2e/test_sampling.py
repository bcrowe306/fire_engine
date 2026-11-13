"""Recording a sample into a pad from the pad: Option-press records while
held (Hold); the toolbar's Sample control armed, the next pad pressed
records by its method (Arm here), and it disarms. (The simulated device's
input is silent: what is checked is that the take lands on the pad.)"""


def has_sample(app, index):
    return lambda s: any(p["index"] == index for p in s["pads"])


def test_option_press_records_into_the_pad(app):
    app.cmd("hold alt")
    app.drag_by("pad A3", 0, 0, window="detail", steps=40)  # held 40 frames
    app.cmd("let alt")
    app.until(has_sample(app, 2), what="a sample on A3")
    assert app.state()["selected"] == 2
    assert app.state()["undo"] == "Record"


def test_the_sample_control_arms_the_next_press(app):
    s = app.state()
    assert s["sample_method"] == "Hold" and not s["sample_armed"]
    app.click("Sample settings")
    app.click("Arm")
    app.key("esc")
    assert app.state()["sample_method"] == "Arm"
    app.click("Sample: on, the next pad you press records while you hold it")
    assert app.state()["sample_armed"]
    app.drag_by("pad A4", 0, 0, window="detail", steps=40)  # pressed: it records, not plays
    app.until(has_sample(app, 3), what="a sample on A4")
    assert not app.state()["sample_armed"]  # once
