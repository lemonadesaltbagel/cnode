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
#   --key-only           refuse SSH passwords (default: keys from anywhere; passwords only from
#                        private, link-local and Tailscale addresses, enough for the one-time key install)
#   --password-anywhere  also accept passwords from public addresses (e.g. a cloud control node)
#   --authorize 'KEY'    authorize a control node's public key for --user; repeatable
#   --no-docker          skip Docker Engine (and the NVIDIA Container Toolkit)
#   --no-windows         WSL: leave Windows alone (no .wslconfig, boot task, firewall, pagefile)
#   --no-elevate         WSL: never show a UAC prompt; record admin steps as pending
#   --agent-sudo         let the node user run sudo without a password (NOPASSWD; off by default)
#   --fleet-ca 'KEY'     join a fleet: trust certificates from this fleet CA (its public key line, or a
#                        file holding it; printed by cnode fleet info on the admin). Control nodes of the
#                        fleet log in without any per-node key, and the admin's  cnode fleet add-node
#                        gives this node a host certificate. Kept on re-runs; --no-fleet removes it
#   --no-fleet           leave the fleet (remove the CA trust, revocation list and host certificate)
#   --gpu auto|yes|no    install the NVIDIA Container Toolkit (auto: if an NVIDIA GPU is visible)
#   --wsl auto|yes|no    treat this as a WSL distro (auto-detected)
#   --no-self-test       skip the GPU container self-test
#
# Without systemd running, services are started directly; on WSL systemd is also switched on in
# /etc/wsl.conf so it takes over at the distro's next start. Safe to re-run.
set -euo pipefail

SSH_PORT=2222; TARGET_USER="${SUDO_USER:-}"; CREATE_USER=0; SYNC_ROOTS=(); KEYS=(); KEY_ONLY=0; PW_ANYWHERE=0
TAILSCALE=1; TS_KEY="${TS_AUTHKEY:-}"; TS_HOST=""
DOCKER=1; GPU=auto; WSL=auto; SELF_TEST=1; SRC=""; WINDOWS=1; ELEVATE=1; AGENT_SUDO=0
FLEET_CA=""; NO_FLEET=0
while [ $# -gt 0 ]; do
  case "$1" in
    --user) TARGET_USER="${2:?}"; shift 2 ;;
    --create-user) CREATE_USER=1; shift ;;
    --port) SSH_PORT="${2:?}"; shift 2 ;;
    --sync-root) SYNC_ROOTS+=("${2:?}"); shift 2 ;;
    --authorize) KEYS+=("${2:?}"); shift 2 ;;
    --key-only) KEY_ONLY=1; shift ;;
    --password-anywhere) PW_ANYWHERE=1; shift ;;
    --no-tailscale) TAILSCALE=0; shift ;;
    --authkey) TS_KEY="${2:?}"; shift 2 ;;
    --ts-hostname) TS_HOST="${2:?}"; shift 2 ;;
    --no-docker) DOCKER=0; shift ;;
    --no-windows) WINDOWS=0; shift ;;
    --no-elevate) ELEVATE=0; shift ;;
    --agent-sudo) AGENT_SUDO=1; shift ;;
    --fleet-ca) FLEET_CA="${2:?}"; shift 2 ;;
    --no-fleet) NO_FLEET=1; shift ;;
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
[ "$KEY_ONLY" = 1 ] && [ "$PW_ANYWHERE" = 1 ] && die "--key-only and --password-anywhere exclude each other"
if [ -n "$FLEET_CA" ]; then
  [ "$NO_FLEET" = 0 ] || die "--fleet-ca and --no-fleet exclude each other"
  [ -f "$FLEET_CA" ] && FLEET_CA="$(head -n1 "$FLEET_CA")"
  case "$FLEET_CA" in *PRIVATE*) die "--fleet-ca wants the CA's public key line (cnode fleet info), not a private key" ;; esac
  FLEET_CA="$(printf '%s\n' "$FLEET_CA" | awk 'NF>=2{print $1, $2; exit}')"
  # (ssh-keygen may not be installed yet: the shape here, the key itself once the base packages are in)
  [[ "$FLEET_CA" =~ ^(ssh-ed25519|ecdsa-sha2-nistp(256|384|521)|ssh-rsa|sk-ssh-ed25519@openssh\.com|sk-ecdsa-sha2-nistp256@openssh\.com)\ [A-Za-z0-9+/]+=*$ ]] \
    || die "--fleet-ca: not a public key line: $FLEET_CA"
