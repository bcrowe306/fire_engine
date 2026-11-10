# Writes the audio fixtures the Pads drive scripts load: a kick, a hat and a
# one-bar drum loop at 120 BPM (44.1 kHz, 16-bit mono). Run from this folder.
import math, random, struct, wave

RATE = 44100
random.seed(7)

def write(name, x):
    with wave.open(name, "wb") as w:
        w.setnchannels(1); w.setsampwidth(2); w.setframerate(RATE)
        w.writeframes(b"".join(struct.pack("<h", int(max(-1, min(1, v)) * 32000)) for v in x))

def kick(n):
    out, phase = [], 0.0
    for i in range(n):
        f = 50 + 120 * math.exp(-i / 900)
        phase += 2 * math.pi * f / RATE
        out.append(0.9 * math.sin(phase) * math.exp(-i / 5000))
    return out

def hat(n):
    return [random.uniform(-1, 1) * 0.5 * math.exp(-i / 700) for i in range(n)]

write("kick.wav", kick(int(0.35 * RATE)))
write("hat.wav", hat(int(0.12 * RATE)))
beat = RATE // 2                       # 120 BPM
loop = [0.0] * (4 * beat)
for b in range(4):
    for i, v in enumerate(kick(beat if b % 2 == 0 else 0) if b % 2 == 0 else hat(beat // 2)):
        loop[b * beat + i] += v
    for i, v in enumerate(hat(beat // 4)):
        loop[b * beat + beat // 2 + i] += 0.6 * v
write("loop.wav", loop)

# beat.mid: one bar of a drum pattern (kick on 36, hat on 37), 480 ticks a beat.
def vlq(n):
    out = [n & 0x7F]
    n >>= 7
    while n:
        out.insert(0, 0x80 | (n & 0x7F))
        n >>= 7
    return bytes(out)

events = []  # (tick, bytes)
for b in range(4):
    events.append((b * 480, bytes([0x99, 36, 110])))
    events.append((b * 480 + 120, bytes([0x89, 36, 0])))
    events.append((b * 480 + 240, bytes([0x99, 37, 80])))
    events.append((b * 480 + 360, bytes([0x89, 37, 0])))
events.sort(key=lambda e: e[0])
track, last = b"", 0
for tick, data in events:
    track += vlq(tick - last) + data
    last = tick
track += vlq(1920 - last) + bytes([0xFF, 0x2F, 0x00])
with open("beat.mid", "wb") as f:
    f.write(b"MThd" + struct.pack(">IHHH", 6, 0, 1, 480))
    f.write(b"MTrk" + struct.pack(">I", len(track)) + track)
