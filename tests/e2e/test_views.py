"""Pads' views for controllers' displays (fire.pads view_frame): a view
asked for is drawn offscreen with Pads' widgets after the window's frame;
the script command `view` asks and saves its newest frame as a PNG."""

import os
import struct
import zlib

import pytest

from pads import ROOT, Pads


@pytest.fixture
def pads(request):
    out = os.path.join(ROOT, ".build", "app", "e2e", request.node.name)
    p = Pads(out_dir=out)
    yield p
    p.close()


def png_pixels(path):
    """RGBA rows of a PNG Pads wrote (8-bit RGBA, filter 0)."""
    data = open(path, "rb").read()
    w, h = struct.unpack(">II", data[16:24])
    idat, at = b"", 8
    while at < len(data):
        n = struct.unpack(">I", data[at:at + 4])[0]
        kind = data[at + 4:at + 8]
        if kind == b"IDAT":
            idat += data[at + 8:at + 8 + n]
        at += 12 + n
    raw = zlib.decompress(idat)
    return w, h, [raw[y * (w * 4 + 1) + 1:(y + 1) * (w * 4 + 1)] for y in range(h)]


@pytest.mark.parametrize("page", [0, 1, 2, 3, 4, 5, 6])
def test_the_device_view_is_drawn_for_a_display(pads, page):
    pads.cmd(f"view device {page} 960 160")  # asked for: drawn from the next frame
    path = os.path.join(pads.out_dir, f"device_{page}.png")
    for _ in range(20):  # (read back a frame or more later: longer when the machine is busy)
        pads.wait(4)
        said = pads.cmd(f"view device {page} 960 160 {path}")
        if said.startswith("frame ") and int(said.split()[1]) > 0:
            break
    assert said.startswith("frame ") and int(said.split()[1]) > 0, said
    w, h, rows = png_pixels(path)
    assert (w, h) == (960, 160)
    # Not one colour: the plot drawn.
    colours = {bytes(r[x * 4:x * 4 + 3]) for r in rows[::8] for x in range(0, w, 8)}
    assert len(colours) > 8, len(colours)


def test_a_view_no_longer_asked_for_is_let_go(pads):
    pads.cmd("view mixer 0 320 80")
    pads.wait(4)
    assert pads.cmd("view mixer 0 320 80").startswith("frame ")
