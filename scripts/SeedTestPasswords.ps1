# Seeds a single shared test password onto EVERY gebruiker row.
# The password is a mandatory -TestPassword parameter - never hardcode it here.
# Auth-MVP testing only - NEVER run this against a real/production database.
# Runs SeedTestPasswords.p as a standalone ABL batch client (same _progres -b
# pattern as compile.ps1/RefreshLakproductieCache.ps1), connecting to the same
# LunaNew database the PASOE MarcTest instance uses (Backend/README.md,
# "PASOE instance" section).
# Deliberately NOT invoked from compile.ps1, a scheduled task, or any other
# automated pipeline - manual, one-off operational script only.
# Requires an explicit -Confirm switch (this scripts own gate, on top of the
# -param CONFIRM gate inside SeedTestPasswords.p itself - two independent
# guards against an accidental run).
param(
    [switch]$Confirm,
    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$TestPassword
)

if (-not $Confirm) {
    Write-Host "Refusing to run: this seeds gebruiker.Password with a shared test password on EVERY row."
    Write-Host "Re-run with -Confirm if you really mean to do this on a test/dev database. NEVER on production."
    exit 1
}

$ErrorActionPreference = "Stop"

$dlc = if ($env:DLC) { $env:DLC } else { "C:\Progress\OpenEdge" }
$env:DLC = $dlc

Write-Host "Seeding test passwords on LunaNew (lhdc01:4500)..."

$output = & "$dlc\bin\_progres.exe" -b -p "$PSScriptRoot\SeedTestPasswords.p" -param "CONFIRM|$TestPassword" -db LunaNew -H lhdc01 -S 4500 -N TCP 2>&1
$output | Write-Output

if ($LASTEXITCODE -ne 0) {
    Write-Error "SeedTestPasswords.p exited with code $LASTEXITCODE."
    exit 1
}

Write-Host "Done."
