# syntax=docker/dockerfile:1.7
#
# Hartsy SwarmUI worker for Vast.ai (Serverless and Instances).
# Everything provider-neutral comes from SwarmUI-Worker-Base; this image adds Vast's PyWorker SDK
# and the lease controller.
#
# Vast Serverless cannot attach a volume, so a serverless image needs its models baked in on top of this
# one: see scripts/bake_dockerfile.sh and the README.

ARG BASE_IMAGE=kalebbroo/swarmui-worker-base
ARG BASE_VERSION=1.0.0
ARG BACKEND=hartsyinference
FROM ${BASE_IMAGE}:${BASE_VERSION}-${BACKEND}

ARG VERSION=dev
ARG REVISION=unknown
LABEL org.opencontainers.image.title="swarmui-worker-vast" \
      org.opencontainers.image.description="Hartsy SwarmUI worker for Vast.ai Serverless and Instances" \
      org.opencontainers.image.vendor="Hartsy" \
      org.opencontainers.image.url="https://hartsy.ai" \
      org.opencontainers.image.source="https://github.com/HartsyAI/Vast-Worker-SwarmUI" \
      org.opencontainers.image.licenses="MIT" \
      org.opencontainers.image.version="${VERSION}" \
      org.opencontainers.image.revision="${REVISION}"

COPY --chown=swarm:swarm requirements.txt /opt/worker/requirements.txt
RUN /opt/worker/venv/bin/pip install --no-cache-dir -r /opt/worker/requirements.txt

COPY --chown=swarm:swarm src/worker.py src/lease_controller.py /opt/worker/
COPY --chown=swarm:swarm scripts/entrypoint.sh /opt/worker/entrypoint.sh
ENV PYTHONPATH=/opt/worker/lib:/opt/worker

# The entrypoint starts as root only to hand Vast's TLS key to the worker, then drops to `swarm`.
USER root

# 7801: the SwarmUI gateway. WORKER_PORT (set on the template, e.g. 8000): the PyWorker.
EXPOSE 7801 8000
ENTRYPOINT ["/usr/bin/tini", "--", "/bin/bash", "/opt/worker/entrypoint.sh"]
