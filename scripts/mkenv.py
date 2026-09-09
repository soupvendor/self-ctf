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
    "CTFD_DB_PASSWORD": lambda: secrets.token_hex(32),
    "CTFD_ADMIN_PASSWORD": lambda: secrets.token_urlsafe(24),
    "GITEA_ADMIN_PASSWORD": lambda: secrets.token_urlsafe(24),
}


def keys(lines: list[str]) -> set[str]:
    return {line.partition("=")[0] for line in lines if "=" in line}


def add_new_settings(lines: list[str]) -> list[str]:
    """Carry over settings added to .env.example since this .env was written."""
    example = EXAMPLE.read_text().splitlines()
    missing = [
        line for line in example if "=" in line and line.partition("=")[0] not in keys(lines)
    ]
    if not missing:
        return lines
    for line in missing:
        print(f"   added {line.partition('=')[0]} from .env.example")
    return [*lines, "", *missing]


def main() -> int:
    if not ENV.exists():
        ENV.write_text(EXAMPLE.read_text())
        print("   created .env from .env.example")

    # Compared as text, not as lists: add_new_settings returns its argument
    # unchanged when nothing is missing, so a list comparison would be against
    # the same object the fill loop just mutated, and would never write.
    before = ENV.read_text()
    lines = add_new_settings(before.splitlines())
    filled = []
    for i, line in enumerate(lines):
        var, sep, value = line.partition("=")
        if sep and not value.strip() and var in GENERATED:
            lines[i] = f"{var}={GENERATED[var]()}"
            filled.append(var)

    after = "\n".join(lines) + "\n"
    if after != before:
        ENV.write_text(after)
    for var in filled:
        print(f"   generated {var}")
    if not filled:
        print("   secrets already set")
    return 0


if __name__ == "__main__":
    sys.exit(main())
