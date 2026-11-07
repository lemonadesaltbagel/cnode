#!/usr/bin/env bash
# compute-node: Windows side of a WSL compute node, driven from inside the distro (run as root by
# node-setup.sh on WSL; uses WSL interop, never wsl --shutdown, never reboots).
#
#   --user NAME     the Linux user (for messages)
#   --port N        sshd port (Hyper-V firewall rule for mirrored networking)
#   --no-elevate    do not show a UAC prompt; record admin steps as pending instead
#   --wsl-memory GB override the computed WSL memory cap
#
# What it does:
#   1. reads RAM, pagefiles, commit limit, disks, the boot task and Windows' Tailscale (no admin)
#   2. merges %USERPROFILE%\.wslconfig (backup first): [wsl2] memory, swap, vmIdleTimeout=-1,
#      networkingMode=mirrored, [experimental] autoMemoryReclaim=gradual; an explicit memory= is kept
#   3. writes %USERPROFILE%\.cnode\windows-admin.ps1 (boot task, firewall rule, pagefile) and runs it
#      elevated (one UAC prompt) when an admin step is needed and someone is at the terminal
#   4. records facts in /etc/cnode/windows.json and windows.env, open steps in /etc/cnode/pending.json
# Test hooks: CN_POWERSHELL, CN_WSLPATH, CN_STATE_DIR.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=scripts/wincalc.sh
. "$HERE/wincalc.sh"

PORT=2222; ELEVATE=1; MEM_OVERRIDE=""; EMIT=""
while [ $# -gt 0 ]; do
  case "$1" in
    --user) shift 2 ;;   # (accepted for symmetry with node-setup)
    --port) PORT="${2:?}"; shift 2 ;;
    --no-elevate) ELEVATE=0; shift ;;
    --wsl-memory) MEM_OVERRIDE="${2:?}"; shift 2 ;;
    --emit-ps) EMIT="${2:?}"; shift 2 ;;   # tests only
    -h|--help) sed -n '2,/^set -euo/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "windows-setup: unknown option $1" >&2; exit 2 ;;
  esac
done
PS="${CN_POWERSHELL:-/mnt/c/Windows/System32/WindowsPowerShell/v1.0/powershell.exe}"
WSLPATH="${CN_WSLPATH:-wslpath}"
STATE="${CN_STATE_DIR:-/etc/cnode}"
TASK_NAME='WSL Compute Node'
note() { printf '    %s\n' "$*"; }
warn() { printf '!!  %s\n' "$*" >&2; }
js() { local s="$1"; s="${s//\\/\\\\}"; s="${s//\"/\\\"}"; s="${s//$'\t'/ }"; s="${s//$'\n'/ }"; printf '"%s"' "$s"; }
psq() { printf "'%s'" "${1//\'/\'\'}"; }   # PowerShell single-quoted literal
# shellcheck disable=SC2016
b() { if [ "$1" = 1 ]; then echo '$true'; else echo '$false'; fi; }

# Run a PowerShell snippet through interop; output with CRs removed. Under sudo or SSH the interop
# socket variable is often missing; point it at a live one.
ps_run() {
  local enc sock="${WSL_INTEROP:-}"
  [ -n "$sock" ] || sock="$(find /run/WSL -maxdepth 1 -name '*_interop' 2>/dev/null | sort | head -n1)"
  enc="$(printf '%s' "$1" | iconv -f UTF-8 -t UTF-16LE | base64 | tr -d '\n')"
  WSL_INTEROP="$sock" timeout "${2:-90}" "$PS" -NoProfile -NonInteractive -EncodedCommand "$enc" </dev/null 2>/dev/null | tr -d '\r'
}

write_unavailable() {
  warn "Windows interop is not available ($1); Windows-side steps skipped."
  printf '{"available":false,"warnings":[%s]}\n' "$(js "Windows interop unavailable: $1")" >"$STATE/windows.json"
  printf '[\n{"id":"windows-interop","title":"Enable WSL interop (or run the node install again from a WSL terminal)","run":"","needs":"interop"}\n]\n' >"$STATE/pending.json"
  printf 'WINDOWS_AVAILABLE=0\nWINDOWS_TAILSCALE=0\n' >"$STATE/windows.env"
  exit 0
}

