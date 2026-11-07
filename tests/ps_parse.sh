#!/usr/bin/env bash
# shellcheck disable=SC2016,SC2001,SC2329,SC2086  # test snippets are single-quoted on purpose
# Parse-only check of the PowerShell that windows-setup.sh generates (facts query, UAC launcher,
# windows-admin.ps1). Nothing is executed on Windows: the parser reads the text and reports
# errors. Uses powershell.exe or pwsh on PATH, or Windows PowerShell on a WSL host over SSH
# (CN_TEST_PS_SSH=<ssh host>; WSL_INTEROP is pointed at a running socket, which SSH sessions lack).
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
. tests/lib.sh
W="$(mktemp -d "${TMPDIR:-/tmp}/cn-ps.XXXXXX")"; trap 'rm -rf "$W"' EXIT
bash scripts/windows-setup.sh --emit-ps "$W" || { bad "emit PowerShell texts"; finish; }
read -r -d '' PROG <<'PS'
$s = [Console]::In.ReadToEnd()
$t = $null; $e = $null
[void][System.Management.Automation.Language.Parser]::ParseInput($s, [ref]$t, [ref]$e)
if ($e.Count -gt 0) { $e | ForEach-Object { 'ERROR {0}:{1} {2}' -f $_.Extent.StartLineNumber, $_.Extent.StartColumnNumber, $_.Message }; exit 1 }
'OK PS ' + $PSVersionTable.PSVersion.ToString() + ', ' + $t.Count + ' tokens'
PS
ENC="$(printf '%s' "$PROG" | iconv -f UTF-8 -t UTF-16LE | base64 | tr -d '\n')"
if command -v powershell.exe >/dev/null 2>&1; then runner=(powershell.exe -NoProfile -NonInteractive -EncodedCommand "$ENC")
elif command -v pwsh >/dev/null 2>&1; then runner=(pwsh -NoProfile -NonInteractive -EncodedCommand "$ENC")
elif [ -n "${CN_TEST_PS_SSH:-}" ]; then
  runner=(ssh -o BatchMode=yes "$CN_TEST_PS_SSH" "WSL_INTEROP=\$(ls -1 /run/WSL/*_interop 2>/dev/null | head -n1) /mnt/c/Windows/System32/WindowsPowerShell/v1.0/powershell.exe -NoProfile -NonInteractive -EncodedCommand $ENC")
else
  echo "  no PowerShell found (set CN_TEST_PS_SSH=<wsl ssh host> or install pwsh): skipping"; exit 77
fi
# the live commit query cn-status runs on WSL nodes
sed -n "s/^ *'\(\$o = Get-CimInstance Win32_OperatingSystem.*\)' <\/dev\/null.*/\1/p" node/cn-status >"$W/cn-status-commit.ps1"
check "found the commit query in cn-status" test -s "$W/cn-status-commit.ps1"
for f in facts elevate windows-admin cn-status-commit; do
  check "$f.ps1 is ASCII-only (Windows PowerShell 5.1)" sh -c '[ "$(LC_ALL=C tr -d "\000-\177" <"$1" | wc -c | tr -d " ")" = 0 ]' _ "$W/$f.ps1"
  OUT="$("${runner[@]}" <"$W/$f.ps1" 2>&1 | tr -d '\r')"; rc=$?
  echo "$OUT" | sed "s/^/    | $f: /"
  check "$f.ps1 parses without errors" sh -c '[ "$1" = 0 ] && echo "$2" | grep -q "^OK PS "' _ "$rc" "$OUT"
done
check "windows-admin.ps1 registers the boot task like the original" sh -c 'grep -q "New-ScheduledTaskTrigger -AtStartup" "$1" && grep -q -- "--exec /bin/sleep infinity" "$1" && grep -q "RunLevel Limited" "$1"' _ "$W/windows-admin.ps1"
check "windows-admin.ps1 sets a fixed pagefile (initial = maximum)" grep -q 'InitialSize = \[uint32\]$PagefileMB; MaximumSize = \[uint32\]$PagefileMB' "$W/windows-admin.ps1"
check "windows-admin.ps1 turns off sleep and hibernate on AC only" sh -c 'grep -q "standby-timeout-ac 0" "$1" && grep -q "hibernate-timeout-ac 0" "$1" && ! grep -q "timeout-dc" "$1"' _ "$W/windows-admin.ps1"
check "facts.ps1 reads the AC sleep timeouts" grep -q "powercfg /query SCHEME_CURRENT SUB_SLEEP" "$W/facts.ps1"
check "the UAC launcher uses Start-Process -Verb RunAs and reports a decline" sh -c 'grep -q "Start-Process -FilePath powershell.exe -Verb RunAs" "$1" && grep -q "exit 99" "$1"' _ "$W/elevate.ps1"
check "no reboot and no wsl --shutdown in any generated script" sh -c '! grep -qiE "Restart-Computer|shutdown(\.exe)? /r|wsl(\.exe)? --shutdown" "$1"/*.ps1' _ "$W"
finish
