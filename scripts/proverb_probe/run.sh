#!/usr/bin/env bash
# ProVerb's reference, measured again (macOS, with ValhallaRoom installed):
# the probe renders the grid through its Audio Unit offline, into
# .build/proverb_ref (gitignored: its output stays on this machine), and
# the analysis writes what was measured to tests/proverb/reference.json.
set -euo pipefail
cd "$(dirname "$0")/../.."
mkdir -p .build/proverb_ref
swiftc -O scripts/proverb_probe/probe.swift -o .build/proverb_probe
.build/proverb_probe list ValhallaRoom > .build/proverb_ref/params.txt
python3 scripts/proverb_probe/jobs.py > .build/proverb_ref/jobs.json
.build/proverb_probe render ValhallaRoom .build/proverb_ref/jobs.json .build/proverb_ref > /dev/null
odin run scripts/proverb_probe/analyze -collection:fire=f_engine -o:speed -out:.build/proverb_analyze -- .build/proverb_ref tests/proverb/reference.json
