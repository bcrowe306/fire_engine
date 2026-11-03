#!/usr/bin/env python3
"""Render a diagnostic PNG for a failed audio comparison. Standard library only.

    python3 scripts/plot.py .test_artifacts/<name>

Reads expected.wav / actual.wav / diff.wav (whichever exist) from the directory and
writes plot.png with three panels:
  1. waveform: expected (blue) vs actual (orange), channel 0
  2. difference (red), auto-scaled, with its peak marked
  3. magnitude spectrum in dB (log frequency) of expected vs actual
"""
import math
import os
import struct
import sys
import zlib

W, H = 1200, 900
PANEL_H = 280
MARGIN = 40
BG = (255, 255, 255)
GRID = (225, 225, 225)
AXIS = (120, 120, 120)
BLUE = (31, 119, 180)
ORANGE = (255, 127, 14)
RED = (214, 39, 40)


def read_wav(path):
    with open(path, "rb") as f:
        data = f.read()
    if data[:4] != b"RIFF" or data[8:12] != b"WAVE":
        raise ValueError(f"{path}: not RIFF/WAVE")
    pos, fmt, pcm = 12, None, None
    while pos + 8 <= len(data):
        cid, size = data[pos:pos + 4], struct.unpack_from("<I", data, pos + 4)[0]
        body = data[pos + 8:pos + 8 + size]
        if cid == b"fmt ":
            fmt = struct.unpack_from("<HHIIHH", body)
        elif cid == b"data":
            pcm = body
        pos += 8 + size + (size & 1)
    tag, channels, rate, _, _, bits = fmt
    if tag == 3 and bits == 32:
        samples = struct.unpack(f"<{len(pcm) // 4}f", pcm)
    elif tag == 1 and bits == 16:
        samples = [s / 32768 for s in struct.unpack(f"<{len(pcm) // 2}h", pcm)]
    else:
        raise ValueError(f"{path}: unsupported format tag={tag} bits={bits}")
    return [list(samples[c::channels]) for c in range(channels)], rate


class Canvas:
    def __init__(self, w, h):
        self.w, self.h = w, h
        self.px = bytearray(BG * (w * h))

    def set(self, x, y, c):
        if 0 <= x < self.w and 0 <= y < self.h:
            i = (y * self.w + x) * 3
            self.px[i:i + 3] = bytes(c)

    def line(self, x0, y0, x1, y1, c):
        x0, y0, x1, y1 = int(x0), int(y0), int(x1), int(y1)
        dx, dy = abs(x1 - x0), -abs(y1 - y0)
        sx, sy = (1 if x0 < x1 else -1), (1 if y0 < y1 else -1)
        err = dx + dy
        while True:
            self.set(x0, y0, c)
            if x0 == x1 and y0 == y1:
                return
            e2 = 2 * err
            if e2 >= dy:
                err += dy
                x0 += sx
            if e2 <= dx:
                err += dx
                y0 += sy

    def rect(self, x0, y0, x1, y1, c):
        for x in range(x0, x1 + 1):
            self.set(x, y0, c)
            self.set(x, y1, c)
        for y in range(y0, y1 + 1):
            self.set(x0, y, c)
            self.set(x1, y, c)

    def png(self, path):
        raw = b"".join(b"\x00" + bytes(self.px[y * self.w * 3:(y + 1) * self.w * 3]) for y in range(self.h))

        def chunk(t, d):
            return struct.pack(">I", len(d)) + t + d + struct.pack(">I", zlib.crc32(t + d) & 0xFFFFFFFF)

        with open(path, "wb") as f:
            f.write(b"\x89PNG\r\n\x1a\n")
            f.write(chunk(b"IHDR", struct.pack(">IIBBBBB", self.w, self.h, 8, 2, 0, 0, 0)))
            f.write(chunk(b"IDAT", zlib.compress(raw, 6)))
            f.write(chunk(b"IEND", b""))


