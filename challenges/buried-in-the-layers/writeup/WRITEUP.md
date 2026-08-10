# Buried in the Layers

## The flaw

A Docker image is a stack of layers. Each layer records a filesystem *change*,
and layers are immutable once written. Deleting a file in a later layer does not
edit the earlier layer that created it — it only writes a whiteout marker saying
"this path is gone from here down".

The image's build did exactly that:

```dockerfile
COPY build/deploy-creds.env /opt/deploy/creds.env   # layer A: secret written
RUN ...                                             # layer B: uses it
RUN rm -f /opt/deploy/creds.env                     # layer C: whiteout only
```

`docker run` shows nothing at `/opt/deploy/creds.env`, so the file looks gone.
Layer A still contains the bytes, and `docker save` exports every layer.

## Solve

Unpack the artifact and read the layer directly — no daemon needed:

```bash
mkdir -p /tmp/solve && tar -xf internal-deployer.tar -C /tmp/solve
find /tmp/solve -type f -exec tar -xOf {} opt/deploy/creds.env \; 2>/dev/null
```

`DEPLOY_TOKEN` in that output is the flag.

`docker history --no-trunc` shows the `rm` and hints at the mistake, and `dive`
lets you browse layer A interactively — both are fine routes to the same place.

## The real-world lesson

Squashing, `--squash`, or multi-stage builds remove the layer. Build secrets
(`RUN --mount=type=secret`) never create one. Deleting the file afterward is not
a fix, and any image published this way should be treated as leaked.
