$env:DLC = 'C:\Progress\OpenEdge'
. "$PSScriptRoot\Load-LunaEnv.ps1"
& "C:\OpenEdge\WRK\MarcDev\bin\tcman.bat" stop
& "C:\OpenEdge\WRK\MarcDev\bin\tcman.bat" start
