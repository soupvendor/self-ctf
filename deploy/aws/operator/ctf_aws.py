import argparse
import fcntl
import json
import os
import re
import subprocess
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
TERRAFORM = ROOT / "deploy/aws/terraform"
TEAM_RESOURCES = {
    "aws_ecs_service.team",
    "aws_ecs_task_definition.team",
    "aws_iam_role.execution",
    "aws_iam_role_policy.execution",
    "aws_cloudwatch_log_group.team",
    "aws_security_group.team",
}
ENDPOINT_RESOURCES = {
    "aws_lb_target_group.team",
    "aws_lb_listener_rule.team",
    "aws_route53_record.team",
    "aws_vpc_security_group_egress_rule.alb_to_team",
}
SHARED_RESOURCES = {
    "aws_ecs_cluster.teams",
    "aws_security_group.alb[0]",
    "aws_lb.teams[0]",
    "aws_lb_listener.https[0]",
}


def run(args: list[str], *, content: str | None = None, capture: bool = True) -> str:
    result = subprocess.run(
        args,
        input=content,
        text=True,
        capture_output=capture,
        check=True,
        env={**os.environ, "AWS_IGNORE_CONFIGURED_ENDPOINT_URLS": "true", "AWS_PAGER": ""},
    )
    return result.stdout.strip() if capture else ""


def mapping(value: object) -> dict[str, object]:
    if not isinstance(value, dict) or not all(isinstance(key, str) for key in value):
        raise ValueError("Expected a JSON object")
    return dict(value)


def text(value: object) -> str:
    if not isinstance(value, str):
        raise ValueError("Expected a string")
    return value


def records(value: object) -> list[dict[str, object]]:
    if not isinstance(value, list):
        raise ValueError("Expected a JSON list")
    return [mapping(item) for item in value]


def output(root: str, name: str) -> dict[str, object]:
    return mapping(
        json.loads(run(["terraform", f"-chdir={TERRAFORM / root}", "output", "-json", name]))
    )


def aws(region: str, *args: str) -> dict[str, object]:
    return mapping(json.loads(run(["aws", "--region", region, "--output", "json", *args])))


def identity(account: str, region: str, deployment: dict[str, object], event: str) -> None:
    if deployment != {"account_id": account, "region": region, "event_name": event}:
        raise ValueError(
            "Selected Terraform state does not match the requested account/region/event"
        )
    if aws(region, "sts", "get-caller-identity")["Account"] != account:
        raise ValueError("AWS credentials belong to a different account")


def team_id(value: str) -> str:
    if not re.fullmatch(r"[a-z][a-z0-9-]{0,15}", value):
        raise ValueError("Invalid team ID")
    return value


def roster(path: Path) -> set[str]:
    value = mapping(json.loads(path.read_text()))
    if set(value) != {"team_ids"} or not isinstance(value["team_ids"], list):
        raise ValueError("Roster must contain only a team_ids list")
    teams = [team_id(text(item)) for item in value["team_ids"]]
    if len(teams) != len(set(teams)):
        raise ValueError("Duplicate team IDs in roster")
    return set(teams)


def validate_plan(
    plan: dict[str, object], team: str, operation: str, deployment: dict[str, object]
) -> None:
    outputs = mapping(mapping(plan["planned_values"])["outputs"])
    if mapping(outputs["deployment"])["value"] != deployment:
        raise ValueError("Plan account, region, or event does not match the foundation")
    if "prior_state" in plan:
        prior = mapping(mapping(plan["prior_state"])["values"])
        prior_outputs = mapping(prior["outputs"])
        resources = records(mapping(prior["root_module"]).get("resources", []))
        if (
            any(item["mode"] == "managed" for item in resources)
            and mapping(prior_outputs["deployment"])["value"] != deployment
        ):
            raise ValueError("Existing teams state belongs to a different deployment")
    allowed = {f'{resource}["{team}"]' for resource in TEAM_RESOURCES}
    allowed |= {
        f'{resource}["{team}/{service}"]'
        for resource in ENDPOINT_RESOURCES
        for service in ["gitea", "localstack"]
    }
    expected = ["create"] if operation == "create" else ["delete"]
    changed: set[str] = set()
    for resource in records(plan["resource_changes"]):
        change = mapping(resource["change"])
        actions = change["actions"]
        if actions == ["no-op"] or resource["mode"] == "data":
            continue
        address = text(resource["address"])
        shared = address in SHARED_RESOURCES or address.startswith(
            "aws_vpc_security_group_ingress_rule.vpn["
        )
        if operation == "create" and shared and actions == ["create"]:
            continue
        if address not in allowed or actions != expected:
            raise ValueError(f"Refusing unrelated or unexpected plan change: {address} {actions}")
        changed.add(address)
    if f'aws_ecs_service.team["{team}"]' not in changed:
        raise ValueError("Plan does not perform the requested team service operation")


