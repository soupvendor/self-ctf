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


def flags() -> dict[str, str]:
    return {k: v for k, v in os.environ.items() if k.startswith("FLAG_") and v}


def tracked_files() -> list[str]:
    out = subprocess.run(
        ["git", "ls-files"], cwd=ROOT, capture_output=True, text=True, check=True
    )
    return out.stdout.split()


def main() -> int:
    problems = []
    values = flags()

    if not values:
        print("!! No FLAG_* variables set - nothing to check against.", file=sys.stderr)
        return 1

    # 1. No real flag may be committed.
    for rel in tracked_files():
        path = ROOT / rel
        try:
            text = path.read_text()
        except (UnicodeDecodeError, OSError):
            continue
        for var, value in values.items():
            if value in text:
                problems.append(f"{rel} contains the real value of {var}")

    # 0. A template that git does not track renders fine for whoever wrote it
    #    and is simply absent for everyone else, including CI.
    tracked = set(tracked_files())
    for tmpl in sorted(ROOT.glob("challenges/*/**/*.tmpl")):
        rel = str(tmpl.relative_to(ROOT))
        if rel not in tracked:
            problems.append(f"{rel} is not tracked by git - check .gitignore")

    for challenge in sorted(ROOT.glob("challenges/*/")):
        name = challenge.relative_to(ROOT)

        # 2. Every challenge that builds an image must exclude its answer key.
        if any(challenge.glob("*Dockerfile")):
            ignore = challenge / ".dockerignore"
            if not ignore.exists():
                problems.append(f"{name} has a Dockerfile but no .dockerignore")
            else:
                entries = ignore.read_text().split()
                for required in REQUIRED_DOCKERIGNORE:
                    if required not in entries:
                        problems.append(f"{name}/.dockerignore does not exclude {required}")

        # 3. A challenge README enters the build context even untracked, so
        #    check it whether or not git knows about it.
        readme = challenge / "README.md"
        if readme.exists() and readme.name not in tracked_files():
            for var, value in values.items():
                if value in readme.read_text():
                    problems.append(f"{name}/README.md contains {var}")

    if problems:
        print("Leak check failed:", file=sys.stderr)
        for problem in problems:
            print(f"  - {problem}", file=sys.stderr)
        return 1

    print(f"Leak check passed ({len(values)} flag(s), {len(tracked_files())} tracked files).")
    return 0


if __name__ == "__main__":
    sys.exit(main())
