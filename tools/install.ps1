<#
.SYNOPSIS
  TX install script: static checks -> mirror TX\ and/or TX_Dev\ into the game's Mods folder -> optional log tail.

.DESCRIPTION
  Default:     runs tools\check_all.py on TX\ (and TX_Dev\ with -Dev); stops on errors unless -Force;
               then robocopy /MIR TX\ -> <Mods>\TX (and TX_Dev\ -> <Mods>\TX_Dev with -Dev).
  -DevOnly:    checks and installs ONLY TX_Dev\ (the dev tools). TX\ does not need to exist (the spike
               phase only has the dev mod). <Mods>\TX is not touched; a note is printed when it exists.
  Installing refuses to run while Civilization VI is running (the game locks and caches mod files).
  -Watch:      after installing, tails Lua.log live, filtered by -Pattern.
               Start it after the game's main menu is up: the game recreates Lua.log at launch
               (the tail re-attaches when the file is recreated). Lua.log is buffered while playing;
               some output only shows after exiting to the menu or desktop.
  -WatchOnly:  tail without checking/installing.
  -CheckLogs:  only scan Database.log, Modding.log, Lua.log and UserInterface.log of the last run for
               TX-related errors (tools\check_logs.py); exit code 1 if any.
  Mirroring deletes files in the target that no longer exist in the source; the target folders are TX-owned.
  Only folders named TX* are ever mirrored, and only into -ModsDir.

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File tools\install.ps1 -DevOnly
  powershell -ExecutionPolicy Bypass -File tools\install.ps1 -DevOnly -Watch
  powershell -ExecutionPolicy Bypass -File tools\install.ps1
  powershell -ExecutionPolicy Bypass -File tools\install.ps1 -Dev -Watch
  powershell -ExecutionPolicy Bypass -File tools\install.ps1 -CheckLogs
#>
[CmdletBinding()]
param(
    [switch]$Dev,
    [switch]$DevOnly,
    [switch]$Watch,
    [switch]$WatchOnly,
    [switch]$CheckLogs,
    [switch]$Force,
    [switch]$SkipChecks,
    [switch]$Strict,
    [string]$Src,
    [string]$DevSrc,
    [string]$ModsDir = "S:\Libraries\Documents\My Games\Sid Meier's Civilization VI\Mods",
    [string]$LogsDir,
    [string]$Python = "python",
    [string]$Pattern = "TX|Runtime Error|Syntax Error|stack traceback"
)

$ErrorActionPreference = "Stop"
$ToolsDir = $PSScriptRoot
$ProjectDir = Split-Path -Parent $ToolsDir
if (-not $Src)    { $Src    = Join-Path $ProjectDir "TX" }
if (-not $DevSrc) { $DevSrc = Join-Path $ProjectDir "TX_Dev" }
if (-not $LogsDir) {
    if ($env:LOCALAPPDATA) {
        $LogsDir = Join-Path $env:LOCALAPPDATA "Firaxis Games\Sid Meier's Civilization VI\Logs"
    } else {
        $LogsDir = Join-Path $HOME "AppData\Local\Firaxis Games\Sid Meier's Civilization VI\Logs"
    }
}

function Write-Step([string]$msg) { Write-Host ""; Write-Host "== $msg" -ForegroundColor Cyan }

function Invoke-Python([string[]]$argList) {
    # Out-Host keeps python's output out of the function's return value
    & $Python @argList | Out-Host
    return [int]$LASTEXITCODE
}

function Invoke-LogCheck {
    Write-Step "Scanning logs in $LogsDir"
    $code = Invoke-Python @((Join-Path $ToolsDir "check_logs.py"), "--logs", $LogsDir, "--tail", "5")
    return $code
}

