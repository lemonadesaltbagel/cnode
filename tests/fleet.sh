#!/usr/bin/env bash
# shellcheck disable=SC2016,SC2088,SC2001  # test snippets are single-quoted on purpose
# Fleet end to end in containers, real sshd and real certificates (no systemd, no TUN):
#   cntest-fl-n1, -n2, -n3   compute nodes installed with --fleet-ca (key-only, nothing authorized)
#   cntest-fl-ctl            control container: alice creates the fleet (admin), bob joins later;
#                            the store is a shared directory (dir:/srv/fleet) instead of GitHub
# Shows that a new control node works on every node after one approval, that a node added later
# reaches every control node by itself, and that revocation, host certificates and the inbox
# checks hold.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
. tests/lib.sh
mem_gate
IMG="${IMG:-debian:13}"
NET="cntest-fl-net-$$"; N1=cntest-fl-n1; N2=cntest-fl-n2; N3=cntest-fl-n3; CTL=cntest-fl-ctl
cleanup() { docker rm -f "$N1" "$N2" "$N3" "$CTL" >/dev/null 2>&1; docker network rm "$NET" >/dev/null 2>&1; }
[ -n "${KEEP:-}" ] || trap cleanup EXIT
cleanup
docker network create "$NET" >/dev/null || exit 1
for c in "$N1" "$N2" "$N3" "$CTL"; do
  docker run -d --memory 512m --name "$c" --hostname "${c#cntest-fl-}" --network "$NET" "$IMG" sleep infinity >/dev/null || exit 1
  repo_tar . | docker exec -i "$c" sh -c 'mkdir -p /src && tar -x -C /src'
done
as() { local u="$1"; shift   # as <user> <snippet>: on the control container, login-like env
  docker exec -i -u "$u" -e HOME="/home/$u" -e USER="$u" -e SHELL=/bin/bash -e LANG=C.UTF-8 -e CN_NO_TIMER=1 \
    -e PATH="/home/$u/.local/bin:/usr/local/bin:/usr/bin:/bin" -w "/home/$u" "$CTL" bash -c "$*" </dev/null; }
on() { local c="$1"; shift; docker exec -i "$c" bash -c "$*" </dev/null; }   # on <node> <snippet> (root)
dev() { local c="$1"; shift; docker exec -i -u dev -e HOME=/home/dev "$c" bash -c "$*" </dev/null; }
export -f as on dev; export CTL

echo "-- control container: alice creates the fleet"
on "$CTL" 'apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends openssh-client procps jq >/dev/null \
  && groupadd fleet && useradd -m -s /bin/bash -G fleet alice && useradd -m -s /bin/bash -G fleet bob \
  && install -d -m 2775 -g fleet /srv/fleet /srv/fleet/requests /srv/fleet/certs' >/dev/null 2>&1
check "control container ready" docker exec "$CTL" id bob
out="$(as alice 'umask 002; bash /src/install.sh control --no-install --no-docker --no-agent-rules --fleet-init dir:/srv/fleet --fleet-name lap-a --no-passphrase' 2>&1)"; rc=$?
echo "$out" | grep -E 'Fleet created|Back up|registry serial' | sed 's/^/    | /'
check "alice: install with --fleet-init exits 0" test "$rc" = 0
CA="$(as alice 'cut -d" " -f1,2 ~/.config/compute-node/fleet/ca.pub')"
CAFP="$(as alice 'ssh-keygen -lf ~/.config/compute-node/fleet/ca.pub | cut -d" " -f2')"
check "alice holds the CA" test -n "$CAFP"

echo "-- compute nodes join with --fleet-ca (key-only, no key authorized by hand)"
declare -A FP
for c in "$N1" "$N2"; do
  out="$(on "$c" "bash /src/install.sh node --user dev --create-user --no-docker --no-tailscale --key-only --fleet-ca '$CA'" 2>&1)"; rc=$?
  check "$c: node install exits 0" test "$rc" = 0
  [ "$rc" = 0 ] || echo "$out" | tail -n 15 | sed 's/^/    | /'
  check "$c: join line names cnode fleet add-node" sh -c 'echo "$1" | grep -q "cnode fleet add-node .* --user dev --port 2222 --fingerprint SHA256:"' _ "$out"
  FP[$c]="$(echo "$out" | sed -n 's/.*join: .*fingerprint=\(SHA256:[^ ]*\).*/\1/p' | head -n1)"
done
check "n1: sshd trusts the fleet CA, principals file for dev, revocation list" on "$N1" 'sshd -T -C user=dev,host=x,addr=10.0.0.1 | grep -q "^trustedusercakeys /etc/cnode/fleet/ca.pub" && sshd -T -C user=dev,host=x,addr=10.0.0.1 | grep -q "^revokedkeys /etc/cnode/fleet/revoked.krl" && [ "$(cat /etc/cnode/fleet/principals/dev)" = cnode ]'
check "n1: no authorized_keys for dev" on "$N1" '! [ -s /home/dev/.ssh/authorized_keys ]'
check "n1: inbox loop running (no systemd)" on "$N1" 'kill -0 "$(cat /run/cnode-fleet-loop.pid)"'
check "n1: no host certificate yet" on "$N1" 'cn-fleet-apply --status | grep -q "host certificate: none"'

