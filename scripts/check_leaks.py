#!/usr/bin/env python3
"""Fail if an answer key can reach a player, or a real flag reaches git.

AGENTS.md requires the exclusion to be mechanical rather than conventional.
This is the mechanism.
"""

import os
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
REQUIRED_DOCKERIGNORE = ("writeup/", "dist/")
# Exempt from gitleaks because they are gitignored; this is what enforces that.
NEVER_TRACKED = (".env", ".ctf/config")


def flags() -> dict[str, str]:
    return {k: v for k, v in os.environ.items() if k.startswith("FLAG_") and v}


def tracked_files() -> list[str]:
    out = subprocess.run(["git", "ls-files"], cwd=ROOT, capture_output=True, text=True, check=True)
    return out.stdout.split()


def no_flag_committed(values: dict[str, str], tracked: set[str]) -> list[str]:
    problems = []
    for rel in sorted(tracked):
        try:
            text = (ROOT / rel).read_text()
        except (UnicodeDecodeError, OSError):
            continue
        problems += [
            f"{rel} contains the real value of {var}"
            for var, value in values.items()
            if value in text
        ]
    return problems


def templates_tracked(tracked: set[str]) -> list[str]:
    """An untracked template renders for its author and is absent for everyone else."""
    return [
        f"{rel} is not tracked by git - check .gitignore"
        for tmpl in sorted(ROOT.glob("challenges/*/**/*.tmpl"))
        if (rel := str(tmpl.relative_to(ROOT))) not in tracked
    ]


def answer_key_excluded(challenge: Path) -> list[str]:
    name = challenge.relative_to(ROOT)
    if not any(challenge.glob("*Dockerfile")):
        return []

    ignore = challenge / ".dockerignore"
    if not ignore.exists():
        return [f"{name} has a Dockerfile but no .dockerignore"]

    entries = ignore.read_text().split()
    return [
        f"{name}/.dockerignore does not exclude {required}"
        for required in REQUIRED_DOCKERIGNORE
        if required not in entries
    ]


def readme_clean(challenge: Path, values: dict[str, str], tracked: set[str]) -> list[str]:
    """A challenge README enters the build context even when git does not track it."""
    readme = challenge / "README.md"
    if not readme.exists() or str(readme.relative_to(ROOT)) in tracked:
        return []
    text = readme.read_text()
    name = challenge.relative_to(ROOT)
    return [f"{name}/README.md contains {var}" for var, value in values.items() if value in text]


def main() -> int:
    values = flags()
    if not values:
        print("!! No FLAG_* variables set - nothing to check against.", file=sys.stderr)
        return 1

    tracked = set(tracked_files())
    problems = [
        f"{path} is tracked by git and must never be" for path in NEVER_TRACKED if path in tracked
    ]
    problems += no_flag_committed(values, tracked) + templates_tracked(tracked)
    for challenge in sorted(ROOT.glob("challenges/*/")):
        problems += answer_key_excluded(challenge) + readme_clean(challenge, values, tracked)

    if problems:
        print("Leak check failed:", file=sys.stderr)
        for problem in problems:
            print(f"  - {problem}", file=sys.stderr)
        return 1

    print(f"Leak check passed ({len(values)} flag(s), {len(tracked_files())} tracked files).")
    return 0


if __name__ == "__main__":
    sys.exit(main())
