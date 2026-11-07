#!/usr/bin/env bash
# shellcheck disable=SC2016,SC2088,SC2001,SC2329  # test snippets are single-quoted on purpose
# Runs INSIDE a fresh Debian/Ubuntu container as root (see node_docker.sh). No systemd and no TUN
# device there, so this also covers the degraded paths: sshd and tailscaled are started directly,
# Docker is installed but cannot run. Tailscale's daemon and login are stubbed (no tailnet here);
# its apt repository and package install are real.
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
printf '#!/bin/sh\necho s3cret\n' >/root/askpass; chmod 700 /root/askpass
pwlogin() { SSH_ASKPASS=/root/askpass SSH_ASKPASS_REQUIRE=force ssh -p 2222 -o PubkeyAuthentication=no \
  -o PreferredAuthentications=password -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "$@" </dev/null; }
OUT="$(bash /src/install.sh node --user tester --create-user --no-tailscale --authorize "$(cat /root/ctl.pub)" 2>&1)"; rc=$?
echo "$OUT" | tail -n 9 | sed 's/^/    | /'
check "exit 0" test "$rc" = 0
check "user created" id tester
check "user in sudo group" sh -c 'id -nG tester | grep -qw sudo'
check "sshd drop-in written" test -f /etc/ssh/sshd_config.d/10-compute-node.conf
check "sshd config valid" sshd -t
check "port 2222" sh -c 'sshd -T -C user=tester,host=x,addr=8.8.8.8 | grep -qx "port 2222"'
check "root login off" sh -c 'sshd -T -C user=tester,host=x,addr=8.8.8.8 | grep -qx "permitrootlogin no"'
check "password login allowed by default" sh -c 'sshd -T -C user=tester,host=x,addr=8.8.8.8 | grep -qx "passwordauthentication yes"'
check "warns that the new user has no password yet" sh -c 'printf "%s\n" "$1" | grep -q "no usable password"' _ "$OUT"
check "--no-tailscale: no tailscale installed" sh -c '! dpkg-query -W tailscale >/dev/null 2>&1'
check "--no-tailscale: join host is the LAN address" sh -c 'printf "%s\n" "$1" | grep -q "join: host=[0-9][0-9.]* user=tester"' _ "$OUT"
check "join line: control command needs no fingerprint (optional pinning)" sh -c 'printf "%s\n" "$1" | grep -q "bash -s -- control --name <name> --host [^ ]* --user tester --port 2222$" && echo "$1" | grep -q "optional: add --fingerprint SHA256:"' _ "$OUT"
check "maxsessions 64" sh -c 'sshd -T -C user=tester,host=x,addr=8.8.8.8 | grep -qx "maxsessions 64"'
check "no systemd: sshd started directly" pgrep -x sshd
check "key login over SSH works" ssh -p 2222 -i /root/ctl -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null tester@127.0.0.1 true
check "root cannot log in" sh -c '! ssh -p 2222 -i /root/ctl -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null root@127.0.0.1 true'
echo 'tester:s3cret' | chpasswd
check "password login over SSH works (no key)" pwlogin tester@127.0.0.1 true
check "wrong password refused" sh -c 'printf "#!/bin/sh\necho wrong\n" >/root/askbad; chmod 700 /root/askbad; ! SSH_ASKPASS=/root/askbad SSH_ASKPASS_REQUIRE=force ssh -p 2222 -o PubkeyAuthentication=no -o PreferredAuthentications=password -o NumberOfPasswordPrompts=1 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null tester@127.0.0.1 true </dev/null'

J="$(ssh -p 2222 -i /root/ctl -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null tester@127.0.0.1 cn-status --json 2>/dev/null)"
echo "    cn-status: $J"
if command -v jq >/dev/null 2>&1; then
  check "cn-status --json: hardware (cpu model, cores, RAM, wsl=false, container) and load (mem, disk of /Users)" sh -c 'printf "%s\n" "$1" | jq -e ".hardware.cpus_effective > 0 and .hardware.cpu_threads > 0 and .hardware.mem_total_mb > 0 and (.hardware.cpu_model|length) > 0 and .hardware.wsl == false and .hardware.container == true and (.hardware.gpus|length) == 0 and .load.mem_available_mb > 0 and .load.disk[0].path == \"/Users\" and (.load.loadavg|length) == 3"' _ "$J"
