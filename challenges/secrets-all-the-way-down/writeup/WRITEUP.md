# Secrets All the Way Down

Three flags, one thread. Each stage hands over the credentials for the next, so
the order is forced by the challenge even though CTFd accepts the flags in any
order.

`writeup/exploit.sh` performs all three stages end to end and is wired in as the
challenge's healthcheck. It reads nothing from `.env` except the flags it
verifies — every endpoint and credential comes out of the previous stage, so a
broken handoff fails the build.

## Stage 1 — the layer that still has it

A Docker image is a stack of layers. Each records a filesystem *change*, and
layers are immutable once written. Deleting a file in a later layer does not edit
the earlier layer that created it — it only writes a whiteout marker saying "this
path is gone from here down".

The build did exactly that:

```dockerfile
COPY seed/deploy-creds.env /opt/deploy/creds.env   # layer A: secret written
RUN ...                                            # layer B: uses it
RUN rm -f /opt/deploy/creds.env                    # layer C: whiteout only
```

`docker run` shows nothing at `/opt/deploy/creds.env`, so the file looks gone.
Layer A still holds the bytes, and `docker save` exports every layer.

```bash
mkdir -p /tmp/solve && tar -xf internal-deployer.tar -C /tmp/solve
find /tmp/solve -type f -exec tar -xOf {} opt/deploy/creds.env \; 2>/dev/null
```

`DEPLOY_TOKEN` is flag 1. `docker history --no-trunc` shows the `rm`, and `dive`
browses layer A interactively — both reach the same place.

**The handoff:** the same file carries `CI_URL`, `CI_USER`, and `CI_PASS`. That
is the point of the hint "the file you recover is not just a flag".

## Stage 2 — the pipeline that says too much

Log into the Gitea instance at `CI_URL` as `deploy-bot`. The account owns one
private repository, `internal-deploy`, whose `.gitea/workflows/deploy.yml` holds:

- flag 2, echoed by the "Show deploy identity" step — a secret written into every
  build log
- `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, and `AWS_ENDPOINT_URL` in the
  workflow `env:` block, committed to version control because repo secrets were
  "not working"

Two separate failures worth naming: credentials in pipeline config, and
credentials echoed into build output. The second is the one people forget.

**The handoff:** those AWS credentials and that endpoint are the only route into
stage 3.

## Stage 3 — a break-glass secret nobody scoped

Point the AWS CLI at the endpoint from the workflow and enumerate. The flag sits
in Secrets Manager under a deliberately non-obvious name among decoys, so listing
has to happen before reading.

```bash
export AWS_ACCESS_KEY_ID=... AWS_SECRET_ACCESS_KEY=... AWS_DEFAULT_REGION=us-east-1
EP="--endpoint-url http://<challenge-host>:4566"

aws $EP sts get-caller-identity
aws $EP ssm get-parameter --name /platform/notes/ops-todo      # breadcrumb
aws $EP secretsmanager list-secrets --query 'SecretList[].Name'
aws $EP secretsmanager get-secret-value \
  --secret-id platform/break-glass/root-recovery \
  --query SecretString --output text
```

The SSM parameter is a nudge for anyone who does not think to list Secrets
Manager.

## The real-world lessons

- Squashing or multi-stage builds remove the layer; `RUN --mount=type=secret`
  never creates one. Deleting the file afterwards is not a fix, and an image
  published this way should be treated as leaked.
- A secret in pipeline config is a secret in every clone and every fork, and one
  echoed to a log is a secret in every log sink downstream.
- A deploy identity that can *list* a secret store can read everything it was
  never scoped away from. Break-glass credentials are the ones most likely to
  predate whatever scoping arrived later.

## Notes for the organizer

**LocalStack Community does not enforce IAM.** Any credentials, including empty
ones, can call any enabled service. Stage 3 is therefore an enumeration and
discovery exercise, not a privilege-escalation one. A genuine scoped-credentials
version needs `ENFORCE_IAM=1` on LocalStack Pro.

This has one consequence worth knowing: a player who finds the LocalStack port
without doing stages 1 and 2 can read the secret directly. It costs them nothing
and gains them nothing — `logic: all` means the challenge only completes with all
three flags, and the other two still require the real chain. The endpoint is
deliberately absent from the challenge description for the same reason.

**Unintended path to close:** the repository this challenge is built from is
public. Nothing in it unlocks a live instance, because flags are generated per
deployment, but the method is readable. That is a deliberate, accepted trade —
see the honour-system note in the project README.
