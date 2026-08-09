# PLANTED VULNERABILITY - do not "fix" this.
#
# The flaw: COPY writes the credentials into layer A. The later RUN rm only
# adds a whiteout entry in layer C; the original bytes are still sitting in
# layer A and survive in the exported image.
#
# Intended solve: docker save / dive / manual tar extraction of the layer.

FROM alpine:3.20@sha256:d9e853e87e55526f6b2917df91a2115c36dd7c696a35be12163d44e6e2a4b6bc

LABEL org.internal.team="platform" \
      org.internal.note="deployer image - do not distribute build context"

# Layer A: the secret enters the image here.
COPY build/deploy-creds.env /opt/deploy/creds.env

# Layer B: pretend to do real work with the creds.
RUN echo "authenticating to CI as $(grep CI_USER /opt/deploy/creds.env | cut -d= -f2)" \
    && mkdir -p /opt/deploy/out \
    && echo "deploy artifact built" > /opt/deploy/out/artifact.txt

# Layer C: "clean up" the secret. Whiteout only - layer A is untouched.
RUN rm -f /opt/deploy/creds.env

WORKDIR /opt/deploy
CMD ["sh", "-c", "echo internal-deployer ready && sleep infinity"]
