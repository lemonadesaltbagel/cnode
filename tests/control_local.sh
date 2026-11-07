#!/usr/bin/env bash
# shellcheck disable=SC2016,SC2088,SC2001  # test snippets are single-quoted on purpose
# Control-node install in throwaway HOMEs on this machine. ssh, ssh-keyscan, ssh-copy-id,
# mutagen, docker and brew are replaced by stubs that only log their arguments, so nothing
# outside the temporary directory is read or changed (no network, no real sync sessions).
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
REPO="$(pwd)"
. tests/lib.sh
W="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/cn-control-test.XXXXXX")" && pwd -P)"
trap 'rm -rf "$W"' EXIT
STUBS="$W/stubs"; LOG="$W/calls.log"; STATE="$W/state"
mkdir -p "$STUBS" "$STATE"; : >"$LOG"; : >"$STATE/sessions"; : >"$STATE/contexts"
ssh-keygen -q -t ed25519 -N '' -f "$W/hostkey" -C testhost
HOSTPUB="$(cut -d' ' -f1,2 "$W/hostkey.pub")"
HOSTFP="$(ssh-keygen -lf "$W/hostkey.pub" | awk '{print $2}')"
ssh-keygen -q -t ed25519 -N '' -f "$W/altkey" -C otherhost
ALTPUB="$(cut -d' ' -f1,2 "$W/altkey.pub")"

stub() { printf '#!/usr/bin/env bash\nLOG=%q; STATE=%q; HOSTPUB=%q; ALTPUB=%q\necho "$(basename "$0") $*" >>"$LOG"\n%s\n' "$LOG" "$STATE" "$HOSTPUB" "$ALTPUB" "$2" >"$STUBS/$1"; chmod +x "$STUBS/$1"; }
# ssh-keyscan: the test host key, or another one once "$STATE/altkey" exists (a changed/impostor host)
stub ssh-keyscan 'host="${!#}"; if [ -f "$STATE/altkey" ]; then echo "$host $ALTPUB"; else echo "$host $HOSTPUB"; fi'
stub ssh-copy-id 'exit 0'
stub brew 'exit 0'
# ssh: -O exit / "true" succeed (for cn-pw* only after the password login installed the key);
# the password login checks the askpass answer; the status probe prints a fixed snapshot;
# anything else is echoed back; a remote command containing "exit 7" exits 7.
stub ssh 'case "$*" in
  *"-O exit"*) exit 0 ;;
  *"PubkeyAuthentication=no"*)
    [ -n "${SSH_ASKPASS:-}" ] && [ "$("$SSH_ASKPASS")" = s3cret ] || exit 255
    echo "$*" >"$STATE/pwcmd"; touch "$STATE/pw-authorized" ;;
  *cn-pw*" true") [ -f "$STATE/pw-authorized" ] ;;
  *" true") exit 0 ;;
  *"bash -s -- --both"*) cat >/dev/null
    echo "Test CPU 4C/8T eff 8, 31G RAM, no GPU | load 0.10, mem 20G free, disk /Users:100G, tmux - | Windows commit 30/86G free, 1 PENDING STEP(S)"
    echo "{\"hostname\":\"stub\",\"hardware\":{\"cpu_model\":\"Test CPU\",\"cpu_cores\":4,\"cpu_threads\":8,\"cpus_effective\":8,\"mem_total_mb\":32000,\"gpus\":[],\"windows\":{\"ram_gb\":31.1,\"pending\":[{\"id\":\"reboot\",\"run\":\"Restart Windows\"}]}},\"load\":{\"loadavg\":[0.1,0.1,0.1],\"mem_available_mb\":20000,\"gpus\":[],\"disk\":[],\"tmux\":[],\"windows_commit_free_gb\":30.0}}" ;;
  *"mkdir -p"*) exit 0 ;;
  *"exit\ 7"*) exit 7 ;;
  *) echo "REMOTE: $*" ;;
esac'
stub mutagen 'case "$1 $2" in
  "version "*) echo 0.18.1 ;;
  "daemon "*) exit 0 ;;
  "sync list")
    if [ "${3:-}" = --label-selector ]; then
      while read -r n l p; do [ "compute=$l" = "$4" ] && printf "%s\tWatching\t%s\t0\ttrue\tfalse\n" "$n" "$p"; done <"$STATE/sessions"; exit 0; fi
    grep -q "^${3:-x} " "$STATE/sessions" ;;
  "sync create") n=""; l=""; for a in "$@"; do case "$a" in --name=*) n="${a#--name=}";; compute=*) l="${a#compute=}";; esac; done
    echo "$n $l $3" >>"$STATE/sessions" ;;
  "sync flush"|"sync terminate") exit 0 ;;
  *) exit 0 ;;
