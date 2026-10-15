# Loads machine-local environment variables for the PASOE agents from
# scripts\luna-env.local (NOT in git - see luna-env.example). Dot-source it
# BEFORE starting PASOE (tcman start), because the agents inherit the
# environment of the process that starts the instance:
#     . "$PSScriptRoot\Load-LunaEnv.ps1"
# File format: one NAME=VALUE per line, '#' starts a comment, no code is
# executed. Only the names in $allowed are accepted; values are never printed.
$envFile = Join-Path $PSScriptRoot "luna-env.local"
$allowed = @("AUTH_ENFORCE", "DEV_ENDPOINTS_ENABLED", "AUTH_EVERYONE_ADMIN", "GEMINI_API_KEY")

if (Test-Path $envFile) {
    foreach ($line in Get-Content $envFile) {
        $line = $line.Trim()
        if ($line -eq "" -or $line.StartsWith("#")) { continue }
        $idx = $line.IndexOf("=")
        if ($idx -lt 1) { continue }
        $name  = $line.Substring(0, $idx).Trim()
        $value = $line.Substring($idx + 1).Trim()
        if ($allowed -contains $name) {
            [Environment]::SetEnvironmentVariable($name, $value, "Process")
            Write-Host "Load-LunaEnv: set $name"
        } else {
            Write-Warning "Load-LunaEnv: ignoring unknown variable '$name'"
        }
    }
} else {
    Write-Warning "Load-LunaEnv: $envFile not found - PASOE starts without AUTH_ENFORCE/DEV_ENDPOINTS_ENABLED/GEMINI_API_KEY (copy scripts\luna-env.example to scripts\luna-env.local)."
}
