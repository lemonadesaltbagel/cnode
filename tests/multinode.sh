#!/usr/bin/env bash
# shellcheck disable=SC2016,SC2088,SC2001  # test snippets are single-quoted on purpose
# Many control nodes x many compute nodes, end to end, in containers on one docker network:
#   cntest-mn-n1, cntest-mn-n2   compute nodes (node install, --no-docker)
#   cntest-mn-ctl                control node with two users, alice and bob (two separate HOMEs,
#                                registries, keys and Mutagen daemons) using the real installer,
#                                real ssh and a real Mutagen release binary
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
. tests/lib.sh
mem_gate
IMG="${IMG:-debian:13}"
NET="cntest-mn-net-$$"; N1=cntest-mn-n1; N2=cntest-mn-n2; CTL=cntest-mn-ctl
cleanup() { docker rm -f "$N1" "$N2" "$CTL" >/dev/null 2>&1; docker network rm "$NET" >/dev/null 2>&1; }
trap cleanup EXIT
cleanup
docker network create "$NET" >/dev/null || exit 1
for c in "$N1" "$N2" "$CTL"; do
  docker run -d --name "$c" --hostname "${c#cntest-mn-}" --network "$NET" "$IMG" sleep infinity >/dev/null || exit 1
  repo_tar . | docker exec -i "$c" sh -c 'mkdir -p /src && tar -x -C /src'
done

# as <user> <shell snippet>   run on the control container as alice or bob, in a login-like env
as() { local u="$1"; shift
  docker exec -i -u "$u" -e HOME="/home/$u" -e USER="$u" -e SHELL=/bin/bash -e LANG=C.UTF-8 \
    -e PATH="/home/$u/.local/bin:/usr/local/bin:/usr/bin:/bin" -w "/home/$u" "$CTL" bash -c "$*" </dev/null; }

FP_n1=""; FP_n2=""
echo "-- compute nodes"
for c in "$N1" "$N2"; do
  out="$(docker exec "$c" bash /src/install.sh node --user dev --create-user --no-docker 2>&1)"; rc=$?
  check "$c: node install exits 0" test "$rc" = 0
  fp="$(echo "$out" | sed -n 's/.*join: .*fingerprint=\(SHA256:[^ ]*\).*/\1/p' | head -n1)"
  check "$c: join line has a fingerprint" test -n "$fp"
  case "$c" in "$N1") FP_n1="$fp" ;; *) FP_n2="$fp" ;; esac
done

echo "-- control node users (alice, bob)"
docker exec "$CTL" sh -c 'apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends \
  openssh-client curl ca-certificates jq procps >/dev/null && useradd -m -s /bin/bash alice && useradd -m -s /bin/bash bob \
  && mkdir -p /Users/alice/proj /Users/bob/proj && chown -R alice /Users/alice && chown -R bob /Users/bob' >/dev/null 2>&1
check "control container ready" docker exec "$CTL" id bob

out="$(as alice "bash /src/install.sh control --name n1 --host $N1 --user dev --fingerprint $FP_n1 --no-docker --agent-rules /home/alice/AGENTS.md" 2>&1)"; rc=$?
echo "$out" | grep -E 'mutagen|not authorized|cn-authorize' | head -n 4 | sed 's/^/    | /'
check "alice: install exits 0 although the key is not authorized yet" test "$rc" = 0
check "alice: real mutagen installed" as alice 'mutagen version'
check "alice: install prints the cn-authorize line" sh -c 'echo "$1" | grep -q "cn-authorize '"'"'ssh-ed25519 "' _ "$out"
check "alice: AGENTS.md rules mention rx nodes --json" as alice 'grep -q "rx nodes --json" AGENTS.md'
KA="$(as alice 'cnode key')"
check "authorize alice on n1 (cn-authorize, as dev)" docker exec -u dev "$N1" bash -c "$KA"
check "authorize alice on n2" docker exec -u dev "$N2" bash -c "$KA"
check "alice: key login to n1 works now" as alice 'ssh -o BatchMode=yes cn-n1 true'
check "alice: rx outside a synced path explains itself" sh -c "docker exec -u alice -e HOME=/home/alice -w /home/alice $CTL /home/alice/.local/bin/rx -n n1 true 2>&1 | grep -q 'does not exist on n1'"
check "alice: cnode add n2 with the right fingerprint" as alice "cnode add n2 --host $N2 --user dev --fingerprint $FP_n2"
check "alice: wrong fingerprint refused" sh -c "! docker exec -u alice -e HOME=/home/alice $CTL /home/alice/.local/bin/cnode add n3 --host $N1 --user dev --fingerprint SHA256:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
check "alice: n1 key does not pass for n2 (pinned per node)" sh -c "! docker exec -u alice -e HOME=/home/alice $CTL /home/alice/.local/bin/cnode add n2b --host $N2 --user dev --fingerprint $FP_n1"
check "alice: two nodes registered, default n1" as alice '[ "$(cnode list | grep -c "dev@")" = 2 ] && [ "$(cnode default)" = n1 ]'

