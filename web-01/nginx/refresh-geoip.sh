#!/usr/bin/env bash
# Refresh the DB-IP IP-to-Country Lite database in place (no image rebuild).
# DB-IP Lite is free, MMDB format, NO license key, monthly, CC BY 4.0.
# Attribution: "IP Geolocation by DB-IP" (https://db-ip.com).
#
# Usage (on web-01, monthly cron):
#   GEOIP_DIR=/opt/wiriri/nginx/geoip /opt/wiriri/nginx/refresh-geoip.sh
# Requires the geo DB to be host-mounted into the nginx container
# (uncomment the ./nginx/geoip volume in docker-compose.yml). nginx geoip2
# auto_reload (60m) picks up the new file with no reload needed.
set -euo pipefail

GEOIP_DIR="${GEOIP_DIR:-/opt/wiriri/nginx/geoip}"
DEST="${GEOIP_DIR}/dbip-country-lite.mmdb"
TMP="$(mktemp)"
trap 'rm -f "$TMP" "$TMP.gz"' EXIT

mkdir -p "$GEOIP_DIR"

month="$(date -u +%Y-%m)"
prev="$(date -u -d 'last month' +%Y-%m 2>/dev/null || echo "$month")"
base="https://download.db-ip.com/free"

echo "[refresh-geoip] downloading dbip-country-lite ${month}…"
if ! curl -fsSL "${base}/dbip-country-lite-${month}.mmdb.gz" -o "$TMP.gz"; then
  echo "[refresh-geoip] ${month} not yet published, trying ${prev}…"
  curl -fsSL "${base}/dbip-country-lite-${prev}.mmdb.gz" -o "$TMP.gz"
fi

gunzip -c "$TMP.gz" > "$TMP"
test -s "$TMP"
# Atomic swap so nginx never reads a half-written file.
mv -f "$TMP" "$DEST"
trap - EXIT
rm -f "$TMP.gz"
echo "[refresh-geoip] updated ${DEST} ($(stat -c%s "$DEST" 2>/dev/null || echo '?') bytes)"
