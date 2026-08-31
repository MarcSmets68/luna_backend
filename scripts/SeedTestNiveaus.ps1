# Seeds gebruiker.niveau on a small, named list of test users only
# (ABNA -> 5, MS -> 9, JS -> 9 - see SeedTestNiveaus.p header for why).
# Auth-MVP / login testing only - NEVER run this against a real/production
# database. Runs SeedTestNiveaus.p as a standalone ABL batch client (same
# _progres -b pattern as compile.ps1/RefreshLakproductieCache.ps1/
# SeedTestPasswords.ps1), connecting to the same LunaNew database the PASOE
# MarcTest instance uses (Backend/README.md, "PASOE instance" section).
# Deliberately NOT invoked from compile.ps1, a scheduled task, or any other
# automated pipeline - manual, one-off operational script only.
# Requires an explicit -Confirm switch (this scripts own gate, on top of the
# -param CONFIRM gate inside SeedTestNiveaus.p itself - two independent
# guards against an accidental run).
param(
    [switch]$Confirm
)

if (-not $Confirm) {
    Write-Host "Refusing to run: this seeds gebruiker.niveau on a named list of test users (ABNA/MS/JS)."
    Write-Host "Re-run with -Confirm if you really mean to do this on a test/dev database. NEVER on production."
    exit 1
}

$ErrorActionPreference = "Stop"

$dlc = if ($env:DLC) { $env:DLC } else { "C:\Progress\OpenEdge" }
$env:DLC = $dlc

Write-Host "Seeding test niveaus on LunaNew (lhdc01:4500)..."

$output = & "$dlc\bin\_progres.exe" -b -p "$PSScriptRoot\SeedTestNiveaus.p" -param "CONFIRM" -db LunaNew -H lhdc01 -S 4500 -N TCP 2>&1
$output | Write-Output

if ($LASTEXITCODE -ne 0) {
    Write-Error "SeedTestNiveaus.p exited with code $LASTEXITCODE."
    exit 1
}

Write-Host "Done."
