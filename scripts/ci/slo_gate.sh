#!/usr/bin/env bash
# Post-deploy SLO gate: query Amazon Managed Prometheus for the 1h burn rate
# and fail the pipeline if the new release is burning error budget too fast.
# (ECS's circuit breaker handles crash-looping tasks; this catches releases
# that are "up" but returning errors.)
set -euo pipefail

MINUTES=10
MAX_BURN=14.4
while [[ $# -gt 0 ]]; do
  case "$1" in
    --minutes) MINUTES="$2"; shift 2 ;;
    --max-burn-rate) MAX_BURN="$2"; shift 2 ;;
    *) echo "unknown arg $1"; exit 2 ;;
  esac
done

: "${AMP_QUERY_URL:?set AMP_QUERY_URL to the workspace prometheus endpoint}"
QUERY='sum(rate(http_requests_total{service="intake-api",env="prod",status="5xx"}[5m])) / sum(rate(http_requests_total{service="intake-api",env="prod"}[5m])) / 0.001'

end=$(( $(date +%s) + MINUTES * 60 ))
while (( $(date +%s) < end )); do
  burn=$(awscurl --service aps --region "${AWS_REGION:-us-east-1}" \
    "${AMP_QUERY_URL}api/v1/query" --data-urlencode "query=${QUERY}" \
    | jq -r '.data.result[0].value[1] // "0"')
  echo "$(date -u +%T) burn rate: $burn (max $MAX_BURN)"
  if awk -v b="$burn" -v m="$MAX_BURN" 'BEGIN{exit !(b > m)}'; then
    echo "::error::SLO gate failed: burn rate $burn > $MAX_BURN. Roll back with: make rollback ENV=prod"
    exit 1
  fi
  sleep 60
done
echo "SLO gate passed"