esac'
stub docker 'case "$1 $2" in
  "context inspect") grep -qx "$3" "$STATE/contexts" || exit 1; echo "ssh://cn-$3" ;;
  "context create") echo "$3" >>"$STATE/contexts" ;;
  "context use") echo "$3" >"$STATE/current" ;;
  "context show") cat "$STATE/current" 2>/dev/null ;;
  "context rm") grep -vx "$3" "$STATE/contexts" >"$STATE/c2"; mv "$STATE/c2" "$STATE/contexts" ;;
esac'

new_home() { local h="$W/$1"; mkdir -p "$h"; echo "$h"; }
as_user() { # as_user HOME cmd...  (clean environment; stubs first on PATH)
  local h="$1"; shift
  env -i HOME="$h" PATH="$STUBS:$h/.local/bin:/usr/bin:/bin:/usr/sbin:/sbin" SHELL=/bin/zsh TMPDIR="$W" LANG=C "$@"
}
snapshot() { (cd "$1" && find . \( -type f -o -type l \) ! -path './.ssh/cm/*' | LC_ALL=C sort | while read -r f; do
  if [ -L "$f" ]; then echo "$f -> $(readlink "$f")"; else echo "$f $(cksum <"$f")"; fi; done); }

echo "-- fresh HOME, first run"
H1="$(new_home home1)"
OUT="$(as_user "$H1" bash "$REPO/install.sh" control --host node1.example.test --user alice \
        --fingerprint "$HOSTFP" --no-install 2>&1)"; rc=$?
echo "$OUT" | sed 's/^/    | /' | tail -n 12
check "install exits 0" test "$rc" = 0
check "cnode installed and executable" test -x "$H1/.local/bin/cnode"
check "rx -> cnode symlink" test "$(readlink "$H1/.local/bin/rx")" = cnode
check "wsync -> cnode symlink" test "$(readlink "$H1/.local/bin/wsync")" = cnode
check "cn-status copy for rx nodes" test -f "$H1/.local/share/compute-node/cn-status"
check "~/.ssh/config starts with the Include block" test "$(head -n1 "$H1/.ssh/config")" = "# BEGIN compute-node"
check "~/.ssh/config mode 600" test "$(stat -f %Lp "$H1/.ssh/config" 2>/dev/null || stat -c %a "$H1/.ssh/config")" = 600
check "registry line" grep -qx "wsl node1.example.test alice 2222" "$H1/.config/compute-node/nodes"
check "default node is wsl" grep -qx wsl "$H1/.config/compute-node/default"
check "pinned host key under alias cn-wsl" grep -q "^cn-wsl ssh-ed25519 " "$H1/.config/compute-node/known_hosts"
check "Host cn-wsl wsl block" grep -qx "Host cn-wsl wsl" "$H1/.config/compute-node/ssh_config"
check "StrictHostKeyChecking yes" grep -q "StrictHostKeyChecking yes" "$H1/.config/compute-node/ssh_config"
check "connection reuse" grep -q "ControlPersist 30m" "$H1/.config/compute-node/ssh_config"
check "SSH key generated" test -f "$H1/.ssh/id_ed25519.pub"
check "PATH line in ~/.zshrc" grep -q '.local/bin' "$H1/.zshrc"
check "agent rules block in ~/.claude/CLAUDE.md" grep -q '^<!-- BEGIN compute-node -->$' "$H1/.claude/CLAUDE.md"
check "docker context wsl created" grep -qx wsl "$STATE/contexts"
check "docker context wsl is default" grep -qx wsl "$STATE/current"
check "mutagen daemon registered (stub)" grep -q '^mutagen daemon register' "$LOG"
check "cnode key prints the manual cn-authorize line" sh -c "env -i HOME='$H1' PATH=/usr/bin:/bin '$H1/.local/bin/cnode' key | grep -q \"^cn-authorize 'ssh-ed25519 \""

