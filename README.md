# SwarmUI Worker for Vast.ai

Run [SwarmUI](https://github.com/mcmonkeyprojects/SwarmUI) generations on Vast.ai GPUs, on demand. This image is the Vast.ai worker used by the [Cloud Backends](https://github.com/HartsyAI/SwarmUI-CloudBackends) SwarmUI extension. The extension opens workers when you generate, sends generations straight to them, and lets them go when idle. Under load, Vast's autoscaler adds workers.

It is built on [SwarmUI-Worker-Base](https://github.com/HartsyAI/SwarmUI-Worker-Base), which provides SwarmUI, the generation backend, an authenticated gateway, and clean per-lease state. This repo adds Vast's official PyWorker and a small lease controller.

## Images

`kalebbroo/swarmui-worker-vast:<version>-<backend>` on Docker Hub. The backend is `hartsyinference` (recommended for Vast: a small image and a fast cold start) or `comfyui`. Pin a release version in production.

**Vast Serverless cannot attach a volume, so a serverless worker needs its model inside the image.** Build your own image with the model baked in:

```bash
docker build --build-arg BACKEND=hartsyinference --build-arg BASE_VERSION=1.0.0 \
  --build-arg BAKE_MODEL_URL=https://example.com/models/my-model.safetensors \
  --build-arg BAKE_MODEL_SHA256=<sha256 of the file> \
  -t <your-dockerhub-user>/swarmui-worker-vast:1.0.0-mymodel .
docker push <your-dockerhub-user>/swarmui-worker-vast:1.0.0-mymodel
```

For Vast Instances (rented machines), the published image works as is: attach a volume with your models.

## How it works

- **Sessions hold workers.** The client opens a Vast **session** on a worker. That's Vast's own mechanism: the session counts as the worker's load, and the SDK closes it when its lifetime runs out. Each worker takes one session. An open session reads as a fully used worker, so the next session goes to another worker, or makes Vast recruit one.
- **A lease rides on the session.** Calling `/lease` with the session returns the worker's HTTPS address and an access token for SwarmUI. When the session ends (the client lets it expire, or ends it), the token is revoked at once and Vast scales the worker down.
- **Security:**
  - SwarmUI never listens on a public port.
  - The gateway and the PyWorker both serve TLS with the certificate Vast issues to every instance (`/etc/instance.crt`, signed by Vast's root CA).
  - Every `/lease` request must carry Vast's signed routing grant. The worker refuses to start if signature checks are disabled (`UNSECURED`).
- **A crashed client costs at most one session lifetime.** Nothing keeps a worker alive except a client that keeps renewing.

## Serverless setup

1. **Image:** build and push an image with your model (see above).
2. **Template** ([Templates, New](https://cloud.vast.ai/templates/)):

   | Setting | Value |
   |---|---|
   | Image | your image from step 1 |
   | Launch mode | Docker ENTRYPOINT |
   | Docker options | `-p 7801:7801 -p 8000:8000 -e WORKER_PORT=8000` |
   | Container disk | above the image's unpacked size (e.g. 40 GB). Vast's 8 GB default is too small, and an undersized disk fails without naming the cause. |

3. **Endpoint** ([Serverless](https://cloud.vast.ai/serverless/)):

   | Setting | Value | Why |
   |---|---|---|
   | Min workers | `0` | Otherwise Vast keeps that many loaded, stopped workers, which bill for storage. |
   | Min load | `0` | Any value above 0 keeps a worker active, so the endpoint never scales to zero. |
   | Inactivity timeout | e.g. `300` | Lets the endpoint scale to zero after this many idle seconds. |
   | Max workers | the most workers you want running at once | |
   | Target utilization | `0.9` (the default) | |

4. **Workergroup:** add one to the endpoint using the template, with a GPU filter of 16 GB VRAM or more.
5. **Cloud Backends:** in SwarmUI, add a **Cloud Backends** backend, enable Vast.ai Serverless, and enter the endpoint name. Put your Vast API key in User Settings.

## Instance setup

The Cloud Backends extension rents, starts, and stops Vast instances for you (Vast.ai Instances section of the card), and sets the instance's token.

To run one by hand: rent an instance with this image, expose port 7801, set `SWARMUI_WORKER_TOKEN` to a random value of at least 32 characters, and attach a volume with your models at `/workspace`. The gateway serves HTTPS with the instance's Vast certificate. Clients must trust [Vast's root certificate](https://console.vast.ai/static/jvastai_root.cer).

## Configuration

| Variable | Default | Meaning |
|---|---|---|
| `WORKER_PORT` | *(template)* | The PyWorker's port. Required for serverless. |
| `SWARMUI_WORKER_TOKEN` | *(none)* | **Instances only.** Serverless refuses it, because each lease gets its own token. |
| `SWARMUI_MODEL_ROOT` | the image's models, or `/workspace/Models` on instances | Where the models are. |
| `SWARM_MODE` | `auto` | `serverless` or `instance`. Detected from `REPORT_ADDR`, which Vast sets only for serverless workers. |

The base image's full list is in the [SwarmUI-Worker-Base README](https://github.com/HartsyAI/SwarmUI-Worker-Base#configuration).

## Protocol

The Cloud Backends extension is the intended client. For reference, with Vast's `vastai` client SDK:

1. `start_endpoint_session(endpoint, cost=100, lifetime=<idle seconds>, on_close_route="/lease/end")`
2. `POST /lease` through the session, with payload `{"session_id": <id>}`. It returns `{"success": true, "public_url", "token", "worker_id", "protocol": 2, "idle_seconds"}`.
3. Use SwarmUI at `public_url` with `Authorization: Bearer <token>`.
4. While in use, renew by repeating step 2, but only when the session's remaining time is below one lifetime (read it with `/session/get`). Each call *adds* a full lifetime, so renewing on a timer would keep the worker alive long after you stop.
5. Stop renewing, or call `/session/end`, to release the worker.

## Development

```bash
PYTHONPATH=../SwarmUI-Worker-Base/src python -m pytest tests
# Until base images are published, build the base locally first (CI does the same):
git clone https://github.com/HartsyAI/SwarmUI-Worker-Base ../SwarmUI-Worker-Base
docker build --build-arg BACKEND=hartsyinference -t kalebbroo/swarmui-worker-base:source-hartsyinference ../SwarmUI-Worker-Base
docker build --build-arg BACKEND=hartsyinference --build-arg BASE_VERSION=source -t swarmui-worker-vast:local .
bash tests/smoke/smoke.sh swarmui-worker-vast:local
```

## License

MIT, see [LICENSE](LICENSE).
