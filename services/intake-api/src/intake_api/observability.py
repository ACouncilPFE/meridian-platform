"""Prometheus metrics + OpenTelemetry tracing.

Metrics are exposed on /metrics and scraped by the OTel collector sidecar
(ADOT), which remote-writes to Amazon Managed Prometheus. Traces go OTLP ->
sidecar -> Grafana Tempo. Labels are deliberately low-cardinality and never
contain identifiers (no patient ids, no raw paths).
"""

from __future__ import annotations

import os
import time

from fastapi import FastAPI, Request, Response
from prometheus_client import CONTENT_TYPE_LATEST, CollectorRegistry, Counter, Gauge, Histogram, generate_latest
from starlette.routing import Match

REGISTRY = CollectorRegistry(auto_describe=True)

HTTP_REQUESTS = Counter(
    "http_requests_total",
    "HTTP requests by route template and status class.",
    ["method", "route", "status"],
    registry=REGISTRY,
)
HTTP_LATENCY = Histogram(
    "http_request_duration_seconds",
    "HTTP request latency by route template.",
    ["method", "route"],
    buckets=(0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1, 2.5, 5),
    registry=REGISTRY,
)
PHI_ACCESS = Counter(
    "phi_access_total",
    "PHI record accesses (audit signal; anomalous spikes page security).",
    ["action", "actor_type"],
    registry=REGISTRY,
)
DECRYPT_FAILURES = Counter(
    "phi_decrypt_failures_total",
    "Field decryption failures (tampering, key misconfig).",
    registry=REGISTRY,
)
BUILD_INFO = Gauge(
    "app_build_info",
    "Build metadata.",
    ["version", "commit"],
    registry=REGISTRY,
)


def _route_template(request: Request) -> str:
    for route in request.app.routes:
        match, _ = route.matches(request.scope)
        if match == Match.FULL:
            return getattr(route, "path", "unknown")
    return "unmatched"


def instrument(app: FastAPI) -> None:
    BUILD_INFO.labels(os.getenv("APP_VERSION", "dev"), os.getenv("GIT_SHA", "local")).set(1)

    @app.middleware("http")
    async def _metrics(request: Request, call_next):
        route = _route_template(request)
        start = time.perf_counter()
        status = "500"
        try:
            response = await call_next(request)
            status = str(response.status_code)
            return response
        finally:
            if route not in ("/metrics", "/healthz"):
                HTTP_LATENCY.labels(request.method, route).observe(time.perf_counter() - start)
                HTTP_REQUESTS.labels(request.method, route, status[0] + "xx").inc()

    @app.get("/metrics", include_in_schema=False)
    def metrics() -> Response:
        return Response(generate_latest(REGISTRY), media_type=CONTENT_TYPE_LATEST)

    _setup_tracing(app)


def _setup_tracing(app: FastAPI) -> None:
    endpoint = os.getenv("OTEL_EXPORTER_OTLP_ENDPOINT")
    if not endpoint:
        return
    from opentelemetry import trace
    from opentelemetry.exporter.otlp.proto.grpc.trace_exporter import OTLPSpanExporter
    from opentelemetry.instrumentation.fastapi import FastAPIInstrumentor
    from opentelemetry.sdk.resources import Resource
    from opentelemetry.sdk.trace import TracerProvider
    from opentelemetry.sdk.trace.export import BatchSpanProcessor

    provider = TracerProvider(resource=Resource.create({"service.name": os.getenv("OTEL_SERVICE_NAME", "intake-api")}))
    provider.add_span_processor(BatchSpanProcessor(OTLPSpanExporter(endpoint=endpoint, insecure=True)))
    trace.set_tracer_provider(provider)
    # Exclude health/metrics; never record request bodies or query strings.
    FastAPIInstrumentor.instrument_app(app, excluded_urls="healthz,metrics", tracer_provider=provider)
