<#
.SYNOPSIS
    Smoke-tests the MarcDev PASOE instance after a restart: polls GET /web/test
    until it responds, then fails if the ABL session isn't connected to LunaNew.
.DESCRIPTION
    Meant to run right after RestartMarcDev.ps1 in CI, so a compile that
    succeeded but a PASOE that came up broken (agent didn't reconnect,
    handler mapping typo, etc.) still fails the pipeline instead of shipping
    silently - same failure mode the "shipped but PASOE never restarted"
    incident in AGENTS.md is about, just automated.
#>

$ErrorActionPreference = "Stop"

$url            = "http://localhost:8081/web/test"
$maxWaitSeconds = 60
$waited         = 0

Write-Output "Waiting for MarcDev to answer $url ..."
while ($true) {
    try {
        $response = Invoke-RestMethod -Uri $url -Method Get -TimeoutSec 5
        break
    } catch {
        if ($waited -ge $maxWaitSeconds) {
            Write-Error "MarcDev did not respond on $url after $maxWaitSeconds seconds."
            exit 1
        }
        Start-Sleep -Seconds 2
        $waited += 2
    }
}

Write-Output ($response | ConvertTo-Json -Compress)

if (-not $response.databaseConnected) {
    Write-Error "MarcDev is up but not connected to LunaNew (databaseConnected=false)."
    exit 1
}

Write-Output "MarcDev smoke test passed (waited ${waited}s, databaseConnected=true)."
