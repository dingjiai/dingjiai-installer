$ErrorActionPreference = 'Stop'

$script:BootstrapVersion = '0.1.0-startup.1'
$script:StartedAt = (Get-Date).ToString('o')
$existingStartupId = [Environment]::GetEnvironmentVariable('DINGJIAI_STARTUP_ID', 'Process')
$script:StartupId = if ([string]::IsNullOrWhiteSpace($existingStartupId)) { [guid]::NewGuid().ToString('N') } else { $existingStartupId }
$script:IsRemoteRun = [string]::IsNullOrWhiteSpace($MyInvocation.MyCommand.Path)
$script:BootstrapSource = if ($script:IsRemoteRun) { 'remote-win-ps1' } else { 'local-win-ps1' }
$script:BootstrapRoot = if ($script:IsRemoteRun) { $null } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$script:LocalPayloadSourceRoot = if ($script:BootstrapRoot) { Join-Path $script:BootstrapRoot 'installer\windows' } else { $null }
$script:BaseUrl = 'https://get.dingjiai.com/installer/windows'
$script:WorkspaceRoot = Join-Path $env:LOCALAPPDATA 'dingjiai-installer'
$script:PayloadRoot = Join-Path $script:WorkspaceRoot 'payload'
$script:StagingRoot = Join-Path $script:WorkspaceRoot 'staging'
$script:CacheRoot = Join-Path $script:WorkspaceRoot 'cache'
$script:TempRoot = Join-Path $script:WorkspaceRoot 'temp'
$script:StateRoot = Join-Path $script:WorkspaceRoot 'state'
$script:LogRoot = Join-Path $script:WorkspaceRoot 'logs'
$script:ManifestPath = Join-Path $script:WorkspaceRoot 'manifest.json'
$script:StatePath = Join-Path $script:StateRoot ("startup-$($script:StartupId).json")
$script:LogPath = Join-Path $script:LogRoot ("startup-$($script:StartupId).jsonl")
$script:StartupChecks = @()
$script:ManifestRequestTimeoutSeconds = 15
$script:PayloadFileRequestTimeoutSeconds = 30
$script:ManifestDownloadRetryCount = 2
$script:PayloadFileDownloadRetryCount = 2
$script:WorkspaceCreationRetryCount = 1
$script:WorkspacePreparationTimeoutSeconds = 10
$script:TotalStartupBudgetSeconds = 180
$script:PowerShellRuntimeHealthRetryCount = 0
$script:UacHandoffAttemptCount = 1
$script:HandoffAcceptedWaitSeconds = 30
$script:HandoffAcceptedPollMilliseconds = 500
$script:PayloadHashMismatchRetryCount = 0
$script:PayloadRepairRebuildRetryCount = 1
$script:BitnessConvergenceRetryCount = 1
$script:HostNormalizationRetryCount = 1
$script:StartupStages = [ordered]@{
    HostNormalize = 'host-normalize'
    PlatformGate = 'platform-gate'
    Workspace = 'workspace'
    Payload = 'payload'
    Handoff = 'handoff'
    Completed = 'completed'
    Failed = 'failed'
}
$script:CurrentStage = $null
$script:HostNormalizeAttempted = ([Environment]::GetEnvironmentVariable('DINGJIAI_HOST_NORMALIZE_ATTEMPTED', 'Process') -eq '1')
$script:BitnessNormalizeAttempted = ([Environment]::GetEnvironmentVariable('DINGJIAI_BITNESS_NORMALIZE_ATTEMPTED', 'Process') -eq '1')
$script:HandoffAttempted = $false
$script:HandoffAccepted = $false
$script:LastFailureStage = $null
$script:LastFailureReason = $null
$script:LastFailureMessage = $null
$script:MinimumPowerShellVersion = [version]'5.1'
$script:MinimumWindowsBuild = 17763

function Add-StartupCheck {
    param(
        [string] $Name,
        [string] $Status,
        [hashtable] $Detail = @{}
    )

    $check = [ordered]@{
        name = $Name
        status = $Status
        checkedAt = (Get-Date).ToString("o")
    }

    foreach ($key in $Detail.Keys) {
        $check[$key] = $Detail[$key]
    }

    $script:StartupChecks += $check
}

