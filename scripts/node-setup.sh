#!/usr/bin/env bash
# compute-node: set up THIS Linux machine (a WSL2 distro or plain Linux) as a compute node.
# Run it inside the WSL distro or on the Linux box; nothing on Windows is touched.
#   curl -fsSL https://raw.githubusercontent.com/lemonadesaltbagel/cnode/main/install.sh | sudo bash -s -- node [options]
#
#   --user NAME          the account control nodes log in as (default: $SUDO_USER)
#   --create-user        create --user if missing (adds it to sudo; asks for a password on a TTY)
#   --port N             sshd port (default 2222, so it never clashes with Windows' own OpenSSH on 22)
#   --sync-root DIR      where control-node paths are mirrored; repeatable (default /Users, for macOS
#                        control nodes; add e.g. /home/alice for a Linux control node)
#   --no-tailscale       do not install/start Tailscale (use the LAN address instead)
#   --authkey KEY        Tailscale auth key for an unattended login (or env TS_AUTHKEY);
#                        without it `tailscale up` prints a login URL to open once
#   --ts-hostname NAME   machine name in the tailnet (default: the hostname)
#   --key-only           refuse SSH passwords (default: passwords and keys both work)
#   --authorize 'KEY'    authorize a control node's public key for --user; repeatable
#   --no-docker          skip Docker Engine (and the NVIDIA Container Toolkit)
#   --gpu auto|yes|no    install the NVIDIA Container Toolkit (auto: if an NVIDIA GPU is visible)
#   --wsl auto|yes|no    treat this as a WSL distro (auto-detected)
#   --no-self-test       skip the GPU container self-test
#
# Without systemd running, services are started directly; on WSL systemd is also switched on in
# /etc/wsl.conf so it takes over at the distro's next start. Safe to re-run.
set -euo pipefail

SSH_PORT=2222; TARGET_USER="${SUDO_USER:-}"; CREATE_USER=0; SYNC_ROOTS=(); KEYS=(); KEY_ONLY=0
TAILSCALE=1; TS_KEY="${TS_AUTHKEY:-}"; TS_HOST=""
DOCKER=1; GPU=auto; WSL=auto; SELF_TEST=1; SRC=""
while [ $# -gt 0 ]; do
  case "$1" in
    --user) TARGET_USER="${2:?}"; shift 2 ;;
    --create-user) CREATE_USER=1; shift ;;
    --port) SSH_PORT="${2:?}"; shift 2 ;;
    --sync-root) SYNC_ROOTS+=("${2:?}"); shift 2 ;;
    --authorize) KEYS+=("${2:?}"); shift 2 ;;
    --key-only) KEY_ONLY=1; shift ;;
    --no-tailscale) TAILSCALE=0; shift ;;
    --authkey) TS_KEY="${2:?}"; shift 2 ;;
    --ts-hostname) TS_HOST="${2:?}"; shift 2 ;;
    --no-docker) DOCKER=0; shift ;;
    --gpu) GPU="${2:?}"; shift 2 ;;
    --wsl) WSL="${2:?}"; shift 2 ;;
    --no-self-test) SELF_TEST=0; shift ;;
    --src) SRC="${2:?}"; shift 2 ;;
    -h|--help) sed -n '2,/^set -euo/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "node-setup: unknown option $1" >&2; exit 2 ;;
  esac
