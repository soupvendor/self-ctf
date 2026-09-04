# Seed fixtures — planted vulnerabilities live here

Maintainer notes. The player-facing artifact receives only the rendered deploy
credentials. Runtime seeders have allowlisted build contexts under `runtime/`,
so no rendered flag file can enter a reusable image.

These notes are not in the files they describe because two of those files ship
to players verbatim: a `PLANTED VULNERABILITY` banner inside `repo/` would sit
in the repository players are meant to search, and hand them the answer.

## `runtime/gitea-seed/repo/.gitea/workflows/deploy.yml.template` — stage 2

**The flaw, deliberately:** pipeline credentials committed to version control,
plus a step that echoes a secret into the build log. Do not move them to repo
secrets, and do not remove the `echo`.

The `NOTE(ops)` comment is in-fiction and doubles as the nudge for players. The
AWS credentials are the only route into stage 3.

## `runtime/localstack/seed.sh` — stage 3

**The flaw, deliberately:** a break-glass secret readable by an ordinary deploy
identity, with an SSM parameter pointing at it. Do not scope the credentials.

LocalStack Community does not enforce IAM at all, so this stage is enumeration —
list before you can read — rather than privilege escalation. Scoping the deploy
identity would need LocalStack Pro and would not change what players do.

## Runtime injection

The Gitea seeder replaces explicit placeholders while the container runs. The
LocalStack init hook reads its flag from the task environment. Neither flag is a
Docker build argument, copied file, image environment variable, or image layer.
