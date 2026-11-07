# compute-node: turn this Windows PC into a compute node (WSL2 + sshd + Docker + GPU).
#
# Run in an ELEVATED PowerShell (Run as administrator):
#   irm <raw-url>/install.ps1 | iex
# With options:
#   & ([scriptblock]::Create((irm <raw-url>/install.ps1))) -Distro Debian -User alice
# From a clone:
#   powershell -ExecutionPolicy Bypass -File .\install.ps1 [-Options]
#
# Options:
#   -Distro NAME        WSL distro to use (default: an installed Debian/Ubuntu one, else installs Debian)
#   -User NAME          Linux account control nodes log in as (default: the distro's user, else your Windows name)
#   -SshPort N          sshd port inside WSL (default 2222)
#   -MemoryGB N         WSL memory cap (default: 75% of RAM)
#   -SyncRoot DIR       mirrored path root(s) inside WSL (default /Users, for macOS control nodes)
#   -AuthorizeKey KEY   control-node public key(s) to authorize right away
#   -NoDocker           skip Docker Engine and the NVIDIA Container Toolkit
#   -AllowLanPassword   also accept SSH passwords from private/Tailscale ranges (default: keys only)
#   -InstallTailscale   install Tailscale with winget if it is missing
#   -SkipWslConfig -SkipPower -SkipTask -SkipFirewall   leave those parts alone
#   -ResetTask          re-create the boot task (e.g. after changing your Windows password)
#
# Safe to re-run. Kept ASCII-only on purpose: Windows PowerShell 5.1 misreads BOM-less UTF-8.
[CmdletBinding()]
param(
  [string]$Distro = '',
  [string]$User = '',
  [int]$SshPort = 2222,
  [int]$MemoryGB = 0,
  [string[]]$SyncRoot = @('/Users'),
  [string[]]$AuthorizeKey = @(),
  [switch]$NoDocker,
  [switch]$AllowLanPassword,
  [switch]$InstallTailscale,
  [switch]$SkipWslConfig,
  [switch]$SkipPower,
  [switch]$SkipTask,
  [switch]$SkipFirewall,
  [switch]$ResetTask,
  [string]$RawUrl = ''
)

$CnRawUrlDefault = '<raw-url>'   # e.g. https://raw.githubusercontent.com/<owner>/<repo>/main
$TaskName = 'WSL Compute Node'
$WslVmCreatorId = '{40E0AC32-46A5-438A-A0B2-2B479E8F2E90}'   # Hyper-V firewall id of the WSL VM
$ErrorActionPreference = 'Stop'
$env:WSL_UTF8 = '1'   # newer WSL: print UTF-8 instead of UTF-16

function Say([string]$m) { Write-Host ''; Write-Host "==> $m" }
function Note([string]$m) { Write-Host "    $m" }

function Invoke-Wsl {
  # run wsl.exe, return its output as clean strings (older WSL prints UTF-16 with NULs)
  # (Windows PowerShell 5.1 turns redirected native stderr into errors; do not let 'Stop' abort on them)
  $ErrorActionPreference = 'Continue'
  $out = & wsl.exe @args 2>&1
  $script:WslExit = $LASTEXITCODE
  @($out | ForEach-Object { ("$_" -replace "`0", '').TrimEnd() } | Where-Object { $_ -ne '' })
}

function Get-WslDistros {
  @(Invoke-Wsl -l -q | ForEach-Object { $_.Trim() } | Where-Object { $_ -and $_ -notlike 'docker-desktop*' })
}

function Test-DebianLike([string]$name) {
  # no double quotes inside: PowerShell 5.1 does not escape them for native commands
  $r = Invoke-Wsl -d $name -u root -e sh -c '. /etc/os-release; echo $ID $ID_LIKE'
  return ($script:WslExit -eq 0 -and (" $r " -match ' (debian|ubuntu) '))
}

