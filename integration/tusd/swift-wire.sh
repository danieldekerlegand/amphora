#!/usr/bin/env bash
set -euo pipefail

# The Swift port against a real tusd, across a real process death, with disk measured.
#
# `run.sh` proves the SERVER works by driving it with curl. This proves the SWIFT PORT works, which
# is a different claim and the one tasklist 80 recorded without ever making. Three things happen
# here that cannot happen inside a single process:
#
#   1. A process uploads a prefix and is then killed with SIGKILL. The driver asserts on exit
#      status 137 — proof the death was a signal, not a return.
#   2. A SECOND process, sharing nothing with the first but the upload URL on its command line,
#      recovers the offset from the server with HEAD and finishes the upload.
#   3. Peak extra disk is SAMPLED throughout, not reasoned about. Invariant I6 says the transport
#      stages no chunk file; a staged remainder would appear here as megabytes.
#
# The prefix deliberately exceeds the S3 multipart minimum part size (5 MiB — see
# docs/reference/platform-constraints.md), so tusd has flushed a real part into MinIO before the
# process dies. Otherwise the "resume" would only read back a number tusd still had in memory.

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
# shellcheck source=integration/tusd/lib.sh
source "$root/integration/tusd/lib.sh"
amphora_require_docker
amphora_require_commands curl python3 shasum swift

compose=(docker compose -f "$root/integration/tusd/docker-compose.yml")
endpoint=${TUSD_ENDPOINT:-http://127.0.0.1:8080/files/}
size=$((8 * 1024 * 1024))
prefix=$((5 * 1024 * 1024 + 256 * 1024))   # > the 5 MiB S3 part minimum, < size
# Peak extra disk allowed under the sampled tree, in KiB. A transport that staged the remainder
# would need ~2816 KiB here; a transport that staged the whole file, ~8192. 256 KiB is far below
# either and above the noise of a few response-header files.
budget_kib=256

work=$(mktemp -d)
scratch="$work/scratch"
mkdir -p "$scratch"
sampler_pid=""
cleanup() {
  [[ -n "$sampler_pid" ]] && kill "$sampler_pid" 2>/dev/null
  rm -rf "$work"
  "${compose[@]}" down -v --remove-orphans
}
trap cleanup EXIT

"${compose[@]}" up -d
for _ in $(seq 1 60); do
  curl --silent --output /dev/null "$endpoint" && break
  sleep 1
done
curl --silent --output /dev/null "$endpoint"

# Built before the stack matters, and before sampling starts: compiler output goes to ios/.build,
# which is outside the sampled tree, but a build racing the measurement would still muddy it.
swift build --package-path "$root/ios" --product AmphoraTusdIntegration >/dev/null
binary="$(swift build --package-path "$root/ios" --show-bin-path)/AmphoraTusdIntegration"
[[ -x "$binary" ]] || { echo "AmphoraTusdIntegration was not built at $binary" >&2; exit 1; }

python3 - "$work/source.bin" "$size" <<'PY'
import sys
from pathlib import Path
Path(sys.argv[1]).write_bytes(bytes(n % 251 for n in range(int(sys.argv[2]))))
PY
source="$work/source.bin"
sha=$(shasum -a 256 "$source" | awk '{print $1}')

# --- the measurement -----------------------------------------------------------------------------
# Baseline is taken with the source already in place, so what is measured is strictly what the
# upload adds. TMPDIR is redirected into the sampled tree so a staging file placed "somewhere
# temporary" lands where the sampler can see it rather than in /var/folders where it could not.
baseline_kib=$(du -sk "$work" | awk '{print $1}')
peak_file="$work/peak.kib"
echo "$baseline_kib" > "$peak_file"
(
  while :; do
    current=$(du -sk "$work" 2>/dev/null | awk '{print $1}')
    if [[ -n "$current" ]] && (( current > $(cat "$peak_file") )); then
      echo "$current" > "$peak_file"
    fi
    sleep 0.05
  done
) &
sampler_pid=$!
export TMPDIR="$scratch"

# --- phase 1: create -----------------------------------------------------------------------------
upload_url=$("$binary" create "$endpoint" "$size")
[[ -n "$upload_url" ]] || { echo 'the Swift port produced no upload URL' >&2; exit 1; }
echo "created $upload_url"

# --- phase 2: upload a prefix, then die ----------------------------------------------------------
set +e
"$binary" send-prefix "$upload_url" "$source" "$prefix"
killed_status=$?
set -e
# 137 = 128 + SIGKILL(9). An ordinary `exit 1` here would mean the phase FAILED and reported it,
# which is the opposite of what this phase is for, so the status is checked exactly.
[[ "$killed_status" == 137 ]] || {
  echo "send-prefix exited $killed_status; expected 137 (SIGKILL). Nothing was interrupted." >&2
  exit 1
}
echo "sender died: exit status $killed_status (SIGKILL)"

# --- phase 3: a new process resumes --------------------------------------------------------------
"$binary" resume "$upload_url" "$source"

# --- phase 4: the bytes at rest ------------------------------------------------------------------
# Read the object out of MinIO rather than trusting tusd's offset bookkeeping. The alias is set in
# the SAME shell as the read: `mc`'s config lives in the container's ~/.mc, and the alias created by
# the create-bucket container does not exist in this one.
#
# tusd's S3 upload id is `<object-key>+<s3-multipart-upload-id>`; only the part before the `+` is
# the object. Passing the whole id yields "Object does not exist", which is what
# `integration/tusd/resume.sh` would have reported had it ever got this far.
upload_id=${upload_url##*/}
object_key=${upload_id%%+*}
stored=$("${compose[@]}" exec -T minio sh -c \
  "mc alias set local http://127.0.0.1:9000 amphora amphora-secret >/dev/null \
   && mc cat local/amphora-uploads/uploads/$object_key" | shasum -a 256 | awk '{print $1}')
[[ "$stored" == "$sha" ]] || {
  echo "S3 object checksum $stored differs from the source $sha" >&2; exit 1;
}
echo "bytes at rest in MinIO match the source: sha256 $stored"

# --- phase 5: protocol pins ----------------------------------------------------------------------
"$binary" reject-version "$endpoint"
"$binary" terminate "$upload_url"

# --- the verdict on storage ----------------------------------------------------------------------
kill "$sampler_pid" 2>/dev/null || true
wait "$sampler_pid" 2>/dev/null || true
sampler_pid=""
peak_kib=$(cat "$peak_file")
extra_kib=$((peak_kib - baseline_kib))
printf 'peak extra disk during transfer: %s KiB (baseline %s KiB, peak %s KiB) for a %s KiB upload\n' \
  "$extra_kib" "$baseline_kib" "$peak_kib" "$((size / 1024))"
(( extra_kib <= budget_kib )) || {
  echo "I6 violated: transferring ${size} bytes added ${extra_kib} KiB of disk, over the ${budget_kib} KiB budget" >&2
  exit 1
}

printf 'Swift real wire: %s MiB uploaded across a SIGKILL at offset %s, resumed by a new process, checksum verified, peak extra disk %s KiB\n' \
  "$((size / 1024 / 1024))" "$prefix" "$extra_kib"
