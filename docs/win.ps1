param(
    [string]$PayloadBaseUrl = 'https://get.dingjiai.com/installer/windows',
    [string]$SourceDir = '',
    [string]$InstallRoot = (Join-Path $env:LOCALAPPDATA 'dingjiai-installer')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$PayloadFiles = @('win.ps1', 'menu.txt', 'main.cmd')

function Initialize-InstallRoot {
    if (-not (Test-Path -LiteralPath $InstallRoot)) {
        New-Item -ItemType Directory -Path $InstallRoot -Force | Out-Null
    }
}

function Copy-LocalPayload([string]$Root) {
    foreach ($file in $PayloadFiles) {
        $sourcePath = Join-Path $Root $file
        $destinationPath = Join-Path $InstallRoot $file

        if (-not (Test-Path -LiteralPath $sourcePath)) {
            throw "Missing source file: $sourcePath"
        }

        Copy-Item -LiteralPath $sourcePath -Destination $destinationPath -Force
    }
}

function Download-RemotePayload([string]$BaseUrl) {
    $trimmedBaseUrl = $BaseUrl.TrimEnd('/')

    foreach ($file in $PayloadFiles) {
        $uri = "$trimmedBaseUrl/$file"
        $destinationPath = Join-Path $InstallRoot $file
        Invoke-WebRequest -Uri $uri -OutFile $destinationPath
    }
}

function Start-LocalLauncher {
    $launcherPath = Join-Path $InstallRoot 'win.ps1'
    $menuFilePath = Join-Path $InstallRoot 'menu.txt'

    if (-not (Test-Path -LiteralPath $launcherPath)) {
        throw "Missing launcher file: $launcherPath"
    }

    if (-not (Test-Path -LiteralPath $menuFilePath)) {
        throw "Missing menu file: $menuFilePath"
    }

    & $launcherPath -MenuFilePath $menuFilePath
}

Write-Host 'dingjiai Installer bootstrap (Windows)'
Initialize-InstallRoot

if (-not [string]::IsNullOrWhiteSpace($SourceDir)) {
    $resolvedSourceDir = (Resolve-Path -LiteralPath $SourceDir).Path
    Write-Host "Using local payload from: $resolvedSourceDir"
    Copy-LocalPayload -Root $resolvedSourceDir
}
else {
    Write-Host "Downloading payload from: $PayloadBaseUrl"
    Download-RemotePayload -BaseUrl $PayloadBaseUrl
}

Start-LocalLauncher
