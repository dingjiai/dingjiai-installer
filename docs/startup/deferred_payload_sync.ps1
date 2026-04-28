param(
    [Parameter(Mandatory = $true)]
    [string] $WorkspaceRoot,

    [Parameter(Mandatory = $true)]
    [string] $PayloadRoot,

    [Parameter(Mandatory = $true)]
    [string] $ManifestPath,

    [Parameter(Mandatory = $true)]
    [string] $StatePath,

    [Parameter(Mandatory = $true)]
    [string] $BaseUrl
)

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

function Get-NormalizedPath {
    param([string] $Path)

    if ([string]::IsNullOrWhiteSpace($Path)) {
        throw 'empty path'
    }

    return [System.IO.Path]::GetFullPath($Path).TrimEnd([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar)
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

function Test-Sha256Text {
    param([string] $Value)

    return ($Value -match '^[a-fA-F0-9]{64}$')
}

function Get-FileSha256 {
    param([string] $Path)

    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Assert-NoReparsePointInPath {
    param(
        [string] $Path,
        [string] $Root
    )

    $normalizedPath = Get-NormalizedPath -Path $Path
    $normalizedRoot = Get-NormalizedPath -Path $Root
    $relativePath = $normalizedPath.Substring($normalizedRoot.Length).TrimStart([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar)
    $currentPath = $normalizedRoot

    foreach ($part in $relativePath.Split([System.IO.Path]::DirectorySeparatorChar, [System.StringSplitOptions]::RemoveEmptyEntries)) {
        $currentPath = Join-Path $currentPath $part
        if (Test-Path -LiteralPath $currentPath) {
            $item = Get-Item -LiteralPath $currentPath -Force
            if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw "payload 路径不能包含链接或 junction：$currentPath"
            }
        }
    }
}

function Assert-ManifestBoundToStartupState {
    $state = Get-Content -LiteralPath $StatePath -Raw | ConvertFrom-Json
    if (-not (Test-PathInsideRoot -Path $StatePath -Root (Join-Path $WorkspaceRoot 'state'))) {
        throw 'state 文件不在本地 state 目录内。'
    }
    if ([string]::IsNullOrWhiteSpace([string] $state.manifestSha256)) {
        throw '启动状态缺少 manifest hash。'
    }

    $actualManifestHash = Get-FileSha256 -Path $ManifestPath
    if ($actualManifestHash -ne ([string] $state.manifestSha256).ToLowerInvariant()) {
        throw 'manifest.json 与启动时记录不一致。'
    }
}

function Assert-SafePayloadPath {
    param([string] $Path)

    if ([string]::IsNullOrWhiteSpace($Path)) {
        throw 'payload 文件路径为空。'
    }
    if ([System.IO.Path]::IsPathRooted($Path)) {
        throw "payload 文件路径不能是绝对路径：$Path"
    }

    $destination = Join-Path $PayloadRoot $Path
    if (-not (Test-PathInsideRoot -Path $destination -Root $PayloadRoot)) {
        throw "payload 文件路径超出目录：$Path"
    }
    Assert-NoReparsePointInPath -Path $destination -Root $PayloadRoot
}

function Assert-ManifestShape {
    param($Manifest)

    if ($null -eq $Manifest) {
        throw 'manifest 为空。'
    }
    if ($Manifest.schemaVersion -ne 1) {
        throw 'manifest schemaVersion 不受支持。'
    }
    if ($Manifest.channel -ne 'v1-startup') {
        throw 'manifest channel 不受支持。'
    }
    if ($Manifest.basePath -ne '') {
        throw 'manifest basePath 必须是 payload。'
    }
    if ($null -eq $Manifest.files -or $Manifest.files.Count -lt 1) {
        throw 'manifest 缺少 payload 文件清单。'
    }

    foreach ($file in $Manifest.files) {
        Assert-SafePayloadPath -Path ([string] $file.path)
        if (-not (Test-Sha256Text -Value ([string] $file.sha256))) {
            throw "manifest 文件 $($file.path) 的 sha256 不合法。"
        }
        if ($file.required -isnot [bool]) {
            throw "manifest 文件 $($file.path) 的 required 必须是布尔值。"
        }
    }
}

function Sync-DeferredPayloadFile {
    param(
        $Manifest,
        $File
    )

    $relativePath = [string] $File.path
    $destination = Join-Path $PayloadRoot $relativePath
    $expectedHash = ([string] $File.sha256).ToLowerInvariant()

    if (Test-Path -LiteralPath $destination -PathType Leaf) {
        $currentHash = Get-FileSha256 -Path $destination
        if ($currentHash -eq $expectedHash) {
            return
        }
    }

    $destinationDir = Split-Path -Parent $destination
    New-Item -ItemType Directory -Force -Path $destinationDir | Out-Null

    $sourcePath = if ([string]::IsNullOrWhiteSpace([string] $Manifest.basePath)) { $relativePath } else { "$($Manifest.basePath)/$relativePath" }
    $url = "$($BaseUrl.TrimEnd('/'))/$($sourcePath.Replace('', '/'))"
    Invoke-WebRequest -Uri $url -OutFile $destination -UseBasicParsing -TimeoutSec 30

    $actualHash = Get-FileSha256 -Path $destination
    if ($actualHash -ne $expectedHash) {
        Remove-Item -LiteralPath $destination -Force -ErrorAction SilentlyContinue
        throw "payload 文件校验失败：$relativePath"
    }
}

try {
    if (-not (Test-Path -LiteralPath $WorkspaceRoot -PathType Container)) {
        throw '本地工作目录不存在。'
    }
    if (-not (Test-Path -LiteralPath $PayloadRoot -PathType Container)) {
        throw '本地 payload 目录不存在。'
    }
    if (-not (Test-Path -LiteralPath $ManifestPath -PathType Leaf)) {
        throw 'manifest.json 不存在。'
    }
    if (-not (Test-Path -LiteralPath $StatePath -PathType Leaf)) {
        throw '启动状态文件不存在。'
    }
    if (-not (Test-PathInsideRoot -Path $PayloadRoot -Root $WorkspaceRoot)) {
        throw 'payload 目录不在本地工作目录内。'
    }

    Assert-ManifestBoundToStartupState

    $manifest = Get-Content -LiteralPath $ManifestPath -Raw | ConvertFrom-Json
    Assert-ManifestShape -Manifest $manifest

    foreach ($file in $manifest.files) {
        if ($file.required -eq $true) {
            continue
        }
        Sync-DeferredPayloadFile -Manifest $manifest -File $file
    }

    Write-Host '启动文件已准备完成。'
    exit 0
} catch {
    Write-Host "启动文件准备失败：$($_.Exception.Message)"
    exit 70
}