done
[ ${#SYNC_ROOTS[@]} -gt 0 ] || SYNC_ROOTS=(/Users)
[ -n "$SRC" ] || SRC="$(cd "$(dirname "$0")/.." && pwd)"

say() { printf '\n==> %s\n' "$*"; }
note() { printf '    %s\n' "$*"; }
warn() { printf '!!  %s\n' "$*" >&2; }
die() { printf 'node-setup: %s\n' "$*" >&2; exit 1; }
has_systemd() { [ -d /run/systemd/system ]; }
can_tty() { (exec </dev/tty) 2>/dev/null; }
# write_if_changed FILE (content on stdin); returns 0 if the file changed
write_if_changed() {
  local tmp; tmp="$(mktemp)"; cat >"$tmp"
  if [ -f "$1" ] && cmp -s "$tmp" "$1"; then rm -f "$tmp"; return 1; fi
  install -m 0644 "$tmp" "$1"; rm -f "$tmp"; return 0
}
# ini_set FILE SECTION KEY VALUE  (creates the section/key or replaces the value; returns 0 if changed)
ini_set() {
  local f="$1" s="$2" k="$3" v="$4"
  [ -f "$f" ] || : >"$f"
  awk -v s="[$s]" -v k="$k" -v v="$v" '
    function flush() { if (insec && !done) { print k "=" v; done=1 } }
    /^[ \t]*\[/ { flush(); insec = ($0 ~ "^[ \t]*\\[" substr(s,2,length(s)-2) "\\][ \t]*$"); if (insec) seen=1; print; next }
    insec && $0 ~ "^[ \t]*" k "[ \t]*=" { if (!done) print k "=" v; done=1; next }
    { print }
    END { if (insec && !done) { print k "=" v; done=1 } if (!seen) { print ""; print s; print k "=" v } }
  ' "$f" | write_if_changed "$f"
}

[ "$(id -u)" -eq 0 ] || die "run as root (sudo)"
[[ "$SSH_PORT" =~ ^[0-9]+$ ]] || die "bad --port"
[ -r /etc/os-release ] || die "no /etc/os-release"
# shellcheck disable=SC1091
. /etc/os-release
case " ${ID:-} ${ID_LIKE:-} " in
  *" ubuntu "*) DOCKER_DISTRO=ubuntu; DOCKER_CODENAME="${UBUNTU_CODENAME:-${VERSION_CODENAME:-}}" ;;
  *" debian "*) DOCKER_DISTRO=debian; DOCKER_CODENAME="${VERSION_CODENAME:-}" ;;
  *) die "unsupported distribution '${ID:-?}' (Debian/Ubuntu and derivatives only)" ;;
esac

if [ "$WSL" = auto ]; then
  if [ -n "${WSL_DISTRO_NAME:-}" ] || [ -d /run/WSL ] || [ -e /proc/sys/fs/binfmt_misc/WSLInterop ]; then WSL=yes; else WSL=no; fi
fi
if [ "$GPU" = auto ]; then
  if [ -e /usr/lib/wsl/lib/nvidia-smi ] || command -v nvidia-smi >/dev/null 2>&1 || [ -e /dev/nvidia0 ]; then GPU=yes; else GPU=no; fi
fi
[ -n "$TARGET_USER" ] || die "cannot tell which account to configure: pass --user <name>"
[ "$TARGET_USER" != root ] || die "--user must be a normal account, not root"
note "distro: ${PRETTY_NAME:-$ID} | WSL: $WSL | systemd: $(has_systemd && echo yes || echo no) | GPU: $GPU | user: $TARGET_USER | port: $SSH_PORT"

