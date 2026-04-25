$ErrorActionPreference = 'Stop'

$script:Failed = $false

function Pass {
    param([string] $Message)
    Write-Host "[PASS] $Message"
}

function Fail {
    param([string] $Message)
    $script:Failed = $true
    Write-Host "[FAIL] $Message" -ForegroundColor Red
}

function Need {
    param(
        [bool] $Condition,
        [string] $Message
    )

    if ($Condition) {
        Pass $Message
    } else {
        Fail $Message
    }
}

function Test-PowerShellFileSyntax {
    param([string] $Path)

    $tokens = $null
    $errors = $null
    [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref] $tokens, [ref] $errors) | Out-Null
    if ($errors.Count -eq 0) {
        Pass "PowerShell syntax ok: $Path"
        return
    }

    foreach ($errorItem in $errors) {
        Fail "PowerShell syntax error: $Path line $($errorItem.Extent.StartLineNumber): $($errorItem.Message)"
    }
}

function Test-RelativePayloadPath {
    param([string] $Path)

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return $false
    }
    if ([System.IO.Path]::IsPathRooted($Path)) {
        return $false
    }

    $parts = $Path -split '[\\/]+'
    return -not ($parts -contains '..')
}

function Get-Sha256Hex {
    param([string] $Path)

    $stream = [System.IO.File]::OpenRead($Path)
    try {
        $sha256 = [System.Security.Cryptography.SHA256]::Create()
        try {
            $hashBytes = $sha256.ComputeHash($stream)
            return ([System.BitConverter]::ToString($hashBytes) -replace '-', '').ToLowerInvariant()
        } finally {
            $sha256.Dispose()
        }
    } finally {
        $stream.Dispose()
    }
}

$manifestPath = Join-Path $PSScriptRoot 'manifest.json'
$payloadRoot = Join-Path $PSScriptRoot 'payload'
$winEntryPath = Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) 'win.ps1'

Need (Test-Path -LiteralPath $manifestPath -PathType Leaf) "manifest exists: $manifestPath"
Need (Test-Path -LiteralPath $payloadRoot -PathType Container) "payload directory exists: $payloadRoot"
Need (Test-Path -LiteralPath $winEntryPath -PathType Leaf) "Windows bootstrap exists: $winEntryPath"

if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
    exit 1
}

$manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
Need ($manifest.schemaVersion -eq 1) 'manifest schemaVersion is 1'
Need ($manifest.basePath -eq 'payload') 'manifest basePath is payload'
Need ($manifest.mainEntry -eq 'main.cmd') 'manifest mainEntry is main.cmd'
Need ($manifest.handoffMode -eq 'admin-cmd') 'manifest handoffMode is admin-cmd'
Need ($null -ne $manifest.files -and $manifest.files.Count -gt 0) 'manifest has payload files'

$seenPaths = @{}
$mainEntrySeen = $false
foreach ($file in $manifest.files) {
    $payloadPath = [string] $file.path
    $pathIsRelative = Test-RelativePayloadPath -Path $payloadPath
    Need $pathIsRelative "payload path is relative and safe: $payloadPath"

    if (-not $pathIsRelative) {
        continue
    }

    $normalizedRelativePath = $payloadPath -replace '/', [System.IO.Path]::DirectorySeparatorChar
    $localPath = Join-Path $payloadRoot $normalizedRelativePath
    $pathKey = $payloadPath.ToLowerInvariant()

    Need (-not $seenPaths.ContainsKey($pathKey)) "payload path is unique: $payloadPath"
    $seenPaths[$pathKey] = $true

    Need (Test-Path -LiteralPath $localPath -PathType Leaf) "payload file exists: $payloadPath"
    Need (-not [string]::IsNullOrWhiteSpace([string] $file.sha256)) "payload file has sha256: $payloadPath"
    Need ($file.required -eq $true) "payload file is required: $payloadPath"

    if (Test-Path -LiteralPath $localPath -PathType Leaf) {
        $actualHash = Get-Sha256Hex -Path $localPath
        $expectedHash = ([string] $file.sha256).ToLowerInvariant()
        Need ($actualHash -eq $expectedHash) "payload sha256 matches manifest: $payloadPath"
    }

    if ($payloadPath -eq $manifest.mainEntry -and $file.required -eq $true) {
        $mainEntrySeen = $true
    }
}

Need $mainEntrySeen 'manifest includes required main entry'

$mainCmdPath = Join-Path $payloadRoot 'main.cmd'
if (Test-Path -LiteralPath $mainCmdPath -PathType Leaf) {
    $mainCmd = Get-Content -LiteralPath $mainCmdPath -Raw
    Need ($mainCmd -match '(?m)^:main_menu\s*$') 'main.cmd has main menu label'
    Need ($mainCmd -match '--startup-id') 'main.cmd accepts startup id'
    Need ($mainCmd -match '--workspace-root') 'main.cmd accepts workspace root'
    Need ($mainCmd -match '--state') 'main.cmd accepts state path'
    Need ($mainCmd -match '--log-path') 'main.cmd accepts log path'
    Need ($mainCmd -match '--payload-root') 'main.cmd accepts payload root'
    Need ($mainCmd -match '--main-entry-path') 'main.cmd accepts main entry path'
    Need ($mainCmd -match '--source') 'main.cmd accepts source'
    Need ($mainCmd -match '--handoff-mode') 'main.cmd accepts handoff mode'

    $embeddedLine = $mainCmd -split "`r?`n" | Where-Object { $_ -like 'powershell.exe * -Command "*' } | Select-Object -First 1
    Need (-not [string]::IsNullOrWhiteSpace($embeddedLine)) 'main.cmd has embedded PowerShell state writer'

    if (-not [string]::IsNullOrWhiteSpace($embeddedLine)) {
        $embeddedScript = $embeddedLine -replace '^.* -Command "', '' -replace '"\s*$', ''
        try {
            [scriptblock]::Create($embeddedScript) | Out-Null
            Pass 'embedded PowerShell syntax ok: main.cmd'
        } catch {
            Fail "embedded PowerShell syntax error: $($_.Exception.Message)"
        }
    }
}

if (Test-Path -LiteralPath $winEntryPath -PathType Leaf) {
    Test-PowerShellFileSyntax -Path $winEntryPath

    $winEntry = Get-Content -LiteralPath $winEntryPath -Raw
    Need ($winEntry -match '\$script:MinimumPowerShellVersion\s*=\s*\[version\]''5\.1''') 'win.ps1 requires PowerShell 5.1+'
    Need ($winEntry -match '\$script:MinimumWindowsBuild\s*=\s*17763') 'win.ps1 requires Windows build 17763+'
    Need ($winEntry -match 'function Get-StartupFailureSuggestion') 'win.ps1 has failure suggestion mapper'
    Need ($winEntry -match 'function Write-StartupFailureMessage') 'win.ps1 has unified failure message writer'
    Need ($winEntry -match 'failureSuggestion') 'win.ps1 writes failure suggestion to state'
    Need ($winEntry -match 'failureLogPath') 'win.ps1 writes failure log path to state'
    Need ($winEntry -match "Add-StartupCheck -Name 'windows_build'") 'win.ps1 checks Windows build'
    Need ($winEntry -match "Add-StartupCheck -Name 'powershell_version'") 'win.ps1 checks PowerShell version'
    Need ($winEntry -match '\$missingCapabilities') 'win.ps1 checks runtime capabilities'
}

if ($script:Failed) {
    Write-Host 'Windows startup self-check failed.' -ForegroundColor Red
    exit 1
}

Write-Host 'Windows startup self-check passed.'
