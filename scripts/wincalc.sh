# shellcheck shell=bash
# Pure helpers for the Windows side of a WSL compute node (sourced by windows-setup.sh and tests).
# No side effects except cn_wslconfig_merge, which edits the file it is given.

# cn_sizes RAM_GB -> "M SWAP P"
#   M    WSL memory cap   = floor(RAM - max(6, 0.2 * RAM))       (31.1 GB -> 24)
#   SWAP WSL swap         = ceil(M / 4)                          (24 -> 6)
#   P    total pagefile   = round(RAM) + M                       (31.1 + 24 -> 55)
# Windows' commit limit is RAM + pagefile; it must cover Windows itself, the WSL VM (up to M) and
# GPU shared memory, or the machine crashes when they are all busy. RAM + P = 2 RAM + M (86 GB here).
cn_sizes() {
  awk -v r="$1" 'BEGIN {
    if (r + 0 <= 0) { print "0 0 0"; exit 1 }
    res = 0.2 * r; if (res < 6) res = 6
    m = int(r - res); if (m < 1) m = 1
    s = int(m / 4); if (s * 4 < m) s++
    p = int(r + 0.5) + m
    print m, s, p }'
}

# cn_pagefile_plan P "DRIVE FREE_GB" ... -> "DRIVE SIZE_GB CAPPED"
#   picks the drive with the most free space; needs P + 20 GB free there, else caps the
#   pagefile at free - 20 GB (CAPPED=1; SIZE 0 when even that is impossible)
cn_pagefile_plan() {
  local p="$1"; shift
  printf '%s\n' "$@" | awk -v p="$p" '
    NF >= 2 && $2 + 0 > best { best = $2 + 0; d = $1 }
    END {
      if (d == "") { print "- 0 1"; exit }
      if (best >= p + 20) print d, p, 0
      else { c = int(best - 20); if (c < 0) c = 0; print d, c, 1 }
    }'
}

# cn_size_gb "24GB" | "24576MB" | "24G" | "1TB" -> whole GB (floor), empty if unparsable
cn_size_gb() {
  printf '%s\n' "$1" | awk '{
    v = toupper($0); gsub(/[ \t\r]/, "", v)
    if (match(v, /^[0-9]+(\.[0-9]+)?/) == 0) exit
    n = substr(v, 1, RLENGTH) + 0; u = substr(v, RLENGTH + 1)
    if (u == "" || u == "B") n = n / 1073741824
    else if (u == "K" || u == "KB") n = n / 1048576
    else if (u == "M" || u == "MB") n = n / 1024
    else if (u == "G" || u == "GB") n = n
    else if (u == "T" || u == "TB") n = n * 1024
    else exit
    print int(n) }'
}

# cn_ini_get FILE SECTION KEY -> value (section and key names are case-insensitive)
cn_ini_get() {
  [ -f "$1" ] || return 0
  tr -d '\r' <"$1" | awk -v s="$2" -v k="$3" '
    /^[ \t]*\[/ { cur = $0; gsub(/[][ \t]/, "", cur); insec = (tolower(cur) == tolower(s)); next }
    insec && index($0, "=") {
      key = substr($0, 1, index($0, "=") - 1); gsub(/[ \t]/, "", key)
      if (tolower(key) == tolower(k)) { v = substr($0, index($0, "=") + 1); gsub(/^[ \t]+|[ \t]+$/, "", v); print v; exit }
    }'
}

# cn_ini_text_set SECTION KEY VALUE  (stdin -> stdout, LF text): replace the key in its section or
# add it at the end of the section (creating the section at the end of the file)
cn_ini_text_set() {
  awk -v s="$1" -v k="$2" -v v="$3" '
    function blanks() { while (nb > 0) { print ""; nb-- } }
    /^[ \t]*\[/ {
      if (insec && !done) { print k "=" v; done = 1 }      # before the blank lines ending the section
      blanks()
      cur = $0; gsub(/[][ \t]/, "", cur); insec = (tolower(cur) == tolower(s)); if (insec) seen = 1
      print; next }
    /^[ \t]*$/ { nb++; next }
    { blanks() }
    insec && index($0, "=") {
      key = substr($0, 1, index($0, "=") - 1); gsub(/[ \t]/, "", key)
      if (tolower(key) == tolower(k)) { if (!done) print k "=" v; done = 1; next }
    }
    { print }
    END {
      if (insec && !done) { print k "=" v; done = 1 }
      had = nb; blanks()
      if (!seen) { if (NR > 0 && !had) print ""; print "[" s "]"; print k "=" v }
    }'
}

# cn_wslconfig_merge FILE KEEP_MEMORY SECTION.KEY=VALUE ...
#   Sets each key, keeps every other line; with KEEP_MEMORY=1 an existing wsl2.memory stays.
#   Keeps CRLF line endings if the file used them. Backs up FILE to FILE.bak-<time> before the
#   first change. Prints "changed <backup>" or "unchanged".
cn_wslconfig_merge() {
  local f="$1" keep="$2" crlf=0 tmp new kv sec key val bak=""
  shift 2
  tmp="$(mktemp)"; new="$(mktemp)"
  if [ -f "$f" ]; then
    grep -q $'\r' "$f" && crlf=1
    tr -d '\r' <"$f" >"$tmp"
  fi
  for kv in "$@"; do
    sec="${kv%%.*}"; kv="${kv#*.}"; key="${kv%%=*}"; val="${kv#*=}"
    if [ "$keep" = 1 ] && [ "$sec.$key" = wsl2.memory ] && [ -n "$(cn_ini_get "$tmp" wsl2 memory)" ]; then continue; fi
    cn_ini_text_set "$sec" "$key" "$val" <"$tmp" >"$new" && cat "$new" >"$tmp"
  done
  if [ "$crlf" = 1 ]; then awk '{ printf "%s\r\n", $0 }' "$tmp" >"$new"; else cat "$tmp" >"$new"; fi
  if [ -f "$f" ] && cmp -s "$new" "$f"; then echo unchanged
  else
    if [ -f "$f" ]; then bak="$f.bak-$(date +%Y%m%d-%H%M%S)"; cp -p "$f" "$bak"; fi
    cat "$new" >"$f"; echo "changed ${bak:-}"
  fi
  rm -f "$tmp" "$new"
}