function Set-IniValue([System.Collections.Generic.List[string]]$lines, [string]$section, [string]$key, [string]$value) {
  # set key=value inside [section]; returns $true if anything changed
  $start = -1
  for ($i = 0; $i -lt $lines.Count; $i++) { if ($lines[$i].Trim() -ieq "[$section]") { $start = $i; break } }
  if ($start -lt 0) {
    if ($lines.Count -gt 0 -and $lines[$lines.Count - 1].Trim() -ne '') { $lines.Add('') }
    $lines.Add("[$section]"); $lines.Add("$key=$value"); return $true
  }
  $end = $lines.Count
  for ($i = $start + 1; $i -lt $lines.Count; $i++) { if ($lines[$i].Trim().StartsWith('[')) { $end = $i; break } }
  for ($i = $start + 1; $i -lt $end; $i++) {
    if ($lines[$i] -match "^\s*$([regex]::Escape($key))\s*=") {
      if ($lines[$i].Trim() -eq "$key=$value") { return $false }
      $lines[$i] = "$key=$value"; return $true
    }
  }
  $at = $end
  while ($at -gt $start + 1 -and $lines[$at - 1].Trim() -eq '') { $at-- }
  $lines.Insert($at, "$key=$value"); return $true
}

# ---------------------------------------------------------------------------------------
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
  [Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) { throw 'Run this in an elevated PowerShell (right-click > Run as administrator).' }
if (-not $RawUrl) { $RawUrl = if ($env:CN_RAW_URL) { $env:CN_RAW_URL } else { $CnRawUrlDefault } }

$build = [int](Get-CimInstance Win32_OperatingSystem).BuildNumber
if (-not $SkipWslConfig -and $build -lt 22621) {
  throw "Windows build ${build}: mirrored WSL networking needs Windows 11 22H2 (build 22621) or newer. Update Windows, or re-run with -SkipWslConfig and expose sshd yourself (netsh portproxy)."
}

Say 'WSL2'
$vmp = Get-WindowsOptionalFeature -Online -FeatureName VirtualMachinePlatform
if ($vmp.State -ne 'Enabled') {
  Note 'enabling WSL (Virtual Machine Platform + WSL)...'
  & wsl.exe --install --no-distribution
  Write-Host ''
  Write-Host '!! WSL was just enabled. REBOOT Windows, then run this same command again.'
  return
}
$null = Invoke-Wsl --version
if ($script:WslExit -ne 0) { Note 'updating to the current WSL release (wsl --update)'; & wsl.exe --update }
$ver = (Invoke-Wsl --version | Select-Object -First 1)
Note "$ver"

if ($InstallTailscale) {
  Say 'Tailscale'
  if (Get-Command tailscale.exe -ErrorAction SilentlyContinue) { Note 'already installed' }
  elseif (Get-Command winget.exe -ErrorAction SilentlyContinue) {
    & winget.exe install --id Tailscale.Tailscale -e --accept-source-agreements --accept-package-agreements
    Note 'log in from the tray icon, then enable "Run unattended" (see README)'
  } else { Write-Warning 'winget not found; install Tailscale from https://tailscale.com/download' }
}

