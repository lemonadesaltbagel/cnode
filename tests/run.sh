#!/usr/bin/env bash
# tests/run.sh [lint|control|node|multinode|ps|all]...   (default: all)
#
#   lint       shellcheck + bash -n on every shell script, ASCII/CRLF checks on install.ps1
#   control    control-node install in a throwaway HOME on this machine; ssh, mutagen, docker,
#              brew are stubbed, so nothing outside that HOME is touched; checks idempotency
#   node       compute-node install in fresh Debian 13 and Ubuntu 24.04 containers (no systemd)
#   multinode  2 compute-node containers + 1 control container with 2 users: registry, host-key
#              checks, cn-authorize, rx -n, wsync -n to both nodes, rx nodes --json with a node down
#   ps         parse-only check of install.ps1 with Windows PowerShell or pwsh (never executed)
#
# Docker tests use the current docker context (any Linux engine). They first check that the
# engine has more than MIN_AVAILABLE_MB (default 6000) MB available and skip otherwise.
# Never uses GPUs. Env: CN_TEST_PS_SSH=<ssh host> runs the ps check on a WSL host over SSH.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
T="$(pwd)/tests"
results=()
run() {
  local name="$1"; shift
  echo; echo "################ $name"
  "$@"; local rc=$?
  case "$rc" in 0) results+=("PASS  $name") ;; 77) results+=("SKIP  $name") ;; *) results+=("FAIL  $name (exit $rc)") ;; esac
}
[ $# -gt 0 ] || set -- all
for t in "$@"; do
  case "$t" in
    lint) run lint bash "$T/lint.sh" ;;
    control) run control bash "$T/control_local.sh" ;;
    node) run "node (debian:13)" bash "$T/node_docker.sh" debian:13
          run "node (ubuntu:24.04)" bash "$T/node_docker.sh" ubuntu:24.04 ;;
    multinode) run multinode bash "$T/multinode.sh" ;;
    ps) run ps bash "$T/ps_parse.sh" ;;
    all) "$0" lint control node multinode ps; exit $? ;;
    *) echo "unknown test: $t" >&2; exit 2 ;;
  esac
done
echo; echo "################ summary"
printf '%s\n' "${results[@]}"
printf '%s\n' "${results[@]}" | grep -q '^FAIL' && exit 1
exit 0
