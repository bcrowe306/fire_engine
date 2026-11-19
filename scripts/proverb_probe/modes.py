"""ProVerb's modes, from the reference's measurements: each mode's
character against the default mode's (how much sooner or later its tail
arrives, how its bass and treble last against its middle, how much it
modulates, how loud and how stereo its early part is), written as an
Odin table for the node. Numbers only: the structure is ProVerb's own.

    python3 scripts/proverb_probe/modes.py > f_engine/fx/proverb_modes.odin
"""

import json

ref = {m["name"]: m for m in json.load(open("tests/proverb/reference.json"))}
base = ref["mode01"]
base_late = ref["mode01_late"]
base_sine = ref["mode01_sine"]["spread_hz"]
base_early = ref["mode01_early"]

rows = []
for k in range(1, 13):
    m = ref[f"mode{k:02d}"]
    late, early, sine = ref[f"mode{k:02d}_late"], ref[f"mode{k:02d}_early"], ref[f"mode{k:02d}_sine"]
    rt, brt = late["rt60"], base_late["rt60"]  # (the late tail's: what the network makes)
    rows.append({
        "first": max(late["first_ms"], 1.0) / base_late["first_ms"],
        "mid": rt[3] / brt[3],
        "bass": (rt[0] / rt[3]) / (brt[0] / brt[3]),
        "high": (rt[6] / rt[3]) / (brt[6] / brt[3]),
        "mod": sine["spread_hz"] / base_sine,
        "late_db": late["level_db"] - base_late["level_db"],
        "early_db": early["level_db"] - base_early["level_db"],
        "wide": abs(early["correlation"]) < 0.9,
        "slow": m["density_90"] < 0 or m["density_90"] > 200,
    })

print("""package fx

// ProVerb's modes, each one's character against the first's, from the
// reference's measurements (scripts/proverb_probe/modes.py writes this
// file; don't edit it by hand).
@(private)
Pv_Mode :: struct {
	first:    f32,  // the late tail's first arrival, against the first mode's
	mid:      f32,  // the middle's decay, against the first mode's
	bass:     f32,  // the bass's decay against the middle's, against the first mode's
	high:     f32,  // and the treble's
	mod:      f32,  // how much it modulates
	late_db:  f32,  // the late tail's level
	early_db: f32,  // the early part's level
	wide:     bool, // its early part differs left and right
	slow:     bool, // its density builds slowly
}

@(private)
PV_MODES := [12]Pv_Mode{""")
for r in rows:
    print(f"\t{{first = {r['first']:.3f}, mid = {r['mid']:.3f}, bass = {r['bass']:.3f}, high = {r['high']:.3f}, mod = {r['mod']:.3f}, late_db = {r['late_db']:.2f}, early_db = {r['early_db']:.2f}, wide = {str(r['wide']).lower()}, slow = {str(r['slow']).lower()}}},")
print("}")
