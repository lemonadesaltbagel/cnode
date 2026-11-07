#!/usr/bin/env bash
# shellcheck disable=SC2016,SC2088,SC2001  # test snippets are single-quoted on purpose
# Fleet logic on this machine, no Docker and no network: two throwaway HOMEs (admin and member)
# with real ssh-keygen; gh is a stub that emulates the GitHub contents API on a directory (raw
# GET, PUT with sha, DELETE, listings, repo view/create); ssh, ssh-keyscan, systemctl, crontab and
# docker are stubs. Covers init/join/approve/revoke/renew/leave, CA pinning, signature and
# rollback checks, malformed registry entries, the generated ssh_config and the background sync.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
REPO="$(pwd)"
. tests/lib.sh
command -v python3 >/dev/null 2>&1 || { echo "  python3 needed for the gh stub: skipping"; exit 77; }
W="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/cn-fleet-test.XXXXXX")" && pwd -P)"
trap 'rm -rf "$W"' EXIT
STUBS="$W/stubs"; GHROOT="$W/github"; STATE="$W/state"; mkdir -p "$STUBS" "$GHROOT" "$STATE"

cat >"$STUBS/gh" <<'EOF'
#!/usr/bin/env python3
# Minimal GitHub CLI stand-in: repositories are directories under $GHROOT.
import base64, hashlib, json, os, sys
root = os.environ["GHROOT"]; a = sys.argv[1:]
def out(s): sys.stdout.write(s)
def nf():
    out('{"message":"Not Found","status":"404"}'); sys.stderr.write("gh: Not Found (HTTP 404)\n"); sys.exit(1)
def sha(p): return hashlib.sha1(open(p, "rb").read()).hexdigest()
if a[:2] == ["auth", "status"]: sys.exit(0)
if a[:2] == ["repo", "view"]:
    d = os.path.join(root, a[2])
    if not os.path.isdir(d): sys.stderr.write("GraphQL: Could not resolve to a Repository\n"); sys.exit(1)
    out(open(os.path.join(d, ".visibility")).read().strip() + "\n"); sys.exit(0)
if a[:2] == ["repo", "create"]:
    d = os.path.join(root, a[2]); os.makedirs(d)
    open(os.path.join(d, ".visibility"), "w").write("PRIVATE" if "--private" in a else "PUBLIC"); sys.exit(0)
if a[0] != "api": sys.exit(2)
method, raw, jq, fields, inp, path = "GET", False, None, {}, False, None
i = 1
while i < len(a):
    x = a[i]
    if x == "-X": method = a[i + 1]; i += 2
    elif x == "-H": raw = "raw" in a[i + 1]; i += 2
    elif x == "--jq": jq = a[i + 1]; i += 2
    elif x == "-f": k, v = a[i + 1].split("=", 1); fields[k] = v; i += 2
    elif x == "--input": inp = True; i += 2
    else: path = x; i += 1
parts = path.split("/")            # repos/OWNER/REPO/contents/...
repo = os.path.join(root, parts[1], parts[2]); rel = "/".join(parts[4:])
if not os.path.isdir(repo): nf()
f = os.path.join(repo, rel)
if method == "GET":
    if os.path.isdir(f) and jq:
        for n in sorted(os.listdir(f)):
            if os.path.isfile(os.path.join(f, n)): out(n + "\n")
        sys.exit(0)
    if not os.path.isfile(f): nf()
    if jq == ".sha": out(sha(f) + "\n")
    elif raw: sys.stdout.buffer.write(open(f, "rb").read())
    else: out(json.dumps({"sha": sha(f)}))
    sys.exit(0)
if method == "PUT":
    body = json.load(sys.stdin)
    if os.path.isfile(f) and body.get("sha") != sha(f):
        sys.stderr.write("gh: sha wasn't supplied or does not match (HTTP 409)\n"); sys.exit(1)
    os.makedirs(os.path.dirname(f), exist_ok=True)
    open(f, "wb").write(base64.b64decode(body["content"]))
    open(os.path.join(repo, ".log"), "a").write(body["message"] + "\n"); sys.exit(0)
