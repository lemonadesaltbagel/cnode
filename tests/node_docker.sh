#!/usr/bin/env bash
# shellcheck disable=SC2016,SC2001  # test snippets are single-quoted on purpose
# tests/node_docker.sh <image>   compute-node install inside a fresh container of <image>.
# The repository is streamed into the container with tar; nothing is mounted from the host.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
. tests/lib.sh
IMG="${1:?usage: node_docker.sh <image>}"
mem_gate
name="cntest-node-$(echo "$IMG" | tr -c 'a-z0-9\n' '-')$$"
repo_tar . | docker run --rm -i --name "$name" -e NO_DOCKER="${NO_DOCKER:-0}" "$IMG" \
  bash -c 'mkdir -p /src && tar -x -C /src && exec bash /src/tests/node_in_container.sh </dev/null'