$needShutdown = $false
if (-not $SkipWslConfig) {
  Say '.wslconfig (merged; other settings are kept)'
  if ($MemoryGB -le 0) {
    $totalGB = [math]::Floor((Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory / 1GB)
    $MemoryGB = [math]::Max(4, [math]::Floor($totalGB * 0.75))
  }
  $cfg = Join-Path $env:USERPROFILE '.wslconfig'
  $lines = New-Object 'System.Collections.Generic.List[string]'
  if (Test-Path $cfg) { foreach ($l in (Get-Content -Path $cfg)) { $lines.Add($l) } }
  $changed = $false
  # memory: cap for the WSL VM (it competes with Windows for RAM)
  if (Set-IniValue $lines 'wsl2' 'memory' "${MemoryGB}GB") { $changed = $true }
  # mirrored: WSL shares the Windows network interfaces, so <windows-ip>:2222 reaches sshd in WSL
  if (Set-IniValue $lines 'wsl2' 'networkingMode' 'mirrored') { $changed = $true }
  # never stop the VM when idle (otherwise sshd disappears after a few idle minutes)
  if (Set-IniValue $lines 'wsl2' 'vmIdleTimeout' '-1') { $changed = $true }
  # hand freed page cache back to Windows gradually
  if (Set-IniValue $lines 'experimental' 'autoMemoryReclaim' 'gradual') { $changed = $true }
  if ($changed) {
    if (Test-Path $cfg) {
      $bak = "$cfg.bak-$(Get-Date -Format yyyyMMdd-HHmmss)"; Copy-Item $cfg $bak; Note "backup: $bak"
    }
    Set-Content -Path $cfg -Value $lines -Encoding ASCII
    Note "written: $cfg (memory=${MemoryGB}GB, mirrored networking)"
    $needShutdown = $true
  } else { Note 'unchanged' }
}

Say 'Distro'
$have = Get-WslDistros
if (-not $Distro) {
  $default = ''
  try {
    $lxss = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Lxss'
    $guid = (Get-ItemProperty $lxss -ErrorAction Stop).DefaultDistribution
    if ($guid) { $default = (Get-ItemProperty (Join-Path $lxss $guid)).DistributionName }
  } catch { }
  $cands = @($have | Where-Object { Test-DebianLike $_ })
  if ($default -and ($cands -contains $default)) { $Distro = $default }
  elseif ($cands.Count -gt 0) { $Distro = $cands[0] }
  else { $Distro = 'Debian' }
}
if ($have -notcontains $Distro) {
  Note "installing $Distro (wsl --install -d $Distro --no-launch)"
  & wsl.exe --install -d $Distro --no-launch
  if (-not ((Get-WslDistros) -contains $Distro)) {
    # older store-packaged distros register only on first launch; do that with root as default user
    $launcher = (($Distro -replace '[^A-Za-z0-9]', '').ToLower()) + '.exe'
    if (Get-Command $launcher -ErrorAction SilentlyContinue) { & $launcher install --root }
  }
  if (-not ((Get-WslDistros) -contains $Distro)) {
    throw "Could not register '$Distro'. Start it once from the Start menu (create the user), then re-run."
  }
}
if (-not (Test-DebianLike $Distro)) { throw "'$Distro' is not Debian/Ubuntu based (see: wsl -l -v)." }
Note "using $Distro"

if (-not $User) {
  $u = (Invoke-Wsl -d $Distro -e id -un | Select-Object -First 1)
  if ($u -and $u -ne 'root') { $User = $u }
  else {
    $User = ($env:USERNAME.ToLower() -replace '[^a-z0-9_-]', '')
    if ($User -notmatch '^[a-z]') { $User = 'dev' + $User }
  }
}
Note "Linux user: $User"

if ($needShutdown) {
  Say 'Restarting WSL so .wslconfig takes effect (wsl --shutdown stops all running distros)'
  & wsl.exe --shutdown
}

Say "Compute-node setup inside $Distro"
$srcWin = ''
if ($PSScriptRoot -and (Test-Path (Join-Path $PSScriptRoot 'scripts\node-setup.sh'))) {
  $srcWin = $PSScriptRoot
} else {
  if ($RawUrl -like '*<raw-url>*') { throw 'No download URL in this copy; pass -RawUrl https://raw.githubusercontent.com/<owner>/<repo>/main' }
  $srcWin = Join-Path $env:TEMP ('compute-node-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
  foreach ($f in @('install.sh', 'scripts/node-setup.sh', 'node/cn-status', 'node/cn-authorize')) {
    $dst = Join-Path $srcWin ($f -replace '/', '\')
    New-Item -ItemType Directory -Force -Path (Split-Path $dst) | Out-Null
    Invoke-WebRequest -UseBasicParsing -Uri "$RawUrl/$f" -OutFile $dst
  }
}
$srcLinux = (Invoke-Wsl -d $Distro -u root -e wslpath -a -u $srcWin | Select-Object -First 1)
$env:CN_RAW_URL = $RawUrl
if (-not ($env:WSLENV -split ':' | Where-Object { $_ -like 'CN_RAW_URL*' })) {
  $env:WSLENV = (@($env:WSLENV, 'CN_RAW_URL/u') | Where-Object { $_ }) -join ':'
}
$setupArgs = @('-d', $Distro, '-u', 'root', '-e', 'bash', "$srcLinux/install.sh", 'node',
  '--user', $User, '--create-user', '--port', "$SshPort", '--wsl', 'yes')
foreach ($r in $SyncRoot) { $setupArgs += @('--sync-root', $r) }
foreach ($k in $AuthorizeKey) { $setupArgs += @('--authorize', $k) }
if ($NoDocker) { $setupArgs += '--no-docker' }
if ($AllowLanPassword) { $setupArgs += '--allow-lan-password' }
$rc = 0
for ($try = 1; $try -le 3; $try++) {
  & wsl.exe @setupArgs
  $rc = $LASTEXITCODE
  if ($rc -ne 10) { break }
  Note "systemd enabled; restarting $Distro and continuing"
  & wsl.exe --terminate $Distro
}
if ($rc -ne 0) { throw "In-WSL setup failed (exit $rc). Fix the error above and re-run." }

if (-not $SkipFirewall) {
  Say "Hyper-V firewall: allow inbound TCP $SshPort to WSL"
  $ruleName = "WSL-SSH-$SshPort"
  try {
    $rule = Get-NetFirewallHyperVRule -Name $ruleName -ErrorAction SilentlyContinue
    if ($rule) { Note "rule $ruleName exists" }
    else {
      New-NetFirewallHyperVRule -Name $ruleName -DisplayName "WSL sshd $SshPort" -Direction Inbound `
        -VMCreatorId $WslVmCreatorId -Protocol TCP -LocalPorts $SshPort -Action Allow | Out-Null
      Note "created $ruleName"
    }
  } catch { Write-Warning "Hyper-V firewall cmdlets unavailable ($($_.Exception.Message)); allow TCP $SshPort manually." }
  # To expose another WSL port directly (e.g. 8888), add a rule like the one above.
}

if (-not $SkipPower) {
  Say 'Power: never sleep or hibernate on AC power'
  & powercfg.exe /change standby-timeout-ac 0
  & powercfg.exe /change hibernate-timeout-ac 0
}

if (-not $SkipTask) {
  Say "Scheduled task '$TaskName': start $Distro at boot, without logging in"
  $taskArgs = "-d $Distro --exec /bin/sleep infinity"
  $existing = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
  if ($existing -and -not $ResetTask -and $existing.Actions.Count -ge 1 -and $existing.Actions[0].Arguments -eq $taskArgs) {
    Note 'exists (use -ResetTask after a Windows password change)'
  } else {
    $acct = "$env:USERDOMAIN\$env:USERNAME"
    Note "account: $acct"
    Note 'Enter the Windows account PASSWORD (not the PIN; for a Microsoft account, its password).'
    $sec = Read-Host -AsSecureString 'Password'
    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec)
    $plain = [Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr)
    [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
    if ([string]::IsNullOrEmpty($plain)) { throw 'Empty password, aborting.' }
    $action = New-ScheduledTaskAction -Execute "$env:SystemRoot\System32\wsl.exe" -Argument $taskArgs
    $trigger = New-ScheduledTaskTrigger -AtStartup
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
      -ExecutionTimeLimit ([TimeSpan]::Zero) -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1)
    Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Settings $settings `
      -User $acct -Password $plain -RunLevel Limited -Force | Out-Null
    $plain = $null
    Note 'registered'
  }
  Start-ScheduledTask -TaskName $TaskName
  Note 'started'
}

# ---------------------------------------------------------------------------------------
$fp = (Invoke-Wsl -d $Distro -u root -e ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub | Select-Object -First 1)
$fp = ($fp -split '\s+')[1]
$hostName = ''
if (Get-Command tailscale.exe -ErrorAction SilentlyContinue) {
  try { $hostName = ((& tailscale.exe status --json | Out-String | ConvertFrom-Json).Self.DNSName).TrimEnd('.') } catch { }
}
if (-not $hostName) {
  try {
    $ifx = (Get-NetRoute -DestinationPrefix '0.0.0.0/0' | Sort-Object RouteMetric | Select-Object -First 1).InterfaceIndex
    $hostName = (Get-NetIPAddress -AddressFamily IPv4 -InterfaceIndex $ifx | Select-Object -First 1).IPAddress
  } catch { $hostName = '<host>' }
}
Write-Host ''
Write-Host 'Compute node ready.'
Write-Host "  join: host=$hostName user=$User port=$SshPort fingerprint=$fp"
Write-Host ''
Write-Host 'On each control node (first time: the full installer; later: cnode add):'
Write-Host "  curl -fsSL $RawUrl/install.sh | bash -s -- control --name <name> --host $hostName --user $User --port $SshPort --fingerprint $fp"
Write-Host "  cnode add <name> --host $hostName --user $User --port $SshPort --fingerprint $fp"
Write-Host "Then authorize it here:  wsl -d $Distro -u $User -- <the line printed by: cnode key>"
Write-Host '  (or re-run this script with -AuthorizeKey "<public key>")'
