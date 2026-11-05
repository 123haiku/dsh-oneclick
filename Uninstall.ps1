#Requires -Version 5.1
<#
.SYNOPSIS
    Undo Install.ps1: revert patches, restore app.asar, unwire the profile.

.PARAMETER KeepFiles
    Leave the plugin and injection file in place; only revert the patch set.

.EXAMPLE
    .\Uninstall.ps1
    .\Uninstall.ps1 -KeepFiles
#>
[CmdletBinding()]
param(
    [string]$DshHome,
    [switch]$KeepFiles
)

$ErrorActionPreference = 'Stop'
if (-not $DshHome) {
    $DshHome = if ($env:DSH_HOME) { $env:DSH_HOME } else { Join-Path $env:USERPROFILE '.dsh' }
}

function Say([string]$m, [string]$c = 'Gray') { Write-Host $m -ForegroundColor $c }

Get-Process -Name 'DeepSeek Harness' -ErrorAction SilentlyContinue | Stop-Process -Force
Start-Sleep -Seconds 3

# the guard would re-apply everything we are about to remove
$task = Get-ScheduledTask -TaskName 'DSH-Purge-Guard' -ErrorAction SilentlyContinue
if ($task) {
    Unregister-ScheduledTask -TaskName 'DSH-Purge-Guard' -Confirm:$false
    Say 'removed update guard task'
}

$installRoot = Join-Path $env:LOCALAPPDATA 'Programs\DeepSeek Harness'
$node = $null
foreach ($rel in @(
        'resources\runtime\primary-runtime\dependencies\node\bin\node.exe',
        'resources\runtime\primary-runtime\node.exe'
    )) {
    $c = Join-Path $installRoot $rel
    if (Test-Path $c) { $node = $c; break }
}

$cli = Join-Path $DshHome 'plugins\dsh-purge\bin\dsh-purge.js'
if ($node -and (Test-Path $cli)) {
    $env:DSH_HOME = $DshHome
    Say '-- revert patch set --'
    & $node $cli --revert
}

$asar = Join-Path $installRoot 'resources\app.asar'
$backup = "$asar.dshpurge-backup"
if (-not (Test-Path $asar) -and (Test-Path $backup)) {
    Say 'restore app.asar'
    Move-Item $backup $asar -Force
}

$pkgPath = Join-Path $DshHome 'profiles\desktop\package.json'
if ((Test-Path $pkgPath) -and -not $KeepFiles) {
    $pkg = Get-Content $pkgPath -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($pkg.dependencies.PSObject.Properties.Name -contains 'dsh-purge') {
        $pkg.dependencies.PSObject.Properties.Remove('dsh-purge')
    }
    $pkg.dsh.profile.bundles = @($pkg.dsh.profile.bundles | Where-Object { $_ -ne 'dsh-purge' })
    $pkg | ConvertTo-Json -Depth 10 | Set-Content $pkgPath -Encoding UTF8
    Say 'unwired profile'
}

if (-not $KeepFiles) {
    Remove-Item (Join-Path $DshHome 'plugins\dsh-purge') -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item (Join-Path $DshHome 'profiles\desktop\node_modules\dsh-purge') -Recurse -Force -ErrorAction SilentlyContinue
    Say 'removed plugin copies (prompt-inject.md left in place)'
}

Say 'start DSH again to confirm stock behavior' 'Green'
