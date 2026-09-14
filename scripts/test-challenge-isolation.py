import json
import os
import secrets
import shutil
import socket
import subprocess
import tempfile
import unittest
from dataclasses import dataclass
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
BUNDLES = ("secrets-all-the-way-down", "nothing-is-ephemeral")
PROBE = """
import socket, sys
with socket.create_connection(('127.0.0.1', 4566), timeout=1):
    pass
for host, port in zip(sys.argv[1::2], sys.argv[2::2], strict=True):
    try:
        connection = socket.create_connection((host, int(port)), timeout=1)
    except OSError:
        continue
    connection.close()
    raise SystemExit(f"Cross-bundle connection succeeded: {host}:{port}")
"""


@dataclass
class Container:
    id: str
    networks: dict[str, str]
    environment: set[str]
    bind_mounts: bool
    memory: int
    user: str


def port() -> str:
    with socket.socket() as listener:
        listener.bind(("127.0.0.1", 0))
        return str(listener.getsockname()[1])


def endpoints(containers: dict[str, Container], challenge: str) -> list[str]:
    ports = {"localstack": ["4566"], "gitea": ["3000"], "ingress": ["4566"]}
    if challenge == BUNDLES[0]:
        ports["ingress"].append("3000")
    targets = []
    for service, container in containers.items():
        for address in container.networks.values():
            for target_port in ports.get(service, []):
                targets.extend([address, target_port])
    return targets