# ------------------------------------------------------------------------- PowerShell texts
crlf() { awk '{ printf "%s\r\n", $0 }'; }
facts_ps() {   # read-only facts, no admin needed
  cat <<EOF
# cnode:facts
\$ErrorActionPreference = 'SilentlyContinue'
\$cs = Get-CimInstance Win32_ComputerSystem
\$os = Get-CimInstance Win32_OperatingSystem
'ram_bytes=' + \$cs.TotalPhysicalMemory
'pagefile_auto=' + \$cs.AutomaticManagedPagefile
'commit_limit_kb=' + \$os.TotalVirtualMemorySize
'commit_free_kb=' + \$os.FreeVirtualMemory
'os_caption=' + \$os.Caption + ' ' + \$os.BuildNumber
foreach (\$u in @(Get-CimInstance Win32_PageFileUsage)) { if (\$u) { 'pagefile_usage=' + \$u.Name + '|' + \$u.AllocatedBaseSize } }
foreach (\$s in @(Get-CimInstance Win32_PageFileSetting)) { if (\$s) { 'pagefile_setting=' + \$s.Name + '|' + \$s.InitialSize + '|' + \$s.MaximumSize } }
foreach (\$d in @(Get-CimInstance Win32_LogicalDisk -Filter 'DriveType=3')) { if (\$d) { 'disk=' + \$d.DeviceID + '|' + \$d.FreeSpace } }
'userprofile=' + \$env:USERPROFILE
'account=' + \$env:USERDOMAIN + '\\' + \$env:USERNAME
\$t = Get-ScheduledTask -TaskName '$TASK_NAME'
if (\$t) { 'task_args=' + \$t.Actions[0].Arguments }
\$svc = Get-Service -Name Tailscale
if (\$svc) { 'tailscale_service=' + \$svc.Status }
\$exe = Join-Path \$env:ProgramFiles 'Tailscale\\tailscale.exe'
if (Test-Path \$exe) { \$j = (& \$exe status --json | Out-String | ConvertFrom-Json); 'tailscale_state=' + \$j.BackendState; 'tailscale_dns=' + \$j.Self.DNSName }
\$fw = Get-NetFirewallHyperVRule -Name 'WSL-SSH-$PORT'
'firewall_rule=' + [bool]\$fw
EOF
}
elevate_ps() {   # one UAC prompt: run windows-admin.ps1 elevated, wait, pass its exit code back
  cat <<EOF
# cnode:elevate
try {
  \$p = Start-Process -FilePath powershell.exe -Verb RunAs -Wait -PassThru -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File','"$ADMIN_W"','-ResultPath','"$RESULT_W"')
  exit \$p.ExitCode
} catch { 'declined: ' + \$_.Exception.Message; exit 99 }
EOF
}
admin_ps() {   # the elevated steps; also saved on Windows so they can be run by hand
  cat <<EOF
# compute-node: Windows-side steps for the WSL compute node. Run in an ELEVATED PowerShell:
#   $ADMIN_CMD
# Generated by node-setup.sh. Safe to re-run. ASCII only (Windows PowerShell 5.1).
param(
  [string]\$ResultPath = '',
  [string]\$Distro = $(psq "$DISTRO"),
  [int]\$SshPort = $PORT,
  [string]\$Account = $(psq "$ACCOUNT"),
  [bool]\$DoTask = $(b "$NEED_TASK"),
  [bool]\$DoFirewall = $(b "$NEED_FW"),
  [bool]\$DoPagefile = $(b "$NEED_PF"),
  [string]\$PagefileName = $(psq "$PF_DRIVE\\pagefile.sys"),
  [int]\$PagefileMB = $((PF_SIZE * 1024))
)
\$ErrorActionPreference = 'Stop'
\$results = New-Object System.Collections.Generic.List[string]
\$principal = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
if (-not \$principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
  Write-Host 'Run this in an elevated PowerShell (Run as administrator).'; exit 2
}

if (\$DoTask) {
  # Boot task: start the distro at boot without logon; systemd in it starts sshd, Docker, Tailscale.
  try {
    \$taskArgs = "-d \$Distro --exec /bin/sleep infinity"
    \$existing = Get-ScheduledTask -TaskName '$TASK_NAME' -ErrorAction SilentlyContinue
    if (\$existing -and \$existing.Actions[0].Arguments -eq \$taskArgs) { \$results.Add('task=ok') }
    else {
      Write-Host "Boot task '$TASK_NAME' for \${Account}, starting \${Distro} at boot without logon."
      Write-Host 'Enter the Windows account PASSWORD (not the PIN; for a Microsoft account, its password).'
      \$sec = Read-Host -AsSecureString 'Password'
      \$bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR(\$sec)
      \$plain = [Runtime.InteropServices.Marshal]::PtrToStringAuto(\$bstr)
      [Runtime.InteropServices.Marshal]::ZeroFreeBSTR(\$bstr)
      if ([string]::IsNullOrEmpty(\$plain)) { throw 'empty password' }
      \$action = New-ScheduledTaskAction -Execute "\$env:SystemRoot\\System32\\wsl.exe" -Argument \$taskArgs
      \$trigger = New-ScheduledTaskTrigger -AtStartup
      \$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries \`
        -ExecutionTimeLimit ([TimeSpan]::Zero) -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1)
      Register-ScheduledTask -TaskName '$TASK_NAME' -Action \$action -Trigger \$trigger -Settings \$settings \`
        -User \$Account -Password \$plain -RunLevel Limited -Force | Out-Null
      \$plain = \$null
      \$results.Add('task=ok')
    }
  } catch { \$results.Add('task=fail ' + \$_.Exception.Message) }
}

if (\$DoFirewall) {
  # Mirrored networking: inbound traffic to WSL passes the Hyper-V firewall.
  try {
    \$name = "WSL-SSH-\$SshPort"
    if (-not (Get-NetFirewallHyperVRule -Name \$name -ErrorAction SilentlyContinue)) {
      New-NetFirewallHyperVRule -Name \$name -DisplayName "WSL sshd \$SshPort" -Direction Inbound \`
        -VMCreatorId '{40E0AC32-46A5-438A-A0B2-2B479E8F2E90}' -Protocol TCP -LocalPorts \$SshPort -Action Allow | Out-Null
    }
    \$results.Add('firewall=ok')
  } catch { \$results.Add('firewall=fail ' + \$_.Exception.Message) }
}

if (\$DoPagefile) {
  # Fixed-size pagefile (initial = maximum). Commit limit = RAM + pagefile. Needs a reboot.
  try {
    \$cs = Get-CimInstance Win32_ComputerSystem
    if (\$cs.AutomaticManagedPagefile) {
      Set-CimInstance -InputObject \$cs -Property @{ AutomaticManagedPagefile = \$false }
      # keep the system-managed pagefile on C: that was there (0/0 = system managed)
      if (\$PagefileName -notlike 'C:*' -and -not (Get-CimInstance Win32_PageFileSetting | Where-Object { \$_.Name -like 'C:*' })) {
        New-CimInstance -ClassName Win32_PageFileSetting -Property @{ Name = 'C:\\pagefile.sys' } | Out-Null
      }
    }
    \$pf = Get-CimInstance Win32_PageFileSetting | Where-Object { \$_.Name -ieq \$PagefileName }
    if (-not \$pf) { \$pf = New-CimInstance -ClassName Win32_PageFileSetting -Property @{ Name = \$PagefileName } }
    Set-CimInstance -InputObject \$pf -Property @{ InitialSize = [uint32]\$PagefileMB; MaximumSize = [uint32]\$PagefileMB }
    \$results.Add('pagefile=ok')
    Write-Host 'Pagefile set; it takes effect after a reboot (not done automatically).'
  } catch { \$results.Add('pagefile=fail ' + \$_.Exception.Message) }
}

if (\$ResultPath) { \$results | Set-Content -Path \$ResultPath -Encoding ASCII }
\$results | ForEach-Object { Write-Host \$_ }
Start-Sleep -Seconds 4
EOF
}

if [ -n "$EMIT" ]; then   # tests: write the PowerShell texts with sample values, run nothing
  DISTRO=Debian; ACCOUNT='PC\user'; NEED_TASK=1; NEED_FW=1; NEED_PF=1; PF_DRIVE=D:; PF_SIZE=55
  ADMIN_W='C:\Users\user\.cnode\windows-admin.ps1'; RESULT_W='C:\Users\user\.cnode\windows-admin.result'
  ADMIN_CMD="powershell -NoProfile -ExecutionPolicy Bypass -File \"$ADMIN_W\""
  mkdir -p "$EMIT"; facts_ps | crlf >"$EMIT/facts.ps1"; elevate_ps | crlf >"$EMIT/elevate.ps1"; admin_ps | crlf >"$EMIT/windows-admin.ps1"
  exit 0
fi
[ -x "$PS" ] || [ -f "$PS" ] || write_unavailable "no $PS"
install -d -m 0755 "$STATE"

# ---------------------------------------------------------------------------------------- facts
FACTS="$(ps_run "$(facts_ps)" 60 || true)"
fact() { printf '%s\n' "$FACTS" | sed -n "s/^$1=//p" | head -n1; }
facts() { printf '%s\n' "$FACTS" | sed -n "s/^$1=//p"; }
RAM_BYTES="$(fact ram_bytes)"
[ -n "$RAM_BYTES" ] || write_unavailable "PowerShell returned nothing"

RAM_GB="$(awk -v b="$RAM_BYTES" 'BEGIN{printf "%.1f", b/1073741824}')"
read -r M SWAP P <<<"$(cn_sizes "$RAM_GB")"
[ -n "$MEM_OVERRIDE" ] && M="$MEM_OVERRIDE" && SWAP=$(( (M + 3) / 4 )) && P=$(( ${RAM_GB%.*} + M ))
CL_GB="$(awk -v k="$(fact commit_limit_kb)" 'BEGIN{printf "%.1f", k/1048576}')"
CF_GB="$(awk -v k="$(fact commit_free_kb)" 'BEGIN{printf "%.1f", k/1048576}')"
PF_TOTAL_GB="$(facts pagefile_usage | awk -F'|' '{s+=$2} END{printf "%.1f", s/1024}')"
PF_AUTO="$(fact pagefile_auto)"
USERPROFILE_W="$(fact userprofile)"; ACCOUNT="$(fact account)"
DISTRO="$("$WSLPATH" -w / 2>/dev/null | tr -d '\r' | tr '\134' '/' | cut -d/ -f4)"   # \\wsl.localhost\<Distro>\
[ -n "$DISTRO" ] || DISTRO="${WSL_DISTRO_NAME:-}"
TS_WIN=0; [ "$(fact tailscale_service)" = Running ] && TS_WIN=1; [ "$(fact tailscale_state)" = Running ] && TS_WIN=1
TS_WIN_NAME="$(fact tailscale_dns)"; TS_WIN_NAME="${TS_WIN_NAME%.}"
WARN=()
note "Windows: $(fact os_caption), RAM ${RAM_GB} GB, pagefile ${PF_TOTAL_GB} GB$([ "$PF_AUTO" = True ] && echo ' (system-managed)'), commit limit ${CL_GB} GB (free ${CF_GB} GB)"
note "recommended: WSL memory ${M} GB, swap ${SWAP} GB, pagefile ${P} GB (commit limit about $(awk -v r="$RAM_GB" -v p="$P" 'BEGIN{printf "%.0f", r+p}') GB)"

# --------------------------------------------------------------------------------- .wslconfig
WSLCONFIG=""; WSLCONFIG_CHANGED=0; MEM_SET="${M}GB"
if [ -n "$USERPROFILE_W" ] && UP_L="$("$WSLPATH" -u "$USERPROFILE_W" 2>/dev/null)" && [ -d "$UP_L" ]; then
  WSLCONFIG="$UP_L/.wslconfig"
  existing="$(cn_ini_get "$WSLCONFIG" wsl2 memory)"
  if [ -n "$existing" ]; then
    MEM_SET="$existing"
    eg="$(cn_size_gb "$existing")"
    if [ -n "$eg" ] && [ "$eg" -gt "$M" ]; then
      WARN+=("wsl2.memory=$existing in .wslconfig is above the recommended ${M} GB for ${RAM_GB} GB RAM; Windows can run out of commit memory under load")
      warn "${WARN[-1]}"
    fi
  fi
  res="$(cn_wslconfig_merge "$WSLCONFIG" 1 "wsl2.memory=${M}GB" "wsl2.swap=${SWAP}GB" wsl2.vmIdleTimeout=-1 \
          wsl2.networkingMode=mirrored experimental.autoMemoryReclaim=gradual)"
  case "$res" in
    changed*) WSLCONFIG_CHANGED=1; note "merged $WSLCONFIG (takes effect after wsl --shutdown)"; [ -n "${res#changed }" ] && note "backup: ${res#changed }" ;;
    *) note ".wslconfig already has the recommended settings" ;;
  esac
else
  WARN+=("could not locate %USERPROFILE%\\.wslconfig"); warn "${WARN[-1]}"
fi
# applied? WSL's MemTotal equals the memory= cap once the VM was restarted with it
MEM_SET_GB="$(cn_size_gb "$MEM_SET")"
memtot_gb="$(awk '/^MemTotal:/{printf "%d", $2/1048576 + 0.5}' /proc/meminfo)"
WSL_APPLIED=0
if [ "$WSLCONFIG_CHANGED" = 0 ] && [ -n "$MEM_SET_GB" ] && [ "$memtot_gb" -ge $((MEM_SET_GB - 1)) ] && [ "$memtot_gb" -le $((MEM_SET_GB + 1)) ]; then WSL_APPLIED=1; fi

# ------------------------------------------------------------------------------ admin steps
TASK_ARGS="-d $DISTRO --exec /bin/sleep infinity"
NEED_TASK=0; [ "$(fact task_args)" = "$TASK_ARGS" ] || NEED_TASK=1
[ -n "$DISTRO" ] || { NEED_TASK=0; WARN+=("could not tell the WSL distro name; boot task skipped"); }
NEED_FW=0; [ "$(fact firewall_rule)" = True ] || NEED_FW=1
NEED_PF=0; PF_DRIVE="-"; PF_SIZE=0; PF_CAPPED=0
if awk -v t="$PF_TOTAL_GB" -v p="$P" 'BEGIN{exit !(t + 0.5 < p)}'; then
  disks=()
  while IFS='|' read -r dev free; do
    [ -n "$dev" ] && disks+=("$dev $(awk -v b="$free" 'BEGIN{printf "%d", b/1073741824}')")
  done < <(facts disk)
  read -r PF_DRIVE PF_SIZE PF_CAPPED <<<"$(cn_pagefile_plan "$P" ${disks[@]+"${disks[@]}"})"
  if [ "$PF_CAPPED" = 1 ]; then
    WARN+=("NOT ENOUGH DISK for the recommended ${P} GB pagefile (largest free: ${PF_DRIVE}); using ${PF_SIZE} GB. Free up disk space or lower wsl2.memory, or the machine can crash under memory load")
    warn "${WARN[-1]}"
  fi
  [ "$PF_SIZE" -gt 0 ] && NEED_PF=1
fi
if awk -v c="$CL_GB" -v r="$RAM_GB" -v p="$P" 'BEGIN{exit !(c + 1 < r + p)}'; then
  WARN+=("Windows commit limit ${CL_GB} GB is below the recommended $(awk -v r="$RAM_GB" -v p="$P" 'BEGIN{printf "%.0f", r+p}') GB (RAM + pagefile)")
fi

CN_DIR_W="$USERPROFILE_W\\.cnode"; CN_DIR_L="${UP_L:-}/.cnode"
ADMIN_W="$CN_DIR_W\\windows-admin.ps1"; RESULT_W="$CN_DIR_W\\windows-admin.result"
ADMIN_CMD="powershell -NoProfile -ExecutionPolicy Bypass -File \"$ADMIN_W\""
TASK_DONE=0; FW_DONE=0; PF_DONE=0; ELEVATED="not needed"
if [ $((NEED_TASK + NEED_FW + NEED_PF)) -gt 0 ] && [ -n "${UP_L:-}" ]; then
  install -d "$CN_DIR_L"
  # The script is kept on Windows so the same step can be run by hand later (see pending.json).
  admin_ps | crlf >"$CN_DIR_L/windows-admin.ps1"
  note "admin steps saved to $ADMIN_W"
  if [ "$ELEVATE" = 1 ] && (exec </dev/tty) 2>/dev/null; then
    note "asking Windows for administrator rights (a UAC prompt on the Windows desktop; a password prompt for the boot task follows)"
    rm -f "$CN_DIR_L/windows-admin.result"
    if out="$(ps_run "$(elevate_ps)" 900)"; then ELEVATED="ran"; else ELEVATED="declined or failed${out:+: $out}"; fi
    if [ -f "$CN_DIR_L/windows-admin.result" ]; then
      r="$(tr -d '\r' <"$CN_DIR_L/windows-admin.result")"
      grep -qx 'task=ok' <<<"$r" && TASK_DONE=1
      grep -qx 'firewall=ok' <<<"$r" && FW_DONE=1
      grep -qx 'pagefile=ok' <<<"$r" && PF_DONE=1
      while IFS= read -r l; do case "$l" in *=fail*) warn "Windows: $l" ;; esac; done <<<"$r"
    fi
    note "elevated step: $ELEVATED"
  else
    ELEVATED="skipped ($([ "$ELEVATE" = 0 ] && echo '--no-elevate' || echo 'no terminal'))"
  fi
fi

# ---------------------------------------------------------------------------- state files
P_ITEMS=()
padd() { P_ITEMS+=("{\"id\":$(js "$1"),\"title\":$(js "$2"),\"run\":$(js "$3"),\"needs\":$(js "$4")}"); }
if [ "$NEED_TASK" = 1 ] && [ "$TASK_DONE" = 0 ]; then
  padd autostart "Register the boot task that starts the WSL distro without logon" "$ADMIN_CMD   (elevated PowerShell)" admin
fi
if [ "$NEED_FW" = 1 ] && [ "$FW_DONE" = 0 ]; then
  padd firewall "Allow inbound TCP $PORT to WSL in the Hyper-V firewall (mirrored networking)" "$ADMIN_CMD   (elevated PowerShell)" admin
fi
if [ "$NEED_PF" = 1 ] && [ "$PF_DONE" = 0 ]; then
  padd pagefile "Set a fixed ${PF_SIZE} GB pagefile on ${PF_DRIVE} (commit limit RAM + pagefile), then reboot" "$ADMIN_CMD   (elevated PowerShell), then reboot Windows" admin+reboot
fi
if [ "$PF_DONE" = 1 ]; then
  padd reboot "Reboot Windows so the new pagefile takes effect" "Restart Windows when convenient" reboot
fi
if [ "$WSL_APPLIED" = 0 ] && [ -n "$WSLCONFIG" ]; then
  padd wsl-restart "Restart WSL so .wslconfig (memory ${MEM_SET}, swap ${SWAP}GB, mirrored networking) takes effect" \
    "wsl --shutdown   (in Windows, when nothing is running in WSL; then start the distro again or run the boot task)" wsl-shutdown
fi
{ echo '['; for i in "${!P_ITEMS[@]}"; do printf '%s%s\n' "${P_ITEMS[$i]}" "$([ "$i" -lt $((${#P_ITEMS[@]} - 1)) ] && echo ,)"; done; echo ']'; } >"$STATE/pending.json"

wj=""; for w in ${WARN[@]+"${WARN[@]}"}; do wj="${wj:+$wj,}$(js "$w")"; done
pf_list=""; while IFS='|' read -r n a; do [ -n "$n" ] && pf_list="${pf_list:+$pf_list,}{\"name\":$(js "$n"),\"allocated_gb\":$(awk -v a="$a" 'BEGIN{printf "%.1f", a/1024}')}"; done < <(facts pagefile_usage)
autostart="registered"; [ "$NEED_TASK" = 1 ] && [ "$TASK_DONE" = 0 ] && autostart="pending"
printf '%s\n' "{\"available\":true,\"os\":$(js "$(fact os_caption)"),\"ram_gb\":$RAM_GB,\"pagefile_total_gb\":$PF_TOTAL_GB,\"pagefile_system_managed\":$([ "$PF_AUTO" = True ] && echo true || echo false),\"pagefiles\":[$pf_list],\"commit_limit_gb_at_install\":$CL_GB,\"recommended\":{\"wsl_memory_gb\":$M,\"wsl_swap_gb\":$SWAP,\"pagefile_gb\":$P,\"pagefile_drive\":$(js "$PF_DRIVE"),\"commit_limit_gb\":$(awk -v r="$RAM_GB" -v p="$P" 'BEGIN{printf "%.1f", r+p}')},\"wslconfig\":{\"path\":$(js "${USERPROFILE_W}\\.wslconfig"),\"memory\":$(js "$MEM_SET"),\"swap\":$(js "${SWAP}GB"),\"vmIdleTimeout\":\"-1\",\"networkingMode\":\"mirrored\",\"autoMemoryReclaim\":\"gradual\"},\"autostart\":$(js "$autostart"),\"tailscale_on_windows\":$([ "$TS_WIN" = 1 ] && echo true || echo false),\"admin_script\":$(js "$ADMIN_W"),\"warnings\":[$wj]}" >"$STATE/windows.json"
cat >"$STATE/windows.env" <<EOF
WINDOWS_AVAILABLE=1
WINDOWS_TAILSCALE=$TS_WIN
WINDOWS_TS_NAME=$TS_WIN_NAME
POWERSHELL=$PS
RAM_GB=$RAM_GB
PAGEFILE_GB=$P
WSL_MEMORY_GB=${MEM_SET_GB:-$M}
EOF
chmod 0644 "$STATE"/windows.json "$STATE"/windows.env "$STATE"/pending.json
note "state: $STATE/windows.json, $STATE/pending.json (${#P_ITEMS[@]} pending)"
exit 0
