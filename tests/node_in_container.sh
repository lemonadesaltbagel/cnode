#!/usr/bin/env bash
# shellcheck disable=SC2016,SC2088,SC2001  # test snippets are single-quoted on purpose
# Runs INSIDE a fresh Debian/Ubuntu container as root (see node_docker.sh). No systemd there,
# so this also covers the degraded path: sshd is started directly, Docker is installed but not run.
set -uo pipefail
# shellcheck source=tests/lib.sh
. /src/tests/lib.sh
export DEBIAN_FRONTEND=noninteractive
snap() { for f in /etc/ssh/sshd_config.d/10-compute-node.conf /etc/compute-node.conf /etc/sysctl.d/90-compute-node.conf \
  /usr/local/bin/cn-status /usr/local/bin/cn-authorize /home/tester/.ssh/authorized_keys /etc/apt/sources.list.d/docker.list; do
  [ -e "$f" ] && echo "$f $(cksum <"$f") $(stat -c '%a %U' "$f")"; done; stat -c '%n %a %U' /Users; }

echo "-- first run (fresh image, --create-user, no TTY)"
# test tooling only (the node setup installs its own packages): ssh client for the key, jq for JSON
apt-get update -qq >/dev/null && apt-get install -y -qq --no-install-recommends openssh-client jq >/dev/null 2>&1
ssh-keygen -q -t ed25519 -N '' -f /root/ctl -C control-test   # stands in for a control node's key
OUT="$(bash /src/install.sh node --user tester --create-user --authorize "$(cat /root/ctl.pub)" 2>&1)"; rc=$?
echo "$OUT" | tail -n 9 | sed 's/^/    | /'
check "exit 0" test "$rc" = 0
check "user created" id tester
check "user in sudo group" sh -c 'id -nG tester | grep -qw sudo'
check "sshd drop-in written" test -f /etc/ssh/sshd_config.d/10-compute-node.conf
check "sshd config valid" sshd -t
check "port 2222" sh -c 'sshd -T -C user=tester,host=x,addr=8.8.8.8 | grep -qx "port 2222"'
check "root login off" sh -c 'sshd -T -C user=tester,host=x,addr=8.8.8.8 | grep -qx "permitrootlogin no"'
check "passwords off from the internet" sh -c 'sshd -T -C user=tester,host=x,addr=8.8.8.8 | grep -qx "passwordauthentication no"'
check "passwords off from the LAN too (key-only default)" sh -c 'sshd -T -C user=tester,host=x,addr=192.168.1.5 | grep -qx "passwordauthentication no"'
check "maxsessions 64" sh -c 'sshd -T -C user=tester,host=x,addr=8.8.8.8 | grep -qx "maxsessions 64"'
check "no systemd: sshd started directly" pgrep -x sshd
check "key login over SSH works" ssh -p 2222 -i /root/ctl -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null tester@127.0.0.1 true
check "root cannot log in" sh -c '! ssh -p 2222 -i /root/ctl -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null root@127.0.0.1 true'
J="$(ssh -p 2222 -i /root/ctl -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null tester@127.0.0.1 cn-status --json 2>/dev/null)"
echo "    cn-status: $J"
if command -v jq >/dev/null 2>&1; then
  check "cn-status --json: hardware (cpu model, cores, RAM, wsl=false, container) and load (mem, disk of /Users)" sh -c 'echo "$1" | jq -e ".hardware.cpus_effective > 0 and .hardware.cpu_threads > 0 and .hardware.mem_total_mb > 0 and (.hardware.cpu_model|length) > 0 and .hardware.wsl == false and .hardware.container == true and (.hardware.gpus|length) == 0 and .load.mem_available_mb > 0 and .load.disk[0].path == \"/Users\" and (.load.loadavg|length) == 3"' _ "$J"
else check "cn-status --json looks like JSON" sh -c 'echo "$1" | grep -q "^{\"hostname\""' _ "$J"; fi
check "cn-status --both: line + JSON" sh -c '[ "$(cn-status --both | wc -l)" = 2 ]'
check "/Users owned by tester" sh -c '[ "$(stat -c %U /Users)" = tester ]'
check "sync roots recorded" grep -qx 'SYNC_ROOTS="/Users"' /etc/compute-node.conf
check "join line with host-key fingerprint" sh -c 'echo "$1" | grep -q "join: host=.* user=tester port=2222 fingerprint=SHA256:"' _ "$OUT"
check "WSL not detected in a container" sh -c 'echo "$1" | grep -q "WSL: no"' _ "$OUT"
if [ "${NO_DOCKER:-0}" = 0 ]; then
  check "docker-ce installed from download.docker.com" sh -c 'dpkg-query -W -f="\${Status}" docker-ce | grep -q "install ok installed"'
  check "tester in docker group" sh -c 'id -nG tester | grep -qw docker'
  check "no-systemd warning about Docker" sh -c 'echo "$1" | grep -q "cannot run at all"' _ "$OUT"
  check "no NVIDIA toolkit without a GPU" sh -c '! dpkg-query -W nvidia-container-toolkit >/dev/null 2>&1'
