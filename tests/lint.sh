#!/usr/bin/env bash
# Lint: shellcheck and bash -n for every shell script; CRLF, executable bits, download URL.
# shellcheck disable=SC2016  # (sh -c snippets are single-quoted on purpose)
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
. tests/lib.sh
scripts=(install.sh scripts/*.sh tests/*.sh bin/cnode node/cn-status node/cn-authorize)
for f in "${scripts[@]}"; do check "bash -n $f" bash -n "$f"; done
if command -v shellcheck >/dev/null 2>&1; then
  if shellcheck -x "${scripts[@]}"; then ok "shellcheck: ${#scripts[@]} files clean ($(shellcheck --version | awk '/^version/{print $2}'))"; else bad shellcheck; fi
elif command -v docker >/dev/null 2>&1; then
  if tar -cf - "${scripts[@]}" .shellcheckrc | docker run --rm -i --entrypoint sh koalaman/shellcheck-alpine:stable \
       -c "mkdir /s && tar -x -C /s && cd /s && shellcheck -x ${scripts[*]}"; then
    ok "shellcheck (docker): ${#scripts[@]} files clean"; else bad shellcheck; fi
else
  echo "  shellcheck not available (brew install shellcheck)"; exit 77
fi
cr="$(printf '\r')"
check "no CRLF in shell scripts" sh -c "! grep -l '$cr' ${scripts[*]}"
check "executable bits" sh -c 'for f in install.sh bin/cnode node/cn-status node/cn-authorize scripts/*.sh tests/run.sh; do [ -x "$f" ] || exit 1; done'
check "download URL set in install.sh" grep -qE "^CN_RAW_URL_DEFAULT='https://raw.githubusercontent.com/[^/]+/[^/]+/[^/']+'" install.sh
finish
