param(
    [string]$MenuFilePath = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$MenuFile = if ([string]::IsNullOrWhiteSpace($MenuFilePath)) {
    Join-Path $ScriptDir 'menu.txt'
}
else {
    $MenuFilePath
}
$Title = ''
$Subtitle = ''
$MenuOrder = [System.Collections.Generic.List[string]]::new()
$MenuLabels = @{}
$MenuMessages = @{}

function Import-Menu {
    if (-not (Test-Path -LiteralPath $MenuFile)) {
        throw "Missing menu definition: $MenuFile"
    }

    foreach ($line in Get-Content -LiteralPath $MenuFile) {
        if ([string]::IsNullOrWhiteSpace($line)) {
            continue
        }

        if ($line.StartsWith('TITLE=')) {
            $script:Title = $line.Substring(6)
            continue
        }

        if ($line.StartsWith('SUBTITLE=')) {
            $script:Subtitle = $line.Substring(9)
            continue
        }

        $parts = $line.Split('|', 3)
        if ($parts.Count -eq 3) {
            $key = $parts[0]
            $script:MenuOrder.Add($key)
            $script:MenuLabels[$key] = $parts[1]
            $script:MenuMessages[$key] = $parts[2]
        }
    }
}

function Show-Menu {
    Write-Host ''
    Write-Host '================================'
    Write-Host " $Title"
    Write-Host " $Subtitle"
    Write-Host '================================'

    foreach ($key in $MenuOrder) {
        Write-Host "[$key] $($MenuLabels[$key])"
    }

    Write-Host ''
}

function Invoke-Choice([string]$Choice) {
    if (-not $MenuMessages.ContainsKey($Choice)) {
        Write-Host "`nInvalid selection."
        return
    }

    Write-Host "`n$($MenuMessages[$Choice])"

    if ($Choice -eq '0') {
        exit 0
    }
}

Import-Menu

while ($true) {
    Show-Menu
    $choice = Read-Host 'Select an option'
    Invoke-Choice $choice
    Read-Host 'Press Enter to continue' | Out-Null
}
