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

function Test-Sha256Text {
    param([string] $Value)
    return ($Value -match '^[0-9a-fA-F]{64}$')
}

function Test-Utf8Bom {
    param([string] $Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return $false
    }

    $bytes = [System.IO.File]::ReadAllBytes($Path)
    return ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)
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

function Invoke-CheckpointJson {
    param(
        [string] $Path,
        [string[]] $Arguments,
        [int] $ExpectedExitCode
    )

    $output = & cmd.exe /c "call `"$Path`" $($Arguments -join ' ')"
    $exitCode = $LASTEXITCODE
    Need ($exitCode -eq $ExpectedExitCode) "checkpoint exits ${ExpectedExitCode}: $Path $($Arguments -join ' ')"

    try {
        return (($output -join "`n") | ConvertFrom-Json)
    } catch {
        Fail "checkpoint did not emit valid JSON: $Path $($Arguments -join ' '): $($_.Exception.Message)"
        return $null
    }
}

function Test-StartupAcceptBehavior {
    param([string] $HelperPath)

    if (-not (Test-Path -LiteralPath $HelperPath -PathType Leaf)) {
        return
    }

    $testRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("dingjiai-startup-accept-{0}" -f [guid]::NewGuid().ToString('N'))
    try {
        $workspaceRoot = Join-Path $testRoot 'workspace'
        $stateRoot = Join-Path $workspaceRoot 'state'
        $logRoot = Join-Path $workspaceRoot 'logs'
        $payloadRoot = Join-Path $workspaceRoot 'payload'
        New-Item -ItemType Directory -Path $stateRoot, $logRoot, $payloadRoot -Force | Out-Null

        $startupId = 'self-check-startup'
        $mainEntryPath = Join-Path $payloadRoot 'main.cmd'
        Set-Content -LiteralPath $mainEntryPath -Value '@echo off' -Encoding ASCII

        $statePath = Join-Path $stateRoot 'startup-self-check.json'
        $logPath = Join-Path $logRoot 'startup-self-check.jsonl'
        $source = 'local-win-ps1'
        $initialState = [ordered] @{
            startupId = $startupId
            stage = 'handoff'
            workspaceRoot = $workspaceRoot
            payloadRoot = $payloadRoot
            mainEntryPath = $mainEntryPath
            source = $source
        }
        Set-Content -LiteralPath $statePath -Value ($initialState | ConvertTo-Json -Depth 4) -Encoding UTF8

        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $HelperPath `
            -StartupId $startupId `
            -WorkspaceRoot $workspaceRoot `
            -StatePath $statePath `
            -LogPath $logPath `
            -PayloadRoot $payloadRoot `
            -MainEntryPath $mainEntryPath `
            -Source $source `
            -SelfPath $mainEntryPath
        $successExitCode = $LASTEXITCODE
        Need ($successExitCode -eq 0) 'startup_accept.ps1 accepts valid handoff state'

        $acceptedState = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json
        Need ($acceptedState.stage -eq 'completed') 'startup_accept.ps1 marks startup completed'
        Need ($acceptedState.handoffAccepted -eq $true) 'startup_accept.ps1 marks handoff accepted'
        Need ($acceptedState.acceptedHandoffMode -eq 'admin-cmd') 'startup_accept.ps1 records admin-cmd handoff mode'
        Need ((Get-NormalizedFullPath -Path $acceptedState.acceptedWorkspaceRoot) -eq (Get-NormalizedFullPath -Path $workspaceRoot)) 'startup_accept.ps1 records accepted workspace root'
        Need ((Get-NormalizedFullPath -Path $acceptedState.acceptedMainEntryPath) -eq (Get-NormalizedFullPath -Path $mainEntryPath)) 'startup_accept.ps1 records accepted main entry path'

        $failureStdoutPath = Join-Path $testRoot 'expected-failure.stdout.txt'
        $failureStderrPath = Join-Path $testRoot 'expected-failure.stderr.txt'
        $failureProcess = Start-Process -FilePath 'powershell.exe' -ArgumentList @(
            '-NoProfile',
            '-ExecutionPolicy',
            'Bypass',
            '-File',
            $HelperPath,
            '-StartupId',
            $startupId,
            '-WorkspaceRoot',
            $workspaceRoot,
            '-StatePath',
            $statePath,
            '-LogPath',
            $logPath,
            '-PayloadRoot',
            $payloadRoot,
            '-MainEntryPath',
            $mainEntryPath,
            '-Source',
            $source,
            '-SelfPath',
            (Join-Path $payloadRoot 'wrong.cmd')
        ) -NoNewWindow -Wait -PassThru -RedirectStandardOutput $failureStdoutPath -RedirectStandardError $failureStderrPath
        Need ($failureProcess.ExitCode -ne 0) 'startup_accept.ps1 rejects wrong main entry self path'
    } finally {
        if (Test-Path -LiteralPath $testRoot) {
            Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

function Test-WinBootstrapManifestShapeBehavior {
    param([string] $WinEntryPath)

    if (-not (Test-Path -LiteralPath $WinEntryPath -PathType Leaf)) {
        return
    }

    $scriptText = Get-Content -LiteralPath $WinEntryPath -Raw
    $start = $scriptText.IndexOf('function Test-Sha256Text')
    $end = $scriptText.IndexOf('function Assert-SafeRelativePath')
    if ($start -lt 0 -or $end -le $start) {
        Fail 'win.ps1 manifest shape behavior functions are discoverable'
        return
    }

    $snippet = $scriptText.Substring($start, $end - $start)
    $snippet += @'
$ErrorActionPreference = 'Stop'
$script:StartupChecks = @()
function Add-StartupCheck { param([string] $Name, [string] $Status, [hashtable] $Detail = @{}) }
function Stop-Startup { param([string] $Reason, [string] $Message) throw "$Reason|$Message" }
$manifest = [pscustomobject] @{
    schemaVersion = 1
    channel = 'v1-startup'
    payloadVersion = 'self-check'
    basePath = ''
    mainEntry = 'startup/main.cmd'
    handoffMode = 'admin-cmd'
    files = @(
        [pscustomobject] @{ path = 'startup/main.cmd'; sha256 = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'; required = $true },
        [pscustomobject] @{ path = 'startup\startup_accept.ps1'; sha256 = 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'; required = $true }
    )
}
Assert-ManifestShape -Manifest $manifest
'@

    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($snippet))
    $process = Start-Process -FilePath 'powershell.exe' -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-EncodedCommand', $encoded) -NoNewWindow -Wait -PassThru
    Need ($process.ExitCode -eq 0) 'bootstrap manifest shape accepts three-layer payload paths without runtime errors'
}

$docsRoot = Split-Path -Parent $PSScriptRoot
$startupRoot = Join-Path $docsRoot 'startup'
$flowsRoot = Join-Path $docsRoot 'flows'
$actionsRoot = Join-Path $docsRoot 'actions'
$manifestPath = Join-Path $startupRoot 'manifest.json'
$payloadRoot = $docsRoot
$winEntryPath = Join-Path $docsRoot 'win.ps1'
$bootstrapPath = Join-Path $startupRoot 'bootstrap.ps1'
$windowsFlowPath = Join-Path $flowsRoot 'windows.cmd'
$wingetActionRoot = Join-Path $actionsRoot 'winget'
$wingetActionCmdPath = Join-Path $wingetActionRoot 'winget.cmd'
$wingetActionPsPath = Join-Path $wingetActionRoot 'winget.ps1'

Need (Test-Path -LiteralPath $startupRoot -PathType Container) "startup layer directory exists: $startupRoot"
Need (Test-Path -LiteralPath $flowsRoot -PathType Container) "platform flow layer directory exists: $flowsRoot"
Need (Test-Path -LiteralPath $actionsRoot -PathType Container) "action layer directory exists: $actionsRoot"
Need (Test-Path -LiteralPath $wingetActionRoot -PathType Container) "winget component directory exists: $wingetActionRoot"
Need (Test-Path -LiteralPath $manifestPath -PathType Leaf) "manifest exists: $manifestPath"
Need (Test-Path -LiteralPath $payloadRoot -PathType Container) "publish root exists: $payloadRoot"
Need (Test-Path -LiteralPath $winEntryPath -PathType Leaf) "Windows public entry exists: $winEntryPath"
Need (-not (Test-Utf8Bom -Path $winEntryPath)) 'win.ps1 has no UTF-8 BOM so irm pipe execution starts at the first PowerShell token'
Need (Test-Path -LiteralPath $bootstrapPath -PathType Leaf) "Windows bootstrap exists: $bootstrapPath"
Need (Test-Utf8Bom -Path $bootstrapPath) 'bootstrap.ps1 uses UTF-8 BOM for Windows PowerShell 5.1'
Need (Test-Path -LiteralPath $windowsFlowPath -PathType Leaf) "Windows platform flow exists: $windowsFlowPath"
Need (Test-Path -LiteralPath $wingetActionCmdPath -PathType Leaf) "winget action cmd exists: $wingetActionCmdPath"
Need (Test-Path -LiteralPath $wingetActionPsPath -PathType Leaf) "winget action helper exists: $wingetActionPsPath"

if (Test-Path -LiteralPath $winEntryPath -PathType Leaf) {
    $winEntry = Get-Content -LiteralPath $winEntryPath -Raw
    Need ($winEntry.Contains("'startup'") -and $winEntry.Contains("'bootstrap.ps1'") -and $winEntry.Contains('https://get.dingjiai.com/startup/bootstrap.ps1') -and $winEntry.Contains('TrimStart([char] 0xFEFF)')) 'win.ps1 delegates to startup/bootstrap.ps1 and strips remote BOM before Invoke-Expression'
}

if (Test-Path -LiteralPath $bootstrapPath -PathType Leaf) {
    $winEntry = Get-Content -LiteralPath $bootstrapPath -Raw
    Need ($winEntry.Contains('[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12')) 'bootstrap.ps1 sets startup downloads to TLS 1.2 rather than preserving older protocols'
    Need ($winEntry.Contains('正在启动中，请勿关闭当前窗口')) 'bootstrap.ps1 tells users startup is in progress and not to close the window'
    Need ($winEntry.Contains('同步启动文件...请稍等')) 'bootstrap.ps1 keeps payload sync progress user-friendly without file counts'
    Need ($winEntry.Contains('已等待') -and $winEntry.Contains('Start-StartupWaitTimer') -and $winEntry.Contains('Stop-StartupWaitTimer')) 'bootstrap.ps1 shows a live wait timer during payload sync'
    Need (-not ($winEntry -match '同步启动文件 \{0\}/\{1\}')) 'bootstrap.ps1 does not expose payload file counts during startup'
    Need ($winEntry.Contains('正在打开管理员 CMD')) 'bootstrap.ps1 tells users when administrator CMD handoff is starting'
    Need ($winEntry.Contains('manifestSha256 = (Get-FileSha256 -Path $script:ManifestPath)')) 'bootstrap.ps1 records manifest hash in startup state for deferred sync'
    Need ($winEntry.Contains('function Test-CmdAutoRun') -and $winEntry.Contains('Command Processor') -and $winEntry.Contains('AutoRun')) 'bootstrap.ps1 detects CMD AutoRun before administrator handoff'
    Need (-not ($winEntry -match 'reg(\.exe)?\s+(add|delete).*AutoRun')) 'bootstrap.ps1 does not modify CMD AutoRun registry values'
    Need ($winEntry.Contains('.Replace(') -and -not $winEntry.Contains('RelativePath -replace')) 'bootstrap.ps1 builds remote payload URLs without regex backslash errors'
    Test-WinBootstrapManifestShapeBehavior -WinEntryPath $bootstrapPath
}

if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
    exit 1
}

$manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
Need ($manifest.schemaVersion -eq 1) 'manifest schemaVersion is 1'
Need ($manifest.channel -eq 'v1-startup') 'manifest channel is v1-startup'
Need (-not [string]::IsNullOrWhiteSpace([string] $manifest.payloadVersion)) 'manifest has payloadVersion'
Need ($manifest.basePath -eq '') 'manifest basePath is publish root'
Need ($manifest.mainEntry -eq 'startup/main.cmd') 'manifest mainEntry is startup/main.cmd'
Need ($manifest.handoffMode -eq 'admin-cmd') 'manifest handoffMode is admin-cmd'
Need ($null -ne $manifest.files -and $manifest.files.Count -gt 0) 'manifest has payload files'

$startupCriticalPayloadPaths = @(
    'startup/main.cmd',
    'startup/ui.ps1',
    'startup/console_guard.ps1',
    'startup/startup_accept.ps1',
    'startup/deferred_payload_sync.ps1'
)
$startupCriticalPathSet = @{}
foreach ($startupCriticalPayloadPath in $startupCriticalPayloadPaths) {
    $startupCriticalPathSet[$startupCriticalPayloadPath] = $true
}

$seenPaths = @{}
$mainEntrySeen = $false
$deferredPayloadSeen = $false
foreach ($file in $manifest.files) {
    $payloadPath = [string] $file.path
    $pathIsRelative = Test-RelativePayloadPath -Path $payloadPath
    Need $pathIsRelative "payload path is relative and safe: $payloadPath"

    if (-not $pathIsRelative) {
        continue
    }

    $normalizedRelativePath = $payloadPath -replace '/', [System.IO.Path]::DirectorySeparatorChar
    $localPath = Join-Path $payloadRoot $normalizedRelativePath
    Need (Test-PathInsideRoot -Path $localPath -Root $payloadRoot) "payload path stays under payload root: $payloadPath"
    $pathKey = $payloadPath.ToLowerInvariant()

    Need (-not $seenPaths.ContainsKey($pathKey)) "payload path is unique: $payloadPath"
    $seenPaths[$pathKey] = $true

    Need (Test-Path -LiteralPath $localPath -PathType Leaf) "payload file exists: $payloadPath"
    Need (Test-Sha256Text -Value ([string] $file.sha256)) "payload file has valid sha256: $payloadPath"
    Need ($file.required -is [bool]) "payload file required is boolean: $payloadPath"
    if ($startupCriticalPathSet.ContainsKey($pathKey)) {
        Need ($file.required -eq $true) "startup-critical payload file is required: $payloadPath"
    } else {
        if ($file.required -eq $false) {
            $deferredPayloadSeen = $true
        }
    }

    if (Test-Path -LiteralPath $localPath -PathType Leaf) {
        $actualHash = Get-Sha256Hex -Path $localPath
        $expectedHash = ([string] $file.sha256).ToLowerInvariant()
        Need ($actualHash -eq $expectedHash) "payload sha256 matches manifest: $payloadPath"
        if ($payloadPath.EndsWith('.cmd', [System.StringComparison]::OrdinalIgnoreCase)) {
            $payloadBytes = [System.IO.File]::ReadAllBytes($localPath)
            Need (($payloadBytes -join ',').Contains('13,10')) "cmd payload uses CRLF line endings for cmd.exe: $payloadPath"
        }
    }

    if ($payloadPath -eq $manifest.mainEntry -and $file.required -eq $true) {
        $mainEntrySeen = $true
    }
}

Need $mainEntrySeen 'manifest includes required main entry'
Need $deferredPayloadSeen 'manifest defers non-menu payload files until task execution'
foreach ($startupCriticalPayloadPath in $startupCriticalPayloadPaths) {
    Need ($seenPaths.ContainsKey($startupCriticalPayloadPath)) "manifest includes startup-critical payload file: $startupCriticalPayloadPath"
}

$requiredPayloadPaths = @(
    'startup/main.cmd',
    'startup/ui.ps1',
    'startup/console_guard.ps1',
    'startup/startup_accept.ps1',
    'startup/deferred_payload_sync.ps1',
    'flows/windows.cmd',
    'actions/winget/winget.cmd',
    'actions/winget/winget.ps1'
)
foreach ($requiredPayloadPath in $requiredPayloadPaths) {
    Need ($seenPaths.ContainsKey($requiredPayloadPath)) "manifest includes three-layer file: $requiredPayloadPath"
}

$mainCmdPath = Join-Path $payloadRoot 'startup/main.cmd'
if (Test-Path -LiteralPath $mainCmdPath -PathType Leaf) {
    $mainCmd = Get-Content -LiteralPath $mainCmdPath -Raw
    Need ($mainCmd -match '--startup-id') 'startup/main.cmd accepts startup id'
    Need ($mainCmd -match '--workspace-root') 'startup/main.cmd accepts workspace root'
    Need ($mainCmd -match '--state') 'startup/main.cmd accepts state path'
    Need ($mainCmd -match '--log-path') 'startup/main.cmd accepts log path'
    Need ($mainCmd -match '--payload-root') 'startup/main.cmd accepts payload root'
    Need ($mainCmd -match '--main-entry-path') 'startup/main.cmd accepts main entry path'
    Need ($mainCmd -match '--source') 'startup/main.cmd accepts source'
    Need ($mainCmd -match '--handoff-mode') 'startup/main.cmd accepts handoff mode'
    Need ($mainCmd.Contains('startup\console_guard.ps1')) 'startup/main.cmd delegates console guard to startup layer'
    Need ($mainCmd.Contains('startup\startup_accept.ps1')) 'startup/main.cmd delegates handoff acceptance to startup layer'
    Need ($mainCmd.Contains('flows\windows.cmd')) 'startup/main.cmd hands control to Windows platform flow'
    Need ($mainCmd.Contains('fltmc >nul 2>nul')) 'startup/main.cmd uses fltmc as administrator probe'
    Need (-not ($mainCmd -match '(?m)^:main_menu\s*$')) 'startup/main.cmd does not own the platform menu'
    Need (-not ($mainCmd -split "`r?`n" | Where-Object { $_ -like 'powershell.exe * -Command "*' } | Select-Object -First 1)) 'startup/main.cmd does not embed startup acceptance PowerShell'
}

$windowsFlowPath = Join-Path $payloadRoot 'flows/windows.cmd'
if (Test-Path -LiteralPath $windowsFlowPath -PathType Leaf) {
    $windowsFlow = Get-Content -LiteralPath $windowsFlowPath -Raw
    Need ($windowsFlow -match '(?m)^:main_menu\s*$') 'flows/windows.cmd owns the Windows menu'
    Need ($windowsFlow.Contains('MENU_1_ACTIONS=A')) 'flows/windows.cmd maps menu 1 to action list A'
    Need ($windowsFlow.Contains('ACTION_A=winget')) 'flows/windows.cmd names action A as winget'
    Need ($windowsFlow.Contains('actions\winget\winget.cmd')) 'flows/windows.cmd calls winget action'
    Need ($windowsFlow.Contains('startup\ui.ps1')) 'flows/windows.cmd renders UI through startup layer UI helper'
    Need ($windowsFlow.Contains('startup\deferred_payload_sync.ps1')) 'flows/windows.cmd prepares deferred action files through startup helper'
    Need ($windowsFlow.Contains('-BaseUrl "https://get.dingjiai.com"')) 'flows/windows.cmd uses publish root for deferred payload sync'
    $windowsFlowLines = $windowsFlow -split "`r?`n"
    foreach ($pageName in @('main', 'install', 'update', 'uninstall')) {
        $renderCallIndex = [array]::IndexOf($windowsFlowLines, "call :render_ui $pageName")
        Need ($renderCallIndex -ge 0 -and $windowsFlowLines[$renderCallIndex + 1] -eq 'if errorlevel 1 exit /b %errorlevel%') "flows/windows.cmd stops after failed UI render for $pageName page"
    }
    Need ($windowsFlow -match '(?m)^if errorlevel 4 exit /b 0\s*$') 'flows/windows.cmd exits administrator window from menu 0'
    Need ($windowsFlow -match '(?m)^chcp 65001 >nul\s*$') 'flows/windows.cmd switches UI rendering to UTF-8 code page'
}

$deferredPayloadSyncPath = Join-Path $payloadRoot 'startup/deferred_payload_sync.ps1'
if (Test-Path -LiteralPath $deferredPayloadSyncPath -PathType Leaf) {
    $deferredPayloadSync = Get-Content -LiteralPath $deferredPayloadSyncPath -Raw
    Need ($deferredPayloadSync.Contains('manifestSha256')) 'deferred_payload_sync.ps1 binds manifest to startup state'
    Need ($deferredPayloadSync.Contains('Test-PathInsideRoot')) 'deferred_payload_sync.ps1 validates path containment'
    Need ($deferredPayloadSync.Contains('$Manifest.basePath')) 'deferred_payload_sync.ps1 honors manifest base path'
    Need ($deferredPayloadSync.Contains('$sourcePath.Replace')) 'deferred_payload_sync.ps1 builds remote URLs from publish source paths'
    Need ($deferredPayloadSync.Contains('Invoke-WebRequest')) 'deferred_payload_sync.ps1 downloads deferred files only when needed'
    Test-PowerShellFileSyntax -Path $deferredPayloadSyncPath
}

$startupAcceptPath = Join-Path $payloadRoot 'startup/startup_accept.ps1'
if (Test-Path -LiteralPath $startupAcceptPath -PathType Leaf) {
    $startupAccept = Get-Content -LiteralPath $startupAcceptPath -Raw
    Need ($startupAccept.Contains('handoffAccepted')) 'startup_accept.ps1 records handoffAccepted'
    Need ($startupAccept.Contains('acceptedHandoffMode')) 'startup_accept.ps1 records accepted handoff mode'
    Need ($startupAccept.Contains('Test-SamePath')) 'startup_accept.ps1 checks entry identity by path'
    Test-PowerShellFileSyntax -Path $startupAcceptPath
    Test-StartupAcceptBehavior -HelperPath $startupAcceptPath
}

$consoleGuardPath = Join-Path $payloadRoot 'startup/console_guard.ps1'
if (Test-Path -LiteralPath $consoleGuardPath -PathType Leaf) {
    $consoleGuard = Get-Content -LiteralPath $consoleGuardPath -Raw
    Need ($consoleGuard.Contains('SetConsoleMode')) 'console_guard.ps1 configures console mode'
    Test-PowerShellFileSyntax -Path $consoleGuardPath
}

$uiPath = Join-Path $payloadRoot 'startup/ui.ps1'
if (Test-Path -LiteralPath $uiPath -PathType Leaf) {
    $ui = Get-Content -LiteralPath $uiPath -Raw
    Need ($ui.Contains("[ValidateSet('main', 'install', 'update', 'uninstall')]")) 'ui.ps1 has fixed page names'
    Need ($ui.Contains('dingjiai installer')) 'ui.ps1 renders installer identity'
    Test-PowerShellFileSyntax -Path $uiPath
}

$wingetActionCmdPath = Join-Path $payloadRoot 'actions/winget/winget.cmd'
if (Test-Path -LiteralPath $wingetActionCmdPath -PathType Leaf) {
    $wingetActionCmd = Get-Content -LiteralPath $wingetActionCmdPath -Raw
    Need ($wingetActionCmd.Contains('winget.ps1')) 'actions/winget/winget.cmd delegates to winget.ps1'
    Need ($wingetActionCmd.Contains('-Action "%ACTION%"')) 'actions/winget/winget.cmd passes selected action to helper'
    Need ($wingetActionCmd.Contains('exit /b 20')) 'actions/winget/winget.cmd fails closed when helper is missing'
    Need ($wingetActionCmd.Contains('exit /b %errorlevel%')) 'actions/winget/winget.cmd propagates helper exit code'
}

$wingetActionPsPath = Join-Path $payloadRoot 'actions/winget/winget.ps1'
if (Test-Path -LiteralPath $wingetActionPsPath -PathType Leaf) {
    $wingetActionPs = Get-Content -LiteralPath $wingetActionPsPath -Raw
    Need ($wingetActionPs.Contains('[ValidateSet(''ensure'')]')) 'actions/winget/winget.ps1 exposes explicit ensure action'
    Need ($wingetActionPs.Contains('$script:ComponentName = ''winget''')) 'actions/winget/winget.ps1 reports winget component'
    Need ($wingetActionPs.Contains('$script:ActionMode = ''report-only''')) 'actions/winget/winget.ps1 remains report-only in current stage'
    Need ($wingetActionPs.Contains('$script:DependencyBlockerExitCode = 60')) 'actions/winget/winget.ps1 uses dependency blocker exit code 60'
    Need ($wingetActionPs.Contains('$script:HelperFailureExitCode = 70')) 'actions/winget/winget.ps1 uses helper failure exit code 70'
    Need ($wingetActionPs.Contains('https://cdn.winget.microsoft.com/cache')) 'actions/winget/winget.ps1 checks official winget source URL'
    Need (-not ($wingetActionPs -match '(?m)^\s*&?\s*winget(\.exe)?\s+install')) 'actions/winget/winget.ps1 does not install packages in report-only stage'
    Need (-not ($wingetActionPs -match '(?m)^\s*Add-AppxPackage')) 'actions/winget/winget.ps1 does not install App Installer packages'
    Need (-not ($wingetActionPs -match '(?m)^\s*&?\s*winget(\.exe)?\s+source\s+(reset|add|update)')) 'actions/winget/winget.ps1 does not mutate winget sources'
    Test-PowerShellFileSyntax -Path $wingetActionPsPath
}

if (Test-Path -LiteralPath $winEntryPath -PathType Leaf) {
    Need (-not (Test-Utf8Bom -Path $winEntryPath)) 'win.ps1 has no UTF-8 BOM for irm pipe execution'
    Test-PowerShellFileSyntax -Path $winEntryPath
}

if (Test-Path -LiteralPath $bootstrapPath -PathType Leaf) {
    Need (Test-Utf8Bom -Path $bootstrapPath) 'bootstrap.ps1 uses UTF-8 BOM for Windows PowerShell 5.1'
    Test-PowerShellFileSyntax -Path $bootstrapPath

    $winEntry = Get-Content -LiteralPath $bootstrapPath -Raw
    Need ($winEntry -match '\$script:MinimumPowerShellVersion\s*=\s*\[version\]''5\.1''') 'bootstrap.ps1 requires PowerShell 5.1+'
    Need ($winEntry -match '\$script:MinimumWindowsBuild\s*=\s*17763') 'bootstrap.ps1 requires Windows build 17763+'
    Need ($winEntry -match 'function Get-StartupFailureSuggestion') 'bootstrap.ps1 has failure suggestion mapper'
    Need ($winEntry -match "'handoff_failed'") 'bootstrap.ps1 maps handoff failure suggestion'
    Need ($winEntry -match 'function Write-StartupFailureMessage') 'bootstrap.ps1 has unified failure message writer'
    Need ($winEntry.Contains('manifest_read_failed')) 'bootstrap.ps1 uses manifest_read_failed reason'
    Need ($winEntry.Contains('manifest_schema_invalid')) 'bootstrap.ps1 uses manifest_schema_invalid reason'
    Need ($winEntry.Contains('payload_path_invalid')) 'bootstrap.ps1 uses payload_path_invalid reason'
    Need ($winEntry.Contains('payload_download_failed')) 'bootstrap.ps1 uses payload_download_failed reason'
    Need ($winEntry.Contains('entry_shape_invalid')) 'bootstrap.ps1 uses entry_shape_invalid reason'
    Need ($winEntry.Contains('handoff_timeout')) 'bootstrap.ps1 uses handoff_timeout reason'
    Need ($winEntry.Contains('function Test-PathInsideRoot')) 'bootstrap.ps1 has path containment helper'
    Need ($winEntry.Contains('Test-PathInsideRoot -Path $rootedPath -Root $Root')) 'bootstrap.ps1 validates payload relative paths by containment'
    Need ($winEntry -match 'failureSuggestion') 'bootstrap.ps1 writes failure suggestion to state'
    Need ($winEntry -match 'failureLogPath') 'bootstrap.ps1 writes failure log path to state'
    Need ($winEntry -match 'function Test-HandoffAcceptedState') 'bootstrap.ps1 validates handoff accepted state'
    Need ($winEntry -match 'acceptedWorkspaceRoot' -and $winEntry -match 'acceptedStatePath' -and $winEntry -match 'acceptedLogPath' -and $winEntry -match 'acceptedPayloadRoot' -and $winEntry -match 'acceptedMainEntryPath' -and $winEntry -match 'acceptedSource' -and $winEntry -match 'acceptedHandoffMode') 'bootstrap.ps1 checks handoff accepted identity fields'
    Need ($winEntry -match "Add-StartupCheck -Name 'windows_build'") 'bootstrap.ps1 checks Windows build'
    Need ($winEntry -match "Add-StartupCheck -Name 'powershell_version'") 'bootstrap.ps1 checks PowerShell version'
    Need ($winEntry -match '\$missingCapabilities') 'bootstrap.ps1 checks runtime capabilities'
    Need ($winEntry -match '\$cmdArguments\s*=\s*''/c') 'bootstrap.ps1 launches administrator cmd with /c'
}

if ($script:Failed) {
    Write-Host 'Windows startup self-check failed.' -ForegroundColor Red
    exit 1
}

Write-Host 'Windows startup self-check passed.'
exit 0
