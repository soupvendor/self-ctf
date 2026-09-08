import configparser
import contextlib
import io
import os
import runpy
import stat
import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest.mock import mock_open, patch

RUNTIME = Path(__file__).resolve().parents[1]
EXECUTION_ID = "00000000-0000-0000-0000-000000000001"
PLATFORM_ARN = "arn:aws:secretsmanager:us-east-1:123456789012:secret:ctf/platform-000001"


class HostTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory(prefix="self-ctf-host-test-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.run_dir = self.root / "run"
        self.data_dir = self.root / "data"
        self.bin_dir = self.root / "bin"
        for directory in [self.run_dir, self.data_dir, self.bin_dir]:
            directory.mkdir()
        for name in ["aws", "docker", "systemctl", "mountpoint", "sync"]:
            (self.bin_dir / name).symlink_to(RUNTIME / "tests" / "command_stub.py")
        self.calls_file = self.root / "calls"
        self.calls_file.touch()
        self.environment = {
            **os.environ,
            "PATH": str(self.bin_dir) + os.pathsep + os.environ["PATH"],
            "AWS_REGION": "us-east-1",
            "PLATFORM_SECRET_ARN": PLATFORM_ARN,
            "ECR_REGISTRY": "123456789012.dkr.ecr.us-east-1.amazonaws.com",
            "CTFD_IMAGE": "example-runtime",
            "DOCKER_CONFIG": str(self.run_dir / "docker"),
            "SELF_CTF_RUN_DIR": str(self.run_dir),
            "SELF_CTF_PROJECT_NAME": "self-ctf-unit-test",
            "SELF_CTF_BACKUP_DIR": str(self.run_dir),
            "SELF_CTF_LIB_DIR": str(RUNTIME),
            "SELF_CTF_CONFIG_DIR": str(self.root / "config"),
            "PLATFORM_DATA_DIR": str(self.data_dir),
            "MOCK_CALLS": str(self.calls_file),
            "MOCK_VERSION": EXECUTION_ID,
            "MOCK_SECRET": "CTFD_DB_PASSWORD=" + "a" * 64 + "\nCTFD_SECRET_KEY=" + "b" * 64,
        }

    def script(self, name: str, *args: str) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            ["bash", str(RUNTIME / name), *args],
            env=self.environment,
            capture_output=True,
            text=True,
            check=False,
        )

    def calls(self) -> str:
        return self.calls_file.read_text()

    def test_start_pins_secret_and_keeps_credentials_private(self) -> None:
        result = self.script("start.sh")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(
            (self.data_dir / "platform-secret-version").read_text(),
            PLATFORM_ARN + "\n" + EXECUTION_ID + "\n",
        )
        self.assertEqual(stat.S_IMODE((self.run_dir / "platform.env").stat().st_mode), 0o600)
        self.assertIn("--version-id " + EXECUTION_ID, self.calls())
        self.assertIn("up -d --wait", self.calls())
        self.assertNotIn("a" * 64, result.stdout + result.stderr)

    def test_restored_host_uses_original_secret_version(self) -> None:
        (self.data_dir / "platform-secret-version").write_text(PLATFORM_ARN + "\n" + EXECUTION_ID)
        self.environment["MOCK_VERSION"] = "00000000-0000-0000-0000-000000000002"
        result = self.script("start.sh")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn("--query VersionId", self.calls())
        self.assertIn("--version-id " + EXECUTION_ID, self.calls())

    def test_restore_rejects_different_secret(self) -> None:
        (self.data_dir / "platform-secret-version").write_text("different-secret\n" + EXECUTION_ID)
        self.assertNotEqual(self.script("start.sh").returncode, 0)
        self.assertNotIn("aws ", self.calls())

    def test_missing_disk_prevents_start(self) -> None:
        self.environment["MOCK_MISSING_MOUNT"] = "1"
        self.assertNotEqual(self.script("start.sh").returncode, 0)
        self.assertNotIn("aws ", self.calls())
        self.assertNotIn("docker ", self.calls())

    def test_incomplete_secret_prevents_start(self) -> None:
        self.environment["MOCK_SECRET"] = "CTFD_SECRET_KEY=" + "a" * 64
        self.assertNotEqual(self.script("start.sh").returncode, 0)
        self.assertNotIn("docker ", self.calls())

    def test_extra_secret_key_prevents_start(self) -> None:
        self.environment["MOCK_SECRET"] += "\nCTFD_ADMIN_PASSWORD=unwanted"
        self.assertNotEqual(self.script("start.sh").returncode, 0)
        self.assertNotIn("docker ", self.calls())

    def test_duplicate_secret_key_prevents_start(self) -> None:
        self.environment["MOCK_SECRET"] += "\nCTFD_SECRET_KEY=" + "b" * 64
        self.assertNotEqual(self.script("start.sh").returncode, 0)
        self.assertNotIn("docker ", self.calls())

    def test_non_hex_secret_prevents_start_without_logging_value(self) -> None:
        malformed_value = "not-a-valid-database-password"
        self.environment["MOCK_SECRET"] = "CTFD_SECRET_KEY=" + malformed_value
        result = self.script("start.sh")
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn(malformed_value, result.stdout + result.stderr)
        self.assertNotIn("docker ", self.calls())

    def test_clean_stop_flushes_disk(self) -> None:
        result = self.script("stop.sh")
        self.assertEqual(result.returncode, 0, result.stderr)
        for name in ["ctfd", "db", "cache"]:
            self.assertIn(name + "-container", self.calls())
        self.assertIn("sync -f " + str(self.data_dir), self.calls())

    def test_forced_container_exit_blocks_snapshot(self) -> None:
        self.environment["MOCK_CONTAINER_EXIT"] = "137"
        self.assertNotEqual(self.script("stop.sh").returncode, 0)
        self.assertNotIn("sync ", self.calls())

    def test_backup_stops_and_resumes_matching_execution(self) -> None:
        pre = self.script("backup.sh", "pre-script", EXECUTION_ID)
        self.assertEqual(pre.returncode, 0, pre.stderr)
        marker = self.run_dir / "self-ctf-backup"
        self.assertEqual(marker.read_text(), EXECUTION_ID + "\n")
        post = self.script("backup.sh", "post-script", EXECUTION_ID)
        self.assertEqual(post.returncode, 0, post.stderr)
        self.assertFalse(marker.exists())
        self.assertIn("systemctl stop self-ctf.service", self.calls())
        self.assertIn("systemctl start self-ctf.service", self.calls())

    def test_backup_does_not_restart_an_unrelated_execution(self) -> None:
        (self.run_dir / "self-ctf-backup").write_text("different-execution")
        self.assertNotEqual(self.script("backup.sh", "post-script", EXECUTION_ID).returncode, 0)
        self.assertNotIn("systemctl start", self.calls())

    def test_backup_failure_restores_service_but_still_fails(self) -> None:
        self.environment["MOCK_STOP_FAIL"] = "1"
        self.assertNotEqual(self.script("backup.sh", "pre-script", EXECUTION_ID).returncode, 0)
        self.assertIn("systemctl start self-ctf.service", self.calls())
        self.assertFalse((self.run_dir / "self-ctf-backup").exists())

    def test_backup_respects_operator_maintenance(self) -> None:
        self.environment["MOCK_INACTIVE"] = "1"
        self.assertNotEqual(self.script("backup.sh", "pre-script", EXECUTION_ID).returncode, 0)
        self.assertNotIn("systemctl start", self.calls())
        self.assertNotIn("systemctl stop", self.calls())

    def test_failed_stop_result_blocks_snapshot_even_if_job_returns_zero(self) -> None:
        self.environment["MOCK_STOP_RESULT"] = "exit-code"
        self.assertNotEqual(self.script("backup.sh", "pre-script", EXECUTION_ID).returncode, 0)
        self.assertIn("systemctl start self-ctf.service", self.calls())
        self.assertFalse((self.run_dir / "self-ctf-backup").exists())

    def test_failed_resume_retains_recovery_marker(self) -> None:
        (self.run_dir / "self-ctf-backup").write_text(EXECUTION_ID)
        self.environment["MOCK_START_FAIL"] = "1"
        self.assertNotEqual(self.script("backup.sh", "post-script", EXECUTION_ID).returncode, 0)
        self.assertTrue((self.run_dir / "self-ctf-backup").exists())

    def test_backup_dry_run_uses_document_defaults(self) -> None:
        result = self.script("backup.sh", "dry-run", "None")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn("systemctl stop", self.calls())

    def test_backup_rejects_invalid_execution(self) -> None:
        self.assertNotEqual(self.script("backup.sh", "pre-script", "not-a-uuid").returncode, 0)
        self.assertEqual(self.calls(), "")

    def test_storage_rejects_missing_device(self) -> None:
        self.environment.update(
            DATA_DEVICE=str(self.root / "missing"), INITIALIZE_NEW_VOLUME="true"
        )
        self.assertNotEqual(self.script("storage.sh").returncode, 0)

    def test_secure_ctfd_config_uses_supported_extra_section(self) -> None:
        output = io.StringIO()
        source = "[server]\nSECRET_KEY =\n[security]\n[extra]\n"
        with (
            patch("builtins.open", mock_open(read_data=source)),
            contextlib.redirect_stdout(output),
        ):
            runpy.run_path(str(RUNTIME / "configure_ctfd.py"))
        result = configparser.ConfigParser()
        result.read_string(output.getvalue())
        self.assertEqual(result.get("extra", "SESSION_COOKIE_SECURE"), "")
        self.assertTrue(result.getboolean("security", "SESSION_COOKIE_HTTPONLY"))
        self.assertEqual(result.get("security", "SESSION_COOKIE_SAMESITE"), "Lax")
        self.assertEqual(result.get("server", "SECRET_KEY"), "")


if __name__ == "__main__":
    unittest.main()