if method == "DELETE":
    if not os.path.isfile(f): nf()
    if fields.get("sha") != sha(f): sys.stderr.write("gh: sha does not match (HTTP 409)\n"); sys.exit(1)
    os.remove(f); sys.exit(0)
sys.exit(2)
EOF
chmod +x "$STUBS/gh"
# ssh: -O exit succeeds; a push (cat > inbox) stores what it got per alias; anything else fails
cat >"$STUBS/ssh" <<EOF
#!/usr/bin/env bash
echo "ssh \$*" >>"$STATE/ssh.log"
case "\$*" in
  *"-O exit"*) exit 0 ;;
  *registry.signed*) for a in "\$@"; do case "\$a" in cn-*) cat >"$STATE/inbox-\$a"; exit 0 ;; esac; done ;;
esac
exit 255
EOF
printf '#!/bin/sh\nexit 1\n' >"$STUBS/ssh-keyscan"
printf '#!/bin/sh\n# no systemd --user here\nexit 1\n' >"$STUBS/systemctl"
cat >"$STUBS/crontab" <<EOF
#!/bin/sh
if [ "\$1" = -l ]; then cat "$STATE/crontab" 2>/dev/null || exit 1; else cat >"$STATE/crontab"; fi
EOF
chmod +x "$STUBS"/*

home() { local h="$W/$1"; mkdir -p "$h/.ssh"; ssh-keygen -q -t ed25519 -N '' -f "$h/.ssh/id_ed25519" -C "$1@test"; echo "$h"; }
# asu HOME cmd...: run as that throwaway user (clean environment, stubs first on PATH); a script, so
# that the sh -c snippets of check can use it too
mkdir -p "$W/bin"
cat >"$W/bin/asu" <<EOF
#!/usr/bin/env bash
h="\$1"; shift
exec env -i HOME="\$h" PATH="$STUBS:/usr/bin:/bin:/usr/sbin:/sbin" GHROOT="$GHROOT" TMPDIR="$W" LANG=C CN_NO_DOCKER=1 \\
  \${NO_TIMER:+CN_NO_TIMER=1} "\$@" </dev/null
EOF
chmod +x "$W/bin/asu"; export PATH="$W/bin:$PATH"
CN="$REPO/bin/cnode"
A="$(home admin)"; M="$(home member)"; FA="$A/.config/compute-node/fleet"; FM="$M/.config/compute-node/fleet"
STORE="$GHROOT/alice/cnode-fleet"

echo "-- admin: cnode fleet init (GitHub store through gh)"
OUT="$(NO_TIMER=1 asu "$A" bash "$CN" fleet init alice/cnode-fleet --name laptop1 --no-passphrase 2>&1)"; rc=$?
echo "$OUT" | sed 's/^/    | /' | head -n 12
check "init exits 0" test "$rc" = 0
check "private repository created" grep -qx PRIVATE "$STORE/.visibility"
check "CA key kept on the admin only (mode 600)" sh -c '[ "$(stat -c %a "$1/ca" 2>/dev/null || stat -f %Lp "$1/ca")" = 600 ] && [ ! -e "$2/ca" ]' _ "$FA" "$STORE"
check "store has ca.pub, registry.signed, README and the admin's certificate" sh -c 'for f in ca.pub registry.signed README.md certs/laptop1-cert.pub; do [ -f "$1/$f" ] || exit 1; done' _ "$STORE"
check "registry serial 1 lists the admin as control node" sh -c 'grep -qx "serial 1" "$1/registry" && grep -q "^control laptop1 ssh-ed25519 " "$1/registry"' _ "$FA"
check "admin's user certificate: principal cnode, no agent forwarding" sh -c 'i="$(ssh-keygen -L -f "$1/id-cert.pub")"; echo "$i" | grep -qx "[[:space:]]*cnode" && ! echo "$i" | grep -q permit-agent-forwarding && echo "$i" | grep -q permit-pty' _ "$FA"
CAFP="$(ssh-keygen -lf "$FA/ca.pub" | awk '{print $2}')"
check "init prints the join commands with the CA fingerprint" sh -c 'echo "$1" | grep -q -- "control --fleet alice/cnode-fleet --fleet-ca $2" && echo "$1" | grep -q -- "node --key-only --fleet-ca '"'"'ssh-ed25519 "' _ "$OUT" "$CAFP"
check "init refuses a second fleet in the same store" sh -c '! asu "$1" bash "$2" fleet init alice/cnode-fleet --no-passphrase' _ "$M" "$CN"
mkdir -p "$GHROOT/alice/pub"; echo PUBLIC >"$GHROOT/alice/pub/.visibility"
check "init refuses a public repository" sh -c 'asu "$1" bash "$2" fleet init alice/pub --no-passphrase 2>&1 | grep -q "keep it in a private repository"' _ "$M" "$CN"
rm -rf "$FM"

echo "-- member: join (CA pinned), approve"
check "join with a wrong --ca is refused" sh -c '! asu "$1" bash "$2" fleet join alice/cnode-fleet --ca SHA256:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA' _ "$M" "$CN"
OUT="$(NO_TIMER=1 asu "$M" bash "$CN" fleet join alice/cnode-fleet --ca "$CAFP" --name laptop2 2>&1)"; rc=$?
echo "$OUT" | sed 's/^/    | /' | tail -n 3
check "join exits 0 and names the approve command" sh -c '[ "$2" = 0 ] && echo "$1" | grep -q "cnode fleet approve laptop2"' _ "$OUT" "$rc"
check "join request in the store" test -f "$STORE/requests/laptop2.pub"
check "member pinned the CA and has the registry" sh -c '[ "$(ssh-keygen -lf "$1/ca.pub" | awk "{print \$2}")" = "$2" ] && grep -qx "serial 1" "$1/registry"' _ "$FM" "$CAFP"
check "member status: waiting for approval" sh -c 'asu "$1" bash "$2" fleet status | grep -q "waiting for approval"' _ "$M" "$CN"
check "member cannot approve (no CA)" sh -c '! asu "$1" bash "$2" fleet approve laptop2' _ "$M" "$CN"
check "admin status lists the pending request" sh -c 'asu "$1" bash "$2" fleet status | grep -q "pending join requests: laptop2"' _ "$A" "$CN"
check "approve without a name and without a terminal approves nothing" sh -c 'asu "$1" bash "$2" fleet approve | grep -q "not approved" && [ -f "$3/requests/laptop2.pub" ]' _ "$A" "$CN" "$STORE"
OUT="$(asu "$A" bash "$CN" fleet approve laptop2 2>&1)"; rc=$?
echo "$OUT" | sed 's/^/    | /' | tail -n 3
check "approve laptop2" test "$rc" = 0
check "certificate in the store, request gone, registry serial 2" sh -c '[ -f "$1/certs/laptop2-cert.pub" ] && [ ! -e "$1/requests/laptop2.pub" ] && grep -qx "serial 2" "$2/registry"' _ "$STORE" "$FA"
asu "$M" bash "$CN" fleet sync >/dev/null 2>&1
check "member sync: certificate for its own key installed" sh -c 'ssh-keygen -L -f "$1/id-cert.pub" | grep -q "cnode-control:laptop2"' _ "$FM"
check "member status: certificate valid" sh -c 'asu "$1" bash "$2" fleet status | grep -q "certificate valid until"' _ "$M" "$CN"

echo "-- registry with nodes (signed here with the CA, as add-node would)"
publish() { # publish SERIAL RECORDS... -> the store's registry.signed
  local t="$W/pub"; rm -rf "$t"; mkdir -p "$t"
  { echo "cnode-fleet-registry 1"; echo "serial $1"; echo "updated 2026-01-01T00:00:00Z"; shift; printf '%s\n' "$@"; } >"$t/body"
  ssh-keygen -q -Y sign -f "$FA/ca" -n cnode-fleet "$t/body" </dev/null && cat "$t/body" "$t/body.sig" >"$STORE/registry.signed"
}
ssh-keygen -q -t ed25519 -N '' -f "$W/hk1" -C h1; HK1="$(cut -d' ' -f1,2 "$W/hk1.pub")"
CTLS="$(grep '^control ' "$FA/registry")"
publish 3 "$CTLS" "node gpu1 gpu1.example.ts.net dev 2222 $HK1" "node evil evil.example;ProxyCommand=touch_x dev 2222 $HK1" "node bad2 h.example dev 99999 $HK1"
OUT="$(asu "$M" bash "$CN" fleet sync 2>&1)"
echo "$OUT" | sed 's/^/    | /'
check "member: gpu1 joined" sh -c 'echo "$1" | grep -q "node .gpu1. joined"' _ "$OUT"
check "malformed entries (shell/ssh_config injection, bad port) skipped" sh -c '! grep -q evil "$1/nodes" && ! grep -q bad2 "$1/nodes" && ! grep -q ProxyCommand "$2/.config/compute-node/ssh_config"' _ "$FM" "$M"
check "cnode list marks gpu1 (fleet)" sh -c 'asu "$1" bash "$2" list | grep -q "gpu1 .*dev@gpu1.example.ts.net:2222  (fleet)"' _ "$M" "$CN"
SC="$M/.config/compute-node/ssh_config"
check "ssh_config: fleet known_hosts, revocation list, certificate" sh -c 'grep -q "UserKnownHostsFile \"$2/known_hosts\"" "$1" && grep -q "RevokedHostKeys \"$2/revoked.krl\"" "$1" && grep -q "CertificateFile \"$2/id-cert.pub\"" "$1"' _ "$SC" "$FM"
check "fleet known_hosts trusts only the fleet CA" sh -c '[ "$(cat "$1/known_hosts")" = "@cert-authority * $(cut -d" " -f1,2 "$1/ca.pub")" ]' _ "$FM"
check "registry pushed to gpu1's inbox (signed copy)" sh -c 'cmp -s "$1/inbox-cn-gpu1" "$2/registry.signed"' _ "$STATE" "$FM"
check "push recorded, second sync does not push again" sh -c 'grep -qx "gpu1 3" "$1/pushed" && n=$(grep -c "registry.signed" "$2/ssh.log"); asu "$3" bash "$4" fleet sync >/dev/null 2>&1; [ "$(grep -c "registry.signed" "$2/ssh.log")" = "$n" ]' _ "$FM" "$STATE" "$M" "$CN"
check "manual cnode add with a fleet name is refused" sh -c '! asu "$1" bash "$2" add gpu1 --host x --user y 2>/dev/null' _ "$M" "$CN"
check "cnode remove of a fleet node is refused" sh -c 'asu "$1" bash "$2" remove gpu1 2>&1 | grep -q "managed by the fleet"' _ "$M" "$CN"

echo "-- tampering and rollback"
cp "$STORE/registry.signed" "$W/good.signed"
sed 's/^serial 3$/serial 9/' "$W/good.signed" >"$STORE/registry.signed"
OUT="$(asu "$M" bash "$CN" fleet sync 2>&1)"
check "a tampered registry is refused" sh -c 'echo "$1" | grep -q "not signed by the fleet CA" && grep -qx "serial 3" "$2/registry"' _ "$OUT" "$FM"
ssh-keygen -q -t ed25519 -N '' -f "$W/rogue" -C rogue
( t="$W/rogue.d"; mkdir -p "$t"; printf 'cnode-fleet-registry 1\nserial 50\nnode x x.example dev 2222 %s\n' "$HK1" >"$t/body"
  ssh-keygen -q -Y sign -f "$W/rogue" -n cnode-fleet "$t/body" </dev/null; cat "$t/body" "$t/body.sig" >"$STORE/registry.signed" )
OUT="$(asu "$M" bash "$CN" fleet sync 2>&1)"
check "a registry signed by another key is refused" sh -c 'echo "$1" | grep -q "not signed by the fleet CA" && ! grep -q "^x " "$2/nodes"' _ "$OUT" "$FM"
cp "$W/good.signed" "$STORE/registry.signed"; asu "$A" bash "$CN" fleet sync >/dev/null 2>&1   # admin at serial 3 too
publish 2 "$CTLS"
OUT="$(asu "$M" bash "$CN" fleet sync 2>&1)"
check "an older serial is refused (rollback)" sh -c 'echo "$1" | grep -q "older registry" && grep -q "^gpu1 " "$2/nodes"' _ "$OUT" "$FM"
check "the admin refuses to change the fleet while the store holds an older registry" sh -c 'asu "$1" bash "$2" fleet approve 2>&1 | grep -q "not changing it"' _ "$A" "$CN"
cp "$W/good.signed" "$STORE/registry.signed"
asu "$A" bash "$CN" fleet sync >/dev/null 2>&1

echo "-- revoke, renew, re-join with the same name and a new key"
OUT="$(asu "$A" bash "$CN" fleet revoke laptop2 2>&1)"; rc=$?
echo "$OUT" | sed 's/^/    | /' | tail -n 3
check "revoke laptop2" test "$rc" = 0
check "registry: laptop2 gone, its key revoked, certificate deleted" sh -c '! grep -q "^control laptop2" "$1/registry" && grep -q "^revoke ssh-ed25519 .* control:laptop2$" "$1/registry" && [ ! -e "$2/certs/laptop2-cert.pub" ]' _ "$FA" "$STORE"
check "revocation delivered to gpu1's inbox" sh -c 'grep -q "control:laptop2" "$1/inbox-cn-gpu1"' _ "$STATE"
asu "$M" bash "$CN" fleet sync >/dev/null 2>&1
check "member status: REVOKED" sh -c 'asu "$1" bash "$2" fleet status | grep -q REVOKED' _ "$M" "$CN"
check "the revoked key cannot ask to join again" sh -c '! asu "$1" bash "$2" fleet join alice/cnode-fleet --ca "$3" --name laptop2 2>/dev/null' _ "$M" "$CN" "$CAFP"
check "renew: nothing expires within 30 days" sh -c 'asu "$1" bash "$2" fleet renew | grep -q "no certificate expires"' _ "$A" "$CN"
check "renew --within 400 re-signs the admin" sh -c 'asu "$1" bash "$2" fleet renew --within 400 | grep -q "renewed: laptop1"' _ "$A" "$CN"
ssh-keygen -q -t ed25519 -N '' -f "$M/.ssh/id_ed25519" -C member-newkey <<<y >/dev/null 2>&1
rm -f "$FM/id-cert.pub"
NO_TIMER=1 asu "$M" bash "$CN" fleet join alice/cnode-fleet --ca "$CAFP" --name laptop2 >/dev/null 2>&1
check "new key: join request again" test -f "$STORE/requests/laptop2.pub"
asu "$A" bash "$CN" fleet approve laptop2 >/dev/null 2>&1
check "approved again with the new key; the old key stays revoked" sh -c 'grep -q "^control laptop2 $(cut -d" " -f1,2 "$2/.ssh/id_ed25519.pub")$" "$1/registry" && grep -q "control:laptop2$" "$1/registry"' _ "$FA" "$M"

echo "-- background sync and leave"
OUT="$(asu "$M" bash "$CN" fleet join alice/cnode-fleet --name laptop2 2>&1)"
check "no systemd --user: falls back to cron, every minute" sh -c 'grep -q "fleet sync --quiet .*# cnode fleet sync$" "$1/crontab" && echo "$2" | grep -q "background sync: cron"' _ "$STATE" "$OUT"
check "re-join does not duplicate the cron line" sh -c '[ "$(grep -c "# cnode fleet sync" "$1/crontab")" = 1 ]' _ "$STATE"
check "admin cannot leave without --force (holds the CA)" sh -c '! asu "$1" bash "$2" fleet leave 2>/dev/null' _ "$A" "$CN"
check "member leaves: fleet state, nodes and cron line gone" sh -c 'asu "$1" bash "$2" fleet leave >/dev/null && [ ! -d "$3" ] && ! grep -q cnode "$4/crontab" && ! asu "$1" bash "$2" list | grep -q gpu1' _ "$M" "$CN" "$FM" "$STATE"
finish