echo "-- second run changes nothing"
before="$(snapshot "$H1")"
as_user "$H1" bash "$REPO/install.sh" control --host node1.example.test --user alice \
  --fingerprint "$HOSTFP" --no-install >/dev/null 2>&1
check "second run exits 0" test $? = 0
after="$(snapshot "$H1")"
if [ "$before" = "$after" ]; then ok "HOME identical after re-run ($(echo "$after" | wc -l | tr -d ' ') files)"
else bad "HOME changed on re-run:"; diff <(echo "$before") <(echo "$after") | sed 's/^/      /'; fi
check "no second docker context" test "$(grep -cx wsl "$STATE/contexts")" = 1

echo "-- host key verification"
OUT="$(as_user "$H1" cnode add evil --host node1.example.test --user alice --fingerprint SHA256:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA 2>&1)"; rc=$?
check "wrong fingerprint is refused" test "$rc" != 0
check "refused node not registered" sh -c "! grep -q '^evil ' '$H1/.config/compute-node/nodes'"
OUT="$(as_user "$H1" cnode add gpu2 --host other.example.test --user bob --port 2200 </dev/null 2>&1)"; rc=$?
check "no --fingerprint: trusted on first use, second node added" test "$rc" = 0
check "TOFU prints the fingerprint" sh -c "echo \"\$1\" | grep -q 'first use: $HOSTFP'" _ "$OUT"
touch "$STATE/altkey"
OUT="$(as_user "$H1" cnode add gpu2 --host other.example.test --user bob --port 2200 </dev/null 2>&1)"; rc=$?
check "a changed host key for a known node is refused" sh -c "[ $rc != 0 ] && echo \"\$1\" | grep -q CHANGED" _ "$OUT"
check "the pinned key was not replaced" grep -q "^cn-gpu2 $HOSTPUB" "$H1/.config/compute-node/known_hosts"
rm -f "$STATE/altkey"
check "second node has its own alias" grep -qx "Host cn-gpu2" "$H1/.config/compute-node/ssh_config"
check "default stays wsl" grep -qx wsl "$H1/.config/compute-node/default"
check "bad name rejected" sh -c "! env -i HOME='$H1' PATH='$STUBS:/usr/bin:/bin' '$H1/.local/bin/cnode' add Bad_Name --host x --user y"

echo "-- first login with a password installs the key"
OUT="$(as_user "$H1" cnode add pw1 --host pw.example.test --user dave </dev/null 2>&1)"; rc=$?
check "no password and no terminal: exit 3 with the cn-authorize fallback" sh -c "[ $rc = 3 ] && echo \"\$1\" | grep -q \"cn-authorize 'ssh-ed25519 \"" _ "$OUT"
OUT="$(as_user "$H1" env CN_PASSWORD=s3cret cnode add pw1 --host pw.example.test --user dave </dev/null 2>&1)"; rc=$?
check "CN_PASSWORD: password login once, then key login works" test "$rc" = 0
check "the password login appends this machine's public key" grep -qF "$(cut -d' ' -f2 "$H1/.ssh/id_ed25519.pub")" "$STATE/pwcmd"
check "it does not use or reuse the key/master for that login" sh -c "grep -q 'ControlPath=none' '$STATE/pwcmd' && grep -q 'PubkeyAuthentication=no' '$STATE/pwcmd'"
check "wrong password fails" sh -c "rm -f '$STATE/pw-authorized'; ! env -i HOME='$H1' PATH='$STUBS:/usr/bin:/bin' CN_PASSWORD=nope '$H1/.local/bin/cnode' add pw2 --host pw2.example.test --user dave </dev/null >/dev/null 2>&1"
as_user "$H1" cnode remove pw2 >/dev/null 2>&1; as_user "$H1" cnode remove pw1 >/dev/null 2>&1

echo "-- piped install (curl | bash) fetching the other files from CN_RAW_URL"
H5="$(new_home home5)"
OUT="$(cat "$REPO/install.sh" | as_user "$H5" env CN_RAW_URL="file://$REPO" bash -s -- control --no-install --no-agent-rules 2>&1)"; rc=$?
check "piped install works (files fetched from the URL)" sh -c "[ $rc = 0 ] && test -x '$H5/.local/bin/cnode' && test -f '$H5/.local/share/compute-node/cn-status'"

