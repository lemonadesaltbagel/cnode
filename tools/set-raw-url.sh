#!/usr/bin/env bash
# tools/set-raw-url.sh <url>   fill in the download URL placeholder once the repository exists.
#   e.g. tools/set-raw-url.sh https://raw.githubusercontent.com/<owner>/<repo>/main
set -euo pipefail
url="${1:?usage: tools/set-raw-url.sh https://raw.githubusercontent.com/<owner>/<repo>/main}"
url="${url%/}"
cd "$(dirname "$0")/.."
files=(install.sh install.ps1 scripts/node-setup.sh scripts/control-setup.sh README.md README.zh-CN.md)
for f in "${files[@]}"; do
  tmp="$(mktemp)"; sed "s#<raw-url>#${url}#g" "$f" >"$tmp" && cat "$tmp" >"$f" && rm -f "$tmp"
done
grep -rn '<raw-url>' "${files[@]}" || echo "placeholder replaced in ${#files[@]} files"