fi
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

WINDOWS_TAILSCALE=0; WINDOWS_TS_NAME=""
if [ "$WSL" = yes ] && [ "$WINDOWS" = 1 ]; then
  say "Windows side (via WSL interop): .wslconfig, boot task, firewall rule, pagefile"
  w_args=(--port "$SSH_PORT"); [ "$ELEVATE" = 0 ] && w_args+=(--no-elevate)
  bash "$SRC/scripts/windows-setup.sh" "${w_args[@]}" || warn "Windows-side setup failed; see the messages above"
  if [ -f /etc/cnode/windows.env ]; then
    WINDOWS_TAILSCALE="$(sed -n 's/^WINDOWS_TAILSCALE=//p' /etc/cnode/windows.env)"
    WINDOWS_TS_NAME="$(sed -n 's/^WINDOWS_TS_NAME=//p' /etc/cnode/windows.env)"
  fi
fi

say "sudo for the node user"
if [ "$AGENT_SUDO" = 1 ]; then
  printf '# compute-node --agent-sudo: %s may run sudo without a password\n%s ALL=(ALL) NOPASSWD:ALL\n' "$TARGET_USER" "$TARGET_USER" \
    | write_if_changed "/etc/sudoers.d/90-cnode-$TARGET_USER" && note "NOPASSWD sudo enabled for $TARGET_USER" || note "unchanged"
  chmod 0440 "/etc/sudoers.d/90-cnode-$TARGET_USER"
  visudo -cf "/etc/sudoers.d/90-cnode-$TARGET_USER" >/dev/null || { rm -f "/etc/sudoers.d/90-cnode-$TARGET_USER"; die "sudoers check failed"; }
elif [ -f "/etc/sudoers.d/90-cnode-$TARGET_USER" ]; then
  rm -f "/etc/sudoers.d/90-cnode-$TARGET_USER"; note "removed NOPASSWD sudo (re-run with --agent-sudo to keep it)"
else
  note "sudo asks for $TARGET_USER's password (agents cannot use it; --agent-sudo changes that)"
fi

FLEET_DIR=/etc/cnode/fleet; FLEET_DROPIN=/etc/ssh/sshd_config.d/05-cnode-fleet.conf; IN_FLEET=0
if [ "$NO_FLEET" = 1 ]; then
  say "Fleet: leaving"
  if has_systemd; then systemctl disable --now cnode-fleet.path cnode-fleet.timer >/dev/null 2>&1 || true; fi
  rm -f /etc/systemd/system/cnode-fleet.{path,service,timer}
  [ -f /run/cnode-fleet-loop.pid ] && kill "$(cat /run/cnode-fleet-loop.pid)" 2>/dev/null; rm -f /run/cnode-fleet-loop.pid
  rm -rf "$FLEET_DIR" "$FLEET_DROPIN" /etc/ssh/ssh_host_ed25519_key-cert.pub /usr/local/sbin/cn-fleet-apply
  note "removed the fleet CA trust, revocation list and host certificate"
elif [ -n "$FLEET_CA" ] || [ -f "$FLEET_DIR/ca.pub" ]; then
  say "Fleet: control nodes log in with certificates from the fleet CA"
  install -d -m 0755 "$FLEET_DIR" "$FLEET_DIR/principals"
  if [ -n "$FLEET_CA" ]; then
    printf '%s\n' "$FLEET_CA" | ssh-keygen -lf - >/dev/null 2>&1 || die "--fleet-ca: not a valid public key: $FLEET_CA"
    if [ -f "$FLEET_DIR/ca.pub" ] && [ "$(awk '{print $1, $2}' "$FLEET_DIR/ca.pub")" != "$FLEET_CA" ]; then
      warn "the fleet CA changes: dropping the old registry state and host certificate"
      rm -f "$FLEET_DIR"/{serial,registry.signed,revoked.krl,revoked.spec} /etc/ssh/ssh_host_ed25519_key-cert.pub
    fi
    printf '%s cnode-fleet-ca\n' "$FLEET_CA" | write_if_changed "$FLEET_DIR/ca.pub" || true
  fi
  printf 'cnode-fleet %s\n' "$(awk '{print $1, $2}' "$FLEET_DIR/ca.pub")" | write_if_changed "$FLEET_DIR/allowed_signers" || true
  # certificates are accepted for the node user only (principal "cnode"), never for other accounts
  find "$FLEET_DIR/principals" -mindepth 1 -maxdepth 1 ! -name "$TARGET_USER" -exec rm -f {} +
  echo cnode | write_if_changed "$FLEET_DIR/principals/$TARGET_USER" || true
  printf 'USER=%s\nINBOX=%s\n' "$TARGET_USER" "$TARGET_HOME/.cnode/inbox" | write_if_changed "$FLEET_DIR/conf" || true
  install -d -m 0700 -o "$TARGET_USER" -g "$TARGET_GROUP" "$TARGET_HOME/.cnode" "$TARGET_HOME/.cnode/inbox"
  [ -f "$SRC/node/cn-fleet-apply" ] || die "missing $SRC/node/cn-fleet-apply"
  install -d -m 0755 /usr/local/sbin
  if cmp -s "$SRC/node/cn-fleet-apply" /usr/local/sbin/cn-fleet-apply; then note "cn-fleet-apply unchanged"
  else install -m 0755 "$SRC/node/cn-fleet-apply" /usr/local/sbin/cn-fleet-apply; note "installed /usr/local/sbin/cn-fleet-apply"; fi
  /usr/local/sbin/cn-fleet-apply --configure || die "could not configure the fleet for sshd"
  note "fleet CA $(ssh-keygen -lf "$FLEET_DIR/ca.pub" | awk '{print $2}'); sshd drop-in $FLEET_DROPIN"
  IN_FLEET=1
