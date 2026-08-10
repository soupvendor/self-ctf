#!/usr/bin/env python3
"""Create .env from .env.example and fill any blank secret with a random value.

Existing values are never overwritten, so this is safe to run against a
configured checkout.
"""

import secrets
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
ENV = ROOT / ".env"
EXAMPLE = ROOT / ".env.example"
GENERATED = {
    "CTFD_SECRET_KEY": lambda: secrets.token_hex(32),
    "CTFD_DB_PASSWORD": lambda: secrets.token_hex(16),
    "CTFD_ADMIN_PASSWORD": lambda: secrets.token_urlsafe(24),
}


def main() -> int:
    if not ENV.exists():
        ENV.write_text(EXAMPLE.read_text())
        print("   created .env from .env.example")

    lines = ENV.read_text().splitlines()
    filled = []
    for i, line in enumerate(lines):
        var, sep, value = line.partition("=")
        if sep and not value.strip() and var in GENERATED:
            lines[i] = f"{var}={GENERATED[var]()}"
            filled.append(var)

    if filled:
        ENV.write_text("\n".join(lines) + "\n")
        for var in filled:
            print(f"   generated {var}")
    else:
        print("   secrets already set")
    return 0


if __name__ == "__main__":
    sys.exit(main())
