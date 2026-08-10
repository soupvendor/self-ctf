#!/usr/bin/env python3
"""Write .ctf/config from the filesystem, preserving any existing token.

ctfcli refuses to run - and prompts interactively - outside a project, so this
has to exist before `ctf challenge lint`, which is well before there is a CTFd
instance to get a token from.
"""

import argparse
import configparser
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
CONFIG = ROOT / ".ctf" / "config"


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--url", default="http://localhost:8000")
    parser.add_argument("--token")
    args = parser.parse_args()

    config = configparser.ConfigParser()
    if CONFIG.exists():
        config.read(CONFIG)

    if not config.has_section("config"):
        config.add_section("config")
    config["config"]["url"] = args.url
    if args.token:
        config["config"]["access_token"] = args.token
    elif not config.has_option("config", "access_token"):
        config["config"]["access_token"] = ""

    config["challenges"] = {
        str(path.parent.relative_to(ROOT)): str(path.parent.relative_to(ROOT))
        for path in sorted(ROOT.glob("challenges/*/challenge.yml"))
    }

    CONFIG.parent.mkdir(exist_ok=True)
    with CONFIG.open("w") as handle:
        config.write(handle)

    print(f"   .ctf/config: {len(config['challenges'])} challenge(s)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
