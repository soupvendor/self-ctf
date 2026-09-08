# self-ctf

An in-development, self-hosted CTF for practical DevOps and cloud security
training. [CTFd](https://ctfd.io/) provides accounts, teams, scoring, and flag
submission; intentionally vulnerable challenge services run separately so they
can be isolated and replaced per team.

The current challenge, **Secrets All the Way Down**, follows a leaked credential
through Docker image layers, a Gitea pipeline, and LocalStack Secrets Manager.

> This repository is under active development. The local Docker Compose path is
> functional and tested. The reusable AWS deployment is being built in stages.

## Architecture

- **Platform stack:** CTFd, MariaDB, and Redis. It is stateful and holds player
  accounts, team progress, and scores.
- **Challenge stack:** vulnerable services and their seeders. It is disposable
  and must run once per team in a hosted event.
- **Event configuration:** flags are generated once per event and shared by all
  team stacks because CTFd stores one accepted value per flag.

Docker Compose is the local and single-host path. Provider-specific deployments
live under [`deploy/`](deploy/README.md) without forking the challenge
definitions.

The staged [AWS Terraform setup](deploy/aws/terraform/README.md) currently
provides the network and image-registry foundation, not a complete deployment.

## Prerequisites

- Docker Engine with Docker Compose
- [mise](https://mise.jdx.dev/)

`mise` installs the remaining project tools, including Python, ctfcli, the AWS
CLI, and the static checkers.

## Quick start

From a fresh clone:

```bash
mise install
mise run env:init
mise run ci
```

`env:init` creates the gitignored `.env`, generates deployment secrets, and
creates unique flags. `ci` builds the player artifact, starts both stacks,
bootstraps CTFd in team mode, loads the challenges, and runs every solver.

Open the `CTFD_URL` configured in `.env`—`http://localhost:8000` by default.
The generated admin credentials are also stored in that file. Players can
create profiles and then create or join a team.

Do not run `mise run ci` against an already initialized platform; its bootstrap
step is intended for a fresh CTFd instance.

## Everyday commands

| Command | Purpose |
|---|---|
| `mise run up` | Start the CTFd platform |
| `mise run challenges:up` | Build and start one local challenge stack |
| `mise run build` | Rebuild player-facing challenge artifacts |
| `mise run sync` | Install new challenges or sync metadata to CTFd |
| `mise run healthcheck` | Solve every challenge end to end |
| `mise run check` | Run all static, formatting, and secret checks |
| `mise run challenges:logs` | Follow challenge service logs |

`mise run challenges:down` deletes only the disposable challenge state.
`mise run down` also deletes the CTFd database, uploads, accounts, solves, and
scores. Back up a real event before touching the platform volumes.

## Flags and secrets

This is a public repository. Real event flags and deployment credentials belong
only in the gitignored `.env`; committed challenge files use `${FLAG_*}`
templates. Generate one `.env` per event and reuse those flag values across all
team stacks.

Reusable runtime images are built from allowlisted contexts and checked for
configured flags and platform secrets. The stage-one player artifact is the
intentional exception: recovering its deleted credential layer is the puzzle.

## Developing challenges

Each challenge lives under `challenges/<name>/` with ctfcli metadata, optional
services, player files, and a private `writeup/` solver. A challenge is not
complete until its solver passes against a fresh instance.

Read [`AGENTS.md`](AGENTS.md) before editing. Its central rule is important:
vulnerabilities under `challenges/` are the product, while platform,
orchestration, deployment, and CI code should be hardened normally.

Licensed under the [MIT License](LICENSE).
