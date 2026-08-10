#!/usr/bin/env python3
"""Fail if an answer key can reach a player, or a real flag reaches git.

AGENTS.md requires the exclusion to be mechanical rather than conventional.
This is the mechanism.
"""

import io
import os
import re
import subprocess
import sys
import tarfile
from collections.abc import Iterator
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
EXPECTED_MARKER = ".expect-flag-in-artifact"
FLAG_VAR = re.compile(r"\bFLAG_[A-Z0-9_]+")
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


def rendered_ignored() -> list[str]:
    """A template whose output is not gitignored is one commit from a leaked flag."""
    targets = [
        str(t.with_suffix("").relative_to(ROOT))
        for t in sorted(ROOT.glob("challenges/*/**/*.tmpl"))
    ]
    if not targets:
        return []
    # check-ignore exits 1 when nothing matches, so check=False and read stdout.
    out = subprocess.run(
        ["git", "check-ignore", "--stdin"],
        cwd=ROOT,
        input="\n".join(targets),
        capture_output=True,
        text=True,
        check=False,
    )
    ignored = set(out.stdout.split())
    return [
        f"{t} is rendered from a template but is not gitignored"
        for t in targets
        if t not in ignored
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


def unpack(data: bytes, depth: int = 2) -> Iterator[bytes]:
    """Yield the buffer and, if it is a tar, the contents of what is inside it.

    A `docker save` archive is a tar of tars, so a flag baked into a layer is
    invisible to a plain byte search of the outer file.
    """
    yield data
    if depth <= 0:
        return
    try:
        with tarfile.open(fileobj=io.BytesIO(data)) as archive:
            for member in archive.getmembers():
                handle = archive.extractfile(member) if member.isfile() else None
                if handle is not None:
                    yield from unpack(handle.read(), depth - 1)
    except tarfile.TarError:
        return


def dist_clean(challenge: Path, values: dict[str, str]) -> list[str]:
    """Only the flags a challenge declares recoverable may reach its dist/.

    `mise run lint` turns off ctfcli's distributed-file scan for any challenge
    carrying the marker file. That is right for the flag the puzzle is about and
    wrong for every other one, so the marker names which flags it covers.
    """
    dist = challenge / "dist"
    if not dist.is_dir():
        return []

    marker = challenge / EXPECTED_MARKER
    expected = set(FLAG_VAR.findall(marker.read_text())) if marker.exists() else set()
    forbidden = {var: value.encode() for var, value in values.items() if var not in expected}
    if not forbidden:
        return []

    name = challenge.relative_to(ROOT)
    found = set()
    for artifact in sorted(p for p in dist.rglob("*") if p.is_file()):
        for chunk in unpack(artifact.read_bytes()):
            found |= {var for var, value in forbidden.items() if value in chunk}
    return [f"{name}/dist/ ships the real value of {var}" for var in sorted(found)]


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
    problems += no_flag_committed(values, tracked) + templates_tracked(tracked) + rendered_ignored()
    for challenge in sorted(ROOT.glob("challenges/*/")):
        problems += (
            answer_key_excluded(challenge)
            + readme_clean(challenge, values, tracked)
            + dist_clean(challenge, values)
        )

    if problems:
        print("Leak check failed:", file=sys.stderr)
        for problem in problems:
            print(f"  - {problem}", file=sys.stderr)
        return 1

    print(f"Leak check passed ({len(values)} flag(s), {len(tracked_files())} tracked files).")
    return 0


if __name__ == "__main__":
    sys.exit(main())