else check "cn-status --json looks like JSON" sh -c 'printf "%s\n" "$1" | grep -q "^{\"hostname\""' _ "$J"; fi
check "cn-status: container memory limit reported (mem_limit_mb, docker --memory)" sh -c 'printf "%s\n" "$1" | jq -e ".hardware.mem_limit_mb > 0 and .hardware.windows == null and .load.windows_commit_free_gb == null"' _ "$J"
check "cn-status --both: line + JSON" sh -c '[ "$(cn-status --both | wc -l)" = 2 ]'
check "/Users owned by tester" sh -c '[ "$(stat -c %U /Users)" = tester ]'
check "sync roots recorded" grep -qx 'SYNC_ROOTS="/Users"' /etc/compute-node.conf
check "join line with host-key fingerprint" sh -c 'printf "%s\n" "$1" | grep -q "join: host=.* user=tester port=2222 fingerprint=SHA256:"' _ "$OUT"
check "WSL not detected in a container" sh -c 'printf "%s\n" "$1" | grep -q "WSL: no"' _ "$OUT"
if [ "${NO_DOCKER:-0}" = 0 ]; then
  check "docker-ce installed from download.docker.com" sh -c 'dpkg-query -W -f="\${Status}" docker-ce | grep -q "install ok installed"'
  check "tester in docker group" sh -c 'id -nG tester | grep -qw docker'
  check "no-systemd warning about Docker" sh -c 'printf "%s\n" "$1" | grep -q "cannot run at all"' _ "$OUT"
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
OUT2="$(bash /src/install.sh node --user tester --create-user --no-tailscale --authorize "$(cat /root/ctl.pub)" 2>&1)"; rc=$?
check "exit 0" test "$rc" = 0
check "managed files identical" test "$before" = "$(snap)"
check "reports unchanged sshd" sh -c 'printf "%s\n" "$1" | grep -q "sshd unchanged"' _ "$OUT2"
check "skips apt when everything is installed" sh -c 'printf "%s\n" "$1" | grep -q "already installed: openssh-server"' _ "$OUT2"
check "key not duplicated" sh -c '[ "$(grep -c control-test /home/tester/.ssh/authorized_keys)" = 1 ]'

echo "-- --key-only hardening"
bash /src/install.sh node --user tester --key-only --no-tailscale --no-docker >/dev/null 2>&1
check "passwords refused with --key-only" sh -c 'sshd -T -C user=tester,host=x,addr=192.168.1.5 | grep -qx "passwordauthentication no"'
check "password login now fails" not pwlogin -o NumberOfPasswordPrompts=1 tester@127.0.0.1 true
check "key login still works" ssh -p 2222 -i /root/ctl -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null tester@127.0.0.1 true
bash /src/install.sh node --user tester --no-tailscale --no-docker >/dev/null 2>&1
check "default run re-enables passwords" pwlogin tester@127.0.0.1 true
check "sshd still running after reloads" pgrep -x sshd

echo "-- Tailscale (real package from pkgs.tailscale.com; daemon and login stubbed)"
cat >/usr/local/bin/tailscale <<'TS'
#!/bin/sh
echo "tailscale $*" >>/tmp/ts.log
case "$1" in
  status) if [ -f /tmp/ts.up ]; then echo '{"BackendState": "Running", "Self": {"DNSName": "node-test.tailnet.example."}}'
          else echo '{"BackendState": "NeedsLogin"}'; fi ;;
  up) touch /tmp/ts.up ;;
  ip) [ -f /tmp/ts.up ] && echo 100.64.0.10 ;;
