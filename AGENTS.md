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

## Flags and secrets

This repo is organizer-only — it holds the answer keys. The line that matters is what
reaches a **player**, not what reaches git.

- ctfcli's blessed path puts the flag in `challenge.yml` in plaintext and CTFd validates
  it server-side. That is expected here. Do not invent a templating step to hide it.
- Nothing carrying a flag or credential may enter a build context, `dist/`, a shipped image
  layer, or any service players can reach — unless leaking it *is* the challenge.
- Deployment secrets are a separate matter: CTFd admin token, registry and cloud keys live
  in `.env` (gitignored), with `.env.example` carrying placeholders. `ctf init` writes an
  admin access token into `.ctf/config` — that file must never be committed.
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
- Clean `up` from nothing, clean `down -v` back to nothing. No manual steps.
- Assume the player gets RCE inside the container. Non-root, resource limits, no host
  mounts, no Docker socket (unless escape *is* the challenge, and then it is isolated),
  no secrets shared with another challenge.
- One shared instance per service. CTFd open-source has no per-team instancing, and the
  plugins that add it generally want the Docker socket mounted — which breaks the rule
  above. Don't reach for one without making that trade deliberately.

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
  Dockerfile          # or compose fragment
  dist/               # player-facing files, listed under files:
  writeup/            # exploit.sh (healthcheck) + WRITEUP.md, never shipped
platform/             # CTFd config, theme, plugins
compose.yaml
```

`dist/` and `writeup/` are ctfcli's own conventions — the spec wires
`healthcheck: writeup/exploit.sh` and `files: dist/...`. Follow them.
