param(
    [Parameter(Mandatory = $true)]
    [string] $StartupId,

    [Parameter(Mandatory = $true)]
    [string] $WorkspaceRoot,

    [Parameter(Mandatory = $true)]
    [string] $StatePath,

    [Parameter(Mandatory = $true)]
    [string] $LogPath,

    [Parameter(Mandatory = $true)]
    [string] $PayloadRoot,

    [Parameter(Mandatory = $true)]
    [string] $MainEntryPath,

    [Parameter(Mandatory = $true)]
    [string] $Source,

    [Parameter(Mandatory = $true)]
    [string] $SelfPath
)

$ErrorActionPreference = 'Stop'

function Get-NormalizedPath {
    param([string] $Path)

    if ([string]::IsNullOrWhiteSpace($Path)) {
        throw 'empty path'
    }

    return [System.IO.Path]::GetFullPath($Path).TrimEnd([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar)
}

function Test-SamePath {
    param(
        [string] $Left,
        [string] $Right
    )

    return (Get-NormalizedPath -Path $Left).Equals((Get-NormalizedPath -Path $Right), [System.StringComparison]::OrdinalIgnoreCase)
}

function Test-PathInsideRoot {
    param(
        [string] $Path,
        [string] $Root
    )

    $normalizedPath = Get-NormalizedPath -Path $Path
    $normalizedRoot = Get-NormalizedPath -Path $Root
    if ($normalizedPath.Equals($normalizedRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
        return $true
    }

    $rootWithSeparator = $normalizedRoot + [System.IO.Path]::DirectorySeparatorChar
    return $normalizedPath.StartsWith($rootWithSeparator, [System.StringComparison]::OrdinalIgnoreCase)
}

function Assert-Condition {
    param(
        [bool] $Condition,
        [string] $Message
    )

    if (-not $Condition) {
        throw $Message
    }
}

function Write-AtomicTextFile {
    param(
        [string] $Path,
        [string] $Value
    )

    $directory = [System.IO.Path]::GetDirectoryName($Path)
    $fileName = [System.IO.Path]::GetFileName($Path)
    $tempPath = [System.IO.Path]::Combine($directory, ('{0}.{1}.tmp' -f $fileName, [guid]::NewGuid().ToString('N')))
    $backupPath = [System.IO.Path]::Combine($directory, ('{0}.{1}.bak' -f $fileName, [guid]::NewGuid().ToString('N')))

    try {
        Set-Content -LiteralPath $tempPath -Value $Value -Encoding UTF8
        if ([System.IO.File]::Exists($Path)) {
            [System.IO.File]::Replace($tempPath, $Path, $backupPath)
        } else {
            [System.IO.File]::Move($tempPath, $Path)
        }
    } finally {
        if ([System.IO.File]::Exists($tempPath)) {
            Remove-Item -LiteralPath $tempPath -Force -ErrorAction SilentlyContinue
        }
        if ([System.IO.File]::Exists($backupPath)) {
            Remove-Item -LiteralPath $backupPath -Force -ErrorAction SilentlyContinue
        }
    }
}

Assert-Condition (Test-Path -LiteralPath $WorkspaceRoot -PathType Container) 'workspace missing'
Assert-Condition (Test-Path -LiteralPath $StatePath -PathType Leaf) 'state missing'
Assert-Condition (Test-Path -LiteralPath $PayloadRoot -PathType Container) 'payload missing'
Assert-Condition (Test-SamePath -Left $PayloadRoot -Right (Join-Path (Get-NormalizedPath -Path $WorkspaceRoot) 'payload')) 'payload root mismatch'
Assert-Condition (Test-SamePath -Left ([System.IO.Path]::GetDirectoryName((Get-NormalizedPath -Path $StatePath))) -Right (Join-Path (Get-NormalizedPath -Path $WorkspaceRoot) 'state')) 'state path outside workspace'
Assert-Condition (Test-SamePath -Left ([System.IO.Path]::GetDirectoryName((Get-NormalizedPath -Path $LogPath))) -Right (Join-Path (Get-NormalizedPath -Path $WorkspaceRoot) 'logs')) 'log path outside workspace'
Assert-Condition (Test-PathInsideRoot -Path $MainEntryPath -Root $PayloadRoot) 'main entry outside payload root'
Assert-Condition (Test-SamePath -Left $MainEntryPath -Right $SelfPath) 'main entry self mismatch'

$state = Get-Content -LiteralPath $StatePath -Raw | ConvertFrom-Json
Assert-Condition ($state.startupId -eq $StartupId) 'startupId mismatch'
Assert-Condition ($state.stage -ne 'failed') 'startup already failed'
Assert-Condition (Test-SamePath -Left $state.workspaceRoot -Right $WorkspaceRoot) 'state workspace mismatch'
Assert-Condition (Test-SamePath -Left $state.payloadRoot -Right $PayloadRoot) 'state payload mismatch'
Assert-Condition (Test-SamePath -Left $state.mainEntryPath -Right $MainEntryPath) 'state main entry mismatch'
Assert-Condition ($state.source -eq $Source) 'state source mismatch'

if ($state.stage -eq 'completed' -and $state.handoffAccepted -eq $true) {
    exit 0
}

$values = @{
    stage = 'completed'
    handoffAccepted = $true
    handoffAcceptedAt = (Get-Date).ToString('o')
    acceptedWorkspaceRoot = $WorkspaceRoot
    acceptedStatePath = $StatePath
    acceptedLogPath = $LogPath
    acceptedPayloadRoot = $PayloadRoot
    acceptedMainEntryPath = $MainEntryPath
    acceptedSource = $Source
    acceptedHandoffMode = 'admin-cmd'
}

foreach ($key in $values.Keys) {
    $state | Add-Member -NotePropertyName $key -NotePropertyValue $values[$key] -Force
}

Write-AtomicTextFile -Path $StatePath -Value ($state | ConvertTo-Json -Depth 8)
