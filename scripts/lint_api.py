#!/usr/bin/env python3
"""Pads is a client of its API (docs/design/api.md): once a module is built,
the UI and the test-script commands (package `pads`, apps/pads/*.odin) do
what it does through `pads_api`, not by calling the model. This fails on a
call into the model that a built module's API owns.

    python3 scripts/lint_api.py

A line may say why it is an exception with `// api-lint: <reason>`.
"""
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
UI = os.path.join(ROOT, "apps", "pads")

# Module: what only its API may do (regexes over a line of the UI's code).
MODULES = {
    "history": [
        (r"\bapp\.(undo|redo)\(", "history_undo / history_redo"),
        (r"\bapp\.(undo_name|redo_name)\(", "history_undo_name / history_redo_name"),
        (r"\.history\.(undo|redo)\b", "history_state / history_step_name"),
    ],
    "transport": [
        (r"\bpm\.(play|stop|silence_all|set_bpm|tap|tap_start_due)\(", "transport_play / stop / silence / set_tempo / tap"),
        (r"\bpm\.set_transport\([^)]*\.(Loop|Count_In|Metro_\w+|Time_Sig)\b", "transport_set_*"),
        (r"\b(project|p)\.song_mode\s*=[^=]", "transport_set_song_mode"),
        (r"\b(engine|e)\.metronome\s*=[^=]", "transport_set_metronome"),
    ],
    "project": [
        (r"\bpm\.model_(new|new_from|load|save|save_as|save_copy|move|load_backup|discard_backup|save_backup)\(", "project_new / open / save / save_as / rename / recover"),
    ],
    # (The Settings window is the editor of the same fields the registry
    # points at; the test-script commands set them through the API.)
    "settings": [
        (r"\ba\.settings\.(?!theme\b|open\b|page\b)\w+(\.\w+)*\s*=[^=]", "settings_set_number / settings_set_text", "shell.odin"),
    ],
}


def main():
    problems = []
    for f in sorted(os.listdir(UI)):
        if not f.endswith(".odin"):
            continue
        path = os.path.join(UI, f)
        with open(path, encoding="utf-8") as fh:
            for n, line in enumerate(fh, 1):
                code = line.split("//", 1)[0] if "api-lint:" not in line else ""
                for module, rules in MODULES.items():
                    for rule in rules:
                        pattern, use = rule[0], rule[1]
                        if len(rule) > 2 and f != rule[2]:
                            continue
                        if re.search(pattern, code):
                            problems.append(f"apps/pads/{f}:{n}: the {module} module's API does this: use {use}\n\t{line.strip()}")
    if problems:
        print("\n".join(problems), file=sys.stderr)
        print(f"lint_api: {len(problems)} call(s) past the API", file=sys.stderr)
        sys.exit(1)
    print(f"lint_api: the UI uses the API for {', '.join(MODULES)}")


if __name__ == "__main__":
    main()
