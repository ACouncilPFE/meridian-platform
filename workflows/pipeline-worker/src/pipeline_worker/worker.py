"""Worker entrypoint.

Health + metrics are served on :9464 (/healthz, /metrics). Temporal SDK
metrics (task latency, schedule-to-start, poll success) are exported via
the SDK's built-in Prometheus endpoint on the same scrape target set the
ADOT sidecar reads, so worker saturation shows up in Grafana next to
the API's RED metrics.
"""

from __future__ import annotations

import asyncio
import base64
import os
import threading
import urllib.request
from concurrent.futures import ThreadPoolExecutor
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

from temporalio.client import Client, TLSConfig
from temporalio.runtime import PrometheusConfig, Runtime, TelemetryConfig
from temporalio.worker import Worker

from .activities import ExportActivities, PostgresRepo, S3Store, SnowflakeWarehouse
from .workflow import DeidentifyExportWorkflow

_ready = threading.Event()


class _Health(BaseHTTPRequestHandler):
    def do_GET(self):  # noqa: N802
        if self.path == "/healthz":
            self.send_response(200 if _ready.is_set() else 503)
            self.end_headers()
            self.wfile.write(b"ok" if _ready.is_set() else b"starting")
        elif self.path == "/metrics":
            # Re-expose the SDK's Prometheus endpoint on the single scrape port.
            with urllib.request.urlopen("http://127.0.0.1:9465/metrics", timeout=2) as r:  # noqa: S310
                body = r.read()
            self.send_response(200)
            self.send_header("Content-Type", "text/plain; version=0.0.4")
            self.end_headers()
            self.wfile.write(body)
        else:
            self.send_response(404)
            self.end_headers()

    def log_message(self, *args):  # silence default access log
        pass


def _serve_health(port: int) -> None:
    ThreadingHTTPServer(("0.0.0.0", port), _Health).serve_forever()  # noqa: S104


async def main() -> None:
    threading.Thread(target=_serve_health, args=(9464,), daemon=True).start()

    runtime = Runtime(telemetry=TelemetryConfig(metrics=PrometheusConfig(bind_address="0.0.0.0:9465")))
    tls = None
    if cert := os.getenv("TEMPORAL_TLS_CERT"):
        tls = TLSConfig(client_cert=cert.encode(), client_private_key=os.environ["TEMPORAL_TLS_KEY"].encode())

    client = await Client.connect(
        os.getenv("TEMPORAL_ADDRESS", "localhost:7233"),
        namespace=os.getenv("TEMPORAL_NAMESPACE", "default"),
        tls=tls or False,
        runtime=runtime,
    )

    acts = ExportActivities(
        repo=PostgresRepo(os.environ["SOURCE_DSN"]),
        store=S3Store(os.environ["EXPORT_BUCKET"]),
        warehouse=SnowflakeWarehouse(),
        pseudonym_secret=base64.b64decode(os.environ["PSEUDONYM_SECRET_B64"]),
    )

    with ThreadPoolExecutor(max_workers=8) as pool:
        worker = Worker(
            client,
            task_queue=os.getenv("TASK_QUEUE", "deidentify-export"),
            workflows=[DeidentifyExportWorkflow],
            activities=[acts.extract_and_deidentify, acts.stage_batch, acts.load_warehouse],
            activity_executor=pool,
            max_concurrent_activities=8,
        )
        _ready.set()
        await worker.run()


if __name__ == "__main__":
    asyncio.run(main())
