#!/usr/bin/env bash
set -euo pipefail

# Run the real-wire smoke test. The compose file deliberately pins every image so a
# future tusd or MinIO upgrade cannot silently change the protocol under test.
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
# shellcheck source=integration/tusd/lib.sh
source "$root/integration/tusd/lib.sh"
amphora_require_docker
amphora_require_commands curl python3 shasum
compose=(docker compose -f "$root/integration/tusd/docker-compose.yml")
endpoint=${TUSD_ENDPOINT:-http://127.0.0.1:8080/files/}
work=$(mktemp -d)
trap 'rm -rf "$work"; "${compose[@]}" down -v --remove-orphans' EXIT

"${compose[@]}" up -d
for _ in $(seq 1 60); do
  if curl --silent --output /dev/null "$endpoint"; then break; fi
  sleep 1
done
curl --silent --output /dev/null "$endpoint"

# Three MiB is large enough to exercise tusd's S3 object path rather than a tiny test body.
python3 - "$work/source.bin" <<'PY'
import sys
from pathlib import Path
Path(sys.argv[1]).write_bytes(bytes((n % 251 for n in range(3 * 1024 * 1024))))
PY
size=$(wc -c < "$work/source.bin" | tr -d ' ')

create_headers="$work/create.headers"
curl --silent --show-error --fail-with-body -D "$create_headers" -o /dev/null \
  -X POST "$endpoint" \
  -H 'Tus-Resumable: 1.0.0' \
  -H "Upload-Length: $size" \
  -H 'Content-Length: 0'
location=$(awk 'BEGIN { IGNORECASE=1 } /^Location:/ { sub(/^[^:]*:[[:space:]]*/, ""); gsub(/\r/, ""); print; exit }' "$create_headers")
[[ -n "$location" ]] || { echo 'tusd did not return Location' >&2; exit 1; }
case "$location" in
  http://*|https://*) upload_url=$location ;;
  *) upload_url="${endpoint%/}/${location#/}" ;;
esac

head_headers="$work/head.headers"
curl --silent --show-error --fail-with-body -D "$head_headers" -o /dev/null \
  --head "$upload_url" -H 'Tus-Resumable: 1.0.0'
grep -Eiq '^Upload-Offset:[[:space:]]*0' "$head_headers"

patch_headers="$work/patch.headers"
curl --silent --show-error --fail-with-body -D "$patch_headers" -o /dev/null \
  -X PATCH "$upload_url" -H 'Tus-Resumable: 1.0.0' \
  -H 'Content-Type: application/offset+octet-stream' \
  -H 'Upload-Offset: 0' --data-binary "@$work/source.bin"
grep -Eiq "^Upload-Offset:[[:space:]]*$size" "$patch_headers"

# The interop pin is fail-closed: a request advertising a different tus version must not create
# an upload. This catches accidental negotiation or a proxy stripping the protocol header.
if curl --silent --show-error --output /dev/null -w '%{http_code}' \
    -X POST "$endpoint" -H 'Tus-Resumable: 9.9.9' \
    -H "Upload-Length: $size" -H 'Content-Length: 0' | grep -qE '^(4|5)'; then
  :
else
  echo 'tusd accepted an unpinned Tus-Resumable version' >&2
  exit 1
fi

curl --silent --show-error --fail-with-body -o /dev/null \
  -X DELETE "$upload_url" -H 'Tus-Resumable: 1.0.0' -H 'Content-Length: 0'
status=$(curl --silent --output /dev/null --write-out '%{http_code}' \
  --head "$upload_url" -H 'Tus-Resumable: 1.0.0')
[[ "$status" == 404 || "$status" == 410 ]] || {
  echo "terminated upload still exists (HEAD returned $status)" >&2
  exit 1
}

printf 'tusd v2 + S3 integration: 3 MiB create/head/patch/terminate passed; version mismatch rejected\n'
