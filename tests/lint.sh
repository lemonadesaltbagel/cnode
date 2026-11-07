#!/usr/bin/env bash
# Lint: shellcheck and bash -n for every shell script; encoding checks for install.ps1.
# shellcheck disable=SC2016  # (sh -c snippets are single-quoted on purpose)
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
. tests/lib.sh
scripts=(install.sh scripts/*.sh tools/*.sh tests/*.sh bin/cnode node/cn-status node/cn-authorize)
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
check "install.ps1 is ASCII-only (Windows PowerShell 5.1 misreads BOM-less UTF-8)" \
  sh -c '[ "$(LC_ALL=C tr -d "\000-\177" <install.ps1 | wc -c | tr -d " ")" = 0 ]'
cr="$(printf '\r')"
check "no CRLF in shell scripts" sh -c "! grep -l '$cr' ${scripts[*]}"
check "executable bits" sh -c 'for f in install.sh bin/cnode node/cn-status node/cn-authorize scripts/*.sh tools/*.sh tests/run.sh; do [ -x "$f" ] || exit 1; done'
check "<raw-url> placeholder present (filled in by tools/set-raw-url.sh)" grep -q '<raw-url>' install.sh install.ps1
finish
