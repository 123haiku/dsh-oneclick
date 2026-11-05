#Requires -Version 5.1
<#
.SYNOPSIS
    Keeps the patch set applied across DSH updates.

.DESCRIPTION
    An official DSH update replaces resources\app and re-seals resources\app.asar. The
    plugin's own boot settle cannot repair that on the desktop surface, by design:

      config.autoApplyOnStart defaults to false        -> boot writes nothing at all
      settleMayReapply() returns false while sealed    -> "sealed desktop: skip startup reapply"

    So after every update the jailbreak silently falls back to stock until somebody clicks
    Apply. This script is that somebody, running outside the host where nothing holds the
    asar lock:

      1. detect drift   asar sealed / official-update marker / version bump / plugin or
                        prompt-inject missing / patch markers gone from the extracted tree
      2. stand down     skip while an installer or updater is running (never fight setup)
      3. heal           stop DSH -> node lib\reapply-cli.js -> retire asar -> start DSH
      4. record         state + log, with cooldown so a broken patch set cannot loop

    Heal fails closed: if the plugin cannot apply its patches to the new build, the asar is
    left intact and DSH keeps running stock. A half-patched tree is worse than stock.

.PARAMETER Detect
    Report drift and exit. Never stops, patches, or starts anything.

.PARAMETER Watch
    Loop until stopped instead of the single pass the scheduled task runs.

.PARAMETER DryRun
    Print the heal command instead of running it.

.PARAMETER NoRestart
    Heal, but leave DSH closed.

.EXAMPLE
    .\Guard.ps1 -Detect
    .\Guard.ps1
    .\Guard.ps1 -Watch -IntervalSeconds 45
    .\Guard.ps1 -DryRun
#>
[CmdletBinding()]
param(
    [string]$InstallDir,
    [string]$DshHome,
    [string]$PluginDir,
    [string]$LogPath,
    [switch]$Detect,
    [switch]$Watch,
    [switch]$DryRun,
    [switch]$NoRestart,
    [int]$IntervalSeconds = 45,
    [int]$CooldownMinutes = 10
)

$ErrorActionPreference = 'Stop'

if (-not $DshHome) {
    $DshHome = if ($env:DSH_HOME) { $env:DSH_HOME } else { Join-Path $env:USERPROFILE '.dsh' }
}
if (-not $PluginDir) { $PluginDir = Join-Path $DshHome 'plugins\dsh-purge' }

$stateRoot = Join-Path $env:LOCALAPPDATA 'dsh-oneclick'
if (-not $LogPath) { $LogPath = Join-Path $stateRoot 'guard.log' }
$statePath = Join-Path $stateRoot 'guard-state.json'
New-Item -ItemType Directory -Force $stateRoot | Out-Null

function Say([string]$msg) {
    $line = "{0}  {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $msg
    Add-Content -LiteralPath $LogPath -Value $line -Encoding UTF8 -ErrorAction SilentlyContinue
    if (-not $Watch) { Write-Host $line }
}

function Get-InstallRoot {
    if ($InstallDir) { return $InstallDir }
    $c = Join-Path $env:LOCALAPPDATA 'Programs\DeepSeek Harness'
    if (Test-Path (Join-Path $c 'resources')) { return $c }
    $hit = Get-ChildItem (Join-Path $env:LOCALAPPDATA 'Programs') -Directory -ErrorAction SilentlyContinue |
        Where-Object Name -like '*Harness*' | Select-Object -First 1
    if ($hit) { return $hit.FullName }
    return $null
}

function Get-BundledNode([string]$Root) {
    foreach ($rel in @(
            'resources\runtime\primary-runtime\dependencies\node\bin\node.exe',
            'resources\runtime\primary-runtime\node.exe'
        )) {
        $c = Join-Path $Root $rel
        if (Test-Path $c) { return $c }
    }
    $cmd = Get-Command node -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    return $null
}

function Get-HostVersion([string]$Root) {
    $p = Join-Path $Root 'resources\app\package.json'
    if (Test-Path $p) {
        try { return (Get-Content $p -Raw -Encoding UTF8 | ConvertFrom-Json).version } catch { }
    }
    $exe = Join-Path $Root 'DeepSeek Harness.exe'
    if (Test-Path $exe) { return (Get-Item $exe).VersionInfo.FileVersion }
    return 'unknown'
}

function Read-State {
    if (-not (Test-Path $statePath)) { return $null }
    try { return Get-Content $statePath -Raw -Encoding UTF8 | ConvertFrom-Json } catch { return null }
}

