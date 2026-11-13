"""The toolbar's Note Repeat: on and off by its button, its rate from its
dropdown (kept with the settings), and Quantize then using that rate."""


def test_note_repeat_from_the_toolbar(app):
    assert not app.state()["repeat_all"]
    app.click("Note Repeat: off (hold a pad to repeat it when on)")
    assert app.state()["repeat_all"]
    app.click("Note repeat settings")
    app.click("repeat rate")
    app.click("1/32")
    app.screenshot("repeat_menu")
    app.key("esc")
    app.expect_item("Note Repeat: on (held pads repeat at its rate; recorded on that grid)")
    app.hover("Quantize", window="sequence")
    app.screenshot("repeat_toolbar")
    app.click("Note Repeat: on (held pads repeat at its rate; recorded on that grid)")
    assert not app.state()["repeat_all"]
