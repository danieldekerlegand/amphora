#!/usr/bin/env bash
# Shared preconditions for the real-wire tusd harness. Sourced, never executed.
#
# The exit-code contract is deliberately three-valued:
#
#   0   the run happened and it passed
#   1   the run happened and it failed
#   77  the run did NOT happen — no Docker on this machine. Nothing is proven either way.
#
# Two-valued harnesses are how tasklist 80 came to record "both platforms complete an upload
# against a real tusd instance" as passing on a machine whose Docker daemon was never reachable.
# "Could not run" and "ran and passed" are different claims and must not share an exit code.
# 77 is the automake/TAP convention for a skip, so CI runners already understand it.
#
# Set AMPHORA_REQUIRE_DOCKER=1 wherever a skip must be red instead — CI, or any run whose entire
# purpose is to produce evidence that bytes crossed a wire.

amphora_skip() {
  if [[ ${AMPHORA_REQUIRE_DOCKER:-0} == 1 ]]; then
    printf 'FAIL: %s (AMPHORA_REQUIRE_DOCKER=1 forbids skipping)\n' "$1" >&2
    exit 1
  fi
  printf 'SKIP (77): %s. This run proved nothing; do not record it as a pass.\n' "$1" >&2
  exit 77
}

amphora_require_docker() {
  command -v docker >/dev/null 2>&1 || amphora_skip 'the docker CLI is not on PATH'
  docker info --format '{{.ServerVersion}}' >/dev/null 2>&1 \
    || amphora_skip 'no reachable Docker daemon'
  docker compose version >/dev/null 2>&1 \
    || amphora_skip 'the Docker Compose v2 plugin is unavailable'
}

amphora_require_commands() {
  local missing=()
  local cmd
  for cmd in "$@"; do
    command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
  done
  (( ${#missing[@]} == 0 )) || amphora_skip "missing required tools: ${missing[*]}"
}