def plot_series(cv, top, series, lo, hi, color):
    """Min/max envelope per pixel column so long signals stay readable."""
    x0, x1 = MARGIN, W - MARGIN
    y0, y1 = top, top + PANEL_H
    n = len(series)
    if n == 0 or hi <= lo:
        return
    to_y = lambda v: y1 - (v - lo) / (hi - lo) * (y1 - y0)
    cols = x1 - x0
    prev = None
    for col in range(cols):
        a = col * n // cols
        b = max(a + 1, (col + 1) * n // cols)
        seg = series[a:b]
        ymin, ymax = to_y(max(seg)), to_y(min(seg))
        cv.line(x0 + col, ymin, x0 + col, ymax, color)
        mid = (ymin + ymax) / 2
        if prev is not None:
            cv.line(x0 + col - 1, prev, x0 + col, mid, color)
        prev = mid


def frame(cv, top, zero=None):
    cv.rect(MARGIN, top, W - MARGIN, top + PANEL_H, AXIS)
    for i in range(1, 10):
        x = MARGIN + i * (W - 2 * MARGIN) // 10
        cv.line(x, top + 1, x, top + PANEL_H - 1, GRID)
    if zero is not None:
        cv.line(MARGIN + 1, zero, W - MARGIN - 1, zero, GRID)


def fft(x):
    n = len(x)
    if n == 1:
        return x
    even, odd = fft(x[0::2]), fft(x[1::2])
    out = [0j] * n
    for k in range(n // 2):
        t = complex(math.cos(-2 * math.pi * k / n), math.sin(-2 * math.pi * k / n)) * odd[k]
        out[k] = even[k] + t
        out[k + n // 2] = even[k] - t
    return out


def spectrum_db(x, n=4096):
    seg = x[:n] + [0.0] * max(0, n - len(x))
    w = [0.5 - 0.5 * math.cos(2 * math.pi * i / (n - 1)) for i in range(n)]
    spec = fft([complex(seg[i] * w[i], 0) for i in range(n)])
    norm = sum(w) / 2
    return [20 * math.log10(max(abs(spec[k]) / norm, 1e-12)) for k in range(n // 2)]


def plot_spectrum(cv, top, db, rate, color):
    x0, x1 = MARGIN, W - MARGIN
    lo_db, hi_db = -140.0, 6.0
    f_lo, f_hi = 20.0, rate / 2
    n = len(db) * 2
    prev = None
    for k in range(1, len(db)):
        f = k * rate / n
        if f < f_lo:
            continue
        x = x0 + math.log(f / f_lo) / math.log(f_hi / f_lo) * (x1 - x0)
        y = top + PANEL_H - (min(max(db[k], lo_db), hi_db) - lo_db) / (hi_db - lo_db) * PANEL_H
        if prev:
            cv.line(prev[0], prev[1], x, y, color)
        prev = (x, y)


def main():
    if len(sys.argv) != 2:
        print(__doc__)
        sys.exit(2)
    d = sys.argv[1]
    load = lambda name: read_wav(os.path.join(d, name)) if os.path.exists(os.path.join(d, name)) else (None, None)
    expected, rate_e = load("expected.wav")
    actual, rate_a = load("actual.wav")
    diff, _ = load("diff.wav")
    rate = rate_a or rate_e or 48000
    if actual is None:
        sys.exit(f"{d}: no actual.wav")

    cv = Canvas(W, H)
    tops = [MARGIN // 2, MARGIN // 2 + PANEL_H + MARGIN, MARGIN // 2 + 2 * (PANEL_H + MARGIN)]

    # 1. waveform
    peak = max([abs(v) for v in actual[0]] + ([abs(v) for v in expected[0]] if expected else []) + [1e-9])
    frame(cv, tops[0], tops[0] + PANEL_H // 2)
    if expected:
        plot_series(cv, tops[0], expected[0], -peak * 1.05, peak * 1.05, BLUE)
    plot_series(cv, tops[0], actual[0], -peak * 1.05, peak * 1.05, ORANGE)

    # 2. difference
    frame(cv, tops[1], tops[1] + PANEL_H // 2)
    if diff:
        dpk = max(max(abs(v) for v in diff[0]), 1e-12)
        plot_series(cv, tops[1], diff[0], -dpk * 1.05, dpk * 1.05, RED)
        at = max(range(len(diff[0])), key=lambda i: abs(diff[0][i]))
        x = MARGIN + at * (W - 2 * MARGIN) // max(len(diff[0]), 1)
        cv.line(x, tops[1], x, tops[1] + PANEL_H, (0, 0, 0))
        print(f"diff peak {dpk:.3g} at frame {at}")

    # 3. spectrum
    frame(cv, tops[2])
    if expected:
        plot_spectrum(cv, tops[2], spectrum_db(expected[0]), rate, BLUE)
    plot_spectrum(cv, tops[2], spectrum_db(actual[0]), rate, ORANGE)

    out = os.path.join(d, "plot.png")
    cv.png(out)
    print(f"wrote {out}  (panels: waveform blue=expected orange=actual | diff | spectrum 20Hz-Nyquist, -140..+6 dB)")


if __name__ == "__main__":
    main()
