import json
import os
import secrets
import shutil
import subprocess
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
RUNTIME = ROOT / "deploy/aws/platform"


def run(args: list[str], environment: dict[str, str], content: str | None = None) -> str:
    result = subprocess.run(
        args, env=environment, input=content, text=True, capture_output=True, check=False
    )
    if result.returncode:
        raise RuntimeError(f"{args[0]} failed ({result.returncode}):\n{result.stderr}")
    return result.stdout.strip()


def compose(environment: dict[str, str], *args: str, content: str | None = None) -> str:
    return run([str(RUNTIME / "compose.sh"), *args], environment, content)


def sql(environment: dict[str, str], query: str) -> str:
    return compose(
        environment,
        "exec",
        "-T",
        "db",
        "sh",
        "-c",
        'mariadb --batch --skip-column-names -u"$MARIADB_USER" '
        '-p"$MARIADB_PASSWORD" "$MARIADB_DATABASE"',
        content=query,
    )


def main() -> None:
    directory = Path(tempfile.mkdtemp(prefix="self-ctf-restore-test-"))
    config_dir = directory / "config"
    run_dir = directory / "run"
    source_dir = directory / "source"
    restore_dir = directory / "restored"
    for path in [config_dir, run_dir, source_dir, restore_dir]:
        path.mkdir()
    for volume in ["ctfd-db", "ctfd-uploads", "ctfd-logs", "ctfd-cache"]:
        (source_dir / volume).mkdir()
    environment = {
        **os.environ,
        "CTFD_DB_PASSWORD": secrets.token_hex(32),
        "CTFD_SECRET_KEY": secrets.token_hex(32),
        "CTFD_PORT": "127.0.0.1:0",
        "PLATFORM_DATA_DIR": str(source_dir),
        "CTFD_CONFIG_FILE": str(run_dir / "ctfd.ini"),
        "SELF_CTF_CONFIG_DIR": str(config_dir),
        "SELF_CTF_RUN_DIR": str(run_dir),
        "SELF_CTF_LIB_DIR": str(RUNTIME),
        "SELF_CTF_PROJECT_NAME": directory.name,
    }
    definition = json.loads(
        run(
            ["docker", "compose", "-f", str(ROOT / "compose.yaml"), "config", "--format", "json"],
            environment,
        )
    )
    images: dict[str, str] = {
        name: definition["services"][name]["image"] for name in ["ctfd", "db", "cache"]
    }
    environment.update(
        CTFD_IMAGE=images["ctfd"], MARIADB_IMAGE=images["db"], REDIS_IMAGE=images["cache"]
    )
    for image in images.values():
        run(["docker", "pull", image], environment)
    shutil.copyfile(ROOT / "compose.yaml", config_dir / "compose.yaml")
    shutil.copyfile(RUNTIME / "compose.aws.yaml", config_dir / "compose.aws.yaml")
    (config_dir / "images.env").touch()
    (run_dir / "platform.env").touch(mode=0o600)
    configured = run(
        [
            "docker",
            "run",
            "--rm",
            "-i",
            "--network",
            "none",
            "--entrypoint",
            "python",
            images["ctfd"],
            "-",
        ],
        environment,
        (RUNTIME / "configure_ctfd.py").read_text(),
    )
    (run_dir / "ctfd.ini").write_text(configured)
    restored_environment = {
        **environment,
        "PLATFORM_DATA_DIR": str(restore_dir),
        "SELF_CTF_PROJECT_NAME": directory.name + "-restored",
    }
    try:
        compose(environment, "up", "-d", "--wait", "--wait-timeout", "240")
        actual_config = compose(
            environment,
            "exec",
            "-T",
            "ctfd",
            "python",
            "-c",
            "from CTFd.config import Config; "
            "print(Config.SESSION_COOKIE_SECURE, Config.SESSION_COOKIE_HTTPONLY, "
            "Config.SESSION_COOKIE_SAMESITE)",
        )
        if actual_config != "True True Lax":
            raise RuntimeError("CTFd did not load secure cookie settings")
        sql(
            environment,
            "CREATE TABLE backup_probe (marker varchar(32));\n"
            "INSERT INTO backup_probe VALUES ('persisted');\n",
        )
        compose(
            environment,
            "exec",
            "-T",
            "ctfd",
            "python",
            "-c",
            "from pathlib import Path; "
            "Path('/var/uploads/backup-probe.txt').write_text('persisted')",
        )
        run([str(RUNTIME / "stop.sh")], environment)
        run(
            [
                "docker",
                "run",
                "--rm",
                "--network",
                "none",
                "--user",
                "0:0",
                "--mount",
                f"type=bind,src={source_dir},dst=/source,readonly",
                "--mount",
                f"type=bind,src={restore_dir},dst=/restore",
                "--entrypoint",
                "cp",
                images["db"],
                "-a",
                "/source/.",
                "/restore/",
            ],
            environment,
        )
        compose(restored_environment, "up", "-d", "--wait", "--wait-timeout", "240")
        if sql(restored_environment, "SELECT marker FROM backup_probe;\n") != "persisted":
            raise RuntimeError("Database state was not restored")
        upload = compose(
            restored_environment,
            "exec",
            "-T",
            "ctfd",
            "python",
            "-c",
            "from pathlib import Path; print(Path('/var/uploads/backup-probe.txt').read_text())",
        )
        if upload != "persisted":
            raise RuntimeError("Uploads were not restored")
        run([str(RUNTIME / "stop.sh")], restored_environment)
        print("Platform restore passed: secure cookies, clean shutdown, database, and uploads.")
    except RuntimeError:
        print(compose(environment, "logs", "--no-color", "--tail", "60", "ctfd"))
        print(compose(restored_environment, "logs", "--no-color", "--tail", "60", "ctfd"))
        raise
    finally:
        compose(environment, "down")
        compose(restored_environment, "down")
        print(f"Test containers stopped; fixture data and volumes retained at {directory}")


if __name__ == "__main__":
    main()
