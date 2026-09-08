#!/usr/bin/env python3
import os
import sys
from pathlib import Path


def aws(args: list[str]) -> int:
    if "--query" in args:
        query = args[args.index("--query") + 1]
        print(os.environ["MOCK_VERSION" if query == "VersionId" else "MOCK_SECRET"])
    else:
        print("example-registry-login")
    return 0


def docker(args: list[str]) -> int:
    if args[0] == "login":
        sys.stdin.read()
    elif args[0] == "run":
        print("[extra]\nSESSION_COOKIE_SECURE = true")
    elif args[0] == "inspect":
        print(os.environ.get("MOCK_CONTAINER_EXIT", "0"))
    elif "ps" in args:
        print(args[-1] + "-container")
    elif "stop" in args:
        return int(os.environ.get("MOCK_STOP_FAIL", "0"))
    elif "up" in args:
        return int(os.environ.get("MOCK_START_FAIL", "0"))
    return 0


def main() -> int:
    name = Path(sys.argv[0]).name
    args = sys.argv[1:]
    with Path(os.environ["MOCK_CALLS"]).open("a") as log:
        log.write(name + " " + " ".join(args) + "\n")
    if name == "aws":
        return aws(args)
    if name == "docker":
        return docker(args)
    if name == "systemctl":
        if args[0] == "show":
            print(os.environ.get("MOCK_STOP_RESULT", "success"))
            return 0
        key = {"stop": "MOCK_STOP_FAIL", "start": "MOCK_START_FAIL", "is-active": "MOCK_INACTIVE"}
        return int(os.environ.get(key[args[0]], "0"))
    if name == "mountpoint":
        return int(os.environ.get("MOCK_MISSING_MOUNT", "0"))
    return 0


if __name__ == "__main__":
    sys.exit(main())
