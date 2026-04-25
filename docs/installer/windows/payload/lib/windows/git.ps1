param(
    [string] $FlowName = 'install',
    [string] $CheckpointName = 'git',
    [switch] $AllowMutation,
    [ValidateSet('Text', 'Json')]
    [string] $OutputMode = 'Text',
    [ValidateSet('none', 'healthy', 'missing', 'version_failed', 'version_timeout', 'version_too_old', 'version_untrusted', 'path_untrusted', 'helper_failed')]
    [string] $TestScenario = 'none',
    [string] $ResultPath
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8
$script:ProbeTimeoutSeconds = 15
$script:HelperFailureExitCode = 70
$script:SampleMode = 'discovery-diagnose-decision-only'
$script:ActionMode = 'report-only'
$script:MinimumGitVersion = [version] '2.40.0'
$script:ExpectedVersionMarker = 'windows.'
$script:WingetPackageId = 'Git.Git'
$script:AllowedStatuses = @('healthy', 'missing', 'command_broken', 'version_too_old', 'identity_untrusted', 'helper_failed')
$script:AllowedDecisions = @('skip', 'install', 'repair', 'upgrade', 'reinstall', 'abort')
$script:DecisionReportExitCode = 0

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

function New-ProbeResult {
    param(
        [bool] $Ok,
        [Nullable[int]] $ExitCode,
        [bool] $TimedOut,
        [string] $Stdout,
        [string] $Stderr
    )

    return [pscustomobject] @{
        ok = $Ok
        exitCode = $ExitCode
        timedOut = $TimedOut
        stdout = $Stdout
        stderr = $Stderr
    }
}

function New-GitDiscovery {
    param(
        [bool] $CommandFound,
        [string] $CommandPath,
        [bool] $VersionOk,
        [string] $VersionOutput,
        [string] $ParsedVersion,
        [Nullable[int]] $VersionExitCode,
        [bool] $VersionTimedOut,
        [string] $VersionError,
        [bool] $MinimumVersionMatched,
        [bool] $VersionMarkerMatched,
        [bool] $PathShapeMatched,
        [bool] $ProductNameMatched,
        [bool] $PublisherMatched,
        [bool] $PackageIdentityMatched,
        [bool] $OfficialIdentityMatched,
        [bool] $PlaceholderIdentityMatched,
        [string] $PackageId
    )

    return [pscustomobject] @{
        commandFound = $CommandFound
        commandPath = $CommandPath
        probeTimeoutSeconds = $script:ProbeTimeoutSeconds
        versionOk = $VersionOk
        versionOutput = $VersionOutput
        parsedVersion = $ParsedVersion
        versionExitCode = $VersionExitCode
        versionTimedOut = $VersionTimedOut
        versionError = $VersionError
        minimumRequiredVersion = $script:MinimumGitVersion.ToString()
        minimumVersionMatched = $MinimumVersionMatched
        expectedVersionMarker = $script:ExpectedVersionMarker
        versionMarkerMatched = $VersionMarkerMatched
        pathShapeMatched = $PathShapeMatched
        productNameMatched = $ProductNameMatched
        publisherMatched = $PublisherMatched
        packageIdentityMatched = $PackageIdentityMatched
        officialIdentityMatched = $OfficialIdentityMatched
        placeholderIdentityMatched = $PlaceholderIdentityMatched
        packageId = $PackageId
    }
}

function Get-TestGitDiscovery {
    param([string] $Scenario)

    switch ($Scenario) {
        'healthy' {
            return New-GitDiscovery -CommandFound $true -CommandPath 'C:\Program Files\Git\cmd\git.exe' -VersionOk $true -VersionOutput 'git version 2.51.0.windows.1' -ParsedVersion '2.51.0' -VersionExitCode 0 -VersionTimedOut $false -VersionError $null -MinimumVersionMatched $true -VersionMarkerMatched $true -PathShapeMatched $true -ProductNameMatched $true -PublisherMatched $true -PackageIdentityMatched $true -OfficialIdentityMatched $true -PlaceholderIdentityMatched $true -PackageId $script:WingetPackageId
        }
        'missing' {
            return New-GitDiscovery -CommandFound $false -CommandPath $null -VersionOk $false -VersionOutput $null -ParsedVersion $null -VersionExitCode $null -VersionTimedOut $false -VersionError $null -MinimumVersionMatched $false -VersionMarkerMatched $false -PathShapeMatched $false -ProductNameMatched $false -PublisherMatched $false -PackageIdentityMatched $false -OfficialIdentityMatched $false -PlaceholderIdentityMatched $false -PackageId $script:WingetPackageId
        }
        'version_failed' {
            return New-GitDiscovery -CommandFound $true -CommandPath 'C:\Program Files\Git\cmd\git.exe' -VersionOk $false -VersionOutput $null -ParsedVersion $null -VersionExitCode 1 -VersionTimedOut $false -VersionError 'simulated git version failure' -MinimumVersionMatched $false -VersionMarkerMatched $false -PathShapeMatched $true -ProductNameMatched $false -PublisherMatched $false -PackageIdentityMatched $false -OfficialIdentityMatched $false -PlaceholderIdentityMatched $false -PackageId $script:WingetPackageId
        }
        'version_timeout' {
            return New-GitDiscovery -CommandFound $true -CommandPath 'C:\Program Files\Git\cmd\git.exe' -VersionOk $false -VersionOutput $null -ParsedVersion $null -VersionExitCode $null -VersionTimedOut $true -VersionError 'simulated git version timeout' -MinimumVersionMatched $false -VersionMarkerMatched $false -PathShapeMatched $true -ProductNameMatched $false -PublisherMatched $false -PackageIdentityMatched $false -OfficialIdentityMatched $false -PlaceholderIdentityMatched $false -PackageId $script:WingetPackageId
        }
        'version_too_old' {
            return New-GitDiscovery -CommandFound $true -CommandPath 'C:\Program Files\Git\cmd\git.exe' -VersionOk $true -VersionOutput 'git version 2.39.5.windows.1' -ParsedVersion '2.39.5' -VersionExitCode 0 -VersionTimedOut $false -VersionError $null -MinimumVersionMatched $false -VersionMarkerMatched $true -PathShapeMatched $true -ProductNameMatched $true -PublisherMatched $true -PackageIdentityMatched $true -OfficialIdentityMatched $true -PlaceholderIdentityMatched $true -PackageId $script:WingetPackageId
        }
        'version_untrusted' {
            return New-GitDiscovery -CommandFound $true -CommandPath 'C:\Program Files\Git\cmd\git.exe' -VersionOk $true -VersionOutput 'git version 2.51.0-custom.1' -ParsedVersion '2.51.0' -VersionExitCode 0 -VersionTimedOut $false -VersionError $null -MinimumVersionMatched $true -VersionMarkerMatched $false -PathShapeMatched $true -ProductNameMatched $false -PublisherMatched $false -PackageIdentityMatched $false -OfficialIdentityMatched $false -PlaceholderIdentityMatched $false -PackageId $script:WingetPackageId
        }
        'path_untrusted' {
            return New-GitDiscovery -CommandFound $true -CommandPath 'C:\Tools\Git\cmd\git.exe' -VersionOk $true -VersionOutput 'git version 2.51.0.windows.1' -ParsedVersion '2.51.0' -VersionExitCode 0 -VersionTimedOut $false -VersionError $null -MinimumVersionMatched $true -VersionMarkerMatched $true -PathShapeMatched $false -ProductNameMatched $true -PublisherMatched $false -PackageIdentityMatched $false -OfficialIdentityMatched $false -PlaceholderIdentityMatched $false -PackageId $script:WingetPackageId
        }
    }

    throw "Unknown Git test scenario: $Scenario"
}

function ConvertTo-ProcessArgument {
    param([string] $Argument)

    if ($null -eq $Argument) {
        return '""'
    }
    if ($Argument -notmatch '[\s"]') {
        return $Argument
    }

    $builder = New-Object System.Text.StringBuilder
    [void] $builder.Append('"')
    $backslashCount = 0

    foreach ($character in $Argument.ToCharArray()) {
        if ($character -eq '\') {
            $backslashCount++
            continue
        }

        if ($character -eq '"') {
            [void] $builder.Append('\' * (($backslashCount * 2) + 1))
            [void] $builder.Append('"')
            $backslashCount = 0
            continue
        }

        if ($backslashCount -gt 0) {
            [void] $builder.Append('\' * $backslashCount)
            $backslashCount = 0
        }
        [void] $builder.Append($character)
    }

    if ($backslashCount -gt 0) {
        [void] $builder.Append('\' * ($backslashCount * 2))
    }
    [void] $builder.Append('"')
    return $builder.ToString()
}

function Join-ProcessArguments {
    param([string[]] $Arguments)

    $quotedArguments = @()
    foreach ($argument in $Arguments) {
        $quotedArguments += ConvertTo-ProcessArgument -Argument $argument
    }
    return [string]::Join(' ', $quotedArguments)
}

function Invoke-ProbeCommand {
    param(
        [string] $FilePath,
        [string[]] $Arguments,
        [int] $TimeoutSeconds = $script:ProbeTimeoutSeconds
    )

    $process = New-Object System.Diagnostics.Process
    $stdoutBuilder = New-Object System.Text.StringBuilder
    $stderrBuilder = New-Object System.Text.StringBuilder
    $process.StartInfo.FileName = $FilePath
    $process.StartInfo.Arguments = Join-ProcessArguments -Arguments $Arguments
    $process.StartInfo.UseShellExecute = $false
    $process.StartInfo.RedirectStandardOutput = $true
    $process.StartInfo.RedirectStandardError = $true
    $process.StartInfo.CreateNoWindow = $true

    try {
        Register-ObjectEvent -InputObject $process -EventName OutputDataReceived -Action {
            if ($null -ne $EventArgs.Data) {
                [void] $Event.MessageData.AppendLine($EventArgs.Data)
            }
        } -MessageData $stdoutBuilder | Out-Null
        Register-ObjectEvent -InputObject $process -EventName ErrorDataReceived -Action {
            if ($null -ne $EventArgs.Data) {
                [void] $Event.MessageData.AppendLine($EventArgs.Data)
            }
        } -MessageData $stderrBuilder | Out-Null

        [void] $process.Start()
        $process.BeginOutputReadLine()
        $process.BeginErrorReadLine()
        $completed = $process.WaitForExit($TimeoutSeconds * 1000)
        if (-not $completed) {
            try {
                $process.Kill()
                $process.WaitForExit()
            } catch {
            }
            $process.CancelOutputRead()
            $process.CancelErrorRead()
            return New-ProbeResult -Ok $false -ExitCode $null -TimedOut $true -Stdout $stdoutBuilder.ToString().Trim() -Stderr "命令超过 $TimeoutSeconds 秒未返回。"
        }

        $process.WaitForExit()
        $exitCode = $process.ExitCode
    } catch {
        return New-ProbeResult -Ok $false -ExitCode $null -TimedOut $false -Stdout $stdoutBuilder.ToString().Trim() -Stderr $_.Exception.Message
    } finally {
        Get-EventSubscriber | Where-Object { $_.SourceObject -eq $process } | Unregister-Event
        $process.Dispose()
    }

    return New-ProbeResult -Ok ($exitCode -eq 0) -ExitCode $exitCode -TimedOut $false -Stdout $stdoutBuilder.ToString().Trim() -Stderr $stderrBuilder.ToString().Trim()
}

function Get-NormalizedPathText {
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

function Test-PathEquals {
    param(
        [string] $Left,
        [string] $Right
    )

    $leftPath = Get-NormalizedPathText -Path $Left
    $rightPath = Get-NormalizedPathText -Path $Right
    if ($null -eq $leftPath -or $null -eq $rightPath) {
        return $false
    }

    return $leftPath.Equals($rightPath, [System.StringComparison]::OrdinalIgnoreCase)
}

function Test-GitTrustedPathShape {
    param([string] $Path)

    $localAppData = [Environment]::GetFolderPath('LocalApplicationData')
    $trustedPaths = @(
        'C:\Program Files\Git\cmd\git.exe',
        'C:\Program Files\Git\bin\git.exe',
        'C:\Program Files\Git\mingw64\bin\git.exe'
    )

    if (-not [string]::IsNullOrWhiteSpace($localAppData)) {
        $trustedPaths += (Join-Path $localAppData 'Programs\Git\cmd\git.exe')
        $trustedPaths += (Join-Path $localAppData 'Programs\Git\bin\git.exe')
        $trustedPaths += (Join-Path $localAppData 'Programs\Git\mingw64\bin\git.exe')
    }

    foreach ($trustedPath in $trustedPaths) {
        if (Test-PathEquals -Left $Path -Right $trustedPath) {
            return $true
        }
    }

    return $false
}

function Get-GitVersionFromOutput {
    param([string] $VersionOutput)

    if ([string]::IsNullOrWhiteSpace($VersionOutput)) {
        return $null
    }
    if ($VersionOutput -notmatch '(\d+\.\d+\.\d+)') {
        return $null
    }

    try {
        return [version] $Matches[1]
    } catch {
        return $null
    }
}

function Test-GitMinimumVersion {
    param([string] $VersionOutput)

    $parsedVersion = Get-GitVersionFromOutput -VersionOutput $VersionOutput
    if ($null -eq $parsedVersion) {
        return $false
    }

    return ($parsedVersion -ge $script:MinimumGitVersion)
}

function Test-GitVersionMarker {
    param([string] $VersionOutput)

    if ([string]::IsNullOrWhiteSpace($VersionOutput)) {
        return $false
    }

    return ($VersionOutput.IndexOf($script:ExpectedVersionMarker, [System.StringComparison]::OrdinalIgnoreCase) -ge 0)
}

function Get-RealGitDiscovery {
    $command = Get-Command git.exe -ErrorAction SilentlyContinue
    if ($null -eq $command) {
        return New-GitDiscovery -CommandFound $false -CommandPath $null -VersionOk $false -VersionOutput $null -ParsedVersion $null -VersionExitCode $null -VersionTimedOut $false -VersionError $null -MinimumVersionMatched $false -VersionMarkerMatched $false -PathShapeMatched $false -ProductNameMatched $false -PublisherMatched $false -PackageIdentityMatched $false -OfficialIdentityMatched $false -PlaceholderIdentityMatched $false -PackageId $script:WingetPackageId
    }

    $versionProbe = Invoke-ProbeCommand -FilePath $command.Source -Arguments @('--version')
    $parsedVersion = Get-GitVersionFromOutput -VersionOutput $versionProbe.stdout
    $parsedVersionText = if ($null -eq $parsedVersion) { $null } else { $parsedVersion.ToString() }
    $minimumVersionMatched = $versionProbe.ok -and (Test-GitMinimumVersion -VersionOutput $versionProbe.stdout)
    $versionMarkerMatched = $versionProbe.ok -and (Test-GitVersionMarker -VersionOutput $versionProbe.stdout)
    $pathShapeMatched = Test-GitTrustedPathShape -Path $command.Source
    $placeholderIdentityMatched = $versionMarkerMatched -and $pathShapeMatched

    return New-GitDiscovery -CommandFound $true -CommandPath $command.Source -VersionOk $versionProbe.ok -VersionOutput $versionProbe.stdout -ParsedVersion $parsedVersionText -VersionExitCode $versionProbe.exitCode -VersionTimedOut $versionProbe.timedOut -VersionError $versionProbe.stderr -MinimumVersionMatched $minimumVersionMatched -VersionMarkerMatched $versionMarkerMatched -PathShapeMatched $pathShapeMatched -ProductNameMatched $placeholderIdentityMatched -PublisherMatched $placeholderIdentityMatched -PackageIdentityMatched $placeholderIdentityMatched -OfficialIdentityMatched $placeholderIdentityMatched -PlaceholderIdentityMatched $placeholderIdentityMatched -PackageId $script:WingetPackageId
}

function Get-GitDiscovery {
    param([string] $Scenario = 'none')

    if ($Scenario -eq 'none') {
        return Get-RealGitDiscovery
    }
    if ($Scenario -eq 'helper_failed') {
        throw 'simulated helper failure'
    }
    return Get-TestGitDiscovery -Scenario $Scenario
}

function Get-GitDecision {
    param($Discovery)

    if (-not $Discovery.commandFound) {
        return [pscustomobject] @{
            status = 'missing'
            decision = 'install'
            reason = '未发现 git.exe，后续版本应通过 winget package Git.Git 安装 Git for Windows。'
            nextAction = '当前样板只报告 install 决策，不执行安装。'
            exitCode = 0
        }
    }

    if (-not $Discovery.versionOk) {
        return [pscustomobject] @{
            status = 'command_broken'
            decision = 'repair'
            reason = '已发现 git.exe，但 git --version 无法正常返回。'
            nextAction = '当前样板只报告 repair 决策，不执行修复。'
            exitCode = 0
        }
    }

    if (-not $Discovery.versionMarkerMatched -or -not $Discovery.pathShapeMatched -or -not $Discovery.placeholderIdentityMatched) {
        return [pscustomobject] @{
            status = 'identity_untrusted'
            decision = 'reinstall'
            reason = 'Git 可运行，但当前只读信任检查未确认其为项目认可的 Git for Windows 形态。'
            nextAction = '当前样板只报告 reinstall 决策，不执行重装。'
            exitCode = 0
        }
    }

    if (-not $Discovery.minimumVersionMatched) {
        return [pscustomobject] @{
            status = 'version_too_old'
            decision = 'upgrade'
            reason = "Git 版本低于当前最低要求 $($script:MinimumGitVersion.ToString())。"
            nextAction = '当前样板只报告 upgrade 决策，不执行升级。'
            exitCode = 0
        }
    }

    return [pscustomobject] @{
        status = 'healthy'
        decision = 'skip'
        reason = 'Git 命令、版本、路径形态和当前占位身份检查均满足要求。'
        nextAction = '继续后续 Claude checkpoint。'
        exitCode = 0
    }
}

function New-GitResult {
    param(
        $Discovery,
        $Decision
    )

    return [pscustomobject] @{
        flow = $FlowName
        checkpoint = $CheckpointName
        mutationAllowed = [bool] $AllowMutation
        sampleMode = $script:SampleMode
        actionMode = $script:ActionMode
        outputMode = $OutputMode
        testScenario = $TestScenario
        probeTimeoutSeconds = $script:ProbeTimeoutSeconds
        exitCodeContract = "decision reports return 0; helper failures return $script:HelperFailureExitCode"
        packageId = $script:WingetPackageId
        discovery = $Discovery
        decision = $Decision
    }
}

function New-HelperFailureResult {
    param([string] $Reason)

    return [pscustomobject] @{
        flow = $FlowName
        checkpoint = $CheckpointName
        mutationAllowed = [bool] $AllowMutation
        sampleMode = $script:SampleMode
        actionMode = $script:ActionMode
        outputMode = $OutputMode
        testScenario = $TestScenario
        probeTimeoutSeconds = $script:ProbeTimeoutSeconds
        exitCodeContract = "decision reports return 0; helper failures return $script:HelperFailureExitCode"
        packageId = $script:WingetPackageId
        discovery = $null
        decision = [pscustomobject] @{
            status = 'helper_failed'
            decision = 'abort'
            reason = $Reason
            nextAction = '请查看 helper failure 输出并修复脚本自身问题。'
            exitCode = $script:HelperFailureExitCode
        }
    }
}

function Write-GitTextResult {
    param($Result)

    Write-Host '[Git checkpoint]'
    Write-Field 'flow' $Result.flow
    Write-Field 'checkpoint' $Result.checkpoint
    Write-Field 'mutationAllowed' ([string] $Result.mutationAllowed)
    Write-Field 'sampleMode' $Result.sampleMode
    Write-Field 'actionMode' $Result.actionMode
    Write-Field 'outputMode' $Result.outputMode
    Write-Field 'testScenario' $Result.testScenario
    Write-Field 'probeTimeoutSeconds' ([string] $Result.probeTimeoutSeconds)
    Write-Field 'exitCodeContract' $Result.exitCodeContract
    Write-Field 'packageId' $Result.packageId
    Write-Host '当前样板只做发现、诊断和决策，不会安装、修复、升级、重装或改写系统。'

    if ($null -ne $Result.discovery) {
        Write-Section 'discovery'
        Write-Field 'commandFound' ([string] $Result.discovery.commandFound)
        Write-Field 'commandPath' $Result.discovery.commandPath
        Write-Field 'versionOk' ([string] $Result.discovery.versionOk)
        Write-Field 'versionOutput' $Result.discovery.versionOutput
        Write-Field 'parsedVersion' $Result.discovery.parsedVersion
        Write-Field 'versionTimedOut' ([string] $Result.discovery.versionTimedOut)
        Write-Field 'minimumRequiredVersion' $Result.discovery.minimumRequiredVersion
        Write-Field 'minimumVersionMatched' ([string] $Result.discovery.minimumVersionMatched)
        Write-Field 'versionMarkerMatched' ([string] $Result.discovery.versionMarkerMatched)
        Write-Field 'pathShapeMatched' ([string] $Result.discovery.pathShapeMatched)
        Write-Field 'placeholderIdentityMatched' ([string] $Result.discovery.placeholderIdentityMatched)

        if (-not [string]::IsNullOrWhiteSpace($Result.discovery.versionError)) {
            Write-Field 'versionError' $Result.discovery.versionError
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
        throw 'Git result contract violation: result is null'
    }
    if ($null -eq $Result.decision) {
        throw 'Git result contract violation: decision is null'
    }
    if ($script:AllowedStatuses -notcontains $Result.decision.status) {
        throw "Git result contract violation: unsupported status '$($Result.decision.status)'"
    }
    if ($script:AllowedDecisions -notcontains $Result.decision.decision) {
        throw "Git result contract violation: unsupported decision '$($Result.decision.decision)'"
    }
    if ($Result.decision.status -eq 'helper_failed') {
        if ($Result.decision.exitCode -ne $script:HelperFailureExitCode) {
            throw 'Git result contract violation: helper failure exit code must be 70'
        }
        return
    }
    if ($Result.decision.exitCode -ne $script:DecisionReportExitCode) {
        throw 'Git result contract violation: decision report exit code must be 0'
    }
}

function ConvertTo-JsonText {
    param($Value)

    $json = $Value | ConvertTo-Json -Depth 6
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

function Write-GitResultFile {
    param($Result)

    if ([string]::IsNullOrWhiteSpace($ResultPath)) {
        return
    }

    try {
        $parentPath = Split-Path -Parent $ResultPath
        if (-not [string]::IsNullOrWhiteSpace($parentPath) -and -not (Test-Path -LiteralPath $parentPath -PathType Container)) {
            New-Item -ItemType Directory -Path $parentPath -Force | Out-Null
        }

        $json = ConvertTo-JsonText -Value $Result
        [System.IO.File]::WriteAllText($ResultPath, $json, [System.Text.Encoding]::UTF8)
    } catch {
        throw "Git result file write failed: $($_.Exception.Message)"
    }
}

function Write-GitResult {
    param(
        $Result,
        [switch] $SkipResultFile
    )

    Test-ResultContract -Result $Result
    if (-not $SkipResultFile) {
        Write-GitResultFile -Result $Result
    }

    if ($OutputMode -eq 'Json') {
        ConvertTo-JsonText -Value $Result
        return
    }

    Write-GitTextResult -Result $Result
}

try {
    $discovery = Get-GitDiscovery -Scenario $TestScenario
    $decision = Get-GitDecision -Discovery $discovery
    $result = New-GitResult -Discovery $discovery -Decision $decision
    Write-GitResult -Result $result
    exit $decision.exitCode
} catch {
    $result = New-HelperFailureResult -Reason $_.Exception.Message
    try {
        Write-GitResult -Result $result
    } catch {
        $fallbackResult = New-HelperFailureResult -Reason $_.Exception.Message
        Write-GitResult -Result $fallbackResult -SkipResultFile
    }
    exit $script:HelperFailureExitCode
}