function Invoke-Mirror([string]$from) {
    if (-not (Test-Path -LiteralPath $from -PathType Container)) { throw "source folder not found: $from" }
    if (-not (Test-Path -LiteralPath $ModsDir -PathType Container)) { throw "Mods folder not found: $ModsDir" }
    # safety: only ever mirror a TX* folder into <ModsDir>\<same leaf name as the source>
    $leaf = Split-Path -Leaf $from
    if ($leaf -notmatch '^TX') { throw "refusing to mirror a folder that is not TX-owned: $leaf" }
    $modsFull = (Resolve-Path -LiteralPath $ModsDir).Path.TrimEnd('\')
    $to = Join-Path $modsFull $leaf
    if ((Split-Path -Parent $to).TrimEnd('\') -ne $modsFull) { throw "refusing to mirror outside $ModsDir" }
    if ((Split-Path -Leaf $to) -notmatch '^TX') { throw "refusing to mirror to $to (not a TX* folder)" }
    Write-Step "Mirroring $from -> $to"
    & robocopy $from $to /MIR /NFL /NDL /NJH /NP /R:2 /W:1 /XF "*.bak" "*~" "Thumbs.db" | Out-Host
    $rc = $LASTEXITCODE
    if ($rc -ge 8) { throw "robocopy failed with exit code $rc" }
    Write-Host "robocopy ok (exit $rc)"
    $global:LASTEXITCODE = 0
}

function Start-LuaLogWatch {
    $log = Join-Path $LogsDir "Lua.log"
    Write-Step "Watching $log  (filter: $Pattern)  Ctrl+C to stop"
    Write-Host "Note: start this after the main menu is up; Lua.log is buffered while playing." -ForegroundColor DarkGray
    while ($true) {
        while (-not (Test-Path -LiteralPath $log)) { Start-Sleep -Milliseconds 500 }
        $created = (Get-Item -LiteralPath $log).CreationTime
        $job = Start-Job -ScriptBlock {
            param($path, $pat)
            Get-Content -LiteralPath $path -Wait -Tail 0 | Where-Object { $_ -match $pat }
        } -ArgumentList $log, $Pattern
        try {
            while ($true) {
                Receive-Job $job | ForEach-Object {
                    if ($_ -match 'Runtime Error|Syntax Error|stack traceback|ERROR|FAIL') { Write-Host $_ -ForegroundColor Red }
                    else { Write-Host $_ }
                }
                Start-Sleep -Milliseconds 300
                # a game relaunch recreates the file: re-attach
                if (-not (Test-Path -LiteralPath $log)) { break }
                if ((Get-Item -LiteralPath $log).CreationTime -ne $created) { Write-Host "-- Lua.log recreated, re-attaching" -ForegroundColor DarkGray; break }
                if ($job.State -ne 'Running') { break }
            }
        } finally {
            Stop-Job $job -ErrorAction SilentlyContinue
            Remove-Job $job -Force -ErrorAction SilentlyContinue
        }
    }
}

# ---------------------------------------------------------------- modes
if ($CheckLogs) {
    $code = Invoke-LogCheck
    exit $code
}
if ($WatchOnly) {
    Start-LuaLogWatch
    exit 0
}

# 0. the game must not be running while its Mods folder changes
$game = Get-Process -Name "CivilizationVI*" -ErrorAction SilentlyContinue
if ($game) {
    Write-Host "Civilization VI is running ($($game[0].ProcessName)). Quit the game, then run this again." -ForegroundColor Red
    exit 3
}

# what to install
$sources = @()
if ($DevOnly) {
    $sources = @($DevSrc)
    $localTx = Join-Path $ModsDir (Split-Path -Leaf $Src)
    if (Test-Path -LiteralPath $localTx -PathType Container) {
        Write-Host "Note: $localTx exists and is not updated by -DevOnly. Disable or delete it if this test should run without TX." -ForegroundColor Yellow
    }
} else {
    $sources = @($Src)
    if ($Dev) { $sources += $DevSrc }
}
foreach ($s in $sources) {
    if (-not (Test-Path -LiteralPath $s -PathType Container)) {
        $hint = ""
        if ($s -eq $Src) { $hint = " (only the dev mod exists so far? use -DevOnly)" }
        Write-Host "Source folder not found: $s$hint" -ForegroundColor Red
        exit 2
    }
}

# 1. static checks
if (-not $SkipChecks) {
    Write-Step ("Static checks: " + ($sources -join ", "))
    $argList = @((Join-Path $ToolsDir "check_all.py")) + $sources + @("--no-checklist")
    if ($Strict) { $argList += "--strict" }
    $code = Invoke-Python $argList
    if ($code -ne 0) {
        if ($Force) {
            Write-Host "Checks FAILED (exit $code), installing anyway because of -Force" -ForegroundColor Yellow
        } else {
            Write-Host "Checks FAILED (exit $code), not installing. Fix the errors or rerun with -Force." -ForegroundColor Red
            exit $code
        }
    }
} else {
    Write-Host "Skipping static checks (-SkipChecks)" -ForegroundColor Yellow
}

# 2. mirror
foreach ($s in $sources) { Invoke-Mirror $s }
Write-Host ""
Write-Host "Installed. Enable the mod(s) in Additional Content, start a NEW game, then quit to the desktop and run:" -ForegroundColor Green
Write-Host "  python tools\summarize_log.py"
Write-Host "  powershell -ExecutionPolicy Bypass -File tools\install.ps1 -CheckLogs"

# 3. watch
if ($Watch) { Start-LuaLogWatch }
exit 0
