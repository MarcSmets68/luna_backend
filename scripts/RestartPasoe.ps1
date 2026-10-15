$env:DLC = 'C:\Progress\OpenEdge' 
. "$PSScriptRoot\Load-LunaEnv.ps1"
& "C:\OpenEdge\MarcOepas\bin\tcman.bat" stop 
& "C:\OpenEdge\MarcOepas\bin\tcman.bat" start 
