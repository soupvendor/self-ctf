#!/usr/bin/env python3
"""Install challenges CTFd has never seen, sync the ones it has.

ctfcli has no upsert: `sync` fails on an unknown challenge and `install`
duplicates a known one. So ask CTFd which names exist and pick the verb.
"""

import configparser
import json
import re
import subprocess
import sys
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
NAME = re.compile(r"^name:\s*(.+?)\s*$", re.MULTILINE)


def require_http(url: str) -> str:
    if not url.startswith(("http://", "https://")):
        raise SystemExit(f"!! CTFD_URL must be http(s), got: {url}")
    return url.rstrip("/")


def remote_names(url: str, token: str) -> set[str]:
    # view=admin so hidden challenges count as existing - otherwise we would
    # install a duplicate every run.
    req = urllib.request.Request(  # noqa: S310 - require_http rejects non-http schemes
        f"{require_http(url)}/api/v1/challenges?view=admin",
        headers={
            "Authorization": f"Token {token}",
            # CTFd ignores the token unless the request is JSON.
            "Content-Type": "application/json",
        },
    )
    with urllib.request.urlopen(req, timeout=30) as resp:  # noqa: S310 - scheme checked above
        return {c["name"] for c in json.load(resp)["data"]}


def local_name(path: Path) -> str:
    match = NAME.search((path / "challenge.yml").read_text())
    if not match:
        raise SystemExit(f"!! {path}/challenge.yml has no name field")
    return match.group(1).strip("\"'")


def main() -> int:
    config = configparser.ConfigParser()
    config.read(ROOT / ".ctf" / "config")
    if "config" not in config:
        print("!! No .ctf/config - run: mise run bootstrap", file=sys.stderr)
        return 1

    existing = remote_names(config["config"]["url"], config["config"]["access_token"])

    for template in sorted(ROOT.glob("challenges/*/challenge.yml.tmpl")):
        path = template.parent
        rel = path.relative_to(ROOT)
        verb = "sync" if local_name(path) in existing else "install"
        print(f"==> {verb} {rel}")
        result = subprocess.run(["ctf", "challenge", verb, str(rel)], cwd=ROOT, check=False)
        if result.returncode != 0:
            return result.returncode

    return 0


if __name__ == "__main__":
    sys.exit(main())
