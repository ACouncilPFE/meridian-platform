"""Dashboards as code.

Generates Grafana dashboard JSON from compact Python definitions so every
service gets the same golden-signals layout (the paved road for
dashboards). CI fails if the committed JSON is out of date:

    python observability/grafana/build_dashboards.py --check
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

OUT = Path(__file__).parent / "dashboards"
DS = {"type": "prometheus", "uid": "prometheus"}


def panel(pid: int, title: str, exprs: list[tuple[str, str]], x: int, y: int, w: int = 12, h: int = 8,
          unit: str = "short", kind: str = "timeseries", thresholds: list[tuple[str, float | None]] | None = None) -> dict:
    p = {
        "id": pid,
        "type": kind,
        "title": title,
        "datasource": DS,
        "gridPos": {"x": x, "y": y, "w": w, "h": h},
        "targets": [{"refId": chr(65 + i), "expr": e, "legendFormat": legend, "datasource": DS}
                    for i, (e, legend) in enumerate(exprs)],
        "fieldConfig": {"defaults": {"unit": unit}, "overrides": []},
        "options": {"legend": {"displayMode": "list", "placement": "bottom"}},
    }
    if thresholds:
        p["fieldConfig"]["defaults"]["thresholds"] = {
            "mode": "absolute",
            "steps": [{"color": c, "value": v} for c, v in thresholds],
        }
    return p


def row(pid: int, title: str, y: int) -> dict:
    return {"id": pid, "type": "row", "title": title, "collapsed": False, "gridPos": {"x": 0, "y": y, "w": 24, "h": 1}}


def dashboard(uid: str, title: str, panels: list[dict], tags: list[str]) -> dict:
    return {
        "uid": uid,
        "title": title,
        "tags": tags,
        "timezone": "utc",
        "schemaVersion": 39,
        "version": 1,
        "refresh": "30s",
        "time": {"from": "now-6h", "to": "now"},
        "templating": {"list": [{
            "name": "env", "type": "query", "datasource": DS,
            "query": "label_values(http_requests_total, env)", "current": {"text": "prod", "value": "prod"},
        }]},
        "annotations": {"list": []},
        "panels": panels,
    }


def service_golden_signals(service: str) -> dict:
    sel = f'service="{service}", env="$env"'
    err_ratio_30d = (
        f'(sum(increase(http_requests_total{{{sel}, status="5xx"}}[30d])) '
        f'/ sum(increase(http_requests_total{{{sel}}}[30d])))'
    )
    panels = [
        row(1, "SLO", 0),
        panel(2, "Availability (30d)", [(f"1 - {err_ratio_30d}", "availability")],
            0, 1, w=6, h=5, unit="percentunit", kind="stat",
            thresholds=[("red", None), ("orange", 0.998), ("green", 0.999)]),
        panel(3, "Error budget remaining", [(f"1 - ({err_ratio_30d} / 0.001)", "budget")],
            6, 1, w=6, h=5, unit="percentunit", kind="stat",
            thresholds=[("red", None), ("orange", 0.25), ("green", 0.5)]),
        panel(4, "Burn rate (1h)", [(f'sli:http_errors:ratio_rate1h{{{sel}}} / 0.001', "burn")],
              12, 1, w=6, h=5, kind="stat", thresholds=[("green", None), ("orange", 6), ("red", 14.4)]),
        panel(5, "p99 latency", [(f'max(sli:http_latency:p99_5m{{{sel}}})', "p99")],
              18, 1, w=6, h=5, unit="s", kind="stat", thresholds=[("green", None), ("orange", 0.3), ("red", 0.5)]),
        row(6, "Golden signals", 6),
        panel(7, "Traffic (req/s) by route", [(f'sum by (route) (rate(http_requests_total{{{sel}}}[5m]))', "{{route}}")],
              0, 7, unit="reqps"),
        panel(8, "Errors (5xx ratio)", [(f'sli:http_errors:ratio_rate5m{{{sel}}}', "5xx ratio")],
              12, 7, unit="percentunit"),
        panel(9, "Latency by route", [
            (f'histogram_quantile(0.50, sum by (le, route) (rate(http_request_duration_seconds_bucket{{{sel}}}[5m])))',
             "p50 {{route}}"),
            (f'histogram_quantile(0.99, sum by (le, route) (rate(http_request_duration_seconds_bucket{{{sel}}}[5m])))',
             "p99 {{route}}"),
        ], 0, 15, unit="s"),
        panel(10, "Saturation: process CPU / memory", [
            (f'rate(process_cpu_seconds_total{{{sel}}}[5m])', "cpu"),
            (f'process_resident_memory_bytes{{{sel}}} / 1e9', "rss GB"),
        ], 12, 15),
        row(11, "PHI & security", 23),
        panel(12, "PHI accesses by action", [(f'sum by (action) (rate(phi_access_total{{{sel}}}[5m]))', "{{action}}")],
              0, 24, unit="ops"),
        panel(13, "Decrypt failures", [(f'sum(increase(phi_decrypt_failures_total{{{sel}}}[1h]))', "failures/1h")],
              12, 24, kind="stat", thresholds=[("green", None), ("red", 1)]),
    ]
    return dashboard(service, f"{service}: SLO & golden signals", panels, ["platform", "slo", service])


def data_platform() -> dict:
    panels = [
        row(1, "Disaster recovery", 0),
        panel(2, "Last drill result", [("min by (cluster) (dr_drill_success)", "{{cluster}}")], 0, 1, w=6, h=5,
              kind="stat", thresholds=[("red", None), ("green", 1)]),
        panel(3, "Measured RTO", [("max by (cluster) (dr_drill_rto_seconds)", "{{cluster}}")], 6, 1, w=6, h=5,
              unit="s", kind="stat", thresholds=[("green", None), ("red", 3600)]),
        panel(4, "Measured RPO", [("max by (cluster) (dr_drill_rpo_seconds)", "{{cluster}}")], 12, 1, w=6, h=5,
              unit="s", kind="stat", thresholds=[("green", None), ("red", 900)]),
        panel(5, "Days since last drill", [("(time() - max(dr_drill_last_run_timestamp_seconds)) / 86400", "days")],
              18, 1, w=6, h=5, kind="stat", thresholds=[("green", None), ("orange", 7), ("red", 8)]),
        row(6, "Temporal pipeline", 6),
        panel(7, "Workflow completions / failures", [
            ('sum by (workflow_type) (rate(temporal_workflow_completed[15m]))', "completed {{workflow_type}}"),
            ('sum by (workflow_type) (rate(temporal_workflow_failed[15m]))', "failed {{workflow_type}}"),
        ], 0, 7),
        panel(8, "Activity schedule-to-start p95", [(
            'histogram_quantile(0.95, sum by (le, task_queue) (rate(temporal_activity_schedule_to_start_latency_bucket[5m])))',
            "{{task_queue}}")], 12, 7, unit="s"),
    ]
    return dashboard("data-platform", "Data platform: DR, backups, pipelines", panels, ["platform", "data", "dr"])


DASHBOARDS = {"intake-api.json": service_golden_signals("intake-api"), "data-platform.json": data_platform()}


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--check", action="store_true", help="fail if committed JSON is stale")
    args = ap.parse_args()
    OUT.mkdir(exist_ok=True)
    stale = []
    for name, dash in DASHBOARDS.items():
        rendered = json.dumps(dash, indent=2, sort_keys=True) + "\n"
        path = OUT / name
        if args.check:
            if not path.exists() or path.read_text() != rendered:
                stale.append(name)
        else:
            path.write_text(rendered)
    if stale:
        print(f"stale dashboards (run build_dashboards.py): {stale}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
