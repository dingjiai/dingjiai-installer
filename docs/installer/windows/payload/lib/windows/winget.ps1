param(
    [string] $FlowName = 'install',
    [string] $CheckpointName = 'winget',
    [switch] $AllowMutation,
    [ValidateSet('Text', 'Json')]
    [string] $OutputMode = 'Text',
    [ValidateSet('none', 'healthy', 'missing', 'version_failed', 'version_timeout', 'source_failed', 'source_timeout', 'source_missing', 'source_untrusted', 'helper_failed')]
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
$script:AllowedStatuses = @('healthy', 'missing', 'command_broken', 'source_broken', 'helper_failed')
$script:AllowedDecisions = @('skip', 'install', 'repair', 'abort')
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

function New-WingetDiscovery {
    param(
        [bool] $CommandFound,
        [string] $CommandPath,
        [bool] $VersionOk,
        [string] $Version,
        [Nullable[int]] $VersionExitCode,
        [bool] $VersionTimedOut,
        [string] $VersionError,
        [bool] $SourceOk,
        [Nullable[int]] $SourceExitCode,
        [bool] $SourceTimedOut,
        [bool] $SourceHasWinget,
        [string] $SourceError,
        [string] $SourceOutput
    )

    return [pscustomobject] @{
        commandFound = $CommandFound
        commandPath = $CommandPath
        probeTimeoutSeconds = $script:ProbeTimeoutSeconds
        versionOk = $VersionOk
        version = $Version
        versionExitCode = $VersionExitCode
        versionTimedOut = $VersionTimedOut
        versionError = $VersionError
        sourceOk = $SourceOk
        sourceExitCode = $SourceExitCode
        sourceTimedOut = $SourceTimedOut
        sourceHasWinget = $SourceHasWinget
        sourceError = $SourceError
        sourceOutput = $SourceOutput
    }
}

function Get-TestWingetDiscovery {
    param([string] $Scenario)

    switch ($Scenario) {
        'healthy' {
            return New-WingetDiscovery -CommandFound $true -CommandPath 'C:\Test\winget.exe' -VersionOk $true -Version 'v1.0.0-test' -VersionExitCode 0 -VersionTimedOut $false -VersionError $null -SourceOk $true -SourceExitCode 0 -SourceTimedOut $false -SourceHasWinget $true -SourceError $null -SourceOutput 'winget https://cdn.winget.microsoft.com/cache'
        }
        'missing' {
            return New-WingetDiscovery -CommandFound $false -CommandPath $null -VersionOk $false -Version $null -VersionExitCode $null -VersionTimedOut $false -VersionError $null -SourceOk $false -SourceExitCode $null -SourceTimedOut $false -SourceHasWinget $false -SourceError $null -SourceOutput $null
        }
        'version_failed' {
            return New-WingetDiscovery -CommandFound $true -CommandPath 'C:\Test\winget.exe' -VersionOk $false -Version $null -VersionExitCode 1 -VersionTimedOut $false -VersionError 'simulated version failure' -SourceOk $false -SourceExitCode $null -SourceTimedOut $false -SourceHasWinget $false -SourceError $null -SourceOutput $null
        }
        'version_timeout' {
            return New-WingetDiscovery -CommandFound $true -CommandPath 'C:\Test\winget.exe' -VersionOk $false -Version $null -VersionExitCode $null -VersionTimedOut $true -VersionError 'simulated version timeout' -SourceOk $false -SourceExitCode $null -SourceTimedOut $false -SourceHasWinget $false -SourceError $null -SourceOutput $null
        }
        'source_failed' {
            return New-WingetDiscovery -CommandFound $true -CommandPath 'C:\Test\winget.exe' -VersionOk $true -Version 'v1.0.0-test' -VersionExitCode 0 -VersionTimedOut $false -VersionError $null -SourceOk $false -SourceExitCode 1 -SourceTimedOut $false -SourceHasWinget $false -SourceError 'simulated source failure' -SourceOutput $null
        }
        'source_timeout' {
            return New-WingetDiscovery -CommandFound $true -CommandPath 'C:\Test\winget.exe' -VersionOk $true -Version 'v1.0.0-test' -VersionExitCode 0 -VersionTimedOut $false -VersionError $null -SourceOk $false -SourceExitCode $null -SourceTimedOut $true -SourceHasWinget $false -SourceError 'simulated source timeout' -SourceOutput $null
        }
        'source_missing' {
            return New-WingetDiscovery -CommandFound $true -CommandPath 'C:\Test\winget.exe' -VersionOk $true -Version 'v1.0.0-test' -VersionExitCode 0 -VersionTimedOut $false -VersionError $null -SourceOk $false -SourceExitCode 0 -SourceTimedOut $false -SourceHasWinget $false -SourceError $null -SourceOutput 'msstore https://storeedgefd.dsx.mp.microsoft.com/v9.0'
        }
        'source_untrusted' {
            return New-WingetDiscovery -CommandFound $true -CommandPath 'C:\Test\winget.exe' -VersionOk $true -Version 'v1.0.0-test' -VersionExitCode 0 -VersionTimedOut $false -VersionError $null -SourceOk $false -SourceExitCode 0 -SourceTimedOut $false -SourceHasWinget $false -SourceError $null -SourceOutput 'winget https://example.invalid/cache'
        }
    }

    throw "Unknown winget test scenario: $Scenario"
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

function Test-WingetSourceOutput {
    param([string] $SourceOutput)

    if ([string]::IsNullOrWhiteSpace($SourceOutput)) {
        return $false
    }
    return ($SourceOutput -match '(?im)^\s*winget\s+https://cdn\.winget\.microsoft\.com/cache(?:\s|$)')
}

function Get-RealWingetDiscovery {
    $command = Get-Command winget.exe -ErrorAction SilentlyContinue
    if ($null -eq $command) {
        return New-WingetDiscovery -CommandFound $false -CommandPath $null -VersionOk $false -Version $null -VersionExitCode $null -VersionTimedOut $false -VersionError $null -SourceOk $false -SourceExitCode $null -SourceTimedOut $false -SourceHasWinget $false -SourceError $null -SourceOutput $null
    }

    $versionProbe = Invoke-ProbeCommand -FilePath $command.Source -Arguments @('--version')
    $sourceProbe = Invoke-ProbeCommand -FilePath $command.Source -Arguments @('source', 'list')
    $sourceHasWinget = $sourceProbe.ok -and (Test-WingetSourceOutput -SourceOutput $sourceProbe.stdout)

    return New-WingetDiscovery -CommandFound $true -CommandPath $command.Source -VersionOk $versionProbe.ok -Version $versionProbe.stdout -VersionExitCode $versionProbe.exitCode -VersionTimedOut $versionProbe.timedOut -VersionError $versionProbe.stderr -SourceOk ($sourceProbe.ok -and $sourceHasWinget) -SourceExitCode $sourceProbe.exitCode -SourceTimedOut $sourceProbe.timedOut -SourceHasWinget $sourceHasWinget -SourceError $sourceProbe.stderr -SourceOutput $sourceProbe.stdout
}

function Get-WingetDiscovery {
    param([string] $Scenario = 'none')

    if ($Scenario -eq 'none') {
        return Get-RealWingetDiscovery
    }
    if ($Scenario -eq 'helper_failed') {
        throw 'simulated helper failure'
    }
    return Get-TestWingetDiscovery -Scenario $Scenario
}

function Get-WingetDecision {
    param($Discovery)

    if (-not $Discovery.commandFound) {
        return [pscustomobject] @{
            status = 'missing'
            decision = 'install'
            reason = '未发现 winget.exe，后续版本应进入 App Installer 安装路径。'
            nextAction = '当前样板只报告 install 决策，不执行安装。'
            exitCode = 0
        }
    }

    if (-not $Discovery.versionOk) {
        return [pscustomobject] @{
            status = 'command_broken'
            decision = 'repair'
            reason = '已发现 winget.exe，但 winget --version 无法正常返回。'
            nextAction = '当前样板只报告 repair 决策，不执行修复。'
            exitCode = 0
        }
    }

    if (-not $Discovery.sourceOk) {
        return [pscustomobject] @{
            status = 'source_broken'
            decision = 'repair'
            reason = 'winget 可运行，但 winget source list 未能确认官方 winget source 可用。'
            nextAction = '当前样板只报告 repair 决策，不执行 source 修复。'
            exitCode = 0
        }
    }

    return [pscustomobject] @{
        status = 'healthy'
        decision = 'skip'
        reason = 'winget 命令、版本输出和官方 source 检查均可用。'
        nextAction = '继续后续 Git checkpoint。'
        exitCode = 0
    }
}

function New-WingetResult {
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

function Write-WingetTextResult {
    param($Result)

    Write-Host '[winget checkpoint]'
    Write-Field 'flow' $Result.flow
    Write-Field 'checkpoint' $Result.checkpoint
    Write-Field 'mutationAllowed' ([string] $Result.mutationAllowed)
    Write-Field 'sampleMode' $Result.sampleMode
    Write-Field 'actionMode' $Result.actionMode
    Write-Field 'outputMode' $Result.outputMode
    Write-Field 'testScenario' $Result.testScenario
    Write-Field 'probeTimeoutSeconds' ([string] $Result.probeTimeoutSeconds)
    Write-Field 'exitCodeContract' $Result.exitCodeContract
    Write-Host '当前样板只做发现、诊断和决策，不会安装、修复或改写系统。'

    if ($null -ne $Result.discovery) {
        Write-Section 'discovery'
        Write-Field 'commandFound' ([string] $Result.discovery.commandFound)
        Write-Field 'commandPath' $Result.discovery.commandPath
        Write-Field 'versionOk' ([string] $Result.discovery.versionOk)
        Write-Field 'version' $Result.discovery.version
        Write-Field 'versionTimedOut' ([string] $Result.discovery.versionTimedOut)
        Write-Field 'sourceOk' ([string] $Result.discovery.sourceOk)
        Write-Field 'sourceTimedOut' ([string] $Result.discovery.sourceTimedOut)
        Write-Field 'sourceHasWinget' ([string] $Result.discovery.sourceHasWinget)

        if (-not [string]::IsNullOrWhiteSpace($Result.discovery.versionError)) {
            Write-Field 'versionError' $Result.discovery.versionError
        }
        if (-not [string]::IsNullOrWhiteSpace($Result.discovery.sourceError)) {
            Write-Field 'sourceError' $Result.discovery.sourceError
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
        throw 'winget result contract violation: result is null'
    }
    if ($null -eq $Result.decision) {
        throw 'winget result contract violation: decision is null'
    }
    if ($script:AllowedStatuses -notcontains $Result.decision.status) {
        throw "winget result contract violation: unsupported status '$($Result.decision.status)'"
    }
    if ($script:AllowedDecisions -notcontains $Result.decision.decision) {
        throw "winget result contract violation: unsupported decision '$($Result.decision.decision)'"
    }
    if ($Result.decision.status -eq 'helper_failed') {
        if ($Result.decision.exitCode -ne $script:HelperFailureExitCode) {
            throw 'winget result contract violation: helper failure exit code must be 70'
        }
        return
    }
    if ($Result.decision.exitCode -ne $script:DecisionReportExitCode) {
        throw 'winget result contract violation: decision report exit code must be 0'
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

function Write-WingetResultFile {
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
        throw "winget result file write failed: $($_.Exception.Message)"
    }
}

function Write-WingetResult {
    param(
        $Result,
        [switch] $SkipResultFile
    )

    Test-ResultContract -Result $Result
    if (-not $SkipResultFile) {
        Write-WingetResultFile -Result $Result
    }

    if ($OutputMode -eq 'Json') {
        ConvertTo-JsonText -Value $Result
        return
    }

    Write-WingetTextResult -Result $Result
}

try {
    $discovery = Get-WingetDiscovery -Scenario $TestScenario
    $decision = Get-WingetDecision -Discovery $discovery
    $result = New-WingetResult -Discovery $discovery -Decision $decision
    Write-WingetResult -Result $result
    exit $decision.exitCode
} catch {
    $result = New-HelperFailureResult -Reason $_.Exception.Message
    try {
        Write-WingetResult -Result $result
    } catch {
        $fallbackResult = New-HelperFailureResult -Reason $_.Exception.Message
        Write-WingetResult -Result $fallbackResult -SkipResultFile
    }
    exit $script:HelperFailureExitCode
}
