FROM gitea/gitea:1.27.1-rootless

COPY --chmod=0555 seed.sh /usr/local/bin/seed-gitea
COPY --chown=1000:1000 repo /opt/self-ctf/repo

ENTRYPOINT ["/usr/local/bin/seed-gitea"]
