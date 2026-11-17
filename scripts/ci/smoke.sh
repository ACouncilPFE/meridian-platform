#!/usr/bin/env bash
# Post-deploy smoke test with synthetic data.
set -euo pipefail
URL="${1:?usage: smoke.sh <base-url>}"
H=(-H "x-actor: svc:smoke" -H "content-type: application/json")

for i in $(seq 1 30); do
  curl -fsS "$URL/healthz" >/dev/null && break
  echo "waiting for $URL ($i)"; sleep 10
done

ref="smoke-$(date +%s)"
id=$(curl -fsS "${H[@]}" -X POST "$URL/v1/patients" \
  -d "{\"external_ref\":\"$ref\",\"name\":\"Smoke Test\",\"date_of_birth\":\"1990-01-01\",\"zip_code\":\"02139\"}" | jq -r .id)
got=$(curl -fsS "${H[@]}" "$URL/v1/patients/$id" | jq -r .name)
[[ "$got" == "Smoke Test" ]] || { echo "::error::round-trip failed"; exit 1; }
curl -fsS "$URL/metrics" | grep -q '^http_requests_total' || { echo "::error::metrics missing"; exit 1; }
echo "smoke OK"