echo "-- one folder synced to two nodes"
as alice 'echo hello >/Users/alice/proj/input.txt'
check "alice: wsync -n n1" as alice 'cd /Users/alice/proj && wsync -n n1'
check "alice: wsync -n n2 (same folder)" as alice 'cd /Users/alice/proj && wsync -n n2'
check "alice: wsync again is a no-op" as alice 'cd /Users/alice/proj && wsync -n n1 | grep -q "already syncing"'
check "file arrived on n1 at the same path" sh -c "[ \"\$(docker exec $N1 cat /Users/alice/proj/input.txt)\" = hello ]"
check "file arrived on n2 at the same path" sh -c "[ \"\$(docker exec $N2 cat /Users/alice/proj/input.txt)\" = hello ]"
check "rx -n n1 output syncs back" as alice 'cd /Users/alice/proj && rx -n n1 "hostname > from-n1.txt" && [ "$(cat from-n1.txt)" = n1 ]'
check "rx -n n2 output syncs back" as alice 'cd /Users/alice/proj && rx -n n2 "hostname > from-n2.txt" && [ "$(cat from-n2.txt)" = n2 ]'
check "rx runs in the same path" as alice 'cd /Users/alice/proj && [ "$(rx -n n2 pwd)" = /Users/alice/proj ]'
check "rx without -n uses the default node" as alice 'cd /Users/alice/proj && [ "$(rx hostname)" = n1 ]'
check "RX_NODE overrides the default" as alice 'cd /Users/alice/proj && [ "$(RX_NODE=n2 rx hostname)" = n2 ]'
as alice 'cd /Users/alice/proj && rx "exit 7"' >/dev/null 2>&1; rc=$?
check "rx passes the exit code through" test "$rc" = 7
check "rx -n unknown fails" sh -c "! docker exec -u alice -e HOME=/home/alice -w /Users/alice/proj $CTL /home/alice/.local/bin/rx -n nope true"
check "start a tmux job on n2 via rx" as alice 'cd /Users/alice/proj && rx -n n2 "tmux new -d -s job1 \"sleep 600\""'

echo "-- rx nodes --json"
J="$(as alice 'rx nodes --json')"
echo "$J" | head -c 400 | sed 's/^/    | /'; echo
check "valid JSON, 2 nodes, both reachable" sh -c 'printf "%s\n" "$1" | docker exec -i '"$CTL"' jq -e "length == 2 and all(.[]; .reachable)"' _ "$J"
check "n1 is the default" sh -c 'printf "%s\n" "$1" | docker exec -i '"$CTL"' jq -e ".[] | select(.name==\"n1\") | .default"' _ "$J"
check "hardware (cpu model, RAM) and load (mem, disk) reported" sh -c 'printf "%s\n" "$1" | docker exec -i '"$CTL"' jq -e "all(.[]; .hardware.cpus_effective > 0 and (.hardware.cpu_model|length) > 0 and .hardware.mem_total_mb > 0 and .load.mem_available_mb > 0 and .load.disk[0].free_mb > 0)"' _ "$J"
check "n2 lists tmux job1" sh -c 'printf "%s\n" "$1" | docker exec -i '"$CTL"' jq -e ".[] | select(.name==\"n2\") | .load.tmux | index(\"job1\") != null"' _ "$J"
check "each node shows its sync session for the folder" sh -c 'printf "%s\n" "$1" | docker exec -i '"$CTL"' jq -e "all(.[]; .sync | map(.path) | index(\"/Users/alice/proj\") != null)"' _ "$J"

