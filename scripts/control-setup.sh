#!/usr/bin/env bash
# compute-node: set up THIS machine (macOS or Linux) as a control node.
# Normally run through install.sh:  curl -fsSL https://raw.githubusercontent.com/lemonadesaltbagel/cnode/main/install.sh | bash -s -- control [options]
#
#   --host H --user U [--port 2222]   register a compute node right away (optional; later: cnode add)
#   --name NAME          its name (default: wsl - also keeps the alias of the original single-node setup)
#                        The first login asks for U's password once (or reads env CN_PASSWORD) and
#                        installs this machine's SSH key, so later rx/wsync calls never prompt.
#   --fingerprint FP     pin the node's host key (SHA256:... from its join line); default: trust on first use
#   Fleet (one SSH CA for all nodes: new compute and control nodes show up everywhere by themselves):
#   --fleet-init STORE   create a fleet with this machine as its admin; STORE is owner/repo (a private
#                        GitHub repository, created through gh if missing) or dir:/path
#   --fleet STORE        join an existing fleet as a control node (then the admin runs cnode fleet approve)
#   --fleet-ca FP        the fleet CA fingerprint (SHA256:..., from cnode fleet info) to pin when joining
#   --fleet-name NAME    this control node's name in the fleet (default: the hostname)
#   --no-passphrase      --fleet-init: create the CA key without a passphrase (not recommended)
#   The agent rules block (how coding agents should use rx/wsync/rx nodes) is written by default to
#   ~/.claude/CLAUDE.md, and to ~/.codex/AGENTS.md if ~/.codex exists, between BEGIN/END markers.
#   --agent-rules FILE   also write it to FILE (repeatable), e.g. a project's AGENTS.md
#   --no-agent-rules     do not write the rules block anywhere
#   --lang en|zh-CN      language of the rules block (default en)
#   --no-install         do not install mutagen or the docker CLI (use what is on PATH)
#   --no-docker          skip everything Docker (CLI install and docker contexts)
#   --keep-docker-context  create the docker context but do not make it the default
# Safe to re-run: files are only rewritten when their content changes.
set -euo pipefail

HOST=""; USER_="" ; PORT=2222; NAME=wsl; FP=""; RULES=(); NORULES=0; LANG_=en
INSTALL=1; DOCKER=1; DOCKER_DEFAULT=1; SRC=""
FLEET_INIT=""; FLEET_JOIN=""; FLEET_CA=""; FLEET_NAME=""; FLEET_NOPASS=0
MUTAGEN_VERSION="${MUTAGEN_VERSION:-0.18.1}"
while [ $# -gt 0 ]; do
  case "$1" in
    --host) HOST="${2:?}"; shift 2 ;;
    --user) USER_="${2:?}"; shift 2 ;;
    --port) PORT="${2:?}"; shift 2 ;;
    --name) NAME="${2:?}"; shift 2 ;;
    --fingerprint) FP="${2:?}"; shift 2 ;;
    --fleet-init) FLEET_INIT="${2:?}"; shift 2 ;;
    --fleet) FLEET_JOIN="${2:?}"; shift 2 ;;
    --fleet-ca) FLEET_CA="${2:?}"; shift 2 ;;
    --fleet-name) FLEET_NAME="${2:?}"; shift 2 ;;
    --no-passphrase) FLEET_NOPASS=1; shift ;;
    --accept-new|--copy-id) shift ;;   # (now the default behaviour)
    --agent-rules) RULES+=("${2:?}"); shift 2 ;;
    --no-agent-rules) NORULES=1; shift ;;
    --lang) LANG_="${2:?}"; shift 2 ;;
    --no-install) INSTALL=0; shift ;;
    --no-docker) DOCKER=0; shift ;;
    --keep-docker-context) DOCKER_DEFAULT=0; shift ;;
    --src) SRC="${2:?}"; shift 2 ;;
    -h|--help) sed -n '2,/^set -euo/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "control-setup: unknown option $1" >&2; exit 2 ;;
  esac
done
[ -n "$SRC" ] || SRC="$(cd "$(dirname "$0")/.." && pwd)"
{ [ -n "$HOST" ] && [ -z "$USER_" ]; } && { echo "control-setup: --host needs --user" >&2; exit 2; }
case "$LANG_" in en|zh-CN) ;; *) echo "control-setup: --lang must be en or zh-CN" >&2; exit 2 ;; esac
{ [ -n "$FLEET_INIT" ] && [ -n "$FLEET_JOIN" ]; } && { echo "control-setup: --fleet-init and --fleet exclude each other" >&2; exit 2; }