esac
exit 0
TS
printf '#!/bin/sh\necho "tailscaled $*" >>/tmp/ts.log\nwhile :; do sleep 60; done\n' >/usr/local/sbin/tailscaled
chmod +x /usr/local/bin/tailscale /usr/local/sbin/tailscaled; : >/tmp/ts.log
OUT3="$(bash /src/install.sh node --user tester --no-docker --authkey tskey-test-123 2>&1)"; rc=$?
echo "$OUT3" | grep -A6 'Tailscale' | sed 's/^/    | /'
check "exit 0" test "$rc" = 0
check "tailscale package installed from the Tailscale apt repo" sh -c 'dpkg-query -W -f="\${Status}" tailscale | grep -q "install ok installed" && test -f /etc/apt/sources.list.d/tailscale.list'
check "no systemd, no TUN: tailscaled started directly in userspace mode" grep -q '^tailscaled .*--tun=userspace-networking' /tmp/ts.log
check "tailscale up with the auth key" grep -q '^tailscale up --authkey=tskey-test-123' /tmp/ts.log
check "join host is the tailnet name" sh -c 'printf "%s\n" "$1" | grep -q "join: host=node-test.tailnet.example user=tester"' _ "$OUT3"
OUT4="$(bash /src/install.sh node --user tester --no-docker --authkey tskey-test-123 2>&1)"
check "re-run: already logged in, no second up, no second daemon" sh -c 'printf "%s\n" "$1" | grep -q "already logged in" && [ "$(grep -c "^tailscale up" /tmp/ts.log)" = 1 ] && [ "$(grep -c "^tailscaled" /tmp/ts.log)" = 1 ]' _ "$OUT4"
rm -f /tmp/ts.up
OUT5="$(bash /src/install.sh node --user tester --no-docker 2>&1)"; rc=$?
check "no auth key and no terminal: exit 0 and says to run tailscale up" sh -c '[ "$2" = 0 ] && echo "$1" | grep -q "sudo tailscale up"' _ "$OUT5" "$rc"

echo "-- WSL path without systemd (simulated with --wsl yes)"
printf '[automount]\noptions = "metadata"\n' >/etc/wsl.conf
bash /src/install.sh node --user tester --wsl yes --no-docker --no-tailscale >/tmp/wsl.out 2>&1; rc=$?
check "exit 0: works now, no WSL restart needed" test "$rc" = 0
check "systemd=true under [boot] for the next start" sh -c 'awk "/^\[boot\]/{b=1;next} /^\[/{b=0} b && /^systemd=true$/{f=1} END{exit !f}" /etc/wsl.conf'
check "default user set under [user]" sh -c 'awk "/^\[user\]/{b=1;next} /^\[/{b=0} b && /^default=tester$/{f=1} END{exit !f}" /etc/wsl.conf'
check "existing [automount] kept" grep -q 'options = "metadata"' /etc/wsl.conf
check "says services were started directly" grep -q 'started directly for now' /tmp/wsl.out
w1="$(cksum </etc/wsl.conf)"
bash /src/install.sh node --user tester --wsl yes --no-docker --no-tailscale >/dev/null 2>&1
check "wsl.conf unchanged on re-run (no duplicate sections)" test "$w1" = "$(cksum </etc/wsl.conf)"

echo "-- WSL + Windows side through mocked interop (nothing real on Windows is touched)"
cat >/usr/local/bin/mock-ps <<'MOCK'
#!/bin/bash
# stands in for powershell.exe: answers the three kinds of call windows-setup/cn-status make
txt=""; prev=""
for a in "$@"; do [ "$prev" = -EncodedCommand ] && txt="$(printf '%s' "$a" | base64 -d | iconv -f UTF-16LE -t UTF-8)"; prev="$a"; done
case "$*" in *Get-CimInstance\ Win32_OperatingSystem*) [ -z "$txt" ] && { cat /tmp/mock-commit; exit 0; } ;; esac
case "$txt" in
  *"# cnode:facts"*)
    printf '%s\r\n' 'ram_bytes=33393377894' 'pagefile_auto=True' "commit_limit_kb=43096473" 'commit_free_kb=20971520' \
      'os_caption=Microsoft Windows 11 Pro 26100' 'pagefile_usage=C:\pagefile.sys|10240' 'disk=C:|107374182400' 'disk=D:|536870912000' \
      'userprofile=C:\Users\tester' 'account=PC\tester' "tailscale_service=${MOCK_TS:-Stopped}" "tailscale_state=${MOCK_TS:-Stopped}" \
      'tailscale_dns=pc.tailnet.example.' 'firewall_rule=False' ;;
  *"# cnode:elevate"*)
    echo "elevate $MOCK_ELEVATE" >>/tmp/mock-ps.log
    [ "${MOCK_ELEVATE:-}" = accept ] || { echo 'declined: The operation was canceled by the user.'; exit 99; }
    printf 'task=ok\r\nfirewall=ok\r\npagefile=ok\r\n' >/mnt/c/Users/tester/.cnode/windows-admin.result ;;