export DEBIAN_FRONTEND=noninteractive
apt_install() { # install only what is missing
  local missing=() p
  for p in "$@"; do dpkg-query -W -f='${Status}' "$p" 2>/dev/null | grep -q 'install ok installed' || missing+=("$p"); done
  [ ${#missing[@]} -eq 0 ] && { note "already installed: $*"; return 0; }
  if [ -z "${APT_UPDATED:-}" ]; then apt-get update -qq; APT_UPDATED=1; fi
  apt-get install -y -qq --no-install-recommends "${missing[@]}" >/dev/null
  note "installed: ${missing[*]}"
}

say "Base packages"
apt_install openssh-server openssh-client ca-certificates curl gnupg rsync git build-essential tmux sudo procps iproute2

say "User $TARGET_USER"
if ! id "$TARGET_USER" >/dev/null 2>&1; then
  [ "$CREATE_USER" = 1 ] || die "user '$TARGET_USER' does not exist (add --create-user)"
  useradd -m -s /bin/bash -G sudo "$TARGET_USER"
  note "created $TARGET_USER (member of sudo)"
  if can_tty; then
    echo "    Set a password for $TARGET_USER (control nodes use it once to install their key; also sudo):"
    until passwd "$TARGET_USER" </dev/tty; do echo "    try again"; done
  else
    warn "no terminal: set a password later with: sudo passwd $TARGET_USER"
  fi
else
  note "exists"
fi
pw_state="$(passwd -S "$TARGET_USER" 2>/dev/null | awk '{print $2}')"
if [ "$KEY_ONLY" = 0 ] && [ "$pw_state" != P ]; then
  warn "$TARGET_USER has no usable password, so control nodes cannot log in once to install their key."
  warn "Set one:  sudo passwd $TARGET_USER   (or authorize keys by hand with cn-authorize)"
fi
TARGET_GROUP="$(id -gn "$TARGET_USER")"
TARGET_HOME="$(getent passwd "$TARGET_USER" | cut -d: -f6)"

if [ "$WSL" = yes ]; then
  say "WSL: /etc/wsl.conf (systemd, default user)"
  changed=0
  ini_set /etc/wsl.conf boot systemd true && changed=1
  if ! grep -qE '^[[:space:]]*default[[:space:]]*=' /etc/wsl.conf; then ini_set /etc/wsl.conf user default "$TARGET_USER" && changed=1; fi
  [ "$changed" = 1 ] && note "updated /etc/wsl.conf" || note "unchanged"
  has_systemd || note "systemd takes over at the distro's next start; services are started directly for now"
fi

say "sshd on port $SSH_PORT ($([ "$KEY_ONLY" = 1 ] && echo 'keys only' || echo 'password or key'))"
install -d -m 0755 /etc/ssh/sshd_config.d
if ! grep -qE '^[[:space:]]*Include[[:space:]]+/etc/ssh/sshd_config\.d/' /etc/ssh/sshd_config; then
  sed -i '1i Include /etc/ssh/sshd_config.d/*.conf' /etc/ssh/sshd_config; note "added Include to sshd_config"
fi
ssh_changed=0
{
  cat <<EOF
# Managed by compute-node (scripts/node-setup.sh). Re-run the setup instead of editing.
Port ${SSH_PORT}
PermitRootLogin no
PubkeyAuthentication yes
PasswordAuthentication $([ "$KEY_ONLY" = 1 ] && echo no || echo yes)
KbdInteractiveAuthentication no
# control nodes reuse connections (ControlMaster) and agents call in parallel
MaxSessions 64
MaxStartups 64:30:128
ClientAliveInterval 30
ClientAliveCountMax 6
AcceptEnv LANG LC_*
EOF
} | write_if_changed /etc/ssh/sshd_config.d/10-compute-node.conf && ssh_changed=1
[ -f /etc/ssh/ssh_host_ed25519_key ] || { ssh-keygen -A >/dev/null; note "generated host keys"; }
install -d -m 0755 /run/sshd
sshd -t || die "sshd config test failed"
if has_systemd; then
  # Ubuntu 22.10+ starts sshd from ssh.socket, which ignores Port/MaxStartups changes; use the service.
  if systemctl list-unit-files ssh.socket >/dev/null 2>&1 && systemctl is-enabled ssh.socket >/dev/null 2>&1; then
    systemctl disable --now ssh.socket >/dev/null 2>&1 || true; ssh_changed=1; note "switched from ssh.socket to ssh.service"
  fi
  systemctl enable ssh >/dev/null 2>&1 || true
  if [ "$ssh_changed" = 1 ] || ! systemctl is-active --quiet ssh; then systemctl restart ssh; note "sshd restarted"; else note "sshd unchanged"; fi
else
  if pgrep -x sshd >/dev/null; then
    if [ "$ssh_changed" = 1 ] && [ -f /run/sshd.pid ]; then kill -HUP "$(cat /run/sshd.pid)"; note "sshd reloaded"; else note "sshd unchanged"; fi
  else
    /usr/sbin/sshd && note "no systemd: started sshd directly"
  fi
fi

say "Node commands: cn-status, cn-authorize"
for f in cn-status cn-authorize; do
  [ -f "$SRC/node/$f" ] || die "missing $SRC/node/$f"
  if cmp -s "$SRC/node/$f" "/usr/local/bin/$f"; then note "$f unchanged"; else install -m 0755 "$SRC/node/$f" "/usr/local/bin/$f"; note "installed /usr/local/bin/$f"; fi
done
printf '# compute-node settings (read by cn-status)\nSSH_PORT=%s\nSYNC_ROOTS="%s"\n' "$SSH_PORT" "${SYNC_ROOTS[*]}" \
  | write_if_changed /etc/compute-node.conf && note "wrote /etc/compute-node.conf" || true
for k in ${KEYS[@]+"${KEYS[@]}"}; do /usr/local/bin/cn-authorize --user "$TARGET_USER" "$k" | sed 's/^/    /'; done
install -d -m 700 -o "$TARGET_USER" -g "$TARGET_GROUP" "$TARGET_HOME/.ssh"

if [ "$DOCKER" = 1 ]; then
  say "Docker Engine"
  if dpkg-query -W -f='${Status}' docker-ce 2>/dev/null | grep -q 'install ok installed'; then
    note "docker-ce already installed"
  elif command -v docker >/dev/null 2>&1; then
    warn "a 'docker' command already exists (Docker Desktop integration or distro docker.io); leaving it alone"
    DOCKER=0
  else
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL "https://download.docker.com/linux/${DOCKER_DISTRO}/gpg" -o /etc/apt/keyrings/docker.asc
    chmod a+r /etc/apt/keyrings/docker.asc
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/${DOCKER_DISTRO} ${DOCKER_CODENAME} stable" \
      | write_if_changed /etc/apt/sources.list.d/docker.list || true
    APT_UPDATED=""
    apt_install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  fi
  if [ "$GPU" = yes ] && [ "$DOCKER" = 1 ]; then
    say "NVIDIA Container Toolkit (GPU containers: docker run --gpus all)"
    if ! dpkg-query -W -f='${Status}' nvidia-container-toolkit 2>/dev/null | grep -q 'install ok installed'; then
      curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey \
        | gpg --dearmor --yes -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
      curl -fsSL https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list \
        | sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' \
        | write_if_changed /etc/apt/sources.list.d/nvidia-container-toolkit.list || true
      APT_UPDATED=""
    fi
    apt_install nvidia-container-toolkit
  fi
  if [ "$DOCKER" = 1 ]; then
    id -nG "$TARGET_USER" | tr ' ' '\n' | grep -qx docker || { usermod -aG docker "$TARGET_USER"; note "added $TARGET_USER to group docker (log in again)"; }
    before="$(cat /etc/docker/daemon.json 2>/dev/null || true)"
    [ "$GPU" = yes ] && nvidia-ctk runtime configure --runtime=docker >/dev/null
    if has_systemd; then
      systemctl enable docker containerd >/dev/null 2>&1 || true
      if [ "$before" != "$(cat /etc/docker/daemon.json 2>/dev/null || true)" ] || ! systemctl is-active --quiet docker; then
        systemctl restart docker; note "docker (re)started"
      fi
    elif service docker status >/dev/null 2>&1; then note "docker running"
    elif service docker start >/dev/null 2>&1 && sleep 2 && service docker status >/dev/null 2>&1; then
      note "no systemd: started docker with its init script"
    else
      warn "no systemd and Docker Engine could not be started. In an unprivileged container (e.g. a"
      warn "RunPod pod or plain docker run) it cannot run at all; use --no-docker there."
    fi
  fi
fi

if [ "$TAILSCALE" = 1 ]; then
  say "Tailscale (reach this node from anywhere, no router or Windows changes)"
  if dpkg-query -W -f='${Status}' tailscale 2>/dev/null | grep -q 'install ok installed' || [ -x /usr/sbin/tailscaled ]; then
    note "tailscale already installed"
  else
    curl -fsSL "https://pkgs.tailscale.com/stable/${DOCKER_DISTRO}/${DOCKER_CODENAME}.noarmor.gpg" \
      -o /usr/share/keyrings/tailscale-archive-keyring.gpg
    curl -fsSL "https://pkgs.tailscale.com/stable/${DOCKER_DISTRO}/${DOCKER_CODENAME}.tailscale-keyring.list" \
      | write_if_changed /etc/apt/sources.list.d/tailscale.list || true
    APT_UPDATED=""
    apt_install tailscale
  fi
  ts_flags=""; [ -c /dev/net/tun ] || ts_flags="--tun=userspace-networking"   # no TUN device: userspace mode
  if has_systemd; then
    if [ -f /etc/default/tailscaled ] && ! grep -qx "FLAGS=\"$ts_flags\"" /etc/default/tailscaled; then
      sed -i "s|^FLAGS=.*|FLAGS=\"$ts_flags\"|" /etc/default/tailscaled; systemctl restart tailscaled 2>/dev/null || true
    fi
    systemctl enable --now tailscaled >/dev/null 2>&1 || warn "could not start tailscaled"
  elif ! pgrep -x tailscaled >/dev/null; then
    install -d -m 0755 /var/lib/tailscale /run/tailscale
    # shellcheck disable=SC2086
    nohup setsid tailscaled --state=/var/lib/tailscale/tailscaled.state --socket=/run/tailscale/tailscaled.sock \
      $ts_flags >/var/log/tailscaled.log 2>&1 </dev/null &
    note "no systemd: started tailscaled directly${ts_flags:+ ($ts_flags)}"
  fi
  for _ in 1 2 3 4 5 6 7 8 9 10; do tailscale status --json >/dev/null 2>&1 && break; sleep 1; done
  ts_state="$(tailscale status --json 2>/dev/null | sed -n 's/.*"BackendState": *"\([^"]*\)".*/\1/p' | head -n1)"
  if [ "$ts_state" = Running ]; then note "already logged in to the tailnet"
  else
    ts_args=(up); [ -n "$TS_KEY" ] && ts_args+=("--authkey=$TS_KEY"); [ -n "$TS_HOST" ] && ts_args+=("--hostname=$TS_HOST")
    if [ -n "$TS_KEY" ]; then tailscale "${ts_args[@]}" || warn "tailscale up failed"
    elif can_tty; then note "open the login URL below once (this waits until you have logged in)"; tailscale "${ts_args[@]}" </dev/tty || warn "tailscale up failed"
    else warn "Tailscale is installed but not logged in: run  sudo tailscale up  (or pass --authkey)"; fi
  fi
fi

say "File-watch limits (Mutagen, build tools)"
printf 'fs.inotify.max_user_watches=1048576\nfs.inotify.max_user_instances=1024\n' \
  | write_if_changed /etc/sysctl.d/90-compute-node.conf && note "wrote /etc/sysctl.d/90-compute-node.conf" || note "unchanged"
sysctl -q -p /etc/sysctl.d/90-compute-node.conf >/dev/null 2>&1 || warn "could not apply sysctl now (read-only /proc/sys in a container?); applies at boot"

if [ "$WSL" = yes ]; then
  say "WSL: make nvidia-smi visible to SSH sessions"
  if [ -e /usr/lib/wsl/lib/nvidia-smi ]; then ln -sfn /usr/lib/wsl/lib/nvidia-smi /usr/local/bin/nvidia-smi; note "linked /usr/local/bin/nvidia-smi"; fi
  # shellcheck disable=SC2016
  echo 'case ":$PATH:" in *:/usr/lib/wsl/lib:*) ;; *) PATH="$PATH:/usr/lib/wsl/lib";; esac' \
    | write_if_changed /etc/profile.d/wsl-lib.sh && note "wrote /etc/profile.d/wsl-lib.sh" || note "unchanged"
fi

say "Sync roots (control-node paths are mirrored 1:1): ${SYNC_ROOTS[*]}"
for r in "${SYNC_ROOTS[@]}"; do
  case "$r" in /*) ;; *) die "--sync-root must be absolute: $r" ;; esac
  if [ ! -e "$r" ]; then install -d -m 0755 -o "$TARGET_USER" -g "$TARGET_GROUP" "$r"; note "created $r (owner $TARGET_USER)"
  elif [ "$(stat -c %U "$r")" = "$TARGET_USER" ] || sudo -u "$TARGET_USER" test -w "$r"; then note "$r ok"
  else warn "$r exists but $TARGET_USER cannot write to it; fix with: sudo chown $TARGET_USER $r"; fi
done

if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q 'Status: active'; then
  say "ufw: allow ${SSH_PORT}/tcp"; ufw allow "${SSH_PORT}/tcp" >/dev/null
fi

say "Self-check"
if command -v ss >/dev/null 2>&1 && ss -ltn | grep -q ":${SSH_PORT} "; then note "sshd listening on ${SSH_PORT}"; else warn "sshd is not listening on ${SSH_PORT}"; fi
if [ "$DOCKER" = 1 ] && has_systemd; then systemctl is-active --quiet docker && note "docker active" || warn "docker not active"; fi
if [ "$SELF_TEST" = 1 ] && [ "$GPU" = yes ] && [ "$DOCKER" = 1 ] && has_systemd; then
  docker run --rm --gpus all nvidia/cuda:12.8.0-base-ubuntu24.04 nvidia-smi --query-gpu=name,memory.total --format=csv,noheader \
    | sed 's/^/    GPU container: /' || warn "GPU container self-test failed"
fi

FP="$(ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub | awk '{print $2}')"
TSNAME=""
if [ "$TAILSCALE" = 1 ] && command -v tailscale >/dev/null 2>&1; then
  TSNAME="$(tailscale status --json 2>/dev/null | grep -m1 '"DNSName"' | sed 's/.*"DNSName": *"\([^"]*\)\.".*/\1/' || true)"
  [ -n "$TSNAME" ] || TSNAME="$(tailscale ip -4 2>/dev/null | head -n1 || true)"
fi
LAN="$(hostname -I 2>/dev/null | awk '{print $1}')"
HOST_HINT="${TSNAME:-${LAN:-<host>}}"
URL="${CN_RAW_URL:-https://raw.githubusercontent.com/lemonadesaltbagel/cnode/main}"
echo
echo "Compute node ready."
echo "  join: host=${HOST_HINT} user=${TARGET_USER} port=${SSH_PORT} fingerprint=${FP}"
[ "$WSL" = yes ] && [ -z "$TSNAME" ] && echo "  (WSL without Tailscale: other machines reach it only if Windows forwards the port, e.g. mirrored networking)"
echo
echo "On each control node (asks for ${TARGET_USER}'s password once, then installs its key):"
echo "  curl -fsSL ${URL}/install.sh | bash -s -- control --name <name> --host ${HOST_HINT} --user ${TARGET_USER} --port ${SSH_PORT}"
echo "  or, if cnode is already installed:  cnode add <name> --host ${HOST_HINT} --user ${TARGET_USER} --port ${SSH_PORT}"
echo "  optional: add --fingerprint ${FP} to pin the host key instead of trusting it on first use"
[ "$KEY_ONLY" = 1 ] && echo "  (--key-only: authorize each control node here with  cn-authorize '<line printed by cnode key>')"
exit 0
