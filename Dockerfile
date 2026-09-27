# syntax=docker/dockerfile:1.7
#
# Hartsy SwarmUI worker for Vast.ai (Serverless and Instances).
# Everything provider-neutral comes from SwarmUI-Worker-Base; this image adds Vast's PyWorker SDK
# and the lease controller.
#
# Vast Serverless cannot attach a volume, so a serverless image needs its model baked in:
#   docker build --build-arg BACKEND=hartsyinference \
#     --build-arg BAKE_MODEL_URL=https://.../model.safetensors --build-arg BAKE_MODEL_SHA256=<sha256> \
#     -t you/swarmui-worker-vast:with-model .

ARG BASE_IMAGE=hartsy/swarmui-worker-base
ARG BASE_VERSION=edge
ARG BACKEND=hartsyinference
FROM ${BASE_IMAGE}:${BASE_VERSION}-${BACKEND}

ARG BAKE_MODEL_URL=""
ARG BAKE_MODEL_SHA256=""
ARG BAKE_MODEL_SUBDIR=Stable-Diffusion
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

RUN if [ -n "$BAKE_MODEL_URL" ]; then \
      if [ -z "$BAKE_MODEL_SHA256" ]; then echo "BAKE_MODEL_SHA256 is required with BAKE_MODEL_URL" >&2; exit 1; fi; \
      name="$(basename "${BAKE_MODEL_URL%%\?*}")"; \
      dest="/opt/swarmui/Models/${BAKE_MODEL_SUBDIR}/${name}"; \
      mkdir -p "$(dirname "$dest")" \
      && curl -fL --retry 5 --retry-delay 5 -o "$dest" "$BAKE_MODEL_URL" \
      && echo "${BAKE_MODEL_SHA256}  ${dest}" | sha256sum -c -; \
    fi

COPY --chown=swarm:swarm src/worker.py src/lease_controller.py /opt/worker/
COPY --chown=swarm:swarm scripts/entrypoint.sh /opt/worker/entrypoint.sh
ENV PYTHONPATH=/opt/worker/lib:/opt/worker

# 7801: the SwarmUI gateway. WORKER_PORT (set on the template, e.g. 8000): the PyWorker.
EXPOSE 7801 8000
ENTRYPOINT ["/bin/bash", "/opt/worker/entrypoint.sh"]
