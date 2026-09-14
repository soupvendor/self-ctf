# Pinned to the last release that runs without a LocalStack account: the
# 2026.x stream refuses to start without an auth token.
FROM localstack/localstack:4.11.1

COPY --chmod=0555 runtime/localstack/run-seeds.sh /etc/localstack/init/ready.d/00-run-seeds.sh
COPY --chmod=0555 runtime/localstack/seeds-ready.sh /usr/local/bin/seeds-ready
COPY --chmod=0555 challenges/ /opt/self-ctf/seeds/

USER 1000:1000
