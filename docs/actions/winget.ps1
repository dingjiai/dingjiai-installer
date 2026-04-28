param(
    [ValidateSet('ensure')]
    [string] $Action = 'ensure',
    [string] $FlowName = 'install',
    [string] $CheckpointName = 'winget',
    [switch] $AllowMutation,
    [ValidateSet('Text', 'Json')]
    [string] $OutputMode = 'Text',
    [ValidateSet('none', 'healthy', 'missing', 'appx_unavailable', 'version_failed', 'version_timeout', 'source_failed', 'source_timeout', 'source_missing', 'source_untrusted', 'helper_failed')]
    [string] $TestScenario = 'none',
    [string] $ResultPath
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8
$script:ContractVersion = 'checkpoint.v1'
$script:ComponentName = 'winget'
$script:ProbeTimeoutSeconds = 15
$script:HelperFailureExitCode = 70
$script:SampleMode = 'discovery-diagnose-decision-only'
$script:ActionMode = 'report-only'
$script:AllowedStatuses = @('healthy', 'missing', 'appx_deployment_unavailable', 'command_broken', 'command_timeout', 'source_broken', 'source_timeout', 'source_missing', 'source_untrusted', 'helper_failed')
$script:AllowedDecisions = @('skip', 'install', 'repair', 'abort')
$script:DecisionReportExitCode = 0
$script:DependencyBlockerExitCode = 60
$script:OfficialWingetSourceUrl = 'https://cdn.winget.microsoft.com/cache'

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

function Test-CurrentProcessAdmin {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Test-WindowsAppsPath {
    param([string] $Path)

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return $false
    }
    return $Path.EndsWith('\WindowsApps\winget.exe', [StringComparison]::OrdinalIgnoreCase)
}

function Get-ProjectLocalRoot {
    $localAppData = [Environment]::GetFolderPath('LocalApplicationData')
    if ([string]::IsNullOrWhiteSpace($localAppData)) {
        $localAppData = $env:TEMP
    }
    return (Join-Path $localAppData 'dingjiai-installer')
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

function Get-AppxDeploymentFacts {
    $addAppxPackage = Get-Command Add-AppxPackage -ErrorAction SilentlyContinue
    $appxService = Get-Service AppXSvc -ErrorAction SilentlyContinue
    $osBuild = [Environment]::OSVersion.Version.Build
    $architecture = if ([Environment]::Is64BitOperatingSystem) { 'x64' } else { 'x86' }
    $appxServiceFound = ($null -ne $appxService)
    $addAppxPackageFound = ($null -ne $addAppxPackage)
    $osBuildSupported = ($osBuild -ge 17763)

    return [pscustomobject] @{
        addAppxPackageFound = $addAppxPackageFound
        appxServiceFound = $appxServiceFound
        appxServiceStatus = if ($appxServiceFound) { $appxService.Status.ToString() } else { $null }
        osBuild = $osBuild
        osBuildSupported = $osBuildSupported
        architecture = $architecture
        repairLikelySupported = ($addAppxPackageFound -and $appxServiceFound -and $osBuildSupported -and [Environment]::Is64BitOperatingSystem)
    }
}

function New-AppxDeploymentFacts {
    param(
        [bool] $AddAppxPackageFound,
        [bool] $AppxServiceFound,
        [string] $AppxServiceStatus,
        [int] $OsBuild,
        [bool] $OsBuildSupported,
        [string] $Architecture,
        [bool] $RepairLikelySupported
    )

    return [pscustomobject] @{
        addAppxPackageFound = $AddAppxPackageFound
        appxServiceFound = $AppxServiceFound
        appxServiceStatus = $AppxServiceStatus
        osBuild = $OsBuild
        osBuildSupported = $OsBuildSupported
        architecture = $Architecture
        repairLikelySupported = $RepairLikelySupported
    }
}

function Get-WingetSourceFacts {
    param([string] $SourceOutput)

    $expectedUrl = $script:OfficialWingetSourceUrl
    $facts = [ordered] @{
        parsed = $false
        found = $false
        nameMatched = $false
        urlMatched = $false
        expectedUrls = @($expectedUrl)
        actualName = $null
        actualUrl = $null
    }

    if ([string]::IsNullOrWhiteSpace($SourceOutput)) {
        return [pscustomobject] $facts
    }

    foreach ($line in ($SourceOutput -split "`r?`n")) {
        $match = [regex]::Match($line, '^\s*(\S+)\s+(https?://\S+)', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
        if (-not $match.Success) {
            continue
        }

        $facts.parsed = $true
        $name = $match.Groups[1].Value
        $url = $match.Groups[2].Value
        if ($name -ieq 'winget') {
            $facts.nameMatched = $true
            $facts.actualName = $name
            $facts.actualUrl = $url
            if ($url -ieq $expectedUrl) {
                $facts.found = $true
                $facts.urlMatched = $true
                break
            }
        }
    }

    return [pscustomobject] $facts
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
        [string] $SourceOutput,
        $AppxDeployment
    )

    $officialSource = Get-WingetSourceFacts -SourceOutput $SourceOutput
    $appxDeployment = if ($null -ne $AppxDeployment) { $AppxDeployment } else { Get-AppxDeploymentFacts }

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
        environment = [pscustomobject] @{
            osBuild = [Environment]::OSVersion.Version.Build
            is64BitOperatingSystem = [Environment]::Is64BitOperatingSystem
            is64BitProcess = [Environment]::Is64BitProcess
            isAdmin = Test-CurrentProcessAdmin
            languageMode = $ExecutionContext.SessionState.LanguageMode.ToString()
        }
        command = [pscustomobject] @{
            found = $CommandFound
            path = $CommandPath
            isWindowsAppsPath = Test-WindowsAppsPath -Path $CommandPath
            resolvedByGetCommand = $CommandFound
        }
        versionProbe = [pscustomobject] @{
            attempted = $CommandFound
            ok = $VersionOk
            exitCode = $VersionExitCode
            timedOut = $VersionTimedOut
            stdout = $Version
            stderr = $VersionError
        }
        sourceProbe = [pscustomobject] @{
            attempted = $CommandFound
            ok = ($null -ne $SourceExitCode -and $SourceExitCode -eq 0 -and -not $SourceTimedOut)
            exitCode = $SourceExitCode
            timedOut = $SourceTimedOut
            stdout = $SourceOutput
            stderr = $SourceError
        }
        officialSource = $officialSource
        appxDeployment = $appxDeployment
    }
}

function Get-TestWingetDiscovery {
    param([string] $Scenario)

    switch ($Scenario) {
        'healthy' {
            return New-WingetDiscovery -CommandFound $true -CommandPath 'C:\Test\winget.exe' -VersionOk $true -Version 'v1.0.0-test' -VersionExitCode 0 -VersionTimedOut $false -VersionError $null -SourceOk $true -SourceExitCode 0 -SourceTimedOut $false -SourceHasWinget $true -SourceError $null -SourceOutput 'winget https://cdn.winget.microsoft.com/cache'
        }
        'missing' {
            return New-WingetDiscovery -CommandFound $false -CommandPath $null -VersionOk $false -Version $null -VersionExitCode $null -VersionTimedOut $false -VersionError $null -SourceOk $false -SourceExitCode $null -SourceTimedOut $false -SourceHasWinget $false -SourceError $null -SourceOutput $null -AppxDeployment (New-AppxDeploymentFacts -AddAppxPackageFound $true -AppxServiceFound $true -AppxServiceStatus 'Running' -OsBuild 17763 -OsBuildSupported $true -Architecture 'x64' -RepairLikelySupported $true)
        }
        'appx_unavailable' {
            return New-WingetDiscovery -CommandFound $false -CommandPath $null -VersionOk $false -Version $null -VersionExitCode $null -VersionTimedOut $false -VersionError $null -SourceOk $false -SourceExitCode $null -SourceTimedOut $false -SourceHasWinget $false -SourceError $null -SourceOutput $null -AppxDeployment (New-AppxDeploymentFacts -AddAppxPackageFound $false -AppxServiceFound $false -AppxServiceStatus $null -OsBuild 17762 -OsBuildSupported $false -Architecture 'x64' -RepairLikelySupported $false)
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

function Get-TestScenarioExpectation {
    param([string] $Scenario)

    switch ($Scenario) {
        'healthy' {
            return [pscustomobject] @{ status = 'healthy'; decision = 'skip'; exitCode = 0; commandFound = $true; versionOk = $true; versionTimedOut = $false; sourceOk = $true; sourceExitCode = 0; sourceTimedOut = $false; officialSourceFound = $true; officialSourceNameMatched = $true; officialSourceUrlMatched = $true }
        }
        'missing' {
            return [pscustomobject] @{ status = 'missing'; decision = 'install'; exitCode = $script:DependencyBlockerExitCode; commandFound = $false; versionOk = $false; versionTimedOut = $false; sourceOk = $false; sourceExitCode = $null; sourceTimedOut = $false; officialSourceFound = $false; officialSourceNameMatched = $false; officialSourceUrlMatched = $false; appxRepairLikelySupported = $true }
        }
        'appx_unavailable' {
            return [pscustomobject] @{ status = 'appx_deployment_unavailable'; decision = 'abort'; exitCode = $script:DependencyBlockerExitCode; commandFound = $false; versionOk = $false; versionTimedOut = $false; sourceOk = $false; sourceExitCode = $null; sourceTimedOut = $false; officialSourceFound = $false; officialSourceNameMatched = $false; officialSourceUrlMatched = $false; appxRepairLikelySupported = $false }
        }
        'version_failed' {
            return [pscustomobject] @{ status = 'command_broken'; decision = 'repair'; exitCode = $script:DependencyBlockerExitCode; commandFound = $true; versionOk = $false; versionTimedOut = $false; sourceOk = $false; sourceExitCode = $null; sourceTimedOut = $false; officialSourceFound = $false; officialSourceNameMatched = $false; officialSourceUrlMatched = $false }
        }
        'version_timeout' {
            return [pscustomobject] @{ status = 'command_timeout'; decision = 'repair'; exitCode = $script:DependencyBlockerExitCode; commandFound = $true; versionOk = $false; versionTimedOut = $true; sourceOk = $false; sourceExitCode = $null; sourceTimedOut = $false; officialSourceFound = $false; officialSourceNameMatched = $false; officialSourceUrlMatched = $false }
        }
        'source_failed' {
            return [pscustomobject] @{ status = 'source_broken'; decision = 'repair'; exitCode = $script:DependencyBlockerExitCode; commandFound = $true; versionOk = $true; versionTimedOut = $false; sourceOk = $false; sourceExitCode = 1; sourceTimedOut = $false; officialSourceFound = $false; officialSourceNameMatched = $false; officialSourceUrlMatched = $false }
        }
        'source_timeout' {
            return [pscustomobject] @{ status = 'source_timeout'; decision = 'repair'; exitCode = $script:DependencyBlockerExitCode; commandFound = $true; versionOk = $true; versionTimedOut = $false; sourceOk = $false; sourceExitCode = $null; sourceTimedOut = $true; officialSourceFound = $false; officialSourceNameMatched = $false; officialSourceUrlMatched = $false }
        }
        'source_missing' {
            return [pscustomobject] @{ status = 'source_missing'; decision = 'repair'; exitCode = $script:DependencyBlockerExitCode; commandFound = $true; versionOk = $true; versionTimedOut = $false; sourceOk = $false; sourceExitCode = 0; sourceTimedOut = $false; officialSourceFound = $false; officialSourceNameMatched = $false; officialSourceUrlMatched = $false }
        }
        'source_untrusted' {
            return [pscustomobject] @{ status = 'source_untrusted'; decision = 'repair'; exitCode = $script:DependencyBlockerExitCode; commandFound = $true; versionOk = $true; versionTimedOut = $false; sourceOk = $false; sourceExitCode = 0; sourceTimedOut = $false; officialSourceFound = $false; officialSourceNameMatched = $true; officialSourceUrlMatched = $false }
        }
    }

    throw "Unknown winget test scenario expectation: $Scenario"
}

function Assert-EqualValue {
    param(
        [string] $Name,
        $Actual,
        $Expected
    )

    if ($Actual -ne $Expected) {
        throw "winget test scenario contract violation: $Name expected '$Expected' but got '$Actual'"
    }
}

function Test-TestScenarioContract {
    param($Result)

    if ($TestScenario -eq 'none' -or $TestScenario -eq 'helper_failed' -or $Result.decision.status -eq 'helper_failed') {
        return
    }

    $expected = Get-TestScenarioExpectation -Scenario $TestScenario
    Assert-EqualValue -Name 'decision.status' -Actual $Result.decision.status -Expected $expected.status
    Assert-EqualValue -Name 'decision.decision' -Actual $Result.decision.decision -Expected $expected.decision
    Assert-EqualValue -Name 'decision.exitCode' -Actual $Result.decision.exitCode -Expected $expected.exitCode
    Assert-EqualValue -Name 'discovery.commandFound' -Actual $Result.discovery.commandFound -Expected $expected.commandFound
    Assert-EqualValue -Name 'discovery.versionOk' -Actual $Result.discovery.versionOk -Expected $expected.versionOk
    Assert-EqualValue -Name 'discovery.versionTimedOut' -Actual $Result.discovery.versionTimedOut -Expected $expected.versionTimedOut
    Assert-EqualValue -Name 'discovery.sourceOk' -Actual $Result.discovery.sourceOk -Expected $expected.sourceOk
    Assert-EqualValue -Name 'discovery.sourceExitCode' -Actual $Result.discovery.sourceExitCode -Expected $expected.sourceExitCode
    Assert-EqualValue -Name 'discovery.sourceTimedOut' -Actual $Result.discovery.sourceTimedOut -Expected $expected.sourceTimedOut
    Assert-EqualValue -Name 'discovery.officialSource.found' -Actual $Result.discovery.officialSource.found -Expected $expected.officialSourceFound
    Assert-EqualValue -Name 'discovery.officialSource.nameMatched' -Actual $Result.discovery.officialSource.nameMatched -Expected $expected.officialSourceNameMatched
    Assert-EqualValue -Name 'discovery.officialSource.urlMatched' -Actual $Result.discovery.officialSource.urlMatched -Expected $expected.officialSourceUrlMatched
    if ($null -ne $expected.PSObject.Properties['appxRepairLikelySupported']) {
        Assert-EqualValue -Name 'discovery.appxDeployment.repairLikelySupported' -Actual $Result.discovery.appxDeployment.repairLikelySupported -Expected $expected.appxRepairLikelySupported
    }
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
            return New-ProbeResult -Ok $false -ExitCode $null -TimedOut $true -Stdout $stdoutBuilder.ToString().Trim() -Stderr "命令超时 $TimeoutSeconds 秒未返回。"
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

    $facts = Get-WingetSourceFacts -SourceOutput $SourceOutput
    return [bool] ($facts.nameMatched -and $facts.urlMatched)
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
        if (-not $Discovery.appxDeployment.repairLikelySupported) {
            return [pscustomobject] @{
                status = 'appx_deployment_unavailable'
                decision = 'abort'
                reason = '未发现 winget.exe，且当前系统缺少 Windows 应用部署能力，无法自动安装 winget。'
                nextAction = '建议使用纯净版 Windows，或手动修复 Appx/App Installer 组件后重试。'
                exitCode = $script:DependencyBlockerExitCode
            }
        }

        return [pscustomobject] @{
            status = 'missing'
            decision = 'install'
            reason = '未发现 winget.exe，但当前系统具备 App Installer 修复基础能力。'
            nextAction = '后续版本可进入 App Installer 依赖下载与安装路径；当前样板不执行安装。'
            exitCode = $script:DependencyBlockerExitCode
        }
    }

    if (-not $Discovery.versionOk) {
        if ($Discovery.versionTimedOut) {
            return [pscustomobject] @{
                status = 'command_timeout'
                decision = 'repair'
                reason = '已发现 winget.exe，但 winget --version 在超时时间内没有返回。'
                nextAction = '当前样板只报告 repair 决策，不执行修复。'
                exitCode = $script:DependencyBlockerExitCode
            }
        }

        return [pscustomobject] @{
            status = 'command_broken'
            decision = 'repair'
            reason = '已发现 winget.exe，但 winget --version 无法正常返回。'
            nextAction = '当前样板只报告 repair 决策，不执行修复。'
            exitCode = $script:DependencyBlockerExitCode
        }
    }

    if (-not $Discovery.sourceOk) {
        if ($Discovery.sourceTimedOut) {
            return [pscustomobject] @{
                status = 'source_timeout'
                decision = 'repair'
                reason = 'winget 可运行，但 winget source list 在超时时间内没有返回。'
                nextAction = '当前样板只报告 repair 决策，不执行 source 修复。'
                exitCode = $script:DependencyBlockerExitCode
            }
        }

        if ($null -ne $Discovery.sourceExitCode -and $Discovery.sourceExitCode -ne 0) {
            return [pscustomobject] @{
                status = 'source_broken'
                decision = 'repair'
                reason = 'winget 可运行，但 winget source list 返回失败。'
                nextAction = '当前样板只报告 repair 决策，不执行 source 修复。'
                exitCode = $script:DependencyBlockerExitCode
            }
        }

        if ($Discovery.officialSource.nameMatched -and -not $Discovery.officialSource.urlMatched) {
            return [pscustomobject] @{
                status = 'source_untrusted'
                decision = 'repair'
                reason = 'winget source list 中存在 winget source，但 URL 不是项目认可的官方地址。'
                nextAction = '当前样板只报告 repair 决策，不执行 source reset 或 add。'
                exitCode = $script:DependencyBlockerExitCode
            }
        }

        return [pscustomobject] @{
            status = 'source_missing'
            decision = 'repair'
            reason = 'winget 可运行，但 winget source list 未发现项目认可的官方 winget source。'
            nextAction = '当前样板只报告 repair 决策，不执行 source 添加。'
            exitCode = $script:DependencyBlockerExitCode
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

function New-ExitCodeContract {
    return [pscustomobject] @{
        healthy = $script:DecisionReportExitCode
        dependencyBlocker = $script:DependencyBlockerExitCode
        helperFailure = $script:HelperFailureExitCode
    }
}

function New-WingetDiagnosis {
    param($Decision)

    return [pscustomobject] @{
        status = $Decision.status
        reason = $Decision.reason
    }
}

function New-WingetActionContract {
    return [pscustomobject] @{
        supported = $false
        attempted = $false
        mutationAllowed = [bool] $AllowMutation
        reason = 'current checkpoint is report-only'
    }
}

function New-WingetValidationContract {
    return [pscustomobject] @{
        contractOk = $true
        violations = @()
    }
}

function New-WingetAuditContract {
    return [pscustomobject] @{
        helper = 'winget.ps1'
        resultPath = $ResultPath
    }
}

function New-WingetResult {
    param(
        $Discovery,
        $Decision
    )

    return [pscustomobject] @{
        contractVersion = $script:ContractVersion
        flow = $FlowName
        checkpoint = $CheckpointName
        component = $script:ComponentName
        mutationAllowed = [bool] $AllowMutation
        sampleMode = $script:SampleMode
        actionMode = $script:ActionMode
        outputMode = $OutputMode
        testScenario = $TestScenario
        probeTimeoutSeconds = $script:ProbeTimeoutSeconds
        exitCodeContract = New-ExitCodeContract
        discovery = $Discovery
        diagnosis = New-WingetDiagnosis -Decision $Decision
        decision = $Decision
        action = New-WingetActionContract
        validation = New-WingetValidationContract
        audit = New-WingetAuditContract
    }
}

function New-HelperFailureResult {
    param([string] $Reason)

    $decision = [pscustomobject] @{
        status = 'helper_failed'
        decision = 'abort'
        reason = $Reason
        nextAction = '查看辅助脚本失败信息，修复脚本或运行环境问题。'
        exitCode = $script:HelperFailureExitCode
    }

    return [pscustomobject] @{
        contractVersion = $script:ContractVersion
        flow = $FlowName
        checkpoint = $CheckpointName
        component = $script:ComponentName
        mutationAllowed = [bool] $AllowMutation
        sampleMode = $script:SampleMode
        actionMode = $script:ActionMode
        outputMode = $OutputMode
        testScenario = $TestScenario
        probeTimeoutSeconds = $script:ProbeTimeoutSeconds
        exitCodeContract = New-ExitCodeContract
        discovery = $null
        diagnosis = New-WingetDiagnosis -Decision $decision
        decision = $decision
        action = New-WingetActionContract
        validation = New-WingetValidationContract
        audit = New-WingetAuditContract
    }
}

function Write-WingetTextResult {
    param($Result)

    Write-Host '[winget checkpoint]'
    Write-Field 'contractVersion' $Result.contractVersion
    Write-Field 'flow' $Result.flow
    Write-Field 'checkpoint' $Result.checkpoint
    Write-Field 'component' $Result.component
    Write-Field 'mutationAllowed' ([string] $Result.mutationAllowed)
    Write-Field 'sampleMode' $Result.sampleMode
    Write-Field 'actionMode' $Result.actionMode
    Write-Field 'outputMode' $Result.outputMode
    Write-Field 'testScenario' $Result.testScenario
    Write-Field 'probeTimeoutSeconds' ([string] $Result.probeTimeoutSeconds)
    Write-Field 'healthyExitCode' ([string] $Result.exitCodeContract.healthy)
    Write-Field 'dependencyBlockerExitCode' ([string] $Result.exitCodeContract.dependencyBlocker)
    Write-Field 'helperFailureExitCode' ([string] $Result.exitCodeContract.helperFailure)
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
        Write-Field 'isAdmin' ([string] $Result.discovery.environment.isAdmin)
        Write-Field 'languageMode' $Result.discovery.environment.languageMode
        Write-Field 'isWindowsAppsPath' ([string] $Result.discovery.command.isWindowsAppsPath)
        Write-Field 'officialSourceFound' ([string] $Result.discovery.officialSource.found)
        Write-Field 'officialSourceNameMatched' ([string] $Result.discovery.officialSource.nameMatched)
        Write-Field 'officialSourceUrlMatched' ([string] $Result.discovery.officialSource.urlMatched)
        Write-Field 'officialSourceActualUrl' $Result.discovery.officialSource.actualUrl
        Write-Field 'addAppxPackageFound' ([string] $Result.discovery.appxDeployment.addAppxPackageFound)
        Write-Field 'appxServiceFound' ([string] $Result.discovery.appxDeployment.appxServiceFound)
        Write-Field 'appxServiceStatus' $Result.discovery.appxDeployment.appxServiceStatus
        Write-Field 'appxRepairLikelySupported' ([string] $Result.discovery.appxDeployment.repairLikelySupported)

        if (-not [string]::IsNullOrWhiteSpace($Result.discovery.versionError)) {
            Write-Field 'versionError' $Result.discovery.versionError
        }
        if (-not [string]::IsNullOrWhiteSpace($Result.discovery.sourceError)) {
            Write-Field 'sourceError' $Result.discovery.sourceError
        }
    }

    Write-Section 'diagnosis'
    Write-Field 'status' $Result.diagnosis.status
    Write-Field 'reason' $Result.diagnosis.reason

    Write-Section 'decision'
    Write-Field 'status' $Result.decision.status
    Write-Field 'decision' $Result.decision.decision
    Write-Field 'reason' $Result.decision.reason
    Write-Field 'nextAction' $Result.decision.nextAction

    Write-Section 'action'
    Write-Field 'supported' ([string] $Result.action.supported)
    Write-Field 'attempted' ([string] $Result.action.attempted)
    Write-Field 'mutationAllowed' ([string] $Result.action.mutationAllowed)
    Write-Field 'reason' $Result.action.reason

    Write-Section 'validation'
    Write-Field 'contractOk' ([string] $Result.validation.contractOk)
    Write-Host ''
}

function Test-ResultContract {
    param($Result)

    if ($null -eq $Result) {
        throw 'winget result contract violation: result is null'
    }
    if ($Result.contractVersion -ne $script:ContractVersion) {
        throw 'winget result contract violation: unsupported contract version'
    }
    if ($Result.component -ne $script:ComponentName) {
        throw 'winget result contract violation: unsupported component'
    }
    if ($null -eq $Result.exitCodeContract) {
        throw 'winget result contract violation: exit code contract is null'
    }
    if ($Result.exitCodeContract.healthy -ne $script:DecisionReportExitCode) {
        throw 'winget result contract violation: healthy exit code contract must be 0'
    }
    if ($Result.exitCodeContract.dependencyBlocker -ne $script:DependencyBlockerExitCode) {
        throw 'winget result contract violation: dependency blocker exit code contract must be 60'
    }
    if ($Result.exitCodeContract.helperFailure -ne $script:HelperFailureExitCode) {
        throw 'winget result contract violation: helper failure exit code contract must be 70'
    }
    if ($null -eq $Result.diagnosis) {
        throw 'winget result contract violation: diagnosis is null'
    }
    if ($null -eq $Result.decision) {
        throw 'winget result contract violation: decision is null'
    }
    if ($null -eq $Result.action) {
        throw 'winget result contract violation: action is null'
    }
    if ($Result.action.supported -ne $false -or $Result.action.attempted -ne $false) {
        throw 'winget result contract violation: report-only action must not be supported or attempted'
    }
    if ($null -eq $Result.validation) {
        throw 'winget result contract violation: validation is null'
    }
    if ($Result.validation.contractOk -ne $true) {
        throw 'winget result contract violation: validation contractOk must be true before output'
    }
    if ($null -eq $Result.audit) {
        throw 'winget result contract violation: audit is null'
    }
    if ($Result.decision.status -ne 'helper_failed') {
        if ($null -eq $Result.discovery) {
            throw 'winget result contract violation: discovery is null'
        }
        foreach ($section in @('environment', 'command', 'versionProbe', 'sourceProbe', 'officialSource', 'appxDeployment')) {
            if ($null -eq $Result.discovery.$section) {
                throw "winget result contract violation: discovery.$section is null"
            }
        }
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
    if ($Result.decision.status -eq 'healthy') {
        if ($Result.decision.exitCode -ne $script:DecisionReportExitCode) {
            throw 'winget result contract violation: healthy exit code must be 0'
        }
        return
    }
    if ($Result.decision.exitCode -ne $script:DependencyBlockerExitCode) {
        throw 'winget result contract violation: dependency blocker exit code must be 60'
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
        $projectLocalRoot = Get-ProjectLocalRoot
        if (-not (Test-PathInsideRoot -Path $ResultPath -Root $projectLocalRoot)) {
            throw "winget result path must stay under $projectLocalRoot"
        }

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
    Test-TestScenarioContract -Result $Result
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