esac
exit 0
MOCK
cat >/usr/local/bin/mock-wslpath <<'MOCK'
#!/bin/sh
case "$1 $2" in
  "-w /") printf '%s\n' '\\wsl.localhost\TestDistro\' ;;
  -u*) printf '%s\n' "$2" | sed 's#^\([A-Za-z]\):#/mnt/\L\1#; s#\\#/#g' ;;
esac
MOCK
chmod +x /usr/local/bin/mock-ps /usr/local/bin/mock-wslpath
echo '45088768 20971520' >/tmp/mock-commit       # commit limit 43 GB, 20 GB free
mkdir -p /mnt/c/Users/tester; printf '[wsl2]\r\nmemory=28GB\r\nprocessors=8\r\n' >/mnt/c/Users/tester/.wslconfig
export CN_POWERSHELL=/usr/local/bin/mock-ps CN_WSLPATH=/usr/local/bin/mock-wslpath
OUT6="$(bash /src/install.sh node --user tester --wsl yes --no-docker --no-tailscale 2>&1)"; rc=$?
echo "$OUT6" | sed -n '/Windows side/,/state:/p' | sed 's/^/    | /'
check "exit 0" test "$rc" = 0
check "no terminal: no UAC prompt attempted" test ! -e /tmp/mock-ps.log
check ".wslconfig merged: explicit memory kept, others set, CRLF kept" sh -c 'f=/mnt/c/Users/tester/.wslconfig; tr -d "\r" <$f | grep -qx memory=28GB && tr -d "\r" <$f | grep -qx swap=6GB && tr -d "\r" <$f | grep -qx vmIdleTimeout=-1 && tr -d "\r" <$f | grep -qx networkingMode=mirrored && tr -d "\r" <$f | grep -qx autoMemoryReclaim=gradual && tr -d "\r" <$f | grep -qx processors=8 && grep -q "$(printf "\r")" $f'
check ".wslconfig backup made" sh -c 'ls /mnt/c/Users/tester/.wslconfig.bak-* >/dev/null'
check "warns: memory=28GB above the recommended 24 GB" sh -c 'printf "%s\n" "$1" | grep -q "memory=28GB in .wslconfig is above the recommended 24 GB"' _ "$OUT6"
check "windows.json: RAM 31.1, recommended M 24 / swap 6 / pagefile 55 on D:" jq -e '.ram_gb == 31.1 and .recommended.wsl_memory_gb == 24 and .recommended.wsl_swap_gb == 6 and .recommended.pagefile_gb == 55 and .recommended.pagefile_drive == "D:" and .autostart == "pending"' /etc/cnode/windows.json
check "pending.json: autostart, firewall, pagefile, wsl-restart" sh -c '[ "$(jq -r "[.[].id] | join(\",\")" /etc/cnode/pending.json)" = "autostart,firewall,pagefile,wsl-restart" ]'
check "admin script saved on Windows with the computed values" sh -c 'f=/mnt/c/Users/tester/.cnode/windows-admin.ps1; grep -q "\$Distro = .TestDistro." $f && grep -q "PagefileName = .D:\\\\pagefile.sys." $f && grep -q "PagefileMB = 56320" $f && grep -q "Account = .PC\\\\tester." $f'
check "install ends with the pending steps and the exact command" sh -c 'printf "%s\n" "$1" | grep -q "PENDING WINDOWS STEPS" && printf "%s\n" "$1" | grep -qF "$2"' _ "$OUT6" 'run: powershell -NoProfile -ExecutionPolicy Bypass -File "C:\Users\tester\.cnode\windows-admin.ps1"'
J="$(su tester -c 'cn-status --json')"
check "cn-status: hardware.windows with commit limit and 4 pending steps" sh -c 'printf "%s\n" "$1" | jq -e ".hardware.windows.ram_gb == 31.1 and .hardware.windows.commit_limit_gb == 43.0 and (.hardware.windows.pending | length) == 4 and (.hardware.windows.warnings | length) >= 1"' _ "$J"
check "cn-status: load.windows_commit_free_gb is live" sh -c 'printf "%s\n" "$1" | jq -e ".load.windows_commit_free_gb == 20.0"' _ "$J"
check "cn-status line shows the pending steps" sh -c 'su tester -c "cn-status" | grep -q "4 PENDING"'
echo '45088768 1048576' >/tmp/mock-commit
check "low commit headroom becomes a live warning" sh -c 'su tester -c "cn-status --json" | jq -e ".load.windows_warnings[0] | test(\"low Windows commit headroom\")"'