function Write-State([hashtable]$values) {
    $old = Read-State
    $obj = [ordered]@{}
    if ($old) {
        foreach ($p in $old.PSObject.Properties) { $obj[$p.Name] = $p.Value }
    }
    foreach ($k in $values.Keys) { $obj[$k] = $values[$k] }
    $obj['at'] = (Get-Date).ToString('o')
    ($obj | ConvertTo-Json -Depth 6) | Set-Content -LiteralPath $statePath -Encoding UTF8
}

# ---------------------------------------------------------------- detection

function Get-Drift([string]$root) {
    $reasons = New-Object System.Collections.Generic.List[string]
    if (-not $root) { $reasons.Add('install: DSH install root not found'); return $reasons }

    $res = Join-Path $root 'resources'
    if (Test-Path (Join-Path $res 'app.asar')) { $reasons.Add('sealed: resources\app.asar is back (official update ran)') }
    if (Test-Path (Join-Path $res 'dsh-purge-reapply-asar')) { $reasons.Add('marker: dsh-purge-reapply-asar pending') }

    if (-not (Test-Path $PluginDir)) {
        $reasons.Add("plugin: missing $PluginDir")
    }
    else {
        $pkg = Join-Path $PluginDir 'package.json'
        if (-not (Test-Path $pkg)) { $reasons.Add('plugin: package.json missing') }
    }

    if (-not (Test-Path (Join-Path $DshHome 'prompt-inject.md'))) {
        $reasons.Add('prompt: prompt-inject.md missing')
    }

    $linked = Join-Path $DshHome 'profiles\desktop\node_modules\dsh-purge'
    if (-not (Test-Path $linked)) { $reasons.Add('profile: dsh-purge not linked into desktop profile') }

    $aiBase = Join-Path $res 'app\dsh\node_modules\@deepseek-ai'
    if (Test-Path $aiBase) {
        $sp = Join-Path $aiBase 'dsh-system-prompt\lib\index.js'
        $marked = $false
        if (Test-Path $sp) {
            $text = Get-Content $sp -Raw -Encoding UTF8
            $marked = $text.Contains('[dsh-purge] identity stripped') -and
                      ($text.Contains('[dsh-purge] complete prompt keeps waterfall inject') -or
                       $text.Contains('[dsh-purge] complete prompt keeps inject'))
        }
        if (-not $marked) { $reasons.Add('code: patch markers missing in the extracted tree') }
    }
    else {
        $reasons.Add('code: extracted tree resources\app\dsh missing')
    }

    $state = Read-State
    $version = Get-HostVersion $root
    if ($state -and $state.hostVersion -and $state.hostVersion -ne $version) {
        $reasons.Add("version: host moved $($state.hostVersion) -> $version")
    }

    return $reasons
}

function Test-UpdateInFlight([string]$root) {
    # Another healer or the bundle installer already owns this install; two of them patching
    # at once is how a tree ends up half applied.
    $busyCmd = Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe' OR Name = 'node.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.ProcessId -ne $PID -and $_.CommandLine -match 'Install\.ps1|reapply-cli\.js|dsh-purge\.js' }
    if ($busyCmd) { return "another installer/reapply is running (pid $((($busyCmd | Select-Object -First 2).ProcessId) -join ','))" }

    # Narrow on purpose: a loose /update|setup/ match hits unrelated updaters (lghub_updater,
    # Edge, Discord's Update.exe) and would keep the guard standing down forever.
    $suspects = @(Get-Process -ErrorAction SilentlyContinue | Where-Object {
            $_.Name -eq 'msiexec' -or
            $_.Name -match '(?i)(^|[-_ ])setup' -or
            $_.Name -match '(?i)squirrel' -or
            ($_.Name -match '(?i)update' -and $_.Path -and
             ($_.Path -like "$root*" -or $_.Path -like (Join-Path $env:LOCALAPPDATA 'Programs\*')))
        })
    if ($suspects.Count -gt 0) {
        return "installer running: $((($suspects | Select-Object -First 3).Name) -join ', ')"
    }

    $asar = Join-Path $root 'resources\app.asar'
    if (Test-Path $asar) {
        $age = (Get-Date) - (Get-Item $asar).LastWriteTime
        if ($age.TotalSeconds -lt 90) { return "app.asar written $([int]$age.TotalSeconds)s ago (update still settling)" }
    }
    return $null
}

# ---------------------------------------------------------------- heal

