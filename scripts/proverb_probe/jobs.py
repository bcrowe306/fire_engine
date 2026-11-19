"""ProVerb's measurement grid: writes the probe's jobs (jobs.json) for the
reference reverb. Each job sets the Audio Unit's own parameters (0..1, as
it exposes them) from the defaults, one or two at a time.

    python3 scripts/proverb_probe/jobs.py > .build/proverb_ref/jobs.json
"""

import json

# The reference's defaults (as `probe list` prints them).
DEFAULT = {
    "mix": 1.0, "predelay": 0.0, "decay": 0.019019019, "HighCut": 0.5302013, "earlyLateMix": 0.5,
    "lateSize": 0.5, "lateCross": 1.0, "lateModRate": 0.09090909, "lateModDepth": 0.5,
    "RTBassMultiply": 0.33333334, "RTXover": 0.09090909, "RTHighMultiply": 0.44444448, "RTHighXover": 0.5302013,
    "earlySize": 0.029029028, "earlyCross": 0.1, "earlyModRate": 0.09090909, "earlyModDepth": 0.0, "earlySend": 0.0,
    "diffusion": 1.0, "type": 0.083333336,
}
# Its Type: floor(type * 12), 0 and 1 the same sound (1: the default,
# Large Room), so twelve modes, 1..12, each set at its range's middle (12
# at 1.0 exactly).
MODES = range(1, 13)


def mode_v(m):
    return 1.0 if m == 12 else (m + 0.5) / 12

jobs = []


def job(name, signal="impulse", seconds=8.0, **over):
    p = dict(DEFAULT)
    p.update(over)
    jobs.append({"name": name, "params": p, "signal": signal, "seconds": seconds})


def decay_v(seconds):  # 0.1..100 s, linear
    return (seconds - 0.1) / 99.9


for m in MODES:
    t = mode_v(m)
    job(f"mode{m:02d}", type=t)
    job(f"mode{m:02d}_late", type=t, earlyLateMix=1.0)
    job(f"mode{m:02d}_early", type=t, earlyLateMix=0.0, seconds=2.0)
    job(f"mode{m:02d}_sine", signal="sine:1000", seconds=4.0, type=t, earlyLateMix=1.0)
    job(f"mode{m:02d}_nomod", signal="sine:1000", seconds=4.0, type=t, earlyLateMix=1.0, lateModDepth=0.0)
# The controls, on the default mode (Large Room).
for s in (0.5, 1, 4, 8):
    job(f"decay_{s}", seconds=max(4.0, 3 * s + 1), decay=decay_v(s), earlyLateMix=1.0)
for v in (0.0, 1.0):
    job(f"bassmult_{v}", RTBassMultiply=v, earlyLateMix=1.0)
    job(f"highmult_{v}", RTHighMultiply=v, earlyLateMix=1.0)
    job(f"latesize_{v}", lateSize=v, earlyLateMix=1.0)
    job(f"latecross_{v}", lateCross=v, earlyLateMix=1.0)
    job(f"earlysize_{v}", earlySize=v, earlyLateMix=0.0, seconds=2.0)
    job(f"earlycross_{v}", earlyCross=v, earlyLateMix=0.0, seconds=2.0)
    job(f"diffusion_{v}", diffusion=v, earlyLateMix=1.0)
for v in (0.25, 0.5, 0.75):
    job(f"bassxover_{v}", RTXover=v, RTBassMultiply=1.0, earlyLateMix=1.0)
    job(f"highxover_{v}", RTHighXover=v, RTHighMultiply=0.0, earlyLateMix=1.0)
    job(f"highcut_{v}", HighCut=v, earlyLateMix=1.0)
    job(f"earlysend_{v}", earlySend=v, earlyLateMix=1.0)
for v in (0.0, 0.5, 1.0):
    job(f"modrate_{v}", signal="sine:1000", seconds=4.0, lateModRate=v, lateModDepth=1.0, earlyLateMix=1.0)
    job(f"moddepth_{v}", signal="sine:1000", seconds=4.0, lateModDepth=v, earlyLateMix=1.0)
job("predelay_0.2", predelay=0.2, seconds=3.0)
job("mix_0.5", mix=0.5, seconds=3.0)
job("burst", signal="noise", seconds=6.0)

print(json.dumps(jobs, indent=1))
