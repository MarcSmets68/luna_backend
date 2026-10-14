<#
.SYNOPSIS
    Refreshes the Omzetanalyse dealers (DNOM dashboard) cache file on disk
    (Backend/cache/omzetanalyse-dealers-dnom.json), read by GET
    /web/rapportage/omzetanalyse-dealers so the canned DNOM dashboard
    request never has to recompute the (~20s) scan live.
.DESCRIPTION
    Runs Luna.BusinessLogic.OmzetanalyseDealersCacheService:RefreshCache()
    as a standalone ABL batch client (RefreshOmzetanalyseDealersCache.p),
    completely independent of the PASOE web agents - a refresh never
    competes with, or is affected by, normal request handling.
    Connects to the same LunaNew database the PASOE MarcTest instance's
    agents connect to (see Backend/README.md, "PASOE instance" section) -
    only ever as an ordinary network client, same as PASOE itself.
    Intended to be run every 5 minutes by a Windows Scheduled Task - see
    Luna-RefreshOmzetanalyseDealersCache-task.xml in this folder for the
    task definition, and Backend/README.md, "Lakproduktie-cache" section,
    for how to register it (same mechanism).
#>

$ErrorActionPreference = "Stop"

$backendRoot = Split-Path -Parent $PSScriptRoot
$buildDir    = Join-Path $backendRoot "build"
$dlc         = if ($env:DLC) { $env:DLC } else { "C:\Progress\OpenEdge" }
$logFile     = Join-Path $PSScriptRoot "RefreshOmzetanalyseDealersCache.log"

function Write-Log {
    param([string]$Message)
    $line = "[{0}] {1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $Message
    Add-Content -Path $logFile -Value $line
}

$env:DLC = $dlc

Write-Log "Starting Omzetanalyse dealers cache refresh..."

# _progres on Windows doesn't pick up a PROPATH environment variable, so
# the build dir is passed via -param instead - RefreshOmzetanalyseDealersCache.p
# adds it to PROPATH itself at runtime (same pattern as scripts/compile.p).
$output = & "$dlc\bin\_progres.exe" -b -p "$PSScriptRoot\RefreshOmzetanalyseDealersCache.p" -param "$buildDir" `
    -db LunaNew -H lhdc01 -S 4500 -N TCP -U ABNA 2>&1
$output | ForEach-Object { Write-Log $_ }

if ($LASTEXITCODE -ne 0) {
    Write-Log "ERROR: RefreshOmzetanalyseDealersCache.p exited with code $LASTEXITCODE - see Backend/cache/omzetanalyse-dealers-refresh.log for details logged by OmzetanalyseDealersCacheService itself."
    exit 1
}

Write-Log "Omzetanalyse dealers cache refresh completed."
