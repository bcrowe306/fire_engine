#!/usr/bin/env python3
"""Drive Pads live: starts the app under remote control and runs the
commands you give it, printing each answer (or the crash report if it
dies). For poking at the app by hand, or from another tool.

    python3 tests/e2e/ctl.py                       # a window; commands from stdin, one per line
    python3 tests/e2e/ctl.py --headless 'click_item "  Mixer"' 'state'   # these, then quit
    python3 tests/e2e/ctl.py --keep 'browse tests/app_ui/fixtures/library'  # these, then stdin

Commands are drive-script lines (see app:ui's Driver and the Pads guide):
click_item, drag_item, drag_by, key, text, items, state, screenshot...
"""

import argparse
import sys

from pads import Pads, PadsCrash, PadsError


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("commands", nargs="*", help="commands to run (then quit, unless --keep)")
    ap.add_argument("--headless", action="store_true", help="no window")
    ap.add_argument("--real", action="store_true", help="the real audio device (default: simulated)")
    ap.add_argument("--keep", action="store_true", help="read more commands from stdin after these")
    ap.add_argument("--project", help="a project folder to open")
    args = ap.parse_args()
    app = Pads(headless=args.headless, fake=not args.real, project=args.project)
    print(f"# Pads is running; screenshots go to {app.out_dir}", file=sys.stderr)

    def run(line):
        try:
            out = app.cmd(line)
            print(out.rstrip("\n") if out else "ok")
        except PadsError as e:
            print(f"error: {e}")
        except PadsCrash as e:
            print(f"# CRASH\n{e.report}", file=sys.stderr)
            sys.exit(2)
        sys.stdout.flush()

    for c in args.commands:
        run(c)
    if args.keep or not args.commands:
        for line in sys.stdin:
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            if line in ("quit", "exit"):
                break
            run(line)
    app.close()


if __name__ == "__main__":
    main()