echo "-- wsync / rx"
P="$H1/proj"; mkdir -p "$P/sub"
SID_WSL="wsl-$(printf '%s\n' "$P" | shasum | cut -c1-10)"
SID_GPU="gpu2-$(printf '%s\n' "$P" | shasum | cut -c1-10)"
( cd "$P" && as_user "$H1" wsync ) >/dev/null 2>&1
check "wsync: session $SID_WSL (default node) created" grep -q "^$SID_WSL wsl $P$" "$STATE/sessions"
check "wsync: endpoint cn-wsl:<same path>, two-way-resolved, ignores" grep -q "mutagen sync create $P cn-wsl:$P --name=$SID_WSL --label compute=wsl --sync-mode=two-way-resolved --ignore=node_modules --ignore=.venv" "$LOG"
( cd "$P" && as_user "$H1" wsync -n gpu2 ) >/dev/null 2>&1
check "wsync -n gpu2: second session for the same folder" grep -q "^$SID_GPU gpu2 $P$" "$STATE/sessions"
: >"$LOG"
OUT="$(cd "$P/sub" && as_user "$H1" rx echo 'a b' 2>&1)"
check "rx runs in the same path" sh -c "echo \"\$1\" | grep -qF \"REMOTE: -q cn-wsl cd $P/sub 2>/dev/null ||\"" _ "$OUT"
check "rx runs the command in a login shell, quoted" sh -c "echo \"\$1\" | grep -qF \"; exec bash -lc echo\\ a\\ b\"" _ "$OUT"
check "rx flushes before and after (session found from a subdirectory)" test "$(grep -c "^mutagen sync flush $SID_WSL$" "$LOG")" = 2
: >"$LOG"
OUT="$(cd "$P" && as_user "$H1" rx -n gpu2 hostname 2>&1)"
check "rx -n gpu2 uses cn-gpu2 and its session" sh -c "grep -q '^ssh -q cn-gpu2 ' '$LOG' && grep -q '^mutagen sync flush $SID_GPU$' '$LOG'"
(cd "$P" && as_user "$H1" rx 'exit 7') >/dev/null 2>&1; rc=$?
check "rx passes the exit code through" test "$rc" = 7
: >"$LOG"
(cd "$P" && as_user "$H1" env RX_NODE=gpu2 rx true) >/dev/null 2>&1
check "RX_NODE selects the node" sh -c "grep -q '^ssh -q cn-gpu2 ' '$LOG'"
OUT="$(cd "$H1" && as_user "$H1" rx true 2>&1)"
check "rx warns outside a synced folder" sh -c "echo \"\$1\" | grep -q 'not synced'" _ "$OUT"

echo "-- rx nodes"
OUT="$(as_user "$H1" rx nodes --json 2>&1)"
if command -v python3 >/dev/null 2>&1; then
  check "rx nodes --json is valid JSON with 2 nodes" python3 -c "import json,sys; d=json.loads(sys.argv[1]); assert len(d)==2 and all(n['reachable'] for n in d) and d[0]['hardware']['cpus_effective']==8 and d[0]['load']['mem_available_mb']==20000 and d[0]['hostname']=='stub' and d[0]['hardware']['windows']['pending'][0]['id']=='reboot' and d[0]['load']['windows_commit_free_gb']==30.0 and len(d[0]['sync'])==1" "$OUT"
else
  check "rx nodes --json mentions both nodes" sh -c "echo \"\$1\" | grep -q '\"name\":\"gpu2\"'" _ "$OUT"
fi
OUT="$(as_user "$H1" rx nodes 2>&1)"; echo "$OUT" | sed 's/^/    | /'
check "rx nodes table shows pending Windows steps" sh -c "echo \"\$1\" | grep -q '1 PENDING STEP'" _ "$OUT"
check "rx nodes table lists sync sessions" sh -c "echo \"\$1\" | grep -q 'sync $P: Watching'" _ "$OUT"

echo "-- cnode remove"
as_user "$H1" cnode remove gpu2 >/dev/null 2>&1
check "removed from registry" sh -c "! grep -q '^gpu2 ' '$H1/.config/compute-node/nodes'"
check "removed from ssh_config" sh -c "! grep -q 'cn-gpu2' '$H1/.config/compute-node/ssh_config'"
check "host key removed" sh -c "! grep -q '^cn-gpu2 ' '$H1/.config/compute-node/known_hosts'"

