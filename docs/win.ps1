$ErrorActionPreference = 'Stop'

$script:BootstrapVersion = '0.1.0-startup.1'
$script:StartedAt = (Get-Date).ToString('o')
$script:StartupId = [guid]::NewGuid().ToString('N')
$script:IsRemoteRun = [string]::IsNullOrWhiteSpace($MyInvocation.MyCommand.Path)
$script:BootstrapRoot = if ($script:IsRemoteRun) { $null } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$script:LocalPayloadSourceRoot = if ($script:BootstrapRoot) { Join-Path $script:BootstrapRoot 'installer\windows' } else { $null }
$script:BaseUrl = 'https://get.dingjiai.com/installer/windows'
$script:WorkspaceRoot = Join-Path $env:LOCALAPPDATA 'dingjiai-installer'
$script:PayloadRoot = Join-Path $script:WorkspaceRoot 'payload'
$script:StagingRoot = Join-Path $script:WorkspaceRoot 'staging'
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
    Failed = 'failed'
    Relaunching64Bit = 'relaunching_64_bit'
    WorkspaceReady = 'workspace_ready'
    PayloadSyncing = 'payload_syncing'
    PayloadReady = 'payload_ready'
    HandoffAttempted = 'handoff_attempted'
    Completed = 'completed'
}

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

function Stop-Startup {
    param(
        [string] $Reason,
        [string] $Message
    )

    Write-StartupState -Stage $script:StartupStages.Failed -Extra @{
        failureReason = $Reason
        failureMessage = $Message
        failedAt = (Get-Date).ToString('o')
    }

    Write-Host "启动失败：$Message"
    exit 1
}

function Write-StartupState {
    param(
        [string] $Stage,
        [hashtable] $Extra = @{}
    )

    New-Item -ItemType Directory -Force -Path $script:StateRoot, $script:LogRoot | Out-Null

    $state = [ordered]@{
        startupId = $script:StartupId
        bootstrapVersion = $script:BootstrapVersion
        stage = $Stage
        startedAt = $script:StartedAt
        updatedAt = (Get-Date).ToString('o')
        workspaceRoot = $script:WorkspaceRoot
        payloadRoot = $script:PayloadRoot
        stagingRoot = $script:StagingRoot
        manifestPath = $script:ManifestPath
        handoffAccepted = $false
        checks = $script:StartupChecks
    }

    foreach ($key in $Extra.Keys) {
        $state[$key] = $Extra[$key]
    }

    $state | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $script:StatePath -Encoding UTF8

    $logEntry = [ordered]@{
        startupId = $script:StartupId
        stage = $Stage
        writtenAt = $state.updatedAt
        statePath = $script:StatePath
        checkCount = $script:StartupChecks.Count
    }
    $logEntry | ConvertTo-Json -Depth 4 -Compress | Add-Content -LiteralPath $script:LogPath -Encoding UTF8
}

function Test-HostNormalization {
    $attempt = 1
    $maxAttempts = $script:HostNormalizationRetryCount
    $processPath = (Get-Process -Id $PID).Path
    Add-StartupCheck -Name 'host_normalization' -Status 'passed' -Detail @{
        attempt = $attempt
        maxAttempts = $maxAttempts
        isRemoteRun = $script:IsRemoteRun
        bootstrapRoot = $script:BootstrapRoot
        shellId = $ShellId
        psVersion = $PSVersionTable.PSVersion.ToString()
        edition = $PSVersionTable.PSEdition
        processPath = $processPath
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

        $bitnessAttempt = 1
        $bitnessMaxAttempts = $script:BitnessConvergenceRetryCount
        Add-StartupCheck -Name 'process_bitness' -Status 'relaunching' -Detail @{ is64BitProcess = [Environment]::Is64BitProcess; sysnativePowerShell = $sysnativePowerShell; attempt = $bitnessAttempt; maxAttempts = $bitnessMaxAttempts }
        Write-StartupState -Stage $script:StartupStages.Relaunching64Bit -Extra @{
            bitnessAttempt = $bitnessAttempt
            bitnessMaxAttempts = $bitnessMaxAttempts
        }

        $source = if ($script:IsRemoteRun) {
            "irm https://get.dingjiai.com/win.ps1 | iex"
        } else {
            "& '$($MyInvocation.MyCommand.Path)'"
        }

        $process = Start-Process -FilePath $sysnativePowerShell -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-Command', $source) -Wait -PassThru
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
        'Get-Content'
    )

    for ($attempt = 1; $attempt -le ($script:PowerShellRuntimeHealthRetryCount + 1); $attempt++) {
        $missingCommands = @()
        foreach ($command in $requiredCommands) {
            if (-not (Get-Command -Name $command -ErrorAction SilentlyContinue)) {
                $missingCommands += $command
            }
        }

        if ($missingCommands.Count -eq 0) {
            Add-StartupCheck -Name 'powershell_runtime' -Status 'passed' -Detail @{
                psVersion = $PSVersionTable.PSVersion.ToString()
                edition = $PSVersionTable.PSEdition
                attempt = $attempt
                maxAttempts = ($script:PowerShellRuntimeHealthRetryCount + 1)
                requiredCommands = $requiredCommands
            }
            return
        }

        Add-StartupCheck -Name 'powershell_runtime' -Status 'failed_attempt' -Detail @{
            psVersion = $PSVersionTable.PSVersion.ToString()
            edition = $PSVersionTable.PSEdition
            attempt = $attempt
            maxAttempts = ($script:PowerShellRuntimeHealthRetryCount + 1)
            missingCommands = $missingCommands
        }

        if ($attempt -gt $script:PowerShellRuntimeHealthRetryCount) {
            Stop-Startup -Reason 'powershell_runtime_unhealthy' -Message '当前 PowerShell 缺少启动所需能力。'
        }
    }
}

