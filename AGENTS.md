# self-ctf

Self-hosted CTF. CTFd as the platform, Docker Compose to run it, one challenge per
directory under `challenges/`.

## Prime directive

Challenge code is **supposed** to be vulnerable. Platform code is **not**. Know which
one you are editing before you change anything.

| Path | Rule |
|---|---|
| `challenges/**` | Vulnerabilities are the product. Never harden, patch, or "improve" them. |
| `platform/**`, `compose.yaml`, CI | Real production code. Harden normally. |
| `challenges/*/writeup/` | Answer key. Never ships to players. |

## Writing code

- **No inline documentation unless it is load-bearing.** No docstrings restating the
  signature, no comments narrating the next line. When a comment earns its place: one
  line, not wordy.
  - *Exception:* every planted vulnerability gets one comment naming the flaw and the
    intended solve path. That comment is what stops the next reader — human or agent —
    from "fixing" it.
- **Take the blessed path.** Use the supported mechanism: ctfcli for challenge metadata,
  compose for orchestration, the framework's documented API.
- **If the blessed path is blocked, stop and report.** Do not route around it with
  `# type: ignore`, disabled lint rules, monkey-patching, `--force`, `|| true`,
  sleep-based retries, or a vendored fork. "Blocked because X" is a better deliverable
  than a working hack.
- **Never weaken a test to make it pass.** No skips, no loosened assertions, no deleted
  cases.
- **Fail loudly.** No bare `except`, no swallowed errors, no default values papering over
  missing config. A silent fallback in flag validation is a platform vulnerability.
- Match the surrounding code. Look for an existing helper before writing one.
- Ask before adding a dependency.
- Change what was asked. Note adjacent problems; don't fix them in passing.
- `mise run check` runs every static check — ruff, mypy strict, shellcheck, shfmt,
  hadolint, actionlint, gitleaks, and the flag-leak guard. hk runs the same set as a
  git hook, so a green commit and a green CI mean the same thing.
- Fix what a linter finds; do not suppress it. A `# noqa` needs a reason on the same
  line, and it means the finding does not apply — not that it is inconvenient.

## Flags and secrets

**This repo is public.** Anyone can read it, so no real flag may ever be committed —
a public clone must not spoil a live event.

- Challenges commit `challenge.yml.tmpl` holding `${FLAG_<NAME>}`, never a literal flag.
  `mise run render` writes the real value into a gitignored `challenge.yml` from `.env`.
  Same for any challenge file that embeds a flag.
- ctfcli has no templating of its own, so the render step is ours. It still hands ctfcli a
  complete, valid `challenge.yml` through the normal interface — nothing is patched or
  bypassed. Consequence: `ctf challenge mirror` writes back to a generated file, so we
  don't use it.
- Nothing carrying a flag or credential may enter a build context, `dist/`, a shipped image
  layer, or any service players can reach — unless leaking it *is* the challenge.
- Every deployment generates its own flags. Two operators running this repo get different
  answers, which is what makes a public CTF repo playable.
- Deployment secrets live in `.env` (gitignored), with `.env.example` carrying placeholders.
  Bootstrap writes a CTFd admin access token into `.ctf/config` — never commit that file.
- Placeholder flags in committed fixtures use `flag{EXAMPLE_...}`, so a real flag never
  looks like test data.
- Answer keys — solvers, seed scripts holding plaintext flags, writeups — live in
  `challenges/*/writeup/` and are excluded from every Docker build context via
  `.dockerignore`. The exclusion must be mechanical; convention is not enough.
- `challenge.yml`'s `solution:` field uploads the document **into CTFd**. Pin it explicitly
  with the object form and `state: hidden`. `state: solved` reveals the writeup to whoever
  solved that stage — in a chain, that hands them the next stage's credentials.

## Challenge authoring

- A challenge is not done until an automated solver runs end-to-end against a fresh
  instance and returns the flag. Unsolvable by script means unverifiable.
- The solver is `writeup/exploit.sh`, wired in as `healthcheck:` in `challenge.yml`.
  ctfcli passes it `--connection-info`, so it runs against a live instance. Use
  `ctf challenge healthcheck` — do not build a parallel harness.
