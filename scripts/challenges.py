import argparse
import json
import re
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def compose(team: str, challenge: str) -> list[str]:
    if not re.fullmatch(r"[a-z][a-z0-9-]{0,15}", team):
        raise ValueError("Invalid team ID")
    if challenge not in available():
        raise ValueError("Unknown challenge")
    return [
        "docker",
        "compose",
        "--env-file",
        str(ROOT / ".env"),
        "-p",
        f"self-ctf-{team}-{challenge}",
        "-f",
        str(ROOT / "challenges" / challenge / "compose.yaml"),
    ]


def available() -> list[str]:
    return sorted(path.parent.name for path in (ROOT / "challenges").glob("*/compose.yaml"))


def run(args: list[str]) -> None:
    subprocess.run(args, check=True)


def operate(command: str, team: str, challenge: str) -> None:
    args = compose(team, challenge)
    config = json.loads(subprocess.check_output([*args, "config", "--format", "json"], text=True))
    seeders = config.get("x-self-ctf-seeders", [])
    services = config["services"]
    if command == "images":
        built = [name for name, service in services.items() if "build" in service]
        if built:
            run([*args, "build", *built])
            run(
                [
                    "bash",
                    str(ROOT / "scripts/check-runtime-images.sh"),
                    *[services[name]["image"] for name in built],
                ]
            )
    elif command in {"up", "reset"}:
        if command == "reset":
            run([*args, "down", "-v"])
        run([*args, "up", "-d"])
        for seeder in seeders:
            run([*args, "wait", seeder])
        run([*args, "up", "-d", "--wait", *[name for name in services if name not in seeders]])
    elif command == "down":
        run([*args, "down", "-v"])
    elif command == "logs":
        run([*args, "logs", "--tail", "100"])
    else:
        run([*args, "ps"])


def main() -> None:
    parser = argparse.ArgumentParser(description="Independent local challenge bundles")
    parser.add_argument("command", choices=["images", "up", "down", "reset", "logs", "status"])
    parser.add_argument("challenge", nargs="?", choices=available())
    parser.add_argument("--team", default="local")
    args = parser.parse_args()
    if args.command == "reset" and args.challenge is None:
        parser.error("reset requires one challenge")
    for challenge in [args.challenge] if args.challenge else available():
        operate(args.command, args.team, challenge)


if __name__ == "__main__":
    main()
