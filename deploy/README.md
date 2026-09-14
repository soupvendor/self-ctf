# Deployment targets

Challenge definitions and runtime images are provider-neutral. Deployment
implementations live here so adding an AWS, Kubernetes, or another local path
does not fork the challenges themselves.

The existing root Compose files remain the local development and single-host
path:

- `compose.yaml` runs the stateful CTFd platform.
- `mise run challenges:up` runs each challenge in a separate Compose project.

Every deployment target must preserve the same boundary: one stateful platform,
one isolated bundle per team/challenge, shared event flags, and no platform
credential in a challenge stack.
