param(
    [string]$Method = "GET",
    [string]$Url,
    [string]$BodyFile = ""
)

try {
    if ($BodyFile -ne "") {
        $body = Get-Content -Raw $BodyFile
        $r = Invoke-WebRequest -Uri $Url -Method $Method -Body $body -ContentType 'application/json' -UseBasicParsing
    } else {
        $r = Invoke-WebRequest -Uri $Url -Method $Method -Headers @{Accept='application/json'} -UseBasicParsing
    }
    Write-Output $r.StatusCode
    Write-Output $r.Content
} catch {
    Write-Output $_.Exception.Response.StatusCode.value__
    $stream = $_.Exception.Response.GetResponseStream()
    $reader = New-Object System.IO.StreamReader($stream)
    Write-Output $reader.ReadToEnd()
}

