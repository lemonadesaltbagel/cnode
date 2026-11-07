# shellcheck shell=bash
# Shared helpers for the tests.
FAILS=0
ok() { printf '  ok   %s\n' "$*"; }
bad() { printf '  FAIL %s\n' "$*"; FAILS=$((FAILS + 1)); }
check() { # check "description" command...
  local d="$1"; shift
  if "$@" >/dev/null 2>&1; then ok "$d"; else bad "$d"; fi
}
not() { ! "$@"; }
finish() { [ "$FAILS" -eq 0 ] && { echo "  all checks passed"; exit 0; }; echo "  $FAILS check(s) failed"; exit 1; }

# Docker engine memory gate: skip (exit 77) unless more than MIN_AVAILABLE_MB is available.
mem_gate() {
  local min="${MIN_AVAILABLE_MB:-6000}" avail
  command -v docker >/dev/null 2>&1 || { echo "  no docker CLI: skipping"; exit 77; }
  avail="$(docker run --rm debian:13 awk '/^MemAvailable:/{print int($2/1024)}' /proc/meminfo 2>/dev/null)"
  [ -n "$avail" ] || { echo "  docker engine not usable: skipping"; exit 77; }
  if [ "$avail" -le "$min" ]; then echo "  only ${avail} MB available on the docker host (need > ${min}): skipping"; exit 77; fi
  echo "  docker host: ${avail} MB available"
}

# tar of the repository (tracked + untracked, minus .git) on stdout
repo_tar() { tar -C "$1" --exclude=.git -cf - .; }
