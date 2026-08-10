#!/usr/bin/env python3
"""Render challenges/**/*.tmpl using values from the environment.

Templates use ${VAR}. A missing variable is a hard error - a challenge.yml that
silently renders an empty flag would sync to CTFd and accept nothing.
"""

import os
import sys
from pathlib import Path
from string import Template

ROOT = Path(__file__).resolve().parent.parent


def main() -> int:
    templates = sorted(ROOT.glob("challenges/*/**/*.tmpl"))
    if not templates:
        print("No templates found.")
        return 0

    failed = False
    for tmpl in templates:
        target = tmpl.with_suffix("")
        try:
            rendered = Template(tmpl.read_text()).substitute(os.environ)
        except KeyError as exc:
            print(f"!! {tmpl.relative_to(ROOT)}: {exc.args[0]} is not set", file=sys.stderr)
            failed = True
            continue
        target.write_text(rendered)
        print(f"   {tmpl.relative_to(ROOT)} -> {target.relative_to(ROOT)}")

    if failed:
        print("\nSet the missing variables in .env (see .env.example).", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