echo "-- alice: add-node n1 (pinned), n2 (first use)"
out="$(as alice "cnode fleet add-node n1 --host $N1 --user dev --fingerprint ${FP[$N1]}" 2>&1)"; rc=$?
echo "$out" | sed 's/^/    | /' | tail -n 4
check "add-node n1 exits 0" test "$rc" = 0
check "n1 presents a host certificate from the fleet CA" on "$N1" 'cn-fleet-apply --status | grep -q "host certificate: Valid: from"'
check "add-node with a wrong fingerprint is refused" sh -c '! docker exec -u alice -e HOME=/home/alice -e CN_NO_TIMER=1 '"$CTL"' /home/alice/.local/bin/cnode fleet add-node n2 --host '"$N2"' --user dev --fingerprint '"${FP[$N1]}"' 2>/dev/null'
check "add-node n2 (trust on first use)" as alice "cnode fleet add-node n2 --host $N2 --user dev"
check "alice: list shows n1 and n2 as fleet nodes" as alice '[ "$(cnode list | grep -c "(fleet)")" = 2 ]'
check "alice: rx -n n1 with the certificate (nothing in authorized_keys)" as alice 'cd /tmp && [ "$(rx -n n1 hostname)" = n1 ]'
check "alice: ssh cn-n2 verifies the host certificate" as alice 'ssh -o BatchMode=yes cn-n2 true'
sleep 6   # the inbox loop on the nodes runs every 5 s
check "n1 and n2 got the registry (serial applied)" bash -c 'on '"$N1"' "cat /etc/cnode/fleet/serial" | grep -qx "[0-9]*" && on '"$N2"' "cat /etc/cnode/fleet/serial" | grep -qx "[0-9]*"'
J="$(as alice 'rx nodes --json')"
check "rx nodes --json: both reachable, fleet state with host certificate" sh -c 'printf "%s\n" "$1" | docker exec -i '"$CTL"' jq -e "length == 2 and all(.[]; .reachable and .fleet.host_cert and .fleet.serial > 0)"' _ "$J"

echo "-- bob: a new control node; one approval, nothing on any compute node"
out="$(as bob "umask 002; bash /src/install.sh control --no-install --no-docker --no-agent-rules --fleet dir:/srv/fleet --fleet-ca $CAFP --fleet-name lap-b" 2>&1)"; rc=$?
echo "$out" | grep -E 'Asked|approve' | sed 's/^/    | /'
check "bob: install with --fleet exits 0, waiting for approval" sh -c '[ "$2" = 0 ] && echo "$1" | grep -q "cnode fleet approve lap-b"' _ "$out" "$rc"
check "bob: cannot log in before approval" sh -c '! docker exec -u bob -e HOME=/home/bob '"$CTL"' ssh -o BatchMode=yes cn-n1 true 2>/dev/null'
check "bob: a wrong --fleet-ca is refused (and leaves his join in place)" sh -c '! docker exec -u bob -e HOME=/home/bob -e CN_NO_TIMER=1 '"$CTL"' /home/bob/.local/bin/cnode fleet join dir:/srv/fleet --ca SHA256:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA 2>/dev/null'
check "bob: still waiting for approval after the refused re-join" as bob 'cnode fleet status --no-sync | grep -q "waiting for approval"'
check "alice: approve lap-b" as alice 'cnode fleet approve lap-b'
check "bob: after one sync, rx -n n1 and n2 work" as bob 'cnode fleet sync >/dev/null && cd /tmp && [ "$(rx -n n1 hostname)" = n1 ] && [ "$(rx -n n2 hostname)" = n2 ]'
check "still nothing in dev's authorized_keys on n1/n2" bash -c 'on '"$N1"' "! [ -s /home/dev/.ssh/authorized_keys ]" && on '"$N2"' "! [ -s /home/dev/.ssh/authorized_keys ]"'

echo "-- a compute node added later reaches every control node by itself"
out="$(on "$N3" "bash /src/install.sh node --user dev --create-user --no-docker --no-tailscale --key-only --fleet-ca '$CA'" 2>&1)"; rc=$?
check "n3: node install exits 0" test "$rc" = 0
[ "$rc" = 0 ] || echo "$out" | tail -n 15 | sed 's/^/    | /'
check "alice: add-node n3" as alice "cnode fleet add-node n3 --host $N3 --user dev"
check "bob: n3 appears after a sync and rx works, no step on bob's side" as bob 'cnode fleet sync | grep -q "node .n3. joined" && cd /tmp && [ "$(rx -n n3 hostname)" = n3 ]'
check "bob: rx nodes lists 3 fleet nodes" as bob '[ "$(rx nodes --json | jq length)" = 3 ]'

