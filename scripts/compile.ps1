<#
.SYNOPSIS
    CLI compile check for the Luna PASOE backend (ABL classes/procedures).
.DESCRIPTION
    Compiles everything under Backend\src into Backend\build using _progres
    in batch mode. Run this after every meaningful backend change - this is
    the project's primary compile workflow (no PDSOE/Eclipse).
#>

$ErrorActionPreference = "Stop"

$backendRoot = Split-Path -Parent $PSScriptRoot
$srcDir      = Join-Path $backendRoot "src"
$buildDir    = Join-Path $backendRoot "build"
$dlc         = if ($env:DLC) { $env:DLC } else { "C:\Progress\OpenEdge" }

# _progres.exe itself calls OS-GETENV("DLC") during PROPATH setup
# (compile.p) - $dlc above is only a local PowerShell variable, so if the
# calling shell never exported DLC as a real environment variable, ABL's
# OS-GETENV("DLC") comes back unknown (?), string-concatenation propagates
# that unknown value into the PROPATH assignment, and the whole compile
# fails immediately with "Unable to evaluate field for assignment. (143)"
# before a single file compiles. Make sure the child process always has it.
$env:DLC = $dlc

if (-not (Test-Path $buildDir)) {
    New-Item -ItemType Directory -Path $buildDir | Out-Null
}

$output = & "$dlc\bin\_progres.exe" -b -p "$PSScriptRoot\compile.p" -param "$srcDir;$buildDir" -db LunaNew -H lhdc01 -S 4500 -N TCP 2>&1
$output | Write-Output

if ($output -match "ERROR compiling" -or $LASTEXITCODE -ne 0) {
    Write-Error "Compile failed - see ERROR lines above."
    exit 1
}