class IsolationTest(unittest.TestCase):
    def setUp(self) -> None:
        self.fixture = Path(tempfile.mkdtemp(prefix="self-ctf-isolation-"))
        self.label = secrets.token_hex(3)
        self.teams = (f"red{self.label}", f"blue{self.label}")
        paths = subprocess.check_output(
            ["git", "ls-files", "--cached", "--others", "--exclude-standard"],
            cwd=ROOT,
            text=True,
        ).splitlines()
        for relative in paths:
            source = ROOT / relative
            if source.is_file() and (
                relative.startswith(("scripts/", "challenges/"))
                or relative in {"compose.yaml", ".env.example"}
            ):
                target = self.fixture / relative
                target.parent.mkdir(parents=True, exist_ok=True)
                shutil.copy2(source, target)
        values = {}
        for line in (ROOT / ".env.example").read_text().splitlines():
            if line and not line.startswith("#"):
                key, _, value = line.partition("=")
                values[key] = value
        for key in values:
            if key.startswith("FLAG_"):
                values[key] = f"flag{{EXAMPLE_ISOLATION_{key}_{self.label}}}"
        values.update(
            {
                "CTFD_DB_PASSWORD": secrets.token_hex(32),
                "CTFD_SECRET_KEY": secrets.token_hex(32),
                "CTFD_ADMIN_PASSWORD": secrets.token_hex(16),
                "GITEA_ADMIN_PASSWORD": secrets.token_hex(16),
                "CTFD_PORT": port(),
                "GITEA_PORT": port(),
                "LOCALSTACK_PORT": port(),
                "TFSTATE_LOCALSTACK_PORT": port(),
                "ARTIFACT_IMAGE": f"self-ctf/isolation-artifact:{self.label}",
            }
        )
        values["CTFD_URL"] = f"http://localhost:{values['CTFD_PORT']}"
        (self.fixture / ".env").write_text(
            "".join(f"{key}={value}\n" for key, value in values.items())
        )
        (self.fixture / ".env").chmod(0o600)
        self.environment = {**os.environ, **values}
        for key in list(self.environment):
            if key.startswith("AWS_") or (key.startswith("FLAG_") and key not in values):
                del self.environment[key]
        self.environment.update({"AWS_EC2_METADATA_DISABLED": "true", "AWS_PAGER": ""})
        self.environments = {
            self.teams[0]: dict(self.environment),
            self.teams[1]: {
                **self.environment,
                "GITEA_PORT": port(),
                "LOCALSTACK_PORT": port(),
                "TFSTATE_LOCALSTACK_PORT": port(),
            },
        }
        self.platform = [
            "docker",
            "compose",
            "-p",
            f"self-ctf-isolation-{self.label}",
            "--env-file",
            str(self.fixture / ".env"),
            "-f",
            str(self.fixture / "compose.yaml"),
        ]
        print(f"Rehearsal fixture and logs: {self.fixture}", flush=True)

    def run_command(self, args: list[str], team: str | None = None) -> str:
        environment = self.environment if team is None else self.environments[team]
        result = subprocess.run(
            args,
            cwd=self.fixture,
            env=environment,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            check=False,
        )
        with (self.fixture / "verification.log").open("a") as log:
            log.write(result.stdout)
        if result.returncode:
            self.fail(f"Command failed: {args[:5]}\n{result.stdout[-6000:]}")
        return result.stdout.strip()

    def bundle(self, command: str, team: str, challenge: str) -> None:
        try:
            self.run_command(
                ["python3", "scripts/challenges.py", command, challenge, "--team", team], team
            )
        except AssertionError:
            print(self.run_command(self.compose(team, challenge, "logs", "--tail", "40"), team))
            raise

    def compose(self, team: str, challenge: str, *args: str) -> list[str]:
        return [
            "docker",
            "compose",
            "--env-file",
            str(self.fixture / ".env"),
            "-p",
            f"self-ctf-{team}-{challenge}",
            "-f",
            str(self.fixture / "challenges" / challenge / "compose.yaml"),
            *args,
        ]

    def containers(self, team: str, challenge: str) -> dict[str, Container]:
        ids = self.run_command(self.compose(team, challenge, "ps", "-a", "-q"), team).splitlines()
        items = json.loads(self.run_command(["docker", "inspect", *ids]))
        return {
            item["Config"]["Labels"]["com.docker.compose.service"]: Container(
                id=item["Id"],
                networks={
                    name: network["IPAddress"]
                    for name, network in item["NetworkSettings"]["Networks"].items()
                },
                environment={entry.split("=", 1)[0] for entry in item["Config"]["Env"]},
                bind_mounts=any(mount["Type"] == "bind" for mount in item["Mounts"]),
                memory=item["HostConfig"]["Memory"],
                user=item["Config"]["User"],
            )
            for item in items
        }

    def solve(self, team: str) -> None:
        self.run_command(["python3", "scripts/render.py"], team)
        self.run_command(["bash", "scripts/build.sh"], team)
        self.run_command(["python3", "scripts/sync.py"], team)
        for challenge in BUNDLES:
            output = self.run_command(
                ["ctf", "challenge", "healthcheck", f"challenges/{challenge}"], team
            )
            self.assertIn("PASS:", output)
            print(f"PASS: {team}/{challenge} ctfcli solver", flush=True)

    def check_failed_seed(self, team: str) -> None:
        challenge = BUNDLES[0]
        config = json.loads(
            self.run_command(self.compose(team, challenge, "config", "--format", "json"), team)
        )
        config["services"]["gitea-seed"]["entrypoint"] = ["/bin/sh", "-c", "exit 17"]
        self.bundle("down", team, challenge)
        (self.fixture / "challenges" / challenge / "compose.yaml").write_text(json.dumps(config))
        with self.assertRaises(self.failureException):
            self.run_command(
                ["python3", "scripts/challenges.py", "up", challenge, "--team", team], team
            )
        seeder = self.run_command(self.compose(team, challenge, "ps", "-a", "-q", "gitea-seed"))
        self.assertEqual(
            self.run_command(["docker", "inspect", "-f", "{{.State.ExitCode}}", seeder]), "17"
        )
        self.assertEqual(
            self.run_command(
                self.compose(team, challenge, "ps", "--status", "running", "-q", "ingress")
            ),
            "",
        )
        print("PASS: failed seeding fails startup and keeps ingress stopped", flush=True)

    def test_two_teams_two_challenges(self) -> None:
        self.run_command(["python3", "scripts/challenges.py", "images"])
        self.addCleanup(self.run_command, [*self.platform, "down"])
        self.run_command([*self.platform, "up", "-d", "--wait"])
        self.run_command(["bash", "scripts/bootstrap.sh"])
        for team in self.teams:
            for challenge in BUNDLES:
                self.addCleanup(self.bundle, "down", team, challenge)
                self.bundle("up", team, challenge)
            self.solve(team)
        instances = {
            (team, challenge): self.containers(team, challenge)
            for team in self.teams
            for challenge in BUNDLES
        }
        networks: set[str] = set()
        for (team, challenge), containers in instances.items():
            cloud = containers["localstack"]
            network_names = list(cloud.networks)
            self.assertEqual(len(network_names), 1)
            self.assertTrue(networks.isdisjoint(network_names))
            networks.update(network_names)
            network = json.loads(
                self.run_command(["docker", "network", "inspect", *network_names])
            )[0]
            self.assertTrue(network["Internal"])
            expected = (
                {"FLAG_CLOUD", "FLAG_PIPELINE"}
                if challenge == BUNDLES[0]
                else {"FLAG_STATE_CURRENT", "FLAG_STATE_PRIOR"}
            )
            flags = {
                entry.split("=", 1)[0]
                for item in containers.values()
                for entry in item.environment
                if entry.startswith("FLAG_")
            }
            self.assertEqual(flags, expected)
            for item in containers.values():
                self.assertFalse(any(entry.startswith("CTFD_") for entry in item.environment))
                self.assertFalse(item.bind_mounts)
                self.assertNotIn(item.user, {"", "0", "root", "0:0"})
                self.assertGreater(item.memory, 0)
            script = self.run_command(
                ["docker", "exec", cloud.id, "cat", "/etc/localstack/init/ready.d/10-seed.sh"]
            )
            foreign = "FLAG_STATE_" if challenge == BUNDLES[0] else "FLAG_CLOUD"
            self.assertNotIn(foreign, script)
            buckets = self.run_command(
                [
                    "docker",
                    "exec",
                    cloud.id,
                    "awslocal",
                    "s3api",
                    "list-buckets",
                    "--query",
                    "Buckets[].Name",
                    "--output",
                    "json",
                ]
            )
            self.assertEqual(
                "data-platform-tfstate" in json.loads(buckets), challenge == BUNDLES[1]
            )
            targets = []
            for key, other in instances.items():
                if key != (team, challenge):
                    targets.extend(endpoints(other, key[1]))
            self.run_command(["docker", "exec", cloud.id, "python3", "-c", PROBE, *targets])
        print(
            "PASS: separate networks, runtime seeds, flags, storage and blocked cross-bundle TCP",
            flush=True,
        )
        for containers in instances.values():
            self.run_command(
                [
                    "docker",
                    "exec",
                    containers["localstack"].id,
                    "awslocal",
                    "s3api",
                    "create-bucket",
                    "--bucket",
                    "isolation-marker",
                ]
            )
        target = (self.teams[0], BUNDLES[1])
        platform_ids = self.run_command([*self.platform, "ps", "-q"])
        self.bundle("reset", *target)
        for key, original in instances.items():
            current = self.containers(*key)
            buckets = json.loads(
                self.run_command(
                    [
                        "docker",
                        "exec",
                        current["localstack"].id,
                        "awslocal",
                        "s3api",
                        "list-buckets",
                        "--query",
                        "Buckets[].Name",
                        "--output",
                        "json",
                    ]
                )
            )
            if key == target:
                self.assertNotEqual(original["localstack"].id, current["localstack"].id)
                self.assertNotIn("isolation-marker", buckets)
            else:
                self.assertEqual(original["localstack"].id, current["localstack"].id)
                self.assertIn("isolation-marker", buckets)
        self.assertEqual(self.run_command([*self.platform, "ps", "-q"]), platform_ids)
        self.solve(self.teams[0])
        print(
            "PASS: reset erases only one bundle; siblings retain data; platform stays running",
            flush=True,
        )
        self.check_failed_seed(self.teams[0])


if __name__ == "__main__":
    unittest.main()
