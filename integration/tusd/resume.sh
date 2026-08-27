#!/usr/bin/env bash
set -euo pipefail

# Proves resumability across a killed client process. The second client uses HEAD as its only
# offset source, then MinIO is read directly to verify that tusd persisted the exact source bytes.
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
  curl --silent --output /dev/null "$endpoint" && break
  sleep 1
done

python3 - "$work/source.bin" <<'PY'
import sys
from pathlib import Path
Path(sys.argv[1]).write_bytes(bytes((n % 251 for n in range(3 * 1024 * 1024))))
PY
source="$work/source.bin"
size=$(wc -c < "$source" | tr -d ' ')
sha=$(shasum -a 256 "$source" | awk '{print $1}')

headers="$work/create.headers"
curl --silent --show-error --fail-with-body -D "$headers" -o /dev/null \
  -X POST "$endpoint" -H 'Tus-Resumable: 1.0.0' \
  -H "Upload-Length: $size" -H 'Content-Length: 0'
location=$(awk 'BEGIN { IGNORECASE=1 } /^Location:/ { sub(/^[^:]*:[[:space:]]*/, ""); gsub(/\r/, ""); print; exit }' "$headers")
case "$location" in
  http://*|https://*) upload_url=$location ;;
  *) upload_url="${endpoint%/}/${location#/}" ;;
esac
# tusd's S3 upload id is `<object-key>+<s3-multipart-upload-id>`. Only the part before the `+` names
# the object; the whole id reads back as "Object does not exist".
upload_id=${upload_url##*/}
object_key=${upload_id%%+*}

# Slow the body enough that SIGKILL lands after a durable, non-zero partial write. Killing curl is
# intentional: the next request is a fresh process with no local offset state.
curl --silent --show-error --fail-with-body --limit-rate 64k -X PATCH "$upload_url" \
  -H 'Tus-Resumable: 1.0.0' -H 'Content-Type: application/offset+octet-stream' \
  -H 'Upload-Offset: 0' --data-binary "@$source" >/dev/null &
patch_pid=$!
sleep 2
kill -KILL "$patch_pid" 2>/dev/null || true
wait "$patch_pid" 2>/dev/null || true

head_headers="$work/resume.headers"
curl --silent --show-error --fail-with-body -D "$head_headers" -o /dev/null \
  --head "$upload_url" -H 'Tus-Resumable: 1.0.0'
offset=$(awk 'BEGIN { IGNORECASE=1 } /^Upload-Offset:/ { sub(/^[^:]*:[[:space:]]*/, ""); gsub(/\r/, ""); print; exit }' "$head_headers")
[[ "$offset" =~ ^[0-9]+$ && "$offset" -gt 0 && "$offset" -lt "$size" ]] || {
  echo "killed process did not leave a resumable offset: $offset" >&2; exit 1;
}

# Relaunch equivalent: a new curl process starts exactly at the server-reported offset.
tail_bytes=$((size - offset))
tail -c "$tail_bytes" "$source" | curl --silent --show-error --fail-with-body -X PATCH "$upload_url" \
  -H 'Tus-Resumable: 1.0.0' -H 'Content-Type: application/offset+octet-stream' \
  -H "Upload-Offset: $offset" --data-binary @- >/dev/null
final=$(curl --silent --show-error --fail-with-body -D - -o /dev/null \
  --head "$upload_url" -H 'Tus-Resumable: 1.0.0' | awk 'BEGIN { IGNORECASE=1 } /^Upload-Offset:/ { sub(/^[^:]*:[[:space:]]*/, ""); gsub(/\r/, ""); print; exit }')
[[ "$final" == "$size" ]] || { echo "resume ended at offset $final, expected $size" >&2; exit 1; }

# tusd's S3 backend stores the upload under its configured object prefix. Read it through MinIO's
# client so this verifies bytes at rest, not only the HTTP offset bookkeeping.
# The alias is set in the SAME shell as the read. `mc` keeps its config in the container's ~/.mc,
# and the alias the create-bucket container made lives in a different container's filesystem.
actual=$(docker compose -f "$root/integration/tusd/docker-compose.yml" exec -T minio sh -c \
  "mc alias set local http://127.0.0.1:9000 amphora amphora-secret >/dev/null \
   && mc cat local/amphora-uploads/uploads/$object_key" | shasum -a 256 | awk '{print $1}')
[[ "$actual" == "$sha" ]] || { echo "S3 checksum $actual differs from source $sha" >&2; exit 1; }

printf 'tusd resume: process death at offset %s, resumed to %s, checksum %s\n' "$offset" "$final" "$actual"