say() { printf '\n==> %s\n' "$*"; }
note() { printf '    %s\n' "$*"; }
warn() { printf '!!  %s\n' "$*" >&2; }
have() { command -v "$1" >/dev/null 2>&1; }
OS="$(uname -s)"
BIN="$HOME/.local/bin"
SHARE="${XDG_DATA_HOME:-$HOME/.local/share}/compute-node"
KEY="$HOME/.ssh/id_ed25519"
[ "$(id -u)" -ne 0 ] || warn "running as root: this sets up root's HOME as a control node"
mkdir -p "$BIN" "$SHARE" "$HOME/.ssh/cm"; chmod 700 "$HOME/.ssh"
export PATH="$BIN:$PATH"

copy_if_changed() { # copy_if_changed SRC DST MODE
  if [ -f "$2" ] && [ ! -L "$2" ] && cmp -s "$1" "$2"; then note "unchanged: $2"; return 0; fi
  rm -f "$2"; cp "$1" "$2"; chmod "$3" "$2"; note "installed: $2"
}

say "Mutagen (file sync)"
if have mutagen; then note "found $(command -v mutagen) ($(mutagen version 2>/dev/null || echo '?'))"
elif [ "$INSTALL" = 0 ]; then warn "mutagen not found and --no-install given; wsync/rx need it"
elif [ "$OS" = Darwin ] && have brew; then brew install mutagen-io/mutagen/mutagen
else
  case "$(uname -m)" in x86_64|amd64) arch=amd64 ;; arm64|aarch64) arch=arm64 ;; armv7l) arch=arm ;; *) arch="" ;; esac
  os="$(echo "$OS" | tr '[:upper:]' '[:lower:]')"
  [ -n "$arch" ] || { echo "control-setup: unsupported CPU $(uname -m) for the mutagen binary" >&2; exit 1; }
  url="https://github.com/mutagen-io/mutagen/releases/download/v${MUTAGEN_VERSION}/mutagen_${os}_${arch}_v${MUTAGEN_VERSION}.tar.gz"
  tmp="$(mktemp -d)"; note "downloading $url"
  curl -fsSL "$url" -o "$tmp/m.tgz"
  # mutagen looks for mutagen-agents.tar.gz next to its own executable
  tar -xzf "$tmp/m.tgz" -C "$BIN" mutagen mutagen-agents.tar.gz
  rm -rf "$tmp"; note "installed mutagen $MUTAGEN_VERSION to $BIN"
fi
if have mutagen; then
  # macOS: registered with launchd so syncing resumes at login; elsewhere just start it
  mutagen daemon register >/dev/null 2>&1 || true
  mutagen daemon start >/dev/null 2>&1 || true
fi

if [ "$DOCKER" = 1 ]; then
  say "Docker CLI (runs against the compute node through a docker context)"
  if have docker; then note "found $(command -v docker)"
  elif [ "$INSTALL" = 1 ] && [ "$OS" = Darwin ] && have brew; then brew install docker
  else warn "no docker CLI; install one to use 'docker --context <node>' (macOS: brew install docker)"; fi
fi

say "SSH key"
if [ -f "$KEY" ]; then note "using $KEY"
else ssh-keygen -q -t ed25519 -N '' -f "$KEY" -C "$(id -un)@$(hostname -s 2>/dev/null || hostname)-compute-node"; note "created $KEY"; fi
if ! ssh-keygen -y -P '' -f "$KEY" >/dev/null 2>&1; then
  if [ "$OS" = Darwin ]; then note "the key has a passphrase: storing it in the macOS keychain"; ssh-add --apple-use-keychain "$KEY" </dev/tty || true
  else note "the key has a passphrase: keep an ssh-agent running (ssh-add $KEY)"; fi
fi

say "Commands cnode, rx, wsync -> $BIN"
copy_if_changed "$SRC/bin/cnode" "$BIN/cnode" 755
copy_if_changed "$SRC/node/cn-status" "$SHARE/cn-status" 644
for l in rx wsync; do
  if [ "$(readlink "$BIN/$l" 2>/dev/null || true)" = cnode ]; then note "unchanged: $BIN/$l -> cnode"
  else rm -f "$BIN/$l"; ln -s cnode "$BIN/$l"; note "linked: $BIN/$l -> cnode"; fi
done
rc=""
case "$(basename "${SHELL:-/bin/bash}")" in
  zsh) rc="$HOME/.zshrc" ;;
  bash) if [ "$OS" = Darwin ]; then rc="$HOME/.bash_profile"; else rc="$HOME/.bashrc"; fi ;;
  *) rc="$HOME/.profile" ;;
esac
# shellcheck disable=SC2016
if grep -qF '.local/bin' "$rc" 2>/dev/null; then note "PATH: $rc already mentions ~/.local/bin"
else printf '\n# added by compute-node\nexport PATH="$HOME/.local/bin:$PATH"\n' >>"$rc"; note "PATH: added ~/.local/bin to $rc (open a new terminal)"; fi

[ "$DOCKER" = 1 ] || export CN_NO_DOCKER=1   # cnode add: no docker contexts
# remembered for the fleet's background sync, which creates docker contexts for new nodes
CN_CONF="${CN_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/compute-node}/config"
mkdir -p "$(dirname "$CN_CONF")"; touch "$CN_CONF"
{ grep -v '^docker=' "$CN_CONF" || true; [ "$DOCKER" = 1 ] || echo docker=0; } >"$CN_CONF.new" && mv "$CN_CONF.new" "$CN_CONF"

