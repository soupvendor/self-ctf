import argparse
import contextlib
import io
import json
import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

import ctf_aws as operator

DEPLOYMENT: dict[str, object] = {
    "account_id": "123456789012",
    "region": "us-east-1",
    "event_name": "test-event",
}
REGISTRY = "123456789012.dkr.ecr.us-east-1.amazonaws.com"
DEFINITION = "arn:aws:ecs:us-east-1:123456789012:task-definition/test-event-red:1"


def change(address: str, action: str) -> dict[str, object]:
    return {"address": address, "mode": "managed", "change": {"actions": [action]}}


def plan(*changes: dict[str, object]) -> dict[str, object]:
    return {
        "planned_values": {"outputs": {"deployment": {"value": DEPLOYMENT}}},
        "resource_changes": list(changes),
    }


class OperatorTests(unittest.TestCase):
    def setUp(self) -> None:
        directory = tempfile.TemporaryDirectory(prefix="self-ctf-operator-test-")
        self.addCleanup(directory.cleanup)
        self.directory = Path(directory.name)
        self.roster = self.directory / "roster.tfvars.json"
        self.roster.write_text('{"team_ids": []}')
        self.variables = self.directory / "event.tfvars"
        self.variables.touch()
        self.args = argparse.Namespace(
            account="123456789012",
            region="us-east-1",
            event="test-event",
            command="create",
            team="red",
            roster=str(self.roster),
            var_file=[str(self.variables)],
            tag="test-release",
            output=str(self.directory / "images.tfvars.json"),
        )
        self.service = {
            "serviceName": "red",
            "status": "ACTIVE",
            "taskDefinition": DEFINITION,
            "desiredCount": 1,
            "runningCount": 1,
            "pendingCount": 0,
            "deployments": [{"id": "old", "status": "PRIMARY", "rolloutState": "COMPLETED"}],
        }

    def test_identity_rejects_wrong_account(self) -> None:
        with (
            patch.object(operator, "aws", return_value={"Account": "999999999999"}),
            self.assertRaisesRegex(ValueError, "credentials"),
        ):
            operator.identity(self.args.account, self.args.region, DEPLOYMENT, self.args.event)

    def test_identity_rejects_wrong_event_before_aws(self) -> None:
        with (
            patch.object(operator, "aws") as aws,
            self.assertRaisesRegex(ValueError, "account/region/event"),
        ):
            operator.identity(self.args.account, self.args.region, DEPLOYMENT, "other-event")
        aws.assert_not_called()

    def test_single_team_plan_accepts_initial_shared_resources(self) -> None:
        operator.validate_plan(
            plan(
                change('aws_ecs_service.team["red"]', "create"),
                change('aws_route53_record.team["red/gitea"]', "create"),
                change("aws_lb.teams[0]", "create"),
            ),
            "red",
            "create",
            DEPLOYMENT,
        )

    def test_single_team_destroy_plan(self) -> None:
        operator.validate_plan(
            plan(
                change('aws_ecs_service.team["red"]', "delete"),
                change('aws_route53_record.team["red/localstack"]', "delete"),
            ),
            "red",
            "destroy",
            DEPLOYMENT,
        )

    def test_plan_rejects_other_team_and_shared_destruction(self) -> None:
        for address in ['aws_ecs_service.team["blue"]', "aws_lb.teams[0]", "aws_instance.platform"]:
            with self.subTest(address=address), self.assertRaisesRegex(ValueError, "unrelated"):
                operator.validate_plan(
                    plan(
                        change('aws_ecs_service.team["red"]', "delete"),
                        change(address, "delete"),
                    ),
                    "red",
                    "destroy",
                    DEPLOYMENT,
                )

    def test_plan_rejects_updates_during_create(self) -> None:
        with self.assertRaisesRegex(ValueError, "unrelated"):
            operator.validate_plan(
                plan(change('aws_ecs_service.team["red"]', "update")), "red", "create", DEPLOYMENT
            )

    def test_plan_rejects_missing_service_change(self) -> None:
        with self.assertRaisesRegex(ValueError, "requested team"):
            operator.validate_plan(plan(), "red", "create", DEPLOYMENT)

    def test_plan_rejects_wrong_prior_state(self) -> None:
        candidate = plan(change('aws_ecs_service.team["red"]', "delete"))
        candidate["prior_state"] = {
            "values": {
                "outputs": {"deployment": {"value": {**DEPLOYMENT, "event_name": "other-event"}}},
                "root_module": {"resources": [{"mode": "managed"}]},
            }
        }
        with self.assertRaisesRegex(ValueError, "different deployment"):
            operator.validate_plan(candidate, "red", "destroy", DEPLOYMENT)

    def test_roster_rejects_duplicates_unknown_fields_and_bad_ids(self) -> None:
        for value in [
            {"team_ids": ["red", "red"]},
            {"team_ids": ["../red"]},
            {"team_ids": [], "images": {}},
        ]:
            with self.subTest(value=value):
                self.roster.write_text(json.dumps(value))
                with self.assertRaises(ValueError):
                    operator.roster(self.roster)

    def run_create(self, answer: str, *, fail_apply: bool = False) -> list[list[str]]:
        calls: list[list[str]] = []

        def run(args: list[str], *, capture: bool = True) -> str:
            calls.append(args)
            if "show" in args:
                return json.dumps(plan(change('aws_ecs_service.team["red"]', "create")))
            if "apply" in args:
                self.assertEqual(operator.roster(self.roster), {"red"})
                if fail_apply:
                    raise subprocess.CalledProcessError(1, args)
            return ""

        with (
            patch.object(operator, "output", return_value=DEPLOYMENT),
            patch.object(operator, "aws", return_value={"Account": self.args.account}),
            patch.object(operator, "run", side_effect=run),
            patch("builtins.input", return_value=answer),
        ):
            operator.change_team(self.args)
        return calls

    def test_create_applies_exact_reviewed_plan_and_persists_roster(self) -> None:
        calls = self.run_create("create test-event/red")
        planned = next(args for args in calls if "plan" in args)
        applied = next(args for args in calls if "apply" in args)
        self.assertEqual(applied[-1], planned[-1].removeprefix("-out="))
        self.assertNotIn("-auto-approve", applied)
        self.assertEqual(operator.roster(self.roster), {"red"})

    def test_cancel_preserves_roster(self) -> None:
        with self.assertRaisesRegex(ValueError, "Cancelled"):
            self.run_create("no")
        self.assertEqual(operator.roster(self.roster), set())

    def test_apply_failure_retains_intended_roster(self) -> None:
        with self.assertRaises(subprocess.CalledProcessError):
            self.run_create("create test-event/red", fail_apply=True)
        self.assertEqual(operator.roster(self.roster), {"red"})

    def test_service_rejects_task_definition_drift(self) -> None:
        def output(root: str, name: str) -> dict[str, object]:
            return (
                DEPLOYMENT
                if name == "deployment"
                else {"red": {"task_definition_arn": DEFINITION, "service_name": "red"}}
            )

        with (
            patch.object(operator, "output", side_effect=output),
            patch.object(
                operator,
                "aws",
                side_effect=[
                    {"Account": self.args.account},
                    {
                        "failures": [],
                        "services": [{**self.service, "taskDefinition": DEFINITION[:-1] + "2"}],
                    },
                ],
            ),
            self.assertRaisesRegex(ValueError, "drifted"),
        ):
            operator.service(self.args)

    def test_reset_verifies_new_deployment(self) -> None:
        final = {
            **self.service,
            "deployments": [{"id": "new", "status": "PRIMARY", "rolloutState": "COMPLETED"}],
        }
        with (
            patch.object(
                operator,
                "service",
                side_effect=[("test-event-teams", self.service), ("test-event-teams", final)],
            ),
            patch.object(operator, "aws", return_value={"service": final}) as aws,
            patch.object(operator, "run") as run,
            patch("builtins.input", return_value="red"),
            contextlib.redirect_stdout(io.StringIO()),
        ):
            operator.reset_team(self.args)
        self.assertIn("--force-new-deployment", aws.call_args.args)
        self.assertIn("services-stable", run.call_args.args[0])

    def test_reset_rejects_rollback_even_if_waiter_succeeds(self) -> None:
        primary = {**self.service, "deployments": [{"id": "new", "status": "PRIMARY"}]}
        with (
            patch.object(operator, "service", return_value=("test-event-teams", self.service)),
            patch.object(operator, "aws", return_value={"service": primary}),
            patch.object(operator, "run"),
            patch("builtins.input", return_value="red"),
            self.assertRaisesRegex(ValueError, "did not complete"),
        ):
            operator.reset_team(self.args)

    def test_reset_cancel_does_not_mutate(self) -> None:
        with (
            patch.object(operator, "service", return_value=("test-event-teams", self.service)),
            patch.object(operator, "aws") as aws,
            patch("builtins.input", return_value="no"),
            self.assertRaisesRegex(ValueError, "Cancelled"),
        ):
            operator.reset_team(self.args)
        aws.assert_not_called()

    def test_aws_endpoint_overrides_are_disabled(self) -> None:
        with patch(
            "subprocess.run", return_value=subprocess.CompletedProcess([], 0, stdout="{}")
        ) as run:
            operator.aws("us-east-1", "sts", "get-caller-identity")
        self.assertEqual(run.call_args.kwargs["env"]["AWS_IGNORE_CONFIGURED_ENDPOINT_URLS"], "true")

    def test_runtime_sources_use_existing_compose_contract(self) -> None:
        images = operator.runtime_images()
        self.assertEqual(
            set(images), {"ctfd", "mariadb", "redis", "gitea", "gitea-seed", "localstack-seeded"}
        )
        self.assertEqual(images["gitea"][0], "gitea/gitea:1.27.1-rootless")
        self.assertEqual(
            images["gitea-seed"][1],
            operator.ROOT / "challenges/secrets-all-the-way-down/runtime/gitea-seed",
        )

    def test_publish_scans_before_push_and_writes_digest_manifest(self) -> None:
        names = ["ctfd", "mariadb", "redis", "gitea", "gitea-seed", "localstack-seeded"]
        repositories = {name: {"url": f"{REGISTRY}/test-event/{name}"} for name in names}
        sources: dict[str, tuple[str, Path | None]] = {name: ("example:1", None) for name in names}
        sources["gitea-seed"] = ("", self.directory)

        def aws(region: str, *args: str) -> dict[str, object]:
            if args[0] == "sts":
                return {"Account": self.args.account}
            if args[1] == "describe-repositories":
                return {"repositories": [{"imageTagMutability": "IMMUTABLE"} for _ in names]}
            return {"imageDetails": [{"imageDigest": "sha256:" + "a" * 64}]}

        with (
            patch.object(operator, "output", side_effect=[DEPLOYMENT, repositories]),
            patch.object(operator, "runtime_images", return_value=sources),
            patch.object(operator, "aws", side_effect=aws),
            patch.object(operator, "run", return_value="temporary-registry-token") as run,
            contextlib.redirect_stdout(io.StringIO()),
        ):
            operator.publish_images(self.args)
        calls = [call.args[0] for call in run.call_args_list]
        scan = next(i for i, args in enumerate(calls) if args[0] == "bash")
        self.assertTrue(all(i > scan for i, args in enumerate(calls) if "push" in args))
        self.assertTrue(all("temporary-registry-token" not in args for args in calls))
        login = next(call for call in run.call_args_list if "login" in call.args[0])
        self.assertEqual(login.kwargs["content"], "temporary-registry-token")
        manifest = json.loads(Path(self.args.output).read_text())
        self.assertEqual(
            set(manifest["images"]),
            {"ctfd", "mariadb", "redis", "gitea", "gitea_seed", "localstack"},
        )
        self.assertTrue(all("@sha256:" in value for value in manifest["images"].values()))

    def test_publish_rejects_existing_manifest_or_missing_parent_before_build(self) -> None:
        existing = self.directory / "existing.tfvars.json"
        existing.write_text("keep this release")
        for destination in [existing, self.directory / "missing" / "images.tfvars.json"]:
            with (
                self.subTest(destination=destination),
                patch.object(operator, "output", return_value=DEPLOYMENT),
                patch.object(operator, "identity"),
                patch.object(operator, "runtime_images") as sources,
                self.assertRaises(ValueError),
            ):
                self.args.output = str(destination)
                operator.publish_images(self.args)
            sources.assert_not_called()
        self.assertEqual(existing.read_text(), "keep this release")

    def test_publish_rejects_mutable_repository_before_login(self) -> None:
        with (
            patch.object(
                operator,
                "output",
                side_effect=[DEPLOYMENT, {"ctfd": {"url": f"{REGISTRY}/test-event/ctfd"}}],
            ),
            patch.object(operator, "identity"),
            patch.object(operator, "runtime_images", return_value={"ctfd": ("example:1", None)}),
            patch.object(
                operator,
                "aws",
                return_value={"repositories": [{"imageTagMutability": "MUTABLE"}]},
            ),
            patch.object(operator, "run") as run,
            self.assertRaisesRegex(ValueError, "immutable"),
        ):
            operator.publish_images(self.args)
        run.assert_not_called()

    def test_failed_scan_prevents_every_push(self) -> None:
        calls: list[list[str]] = []

        def run(args: list[str], *, content: str | None = None, capture: bool = True) -> str:
            calls.append(args)
            if args[0] == "bash":
                raise subprocess.CalledProcessError(1, args)
            return ""

        with (
            patch.object(
                operator,
                "output",
                side_effect=[DEPLOYMENT, {"ctfd": {"url": f"{REGISTRY}/test-event/ctfd"}}],
            ),
            patch.object(operator, "identity"),
            patch.object(operator, "runtime_images", return_value={"ctfd": ("example:1", None)}),
            patch.object(
                operator,
                "aws",
                return_value={"repositories": [{"imageTagMutability": "IMMUTABLE"}]},
            ),
            patch.object(operator, "run", side_effect=run),
            self.assertRaises(subprocess.CalledProcessError),
        ):
            operator.publish_images(self.args)
        self.assertFalse(any("push" in args for args in calls))
        self.assertFalse(Path(self.args.output).exists())


if __name__ == "__main__":
    unittest.main()