function Invoke-Heal([string]$root, [string]$why) {
    $state = Read-State
    $version = Get-HostVersion $root
    $node = Get-BundledNode $root
    $cli = Join-Path $PluginDir 'lib\reapply-cli.js'

    if (-not $node) { Say "heal: no Node runtime; cannot run reapply"; return 1 }
    if (-not (Test-Path $cli)) { Say "heal: reapply CLI missing at $cli"; return 1 }

    if ($state -and $state.lastHealVersion -eq $version -and $state.lastHealAt) {
        $age = (Get-Date) - [datetime]$state.lastHealAt
        if ($age.TotalMinutes -lt $CooldownMinutes -and $state.lastHealOk -eq $false) {
            Say "heal: cooldown ($([int]$age.TotalMinutes)m < ${CooldownMinutes}m), last attempt on v$version failed"
            return 4
        }
    }

    Say "heal: drift on v$version -> $why"

    if ($DryRun) {
        Say "heal(dry): stop 'DeepSeek Harness'; `"$node`" `"$cli`" ; retire asar if still present ; start exe"
        return 0
    }

    $procs = @(Get-Process -Name 'DeepSeek Harness' -ErrorAction SilentlyContinue)
    if ($procs.Count -gt 0) {
        $procs | Stop-Process -Force
        Start-Sleep -Seconds 3
        Say "heal: stopped $($procs.Count) process(es)"
    }

    $env:DSH_HOME = $DshHome
    $out = & $node $cli 2>&1
    $code = $LASTEXITCODE
    $json = $null
    foreach ($line in $out) {
        $t = "$line".Trim()
        if ($t.StartsWith('{')) { try { $json = $t | ConvertFrom-Json } catch { } }
        Say "  reapply: $t"
    }
    Say "heal: reapply exit $code ok=$($json.ok) renamed=$($json.renamed) needsFullQuit=$($json.needsFullQuit)"

    $ok = ($code -eq 0) -and ($json -and $json.ok)
    if (-not $ok) {
        Write-State @{ lastHealAt = (Get-Date).ToString('o'); lastHealVersion = $version; lastHealOk = $false; lastHealWhy = $why }
        Say 'heal: FAILED closed - asar left intact, host stays stock; update the payload for this DSH build'
        return 1
    }

    $asar = Join-Path $root 'resources\app.asar'
    if (Test-Path $asar) {
        $backup = "$asar.dshpurge-backup"
        if (Test-Path $backup) {
            $prev = "$asar.dshpurge-prev-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
            Move-Item $asar $prev -Force
            Say "heal: asar -> $(Split-Path $prev -Leaf)"
        }
        else {
            Move-Item $asar $backup -Force
            Say 'heal: asar -> app.asar.dshpurge-backup'
        }
    }

    Write-State @{
        lastHealAt      = (Get-Date).ToString('o')
        lastHealVersion = $version
        lastHealOk      = $true
        lastHealWhy     = $why
        hostVersion     = $version
    }

    if ($NoRestart) { Say 'heal: restart skipped (-NoRestart)'; return 0 }
    if ($json.needsFullQuit -eq $true -and $json.renamed -eq $true) { Say 'heal: reapply already scheduled the restart'; return 0 }

    $exe = Join-Path $root 'DeepSeek Harness.exe'
    if (Test-Path $exe) { Start-Process $exe; Say 'heal: DSH restarted' }
    else { Say "heal: exe not found at $exe" }
    return 0
}

# ---------------------------------------------------------------- pass

function Invoke-Pass {
    $root = Get-InstallRoot
    $reasons = Get-Drift $root
    if ($reasons.Count -eq 0) {
        if (-not (Read-State)) { Write-State @{ hostVersion = (Get-HostVersion $root) } }
        Say "clean: $(if ($root) { $root } else { 'no install' }) v$(Get-HostVersion $root)"
        return 0
    }

    foreach ($r in $reasons) { Say "drift: $r" }
    if ($Detect) { return 3 }

    $busy = Test-UpdateInFlight $root
    if ($busy) { Say "stand down: $busy"; return 0 }

    return (Invoke-Heal $root ($reasons -join ' | '))
}

if ($Watch) {
    $pidFile = Join-Path $stateRoot 'guard.pid'
    if (Test-Path $pidFile) {
        $old = 0
        try { $old = [int](Get-Content $pidFile -Raw).Trim() } catch { }
        if ($old -gt 0 -and $old -ne $PID -and (Get-Process -Id $old -ErrorAction SilentlyContinue)) {
            Say "watch: already running as pid $old; exiting"
            exit 0
        }
    }
    $PID | Set-Content -LiteralPath $pidFile -Encoding ASCII
    Say "watch: interval ${IntervalSeconds}s, DSH_HOME $DshHome, pid $PID"
    try {
        while ($true) {
            try { [void](Invoke-Pass) } catch { Say "pass error: $($_.Exception.Message)" }
            Start-Sleep -Seconds $IntervalSeconds
        }
    }
    finally {
        Remove-Item $pidFile -Force -ErrorAction SilentlyContinue
    }
}

exit (Invoke-Pass)