echo "-- host certificates: an impostor without one is refused"
on "$N2" 'mv /etc/ssh/ssh_host_ed25519_key-cert.pub /root/cert.bak && cn-fleet-apply --configure && kill -HUP "$(cat /run/sshd.pid)"'; sleep 1
check "bob: n2 without its certificate fails host verification" as bob 'ssh -O exit cn-n2 >/dev/null 2>&1; ! ssh -o BatchMode=yes cn-n2 true 2>/dev/null'
on "$N2" 'mv /root/cert.bak /etc/ssh/ssh_host_ed25519_key-cert.pub && cn-fleet-apply --configure && kill -HUP "$(cat /run/sshd.pid)"'; sleep 1
check "bob: n2 with its certificate again" as bob 'ssh -o BatchMode=yes cn-n2 true'

echo "-- the inbox trusts nothing (written by the node user = any control node)"
S1="$(on "$N1" 'cat /etc/cnode/fleet/serial')"
dev "$N1" 'mkdir -p ~/.cnode/inbox && sed "s/^serial .*/serial 999/" /etc/cnode/fleet/registry.signed > ~/.cnode/inbox/registry.signed'; sleep 7
check "n1: a tampered registry is rejected (serial unchanged)" bash -c '[ "$(on '"$N1"' "cat /etc/cnode/fleet/serial")" = "$1" ]' _ "$S1"
dev "$N1" 'ln -sf /etc/shadow ~/.cnode/inbox/registry.signed'; sleep 7
check "n1: a symlink in the inbox is dropped, inbox empty" dev "$N1" '[ -z "$(ls -A ~/.cnode/inbox)" ]'
docker cp "$N2:/etc/ssh/ssh_host_ed25519_key-cert.pub" "${TMPDIR:-/tmp}/n2cert.$$" && docker cp "${TMPDIR:-/tmp}/n2cert.$$" "$N1:/tmp/n2cert" && rm -f "${TMPDIR:-/tmp}/n2cert.$$"
on "$N1" 'cp /etc/ssh/ssh_host_ed25519_key-cert.pub /root/own.cert; chmod 644 /tmp/n2cert'
dev "$N1" 'cp /tmp/n2cert ~/.cnode/inbox/host-cert.pub'; sleep 7
check "n1: another host's certificate is rejected" on "$N1" 'cmp -s /etc/ssh/ssh_host_ed25519_key-cert.pub /root/own.cert'

echo "-- revocation: immediate on reachable nodes, delivered later to the others"
docker pause "$N3" >/dev/null
out="$(as alice 'cnode fleet revoke lap-b' 2>&1)"; rc=$?
echo "$out" | sed 's/^/    | /'
docker unpause "$N3" >/dev/null
check "revoke exits 0 and reports n3 as not reached" sh -c '[ "$2" = 0 ] && echo "$1" | grep -q "Not yet on: n3"' _ "$out" "$rc"
sleep 7
check "bob: refused by n1 (new connection)" as bob '! ssh -o BatchMode=yes -o ControlPath=none cn-n1 true 2>/dev/null'
check "bob: his open SSH master to n1 was ended too" as bob 'cd /tmp && ! rx -n n1 true 2>/dev/null'
check "bob: n3 still accepts him until it gets the registry" as bob 'ssh -o BatchMode=yes -o ControlPath=none cn-n3 true'
check "alice: a sync delivers the revocation to n3" as alice 'cnode fleet sync | grep -q "delivered to: n3"'
sleep 7
check "bob: refused by n3 now" as bob '! ssh -o BatchMode=yes -o ControlPath=none cn-n3 true 2>/dev/null'
check "alice: unaffected" as alice 'cd /tmp && [ "$(rx -n n3 hostname)" = n3 ]'

echo "-- remove-node, node re-install keeps the fleet, --no-fleet leaves it"
check "alice: remove-node n3" as alice 'cnode fleet remove-node n3 >/dev/null && ! cnode list | grep -q "^  n3 "'
check "n3's host key now revoked for control nodes" as alice '! ssh -F /dev/null -o BatchMode=yes -o UserKnownHostsFile=$HOME/.config/compute-node/fleet/known_hosts -o RevokedHostKeys=$HOME/.config/compute-node/fleet/revoked.krl -o HostKeyAlias=cn-n3 -o StrictHostKeyChecking=yes -p 2222 dev@'"$N3"' true 2>/dev/null'
on "$N1" 'bash /src/install.sh node --user dev --no-docker --no-tailscale --key-only' >/dev/null 2>&1
check "n1: re-run without --fleet-ca stays in the fleet" as alice 'ssh -O exit cn-n1 >/dev/null 2>&1; ssh -o BatchMode=yes cn-n1 true'
on "$N1" 'bash /src/install.sh node --user dev --no-docker --no-tailscale --key-only --no-fleet' >/dev/null 2>&1
check "n1: --no-fleet removes the CA trust" on "$N1" '[ ! -e /etc/cnode/fleet ] && [ ! -e /etc/ssh/sshd_config.d/05-cnode-fleet.conf ] && ! sshd -T -C user=dev,host=x,addr=10.0.0.1 | grep -q "^trustedusercakeys /"'
finish