fi

if [ "$KEY_ONLY" = 1 ]; then SSH_MODE='keys only'
elif [ "$PW_ANYWHERE" = 1 ]; then SSH_MODE='password or key, from anywhere'
else SSH_MODE='key; password only from private/Tailscale addresses'; fi
say "sshd on port $SSH_PORT ($SSH_MODE)"
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
PasswordAuthentication $([ "$PW_ANYWHERE" = 1 ] && echo yes || echo no)
KbdInteractiveAuthentication no
# control nodes reuse connections (ControlMaster) and agents call in parallel
MaxSessions 64
MaxStartups 64:30:128
ClientAliveInterval 30
ClientAliveCountMax 6
AcceptEnv LANG LC_*
EOF
  # Passwords (used once by cnode add to install a key) only from private, link-local, loopback
  # and Tailscale addresses. A Match block lasts to the end of this file, so it comes last.
  if [ "$KEY_ONLY" = 0 ] && [ "$PW_ANYWHERE" = 0 ]; then
    cat <<EOF
Match Address 10.0.0.0/8,172.16.0.0/12,192.168.0.0/16,169.254.0.0/16,100.64.0.0/10,127.0.0.0/8,::1,fc00::/7,fe80::/10
    PasswordAuthentication yes
EOF
  fi
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

if [ "$IN_FLEET" = 1 ]; then
  say "Fleet: apply updates from control nodes (revocations, host certificate)"
  if has_systemd; then
    cat >/etc/systemd/system/cnode-fleet.service <<'EOF'
[Unit]
Description=compute-node fleet: apply what control nodes dropped into the inbox

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/cn-fleet-apply --quiet
EOF
    cat >/etc/systemd/system/cnode-fleet.path <<EOF
[Unit]
Description=compute-node fleet: watch the inbox of ${TARGET_USER}

[Path]
DirectoryNotEmpty=${TARGET_HOME}/.cnode/inbox
Unit=cnode-fleet.service

[Install]
WantedBy=multi-user.target
EOF
    cat >/etc/systemd/system/cnode-fleet.timer <<'EOF'
[Unit]
Description=compute-node fleet: apply the inbox every 5 minutes as well

[Timer]
OnBootSec=1min
OnUnitActiveSec=5min

[Install]
WantedBy=timers.target
EOF
    systemctl daemon-reload
    systemctl enable --now cnode-fleet.path cnode-fleet.timer >/dev/null 2>&1 && note "cnode-fleet.path and .timer active" || warn "could not enable cnode-fleet.path"
  else
    # no systemd (container, or WSL before its next start): a small loop does the same
    if [ -f /run/cnode-fleet-loop.pid ] && kill -0 "$(cat /run/cnode-fleet-loop.pid)" 2>/dev/null; then note "inbox loop running"
    else
      nohup setsid bash -c 'while :; do /usr/local/sbin/cn-fleet-apply --quiet; sleep 5; done' >/dev/null 2>&1 </dev/null &
      echo $! >/run/cnode-fleet-loop.pid; note "no systemd: started the inbox loop (every 5 s)"
    fi
  fi
  /usr/local/sbin/cn-fleet-apply --quiet || true
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

