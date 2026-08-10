# Seed fixtures — planted vulnerabilities live here

Maintainer notes. Excluded from the Docker build context, and only `repo/` is
ever copied into Gitea, so nothing here reaches a player except by way of the
challenge itself.

These notes are not in the files they describe because two of those files ship
to players verbatim: a `PLANTED VULNERABILITY` banner inside `repo/` would sit
in the repository players are meant to search, and hand them the answer.

## `repo/.gitea/workflows/deploy.yml` — stage 2

**The flaw, deliberately:** pipeline credentials committed to version control,
plus a step that echoes a secret into the build log. Do not move them to repo
secrets, and do not remove the `echo`.

The `NOTE(ops)` comment is in-fiction and doubles as the nudge for players. The
AWS credentials are the only route into stage 3.

## `localstack-seed.sh` — stage 3

**The flaw, deliberately:** a break-glass secret readable by an ordinary deploy
identity, with an SSM parameter pointing at it. Do not scope the credentials.

LocalStack Community does not enforce IAM at all, so this stage is enumeration —
list before you can read — rather than privilege escalation. Scoping the deploy
identity would need LocalStack Pro and would not change what players do.

## Templating

`$` is significant in `*.tmpl`: `scripts/render.py` substitutes `${VAR}` from
`.env`, so a literal dollar has to be written `$$`. That is why `deploy.yml.tmpl`
doubles the dollars in its shell snippets — they must survive into the file
players read.