def change_team(args: argparse.Namespace) -> None:
    with Path(args.roster).open("r+") as handle:
        fcntl.flock(handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
        apply_team_change(args)


def apply_team_change(args: argparse.Namespace) -> None:
    deployment = output("foundation", "deployment")
    identity(args.account, args.region, deployment, args.event)
    team = team_id(args.team)
    roster_path = Path(args.roster).resolve(strict=True)
    teams = roster(roster_path)
    if (team in teams) == (args.command == "create"):
        raise ValueError(
            "Team already exists in roster"
            if args.command == "create"
            else "Team is absent from roster"
        )
    desired = teams | {team} if args.command == "create" else teams - {team}
    rendered = json.dumps({"team_ids": sorted(desired)}, indent=2) + "\n"
    original = roster_path.read_text()
    with tempfile.TemporaryDirectory(prefix="self-ctf-team-plan-") as directory:
        candidate = Path(directory) / "roster.tfvars.json"
        candidate.write_text(rendered)
        plan_path = Path(directory) / "team.tfplan"
        tf = ["terraform", f"-chdir={TERRAFORM / 'teams'}"]
        run(
            [
                *tf,
                "plan",
                "-input=false",
                *[f"-var-file={Path(path).resolve(strict=True)}" for path in args.var_file],
                f"-var-file={candidate}",
                f"-out={plan_path}",
            ],
            capture=False,
        )
        plan = mapping(json.loads(run([*tf, "show", "-json", str(plan_path)])))
        validate_plan(plan, team, args.command, deployment)
        confirmation = f"{args.command} {deployment['event_name']}/{team}"
        if input(f"Type '{confirmation}' to apply this plan: ") != confirmation:
            raise ValueError("Cancelled; roster and AWS resources unchanged")
        if roster_path.read_text() != original:
            raise ValueError("Roster changed while planning; refusing to overwrite it")
        # Persist intended state before apply so a partial failure remains recoverable.
        roster_path.write_text(rendered)
        run([*tf, "apply", "-input=false", str(plan_path)], capture=False)


def service(args: argparse.Namespace) -> tuple[str, dict[str, object]]:
    deployment = output("teams", "deployment")
    identity(args.account, args.region, deployment, args.event)
    team = team_id(args.team)
    entry = mapping(output("teams", "teams")[team])
    definition = text(entry["task_definition_arn"])
    if not definition.startswith(f"arn:aws:ecs:{args.region}:{args.account}:task-definition/"):
        raise ValueError("Task definition is outside the selected account/region")
    cluster = f"{deployment['event_name']}-teams"
    result = aws(
        args.region,
        "ecs",
        "describe-services",
        "--cluster",
        cluster,
        "--services",
        text(entry["service_name"]),
    )
    services = records(result["services"])
    if result["failures"] or len(services) != 1 or services[0]["status"] != "ACTIVE":
        raise ValueError("Expected exactly one active ECS service")
    if services[0]["taskDefinition"] != definition:
        raise ValueError("ECS task definition drifted from Terraform; review before proceeding")
    return cluster, services[0]


def team_status(args: argparse.Namespace) -> None:
    cluster, current = service(args)
    print(
        json.dumps(
            {
                "cluster": cluster,
                "team": args.team,
                "desired": current["desiredCount"],
                "running": current["runningCount"],
                "pending": current["pendingCount"],
                "deployments": current["deployments"],
                "endpoints": output("teams", "team_endpoints").get(args.team),
            },
            indent=2,
        )
    )


def reset_team(args: argparse.Namespace) -> None:
    cluster, current = service(args)
    if current["desiredCount"] != 1 or len(records(current["deployments"])) != 1:
        raise ValueError("Reset requires a singleton service without a deployment in progress")
    if input(f"Type '{args.team}' to erase this team's challenge data: ") != args.team:
        raise ValueError("Cancelled")
    updated = aws(
        args.region,
        "ecs",
        "update-service",
        "--cluster",
        cluster,
        "--service",
        text(current["serviceName"]),
        "--force-new-deployment",
    )
    deployments = records(mapping(updated["service"])["deployments"])
    primary = [item for item in deployments if item["status"] == "PRIMARY"]
    if len(primary) != 1:
        raise ValueError(
            "Reset started but ECS did not return one primary deployment; inspect status"
        )
    expected_id = primary[0]["id"]
    run(
        [
            "aws",
            "--region",
            args.region,
            "ecs",
            "wait",
            "services-stable",
            "--cluster",
            cluster,
            "--services",
            text(current["serviceName"]),
        ]
    )
    _, final = service(args)
    finished = records(final["deployments"])
    if (
        len(finished) != 1
        or finished[0]["id"] != expected_id
        or finished[0]["rolloutState"] != "COMPLETED"
    ):
        raise ValueError("Requested reset did not complete successfully")
    print(f"Reset complete: {args.team}. CTFd progress was not changed.")


def runtime_images() -> dict[str, tuple[str, Path | None]]:
    images: dict[str, tuple[str, Path | None]] = {}
    for filename, names in [
        (ROOT / "compose.yaml", {"ctfd": "ctfd", "db": "mariadb", "cache": "redis"}),
        (ROOT / "challenges/secrets-all-the-way-down/compose.yaml", {"gitea": "gitea"}),
    ]:
        config = mapping(
            json.loads(
                run(
                    [
                        "docker",
                        "compose",
                        "--env-file",
                        "/dev/null",
                        "-f",
                        str(filename),
                        "config",
                        "--no-interpolate",
                        "--format",
                        "json",
                    ]
                )
            )
        )
        services = mapping(config["services"])
        for name, repository in names.items():
            source = text(mapping(services[name])["image"])
            if ":" not in source or source.endswith(":latest") or "$" in source:
                raise ValueError("Runtime image source must be pinned")
            images[repository] = (source, None)
    for name, directory in [("gitea-seed", "gitea-seed"), ("localstack-seeded", "localstack")]:
        images[name] = ("", ROOT / "challenges/secrets-all-the-way-down/runtime" / directory)
    return images


def publish_images(args: argparse.Namespace) -> None:
    deployment = output("foundation", "deployment")
    identity(args.account, args.region, deployment, args.event)
    if not re.fullmatch(r"[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}", args.tag):
        raise ValueError("Invalid release tag")
    destination = Path(args.output).resolve()
    if destination.exists():
        raise ValueError("Output file already exists; choose a new release manifest")
    if not destination.parent.is_dir():
        raise ValueError("Create the release manifest's parent directory before publishing")
    repositories = output("foundation", "ecr_repositories")
    sources = runtime_images()
    registry = f"{args.account}.dkr.ecr.{args.region}.amazonaws.com"
    targets = {}
    for name in sources:
        repository = mapping(repositories[name])
        url = text(repository["url"])
        if not url.startswith(registry + "/"):
            raise ValueError("ECR repository is outside the selected account/region")
        targets[name] = url + ":" + args.tag
    names = [target.removeprefix(registry + "/").rsplit(":", 1)[0] for target in targets.values()]
    remote = records(
        aws(args.region, "ecr", "describe-repositories", "--repository-names", *names)[
            "repositories"
        ]
    )
    if len(remote) != len(names) or any(
        item["imageTagMutability"] != "IMMUTABLE" for item in remote
    ):
        raise ValueError("Publishing requires immutable ECR repositories")
    with tempfile.TemporaryDirectory(prefix="self-ctf-ecr-login-") as directory:
        docker = ["docker", "--config", directory]
        password = run(["aws", "--region", args.region, "ecr", "get-login-password"])
        run([*docker, "login", "--username", "AWS", "--password-stdin", registry], content=password)
        for name, (source, context) in sources.items():
            if context is None:
                run([*docker, "pull", "--platform", "linux/amd64", source], capture=False)
                run([*docker, "tag", source, targets[name]])
            else:
                run(
                    [
                        *docker,
                        "build",
                        "--platform",
                        "linux/amd64",
                        "--tag",
                        targets[name],
                        str(context),
                    ],
                    capture=False,
                )
        run(
            ["bash", str(ROOT / "scripts/check-runtime-images.sh"), *targets.values()],
            capture=False,
        )
        manifest = {}
        for name, target in targets.items():
            run([*docker, "push", target], capture=False)
            repository_name = target.removeprefix(registry + "/").rsplit(":", 1)[0]
            result = aws(
                args.region,
                "ecr",
                "describe-images",
                "--repository-name",
                repository_name,
                "--image-ids",
                "imageTag=" + args.tag,
            )
            details = records(result["imageDetails"])
            if len(details) != 1 or not re.fullmatch(
                r"sha256:[a-f0-9]{64}", text(details[0]["imageDigest"])
            ):
                raise ValueError("ECR did not return one immutable digest")
            key = {"gitea-seed": "gitea_seed", "localstack-seeded": "localstack"}.get(name, name)
            manifest[key] = target.rsplit(":", 1)[0] + "@" + text(details[0]["imageDigest"])
        with destination.open("x") as handle:
            json.dump({"images": manifest}, handle, indent=2)
            handle.write("\n")
    print(f"Published runtime images; digest inputs written to {destination}")


def main() -> None:
    parser = argparse.ArgumentParser(
        description="AWS CTF operator commands; use your standard AWS profile."
    )
    parser.add_argument("--account", required=True)
    parser.add_argument("--region", required=True)
    parser.add_argument("--event", required=True)
    commands = parser.add_subparsers(dest="command", required=True)
    for name in ["create", "destroy", "reset", "status"]:
        command = commands.add_parser(name)
        command.add_argument("team")
        if name in {"create", "destroy"}:
            command.add_argument("--roster", required=True)
            command.add_argument("--var-file", action="append", required=True)
    publish = commands.add_parser("publish-images")
    publish.add_argument("--tag", required=True)
    publish.add_argument("--output", required=True)
    args = parser.parse_args()
    if not re.fullmatch(r"[0-9]{12}", args.account):
        parser.error("--account must be a 12-digit AWS account ID")
    functions = {
        "create": change_team,
        "destroy": change_team,
        "reset": reset_team,
        "status": team_status,
        "publish-images": publish_images,
    }
    functions[args.command](args)


if __name__ == "__main__":
    main()
