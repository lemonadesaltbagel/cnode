#!/usr/bin/env bash
# shellcheck disable=SC2016,SC2001,SC2329,SC2086  # test snippets are single-quoted on purpose
# Unit tests for scripts/wincalc.sh: WSL memory / swap / pagefile formula, the disk-space cap,
# size parsing, and the .wslconfig merge (idempotent, backup, other keys and CRLF kept).
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
. tests/lib.sh
# shellcheck source=scripts/wincalc.sh
. scripts/wincalc.sh
eq() { [ "$1" = "$2" ] || { echo "      got '$1', want '$2'"; return 1; }; }

echo "-- formula: M = floor(RAM - max(6, 0.2 RAM)), swap = ceil(M/4), pagefile P = round(RAM) + M"
for c in "31.1 24 6 55" "16 10 3 26" "8 2 1 10" "32 25 7 57" "64 51 13 115" "128 102 26 230" "4 1 1 5"; do
  set -- $c
  check "RAM $1 GB -> M $2, swap $3, pagefile $4 (commit limit RAM + P)" eq "$(cn_sizes "$1")" "$2 $3 $4"
done
check "worked example: 31.1 GB RAM gives a commit limit of about 86 GB" eq "$(awk 'BEGIN{printf "%.0f", 31.1 + 55}')" 86

echo "-- pagefile placement and disk-space cap (needs P + 20 GB free)"
check "picks the drive with most free space" eq "$(cn_pagefile_plan 55 'C: 120' 'D: 400')" "D: 55 0"
check "exactly P + 20 free is enough" eq "$(cn_pagefile_plan 55 'C: 75')" "C: 55 0"
check "too little space: capped at free - 20, flagged" eq "$(cn_pagefile_plan 55 'C: 60')" "C: 40 1"
check "no room at all: size 0, flagged" eq "$(cn_pagefile_plan 55 'C: 10')" "C: 0 1"
check "no drives reported" eq "$(cn_pagefile_plan 55)" "- 0 1"

echo "-- sizes in .wslconfig"
for c in "24GB 24" "24576MB 24" "24G 24" "1TB 1024" "12.5GB 12" "25769803776 24" "abc "; do
  set -- $c
  check "'$1' -> '${2:-}'" eq "$(cn_size_gb "$1")" "${2:-}"
done

echo "-- .wslconfig merge"
T="$(mktemp -d "${TMPDIR:-/tmp}/cn-wincalc.XXXXXX")"; trap 'rm -rf "$T"' EXIT
SET=(wsl2.memory=24GB wsl2.swap=6GB wsl2.vmIdleTimeout=-1 wsl2.networkingMode=mirrored experimental.autoMemoryReclaim=gradual)
F="$T/new/.wslconfig"; mkdir -p "$T/new"
check "new file: created, no backup" bash -c '[ "$(. scripts/wincalc.sh; cn_wslconfig_merge "$1" 1 '"${SET[*]}"')" = "changed " ] && [ "$(ls -A "$2" | wc -l | tr -d " ")" = 1 ]' _ "$F" "$T/new"
check "new file content" eq "$(cat "$F")" "$(printf '[wsl2]\nmemory=24GB\nswap=6GB\nvmIdleTimeout=-1\nnetworkingMode=mirrored\n\n[experimental]\nautoMemoryReclaim=gradual')"
check "second merge: unchanged" eq "$(cn_wslconfig_merge "$F" 1 "${SET[@]}")" unchanged

F="$T/old/.wslconfig"; mkdir -p "$T/old"
printf '# mine\r\n[wsl2]\r\nmemory=28GB\r\nprocessors=8\r\n\r\n[experimental]\r\nsparseVhd=true\r\n\r\n[other]\r\nx=1\r\n' >"$F"
orig="$(cat "$F")"
out="$(cn_wslconfig_merge "$F" 1 "${SET[@]}")"
check "existing file: changed, backup written first" sh -c 'case "$1" in "changed "*) b="${1#changed }"; [ -f "$b" ] && [ "$(cat "$b")" = "$2" ] ;; *) exit 1 ;; esac' _ "$out" "$orig"
check "explicit memory= kept" eq "$(cn_ini_get "$F" wsl2 memory)" 28GB
check "keys added to [wsl2]" bash -c '[ "$(. scripts/wincalc.sh; cn_ini_get "$1" wsl2 swap)" = 6GB ] && [ "$(. scripts/wincalc.sh; cn_ini_get "$1" wsl2 networkingMode)" = mirrored ]' _ "$F"
check "other keys, sections and comments untouched" sh -c 'tr -d "\r" <"$1" | grep -qx "processors=8" && tr -d "\r" <"$1" | grep -qx "sparseVhd=true" && tr -d "\r" <"$1" | grep -qx "x=1" && tr -d "\r" <"$1" | grep -qx "# mine"' _ "$F"
check "autoMemoryReclaim lands in [experimental], before [other]" sh -c 'tr -d "\r" <"$1" | awk "/^\\[other\\]/{o=NR} /^autoMemoryReclaim=gradual/{a=NR} /^\\[experimental\\]/{e=NR} END{exit !(e<a && a<o)}"' _ "$F"
check "CRLF line endings kept" sh -c '[ "$(grep -c "$(printf "\r")\$" "$1")" = "$(wc -l <"$1" | tr -d " ")" ]' _ "$F"
check "re-merge: unchanged, no second backup" bash -c '[ "$(. scripts/wincalc.sh; cn_wslconfig_merge "$1" 1 '"${SET[*]}"')" = unchanged ] && [ "$(ls -A "$2" | grep -c bak)" = 1 ]' _ "$F" "$T/old"
printf '[WSL2]\nnetworkingMode = NAT\n' >"$T/nat"
cn_wslconfig_merge "$T/nat" 0 wsl2.networkingMode=mirrored >/dev/null
check "case-insensitive section/key; NAT replaced by mirrored, not duplicated" sh -c '[ "$(grep -ci networkingmode "$1")" = 1 ] && grep -q "networkingMode=mirrored" "$1"' _ "$T/nat"
finish