function Assert-StartupBudget {
    param([string] $Checkpoint)

    $elapsedSeconds = ((Get-Date) - ([datetime]$script:StartedAt)).TotalSeconds
    if ($elapsedSeconds -gt $script:TotalStartupBudgetSeconds) {
        Add-StartupCheck -Name 'startup_budget' -Status 'failed' -Detail @{
            checkpoint = $Checkpoint
            elapsedSeconds = [math]::Round($elapsedSeconds, 3)
            budgetSeconds = $script:TotalStartupBudgetSeconds
        }
        Stop-Startup -Reason 'startup_budget_exceeded' -Message '启动阶段超过 180 秒预算。'
    }

    Add-StartupCheck -Name 'startup_budget' -Status 'passed' -Detail @{
        checkpoint = $Checkpoint
        elapsedSeconds = [math]::Round($elapsedSeconds, 3)
        budgetSeconds = $script:TotalStartupBudgetSeconds
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

function Get-StartupFailureSuggestion {
    param([string] $Reason)

    switch ($Reason) {
        'not_windows' { return '请在 Windows 10 1809 或更新版本的电脑上重新运行启动命令。' }
        'windows_build_unsupported' { return '请升级到 Windows 10 1809 / Windows Server 2019 或更新版本后重试。' }
        'not_64_bit_os' { return '请换用 64 位 Windows 电脑后重试。' }
        'cannot_converge_64_bit' { return '请使用 Windows 自带 PowerShell，或从 64 位 PowerShell 窗口重新运行启动命令。' }
        'cannot_converge_64_bit_after_retry' { return '请关闭当前窗口，打开 Windows 自带 64 位 PowerShell 后重新运行启动命令。' }
        'cmd_missing' { return '请检查系统 cmd.exe 是否存在，或换用正常的 Windows 系统环境后重试。' }
        'powershell_version_unsupported' { return '请使用 Windows 10 1809+ 自带的 PowerShell 5.1，或使用 PowerShell 7 后重试。' }
        'powershell_language_mode_unsupported' { return '请换用正常的 PowerShell/CMD 窗口；如果这是公司电脑或受管设备，请检查脚本语言模式策略限制。' }
        'powershell_runtime_unhealthy' { return '请换用 Windows 自带 PowerShell 5.1 或 PowerShell 7 后重试。' }
        'powershell_runtime_capability_missing' { return '请换用完整的 Windows PowerShell 环境后重试。' }
        'workspace_preparation_timeout' { return '请稍后重试；如果仍失败，请检查本机磁盘、杀毒软件或 AppData 写入权限。' }
        'workspace_create_failed' { return '请确认当前用户可以写入 AppData，本地安全软件没有拦截文件创建。' }
        'manifest_read_failed' { return '请检查网络、代理或本地调试文件是否完整，然后重试。' }
        'manifest_schema_invalid' { return '请稍后重试；如果你在本地调试，请先运行 manifest/payload 自检。' }
        'payload_path_invalid' { return '请更新到最新启动器文件后重试；如果你在本地调试，请检查 manifest 中的 payload 路径。' }
        'payload_download_failed' { return '请检查网络、代理或本地调试 payload 文件是否完整，然后重试。' }
        'payload_hash_mismatch' { return '请重新运行启动命令；如果你在本地调试，请同步 manifest 中的 SHA-256 后运行自检。' }
        'entry_shape_invalid' { return '请更新到最新启动器文件后重试；如果你在本地调试，请检查 mainEntry 是否仍为 payload 内的 CMD 文件。' }
        'handoff_failed' { return '请确认你允许了 UAC 管理员权限弹窗；如果没有看到弹窗，请检查安全软件或从 Windows 自带 PowerShell 重新运行启动命令。' }
        'handoff_timeout' { return '请查看是否有管理员权限弹窗被隐藏；如果已弹出 CMD，请确认窗口没有被安全软件拦截。' }
        'startup_budget_exceeded' { return '请稍后重试；如果多次发生，请把日志路径发给维护者排查。' }
        default { return '请重新运行启动命令；如果仍失败，请把日志路径发给维护者排查。' }
    }
}

function Write-StartupFailureMessage {
    param(
        [string] $Reason,
        [string] $Message,
        [string] $Suggestion
    )

    Write-Host ''
    Write-Host 'dingjiai 启动失败'
    Write-Host ''
    Write-Host '原因：'
    Write-Host $Message
    Write-Host ''
    Write-Host '建议：'
    Write-Host $Suggestion
    Write-Host ''
    Write-Host '日志：'
    if (Test-Path -LiteralPath $script:LogRoot -PathType Container) {
        Write-Host $script:LogPath
    } else {
        Write-Host '启动失败发生在本地工作区日志目录创建之前，尚未生成日志文件。'
    }
}

function Get-NormalizedPath {
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

function Test-SamePath {
    param(
        [string] $Left,
        [string] $Right
    )

    $leftPath = Get-NormalizedPath -Path $Left
    $rightPath = Get-NormalizedPath -Path $Right
    if ($null -eq $leftPath -or $null -eq $rightPath) {
        return $false
    }

    return $leftPath.Equals($rightPath, [System.StringComparison]::OrdinalIgnoreCase)
}

function Test-PathInsideRoot {
    param(
        [string] $Path,
        [string] $Root
    )

    $normalizedPath = Get-NormalizedPath -Path $Path
    $normalizedRoot = Get-NormalizedPath -Path $Root
    if ($null -eq $normalizedPath -or $null -eq $normalizedRoot) {
        return $false
    }
    if ($normalizedPath.Equals($normalizedRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
        return $true
    }

    $rootWithSeparator = $normalizedRoot + [System.IO.Path]::DirectorySeparatorChar
    return $normalizedPath.StartsWith($rootWithSeparator, [System.StringComparison]::OrdinalIgnoreCase)
}

function Test-HandoffAcceptedState {
    param(
        $State,
        [string] $ExpectedMainEntryPath = $null
    )

    if ($null -eq $State) { return $false }
    if ($State.startupId -ne $script:StartupId) { return $false }
    if ($State.stage -ne $script:StartupStages.Completed) { return $false }
    if ($State.handoffAccepted -ne $true) { return $false }

    $mainEntryPath = if ([string]::IsNullOrWhiteSpace($ExpectedMainEntryPath)) { $State.mainEntryPath } else { $ExpectedMainEntryPath }
    if ([string]::IsNullOrWhiteSpace($mainEntryPath)) { return $false }

    if (-not (Test-SamePath -Left $State.acceptedWorkspaceRoot -Right $script:WorkspaceRoot)) { return $false }
    if (-not (Test-SamePath -Left $State.acceptedStatePath -Right $script:StatePath)) { return $false }
    if (-not (Test-SamePath -Left $State.acceptedLogPath -Right $script:LogPath)) { return $false }
    if (-not (Test-SamePath -Left $State.acceptedPayloadRoot -Right $script:PayloadRoot)) { return $false }
    if (-not (Test-SamePath -Left $State.acceptedMainEntryPath -Right $mainEntryPath)) { return $false }
    if ($State.acceptedSource -ne $script:BootstrapSource) { return $false }
    if ($State.acceptedHandoffMode -ne 'admin-cmd') { return $false }

    return $true
}

function Stop-Startup {
    param(
        [string] $Reason,
        [string] $Message
    )

    try {
        if (Test-Path -LiteralPath $script:StatePath) {
            $state = Get-Content -LiteralPath $script:StatePath -Raw | ConvertFrom-Json
            if (Test-HandoffAcceptedState -State $state) {
                $script:HandoffAccepted = $true
                Add-StartupCheck -Name 'failed_state_skipped' -Status 'skipped' -Detail @{ reason = 'handoff_already_accepted'; statePath = $script:StatePath; acceptedWorkspaceRoot = $state.acceptedWorkspaceRoot; acceptedPayloadRoot = $state.acceptedPayloadRoot; acceptedMainEntryPath = $state.acceptedMainEntryPath; acceptedHandoffMode = $state.acceptedHandoffMode }
                Write-Host '管理员 CMD 主窗口已接管。'
                exit 0
            }
        }
    } catch {
    }

    $script:LastFailureStage = if ($script:CurrentStage) { $script:CurrentStage } else { $script:StartupStages.Failed }
    $script:LastFailureReason = $Reason
    $script:LastFailureMessage = $Message
    $suggestion = Get-StartupFailureSuggestion -Reason $Reason

    Write-StartupState -Stage $script:StartupStages.Failed -Extra @{
        failureReason = $Reason
        failureMessage = $Message
        failureSuggestion = $suggestion
        failureLogPath = $script:LogPath
        failedAt = (Get-Date).ToString('o')
    }

    Write-StartupFailureMessage -Reason $Reason -Message $Message -Suggestion $suggestion
    exit 1
}

function Write-StartupState {
    param(
        [string] $Stage,
        [hashtable] $Extra = @{}
    )

    $script:CurrentStage = $Stage
    New-Item -ItemType Directory -Force -Path $script:StateRoot, $script:LogRoot | Out-Null

    $existingState = $null
    if (Test-Path -LiteralPath $script:StatePath) {
        try {
            $candidateState = Get-Content -LiteralPath $script:StatePath -Raw | ConvertFrom-Json
            if ($candidateState.startupId -eq $script:StartupId) {
                $existingState = $candidateState
            }
        } catch {
        }
    }

    $state = [ordered]@{
        startupId = $script:StartupId
        bootstrapVersion = $script:BootstrapVersion
        stage = $Stage
        startedAt = $script:StartedAt
        updatedAt = (Get-Date).ToString('o')
        workspaceRoot = $script:WorkspaceRoot
        payloadRoot = $script:PayloadRoot
        stagingRoot = $script:StagingRoot
        cacheRoot = $script:CacheRoot
        tempRoot = $script:TempRoot
        manifestPath = $script:ManifestPath
        source = $script:BootstrapSource
        hostNormalizeAttempted = $script:HostNormalizeAttempted
        bitnessNormalizeAttempted = $script:BitnessNormalizeAttempted
        handoffAttempted = $script:HandoffAttempted
        handoffAccepted = $script:HandoffAccepted
        lastFailureStage = $script:LastFailureStage
        lastFailureReason = $script:LastFailureReason
        lastFailureMessage = $script:LastFailureMessage
        checks = $script:StartupChecks
    }

    if ($null -ne $existingState) {
        foreach ($key in @('handoffAccepted', 'handoffAcceptedAt', 'acceptedWorkspaceRoot', 'acceptedStatePath', 'acceptedLogPath', 'acceptedPayloadRoot', 'acceptedMainEntryPath', 'acceptedSource', 'acceptedHandoffMode')) {
            $property = $existingState.PSObject.Properties[$key]
            if ($null -ne $property) {
                $state[$key] = $property.Value
            }
        }
    }

    foreach ($key in $Extra.Keys) {
        $state[$key] = $Extra[$key]
    }

    $stateJson = $state | ConvertTo-Json -Depth 8
    Write-AtomicTextFile -Path $script:StatePath -Value $stateJson

    $logEntry = [ordered]@{
        startupId = $script:StartupId
        stage = $Stage
        writtenAt = $state.updatedAt
        statePath = $script:StatePath
        logPath = $script:LogPath
        failureReason = $script:LastFailureReason
        failureMessage = $script:LastFailureMessage
        checkCount = $script:StartupChecks.Count
    }
    $logEntry | ConvertTo-Json -Depth 4 -Compress | Add-Content -LiteralPath $script:LogPath -Encoding UTF8
}

function Test-HostNormalization {
    $script:HostNormalizeAttempted = $true
    Write-StartupState -Stage $script:StartupStages.HostNormalize

    $attempt = 1
    $maxAttempts = $script:HostNormalizationRetryCount
    $processPath = (Get-Process -Id $PID).Path
    $hostName = $Host.Name
    $hostVersion = $Host.Version.ToString()
    $languageMode = $ExecutionContext.SessionState.LanguageMode.ToString()
    $requiresBitnessConvergence = [Environment]::Is64BitOperatingSystem -and -not [Environment]::Is64BitProcess
    $hostPolicy = 'accepted_bootstrap_host'
    $normalizationAction = if ($requiresBitnessConvergence) { 'defer_to_bitness_convergence' } else { 'continue' }

    if ($languageMode -ne 'FullLanguage') {
        Add-StartupCheck -Name 'host_normalization' -Status 'failed' -Detail @{
            policy = 'unsupported_language_mode'
            attempt = $attempt
            maxAttempts = $maxAttempts
            source = $script:BootstrapSource
            isRemoteRun = $script:IsRemoteRun
            bootstrapRoot = $script:BootstrapRoot
            shellId = $ShellId
            hostName = $hostName
            hostVersion = $hostVersion
            psVersion = $PSVersionTable.PSVersion.ToString()
            edition = $PSVersionTable.PSEdition
            languageMode = $languageMode
            processPath = $processPath
            entryRole = 'bootstrap-only'
            mainUiHost = 'admin-cmd'
            hostNormalizeAttempted = $script:HostNormalizeAttempted
            bitnessNormalizeAttempted = $script:BitnessNormalizeAttempted
        }
        Stop-Startup -Reason 'powershell_language_mode_unsupported' -Message '当前 PowerShell 语言模式不支持启动器运行。'
    }

    Add-StartupCheck -Name 'host_normalization' -Status 'passed' -Detail @{
        policy = $hostPolicy
        action = $normalizationAction
        attempt = $attempt
        maxAttempts = $maxAttempts
        source = $script:BootstrapSource
        isRemoteRun = $script:IsRemoteRun
        bootstrapRoot = $script:BootstrapRoot
        shellId = $ShellId
        hostName = $hostName
        hostVersion = $hostVersion
        psVersion = $PSVersionTable.PSVersion.ToString()
        edition = $PSVersionTable.PSEdition
        languageMode = $languageMode
        processPath = $processPath
        entryRole = 'bootstrap-only'
        acceptedEntryHosts = @('Windows PowerShell', 'PowerShell')
        mainUiHost = 'admin-cmd'
        hostNormalizeAttempted = $script:HostNormalizeAttempted
        bitnessNormalizeAttempted = $script:BitnessNormalizeAttempted
        is64BitOperatingSystem = [Environment]::Is64BitOperatingSystem
        is64BitProcess = [Environment]::Is64BitProcess
        requiresBitnessConvergence = $requiresBitnessConvergence
    }
}

function Test-TerminalCompatibility {
    $hostName = $Host.Name
    $hostVersion = $Host.Version.ToString()
    $rawUiAvailable = $false
    $windowTitle = $null

    try {
        $null = $Host.UI.RawUI
        $rawUiAvailable = $true
        $windowTitle = $Host.UI.RawUI.WindowTitle
    } catch {
        $rawUiAvailable = $false
    }

    Add-StartupCheck -Name 'terminal_compatibility' -Status 'passed' -Detail @{
        hostName = $hostName
        hostVersion = $hostVersion
        rawUiAvailable = $rawUiAvailable
        windowTitle = $windowTitle
        entryRole = 'bootstrap-only'
        mainUiHost = 'admin-cmd'
    }
}

function Test-SystemArchitectureMatrix {
    $cmdPath = Join-Path $env:WINDIR 'System32\cmd.exe'
    $sysnativePowerShell = Join-Path $env:WINDIR 'Sysnative\WindowsPowerShell\v1.0\powershell.exe'
    $system32PowerShell = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'

    Add-StartupCheck -Name 'system_architecture_matrix' -Status 'passed' -Detail @{
        os = $env:OS
        windir = $env:WINDIR
        processorArchitecture = $env:PROCESSOR_ARCHITECTURE
        processorArchitecture6432 = $env:PROCESSOR_ARCHITEW6432
        is64BitOperatingSystem = [Environment]::Is64BitOperatingSystem
        is64BitProcess = [Environment]::Is64BitProcess
        cmdPath = $cmdPath
        cmdExists = (Test-Path -LiteralPath $cmdPath)
        sysnativePowerShell = $sysnativePowerShell
        sysnativePowerShellExists = (Test-Path -LiteralPath $sysnativePowerShell)
        system32PowerShell = $system32PowerShell
        system32PowerShellExists = (Test-Path -LiteralPath $system32PowerShell)
    }
}

function Test-WindowsHost {
    if (-not $IsWindows -and $env:OS -ne 'Windows_NT') {
        Add-StartupCheck -Name 'windows_host' -Status 'failed' -Detail @{ os = $env:OS }
        Stop-Startup -Reason 'not_windows' -Message '当前启动器只支持 Windows。'
    }

    Add-StartupCheck -Name 'windows_host' -Status 'passed' -Detail @{ os = $env:OS }

    $buildNumber = [Environment]::OSVersion.Version.Build
    if ($buildNumber -lt $script:MinimumWindowsBuild) {
        Add-StartupCheck -Name 'windows_build' -Status 'failed' -Detail @{
            buildNumber = $buildNumber
            minimumBuild = $script:MinimumWindowsBuild
            osVersion = [Environment]::OSVersion.Version.ToString()
        }
        Stop-Startup -Reason 'windows_build_unsupported' -Message '当前 Windows 版本低于启动器最低要求。'
    }
    Add-StartupCheck -Name 'windows_build' -Status 'passed' -Detail @{
        buildNumber = $buildNumber
        minimumBuild = $script:MinimumWindowsBuild
        osVersion = [Environment]::OSVersion.Version.ToString()
    }

    if (-not [Environment]::Is64BitOperatingSystem) {
        Add-StartupCheck -Name 'os_bitness' -Status 'failed' -Detail @{ is64BitOperatingSystem = [Environment]::Is64BitOperatingSystem }
        Stop-Startup -Reason 'not_64_bit_os' -Message '当前启动器需要 64 位 Windows。'
    }

    Add-StartupCheck -Name 'os_bitness' -Status 'passed' -Detail @{ is64BitOperatingSystem = [Environment]::Is64BitOperatingSystem }

    if (-not [Environment]::Is64BitProcess) {
        $sysnativePowerShell = Join-Path $env:WINDIR 'Sysnative\WindowsPowerShell\v1.0\powershell.exe'
        if (-not (Test-Path -LiteralPath $sysnativePowerShell)) {
            Add-StartupCheck -Name 'process_bitness' -Status 'failed' -Detail @{ is64BitProcess = [Environment]::Is64BitProcess; sysnativePowerShell = $sysnativePowerShell }
            Stop-Startup -Reason 'cannot_converge_64_bit' -Message '无法切换到 64 位 PowerShell。'
        }

        if ($script:BitnessNormalizeAttempted) {
            Add-StartupCheck -Name 'process_bitness' -Status 'failed' -Detail @{ is64BitProcess = [Environment]::Is64BitProcess; sysnativePowerShell = $sysnativePowerShell; reason = 'bitness_normalize_already_attempted' }
            Stop-Startup -Reason 'cannot_converge_64_bit_after_retry' -Message '无法从 32 位 PowerShell 收敛到 64 位 PowerShell。'
        }

        $script:BitnessNormalizeAttempted = $true
        $bitnessAttempt = 1
        $bitnessMaxAttempts = $script:BitnessConvergenceRetryCount
        Add-StartupCheck -Name 'process_bitness' -Status 'relaunching' -Detail @{ is64BitProcess = [Environment]::Is64BitProcess; sysnativePowerShell = $sysnativePowerShell; source = $script:BootstrapSource; entryRole = 'bootstrap-only'; normalizationMarker = 'DINGJIAI_BITNESS_NORMALIZE_ATTEMPTED'; attempt = $bitnessAttempt; maxAttempts = $bitnessMaxAttempts }
        Write-StartupState -Stage $script:StartupStages.HostNormalize -Extra @{
            bitnessAttempt = $bitnessAttempt
            bitnessMaxAttempts = $bitnessMaxAttempts
            bitnessNormalizationAction = 'relaunch_sysnative_powershell'
        }

        $source = if ($script:IsRemoteRun) {
            "irm https://get.dingjiai.com/win.ps1 | iex"
        } else {
            "& '$($MyInvocation.MyCommand.Path)'"
        }

        $reentryCommand = "`$env:DINGJIAI_STARTUP_ID = '$($script:StartupId)'; `$env:DINGJIAI_HOST_NORMALIZE_ATTEMPTED = '1'; `$env:DINGJIAI_BITNESS_NORMALIZE_ATTEMPTED = '1'; $source"
        $process = Start-Process -FilePath $sysnativePowerShell -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-Command', $reentryCommand) -Wait -PassThru
        exit $process.ExitCode
    }

    Add-StartupCheck -Name 'process_bitness' -Status 'passed' -Detail @{ is64BitProcess = [Environment]::Is64BitProcess }

    $cmdPath = Join-Path $env:WINDIR 'System32\cmd.exe'
    if (-not (Test-Path -LiteralPath $cmdPath)) {
        Add-StartupCheck -Name 'cmd_available' -Status 'failed' -Detail @{ cmdPath = $cmdPath }
        Stop-Startup -Reason 'cmd_missing' -Message '找不到系统 cmd.exe。'
    }
    Add-StartupCheck -Name 'cmd_available' -Status 'passed' -Detail @{ cmdPath = $cmdPath }
}

function Test-PowerShellRuntimeHealth {
    $requiredCommands = @(
        'ConvertFrom-Json',
        'ConvertTo-Json',
        'Invoke-WebRequest',
        'Start-Process',
        'New-Item',
        'Set-Content',
        'Get-Content',
        'Add-Content'
    )

    $psVersion = $PSVersionTable.PSVersion
    if ($psVersion -lt $script:MinimumPowerShellVersion) {
        Add-StartupCheck -Name 'powershell_version' -Status 'failed' -Detail @{
            psVersion = $psVersion.ToString()
            minimumVersion = $script:MinimumPowerShellVersion.ToString()
            edition = $PSVersionTable.PSEdition
        }
        Stop-Startup -Reason 'powershell_version_unsupported' -Message '当前 PowerShell 版本低于启动器最低要求。'
    }
    Add-StartupCheck -Name 'powershell_version' -Status 'passed' -Detail @{
        psVersion = $psVersion.ToString()
        minimumVersion = $script:MinimumPowerShellVersion.ToString()
        edition = $PSVersionTable.PSEdition
    }

    for ($attempt = 1; $attempt -le ($script:PowerShellRuntimeHealthRetryCount + 1); $attempt++) {
        $missingCommands = @()
        foreach ($command in $requiredCommands) {
            if (-not (Get-Command -Name $command -ErrorAction SilentlyContinue)) {
                $missingCommands += $command
            }
        }

        $missingCapabilities = @()
        try { $null = @{} | ConvertTo-Json -Depth 1 } catch { $missingCapabilities += 'ConvertTo-Json execution' }
        try { $null = '{"ok":true}' | ConvertFrom-Json } catch { $missingCapabilities += 'ConvertFrom-Json execution' }
        try { $null = [System.Security.Cryptography.SHA256]::Create() } catch { $missingCapabilities += 'SHA256 .NET API' }
        try { $null = [System.IO.File].GetMethod('Replace', [type[]] @([string], [string], [string])) } catch { $missingCapabilities += 'System.IO.File.Replace' }
        try { $null = [Diagnostics.ProcessStartInfo].GetProperty('Verb') } catch { $missingCapabilities += 'Start-Process Verb support' }

        if ($missingCommands.Count -eq 0 -and $missingCapabilities.Count -eq 0) {
            Add-StartupCheck -Name 'powershell_runtime' -Status 'passed' -Detail @{
                psVersion = $PSVersionTable.PSVersion.ToString()
                edition = $PSVersionTable.PSEdition
                attempt = $attempt
                maxAttempts = ($script:PowerShellRuntimeHealthRetryCount + 1)
                requiredCommands = $requiredCommands
                checkedCapabilities = @('json_execution', 'sha256_dotnet_api', 'file_replace_api', 'start_process_verb')
            }
            return
        }

        Add-StartupCheck -Name 'powershell_runtime' -Status 'failed_attempt' -Detail @{
            psVersion = $PSVersionTable.PSVersion.ToString()
            edition = $PSVersionTable.PSEdition
            attempt = $attempt
            maxAttempts = ($script:PowerShellRuntimeHealthRetryCount + 1)
            missingCommands = $missingCommands
            missingCapabilities = $missingCapabilities
        }

        if ($attempt -gt $script:PowerShellRuntimeHealthRetryCount) {
            Stop-Startup -Reason 'powershell_runtime_unhealthy' -Message '当前 PowerShell 缺少启动所需能力。'
        }
    }
}

function Initialize-Workspace {
    $workspaceStartedAt = Get-Date
    for ($attempt = 1; $attempt -le ($script:WorkspaceCreationRetryCount + 1); $attempt++) {
        try {
            New-Item -ItemType Directory -Force -Path $script:WorkspaceRoot, $script:PayloadRoot, $script:StagingRoot, $script:CacheRoot, $script:TempRoot, $script:StateRoot, $script:LogRoot | Out-Null
            $elapsedSeconds = ((Get-Date) - $workspaceStartedAt).TotalSeconds
            if ($elapsedSeconds -gt $script:WorkspacePreparationTimeoutSeconds) {
                Add-StartupCheck -Name 'workspace_preparation_budget' -Status 'failed' -Detail @{
                    workspaceRoot = $script:WorkspaceRoot
                    elapsedSeconds = [math]::Round($elapsedSeconds, 3)
                    budgetSeconds = $script:WorkspacePreparationTimeoutSeconds
                    attempt = $attempt
                    maxAttempts = ($script:WorkspaceCreationRetryCount + 1)
                }
                Stop-Startup -Reason 'workspace_preparation_timeout' -Message '本地工作区准备超过 10 秒预算。'
            }
            Add-StartupCheck -Name 'workspace_ready' -Status 'passed' -Detail @{
                workspaceRoot = $script:WorkspaceRoot
                payloadRoot = $script:PayloadRoot
                stagingRoot = $script:StagingRoot
                cacheRoot = $script:CacheRoot
                tempRoot = $script:TempRoot
                stateRoot = $script:StateRoot
                logRoot = $script:LogRoot
                elapsedSeconds = [math]::Round($elapsedSeconds, 3)
                budgetSeconds = $script:WorkspacePreparationTimeoutSeconds
                attempt = $attempt
                maxAttempts = ($script:WorkspaceCreationRetryCount + 1)
            }
            Write-StartupState -Stage $script:StartupStages.Workspace
            return
        } catch {
            $elapsedSeconds = ((Get-Date) - $workspaceStartedAt).TotalSeconds
            Add-StartupCheck -Name 'workspace_ready' -Status 'failed_attempt' -Detail @{
                workspaceRoot = $script:WorkspaceRoot
                elapsedSeconds = [math]::Round($elapsedSeconds, 3)
                budgetSeconds = $script:WorkspacePreparationTimeoutSeconds
                attempt = $attempt
                maxAttempts = ($script:WorkspaceCreationRetryCount + 1)
                error = $_.Exception.Message
            }
            if ($elapsedSeconds -gt $script:WorkspacePreparationTimeoutSeconds) {
                Add-StartupCheck -Name 'workspace_preparation_budget' -Status 'failed' -Detail @{
                    workspaceRoot = $script:WorkspaceRoot
                    elapsedSeconds = [math]::Round($elapsedSeconds, 3)
                    budgetSeconds = $script:WorkspacePreparationTimeoutSeconds
                    attempt = $attempt
                    maxAttempts = ($script:WorkspaceCreationRetryCount + 1)
                }
                Stop-Startup -Reason 'workspace_preparation_timeout' -Message '本地工作区准备超过 10 秒预算。'
            }
            if ($attempt -gt $script:WorkspaceCreationRetryCount) {
                Stop-Startup -Reason 'workspace_create_failed' -Message '无法创建本地工作区。'
            }
        }
    }
}

function Copy-LocalFileOrDownload {
    param(
        [string] $RelativePath,
        [string] $DestinationPath,
        [string] $Kind = 'payload'
    )

    $destinationDir = Split-Path -Parent $DestinationPath
    New-Item -ItemType Directory -Force -Path $destinationDir | Out-Null

    if ($script:LocalPayloadSourceRoot) {
        $localSource = Join-Path $script:LocalPayloadSourceRoot $RelativePath
        if (Test-Path -LiteralPath $localSource) {
            Copy-Item -LiteralPath $localSource -Destination $DestinationPath -Force
            Add-StartupCheck -Name "$($Kind)_local_source" -Status 'passed' -Detail @{ relativePath = $RelativePath; source = $localSource; destination = $DestinationPath }
            return
        }
    }

    $timeoutSeconds = if ($Kind -eq 'manifest') { $script:ManifestRequestTimeoutSeconds } else { $script:PayloadFileRequestTimeoutSeconds }
    $retryCount = if ($Kind -eq 'manifest') { $script:ManifestDownloadRetryCount } else { $script:PayloadFileDownloadRetryCount }
    $url = "$($script:BaseUrl)/$($RelativePath -replace '\', '/')"

    for ($attempt = 1; $attempt -le ($retryCount + 1); $attempt++) {
        try {
            Invoke-WebRequest -Uri $url -OutFile $DestinationPath -UseBasicParsing -TimeoutSec $timeoutSeconds
            Add-StartupCheck -Name "$($Kind)_download" -Status 'passed' -Detail @{ relativePath = $RelativePath; url = $url; destination = $DestinationPath; attempt = $attempt; timeoutSeconds = $timeoutSeconds }
            return
        } catch {
            Add-StartupCheck -Name "$($Kind)_download" -Status 'failed_attempt' -Detail @{ relativePath = $RelativePath; url = $url; attempt = $attempt; maxAttempts = ($retryCount + 1); timeoutSeconds = $timeoutSeconds; error = $_.Exception.Message }
            if ($attempt -gt $retryCount) {
                throw
            }
        }
    }
}

function Get-FileSha256 {
    param([string] $Path)

    if (Get-Command -Name 'Get-FileHash' -ErrorAction SilentlyContinue) {
        return (Get-FileHash -Algorithm SHA256 -LiteralPath $Path).Hash.ToLowerInvariant()
    }

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

function Read-Manifest {
    try {
        Copy-LocalFileOrDownload -RelativePath 'manifest.json' -DestinationPath $script:ManifestPath -Kind 'manifest'
        Add-StartupCheck -Name 'manifest_acquired' -Status 'passed' -Detail @{ manifestPath = $script:ManifestPath }
    } catch {
        Add-StartupCheck -Name 'manifest_acquired' -Status 'failed' -Detail @{ manifestPath = $script:ManifestPath; error = $_.Exception.Message }
        Stop-Startup -Reason 'manifest_read_failed' -Message 'manifest.json 获取失败。'
    }

    try {
        $manifest = Get-Content -LiteralPath $script:ManifestPath -Raw | ConvertFrom-Json
        Add-StartupCheck -Name 'manifest_json' -Status 'passed' -Detail @{ manifestPath = $script:ManifestPath }
        return $manifest
    } catch {
        Add-StartupCheck -Name 'manifest_json' -Status 'failed' -Detail @{ manifestPath = $script:ManifestPath; error = $_.Exception.Message }
        Stop-Startup -Reason 'manifest_schema_invalid' -Message 'manifest.json 无法解析。'
    }
}

function Test-Sha256Text {
    param([string] $Value)
    return ($Value -match '^[0-9a-fA-F]{64}$')
}

function Stop-ManifestShape {
    param(
        [string] $Detail,
        [string] $Message = 'manifest.json 结构不符合当前启动契约。'
    )

    Add-StartupCheck -Name 'manifest_shape' -Status 'failed' -Detail @{ reason = $Detail; manifestPath = $script:ManifestPath }
    Stop-Startup -Reason 'manifest_schema_invalid' -Message $Message
}

function Assert-ManifestShape {
    param($Manifest)

    if ($null -eq $Manifest) {
        Stop-ManifestShape -Detail 'manifest_null'
    }
    if ($Manifest.schemaVersion -ne 1) {
        Stop-ManifestShape -Detail 'schema_version_unsupported' -Message 'manifest schemaVersion 不受支持。'
    }
    if ($Manifest.channel -ne 'v1-startup') {
        Stop-ManifestShape -Detail 'channel_unsupported' -Message 'manifest channel 不受支持。'
    }
    if ([string]::IsNullOrWhiteSpace($Manifest.payloadVersion)) {
        Stop-ManifestShape -Detail 'payload_version_missing' -Message 'manifest 缺少 payloadVersion。'
    }
    if ($Manifest.basePath -ne 'payload') {
        Stop-ManifestShape -Detail 'base_path_unsupported' -Message 'manifest basePath 必须是 payload。'
    }
    if ($Manifest.mainEntry -ne 'main.cmd') {
        Stop-ManifestShape -Detail 'main_entry_unsupported' -Message 'manifest mainEntry 必须是 main.cmd。'
    }
    if ($Manifest.handoffMode -ne 'admin-cmd') {
        Stop-ManifestShape -Detail 'handoff_mode_unsupported' -Message 'manifest handoffMode 不受支持。'
    }
    if (-not $Manifest.files -or $Manifest.files.Count -lt 1) {
        Stop-ManifestShape -Detail 'files_missing' -Message 'manifest 缺少 payload 文件清单。'
    }

    $seenPaths = @{}
    foreach ($file in $Manifest.files) {
        if ([string]::IsNullOrWhiteSpace($file.path)) {
            Stop-ManifestShape -Detail 'file_path_missing' -Message 'manifest 文件项缺少 path。'
        }
        if (-not (Test-Sha256Text -Value $file.sha256)) {
            Stop-ManifestShape -Detail 'file_sha256_invalid' -Message "manifest 文件 $($file.path) 的 sha256 不合法。"
        }
        if ($file.required -isnot [bool]) {
            Stop-ManifestShape -Detail 'file_required_invalid' -Message "manifest 文件 $($file.path) 的 required 必须是布尔值。"
        }

        $pathKey = ([string] $file.path).Replace('', '/').ToLowerInvariant()
        if ($seenPaths.ContainsKey($pathKey)) {
            Stop-ManifestShape -Detail 'file_path_duplicate' -Message "manifest 文件路径重复：$($file.path)。"
        }
        $seenPaths[$pathKey] = $true
    }

    Add-StartupCheck -Name 'manifest_shape' -Status 'passed' -Detail @{ schemaVersion = $Manifest.schemaVersion; channel = $Manifest.channel; payloadVersion = $Manifest.payloadVersion; handoffMode = $Manifest.handoffMode; basePath = $Manifest.basePath; mainEntry = $Manifest.mainEntry; fileCount = $Manifest.files.Count }
}

function Assert-SafeRelativePath {
    param(
        [string] $Path,
        [string] $Root = $script:PayloadRoot
    )

    if ([string]::IsNullOrWhiteSpace($Path)) {
        Stop-Startup -Reason 'payload_path_invalid' -Message 'payload 文件路径为空。'
    }
    if ([System.IO.Path]::IsPathRooted($Path)) {
        Stop-Startup -Reason 'payload_path_invalid' -Message 'payload 文件路径不能是绝对路径。'
    }

    $rootedPath = Join-Path $Root $Path
    if (-not (Test-PathInsideRoot -Path $rootedPath -Root $Root)) {
        Stop-Startup -Reason 'payload_path_invalid' -Message 'payload 文件路径必须留在 payload 目录内。'
    }
}

function Sync-Payload {
    param($Manifest)

    Assert-ManifestShape -Manifest $Manifest
    Write-StartupState -Stage $script:StartupStages.Payload -Extra @{ payloadVersion = $Manifest.payloadVersion }

    $verifiedFiles = @{}
    $stagingPayloadRoot = Join-Path $script:StagingRoot ("payload-$($script:StartupId)")
    if (Test-Path -LiteralPath $stagingPayloadRoot) {
        Remove-Item -LiteralPath $stagingPayloadRoot -Recurse -Force
    }
    New-Item -ItemType Directory -Force -Path $stagingPayloadRoot | Out-Null
    Add-StartupCheck -Name 'payload_staging' -Status 'passed' -Detail @{ stagingPayloadRoot = $stagingPayloadRoot }

    foreach ($file in $Manifest.files) {
        Assert-SafeRelativePath -Path $file.path
        if ($file.required -ne $true) {
            continue
        }
        if ([string]::IsNullOrWhiteSpace($file.sha256)) {
            Stop-Startup -Reason 'payload_hash_missing' -Message "payload 文件 $($file.path) 缺少 hash。"
        }

        $relativeSource = Join-Path $Manifest.basePath $file.path
        $stagingDestination = Join-Path $stagingPayloadRoot $file.path
        try {
            Copy-LocalFileOrDownload -RelativePath $relativeSource -DestinationPath $stagingDestination -Kind 'payload'
            Add-StartupCheck -Name 'payload_acquired' -Status 'passed' -Detail @{ path = $file.path; destination = $stagingDestination; staging = $true }
        } catch {
            Add-StartupCheck -Name 'payload_acquired' -Status 'failed' -Detail @{ path = $file.path; destination = $stagingDestination; error = $_.Exception.Message }
            Stop-Startup -Reason 'payload_download_failed' -Message "payload 文件 $($file.path) 获取失败。"
        }

        $hashMaxAttempts = $script:PayloadRepairRebuildRetryCount + 1
        for ($hashAttempt = 1; $hashAttempt -le $hashMaxAttempts; $hashAttempt++) {
            $actualHash = Get-FileSha256 -Path $stagingDestination
            if ($actualHash -eq $file.sha256.ToLowerInvariant()) {
                Add-StartupCheck -Name 'payload_hash' -Status 'passed' -Detail @{ path = $file.path; sha256 = $actualHash; attempt = $hashAttempt; maxAttempts = $hashMaxAttempts; hashMismatchRetryCount = $script:PayloadHashMismatchRetryCount; repairRebuildRetryCount = $script:PayloadRepairRebuildRetryCount }
                break
            }

            Add-StartupCheck -Name 'payload_hash' -Status 'failed_attempt' -Detail @{ path = $file.path; expected = $file.sha256.ToLowerInvariant(); actual = $actualHash; attempt = $hashAttempt; maxAttempts = $hashMaxAttempts; hashMismatchRetryCount = $script:PayloadHashMismatchRetryCount; repairRebuildRetryCount = $script:PayloadRepairRebuildRetryCount }
            if ($hashAttempt -ge $hashMaxAttempts) {
                Stop-Startup -Reason 'payload_hash_mismatch' -Message "payload 文件 $($file.path) 校验失败。"
            }

            Add-StartupCheck -Name 'payload_repair_rebuild' -Status 'attempted' -Detail @{ path = $file.path; repairAttempt = $hashAttempt; repairMaxAttempts = $script:PayloadRepairRebuildRetryCount }
            try {
                Copy-LocalFileOrDownload -RelativePath $relativeSource -DestinationPath $stagingDestination -Kind 'payload'
            } catch {
                Add-StartupCheck -Name 'payload_repair_rebuild' -Status 'failed' -Detail @{ path = $file.path; error = $_.Exception.Message }
                Stop-Startup -Reason 'payload_download_failed' -Message "payload 文件 $($file.path) 重新获取失败。"
            }
        }
        $verifiedFiles[$file.path] = $true
    }

    Assert-SafeRelativePath -Path $Manifest.mainEntry
    if (-not $verifiedFiles.ContainsKey($Manifest.mainEntry)) {
        Add-StartupCheck -Name 'main_entry_verified' -Status 'failed' -Detail @{ mainEntry = $Manifest.mainEntry }
        Stop-Startup -Reason 'main_entry_not_verified' -Message 'payload 主入口不在已校验文件清单中。'
    }
    Add-StartupCheck -Name 'main_entry_verified' -Status 'passed' -Detail @{ mainEntry = $Manifest.mainEntry }

    $stagingMainEntryPath = Join-Path $stagingPayloadRoot $Manifest.mainEntry
    if (-not (Test-Path -LiteralPath $stagingMainEntryPath)) {
        Add-StartupCheck -Name 'main_entry_exists' -Status 'failed' -Detail @{ mainEntryPath = $stagingMainEntryPath }
        Stop-Startup -Reason 'main_entry_missing' -Message 'payload 主入口不存在。'
    }
    Add-StartupCheck -Name 'main_entry_exists' -Status 'passed' -Detail @{ mainEntryPath = $stagingMainEntryPath }

    $previousPayloadRoot = Join-Path $script:StagingRoot ("previous-payload-$($script:StartupId)")
    if (Test-Path -LiteralPath $previousPayloadRoot) {
        Remove-Item -LiteralPath $previousPayloadRoot -Recurse -Force
    }
    if (Test-Path -LiteralPath $script:PayloadRoot) {
        Move-Item -LiteralPath $script:PayloadRoot -Destination $previousPayloadRoot -Force
    }
    Move-Item -LiteralPath $stagingPayloadRoot -Destination $script:PayloadRoot -Force
    if (Test-Path -LiteralPath $previousPayloadRoot) {
        Remove-Item -LiteralPath $previousPayloadRoot -Recurse -Force
    }
    Add-StartupCheck -Name 'payload_promoted' -Status 'passed' -Detail @{ payloadRoot = $script:PayloadRoot; stagingPayloadRoot = $stagingPayloadRoot }

    $mainEntryPath = Join-Path $script:PayloadRoot $Manifest.mainEntry
    Write-StartupState -Stage $script:StartupStages.Payload -Extra @{
        payloadVersion = $Manifest.payloadVersion
        mainEntryPath = $mainEntryPath
    }

    return $mainEntryPath
}

function Test-EntryLandingShape {
    param([string] $MainEntryPath)

    $resolvedPayloadRoot = Get-NormalizedPath -Path $script:PayloadRoot
    $resolvedMainEntryPath = Get-NormalizedPath -Path $MainEntryPath
    $isUnderPayloadRoot = Test-PathInsideRoot -Path $resolvedMainEntryPath -Root $resolvedPayloadRoot
    $extension = [System.IO.Path]::GetExtension($resolvedMainEntryPath)

    if (-not $isUnderPayloadRoot) {
        Add-StartupCheck -Name 'entry_landing_shape' -Status 'failed' -Detail @{ mainEntryPath = $resolvedMainEntryPath; payloadRoot = $resolvedPayloadRoot; reason = 'outside_payload_root' }
        Stop-Startup -Reason 'entry_shape_invalid' -Message 'payload 主入口不在本地 payload 目录内。'
    }

    if ($extension -ne '.cmd') {
        Add-StartupCheck -Name 'entry_landing_shape' -Status 'failed' -Detail @{ mainEntryPath = $resolvedMainEntryPath; extension = $extension; reason = 'not_cmd_entry' }
        Stop-Startup -Reason 'entry_shape_invalid' -Message 'payload 主入口不是 CMD 文件。'
    }

    Add-StartupCheck -Name 'entry_landing_shape' -Status 'passed' -Detail @{
        mainEntryPath = $resolvedMainEntryPath
        payloadRoot = $resolvedPayloadRoot
        extension = $extension
        isUnderPayloadRoot = $isUnderPayloadRoot
        handoffMode = 'admin-cmd'
        mainUiHost = 'admin-cmd'
    }
}

function Start-AdminCmdHandoff {
    param([string] $MainEntryPath)

    $script:HandoffAttempted = $true
    Write-StartupState -Stage $script:StartupStages.Handoff -Extra @{
        mainEntryPath = $MainEntryPath
        handoffAttemptedAt = (Get-Date).ToString('o')
    }

    $cmdPath = Join-Path $env:WINDIR 'System32\cmd.exe'
    $handoffCommand = @(
        '"{0}"' -f $MainEntryPath
        '--startup-id'
        '"{0}"' -f $script:StartupId
        '--workspace-root'
        '"{0}"' -f $script:WorkspaceRoot
        '--state'
        '"{0}"' -f $script:StatePath
        '--log-path'
        '"{0}"' -f $script:LogPath
        '--payload-root'
        '"{0}"' -f $script:PayloadRoot
        '--main-entry-path'
        '"{0}"' -f $MainEntryPath
        '--source'
        '"{0}"' -f $script:BootstrapSource
        '--handoff-mode'
        'admin-cmd'
    ) -join ' '
    $cmdArguments = '/c "{0}"' -f $handoffCommand

    $maxAttempts = $script:UacHandoffAttemptCount
    for ($attempt = 1; $attempt -le $maxAttempts; $attempt++) {
        Add-StartupCheck -Name 'admin_cmd_handoff' -Status 'attempted' -Detail @{ cmdPath = $cmdPath; workspaceRoot = $script:WorkspaceRoot; statePath = $script:StatePath; logPath = $script:LogPath; payloadRoot = $script:PayloadRoot; mainEntryPath = $MainEntryPath; source = $script:BootstrapSource; attempt = $attempt; maxAttempts = $maxAttempts }
        Write-StartupState -Stage $script:StartupStages.Handoff -Extra @{
            mainEntryPath = $MainEntryPath
            handoffAttemptedAt = (Get-Date).ToString('o')
            handoffAttempt = $attempt
            handoffMaxAttempts = $maxAttempts
        }

        try {
            Start-Process -FilePath $cmdPath -ArgumentList $cmdArguments -Verb RunAs | Out-Null
            break
        } catch {
            Add-StartupCheck -Name 'admin_cmd_handoff' -Status 'failed' -Detail @{ cmdPath = $cmdPath; mainEntryPath = $MainEntryPath; attempt = $attempt; maxAttempts = $maxAttempts }
            if ($attempt -ge $maxAttempts) {
                Stop-Startup -Reason 'handoff_failed' -Message '无法打开管理员 CMD 主窗口。'
            }
        }
    }

    $deadline = (Get-Date).AddSeconds($script:HandoffAcceptedWaitSeconds)
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Milliseconds $script:HandoffAcceptedPollMilliseconds
        try {
            $state = Get-Content -LiteralPath $script:StatePath -Raw | ConvertFrom-Json
            if (Test-HandoffAcceptedState -State $state -ExpectedMainEntryPath $MainEntryPath) {
                $script:HandoffAccepted = $true
                Add-StartupCheck -Name 'handoff_accepted' -Status 'passed' -Detail @{ statePath = $script:StatePath; waitSeconds = $script:HandoffAcceptedWaitSeconds; pollMilliseconds = $script:HandoffAcceptedPollMilliseconds; acceptedWorkspaceRoot = $state.acceptedWorkspaceRoot; acceptedPayloadRoot = $state.acceptedPayloadRoot; acceptedMainEntryPath = $state.acceptedMainEntryPath; acceptedSource = $state.acceptedSource; acceptedHandoffMode = $state.acceptedHandoffMode }
                Write-Host '管理员 CMD 主窗口已接管。'
                return
            }
        } catch {
        }
    }

    Add-StartupCheck -Name 'handoff_accepted' -Status 'failed' -Detail @{ timeoutSeconds = $script:HandoffAcceptedWaitSeconds; statePath = $script:StatePath }
    Stop-Startup -Reason 'handoff_timeout' -Message "管理员 CMD 主窗口未在 $script:HandoffAcceptedWaitSeconds 秒内确认接管。"
}

Assert-StartupBudget -Checkpoint 'before_host_normalization'
Test-HostNormalization
Assert-StartupBudget -Checkpoint 'before_terminal_compatibility'
Test-TerminalCompatibility
Assert-StartupBudget -Checkpoint 'before_system_architecture_matrix'
Test-SystemArchitectureMatrix
Assert-StartupBudget -Checkpoint 'before_host_checks'
Write-StartupState -Stage $script:StartupStages.PlatformGate
Test-WindowsHost
Assert-StartupBudget -Checkpoint 'before_powershell_runtime'
Test-PowerShellRuntimeHealth
Assert-StartupBudget -Checkpoint 'before_workspace'
Initialize-Workspace
Assert-StartupBudget -Checkpoint 'before_manifest'
$manifest = Read-Manifest
Assert-StartupBudget -Checkpoint 'before_payload_sync'
$mainEntryPath = Sync-Payload -Manifest $manifest
Assert-StartupBudget -Checkpoint 'before_entry_landing_shape'
Test-EntryLandingShape -MainEntryPath $mainEntryPath
Assert-StartupBudget -Checkpoint 'before_handoff'
Start-AdminCmdHandoff -MainEntryPath $mainEntryPath
