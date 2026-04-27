$ErrorActionPreference = 'Stop'

$localPath = $MyInvocation.MyCommand.Path
if (-not [string]::IsNullOrWhiteSpace($localPath)) {
    $localBootstrap = Join-Path (Split-Path -Parent $localPath) 'bootstrap.ps1'
    if (Test-Path -LiteralPath $localBootstrap -PathType Leaf) {
        & $localBootstrap
        exit $LASTEXITCODE
    }
}

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$client = New-Object Net.WebClient
try {
    $bytes = $client.DownloadData('https://get.dingjiai.com/bootstrap.ps1')
} finally {
    $client.Dispose()
}

$scriptText = [Text.Encoding]::UTF8.GetString($bytes).TrimStart([char] 0xFEFF)
Invoke-Expression $scriptText
