#!/usr/bin/env bash
# tests/run.sh [lint|unit|ps|control|node|multinode|all]...   (default: all)
#
#   lint       shellcheck + bash -n on every shell script, CRLF and URL checks
#   unit       the WSL memory / swap / pagefile formula and the .wslconfig merge (no Docker)
#   ps         parse-only check of the generated PowerShell (never executed; CN_TEST_PS_SSH=<wsl host>)
#   control    control-node install in a throwaway HOME on this machine; ssh, mutagen, docker,
#              brew are stubbed, so nothing outside that HOME is touched; checks idempotency
#   node       compute-node install in fresh Debian 13 and Ubuntu 24.04 containers (no systemd)
#   multinode  2 compute-node containers + 1 control container with 2 users: registry, host-key
#              checks, cn-authorize, rx -n, wsync -n to both nodes, rx nodes --json with a node down
#
# Docker tests use the current docker context (any Linux engine). They first check that the
# engine has more than MIN_AVAILABLE_MB (default 7000) MB available and skip otherwise.
# Never uses GPUs.
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
    unit) run unit bash "$T/wincalc_unit.sh" ;;
    ps) run ps bash "$T/ps_parse.sh" ;;
    control) run control bash "$T/control_local.sh" ;;
    node) run "node (debian:13)" bash "$T/node_docker.sh" debian:13
          run "node (ubuntu:24.04)" bash "$T/node_docker.sh" ubuntu:24.04 ;;
    multinode) run multinode bash "$T/multinode.sh" ;;
    all) "$0" lint unit ps control node multinode; exit $? ;;
    *) echo "unknown test: $t" >&2; exit 2 ;;
  esac
done
echo; echo "################ summary"
printf '%s\n' "${results[@]}"
printf '%s\n' "${results[@]}" | grep -q '^FAIL' && exit 1
exit 0