echo "-- migration from the original single-node setup"
H2="$(new_home home2)"; mkdir -p "$H2/.ssh" "$H2/.claude" "$H2/.local/bin"
cat >"$H2/.ssh/config" <<EOF
Host github.com
    User git

# BEGIN wsl-compute
Host wsl
    HostName legacy.example.test
    Port 2222
    User carol
    ControlMaster auto
# END wsl-compute
EOF
echo "[legacy.example.test]:2222 $HOSTPUB" >"$H2/.ssh/known_hosts"
printf '#!/bin/sh\necho old rx\n' >"$H2/.local/bin/rx"
printf 'my notes\n\n<!-- BEGIN wsl-compute -->\nold rules\n<!-- END wsl-compute -->\n' >"$H2/.claude/CLAUDE.md"
as_user "$H2" bash "$REPO/install.sh" control --no-install </dev/null >/dev/null 2>&1; rc=$?
check "migration run exits 0" test "$rc" = 0
check "legacy block removed" sh -c "! grep -q 'BEGIN wsl-compute' '$H2/.ssh/config'"
check "other hosts kept" grep -qx "Host github.com" "$H2/.ssh/config"
check "legacy node migrated as 'wsl'" grep -qx "wsl legacy.example.test carol 2222" "$H2/.config/compute-node/nodes"
check "host key taken from ~/.ssh/known_hosts (already trusted)" grep -q "^cn-wsl ssh-ed25519" "$H2/.config/compute-node/known_hosts"
check "old rx replaced by the symlink" test "$(readlink "$H2/.local/bin/rx")" = cnode
check "old rules block replaced, own notes kept" sh -c "grep -q 'my notes' '$H2/.claude/CLAUDE.md' && ! grep -q 'old rules' '$H2/.claude/CLAUDE.md' && grep -q 'BEGIN compute-node' '$H2/.claude/CLAUDE.md'"
LP="$H2/legacyproj"; mkdir -p "$LP"
SID_LEGACY="wsl-$(echo "$LP" | shasum | cut -c1-10)"   # how the original wsync named sessions
echo "$SID_LEGACY wsl $LP" >>"$STATE/sessions"; : >"$LOG"
(cd "$LP" && as_user "$H2" rx true) >/dev/null 2>&1
check "sessions made by the original wsync are still found by rx" grep -q "^mutagen sync flush $SID_LEGACY$" "$LOG"
before="$(snapshot "$H2")"
as_user "$H2" bash "$REPO/install.sh" control --no-install </dev/null >/dev/null 2>&1
check "migrated HOME unchanged on re-run" test "$before" = "$(snapshot "$H2")"
echo "-- agent rules: on by default, AGENTS.md when ~/.codex exists, --no-agent-rules skips"
H3="$(new_home home3)"; mkdir -p "$H3/.codex"
as_user "$H3" bash "$REPO/install.sh" control --no-install --lang zh-CN </dev/null >/dev/null 2>&1
check "CLAUDE.md written by default" grep -q '^<!-- BEGIN compute-node -->$' "$H3/.claude/CLAUDE.md"
check "~/.codex/AGENTS.md written because ~/.codex exists" grep -q '^<!-- BEGIN compute-node -->$' "$H3/.codex/AGENTS.md"
check "--lang zh-CN" grep -q '远程算力节点' "$H3/.claude/CLAUDE.md"
check "rules: query rx nodes --json, hardware, memory headroom" sh -c "grep -q 'rx nodes --json' '$H1/.claude/CLAUDE.md' && grep -q 'cpu_model' '$H1/.claude/CLAUDE.md' && grep -q 'headroom' '$H1/.claude/CLAUDE.md' && grep -q 'Never assume a node is idle' '$H1/.claude/CLAUDE.md'"
check "exactly one rules block after re-runs" test "$(grep -c '^<!-- BEGIN compute-node -->$' "$H1/.claude/CLAUDE.md")" = 1
H4="$(new_home home4)"
as_user "$H4" bash "$REPO/install.sh" control --no-install --no-agent-rules </dev/null >/dev/null 2>&1
check "--no-agent-rules writes no CLAUDE.md" test ! -e "$H4/.claude/CLAUDE.md"
check "control --help works" sh -c "bash '$REPO/install.sh' control --help | grep -q -- '--no-agent-rules'"
finish