say "SSH config: Include of the generated per-node aliases"
# Migrate the original single-node setup: reuse its HostName/User/Port if none were given.
if [ -z "$HOST" ] && [ -f "$HOME/.ssh/config" ] && grep -q '^# BEGIN wsl-compute$' "$HOME/.ssh/config"; then
  blk="$(sed -n '/^# BEGIN wsl-compute$/,/^# END wsl-compute$/p' "$HOME/.ssh/config")"
  HOST="$(echo "$blk" | awk '$1=="HostName"{print $2; exit}')"
  USER_="$(echo "$blk" | awk '$1=="User"{print $2; exit}')"
  PORT="$(echo "$blk" | awk '$1=="Port"{print $2; exit}')"; PORT="${PORT:-2222}"
  NAME=wsl
  note "migrating the existing 'Host wsl' block ($USER_@$HOST:$PORT) to node 'wsl'"
fi
cnode init
note "$HOME/.ssh/config now starts with: Include ${XDG_CONFIG_HOME:-$HOME/.config}/compute-node/ssh_config"

ADD_RC=0
if [ -n "$HOST" ]; then
  say "Compute node '$NAME' -> $USER_@$HOST:$PORT"
  args=(add "$NAME" --host "$HOST" --user "$USER_" --port "$PORT" --default)
  [ -n "$FP" ] && args+=(--fingerprint "$FP")
  [ "$DOCKER" = 1 ] && [ "$DOCKER_DEFAULT" = 1 ] && args+=(--docker-default)
  cnode "${args[@]}" || ADD_RC=$?
  [ "$ADD_RC" = 0 ] && cnode status "$NAME" || true
fi

FLEET_RC=0
if [ -n "$FLEET_INIT" ]; then
  say "Fleet: create it, with this machine as the admin (holds the CA)"
  fargs=(fleet init "$FLEET_INIT"); [ -n "$FLEET_NAME" ] && fargs+=(--name "$FLEET_NAME"); [ "$FLEET_NOPASS" = 1 ] && fargs+=(--no-passphrase)
  cnode "${fargs[@]}" || FLEET_RC=$?
elif [ -n "$FLEET_JOIN" ]; then
  say "Fleet: join as a control node"
  fargs=(fleet join "$FLEET_JOIN"); [ -n "$FLEET_CA" ] && fargs+=(--ca "$FLEET_CA"); [ -n "$FLEET_NAME" ] && fargs+=(--name "$FLEET_NAME")
  cnode "${fargs[@]}" || FLEET_RC=$?
fi

if [ "$NORULES" = 0 ]; then
  RULES=("$HOME/.claude/CLAUDE.md" ${RULES[@]+"${RULES[@]}"})
  [ -d "$HOME/.codex" ] && RULES+=("$HOME/.codex/AGENTS.md")
  say "Agent rules block (skip with --no-agent-rules)"
  tpl="$SRC/templates/agent-rules.$LANG_.md"
  [ -f "$tpl" ] || { echo "control-setup: missing $tpl" >&2; exit 1; }
  for f in "${RULES[@]}"; do
    mkdir -p "$(dirname "$f")"; [ -f "$f" ] || : >"$f"
    body="$(awk '/^<!-- BEGIN (compute-node|wsl-compute) -->$/{s=1;next} /^<!-- END (compute-node|wsl-compute) -->$/{s=0;next} !s' "$f")"
    new="$(mktemp)"
    { [ -n "$body" ] && printf '%s\n\n' "$body"; cat "$tpl"; } >"$new"
    if cmp -s "$new" "$f"; then note "unchanged: $f"; else cat "$new" >"$f"; note "updated: $f"; fi
    rm -f "$new"
  done
fi

echo
echo "Control node ready. Next:"
[ "$FLEET_RC" != 0 ] && echo "  !! the fleet step failed (see above); retry with: cnode fleet ${FLEET_INIT:+init $FLEET_INIT}${FLEET_JOIN:+join $FLEET_JOIN}"
if [ -n "$FLEET_INIT$FLEET_JOIN" ] && [ "$FLEET_RC" = 0 ]; then
  echo "  Fleet: cnode fleet status   (fleet nodes appear by themselves; cnode fleet info prints the join commands)"
elif [ -z "$HOST" ]; then
  echo "  cnode add <name> --host <host> --user <user> --port 2222   (values from the node's join line)"
fi
[ "$ADD_RC" = 3 ] && echo "  the key is not on '$NAME' yet: on the node run  $(cnode key)  then check: cnode status $NAME"
echo "  More nodes:  cnode add <name> --host <host> --user <user>   (asks for the password once)"
echo "  Then, in a project:  wsync && rx nproc && rx nodes"
exit 0