- Pin base images: tag at minimum, digest for anything a player dissects. An upstream
  rebuild silently breaks the puzzle.
- If the flag is *meant* to be recoverable from a distributed file, drop an
  `.expect-flag-in-artifact` file in the challenge saying why. `mise run lint` then
  skips ctfcli's distributed-file scan for that challenge only, and keeps the rest.
- Clean `up` from nothing, clean `down -v` back to nothing. No manual steps.
- Assume the player gets RCE inside the container. Non-root, resource limits, no host
  mounts, no Docker socket (unless escape *is* the challenge, and then it is isolated),
  no secrets shared with another challenge.
- Challenge services must survive being shared or replaced. Assume several people hit the
  same instance and that it gets rebuilt mid-event: no manual seeding, no state that only
  exists because someone clicked something.

## Deployment shape

CTFd runs on its own host. Challenge services run separately, one stack per team, so one
player cannot break a challenge for everyone else.

- **The platform host is stateful.** CTFd holds accounts, solves, and scores. Back it up;
  never treat it as disposable mid-event.
- **Team stacks are disposable.** They must come back from nothing with a single command,
  because that is the recovery plan when a player breaks one.
- **Every team stack carries the same flag values.** CTFd stores one flag per challenge, so
  per-team flags would mean only one team could ever submit a correct answer. Generate
  `.env` once and reuse it across stacks.
- **Team stacks get flags only.** Never copy the CTFd admin password, secret key, or
  database password onto a host where a challenge grants code execution.
- Do not reach for the CTFd instancing plugins. They generally want the Docker socket
  mounted, which breaks the containment rule above; running separate stacks does not.

## Multi-stage chains

- One stage, one challenge, chained with `requirements.prerequisites`. `anonymize: true`
  shows a locked placeholder; `false` hides the stage outright.
- Handoff context — recovered credentials, which service to attack next — belongs in the
  next stage's description, which players can't read until they unlock it.
- Set `next:` so a solve points at the follow-up and the narrative pulls forward.
- Do not try to sequence several flags inside one challenge. `logic: all` is unordered and
  will not enforce a chain.

## Running things

- Exploits and solvers run **only** against local instances of this project. Never
  against a host you don't control, and never as a shortcut for testing.
- `docker compose down -v` destroys CTFd state and player progress. Confirm before
  running it.

## Definition of done

1. It runs. You ran it, and you can quote the output.
2. The solver passes against a fresh instance.
3. No secret, flag, or answer key reached git or a build context.
4. Nothing was skipped, silenced, or worked around — or it is called out plainly.

Do not report a task complete on inspection alone. "Should work" is not done.

## Commands

| Task | Command |
|---|---|
| Static checks (as the hooks run) | `mise run check` |
| Autofix formatting and lint | `hk fix --all` |
| Install the git hooks | `mise run hooks:install` |
| Stand up the platform | `docker compose up -d` |
| Tear down (destructive) | `docker compose down -v` |
| Scaffold a challenge | `ctf challenge new` |
| Create it in CTFd (first time) | `ctf challenge install <name>` |
| Push later edits to CTFd | `ctf challenge sync <name>` |
| Check local matches remote | `ctf challenge verify` |
| Run every solver | `ctf challenge healthcheck` |
| Lint / format `challenge.yml` | `ctf challenge lint`, `ctf challenge format` |

Omitting `<name>` applies the command to every challenge.

<!-- TODO: platform-side test and lint commands, once platform/ exists. -->

Host tooling is managed with `mise`: `mise install`.

## Layout

Target structure — parts of this do not exist yet.

```
challenges/<name>/
  challenge.yml       # ctfcli metadata
  compose.yaml        # challenge services, if any — runs on team hosts
  artifact.Dockerfile # if the challenge ships a file rather than a service
  seed/               # planted credentials, rendered from *.tmpl
  dist/               # player-facing files, listed under files:
  writeup/            # exploit.sh (healthcheck) + WRITEUP.md, never shipped
compose.yaml          # the platform: CTFd, database, cache
```

The two compose layers deploy to different hosts — the platform once, the challenge
services once per team.

`dist/` and `writeup/` are ctfcli's own conventions — the spec wires
`healthcheck: writeup/exploit.sh` and `files: dist/...`. Follow them.
