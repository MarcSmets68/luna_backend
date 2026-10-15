<#
.SYNOPSIS
    Checks that the LunaNew database is reachable, falling back to a local
    broker if it isn't, then starts the MarcTest PASOE instance. For use as
    a Windows Scheduled Task at system startup.
.DESCRIPTION
    The MarcTest PASOE AppServer agent connects to LunaNew on startup (see
    Backend/README.md - PASOE instance section). `agentStartupParam` now
    points at the shared test database on lhdc01 (-H lhdc01 -S 4500 -U ABNA),
    the same broker the legacy frontend UI uses - never started or
    reconfigured from here, only ever connected to as a client. If lhdc01 isn't reachable,
    this script falls back to starting the local copy of LunaNew as a
    broker on localhost:3050 (useful for local-only development), but note
    that fallback only takes effect if `openedge.properties` is pointed back
    at localhost:3050 - it does not rewrite that file.
#>

$ErrorActionPreference = "Stop"

$dlc          = if ($env:DLC) { $env:DLC } else { "C:\Progress\OpenEdge" }
$remoteHost   = "lhdc01"
$remotePort   = 4500
$dbPath       = "C:\LunaWEB - workspace\Databases\LunaNew"
$localPort    = 3050
$pasoeHome    = "C:\OpenEdge\MarcOepas"
$logFile      = Join-Path $PSScriptRoot "start-luna-env.log"

function Write-Log {
    param([string]$Message)
    $line = "[{0}] {1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $Message
    Add-Content -Path $logFile -Value $line
    Write-Output $line
}

function Test-PortOpen {
    param([string]$HostName, [int]$Port)
    try {
        $client = New-Object System.Net.Sockets.TcpClient
        $client.Connect($HostName, $Port)
        $client.Close()
        return $true
    } catch {
        return $false
    }
}

$env:DLC = $dlc

# 1. Confirm the shared LunaNew database on lhdc01 is reachable. It is owned
#    and started elsewhere (same broker the legacy frontend UI uses) - this
#    script only ever probes the port, never starts or touches it.
if (Test-PortOpen -HostName $remoteHost -Port $remotePort) {
    Write-Log "LunaNew reachable on ${remoteHost}:${remotePort} - proceeding."
} else {
    Write-Log "WARNING: LunaNew not reachable on ${remoteHost}:${remotePort}. Falling back to a local broker on localhost:$localPort (only useful if openedge.properties agentStartupParam is also pointed back at localhost:$localPort)."

    if (Test-PortOpen -HostName "localhost" -Port $localPort) {
        Write-Log "Local LunaNew copy already listening on port $localPort - skipping proserve."
    } else {
        $dbDrive = Split-Path -Qualifier $dbPath
        $maxDriveWaitSeconds = 30
        $driveWaited = 0
        while (-not (Test-Path $dbDrive)) {
            if ($driveWaited -ge $maxDriveWaitSeconds) {
                Write-Log "ERROR: Drive $dbDrive (for $dbPath) is not available after $maxDriveWaitSeconds seconds. Network drive may not be reconnected yet."
                exit 1
            }
            Start-Sleep -Seconds 2
            $driveWaited += 2
        }

        Write-Log "Starting local LunaNew database broker on port $localPort..."
        $proserve = Join-Path $dlc "bin\proserve.bat"
        Start-Process -FilePath $proserve `
            -ArgumentList "`"$dbPath`" -S $localPort -N TCP -H localhost" `
            -WindowStyle Hidden

        $maxWaitSeconds = 60
        $waited = 0
        while (-not (Test-PortOpen -HostName "localhost" -Port $localPort)) {
            if ($waited -ge $maxWaitSeconds) {
                Write-Log "ERROR: local LunaNew did not come up on port $localPort after $maxWaitSeconds seconds."
                exit 1
            }
            Start-Sleep -Seconds 2
            $waited += 2
        }
        Write-Log "Local LunaNew copy is up (waited ${waited}s)."
    }
}

# 2. Start the MarcTest PASOE instance. The agents inherit this
#    process's environment, so load AUTH_ENFORCE/DEV_ENDPOINTS_ENABLED/GEMINI_API_KEY first.
. "$PSScriptRoot\Load-LunaEnv.ps1"
Write-Log "Starting MarcTest PASOE instance..."
$tcman = Join-Path $pasoeHome "bin\tcman.bat"
$output = & $tcman start 2>&1
$output | ForEach-Object { Write-Log $_ }

Write-Log "start-luna-env.ps1 completed."
