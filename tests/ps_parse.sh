#!/usr/bin/env bash
# shellcheck disable=SC2016,SC2001  # test snippets are single-quoted on purpose
# Parse-only check of install.ps1 (never executed): the PowerShell parser must report no errors,
# and the param() block must expose the documented options. Uses, in order: powershell.exe or
# pwsh on PATH, or Windows PowerShell on a WSL host over SSH (CN_TEST_PS_SSH=<ssh host>; WSL
# interop is not set up in SSH sessions, so the script points WSL_INTEROP at a running socket).
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
. tests/lib.sh
# The parser program (script text arrives on stdin, so no file is written on Windows).
read -r -d '' PROG <<'PS'
$s = [Console]::In.ReadToEnd()
$t = $null; $e = $null
$ast = [System.Management.Automation.Language.Parser]::ParseInput($s, [ref]$t, [ref]$e)
if ($e.Count -gt 0) { $e | ForEach-Object { 'ERROR {0}:{1} {2}' -f $_.Extent.StartLineNumber, $_.Extent.StartColumnNumber, $_.Message }; exit 1 }
$p = $ast.ParamBlock.Parameters | ForEach-Object { $_.Name.VariablePath.UserPath }
'PSVERSION ' + $PSVersionTable.PSVersion.ToString()
'PARAMS ' + ($p -join ',')
'TOKENS ' + $t.Count
PS
ENC="$(printf '%s' "$PROG" | iconv -f UTF-8 -t UTF-16LE | base64 | tr -d '\n')"
if command -v powershell.exe >/dev/null 2>&1; then runner=(powershell.exe -NoProfile -NonInteractive -EncodedCommand "$ENC")
elif command -v pwsh >/dev/null 2>&1; then runner=(pwsh -NoProfile -NonInteractive -EncodedCommand "$ENC")
elif [ -n "${CN_TEST_PS_SSH:-}" ]; then
  runner=(ssh -o BatchMode=yes "$CN_TEST_PS_SSH" "WSL_INTEROP=\$(ls -1 /run/WSL/*_interop 2>/dev/null | head -n1) /mnt/c/Windows/System32/WindowsPowerShell/v1.0/powershell.exe -NoProfile -NonInteractive -EncodedCommand $ENC")
else
  echo "  no PowerShell found (set CN_TEST_PS_SSH=<wsl ssh host> or install pwsh): skipping"; exit 77
fi
OUT="$("${runner[@]}" <install.ps1 2>&1 | tr -d '\r')"; rc=$?
echo "$OUT" | sed 's/^/    | /'
check "parser reports no errors" test "$rc" = 0
check "ran on a real PowerShell" sh -c 'echo "$1" | grep -q "^PSVERSION "' _ "$OUT"
for p in Distro User SshPort MemoryGB SyncRoot AuthorizeKey NoDocker AllowLanPassword InstallTailscale SkipWslConfig SkipPower SkipTask SkipFirewall ResetTask RawUrl; do
  check "param -$p" sh -c 'echo "$1" | grep "^PARAMS " | tr "," "\n" | grep -qx "\(PARAMS \)\{0,1\}$2"' _ "$OUT" "$p"
done

# The .wslconfig merge helper, exercised under pwsh in a Linux container (nothing touches Windows).
if command -v docker >/dev/null 2>&1 && [ -z "${CN_TEST_NO_DOCKER:-}" ]; then
  ( mem_gate >/dev/null ) && {
    U="$(tar -cf - install.ps1 tests/ps_unit.ps1 | docker run --rm -i "${PWSH_IMAGE:-mcr.microsoft.com/powershell:latest}" \
          sh -c 'mkdir -p /src && tar -x -C /src && pwsh -NoProfile -NonInteractive -File /src/tests/ps_unit.ps1' 2>&1)"; urc=$?
    echo "$U" | sed 's/^/    | /'
    check ".wslconfig merge unit tests (pwsh)" test "$urc" = 0
  }
fi
finish