if [ "$TAILSCALE" = 1 ] && [ "$WINDOWS_TAILSCALE" = 1 ]; then
  say "Tailscale"
  note "Windows already runs Tailscale: not adding a second tailnet node inside WSL."
  note "With mirrored networking (after wsl --shutdown) this node is reached at the Windows machine's name${WINDOWS_TS_NAME:+: $WINDOWS_TS_NAME}."
  TAILSCALE=0
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

say "Login shells for rx: load per-user tools that ~/.bashrc only loads interactively (nvm)"
# rx runs commands with bash -lc. Debian/Ubuntu's ~/.bashrc returns early in non-interactive shells,
# so anything set up below that line (nvm's installer puts itself there) is missing over rx.
cat <<'EOF' | write_if_changed /etc/profile.d/cnode-user-tools.sh && note "wrote /etc/profile.d/cnode-user-tools.sh" || note "unchanged"
# Managed by compute-node (scripts/node-setup.sh). rx runs commands in a non-interactive bash login
# shell, where ~/.bashrc returns early; load nvm here so node/npm are found there too.
if [ -n "${BASH_VERSION:-}" ]; then
  case $- in
    *i*) ;;
    *) if [ -z "${NVM_BIN:-}" ] && [ -s "${NVM_DIR:-$HOME/.nvm}/nvm.sh" ]; then
         export NVM_DIR="${NVM_DIR:-$HOME/.nvm}"
         . "$NVM_DIR/nvm.sh"
       fi ;;
  esac
fi
EOF

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
HOST_HINT="${TSNAME:-${WINDOWS_TS_NAME:-${LAN:-<host>}}}"
URL="${CN_RAW_URL:-https://raw.githubusercontent.com/lemonadesaltbagel/cnode/main}"
echo
echo "Compute node ready."
echo "  join: host=${HOST_HINT} user=${TARGET_USER} port=${SSH_PORT} fingerprint=${FP}"
[ "$WSL" = yes ] && [ -z "$TSNAME" ] && echo "  (WSL without Tailscale: other machines reach it only if Windows forwards the port, e.g. mirrored networking)"
echo
if [ "$IN_FLEET" = 1 ]; then
  NODE_NAME="$(hostname -s 2>/dev/null | tr 'A-Z_.' 'a-z--' | sed 's/[^a-z0-9-]//g; s/^[^a-z]*//' | cut -c1-31)"
  echo "Fleet node. On the fleet admin run (once; every control node of the fleet then has it within a minute):"
  echo "  cnode fleet add-node ${NODE_NAME:-<name>} --host ${HOST_HINT} --user ${TARGET_USER} --port ${SSH_PORT} --fingerprint ${FP}"
  [ -f /etc/ssh/ssh_host_ed25519_key-cert.pub ] && echo "  (this node already has a host certificate from the fleet; re-adding it is harmless)"
  echo
  echo "Without the fleet, on each control node:"
else
  echo "On each control node (asks for ${TARGET_USER}'s password once, then installs its key):"
fi
echo "  curl -fsSL ${URL}/install.sh | bash -s -- control --name <name> --host ${HOST_HINT} --user ${TARGET_USER} --port ${SSH_PORT}"
echo "  or, if cnode is already installed:  cnode add <name> --host ${HOST_HINT} --user ${TARGET_USER} --port ${SSH_PORT}"
echo "  optional: add --fingerprint ${FP} to pin the host key instead of trusting it on first use"
[ "$KEY_ONLY" = 1 ] && echo "  (--key-only: authorize each control node here with  cn-authorize '<line printed by cnode key>')"
[ "$KEY_ONLY" = 0 ] && [ "$PW_ANYWHERE" = 0 ] && echo "  (passwords are accepted only from private and Tailscale addresses; from elsewhere use cn-authorize, or --password-anywhere)"
if [ -s /etc/cnode/pending.json ] && grep -q '"id"' /etc/cnode/pending.json; then
  echo
  echo "PENDING WINDOWS STEPS (also shown by rx nodes --json; this installer never runs wsl --shutdown or reboots):"
  sed -n 's/.*"title":"\([^"]*\)","run":"\(\([^"\\]\|\\.\)*\)".*/  - \1\n      run: \2/p' /etc/cnode/pending.json | sed 's/\\\\/\\/g; s/\\"/"/g'
fi
exit 0
