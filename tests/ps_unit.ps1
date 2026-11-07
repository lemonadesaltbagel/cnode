# Unit test of the pure .wslconfig merge helper from install.ps1, run under pwsh on Linux
# (tests/ps_parse.sh does this in a container). Only the Set-IniValue function is loaded from
# the script's AST; nothing else in install.ps1 runs.
param([string]$Path = '/src/install.ps1')
$ErrorActionPreference = 'Stop'
$t = $null; $e = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$t, [ref]$e)
$fn = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Set-IniValue' }, $true) | Select-Object -First 1
. ([scriptblock]::Create($fn.Extent.Text))
$fail = 0
function Apply([string[]]$start) {
  $l = New-Object 'System.Collections.Generic.List[string]'
  foreach ($x in $start) { $l.Add($x) }
  $c = @(
    (Set-IniValue $l 'wsl2' 'memory' '12GB'),
    (Set-IniValue $l 'wsl2' 'networkingMode' 'mirrored'),
    (Set-IniValue $l 'wsl2' 'vmIdleTimeout' '-1'),
    (Set-IniValue $l 'experimental' 'autoMemoryReclaim' 'gradual'))
  return @{ Lines = @($l); Changed = ($c -contains $true) }
}
function Expect([string]$name, [bool]$cond) {
  if ($cond) { Write-Output "ok   $name" } else { Write-Output "FAIL $name"; $script:fail++ }
}
$r = Apply @()
Expect 'empty file gets [wsl2] and [experimental]' (($r.Lines -join "`n") -eq "[wsl2]`nmemory=12GB`nnetworkingMode=mirrored`nvmIdleTimeout=-1`n`n[experimental]`nautoMemoryReclaim=gradual")
$r2 = Apply $r.Lines
Expect 'second merge changes nothing' (-not $r2.Changed -and (($r2.Lines -join "`n") -eq ($r.Lines -join "`n")))
$r = Apply @('[wsl2]', 'memory=24GB')
Expect 'original memory value is replaced, not duplicated' ((@($r.Lines | Where-Object { $_ -like 'memory=*' })).Count -eq 1 -and ($r.Lines -contains 'memory=12GB'))
$r = Apply @('# mine', '[wsl2]', 'processors=8', '', '[experimental]', 'sparseVhd=true', '', '[other]', 'x=1')
Expect 'unrelated keys and sections are kept' (($r.Lines -contains 'processors=8') -and ($r.Lines -contains 'sparseVhd=true') -and ($r.Lines -contains '[other]') -and ($r.Lines -contains '# mine'))
$i = [array]::IndexOf($r.Lines, '[other]'); $j = [array]::IndexOf($r.Lines, 'autoMemoryReclaim=gradual')
Expect 'new key goes into its own section' ($j -gt 0 -and $j -lt $i)
$r = Apply @('[WSL2]', 'networkingMode = NAT')
Expect 'section names case-insensitive; NAT switched to mirrored' (($r.Lines -contains 'networkingMode=mirrored') -and -not ($r.Lines -match 'NAT'))
if ($fail -gt 0) { exit 1 }
