#Requires -Version 5.1
<#
.SYNOPSIS
    One-click installer: unattended prompt-layer + code-layer patch for DSH desktop.

.DESCRIPTION
    Everything a fresh machine needs, in one pass, no global toolchain:

      1. close DSH
      2. stage the plugin into ~/.dsh/plugins and the desktop profile
      3. wire the profile (dependency + bundle entry)
      4. install the prompt injection file
      5. run the plugin CLI with the Node runtime that ships inside DSH
      6. move app.asar aside so the host loads the patched tree
      7. snapshot the drift baseline
      8. restart DSH

    Payload is vendored under .\payload, so this works offline.

.PARAMETER DshHome
    Override DSH_HOME. Default: %USERPROFILE%\.dsh

.PARAMETER NoRestart
    Skip the final restart (the session you launch it from stays alive).

.PARAMETER DryRun
    Stage and wire only. No --apply, no asar move, no restart.

.EXAMPLE
    .\Install.ps1
    .\Install.ps1 -DryRun
    .\Install.ps1 -NoRestart
#>
[CmdletBinding()]
param(
    [string]$DshHome,
    [switch]$NoRestart,
    [switch]$DryRun,
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
$started = Get-Date
$log = Join-Path $env:TEMP ("dsh-oneclick-" + $started.ToString('yyyyMMdd-HHmmss') + '.log')

function Say([string]$msg, [string]$color = 'Gray') {
    $line = "{0}  {1}" -f (Get-Date -Format 'HH:mm:ss'), $msg
    Write-Host $line -ForegroundColor $color
    Add-Content -LiteralPath $log -Value $line -Encoding UTF8
}
function Step([string]$msg) { Say "== $msg" 'Cyan' }
function Fail([string]$msg) { Say "!! $msg" 'Red'; throw $msg }

if (-not $DshHome) {
    $DshHome = if ($env:DSH_HOME) { $env:DSH_HOME } else { Join-Path $env:USERPROFILE '.dsh' }
}
$root = Split-Path $PSCommandPath -Parent
$payload = Join-Path $root 'payload'
$pluginSrc = Join-Path $payload 'dsh-purge'
$injectSrc = Join-Path $payload 'prompt-inject.md'

Say "log: $log"
Say "DSH_HOME: $DshHome"
if ($DryRun) { Say 'DRY RUN: no apply, no asar move, no restart' 'Yellow' }

foreach ($p in @($pluginSrc, $injectSrc)) {
    if (-not (Test-Path $p)) { Fail "payload missing: $p" }
}

# ---------------------------------------------------------------- install root

function Get-InstallRoot {
    $c = Join-Path $env:LOCALAPPDATA 'Programs\DeepSeek Harness'
    if (Test-Path (Join-Path $c 'resources')) { return $c }
    $hit = Get-ChildItem (Join-Path $env:LOCALAPPDATA 'Programs') -Directory -ErrorAction SilentlyContinue |
        Where-Object Name -like '*Harness*' | Select-Object -First 1
    if ($hit) { return $hit.FullName }
    return $null
}

function Get-BundledNode([string]$InstallRoot) {
    foreach ($rel in @(
            'resources\runtime\primary-runtime\dependencies\node\bin\node.exe',
            'resources\runtime\primary-runtime\node.exe'
        )) {
        $c = Join-Path $InstallRoot $rel
        if (Test-Path $c) { return $c }
    }
    return $null
}

Step 'locate DSH'
$installRoot = Get-InstallRoot
if (-not $installRoot) { Fail 'DSH install not found under %LOCALAPPDATA%\Programs - install DSH first' }
$node = Get-BundledNode $installRoot
Say "install: $installRoot"
Say "node:    $(if ($node) { $node } else { 'MISSING (bundled runtime not found)' })"

$appJson = Join-Path $installRoot 'resources\app\package.json'
$version = if (Test-Path $appJson) { (Get-Content $appJson -Raw | ConvertFrom-Json).version } else { 'unknown' }
Say "version: $version"

# ---------------------------------------------------------------- close host

Step 'close DSH'
$procs = @(Get-Process -Name 'DeepSeek Harness' -ErrorAction SilentlyContinue)
if ($procs.Count -gt 0) {
    if ($DryRun) {
        Say "  $($procs.Count) process(es) running - left alone in dry run" 'Yellow'
    }
    else {
        $procs | Stop-Process -Force
        Start-Sleep -Seconds 3
        Say "  stopped $($procs.Count) process(es)"
    }
}
else { Say '  nothing running' }

# ---------------------------------------------------------------- stage plugin

Step 'stage plugin'
$pluginDir = Join-Path $DshHome 'plugins\dsh-purge'
New-Item -ItemType Directory -Force (Split-Path $pluginDir -Parent) | Out-Null
if (Test-Path $pluginDir) {
    $old = (Get-Content (Join-Path $pluginDir 'package.json') -Raw | ConvertFrom-Json).version
    Remove-Item $pluginDir -Recurse -Force
    Say "  replaced existing v$old"
}
Copy-Item $pluginSrc $pluginDir -Recurse -Force
Say "  plugin -> $pluginDir (v$((Get-Content (Join-Path $pluginDir 'package.json') -Raw | ConvertFrom-Json).version))"

# ---------------------------------------------------------------- wire profile

Step 'wire desktop profile'
$profileDir = Join-Path $DshHome 'profiles\desktop'
if (-not (Test-Path $profileDir)) { New-Item -ItemType Directory -Force $profileDir | Out-Null }
$pkgPath = Join-Path $profileDir 'package.json'
if (-not (Test-Path $pkgPath)) {
    @{
        name         = 'dsh-profile-desktop'
        private      = $true
        dependencies = @{}
        dsh          = @{ profile = @{ bundles = @('@deepseek-ai/dsh-base', '@deepseek-ai/dsh-web-app') } }
    } | ConvertTo-Json -Depth 8 | Set-Content $pkgPath -Encoding UTF8
    Say '  created package.json'
}
else {
    Copy-Item $pkgPath "$pkgPath.bak-$(Get-Date -Format 'yyyyMMdd-HHmmss')" -Force
}

$pkg = Get-Content $pkgPath -Raw -Encoding UTF8 | ConvertFrom-Json
if (-not $pkg.dependencies) {
    $pkg | Add-Member -NotePropertyName dependencies -NotePropertyValue ([pscustomobject]@{}) -Force
}
$pkg.dependencies | Add-Member -NotePropertyName 'dsh-purge' -NotePropertyValue 'file:../../plugins/dsh-purge' -Force

$bundles = @($pkg.dsh.profile.bundles)
if ($bundles -notcontains 'dsh-purge') { $bundles += 'dsh-purge' }
$pkg.dsh.profile.bundles = $bundles

$pkg | ConvertTo-Json -Depth 10 | Set-Content $pkgPath -Encoding UTF8
Say "  bundles: $($bundles -join ', ')"

# pnpm is hoisted in this profile; a real copy in node_modules is what the host loads
$linked = Join-Path $profileDir 'node_modules\dsh-purge'
if (-not (Test-Path $linked)) {
    New-Item -ItemType Directory -Force (Split-Path $linked -Parent) | Out-Null
    Copy-Item $pluginDir $linked -Recurse -Force
    Say '  copied into profile node_modules'
}
else { Say '  profile node_modules already linked' }

# ---------------------------------------------------------------- prompt layer

Step 'install prompt injection'
$injectDst = Join-Path $DshHome 'prompt-inject.md'
if ((Test-Path $injectDst) -and -not $Force) {
    $sz = (Get-Item $injectDst).Length
    Say "  kept existing ($sz bytes) - use -Force to overwrite"
}
else {
    if (Test-Path $injectDst) { Copy-Item $injectDst "$injectDst.bak-$(Get-Date -Format 'yyyyMMdd-HHmmss')" -Force }
    Copy-Item $injectSrc $injectDst -Force
    Say "  wrote $((Get-Item $injectDst).Length) bytes"
}

if ($DryRun) {
    Step 'dry run complete'
    Say 'staging + wiring done; nothing applied' 'Green'
    exit 0
}

# ---------------------------------------------------------------- apply

Step 'apply patch set'
if (-not $node) { Fail 'no bundled Node runtime; cannot run the plugin CLI' }
$cli = Join-Path $pluginDir 'bin\dsh-purge.js'
$env:DSH_HOME = $DshHome

& $node $cli --status 2>&1 | ForEach-Object { Say "  $_" }
& $node $cli --apply 2>&1 | ForEach-Object { Say "  $_" }
$code = $LASTEXITCODE
Say "  apply exit: $code"
if ($code -ne 0) { Say '  apply reported a non-zero exit; check the log above' 'Yellow' }

Step 'retire app.asar'
$asar = Join-Path $installRoot 'resources\app.asar'
$backup = "$asar.dshpurge-backup"
if (Test-Path $asar) {
    if (Test-Path $backup) {
        Say '  backup already exists; moving new asar to .dshpurge-prev' 'Yellow'
        Move-Item $asar "$asar.dshpurge-prev-$(Get-Date -Format 'yyyyMMdd-HHmmss')" -Force
    }
    else {
        Move-Item $asar $backup -Force
        Say "  app.asar -> $(Split-Path $backup -Leaf)"
    }
}
else { Say '  app.asar already retired' }

# ---------------------------------------------------------------- baseline

Step 'snapshot drift baseline'
$guard = 'C:\dev\tools\dsh-guard\dsh-guard.ps1'
if (Test-Path $guard) {
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $guard snapshot 2>&1 | ForEach-Object { Say "  $_" }
}
else { Say '  guard not installed; skipped (scripts\verify.ps1 in dsh-prompt-layer-notes covers it)' 'Yellow' }

# ---------------------------------------------------------------- restart

if ($NoRestart) {
    Say 'restart skipped (-NoRestart); start DSH manually' 'Yellow'
}
else {
    Step 'restart DSH'
    $exe = Join-Path $installRoot 'DeepSeek Harness.exe'
    if (Test-Path $exe) {
        Start-Process $exe
        Say '  launched'
    }
    else { Say "  exe not found: $exe" 'Yellow' }
}

Step 'done'
Say "patch baseline: $version"
Say 'verify inside a session: purge_status'
Say "log: $log" 'Green'
