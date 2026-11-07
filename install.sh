#!/usr/bin/env bash
# compute-node installer. One command per role:
#
#   control node (macOS / Linux, as your normal user):
#     curl -fsSL https://raw.githubusercontent.com/lemonadesaltbagel/cnode/main/install.sh | bash -s -- control --host <host> --user <user>
#   compute node (Debian/Ubuntu, plain Linux or inside WSL2), as root:
#     curl -fsSL https://raw.githubusercontent.com/lemonadesaltbagel/cnode/main/install.sh | sudo bash -s -- node [--user <user>]
#   On Windows, run the node command inside the WSL2 distro; nothing on the Windows side is changed.
#
# `install.sh control --help` / `install.sh node --help` list all options. Safe to re-run.
# From a git checkout the local files are used; otherwise the few needed files are fetched
# from CN_RAW_URL (default below; CN_RAW_URL=<url> overrides it, e.g. to pin a tag).

CN_RAW_URL_DEFAULT='https://raw.githubusercontent.com/lemonadesaltbagel/cnode/main'

set -euo pipefail
src=""

main() {
  local role="${1:-}"; [ $# -gt 0 ] && shift
  case "$role" in
    control|node) ;;
    -h|--help|help) usage; return 0 ;;
    "") usage >&2; return 2 ;;
    *) echo "install.sh: unknown role '$role' (control | node)" >&2; return 2 ;;
  esac
  export CN_RAW_URL="${CN_RAW_URL:-$CN_RAW_URL_DEFAULT}"

  local here=""
  if [ -n "${BASH_SOURCE[0]:-}" ] && [ -f "${BASH_SOURCE[0]}" ]; then here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; fi
  if [ -n "$here" ] && [ -f "$here/scripts/$role-setup.sh" ]; then
    src="$here"
  else
    case "$CN_RAW_URL" in http://*|https://*|file://*) ;; *) echo "install.sh: CN_RAW_URL is not a URL: $CN_RAW_URL" >&2; return 1 ;; esac
    src="$(mktemp -d "${TMPDIR:-/tmp}/compute-node.XXXXXX")"
    trap 'rm -rf "$src"' EXIT
    local files=(scripts/"$role"-setup.sh node/cn-status)
    if [ "$role" = control ]; then files+=(bin/cnode templates/agent-rules.en.md templates/agent-rules.zh-CN.md)
    else files+=(node/cn-authorize scripts/windows-setup.sh scripts/wincalc.sh); fi
    ensure_fetcher
    local f
    for f in "${files[@]}"; do mkdir -p "$src/$(dirname "$f")"; fetch "$CN_RAW_URL/$f" "$src/$f"; done
  fi

  # The setup scripts may prompt (passwords, host-key confirmation): give them the terminal,
  # not the rest of this piped script.
  if (exec </dev/tty) 2>/dev/null; then bash "$src/scripts/$role-setup.sh" --src "$src" "$@" </dev/tty
  else bash "$src/scripts/$role-setup.sh" --src "$src" "$@" </dev/null; fi
}

usage() {
  echo "usage: install.sh control [--host H --user U ...]   |   sudo install.sh node [--user U ...]"
  echo "       install.sh control --help   /   install.sh node --help"
}

ensure_fetcher() {
  command -v curl >/dev/null 2>&1 || command -v wget >/dev/null 2>&1 && return 0
  if [ "$(id -u)" -eq 0 ] && command -v apt-get >/dev/null 2>&1; then
    echo "==> installing curl"; apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq curl ca-certificates >/dev/null
  else
    echo "install.sh: need curl or wget" >&2; exit 1
  fi
}

fetch() {
  if command -v curl >/dev/null 2>&1; then curl -fsSL "$1" -o "$2"; else wget -qO "$2" "$1"; fi \
    || { echo "install.sh: download failed: $1" >&2; exit 1; }
}

main "$@"
