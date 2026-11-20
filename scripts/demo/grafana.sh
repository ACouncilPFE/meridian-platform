#!/usr/bin/env bash
# Run Grafana locally against the demo's Amazon Managed Prometheus workspace
# (SigV4-signed with your current AWS credentials) plus AWS X-Ray traces.
# Same dashboards-as-code as prod; no Managed Grafana / Identity Center needed.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck disable=SC1091
source "$ROOT/.demo.env"

WORK="$(mktemp -d)"
mkdir -p "$WORK/datasources" "$WORK/dashboards"
cp "$ROOT/observability/grafana/provisioning/dashboards/dashboards.yml" "$WORK/dashboards/"
cat > "$WORK/datasources/amp.yml" <<EOF
apiVersion: 1
datasources:
  - name: Amazon Managed Prometheus (demo)
    uid: prometheus
    type: prometheus
    access: proxy
    url: ${AMP_QUERY_URL%/}
    isDefault: true
    jsonData:
      sigV4Auth: true
      sigV4AuthType: default
      sigV4Region: $REGION
      httpMethod: POST
  - name: AWS X-Ray
    uid: xray
    type: grafana-x-ray-datasource
    jsonData:
      authType: default
      defaultRegion: $REGION
EOF

# Short-lived credentials from whatever the CLI is using (SSO, profile, env),
# passed via a 0600 env-file that is deleted as soon as the container starts.
CREDS_FILE="$WORK/creds.env"
(umask 077 && aws configure export-credentials --format env-no-export > "$CREDS_FILE")

docker rm -f meridian-demo-grafana >/dev/null 2>&1 || true
docker run -d --name meridian-demo-grafana -p 3000:3000 \
  --env-file "$CREDS_FILE" \
  -e AWS_REGION="$REGION" \
  -e GF_AUTH_SIGV4_AUTH_ENABLED=true \
  -e GF_AUTH_ANONYMOUS_ENABLED=true \
  -e GF_AUTH_ANONYMOUS_ORG_ROLE=Admin \
  -e GF_INSTALL_PLUGINS=grafana-x-ray-datasource \
  -v "$WORK:/etc/grafana/provisioning:ro" \
  -v "$ROOT/observability/grafana/dashboards:/var/lib/grafana/dashboards:ro" \
  grafana/grafana:11.2.2 >/dev/null
rm -f "$CREDS_FILE"

echo "Grafana: http://localhost:3000  (choose env = demo in the dashboard dropdown)"
echo "Credentials are short-lived; re-run this script if panels show auth errors."