fi

echo "-- cn-authorize"
ssh-keygen -q -t ed25519 -N '' -f /root/ctl2 -C second-control
check "add a second control key" su tester -c "cn-authorize '$(cat /root/ctl2.pub)'"
check "adding it again is a no-op" sh -c "su tester -c \"cn-authorize '$(cat /root/ctl2.pub)'\" | grep -q 'already authorized'"
check "two keys listed" sh -c '[ "$(su tester -c "cn-authorize --list" | wc -l)" = 2 ]'
check "rejects garbage" sh -c '! su tester -c "cn-authorize not-a-key"'
FP2="$(ssh-keygen -lf /root/ctl2.pub | awk '{print $2}')"
check "remove by fingerprint" su tester -c "cn-authorize --remove $FP2"
check "one key left" sh -c '[ "$(su tester -c "cn-authorize --list" | wc -l)" = 1 ]'

echo "-- second run changes nothing"
before="$(snap)"
OUT2="$(bash /src/install.sh node --user tester --create-user --authorize "$(cat /root/ctl.pub)" 2>&1)"; rc=$?
check "exit 0" test "$rc" = 0
check "managed files identical" test "$before" = "$(snap)"
check "reports unchanged sshd" sh -c 'echo "$1" | grep -q "sshd unchanged"' _ "$OUT2"
check "skips apt when everything is installed" sh -c 'echo "$1" | grep -q "already installed: openssh-server"' _ "$OUT2"
check "key not duplicated" sh -c '[ "$(grep -c control-test /home/tester/.ssh/authorized_keys)" = 1 ]'

echo "-- --allow-lan-password (the original behaviour)"
bash /src/install.sh node --user tester --allow-lan-password --no-docker >/dev/null 2>&1
check "passwords allowed from 192.168.0.0/16" sh -c 'sshd -T -C user=tester,host=x,addr=192.168.1.5 | grep -qx "passwordauthentication yes"'
check "passwords allowed from Tailscale 100.64.0.0/10" sh -c 'sshd -T -C user=tester,host=x,addr=100.100.1.1 | grep -qx "passwordauthentication yes"'
check "still no passwords from the internet" sh -c 'sshd -T -C user=tester,host=x,addr=8.8.8.8 | grep -qx "passwordauthentication no"'
check "sshd still running after reload" pgrep -x sshd

echo "-- WSL path without systemd (simulated with --wsl yes)"
cp /etc/wsl.conf /tmp/wsl.conf.orig 2>/dev/null || true
printf '[automount]\noptions = "metadata"\n' >/etc/wsl.conf
bash /src/install.sh node --user tester --wsl yes --no-docker >/tmp/wsl.out 2>&1; rc=$?
check "exits 10 (restart WSL, then re-run)" test "$rc" = 10
check "systemd=true under [boot]" sh -c 'awk "/^\[boot\]/{b=1;next} /^\[/{b=0} b && /^systemd=true$/{f=1} END{exit !f}" /etc/wsl.conf'
check "default user set under [user]" sh -c 'awk "/^\[user\]/{b=1;next} /^\[/{b=0} b && /^default=tester$/{f=1} END{exit !f}" /etc/wsl.conf'
check "existing [automount] kept" grep -q 'options = "metadata"' /etc/wsl.conf
w1="$(cksum </etc/wsl.conf)"
bash /src/install.sh node --user tester --wsl yes --no-docker >/dev/null 2>&1
check "wsl.conf unchanged on re-run (no duplicate sections)" test "$w1" = "$(cksum </etc/wsl.conf)"
check "tells the user what to run" grep -q 'wsl --terminate' /tmp/wsl.out

echo "-- refuses bad input"
check "unknown user without --create-user" sh -c '! bash /src/install.sh node --user nobody-here --no-docker >/dev/null 2>&1'
check "root as --user" sh -c '! bash /src/install.sh node --user root --no-docker >/dev/null 2>&1'
finish