function Initialize-Workspace {
    for ($attempt = 1; $attempt -le ($script:WorkspaceCreationRetryCount + 1); $attempt++) {
        try {
            New-Item -ItemType Directory -Force -Path $script:WorkspaceRoot, $script:PayloadRoot, $script:StagingRoot, $script:StateRoot, $script:LogRoot | Out-Null
            Add-StartupCheck -Name 'workspace_ready' -Status 'passed' -Detail @{
                workspaceRoot = $script:WorkspaceRoot
                payloadRoot = $script:PayloadRoot
                stagingRoot = $script:StagingRoot
                stateRoot = $script:StateRoot
                logRoot = $script:LogRoot
                attempt = $attempt
                maxAttempts = ($script:WorkspaceCreationRetryCount + 1)
            }
            Write-StartupState -Stage $script:StartupStages.WorkspaceReady
            return
        } catch {
            Add-StartupCheck -Name 'workspace_ready' -Status 'failed_attempt' -Detail @{
                workspaceRoot = $script:WorkspaceRoot
                attempt = $attempt
                maxAttempts = ($script:WorkspaceCreationRetryCount + 1)
                error = $_.Exception.Message
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
    Copy-LocalFileOrDownload -RelativePath 'manifest.json' -DestinationPath $script:ManifestPath -Kind 'manifest'
    Add-StartupCheck -Name 'manifest_acquired' -Status 'passed' -Detail @{ manifestPath = $script:ManifestPath }
    try {
        $manifest = Get-Content -LiteralPath $script:ManifestPath -Raw | ConvertFrom-Json
        Add-StartupCheck -Name 'manifest_json' -Status 'passed' -Detail @{ manifestPath = $script:ManifestPath }
        return $manifest
    } catch {
        Add-StartupCheck -Name 'manifest_json' -Status 'failed' -Detail @{ manifestPath = $script:ManifestPath }
        Stop-Startup -Reason 'manifest_invalid_json' -Message 'manifest.json 无法解析。'
    }
}

function Assert-ManifestShape {
    param($Manifest)

    if ($Manifest.schemaVersion -ne 1) {
        Stop-Startup -Reason 'manifest_schema_unsupported' -Message 'manifest schemaVersion 不受支持。'
    }
    if ($Manifest.handoffMode -ne 'admin-cmd') {
        Stop-Startup -Reason 'manifest_handoff_unsupported' -Message 'manifest handoffMode 不受支持。'
    }
    if ([string]::IsNullOrWhiteSpace($Manifest.basePath)) {
        Stop-Startup -Reason 'manifest_base_path_missing' -Message 'manifest 缺少 basePath。'
    }
    if ([string]::IsNullOrWhiteSpace($Manifest.mainEntry)) {
        Stop-Startup -Reason 'manifest_main_entry_missing' -Message 'manifest 缺少 mainEntry。'
    }
    if (-not $Manifest.files -or $Manifest.files.Count -lt 1) {
        Stop-Startup -Reason 'manifest_files_missing' -Message 'manifest 缺少 payload 文件清单。'
    }
    Add-StartupCheck -Name 'manifest_shape' -Status 'passed' -Detail @{ schemaVersion = $Manifest.schemaVersion; handoffMode = $Manifest.handoffMode; basePath = $Manifest.basePath; mainEntry = $Manifest.mainEntry; fileCount = $Manifest.files.Count }
}

function Assert-SafeRelativePath {
    param([string] $Path)

    if ([string]::IsNullOrWhiteSpace($Path)) {
        Stop-Startup -Reason 'path_empty' -Message 'payload 文件路径为空。'
    }
    if ([System.IO.Path]::IsPathRooted($Path) -or $Path.Contains('..')) {
        Stop-Startup -Reason 'path_unsafe' -Message 'payload 文件路径不安全。'
    }
}

function Sync-Payload {
    param($Manifest)

    Assert-ManifestShape -Manifest $Manifest
    Assert-SafeRelativePath -Path $Manifest.basePath
    Write-StartupState -Stage $script:StartupStages.PayloadSyncing -Extra @{ payloadVersion = $Manifest.payloadVersion }

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
        Copy-LocalFileOrDownload -RelativePath $relativeSource -DestinationPath $stagingDestination -Kind 'payload'
        Add-StartupCheck -Name 'payload_acquired' -Status 'passed' -Detail @{ path = $file.path; destination = $stagingDestination; staging = $true }

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
            Copy-LocalFileOrDownload -RelativePath $relativeSource -DestinationPath $stagingDestination -Kind 'payload'
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
    Write-StartupState -Stage $script:StartupStages.PayloadReady -Extra @{
        payloadVersion = $Manifest.payloadVersion
        mainEntryPath = $mainEntryPath
    }

    return $mainEntryPath
}

function Test-EntryLandingShape {
    param([string] $MainEntryPath)

    $resolvedPayloadRoot = [System.IO.Path]::GetFullPath($script:PayloadRoot)
    $resolvedMainEntryPath = [System.IO.Path]::GetFullPath($MainEntryPath)
    $isUnderPayloadRoot = $resolvedMainEntryPath.StartsWith($resolvedPayloadRoot, [System.StringComparison]::OrdinalIgnoreCase)
    $extension = [System.IO.Path]::GetExtension($resolvedMainEntryPath)

    if (-not $isUnderPayloadRoot) {
        Add-StartupCheck -Name 'entry_landing_shape' -Status 'failed' -Detail @{ mainEntryPath = $resolvedMainEntryPath; payloadRoot = $resolvedPayloadRoot; reason = 'outside_payload_root' }
        Stop-Startup -Reason 'entry_landing_outside_payload_root' -Message 'payload 主入口不在本地 payload 目录内。'
    }

    if ($extension -ne '.cmd') {
        Add-StartupCheck -Name 'entry_landing_shape' -Status 'failed' -Detail @{ mainEntryPath = $resolvedMainEntryPath; extension = $extension; reason = 'not_cmd_entry' }
        Stop-Startup -Reason 'entry_landing_not_cmd' -Message 'payload 主入口不是 CMD 文件。'
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

    Write-StartupState -Stage $script:StartupStages.HandoffAttempted -Extra @{
        mainEntryPath = $MainEntryPath
        handoffAttemptedAt = (Get-Date).ToString('o')
    }

    $cmdPath = Join-Path $env:WINDIR 'System32\cmd.exe'
    $cmdArguments = "/k `"`"$MainEntryPath`" --startup-id `"$script:StartupId`" --state `"$script:StatePath`" --payload-root `"$script:PayloadRoot`" --handoff-mode admin-cmd`""

    $maxAttempts = $script:UacHandoffAttemptCount
    for ($attempt = 1; $attempt -le $maxAttempts; $attempt++) {
        Add-StartupCheck -Name 'admin_cmd_handoff' -Status 'attempted' -Detail @{ cmdPath = $cmdPath; mainEntryPath = $MainEntryPath; attempt = $attempt; maxAttempts = $maxAttempts }
        Write-StartupState -Stage $script:StartupStages.HandoffAttempted -Extra @{
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
                Stop-Startup -Reason 'handoff_denied_or_failed' -Message '无法打开管理员 CMD 主窗口。'
            }
        }
    }

    $deadline = (Get-Date).AddSeconds($script:HandoffAcceptedWaitSeconds)
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Milliseconds $script:HandoffAcceptedPollMilliseconds
        try {
            $state = Get-Content -LiteralPath $script:StatePath -Raw | ConvertFrom-Json
            if ($state.startupId -eq $script:StartupId -and $state.handoffAccepted -eq $true) {
                Add-StartupCheck -Name 'handoff_accepted' -Status 'passed' -Detail @{ statePath = $script:StatePath; waitSeconds = $script:HandoffAcceptedWaitSeconds; pollMilliseconds = $script:HandoffAcceptedPollMilliseconds }
                Write-StartupState -Stage $script:StartupStages.Completed -Extra @{
                    mainEntryPath = $MainEntryPath
                    handoffAccepted = $true
                    handoffAcceptedAt = $state.handoffAcceptedAt
                    acceptedPayloadRoot = $state.acceptedPayloadRoot
                }
                Write-Host '管理员 CMD 主窗口已接管。'
                return
            }
        } catch {
        }
    }

    Add-StartupCheck -Name 'handoff_accepted' -Status 'failed' -Detail @{ timeoutSeconds = 30; statePath = $script:StatePath }
    Stop-Startup -Reason 'handoff_accept_timeout' -Message '管理员 CMD 主窗口未在 30 秒内确认接管。'
}

Assert-StartupBudget -Checkpoint 'before_host_normalization'
Test-HostNormalization
Assert-StartupBudget -Checkpoint 'before_terminal_compatibility'
Test-TerminalCompatibility
Assert-StartupBudget -Checkpoint 'before_system_architecture_matrix'
Test-SystemArchitectureMatrix
Assert-StartupBudget -Checkpoint 'before_host_checks'
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
