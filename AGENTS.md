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
| `challenges/*/solution/` | Answer key. Never ships to players. |

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

- No flag literal, credential, or key in git.
- The platform stores flags **hashed**, never plaintext.
- Real values come from `.env` (gitignored). `.env.example` carries placeholders.
- Placeholder flags in committed fixtures use `flag{EXAMPLE_...}`, so a real flag never
  looks like test data.
- Answer keys — solvers, seed scripts holding plaintext flags, writeups — live in
  `challenges/*/solution/` and are excluded from every Docker build context via
  `.dockerignore`. The exclusion must be mechanical; convention is not enough.

## Challenge authoring

- A challenge is not done until an automated solver runs end-to-end against a fresh
  instance and returns the flag. Unsolvable by script means unverifiable.
- Pin base images: tag at minimum, digest for anything a player dissects. An upstream
  rebuild silently breaks the puzzle.
- Clean `up` from nothing, clean `down -v` back to nothing. No manual steps.
- Assume the player gets RCE inside the container. Non-root, resource limits, no host
  mounts, no Docker socket (unless escape *is* the challenge, and then it is isolated),
  no secrets shared with another challenge.

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

<!-- TODO: fill in ctfcli, test, and lint entries once the stack lands. -->

| Task | Command |
|---|---|
| Stand up the platform | `docker compose up -d` |
| Tear down (destructive) | `docker compose down -v` |

Host tooling is managed with `mise`: `mise install`.

## Layout

Target structure — parts of this do not exist yet.

```
challenges/<name>/
  challenge.yml       # ctfcli metadata
  Dockerfile          # or compose fragment
  solution/           # solver + writeup, never shipped
platform/             # CTFd config, theme, plugins
compose.yaml
```