echo "-- second control node (bob): TOFU with --accept-new, then both nodes"
out="$(as bob "bash /src/install.sh control --name n2 --host $N2 --user dev --accept-new --no-docker" 2>&1)"; rc=$?
check "bob: install exits 0" test "$rc" = 0
KB="$(as bob 'cnode key')"
check "bob's key differs from alice's" test "$KA" != "$KB"
docker exec -u dev "$N2" bash -c "$KB" >/dev/null && docker exec -u dev "$N1" bash -c "$KB" >/dev/null
check "bob: key login to n2" as bob 'ssh -o BatchMode=yes cn-n2 true'
check "bob: cnode add n1" as bob "cnode add n1 --host $N1 --user dev --fingerprint $FP_n1"
as bob 'echo bob >/Users/bob/proj/b.txt'
check "bob: wsync -n n2" as bob 'cd /Users/bob/proj && wsync -n n2'
check "bob: rx -n n2 sees bob's files" as bob 'cd /Users/bob/proj && [ "$(rx -n n2 cat b.txt)" = bob ]'
check "n2 holds both users' folders side by side" docker exec "$N2" sh -c 'test -f /Users/alice/proj/input.txt && test -f /Users/bob/proj/b.txt'
check "bob does not see alice's sync sessions" as bob '! wsync -l 2>/dev/null | grep -q /Users/alice'
check "bob: rx nodes --json lists 2 reachable nodes" sh -c 'docker exec -u bob -e HOME=/home/bob '"$CTL"' /home/bob/.local/bin/rx nodes --json | docker exec -i '"$CTL"' jq -e "length == 2 and all(.[]; .reachable)"'

echo "-- one compute node down"
docker stop -t 1 "$N2" >/dev/null
t0=$(date +%s)
J="$(as alice 'RX_NODES_TIMEOUT=8 rx nodes --json')"; rc=$?
dt=$(( $(date +%s) - t0 ))
echo "$J" | docker exec -i "$CTL" jq -c '.[] | {name, reachable, error}' 2>/dev/null | sed 's/^/    | /'
check "rx nodes still exits 0" test "$rc" = 0
check "n2 reported unreachable with an error" sh -c 'printf "%s\n" "$1" | docker exec -i '"$CTL"' jq -e ".[] | select(.name==\"n2\") | (.reachable == false and (.error|length) > 0)"' _ "$J"
check "n1 still reachable" sh -c 'printf "%s\n" "$1" | docker exec -i '"$CTL"' jq -e ".[] | select(.name==\"n1\") | .reachable"' _ "$J"
check "returned within the timeout (${dt}s)" test "$dt" -le 12
T="$(as alice 'RX_NODES_TIMEOUT=8 rx nodes')"; echo "$T" | sed 's/^/    | /'
check "table marks n2 DOWN" sh -c 'echo "$1" | grep -q "n2 .*DOWN"' _ "$T"
check "rx to n1 unaffected" as alice 'cd /Users/alice/proj && [ "$(rx -n n1 hostname)" = n1 ]'

echo "-- a node that hangs (paused container, live SSH master) hits the timeout"
docker pause "$N1" >/dev/null
t0=$(date +%s)
J="$(as alice 'RX_NODES_TIMEOUT=4 rx nodes --json')"
dt=$(( $(date +%s) - t0 ))
docker unpause "$N1" >/dev/null
check "hung n1 reported as timed out" sh -c 'printf "%s\n" "$1" | docker exec -i '"$CTL"' jq -e ".[] | select(.name==\"n1\") | (.reachable == false and (.error | test(\"timed out\")))"' _ "$J"
check "rx nodes returned after ~4s (${dt}s)" test "$dt" -le 7

echo "-- cnode remove"
check "alice: remove n2" as alice 'cnode remove n2'
check "alice: n2 gone from list and ssh_config" as alice '! cnode list | grep -q "^  n2 " && ! grep -q cn-n2 ~/.config/compute-node/ssh_config'
finish
