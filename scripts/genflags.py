#!/usr/bin/env python3
"""Replace placeholder FLAG_* values in .env with freshly generated flags.

Existing real flags are left alone unless --force is passed, so re-running this
never silently invalidates a live event.
"""

import re
import secrets
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
ENV = ROOT / ".env"
PLACEHOLDER = re.compile(r"^\s*$|EXAMPLE|REPLACE_ME")


def generate(var: str) -> str:
    slug = var.removeprefix("FLAG_").lower()
    return f"flag{{{slug}_{secrets.token_hex(6)}}}"


def main() -> int:
    force = "--force" in sys.argv

    if not ENV.exists():
        print("No .env found. Copy .env.example to .env first.", file=sys.stderr)
        return 1

    lines = ENV.read_text().splitlines()
    changed = []
    for i, line in enumerate(lines):
        if not line.startswith("FLAG_") or "=" not in line:
            continue
        var, _, value = line.partition("=")
        if force or PLACEHOLDER.search(value):
            lines[i] = f"{var}={generate(var)}"
            changed.append(var)

    if not changed:
        print("Every flag is already set. Use --force to regenerate.")
        return 0

    ENV.write_text("\n".join(lines) + "\n")
    for var in changed:
        print(f"   generated {var}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
