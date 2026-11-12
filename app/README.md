# quote-api (Part 1)

A small HTTP API written in Python using only the standard library (no dependencies to install or audit).

| Endpoint | What it does | Example response |
|---|---|---|
| `GET /healthz` | Liveness: the process is alive | `200 {"status":"ok"}` |
| `GET /readyz` | Readiness: it can take traffic. Returns `503` after SIGTERM. | `200 {"ready": true}` |
| `GET /metrics` | Prometheus text format | `quote_api_requests_total{path="/api/quote",status="200"} 3` |
| `GET /api/quote` | Random quote, with about 100 ms of real CPU work | `200 {"quote": "...", "pod": "<hostname>"}` |
| anything else | Not found | `404 {"error":"not found"}` |

Environment variables: `PORT` (default `8080`) and `WORK_SECONDS` (default `0.1`, the CPU time burned per `/api/quote`).

---

## How the code works (`main.py`)

**Constants and state (top of the file).** `PORT` and `WORK_SECONDS` come from the environment. `QUOTES` is the list the API picks from. The metrics live in plain dictionaries (`requests_total`, `duration_count`, `duration_sum`, `duration_buckets`) protected by one `lock`, because the server handles each request in its own thread. `ready` is a `threading.Event` that says whether the app should receive traffic.

**`burn_cpu(seconds)`.** Loops until `time.thread_time()` has advanced by the requested amount. It measures CPU time used by the thread, not wall-clock time. A `sleep` would take 100 ms without using any CPU, so load tests would never stress the CPU or trigger autoscaling. Counting thread CPU time makes each request cost real CPU.

**`record(path, status, elapsed)`.** Updates the counter for `(path, status)` and the latency histogram for the path. Each bucket counts every request at or under its limit, which is how Prometheus histograms are defined (cumulative).

**`render_metrics()`.** Writes the metrics as Prometheus text: `quote_api_requests_total` (counter) and `quote_api_request_duration_seconds` (histogram with `_bucket`, `_sum`, `_count` lines and a final `le="+Inf"` bucket).

**`Handler.do_GET()`.** The router. It matches the path and answers:
- `/healthz` always returns 200.
- `/readyz` returns 200 while `ready` is set, otherwise 503.
- `/metrics` returns the text from `render_metrics()`.
- `/api/quote` calls `burn_cpu()`, then returns a random quote plus the `HOSTNAME` (the pod name in Kubernetes, so you can see which replica answered).
- Anything else returns 404, recorded under the path label `other` so random URLs can't create unlimited metric labels.
Every request except `/metrics` is recorded with its status and duration. `log_message` is silenced, because the metrics already describe traffic.

**`main()`.** Starts a `ThreadingHTTPServer` and marks the app ready. On SIGTERM (what Kubernetes sends before stopping a pod) it clears `ready` immediately, so `/readyz` starts returning 503, and shuts the server down 5 seconds later. That delay lets Kubernetes stop routing traffic to the pod before it disappears, so in-flight clients are not sent to a dead pod.

**Capacity note.** Each `/api/quote` needs 100 ms of CPU and Python runs one thread at a time (the GIL), so one process handles roughly 5 to 10 quote requests per second. That is deliberate, so a later load test has something to scale against.

## The Dockerfile

- **Stage 1 (`build`)** copies `main.py` and runs `python -m py_compile`, so a syntax error fails the build.
- **Stage 2** starts again from a clean `python:3.12-alpine`, creates a user and group with ID `10001`, copies in only `main.py`, and switches to that user. The image has no compiler, no pip cache and no secrets. It is about 74 MB.
- `PYTHONDONTWRITEBYTECODE=1` stops Python writing `.pyc` files, so the app also runs with a read-only root filesystem.
- `.dockerignore` keeps `__pycache__` and `*.pyc` out of the build.

---

## Run it directly with Python

Needs Python 3.9 or newer (tested with 3.12):

```bash
cd app
python3 main.py              # listens on :8080; stop with Ctrl+C
```

## Build and run the image

```bash
cd app
docker build -t quote-api:local .
docker run -d --name quote-test --read-only -p 8080:8080 quote-api:local
```

`--read-only` makes the container's root filesystem read-only, which is how it will run in Kubernetes. If port 8080 is busy, use another host port such as `-p 18080:8080` and change the port in the test commands. Stop it with `docker rm -f quote-test`.

## Tag with the git SHA (for GHCR)

The image tag has to be the git commit SHA. A floating `latest` on its own is not acceptable. From the repo root, after committing:

```bash
SHA=$(git rev-parse --short HEAD)
docker build -t ghcr.io/<github-user>/quote-api:$SHA app
```

The registry path must be lowercase. Pushing needs a login first and is a separate, deliberate step:

```bash
docker login ghcr.io -u <github-user>      # use a token with write:packages
docker push ghcr.io/<github-user>/quote-api:$SHA
```

After the first push, set the package to **Public** in GitHub (Packages, `quote-api`, Package settings), because new packages start private.

---

## Test it

Examples use port 8080.

```bash
curl -i localhost:8080/healthz        # 200  {"status":"ok"}
curl -i localhost:8080/readyz         # 200  {"ready": true}
curl -i localhost:8080/api/quote      # 200  a quote and the host name
curl -i localhost:8080/nope           # 404
curl localhost:8080/metrics           # Prometheus text
```

**The simulated CPU work.** `/api/quote` should take about 0.10 s and `/healthz` a few milliseconds:

```bash
curl -s -o /dev/null -w 'quote:   %{time_total}s\n' localhost:8080/api/quote
curl -s -o /dev/null -w 'healthz: %{time_total}s\n' localhost:8080/healthz
```

**The counter goes up:**

```bash
curl -s localhost:8080/metrics | grep 'requests_total{'
for i in 1 2 3; do curl -s -o /dev/null localhost:8080/api/quote; done
curl -s localhost:8080/metrics | grep 'requests_total{'     # /api/quote count is +3
```

**Docker only: the container is locked down:**

```bash
docker exec quote-test id             # uid=10001(app): not root
docker exec quote-test touch /x       # fails: Read-only file system
docker images quote-api:local         # about 74 MB
```

**Graceful shutdown.** The app reports not-ready at once and exits 5 seconds later:

```bash
docker kill --signal=SIGTERM quote-test
curl -i localhost:8080/readyz         # right away: 503 {"ready": false}
# about 5 seconds later the container exits, and curl gets "connection refused"
```

Running directly with Python, `Ctrl+C` stops the process immediately. A plain `kill <pid>` sends SIGTERM and behaves like the Docker case: it keeps answering for 5 seconds with readiness at 503.
