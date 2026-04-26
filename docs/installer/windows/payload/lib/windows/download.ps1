param(
    [string] $FlowName = 'install',
    [string] $CheckpointName = 'download',
    [string] $ArtifactName = 'artifact',
    [ValidateSet('Generic', 'AppInstaller', 'Git', 'Claude')]
    [string] $ArtifactKind = 'Generic',
    [string] $Uri,
    [string[]] $AllowedHosts = @(),
    [string] $ExpectedSha256,
    [string] $StagingRoot,
    [switch] $AllowDownload,
    [int] $RetryCount = 2,
    [int] $TimeoutSeconds = 30,
    [ValidateSet('Text', 'Json')]
    [string] $OutputMode = 'Text',
    [ValidateSet('none', 'planned', 'downloaded', 'missing_metadata', 'source_blocked', 'download_failed', 'hash_mismatch', 'helper_failed')]
    [string] $TestScenario = 'none',
    [string] $ResultPath
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8
$script:ContractVersion = 'checkpoint.v1'
$script:ComponentName = 'download'
$script:HelperFailureExitCode = 70
$script:DownloadFailureExitCode = 60
$script:DecisionReportExitCode = 0
$script:SampleMode = 'download-only-staging'
$script:ActionMode = 'download-only'
$script:AllowedStatuses = @('planned', 'downloaded', 'missing_metadata', 'source_blocked', 'download_failed', 'hash_mismatch', 'helper_failed')
$script:AllowedDecisions = @('download', 'skip', 'retry', 'abort')
$script:MinimumRetryCount = 0
$script:MaximumRetryCount = 5
$script:MinimumTimeoutSeconds = 5
$script:MaximumTimeoutSeconds = 120

function Write-Section {
    param([string] $Text)
    Write-Host ''
    Write-Host "== $Text =="
}

function Write-Field {
    param(
        [string] $Name,
        [string] $Value
    )
    if ([string]::IsNullOrWhiteSpace($Value)) {
        $Value = '-'
    }
    Write-Host ("{0}: {1}" -f $Name, $Value)
}

function New-DownloadSource {
    param(
        [string] $SourceUri,
        [string] $SourceHost,
        [string[]] $AllowedHostList,
        [bool] $Https,
        [bool] $HostAllowed
    )

    return [pscustomobject] @{
        uri = $SourceUri
        host = $SourceHost
        allowedHosts = @($AllowedHostList)
        https = $Https
        hostAllowed = $HostAllowed
    }
}

function New-DownloadState {
    param(
        [string] $Root,
        [string] $Path,
        [Nullable[int64]] $Bytes,
        [string] $Sha256,
        [int] $Attempts,
        [bool] $TimedOut,
        [string] $Error
    )

    return [pscustomobject] @{
        stagingRoot = $Root
        artifactPath = $Path
        bytes = $Bytes
        sha256 = $Sha256
        attempts = $Attempts
        timedOut = $TimedOut
        error = $Error
    }
}

function New-DownloadDecision {
    param(
        [string] $Status,
        [string] $Decision,
        [string] $Reason,
        [string] $NextAction,
        [int] $ExitCode
    )

    return [pscustomobject] @{
        status = $Status
        decision = $Decision
        reason = $Reason
        nextAction = $NextAction
        exitCode = $ExitCode
    }
}

function New-DownloadResult {
    param(
        $Source,
        $Download,
        $Decision
    )

    return [pscustomobject] @{
        contractVersion = $script:ContractVersion
        component = $script:ComponentName
        flow = $FlowName
        checkpoint = $CheckpointName
        artifactName = $ArtifactName
        artifactKind = $ArtifactKind
        mutationAllowed = [bool] $AllowDownload
        sampleMode = $script:SampleMode
        actionMode = $script:ActionMode
        outputMode = $OutputMode
        testScenario = $TestScenario
        retryCount = $RetryCount
        timeoutSeconds = $TimeoutSeconds
        exitCodeContract = "planned reports return 0; download failures return $script:DownloadFailureExitCode; helper failures return $script:HelperFailureExitCode"
        source = $Source
        download = $Download
        decision = $Decision
    }
}

function New-HelperFailureResult {
    param([string] $Reason)

    $decision = New-DownloadDecision -Status 'helper_failed' -Decision 'abort' -Reason $Reason -NextAction '请查看 helper failure 输出并修复脚本自身问题。' -ExitCode $script:HelperFailureExitCode
    return New-DownloadResult -Source $null -Download $null -Decision $decision
}

function Get-ProjectLocalRoot {
    $localAppData = [Environment]::GetFolderPath('LocalApplicationData')
    if ([string]::IsNullOrWhiteSpace($localAppData)) {
        $localAppData = $env:TEMP
    }
    return (Join-Path $localAppData 'dingjiai-installer')
}

function Get-ProjectStagingRoot {
    return (Join-Path (Get-ProjectLocalRoot) 'downloads\staging')
}

function Get-NormalizedFullPath {
    param([string] $Path)

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return $null
    }

    try {
        return [System.IO.Path]::GetFullPath($Path).TrimEnd([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar)
    } catch {
        return $null
    }
}

function Test-PathInsideRoot {
    param(
        [string] $Path,
        [string] $Root
    )

    $normalizedPath = Get-NormalizedFullPath -Path $Path
    $normalizedRoot = Get-NormalizedFullPath -Path $Root
    if ($null -eq $normalizedPath -or $null -eq $normalizedRoot) {
        return $false
    }
    if ($normalizedPath.Equals($normalizedRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
        return $true
    }

    $rootWithSeparator = $normalizedRoot + [System.IO.Path]::DirectorySeparatorChar
    return $normalizedPath.StartsWith($rootWithSeparator, [System.StringComparison]::OrdinalIgnoreCase)
}

function Get-DefaultStagingRoot {
    $projectStagingRoot = Get-ProjectStagingRoot
    if ([string]::IsNullOrWhiteSpace($StagingRoot)) {
        return $projectStagingRoot
    }
    if (-not (Test-PathInsideRoot -Path $StagingRoot -Root $projectStagingRoot)) {
        throw "staging root must stay under $projectStagingRoot"
    }
    return (Get-NormalizedFullPath -Path $StagingRoot)
}

function Get-SafeFileName {
    param([string] $Name)

    if ([string]::IsNullOrWhiteSpace($Name)) {
        $Name = 'artifact'
    }

    $invalidChars = [System.IO.Path]::GetInvalidFileNameChars()
    $builder = New-Object System.Text.StringBuilder
    foreach ($character in $Name.ToCharArray()) {
        if ($invalidChars -contains $character) {
            [void] $builder.Append('_')
        } else {
            [void] $builder.Append($character)
        }
    }
    return $builder.ToString()
}

function Get-ArtifactFileName {
    param([uri] $ParsedUri)

    $sourceName = [System.IO.Path]::GetFileName($ParsedUri.AbsolutePath)
    if ([string]::IsNullOrWhiteSpace($sourceName)) {
        $sourceName = Get-SafeFileName -Name $ArtifactName
    }
    return Get-SafeFileName -Name $sourceName
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

function Test-Sha256Text {
    param([string] $Value)
    return ($Value -match '^[0-9a-fA-F]{64}$')
}

function ConvertTo-NormalizedHostList {
    param([string[]] $Hosts)

    $items = @()
    foreach ($hostItem in $Hosts) {
        if (-not [string]::IsNullOrWhiteSpace($hostItem)) {
            $items += $hostItem.Trim().ToLowerInvariant()
        }
    }
    return $items
}

function Test-AllowedHost {
    param(
        [string] $SourceHost,
        [string[]] $Hosts
    )

    if ([string]::IsNullOrWhiteSpace($SourceHost)) {
        return $false
    }
    $normalizedHost = $SourceHost.ToLowerInvariant()
    return ((ConvertTo-NormalizedHostList -Hosts $Hosts) -contains $normalizedHost)
}

function Get-NormalizedExpectedSha256 {
    if (Test-Sha256Text -Value $ExpectedSha256) {
        return $ExpectedSha256.ToLowerInvariant()
    }
    return $null
}

function Test-DownloadMetadataComplete {
    param($Source)

    return (
        $null -ne $Source -and
        -not [string]::IsNullOrWhiteSpace($Source.uri) -and
        $Source.https -eq $true -and
        $Source.hostAllowed -eq $true -and
        $AllowedHosts.Count -gt 0 -and
        -not [string]::IsNullOrWhiteSpace((Get-NormalizedExpectedSha256))
    )
}

function Add-DownloadMetadataFields {
    param($Source)

    $normalizedExpectedSha256 = Get-NormalizedExpectedSha256
    $metadataComplete = Test-DownloadMetadataComplete -Source $Source
    $Source | Add-Member -NotePropertyName metadataComplete -NotePropertyValue $metadataComplete -Force
    $Source | Add-Member -NotePropertyName downloadEnabled -NotePropertyValue ([bool] ($AllowDownload -and $metadataComplete)) -Force
    $Source | Add-Member -NotePropertyName expectedSha256Present -NotePropertyValue (-not [string]::IsNullOrWhiteSpace($ExpectedSha256)) -Force
    $Source | Add-Member -NotePropertyName expectedSha256Valid -NotePropertyValue (-not [string]::IsNullOrWhiteSpace($normalizedExpectedSha256)) -Force
    $Source | Add-Member -NotePropertyName expectedSha256Normalized -NotePropertyValue $normalizedExpectedSha256 -Force
    return $Source
}

function Get-SourceInfo {
    param([string] $SourceUri)

    $parsedUri = $null
    $isValid = [System.Uri]::TryCreate($SourceUri, [System.UriKind]::Absolute, [ref] $parsedUri)
    if (-not $isValid -or $null -eq $parsedUri) {
        return Add-DownloadMetadataFields -Source (New-DownloadSource -SourceUri $SourceUri -SourceHost $null -AllowedHostList $AllowedHosts -Https $false -HostAllowed $false)
    }

    $https = $parsedUri.Scheme -eq 'https'
    $hostAllowed = Test-AllowedHost -SourceHost $parsedUri.Host -Hosts $AllowedHosts
    return Add-DownloadMetadataFields -Source (New-DownloadSource -SourceUri $SourceUri -SourceHost $parsedUri.Host -AllowedHostList $AllowedHosts -Https $https -HostAllowed $hostAllowed)
}

function Invoke-FileDownload {
    param(
        [uri] $SourceUri,
        [string] $TargetPath
    )

    $attempt = 0
    $lastError = $null
    while ($attempt -le $RetryCount) {
        $attempt++
        try {
            if (Test-Path -LiteralPath $TargetPath -PathType Leaf) {
                Remove-Item -LiteralPath $TargetPath -Force
            }
            Invoke-WebRequest -Uri $SourceUri.AbsoluteUri -OutFile $TargetPath -UseBasicParsing -TimeoutSec $TimeoutSeconds
            return [pscustomobject] @{
                ok = $true
                attempts = $attempt
                timedOut = $false
                error = $null
            }
        } catch {
            $lastError = $_.Exception.Message
            if ($lastError -match 'timed out|timeout|operation has timed out') {
                $timedOut = $true
            } else {
                $timedOut = $false
            }
            if ($attempt -gt $RetryCount) {
                return [pscustomobject] @{
                    ok = $false
                    attempts = $attempt
                    timedOut = $timedOut
                    error = $lastError
                }
            }
        }
    }
}

function New-DownloadBoundaryFailureResult {
    param(
        [string] $Error,
        [string] $Reason,
        [string] $NextAction
    )

    $source = Get-SourceInfo -SourceUri $Uri
    $download = New-DownloadState -Root (Get-ProjectStagingRoot) -Path $null -Bytes $null -Sha256 $null -Attempts 0 -TimedOut $false -Error $Error
    $decision = New-DownloadDecision -Status 'missing_metadata' -Decision 'abort' -Reason $Reason -NextAction $NextAction -ExitCode $script:DownloadFailureExitCode
    return New-DownloadResult -Source $source -Download $download -Decision $decision
}

function Get-ParameterBoundaryFailureResult {
    if ($RetryCount -lt $script:MinimumRetryCount -or $RetryCount -gt $script:MaximumRetryCount) {
        return New-DownloadBoundaryFailureResult -Error 'retry count outside allowed range' -Reason "RetryCount 必须在 $script:MinimumRetryCount 到 $script:MaximumRetryCount 之间。" -NextAction '使用项目固定的下载重试预算，不允许无上限重试。'
    }
    if ($TimeoutSeconds -lt $script:MinimumTimeoutSeconds -or $TimeoutSeconds -gt $script:MaximumTimeoutSeconds) {
        return New-DownloadBoundaryFailureResult -Error 'timeout seconds outside allowed range' -Reason "TimeoutSeconds 必须在 $script:MinimumTimeoutSeconds 到 $script:MaximumTimeoutSeconds 之间。" -NextAction '使用项目固定的下载超时预算，不允许无上限等待。'
    }
    if (-not [string]::IsNullOrWhiteSpace($StagingRoot) -and -not (Test-PathInsideRoot -Path $StagingRoot -Root (Get-ProjectStagingRoot))) {
        return New-DownloadBoundaryFailureResult -Error 'staging root outside project local staging root' -Reason 'StagingRoot 必须位于当前用户的 dingjiai-installer downloads staging 目录内。' -NextAction '不要把下载产物写到系统目录、项目目录或任意外部路径。'
    }
    return $null
}

function Invoke-RealDownloadDiscovery {
    $parameterFailure = Get-ParameterBoundaryFailureResult
    if ($null -ne $parameterFailure) {
        return $parameterFailure
    }

    if (-not $AllowDownload) {
        $source = Get-SourceInfo -SourceUri $Uri
        $download = New-DownloadState -Root (Get-DefaultStagingRoot) -Path $null -Bytes $null -Sha256 $null -Attempts 0 -TimedOut $false -Error $null
        $decision = New-DownloadDecision -Status 'planned' -Decision 'download' -Reason '当前未传入 -AllowDownload，因此只报告下载计划，不写入文件。' -NextAction '确认下载源、sha256 和 staging 规则后，再显式开启 download-only 下载。' -ExitCode $script:DecisionReportExitCode
        return New-DownloadResult -Source $source -Download $download -Decision $decision
    }

    $source = Get-SourceInfo -SourceUri $Uri
    if (-not $source.metadataComplete) {
        $download = New-DownloadState -Root (Get-DefaultStagingRoot) -Path $null -Bytes $null -Sha256 $null -Attempts 0 -TimedOut $false -Error 'download metadata incomplete'
        $decision = New-DownloadDecision -Status 'source_blocked' -Decision 'abort' -Reason '真实下载必须先补齐 URL、允许 host 和 64 位 expected sha256。' -NextAction '确认官方来源、版本、架构和 sha256 后再开启下载。' -ExitCode $script:DownloadFailureExitCode
        return New-DownloadResult -Source $source -Download $download -Decision $decision
    }
    if (-not $source.https -or -not $source.hostAllowed) {
        $download = New-DownloadState -Root (Get-DefaultStagingRoot) -Path $null -Bytes $null -Sha256 $null -Attempts 0 -TimedOut $false -Error 'source is not allowed'
        $decision = New-DownloadDecision -Status 'source_blocked' -Decision 'abort' -Reason '下载源不是 HTTPS，或 host 不在本 checkpoint 明确允许列表中。' -NextAction '只使用项目确认过的官方下载源。' -ExitCode $script:DownloadFailureExitCode
        return New-DownloadResult -Source $source -Download $download -Decision $decision
    }
    if (-not (Test-Sha256Text -Value $ExpectedSha256)) {
        $download = New-DownloadState -Root (Get-DefaultStagingRoot) -Path $null -Bytes $null -Sha256 $null -Attempts 0 -TimedOut $false -Error 'invalid expected sha256'
        $decision = New-DownloadDecision -Status 'missing_metadata' -Decision 'abort' -Reason 'expected sha256 必须是 64 位十六进制字符串。' -NextAction '补齐可信 sha256 后再允许下载。' -ExitCode $script:DownloadFailureExitCode
        return New-DownloadResult -Source $source -Download $download -Decision $decision
    }

    $parsedUri = [uri] $Uri
    $root = Get-DefaultStagingRoot
    if (-not (Test-Path -LiteralPath $root -PathType Container)) {
        New-Item -ItemType Directory -Path $root -Force | Out-Null
    }

    $fileName = Get-ArtifactFileName -ParsedUri $parsedUri
    $artifactPath = Join-Path $root $fileName
    $partPath = "$artifactPath.part"
    $downloadResult = Invoke-FileDownload -SourceUri $parsedUri -TargetPath $partPath
    if (-not $downloadResult.ok) {
        $download = New-DownloadState -Root $root -Path $partPath -Bytes $null -Sha256 $null -Attempts $downloadResult.attempts -TimedOut $downloadResult.timedOut -Error $downloadResult.error
        $decision = New-DownloadDecision -Status 'download_failed' -Decision 'retry' -Reason '下载没有成功完成。' -NextAction '检查网络、代理或下载源状态后重试。' -ExitCode $script:DownloadFailureExitCode
        return New-DownloadResult -Source $source -Download $download -Decision $decision
    }

    $actualHash = Get-Sha256Hex -Path $partPath
    $bytes = (Get-Item -LiteralPath $partPath).Length
    if ($actualHash -ne $ExpectedSha256.ToLowerInvariant()) {
        $cleanupError = $null
        try {
            if (Test-Path -LiteralPath $partPath -PathType Leaf) {
                Remove-Item -LiteralPath $partPath -Force
            }
        } catch {
            $cleanupError = $_.Exception.Message
        }

        $downloadPath = $null
        $downloadError = 'sha256 mismatch; partial file deleted'
        $nextAction = '重新确认官方来源和 hash 后重试。'
        if (-not [string]::IsNullOrWhiteSpace($cleanupError)) {
            $downloadPath = $partPath
            $downloadError = "sha256 mismatch; partial file cleanup failed: $cleanupError"
            $nextAction = '请手动删除该 .part 文件，并重新确认官方来源和 hash。'
        }

        $download = New-DownloadState -Root $root -Path $downloadPath -Bytes $bytes -Sha256 $actualHash -Attempts $downloadResult.attempts -TimedOut $false -Error $downloadError
        $decision = New-DownloadDecision -Status 'hash_mismatch' -Decision 'abort' -Reason '下载文件 sha256 与预期值不一致，当前 helper 不会保留可消费的 staging 产物。' -NextAction $nextAction -ExitCode $script:DownloadFailureExitCode
        return New-DownloadResult -Source $source -Download $download -Decision $decision
    }

    if (Test-Path -LiteralPath $artifactPath -PathType Leaf) {
        Remove-Item -LiteralPath $artifactPath -Force
    }
    Move-Item -LiteralPath $partPath -Destination $artifactPath
    $download = New-DownloadState -Root $root -Path $artifactPath -Bytes $bytes -Sha256 $actualHash -Attempts $downloadResult.attempts -TimedOut $false -Error $null
    $decision = New-DownloadDecision -Status 'downloaded' -Decision 'skip' -Reason '下载产物已写入 staging，且 sha256 校验通过。' -NextAction '后续 checkpoint 可消费该 staging 产物；当前 helper 不执行安装。' -ExitCode $script:DecisionReportExitCode
    return New-DownloadResult -Source $source -Download $download -Decision $decision
}

function Get-TestDownloadResult {
    param([string] $Scenario)

    $source = Add-DownloadMetadataFields -Source (New-DownloadSource -SourceUri 'https://example.invalid/app-installer.msixbundle' -SourceHost 'example.invalid' -AllowedHostList @('example.invalid') -Https $true -HostAllowed $true)
    switch ($Scenario) {
        'planned' {
            $download = New-DownloadState -Root 'C:\Test\staging' -Path $null -Bytes $null -Sha256 $null -Attempts 0 -TimedOut $false -Error $null
            $decision = New-DownloadDecision -Status 'planned' -Decision 'download' -Reason 'simulated planned download' -NextAction 'enable explicit download later' -ExitCode 0
            return New-DownloadResult -Source $source -Download $download -Decision $decision
        }
        'downloaded' {
            $download = New-DownloadState -Root 'C:\Test\staging' -Path 'C:\Test\staging\app-installer.msixbundle' -Bytes 1234 -Sha256 ('a' * 64) -Attempts 1 -TimedOut $false -Error $null
            $decision = New-DownloadDecision -Status 'downloaded' -Decision 'skip' -Reason 'simulated verified staging artifact' -NextAction 'consume staging artifact later' -ExitCode 0
            return New-DownloadResult -Source $source -Download $download -Decision $decision
        }
        'missing_metadata' {
            $download = New-DownloadState -Root 'C:\Test\staging' -Path $null -Bytes $null -Sha256 $null -Attempts 0 -TimedOut $false -Error 'simulated missing metadata'
            $decision = New-DownloadDecision -Status 'missing_metadata' -Decision 'abort' -Reason 'simulated missing metadata' -NextAction 'provide uri host and hash' -ExitCode $script:DownloadFailureExitCode
            return New-DownloadResult -Source $source -Download $download -Decision $decision
        }
        'source_blocked' {
            $blockedSource = Add-DownloadMetadataFields -Source (New-DownloadSource -SourceUri 'http://example.invalid/app-installer.msixbundle' -SourceHost 'example.invalid' -AllowedHostList @('downloads.example.invalid') -Https $false -HostAllowed $false)
            $download = New-DownloadState -Root 'C:\Test\staging' -Path $null -Bytes $null -Sha256 $null -Attempts 0 -TimedOut $false -Error 'simulated blocked source'
            $decision = New-DownloadDecision -Status 'source_blocked' -Decision 'abort' -Reason 'simulated blocked source' -NextAction 'use allowed https source' -ExitCode $script:DownloadFailureExitCode
            return New-DownloadResult -Source $blockedSource -Download $download -Decision $decision
        }
        'download_failed' {
            $download = New-DownloadState -Root 'C:\Test\staging' -Path 'C:\Test\staging\app-installer.msixbundle.part' -Bytes $null -Sha256 $null -Attempts 3 -TimedOut $true -Error 'simulated download timeout'
            $decision = New-DownloadDecision -Status 'download_failed' -Decision 'retry' -Reason 'simulated download failure' -NextAction 'retry after network check' -ExitCode $script:DownloadFailureExitCode
            return New-DownloadResult -Source $source -Download $download -Decision $decision
        }
        'hash_mismatch' {
            $download = New-DownloadState -Root 'C:\Test\staging' -Path 'C:\Test\staging\app-installer.msixbundle.part' -Bytes 1234 -Sha256 ('b' * 64) -Attempts 1 -TimedOut $false -Error 'simulated sha256 mismatch'
            $decision = New-DownloadDecision -Status 'hash_mismatch' -Decision 'abort' -Reason 'simulated sha256 mismatch' -NextAction 'discard staging file' -ExitCode $script:DownloadFailureExitCode
            return New-DownloadResult -Source $source -Download $download -Decision $decision
        }
    }

    throw "Unknown download test scenario: $Scenario"
}

function Get-DownloadResult {
    if ($TestScenario -eq 'none') {
        return Invoke-RealDownloadDiscovery
    }
    if ($TestScenario -eq 'helper_failed') {
        throw 'simulated helper failure'
    }
    return Get-TestDownloadResult -Scenario $TestScenario
}

function Write-DownloadTextResult {
    param($Result)

    Write-Host '[download checkpoint]'
    Write-Field 'contractVersion' $Result.contractVersion
    Write-Field 'component' $Result.component
    Write-Field 'flow' $Result.flow
    Write-Field 'checkpoint' $Result.checkpoint
    Write-Field 'artifactName' $Result.artifactName
    Write-Field 'artifactKind' $Result.artifactKind
    Write-Field 'mutationAllowed' ([string] $Result.mutationAllowed)
    Write-Field 'sampleMode' $Result.sampleMode
    Write-Field 'actionMode' $Result.actionMode
    Write-Field 'outputMode' $Result.outputMode
    Write-Field 'testScenario' $Result.testScenario
    Write-Field 'retryCount' ([string] $Result.retryCount)
    Write-Field 'timeoutSeconds' ([string] $Result.timeoutSeconds)
    Write-Field 'exitCodeContract' $Result.exitCodeContract
    Write-Host '当前 helper 只允许下载到 staging，不会安装、解包到系统目录、改 PATH、注册表或用户配置。'

    if ($null -ne $Result.source) {
        Write-Section 'source'
        Write-Field 'uri' $Result.source.uri
        Write-Field 'host' $Result.source.host
        Write-Field 'https' ([string] $Result.source.https)
        Write-Field 'hostAllowed' ([string] $Result.source.hostAllowed)
        Write-Field 'allowedHosts' ([string]::Join(',', @($Result.source.allowedHosts)))
        Write-Field 'metadataComplete' ([string] $Result.source.metadataComplete)
        Write-Field 'downloadEnabled' ([string] $Result.source.downloadEnabled)
        Write-Field 'expectedSha256Present' ([string] $Result.source.expectedSha256Present)
        Write-Field 'expectedSha256Valid' ([string] $Result.source.expectedSha256Valid)
        Write-Field 'expectedSha256Normalized' $Result.source.expectedSha256Normalized
    }

    if ($null -ne $Result.download) {
        Write-Section 'download'
        Write-Field 'stagingRoot' $Result.download.stagingRoot
        Write-Field 'artifactPath' $Result.download.artifactPath
        Write-Field 'bytes' ([string] $Result.download.bytes)
        Write-Field 'sha256' $Result.download.sha256
        Write-Field 'attempts' ([string] $Result.download.attempts)
        Write-Field 'timedOut' ([string] $Result.download.timedOut)
        if (-not [string]::IsNullOrWhiteSpace($Result.download.error)) {
            Write-Field 'error' $Result.download.error
        }
    }

    Write-Section 'decision'
    Write-Field 'status' $Result.decision.status
    Write-Field 'decision' $Result.decision.decision
    Write-Field 'reason' $Result.decision.reason
    Write-Field 'nextAction' $Result.decision.nextAction
    Write-Host ''
}

function Test-ResultContract {
    param($Result)

    if ($null -eq $Result) {
        throw 'download result contract violation: result is null'
    }
    if ($Result.contractVersion -ne $script:ContractVersion) {
        throw 'download result contract violation: contractVersion must be checkpoint.v1'
    }
    if ($Result.component -ne $script:ComponentName) {
        throw 'download result contract violation: component must be download'
    }
    if ($null -eq $Result.decision) {
        throw 'download result contract violation: decision is null'
    }
    if ($script:AllowedStatuses -notcontains $Result.decision.status) {
        throw "download result contract violation: unsupported status '$($Result.decision.status)'"
    }
    if ($script:AllowedDecisions -notcontains $Result.decision.decision) {
        throw "download result contract violation: unsupported decision '$($Result.decision.decision)'"
    }
    if ($Result.decision.status -eq 'helper_failed') {
        if ($Result.decision.exitCode -ne $script:HelperFailureExitCode) {
            throw 'download result contract violation: helper failure exit code must be 70'
        }
        return
    }
    if (@('missing_metadata', 'source_blocked', 'download_failed', 'hash_mismatch') -contains $Result.decision.status) {
        if ($Result.decision.exitCode -ne $script:DownloadFailureExitCode) {
            throw 'download result contract violation: download failure exit code must be 60'
        }
        return
    }
    if ($Result.decision.exitCode -ne $script:DecisionReportExitCode) {
        throw 'download result contract violation: decision report exit code must be 0'
    }
}

function ConvertTo-JsonText {
    param($Value)

    $json = $Value | ConvertTo-Json -Depth 7
    $builder = New-Object System.Text.StringBuilder
    foreach ($character in $json.ToCharArray()) {
        if ([int] $character -gt 127) {
            [void] $builder.Append(('\u{0:x4}' -f [int] $character))
        } else {
            [void] $builder.Append($character)
        }
    }
    return $builder.ToString()
}

function Write-DownloadResultFile {
    param($Result)

    if ([string]::IsNullOrWhiteSpace($ResultPath)) {
        return
    }

    try {
        $projectLocalRoot = Get-ProjectLocalRoot
        if (-not (Test-PathInsideRoot -Path $ResultPath -Root $projectLocalRoot)) {
            throw "download result path must stay under $projectLocalRoot"
        }

        $parentPath = Split-Path -Parent $ResultPath
        if (-not [string]::IsNullOrWhiteSpace($parentPath) -and -not (Test-Path -LiteralPath $parentPath -PathType Container)) {
            New-Item -ItemType Directory -Path $parentPath -Force | Out-Null
        }

        $json = ConvertTo-JsonText -Value $Result
        [System.IO.File]::WriteAllText($ResultPath, $json, [System.Text.Encoding]::UTF8)
    } catch {
        throw "download result file write failed: $($_.Exception.Message)"
    }
}

function Write-DownloadResult {
    param(
        $Result,
        [switch] $SkipResultFile
    )

    Test-ResultContract -Result $Result
    if (-not $SkipResultFile) {
        Write-DownloadResultFile -Result $Result
    }

    if ($OutputMode -eq 'Json') {
        ConvertTo-JsonText -Value $Result
        return
    }

    Write-DownloadTextResult -Result $Result
}

try {
    $result = Get-DownloadResult
    Write-DownloadResult -Result $result
    exit $result.decision.exitCode
} catch {
    $result = New-HelperFailureResult -Reason $_.Exception.Message
    try {
        Write-DownloadResult -Result $result
    } catch {
        $fallbackResult = New-HelperFailureResult -Reason $_.Exception.Message
        Write-DownloadResult -Result $fallbackResult -SkipResultFile
    }
    exit $script:HelperFailureExitCode
}
