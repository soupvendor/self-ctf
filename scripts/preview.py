#!/usr/bin/env python3
"""Make every challenge visible on the local instance, for looking at it.

Deliberately does not touch challenge.yml.tmpl: release state belongs in the
template. This only changes the running instance, and the next plain
`mise run sync` puts it back to whatever the template says.
"""

import configparser
import json
import sys
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent


def api(url: str, token: str, path: str, method: str = "GET", body: dict | None = None):
    req = urllib.request.Request(
        f"{url.rstrip('/')}{path}",
        method=method,
        data=json.dumps(body).encode() if body else None,
        headers={
            "Authorization": f"Token {token}",
            # CTFd ignores the token unless the request is JSON.
            "Content-Type": "application/json",
        },
    )
    with urllib.request.urlopen(req, timeout=30) as resp:
        return json.load(resp)["data"]


def main() -> int:
    config = configparser.ConfigParser()
    config.read(ROOT / ".ctf" / "config")
    if "config" not in config:
        print("!! No .ctf/config - run: mise run bootstrap", file=sys.stderr)
        return 1

    url = config["config"]["url"]
    token = config["config"]["access_token"]

    challenges = api(url, token, "/api/v1/challenges?view=admin")
    if not challenges:
        print("No challenges installed yet.")
        return 0

    for challenge in challenges:
        api(url, token, f"/api/v1/challenges/{challenge['id']}", "PATCH", {"state": "visible"})
        print(f"   visible: {challenge['name']}")

    print(f"\nOpen {url}/challenges - this is local only, `mise run sync` reverts it.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