MOCK_ELEVATE=accept script -qec 'bash /src/install.sh node --user tester --wsl yes --no-docker --no-tailscale' /dev/null >/dev/null 2>&1
check "with a terminal: one UAC launch" sh -c '[ "$(grep -c "^elevate accept" /tmp/mock-ps.log)" = 1 ]'
check "accepted: autostart/firewall/pagefile done, reboot + wsl-restart pending" sh -c '[ "$(jq -r "[.[].id] | join(\",\")" /etc/cnode/pending.json)" = "reboot,wsl-restart" ] && jq -e ".autostart == \"registered\"" /etc/cnode/windows.json'
echo '90282803 41943040' >/tmp/mock-commit       # after the reboot: limit 86.1 GB
check "after the reboot the pagefile step disappears from cn-status" sh -c 'su tester -c "cn-status --json" | jq -e "[.hardware.windows.pending[].id] == [\"wsl-restart\"]"'
OUT8="$(MOCK_ELEVATE=decline script -qec 'bash /src/install.sh node --user tester --wsl yes --no-docker --no-tailscale' /dev/null 2>&1)"
check "declined UAC: admin steps recorded as pending again" sh -c 'printf "%s\n" "$1" | grep -q "declined" && jq -e "[.[].id] | index(\"autostart\") != null" /etc/cnode/pending.json' _ "$OUT8"
: >/tmp/ts.log
OUT9="$(MOCK_TS=Running bash /src/install.sh node --user tester --wsl yes --no-docker 2>&1)"
check "Windows runs Tailscale: no second tailnet node inside WSL" sh -c 'printf "%s\n" "$1" | grep -q "Windows already runs Tailscale" && ! grep -q "^tailscale up" /tmp/ts.log' _ "$OUT9"
check "join host is the Windows machine's tailnet name" sh -c 'printf "%s\n" "$1" | grep -q "join: host=pc.tailnet.example "' _ "$OUT9"
check "the installer never runs wsl --shutdown or reboots" sh -c '! grep -qiE "shutdown|restart-computer" /tmp/mock-ps.log'
OUT10="$(bash /src/install.sh node --user tester --wsl yes --no-docker --no-tailscale --no-windows 2>&1)"
check "--no-windows skips the Windows side" sh -c '! echo "$1" | grep -q "Windows side"' _ "$OUT10"
unset CN_POWERSHELL CN_WSLPATH

echo "-- --agent-sudo"
bash /src/install.sh node --user tester --no-docker --no-tailscale --agent-sudo >/dev/null 2>&1
check "NOPASSWD sudo with --agent-sudo" su tester -c 'sudo -n true'
bash /src/install.sh node --user tester --no-docker --no-tailscale >/dev/null 2>&1
check "removed again without the flag (default: sudo needs a password)" sh -c '! su tester -c "sudo -n true" 2>/dev/null'

echo "-- refuses bad input"
check "unknown user without --create-user" sh -c '! bash /src/install.sh node --user nobody-here --no-docker >/dev/null 2>&1'
check "root as --user" sh -c '! bash /src/install.sh node --user root --no-docker >/dev/null 2>&1'
finish
