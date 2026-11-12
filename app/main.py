"""quote-api: tiny HTTP service (Python standard library only)."""
import json
import os
import random
import signal
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PORT = int(os.environ.get("PORT", "8080"))
WORK_SECONDS = float(os.environ.get("WORK_SECONDS", "0.1"))  # simulated CPU per /api/quote
BUCKETS = (0.05, 0.1, 0.15, 0.25, 0.5, 1, 2.5, 5)

QUOTES = [
    "The only way to do great work is to love what you do.",
    "Well begun is half done.",
    "Whether you think you can or you think you can't, you're right.",
    "It always seems impossible until it's done.",
    "Small steps every day.",
    "Fall seven times, stand up eight.",
]

ready = threading.Event()
lock = threading.Lock()
requests_total = {}      # (path, status) -> count
duration_count = {}      # path -> count
duration_sum = {}        # path -> seconds
duration_buckets = {}    # path -> [count per bucket]


def burn_cpu(seconds):
    """Burn real CPU time (thread_time, not wall clock) so load is meaningful."""
    end = time.thread_time() + seconds
    x = 0
    while time.thread_time() < end:
        x += 1


def record(path, status, elapsed):
    with lock:
        requests_total[(path, status)] = requests_total.get((path, status), 0) + 1
        duration_count[path] = duration_count.get(path, 0) + 1
        duration_sum[path] = duration_sum.get(path, 0.0) + elapsed
        b = duration_buckets.setdefault(path, [0] * len(BUCKETS))
        for i, le in enumerate(BUCKETS):
            if elapsed <= le:
                b[i] += 1


def render_metrics():
    out = ["# HELP quote_api_requests_total Total HTTP requests.",
           "# TYPE quote_api_requests_total counter"]
    with lock:
        for (path, status), n in sorted(requests_total.items()):
            out.append(f'quote_api_requests_total{{path="{path}",status="{status}"}} {n}')
        out += ["# HELP quote_api_request_duration_seconds Request latency.",
                "# TYPE quote_api_request_duration_seconds histogram"]
        for path in sorted(duration_count):
            for le, n in zip(BUCKETS, duration_buckets[path]):
                out.append(f'quote_api_request_duration_seconds_bucket{{path="{path}",le="{le}"}} {n}')
            out.append(f'quote_api_request_duration_seconds_bucket{{path="{path}",le="+Inf"}} {duration_count[path]}')
            out.append(f'quote_api_request_duration_seconds_sum{{path="{path}"}} {duration_sum[path]:.6f}')
            out.append(f'quote_api_request_duration_seconds_count{{path="{path}"}} {duration_count[path]}')
    return "\n".join(out) + "\n"


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *args):  # quiet stdout; metrics cover traffic
        pass

    def send(self, status, body, ctype="application/json"):
        data = body.encode()
        self.send_response(status)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        start = time.perf_counter()
        path = self.path.split("?")[0]
        if path == "/healthz":
            status = 200
            self.send(200, '{"status":"ok"}')
        elif path == "/readyz":
            status = 200 if ready.is_set() else 503
            self.send(status, json.dumps({"ready": ready.is_set()}))
        elif path == "/metrics":
            status = 200
            self.send(200, render_metrics(), "text/plain; version=0.0.4")
        elif path == "/api/quote":
            status = 200
            burn_cpu(WORK_SECONDS)
            self.send(200, json.dumps({"quote": random.choice(QUOTES), "pod": os.environ.get("HOSTNAME", "")}))
        else:
            status, path = 404, "other"
            self.send(404, '{"error":"not found"}')
        if path != "/metrics":
            record(path, status, time.perf_counter() - start)


def main():
    server = ThreadingHTTPServer(("0.0.0.0", PORT), Handler)
    server.daemon_threads = True

    def shutdown(*_):
        ready.clear()  # fail readiness first so traffic drains, then stop
        threading.Thread(target=lambda: (time.sleep(5), server.shutdown()), daemon=True).start()

    signal.signal(signal.SIGTERM, shutdown)
    ready.set()
    server.serve_forever()


if __name__ == "__main__":
    main()
