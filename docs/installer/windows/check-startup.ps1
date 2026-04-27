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
    basePath = 'payload'
    mainEntry = 'main.cmd'
    handoffMode = 'admin-cmd'
    files = @(
        [pscustomobject] @{ path = 'main.cmd'; sha256 = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'; required = $true },
        [pscustomobject] @{ path = 'lib\windows\startup_accept.ps1'; sha256 = 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'; required = $true }
    )
}
Assert-ManifestShape -Manifest $manifest
'@

    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($snippet))
    $process = Start-Process -FilePath 'powershell.exe' -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-EncodedCommand', $encoded) -NoNewWindow -Wait -PassThru
    Need ($process.ExitCode -eq 0) 'win.ps1 manifest shape accepts slash and backslash payload paths without runtime errors'
}

$manifestPath = Join-Path $PSScriptRoot 'manifest.json'
$payloadRoot = Join-Path $PSScriptRoot 'payload'
$docsRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$winEntryPath = Join-Path $docsRoot 'win.ps1'
$bootstrapPath = Join-Path $docsRoot 'bootstrap.ps1'

Need (Test-Path -LiteralPath $manifestPath -PathType Leaf) "manifest exists: $manifestPath"
Need (Test-Path -LiteralPath $payloadRoot -PathType Container) "payload directory exists: $payloadRoot"
Need (Test-Path -LiteralPath $winEntryPath -PathType Leaf) "Windows public entry exists: $winEntryPath"
Need (-not (Test-Utf8Bom -Path $winEntryPath)) 'win.ps1 has no UTF-8 BOM so irm pipe execution starts at the first PowerShell token'
Need (Test-Path -LiteralPath $bootstrapPath -PathType Leaf) "Windows bootstrap exists: $bootstrapPath"
Need (Test-Utf8Bom -Path $bootstrapPath) 'bootstrap.ps1 uses UTF-8 BOM for Windows PowerShell 5.1'

if (Test-Path -LiteralPath $winEntryPath -PathType Leaf) {
    $winEntry = Get-Content -LiteralPath $winEntryPath -Raw
    Need ($winEntry.Contains('bootstrap.ps1') -and $winEntry.Contains('TrimStart([char] 0xFEFF)')) 'win.ps1 delegates to bootstrap.ps1 and strips remote BOM before Invoke-Expression'
}

if (Test-Path -LiteralPath $bootstrapPath -PathType Leaf) {
    $winEntry = Get-Content -LiteralPath $bootstrapPath -Raw
    Need ($winEntry.Contains('[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12')) 'bootstrap.ps1 sets startup downloads to TLS 1.2 rather than preserving older protocols'
    Need ($winEntry.Contains('function Test-CmdAutoRun') -and $winEntry.Contains('Command Processor') -and $winEntry.Contains('AutoRun')) 'bootstrap.ps1 detects CMD AutoRun before administrator handoff'
    Need (-not ($winEntry -match 'reg(\.exe)?\s+(add|delete).*AutoRun')) 'bootstrap.ps1 does not modify CMD AutoRun registry values'
    Test-WinBootstrapManifestShapeBehavior -WinEntryPath $bootstrapPath
}

if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
    exit 1
}

$manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
Need ($manifest.schemaVersion -eq 1) 'manifest schemaVersion is 1'
Need ($manifest.channel -eq 'v1-startup') 'manifest channel is v1-startup'
Need (-not [string]::IsNullOrWhiteSpace([string] $manifest.payloadVersion)) 'manifest has payloadVersion'
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
    Need (Test-PathInsideRoot -Path $localPath -Root $payloadRoot) "payload path stays under payload root: $payloadPath"
    $pathKey = $payloadPath.ToLowerInvariant()

    Need (-not $seenPaths.ContainsKey($pathKey)) "payload path is unique: $payloadPath"
    $seenPaths[$pathKey] = $true

    Need (Test-Path -LiteralPath $localPath -PathType Leaf) "payload file exists: $payloadPath"
    Need (Test-Sha256Text -Value ([string] $file.sha256)) "payload file has valid sha256: $payloadPath"
    Need ($file.required -is [bool]) "payload file required is boolean: $payloadPath"
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

$requiredPayloadPaths = @(
    'flows/windows/install/entry.cmd',
    'flows/windows/install/checkpoints/00_preflight.cmd',
    'flows/windows/install/checkpoints/10_winget.cmd',
    'flows/windows/install/checkpoints/15_app_installer_download.cmd',
    'flows/windows/install/checkpoints/20_git.cmd',
    'flows/windows/install/checkpoints/30_claude.cmd',
    'flows/windows/install/checkpoints/40_enhancements.cmd',
    'flows/windows/install/checkpoints/50_config.cmd',
    'flows/windows/install/checkpoints/90_finalize.cmd',
    'flows/windows/update/entry.cmd',
    'flows/windows/update/checkpoints/00_preflight.cmd',
    'flows/windows/update/checkpoints/20_git.cmd',
    'flows/windows/update/checkpoints/30_claude.cmd',
    'flows/windows/update/checkpoints/40_enhancements.cmd',
    'flows/windows/update/checkpoints/90_finalize.cmd',
    'flows/windows/uninstall/entry.cmd',
    'flows/windows/uninstall/checkpoints/00_preflight.cmd',
    'flows/windows/uninstall/checkpoints/30_claude.cmd',
    'flows/windows/uninstall/checkpoints/40_enhancements.cmd',
    'flows/windows/uninstall/checkpoints/90_finalize.cmd',
    'lib/windows/checkpoint_runner.cmd',
    'lib/windows/startup_accept.ps1',
    'lib/windows/console_guard.ps1',
    'lib/windows/ui_bridge.cmd',
    'lib/windows/log.cmd',
    'lib/windows/state.cmd',
    'lib/windows/detect.cmd',
    'lib/windows/paths.cmd',
    'lib/windows/exec.cmd',
    'lib/windows/winget.ps1',
    'lib/windows/git.ps1',
    'lib/windows/download.ps1',
    'tasks/install.cmd',
    'tasks/update.cmd',
    'tasks/uninstall.cmd'
)
foreach ($requiredPayloadPath in $requiredPayloadPaths) {
    Need ($seenPaths.ContainsKey($requiredPayloadPath)) "manifest includes payload structure file: $requiredPayloadPath"
}

$checkpointRunnerPath = Join-Path $payloadRoot 'lib/windows/checkpoint_runner.cmd'
Need (Test-Path -LiteralPath $checkpointRunnerPath -PathType Leaf) 'checkpoint runner exists'
if (Test-Path -LiteralPath $checkpointRunnerPath -PathType Leaf) {
    $checkpointRunner = Get-Content -LiteralPath $checkpointRunnerPath -Raw
    Need ($checkpointRunner.Contains('DINGJIAI_CHECKPOINT_HELPER')) 'checkpoint runner reads helper environment'
    Need ($checkpointRunner.Contains('DINGJIAI_CHECKPOINT_FLOW')) 'checkpoint runner reads flow environment'
    Need ($checkpointRunner.Contains('DINGJIAI_CHECKPOINT_NAME')) 'checkpoint runner reads checkpoint environment'
    Need ($checkpointRunner.Contains('powershell.exe -NoProfile -ExecutionPolicy Bypass -File')) 'checkpoint runner invokes PowerShell helper'
    Need ($checkpointRunner.Contains('exit /b %errorlevel%')) 'checkpoint runner propagates helper exit code'
}


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
    Need ($mainCmd -match 'ui\.ps1') 'main.cmd delegates UI rendering to ui.ps1'
    Need ($mainCmd.Contains('flows\windows\install\entry.cmd')) 'main.cmd routes menu 1 to install flow entry'
    Need ($mainCmd.Contains('flows\windows\update\entry.cmd')) 'main.cmd routes menu 2 to update flow entry'
    Need ($mainCmd.Contains('flows\windows\uninstall\entry.cmd')) 'main.cmd routes menu 3 to uninstall flow entry'
    Need ($mainCmd -match '(?m)^if errorlevel 4 exit\s*$') 'main.cmd exits administrator window from menu 0'
    Need ($mainCmd -match '(?m)^chcp 65001 >nul\s*$') 'main.cmd switches UI rendering to UTF-8 code page'
    Need ($mainCmd.Contains('lib\windows\startup_accept.ps1')) 'main.cmd delegates handoff acceptance to startup_accept.ps1'
    Need ($mainCmd.Contains('fltmc >nul 2>nul')) 'main.cmd uses fltmc as administrator probe'
    Need ($mainCmd.Contains('powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%PAYLOAD_ROOT%\lib\windows\startup_accept.ps1"')) 'main.cmd invokes startup acceptance helper as a file'
    Need (-not $mainCmd.Contains('function Full([string]$Path)')) 'main.cmd no longer embeds startup acceptance PowerShell logic'

    $startupAcceptPath = Join-Path $payloadRoot 'lib/windows/startup_accept.ps1'
    Need (Test-Path -LiteralPath $startupAcceptPath -PathType Leaf) 'startup_accept.ps1 helper exists'
    Need (Test-Utf8Bom -Path $startupAcceptPath) 'startup_accept.ps1 uses UTF-8 BOM for Windows PowerShell 5.1'
    if (Test-Path -LiteralPath $startupAcceptPath -PathType Leaf) {
        Test-PowerShellFileSyntax -Path $startupAcceptPath
        Test-StartupAcceptBehavior -HelperPath $startupAcceptPath
    }

    $consoleGuardPath = Join-Path $payloadRoot 'lib/windows/console_guard.ps1'
    Need (Test-Path -LiteralPath $consoleGuardPath -PathType Leaf) 'console_guard.ps1 helper exists'
    Need (Test-Utf8Bom -Path $consoleGuardPath) 'console_guard.ps1 uses UTF-8 BOM for Windows PowerShell 5.1'
    if (Test-Path -LiteralPath $consoleGuardPath -PathType Leaf) {
        Test-PowerShellFileSyntax -Path $consoleGuardPath
        $consoleGuard = Get-Content -LiteralPath $consoleGuardPath -Raw
        Need ($consoleGuard.Contains('QuickEdit') -and $consoleGuard.Contains('GetConsoleMode') -and $consoleGuard.Contains('SetConsoleMode')) 'console_guard.ps1 disables QuickEdit on the current console'
        Need ($consoleGuard.Contains("throw 'failed to disable QuickEdit mode'")) 'console_guard.ps1 fails closed when QuickEdit cannot be disabled'
        Need (-not ($consoleGuard -match 'reg(\.exe)?\s+(add|delete).*QuickEdit')) 'console_guard.ps1 does not modify QuickEdit registry values'
        Need (-not ($consoleGuard.Contains('Start-Process') -or $consoleGuard.Contains('conhost.exe') -or $consoleGuard.Contains('cmd.exe'))) 'console_guard.ps1 does not restart console host'
    }

    $uiPath = Join-Path $payloadRoot 'ui.ps1'
    Need (Test-Path -LiteralPath $uiPath -PathType Leaf) 'ui.ps1 exists'
    Need (Test-Utf8Bom -Path $uiPath) 'ui.ps1 uses UTF-8 BOM for Windows PowerShell 5.1'
    if (Test-Path -LiteralPath $uiPath -PathType Leaf) {
        Test-PowerShellFileSyntax -Path $uiPath
    }

    $flowEntries = @(
        'flows\windows\install\entry.cmd',
        'flows\windows\update\entry.cmd',
        'flows\windows\uninstall\entry.cmd'
    )
    foreach ($flowEntry in $flowEntries) {
        $flowPath = Join-Path $payloadRoot $flowEntry
        Need (Test-Path -LiteralPath $flowPath -PathType Leaf) "flow entry exists: $flowEntry"
        if (Test-Path -LiteralPath $flowPath -PathType Leaf) {
            $flowText = Get-Content -LiteralPath $flowPath -Raw
            Need ($flowText.Contains('checkpoints\')) "flow entry calls checkpoints: $flowEntry"
            Need ($flowText.Contains('if errorlevel 1 exit /b %errorlevel%')) "flow entry gates on checkpoint errorlevel: $flowEntry"
        }
    }



    $wingetCheckpointPath = Join-Path $payloadRoot 'flows/windows/install/checkpoints/10_winget.cmd'
    Need (Test-Path -LiteralPath $wingetCheckpointPath -PathType Leaf) 'winget checkpoint cmd exists'
    if (Test-Path -LiteralPath $wingetCheckpointPath -PathType Leaf) {
        $wingetCheckpoint = Get-Content -LiteralPath $wingetCheckpointPath -Raw
        Need ($wingetCheckpoint.Contains('lib\windows\checkpoint_runner.cmd')) 'winget checkpoint delegates to checkpoint runner'
        Need ($wingetCheckpoint.Contains('DINGJIAI_CHECKPOINT_HELPER')) 'winget checkpoint sets helper environment'
        Need ($wingetCheckpoint.Contains('%*')) 'winget checkpoint forwards helper arguments for contract tests'
    }

    $wingetHelperPath = Join-Path $payloadRoot 'lib/windows/winget.ps1'
    Need (Test-Path -LiteralPath $wingetHelperPath -PathType Leaf) 'winget.ps1 helper exists'
    Need (Test-Utf8Bom -Path $wingetHelperPath) 'winget.ps1 uses UTF-8 BOM for Windows PowerShell 5.1'
    if (Test-Path -LiteralPath $wingetHelperPath -PathType Leaf) {
        Test-PowerShellFileSyntax -Path $wingetHelperPath
        $wingetHelper = Get-Content -LiteralPath $wingetHelperPath -Raw
        Need ($wingetHelper.Contains('function Get-WingetDiscovery')) 'winget.ps1 has discovery stage'
        Need ($wingetHelper.Contains('function Get-RealWingetDiscovery')) 'winget.ps1 keeps real discovery separate from test scenarios'
        Need ($wingetHelper.Contains('function Get-TestWingetDiscovery')) 'winget.ps1 has deterministic test discovery scenarios'
        Need ($wingetHelper.Contains('function Get-WingetDecision')) 'winget.ps1 has decision stage'
        Need ($wingetHelper.Contains('function New-WingetResult')) 'winget.ps1 builds a structured result object'
        Need ($wingetHelper.Contains('function New-HelperFailureResult')) 'winget.ps1 builds structured helper failure results'
        Need ($wingetHelper.Contains('function ConvertTo-ProcessArgument')) 'winget.ps1 quotes probe arguments'
        Need ($wingetHelper.Contains('WaitForExit($TimeoutSeconds * 1000)')) 'winget.ps1 bounds probe runtime with timeout'
        Need ($wingetHelper.Contains('BeginOutputReadLine')) 'winget.ps1 reads stdout asynchronously to avoid pipe buffer deadlocks'
        Need ($wingetHelper.Contains('BeginErrorReadLine')) 'winget.ps1 reads stderr asynchronously to avoid pipe buffer deadlocks'
        Need ($wingetHelper.Contains('Register-ObjectEvent')) 'winget.ps1 captures async probe output in Windows PowerShell 5.1'
        Need ($wingetHelper.Contains('-TimedOut $true')) 'winget.ps1 reports probe timeout state'
        Need ($wingetHelper.Contains('function Test-WingetSourceOutput')) 'winget.ps1 validates winget source output'
        Need ($wingetHelper.Contains('function Get-AppxDeploymentFacts')) 'winget.ps1 reports Appx deployment repair facts'
        Need ($wingetHelper.Contains('Get-Command Add-AppxPackage')) 'winget.ps1 probes Add-AppxPackage availability'
        Need ($wingetHelper.Contains('Get-Service AppXSvc')) 'winget.ps1 probes AppXSvc availability'
        Need ($wingetHelper.Contains('repairLikelySupported')) 'winget.ps1 reports whether App Installer repair is likely supported'
        Need ($wingetHelper.Contains('https://cdn.winget.microsoft.com/cache')) 'winget.ps1 requires the official winget source URL'
        Need ($wingetHelper.Contains('sourceHasWinget')) 'winget.ps1 reports official winget source presence'
        Need ($wingetHelper.Contains('officialSource')) 'winget.ps1 reports official source trust facts'
        Need ($wingetHelper.Contains('environment') -and $wingetHelper.Contains('versionProbe') -and $wingetHelper.Contains('sourceProbe') -and $wingetHelper.Contains('appxDeployment')) 'winget.ps1 reports structured discovery facts'
        Need ($wingetHelper.Contains('HelperFailureExitCode = 70')) 'winget.ps1 separates helper failure exit code'
        Need ($wingetHelper.Contains('DependencyBlockerExitCode = 60')) 'winget.ps1 locks dependency blocker exit code'
        Need ($wingetHelper.Contains('dependencyBlocker')) 'winget.ps1 reports dependency blocker exit code contract'
        Need ($wingetHelper.Contains("ContractVersion = 'checkpoint.v1'")) 'winget.ps1 declares checkpoint.v1 contract'
        Need ($wingetHelper.Contains("ComponentName = 'winget'")) 'winget.ps1 declares winget component'
        Need ($wingetHelper.Contains('exitCodeContract')) 'winget.ps1 reports exit code contract'
        Need ($wingetHelper.Contains('Get-Command winget.exe')) 'winget.ps1 discovers active winget command'
        Need ($wingetHelper.Contains("'--version'")) 'winget.ps1 probes winget version'
        Need ($wingetHelper.Contains("'source', 'list'")) 'winget.ps1 probes winget sources'
        Need ($wingetHelper.Contains('mutationAllowed')) 'winget.ps1 reports mutation boundary'
        Need ($wingetHelper.Contains('actionMode')) 'winget.ps1 reports action boundary'
        Need ($wingetHelper.Contains('AllowedStatuses')) 'winget.ps1 locks status enum contract'
        Need ($wingetHelper.Contains('AllowedDecisions')) 'winget.ps1 locks decision enum contract'
        foreach ($status in @('healthy', 'missing', 'appx_deployment_unavailable', 'command_broken', 'command_timeout', 'source_broken', 'source_timeout', 'source_missing', 'source_untrusted', 'helper_failed')) {
            Need ($wingetHelper.Contains("'$status'")) "winget.ps1 status enum includes $status"
        }
        Need ($wingetHelper.Contains('DecisionReportExitCode = 0')) 'winget.ps1 locks healthy exit code'
        Need ($wingetHelper.Contains('function Test-ResultContract')) 'winget.ps1 validates result contract before output'
        Need ($wingetHelper.Contains('function Get-ProjectLocalRoot')) 'winget.ps1 anchors result files under project local root'
        Need ($wingetHelper.Contains('function Get-NormalizedFullPath')) 'winget.ps1 normalizes result paths before containment checks'
        Need ($wingetHelper.Contains('function Test-PathInsideRoot')) 'winget.ps1 validates result path containment'
        Need ($wingetHelper.Contains('ResultPath')) 'winget.ps1 supports optional result file output'
        Need ($wingetHelper.Contains('function Write-WingetResultFile')) 'winget.ps1 writes optional json result file'
        Need ($wingetHelper.Contains('winget result path must stay under')) 'winget.ps1 restricts result files to project local root'
        Need ($wingetHelper.Contains('winget result file write failed')) 'winget.ps1 reports result file write failures explicitly'
        Need ($wingetHelper.Contains('SkipResultFile')) 'winget.ps1 avoids repeated result file failure during fallback output'
        Need ($wingetHelper.Contains('discovery-diagnose-decision-only')) 'winget.ps1 stays in sample discovery mode'
        Need ($wingetHelper.Contains('report-only')) 'winget.ps1 stays report-only'
        Need ($wingetHelper.Contains("ValidateSet('Text', 'Json')")) 'winget.ps1 declares text and json output modes'
        Need ($wingetHelper.Contains('ConvertTo-Json -Depth 6')) 'winget.ps1 emits structured json output'
        Need ($wingetHelper.Contains('function ConvertTo-JsonText')) 'winget.ps1 emits ASCII-safe json for pipeline parsing'
        Need ($wingetHelper.Contains('TestScenario')) 'winget.ps1 exposes deterministic test scenarios'
        Need ($wingetHelper.Contains('function Get-TestScenarioExpectation')) 'winget.ps1 locks deterministic scenario expectations'
        Need ($wingetHelper.Contains('function Test-TestScenarioContract')) 'winget.ps1 validates deterministic scenario contracts'
        Need ($wingetHelper.Contains('function Assert-EqualValue')) 'winget.ps1 fails fast on scenario contract drift'
        foreach ($scenario in @('healthy', 'missing', 'appx_unavailable', 'version_failed', 'version_timeout', 'source_failed', 'source_timeout', 'source_missing', 'source_untrusted', 'helper_failed')) {
            Need ($wingetHelper.Contains("'$scenario'")) "winget.ps1 test scenarios include $scenario"
        }
        Need ($wingetHelper.Contains("status = 'command_broken'")) 'winget.ps1 maps version_failed to command_broken'
        Need ($wingetHelper.Contains("status = 'command_timeout'")) 'winget.ps1 maps version_timeout to command_timeout'
        Need ($wingetHelper.Contains("status = 'source_broken'")) 'winget.ps1 maps source_failed to source_broken'
        Need ($wingetHelper.Contains("status = 'source_timeout'")) 'winget.ps1 maps source_timeout to source_timeout'
        Need ($wingetHelper.Contains("status = 'source_missing'")) 'winget.ps1 maps source_missing to source_missing'
        Need ($wingetHelper.Contains("status = 'source_untrusted'")) 'winget.ps1 maps source_untrusted to source_untrusted'
        Need ($wingetHelper.Contains('officialSourceNameMatched = $true')) 'winget.ps1 distinguishes untrusted source by name match'
        Need ($wingetHelper.Contains('officialSourceUrlMatched = $false')) 'winget.ps1 distinguishes untrusted source by URL mismatch'
        Need ($wingetHelper.Contains("Result.decision.status -eq 'helper_failed'")) 'winget.ps1 skips scenario self-check for helper failures'
        Need (-not $wingetHelper.Contains("'source', 'reset'")) 'winget.ps1 does not reset winget sources'
        Need (-not $wingetHelper.Contains("'source', 'add'")) 'winget.ps1 does not add winget sources'
        Need (-not $wingetHelper.Contains("'source', 'update'")) 'winget.ps1 does not update winget sources'
        Need (-not $wingetHelper.Contains("'install', '--")) 'winget.ps1 does not invoke winget install command arguments'
        Need (-not $wingetHelper.Contains('winget.exe install')) 'winget.ps1 does not invoke winget install command text'
    }

    $downloadCheckpointPath = Join-Path $payloadRoot 'flows/windows/install/checkpoints/15_app_installer_download.cmd'
    Need (Test-Path -LiteralPath $downloadCheckpointPath -PathType Leaf) 'App Installer download checkpoint cmd exists'
    if (Test-Path -LiteralPath $downloadCheckpointPath -PathType Leaf) {
        $downloadCheckpoint = Get-Content -LiteralPath $downloadCheckpointPath -Raw
        Need ($downloadCheckpoint.Contains('lib\windows\checkpoint_runner.cmd')) 'App Installer download checkpoint delegates to checkpoint runner'
        Need ($downloadCheckpoint.Contains('DINGJIAI_CHECKPOINT_HELPER')) 'App Installer download checkpoint sets helper environment'
        Need ($downloadCheckpoint.Contains('%*')) 'App Installer download checkpoint forwards helper arguments for contract tests'
        Need ($downloadCheckpoint.Contains('app-installer-download')) 'App Installer download checkpoint names the checkpoint explicitly'
        Need ($downloadCheckpoint.Contains('-ArtifactKind "AppInstaller"')) 'App Installer download checkpoint declares AppInstaller artifact kind'
        Need ($downloadCheckpoint.Contains('-ArtifactName "app-installer.msixbundle"')) 'App Installer download checkpoint declares App Installer artifact name'
    }

    $downloadHelperPath = Join-Path $payloadRoot 'lib/windows/download.ps1'
    Need (Test-Path -LiteralPath $downloadHelperPath -PathType Leaf) 'download.ps1 helper exists'
    Need (Test-Utf8Bom -Path $downloadHelperPath) 'download.ps1 uses UTF-8 BOM for Windows PowerShell 5.1'
    if (Test-Path -LiteralPath $downloadHelperPath -PathType Leaf) {
        Test-PowerShellFileSyntax -Path $downloadHelperPath
        $downloadHelper = Get-Content -LiteralPath $downloadHelperPath -Raw
        Need ($downloadHelper.Contains("ContractVersion = 'checkpoint.v1'")) 'download.ps1 declares checkpoint.v1 contract'
        Need ($downloadHelper.Contains("ComponentName = 'download'")) 'download.ps1 declares download component'
        Need ($downloadHelper.Contains('download-only-staging')) 'download.ps1 stays in download-only staging mode'
        Need ($downloadHelper.Contains('DownloadFailureExitCode = 60')) 'download.ps1 separates download failure exit code'
        Need ($downloadHelper.Contains('HelperFailureExitCode = 70')) 'download.ps1 separates helper failure exit code'
        Need ($downloadHelper.Contains('DecisionReportExitCode = 0')) 'download.ps1 locks decision report exit code'
        Need ($downloadHelper.Contains('AllowedStatuses')) 'download.ps1 locks status enum contract'
        Need ($downloadHelper.Contains('AllowedDecisions')) 'download.ps1 locks decision enum contract'
        Need ($downloadHelper.Contains('ExpectedSha256')) 'download.ps1 requires expected sha256 for real downloads'
        Need ($downloadHelper.Contains('AllowedHosts')) 'download.ps1 requires an allowed host list for real downloads'
        Need ($downloadHelper.Contains('AllowDownload')) 'download.ps1 keeps real download behind explicit opt-in'
        Need ($downloadHelper.Contains('metadataComplete')) 'download.ps1 reports whether source metadata is complete'
        Need ($downloadHelper.Contains('downloadEnabled')) 'download.ps1 reports whether real download is enabled'
        Need ($downloadHelper.Contains('expectedSha256Valid')) 'download.ps1 reports expected sha256 validity'
        Need ($downloadHelper.Contains('expectedSha256Normalized')) 'download.ps1 reports normalized expected sha256'
        Need ($downloadHelper.Contains('Test-DownloadMetadataComplete')) 'download.ps1 centralizes metadata completeness checks'
        Need ($downloadHelper.Contains('download metadata incomplete')) 'download.ps1 blocks real download when metadata is incomplete'
        Need ($downloadHelper.Contains('Invoke-WebRequest')) 'download.ps1 performs bounded HTTP download'
        Need ($downloadHelper.Contains('TimeoutSec')) 'download.ps1 passes timeout to download command'
        Need ($downloadHelper.Contains('Get-Sha256Hex')) 'download.ps1 verifies downloaded file hash'
        Need ($downloadHelper.Contains('.part')) 'download.ps1 writes to a partial file before final artifact move'
        Need ($downloadHelper.Contains('Move-Item')) 'download.ps1 promotes verified staging artifact after hash check'
        Need ($downloadHelper.Contains('source_blocked')) 'download.ps1 blocks unapproved sources'
        Need ($downloadHelper.Contains('hash_mismatch')) 'download.ps1 reports hash mismatch explicitly'
        Need ($downloadHelper.Contains('missing_metadata')) 'download.ps1 refuses real download without locked metadata'
        Need ($downloadHelper.Contains('function Write-DownloadResultFile')) 'download.ps1 writes optional json result file'
        Need ($downloadHelper.Contains('function ConvertTo-JsonText')) 'download.ps1 emits ASCII-safe json for pipeline parsing'
        Need ($downloadHelper.Contains('SkipResultFile')) 'download.ps1 avoids repeated result file failure during fallback output'
        Need ($downloadHelper.Contains('function Test-ResultContract')) 'download.ps1 validates result contract before output'
        Need ($downloadHelper.Contains('TestScenario')) 'download.ps1 exposes deterministic test scenarios'
        Need ($downloadHelper.Contains('helper_failed')) 'download.ps1 can simulate helper failure contract'
        Need ($downloadHelper.Contains('MinimumRetryCount = 0')) 'download.ps1 locks minimum retry count'
        Need ($downloadHelper.Contains('MaximumRetryCount = 5')) 'download.ps1 locks maximum retry count'
        Need ($downloadHelper.Contains('MinimumTimeoutSeconds = 5')) 'download.ps1 locks minimum timeout seconds'
        Need ($downloadHelper.Contains('MaximumTimeoutSeconds = 120')) 'download.ps1 locks maximum timeout seconds'
        Need ($downloadHelper.Contains('function Get-ProjectLocalRoot')) 'download.ps1 anchors writable paths under project local root'
        Need ($downloadHelper.Contains('function Get-ProjectStagingRoot')) 'download.ps1 anchors staging under project local root'
        Need ($downloadHelper.Contains('function Test-PathInsideRoot')) 'download.ps1 validates path containment'
        Need ($downloadHelper.Contains('function Get-ParameterBoundaryFailureResult')) 'download.ps1 rejects unsafe parameter boundaries before download'
        Need ($downloadHelper.Contains('retry count outside allowed range')) 'download.ps1 rejects unbounded retry counts'
        Need ($downloadHelper.Contains('timeout seconds outside allowed range')) 'download.ps1 rejects unbounded timeout seconds'
        Need ($downloadHelper.Contains('staging root outside project local staging root')) 'download.ps1 rejects external staging roots'
        Need ($downloadHelper.Contains('partial file deleted')) 'download.ps1 deletes partial files on hash mismatch'
        Need ($downloadHelper.Contains('download result path must stay under')) 'download.ps1 restricts result files to project local root'
    }

    $gitCheckpointPath = Join-Path $payloadRoot 'flows/windows/install/checkpoints/20_git.cmd'
    Need (Test-Path -LiteralPath $gitCheckpointPath -PathType Leaf) 'Git checkpoint cmd exists'
    if (Test-Path -LiteralPath $gitCheckpointPath -PathType Leaf) {
        $gitCheckpoint = Get-Content -LiteralPath $gitCheckpointPath -Raw
        Need ($gitCheckpoint.Contains('lib\windows\checkpoint_runner.cmd')) 'Git checkpoint delegates to checkpoint runner'
        Need ($gitCheckpoint.Contains('DINGJIAI_CHECKPOINT_HELPER')) 'Git checkpoint sets helper environment'
        Need ($gitCheckpoint.Contains('%*')) 'Git checkpoint forwards helper arguments for contract tests'
    }

    $gitHelperPath = Join-Path $payloadRoot 'lib/windows/git.ps1'
    Need (Test-Path -LiteralPath $gitHelperPath -PathType Leaf) 'git.ps1 helper exists'
    Need (Test-Utf8Bom -Path $gitHelperPath) 'git.ps1 uses UTF-8 BOM for Windows PowerShell 5.1'
    if (Test-Path -LiteralPath $gitHelperPath -PathType Leaf) {
        Test-PowerShellFileSyntax -Path $gitHelperPath
        $gitHelper = Get-Content -LiteralPath $gitHelperPath -Raw
        Need ($gitHelper.Contains('function Get-GitDiscovery')) 'git.ps1 has discovery stage'
        Need ($gitHelper.Contains('function Get-RealGitDiscovery')) 'git.ps1 keeps real discovery separate from test scenarios'
        Need ($gitHelper.Contains('function Get-TestGitDiscovery')) 'git.ps1 has deterministic test discovery scenarios'
        Need ($gitHelper.Contains('function Get-GitDecision')) 'git.ps1 has decision stage'
        Need ($gitHelper.Contains('function New-GitResult')) 'git.ps1 builds a structured result object'
        Need ($gitHelper.Contains('function New-HelperFailureResult')) 'git.ps1 builds structured helper failure results'
        Need ($gitHelper.Contains('function ConvertTo-ProcessArgument')) 'git.ps1 quotes probe arguments'
        Need ($gitHelper.Contains('WaitForExit($TimeoutSeconds * 1000)')) 'git.ps1 bounds probe runtime with timeout'
        Need ($gitHelper.Contains('BeginOutputReadLine')) 'git.ps1 reads stdout asynchronously to avoid pipe buffer deadlocks'
        Need ($gitHelper.Contains('BeginErrorReadLine')) 'git.ps1 reads stderr asynchronously to avoid pipe buffer deadlocks'
        Need ($gitHelper.Contains('Register-ObjectEvent')) 'git.ps1 captures async probe output in Windows PowerShell 5.1'
        Need ($gitHelper.Contains('-TimedOut $true')) 'git.ps1 reports probe timeout state'
        Need ($gitHelper.Contains("MinimumGitVersion = [version] '2.40.0'")) 'git.ps1 locks minimum Git version placeholder'
        Need ($gitHelper.Contains("ExpectedVersionMarker = 'windows.'")) 'git.ps1 checks Git for Windows version marker placeholder'
        Need ($gitHelper.Contains("WingetPackageId = 'Git.Git'")) 'git.ps1 reports winget Git package identity'
        Need ($gitHelper.Contains("ContractVersion = 'checkpoint.v1'")) 'git.ps1 declares checkpoint.v1 contract'
        Need ($gitHelper.Contains("ComponentName = 'git'")) 'git.ps1 declares git component'
        Need ($gitHelper.Contains('HelperFailureExitCode = 70')) 'git.ps1 separates helper failure exit code'
        Need ($gitHelper.Contains('exitCodeContract')) 'git.ps1 reports exit code contract'
        Need ($gitHelper.Contains('Get-Command git.exe')) 'git.ps1 discovers active Git command'
        Need ($gitHelper.Contains("'--version'")) 'git.ps1 probes Git version'
        Need ($gitHelper.Contains('mutationAllowed')) 'git.ps1 reports mutation boundary'
        Need ($gitHelper.Contains('actionMode')) 'git.ps1 reports action boundary'
        Need ($gitHelper.Contains('AllowedStatuses')) 'git.ps1 locks status enum contract'
        Need ($gitHelper.Contains('AllowedDecisions')) 'git.ps1 locks decision enum contract'
        Need ($gitHelper.Contains('DecisionReportExitCode = 0')) 'git.ps1 locks decision report exit code'
        Need ($gitHelper.Contains('function Test-ResultContract')) 'git.ps1 validates result contract before output'
        Need ($gitHelper.Contains('function Get-ProjectLocalRoot')) 'git.ps1 anchors result files under project local root'
        Need ($gitHelper.Contains('function Test-PathInsideRoot')) 'git.ps1 validates result path containment'
        Need ($gitHelper.Contains('Git result path must stay under')) 'git.ps1 restricts result files to project local root'
        Need ($gitHelper.Contains('ResultPath')) 'git.ps1 supports optional result file output'
        Need ($gitHelper.Contains('function Write-GitResultFile')) 'git.ps1 writes optional json result file'
        Need ($gitHelper.Contains('Git result file write failed')) 'git.ps1 reports result file write failures explicitly'
        Need ($gitHelper.Contains('SkipResultFile')) 'git.ps1 avoids repeated result file failure during fallback output'
        Need ($gitHelper.Contains('discovery-diagnose-decision-only')) 'git.ps1 stays in sample discovery mode'
        Need ($gitHelper.Contains("ValidateSet('Text', 'Json')")) 'git.ps1 declares text and json output modes'
        Need ($gitHelper.Contains('ConvertTo-Json -Depth 6')) 'git.ps1 emits structured json output'
        Need ($gitHelper.Contains('function ConvertTo-JsonText')) 'git.ps1 emits ASCII-safe json for pipeline parsing'
        Need ($gitHelper.Contains('TestScenario')) 'git.ps1 exposes deterministic test scenarios'
        Need ($gitHelper.Contains('helper_failed')) 'git.ps1 can simulate helper failure contract'
        Need ($gitHelper.Contains('version_timeout')) 'git.ps1 can simulate version timeout'
        Need ($gitHelper.Contains('version_too_old')) 'git.ps1 can simulate old Git version'
        Need ($gitHelper.Contains('version_untrusted')) 'git.ps1 can simulate untrusted Git version marker'
        Need ($gitHelper.Contains('path_untrusted')) 'git.ps1 can simulate untrusted Git path shape'
    }

    $placeholderPaths = @(
        'flows/windows/install/checkpoints/00_preflight.cmd',
        'flows/windows/install/checkpoints/30_claude.cmd',
        'flows/windows/install/checkpoints/40_enhancements.cmd',
        'flows/windows/install/checkpoints/50_config.cmd',
        'flows/windows/install/checkpoints/90_finalize.cmd',
        'flows/windows/update/checkpoints/00_preflight.cmd',
        'flows/windows/update/checkpoints/20_git.cmd',
        'flows/windows/update/checkpoints/30_claude.cmd',
        'flows/windows/update/checkpoints/40_enhancements.cmd',
        'flows/windows/update/checkpoints/90_finalize.cmd',
        'flows/windows/uninstall/checkpoints/00_preflight.cmd',
        'flows/windows/uninstall/checkpoints/30_claude.cmd',
        'flows/windows/uninstall/checkpoints/40_enhancements.cmd',
        'flows/windows/uninstall/checkpoints/90_finalize.cmd'
    )
    foreach ($placeholderPath in $placeholderPaths) {
        $fullPlaceholderPath = Join-Path $payloadRoot $placeholderPath
        Need (Test-Path -LiteralPath $fullPlaceholderPath -PathType Leaf) "placeholder checkpoint exists: $placeholderPath"
        if (Test-Path -LiteralPath $fullPlaceholderPath -PathType Leaf) {
            $placeholderText = Get-Content -LiteralPath $fullPlaceholderPath -Raw
            Need ($placeholderText.Contains('NOT_IMPLEMENTED')) "placeholder checkpoint says NOT_IMPLEMENTED: $placeholderPath"
            Need ($placeholderText.Contains('exit /b 11')) "placeholder checkpoint exits 11: $placeholderPath"
        }
    }


    $wingetJson = Invoke-CheckpointJson -Path $wingetCheckpointPath -Arguments @('-OutputMode', 'Json', '-TestScenario', 'healthy') -ExpectedExitCode 0
    if ($null -ne $wingetJson) {
        Need ($wingetJson.contractVersion -eq 'checkpoint.v1') 'winget checkpoint runner emits checkpoint.v1 JSON'
        Need ($wingetJson.component -eq 'winget') 'winget checkpoint runner preserves component'
        Need ($wingetJson.decision.status -eq 'healthy') 'winget checkpoint runner preserves healthy status'
        Need ($wingetJson.exitCodeContract.healthy -eq 0) 'winget checkpoint reports healthy exit code contract'
        Need ($wingetJson.exitCodeContract.dependencyBlocker -eq 60) 'winget checkpoint reports dependency blocker exit code contract'
        Need ($wingetJson.exitCodeContract.helperFailure -eq 70) 'winget checkpoint reports helper failure exit code contract'
        Need ($null -ne $wingetJson.discovery.appxDeployment) 'winget checkpoint reports Appx deployment facts'
        Need ($null -ne $wingetJson.discovery.appxDeployment.addAppxPackageFound) 'winget checkpoint reports Add-AppxPackage availability'
        Need ($null -ne $wingetJson.discovery.appxDeployment.appxServiceFound) 'winget checkpoint reports AppXSvc availability'
        Need ($null -ne $wingetJson.discovery.appxDeployment.osBuildSupported) 'winget checkpoint reports Appx OS build support'
        Need ($null -ne $wingetJson.discovery.appxDeployment.repairLikelySupported) 'winget checkpoint reports repair likelihood'
    }

    $gitJson = Invoke-CheckpointJson -Path $gitCheckpointPath -Arguments @('-OutputMode', 'Json', '-TestScenario', 'healthy') -ExpectedExitCode 0
    if ($null -ne $gitJson) {
        Need ($gitJson.contractVersion -eq 'checkpoint.v1') 'Git checkpoint runner emits checkpoint.v1 JSON'
        Need ($gitJson.component -eq 'git') 'Git checkpoint runner preserves component'
        Need ($gitJson.decision.status -eq 'healthy') 'Git checkpoint runner preserves healthy status'
    }

    $downloadJson = Invoke-CheckpointJson -Path $downloadCheckpointPath -Arguments @('-OutputMode', 'Json', '-TestScenario', 'planned') -ExpectedExitCode 0
    if ($null -ne $downloadJson) {
        Need ($downloadJson.contractVersion -eq 'checkpoint.v1') 'download checkpoint runner emits checkpoint.v1 JSON'
        Need ($downloadJson.component -eq 'download') 'download checkpoint runner preserves component'
        Need ($downloadJson.checkpoint -eq 'app-installer-download') 'download checkpoint runner preserves checkpoint name'
        Need ($downloadJson.artifactKind -eq 'AppInstaller') 'download checkpoint runner preserves artifact kind'
        Need ($downloadJson.source.metadataComplete -eq $false) 'download planned scenario reports incomplete metadata'
        Need ($downloadJson.source.downloadEnabled -eq $false) 'download planned scenario keeps real download disabled'
        Need ($downloadJson.source.expectedSha256Present -eq $false) 'download planned scenario has no fake expected sha256'
        Need ($downloadJson.source.expectedSha256Valid -eq $false) 'download planned scenario has no valid expected sha256'
        Need ($null -eq $downloadJson.source.expectedSha256Normalized) 'download planned scenario has no normalized expected sha256'
    }

    $downloadBlockedJson = Invoke-CheckpointJson -Path $downloadCheckpointPath -Arguments @('-OutputMode', 'Json', '-AllowDownload') -ExpectedExitCode 60
    if ($null -ne $downloadBlockedJson) {
        Need ($downloadBlockedJson.decision.status -eq 'source_blocked') 'download checkpoint blocks AllowDownload when metadata is incomplete'
        Need ($downloadBlockedJson.decision.exitCode -eq 60) 'download checkpoint reports incomplete metadata as blocker exit code'
        Need ($downloadBlockedJson.source.metadataComplete -eq $false) 'download blocked scenario reports incomplete metadata'
        Need ($downloadBlockedJson.source.downloadEnabled -eq $false) 'download blocked scenario keeps download disabled'
        Need ($downloadBlockedJson.source.https -eq $false) 'download blocked scenario reports missing HTTPS source'
        Need ($downloadBlockedJson.source.hostAllowed -eq $false) 'download blocked scenario reports missing allowed host'
    }

    $downloadSha = 'A' * 64
    $downloadCompleteMetadataJson = Invoke-CheckpointJson -Path $downloadCheckpointPath -Arguments @('-OutputMode', 'Json', '-TestScenario', 'downloaded', '-AllowDownload', '-AllowedHosts', 'example.invalid', '-ExpectedSha256', $downloadSha) -ExpectedExitCode 0
    if ($null -ne $downloadCompleteMetadataJson) {
        Need ($downloadCompleteMetadataJson.source.metadataComplete -eq $true) 'download checkpoint treats HTTPS allowed host and valid sha256 as complete metadata'
        Need ($downloadCompleteMetadataJson.source.downloadEnabled -eq $true) 'download checkpoint enables download only when AllowDownload and metadata are complete'
        Need ($downloadCompleteMetadataJson.source.expectedSha256Normalized -eq $downloadSha.ToLowerInvariant()) 'download checkpoint normalizes expected sha256 to lowercase'
    }

    $downloadHttpBlockedJson = Invoke-CheckpointJson -Path $downloadCheckpointPath -Arguments @('-OutputMode', 'Json', '-AllowDownload', '-Uri', 'http://example.invalid/app-installer.msixbundle', '-AllowedHosts', 'example.invalid', '-ExpectedSha256', $downloadSha) -ExpectedExitCode 60
    if ($null -ne $downloadHttpBlockedJson) {
        Need ($downloadHttpBlockedJson.decision.status -eq 'source_blocked') 'download checkpoint blocks non-HTTPS source before download'
        Need ($downloadHttpBlockedJson.source.https -eq $false) 'download checkpoint reports non-HTTPS source fact'
        Need ($downloadHttpBlockedJson.source.hostAllowed -eq $true) 'download checkpoint keeps host fact separate from HTTPS fact'
        Need ($downloadHttpBlockedJson.source.metadataComplete -eq $false) 'download checkpoint does not treat HTTP source as complete metadata'
        Need ($downloadHttpBlockedJson.source.downloadEnabled -eq $false) 'download checkpoint keeps HTTP source disabled'
    }

    $downloadHostBlockedJson = Invoke-CheckpointJson -Path $downloadCheckpointPath -Arguments @('-OutputMode', 'Json', '-AllowDownload', '-Uri', 'https://example.invalid/app-installer.msixbundle', '-AllowedHosts', 'downloads.example.invalid', '-ExpectedSha256', $downloadSha) -ExpectedExitCode 60
    if ($null -ne $downloadHostBlockedJson) {
        Need ($downloadHostBlockedJson.decision.status -eq 'source_blocked') 'download checkpoint blocks host mismatch before download'
        Need ($downloadHostBlockedJson.source.https -eq $true) 'download checkpoint keeps HTTPS fact separate from host fact'
        Need ($downloadHostBlockedJson.source.hostAllowed -eq $false) 'download checkpoint reports host mismatch fact'
        Need ($downloadHostBlockedJson.source.metadataComplete -eq $false) 'download checkpoint does not treat host mismatch as complete metadata'
        Need ($downloadHostBlockedJson.source.downloadEnabled -eq $false) 'download checkpoint keeps host mismatch disabled'
    }

    foreach ($downloadScenario in @(
        @{ name = 'source_blocked'; decision = 'abort' },
        @{ name = 'download_failed'; decision = 'retry' },
        @{ name = 'hash_mismatch'; decision = 'abort' }
    )) {
        $downloadScenarioJson = Invoke-CheckpointJson -Path $downloadCheckpointPath -Arguments @('-OutputMode', 'Json', '-TestScenario', $downloadScenario.name) -ExpectedExitCode 60
        if ($null -ne $downloadScenarioJson) {
            Need ($downloadScenarioJson.decision.status -eq $downloadScenario.name) "download checkpoint blocks $($downloadScenario.name) scenario"
            Need ($downloadScenarioJson.decision.decision -eq $downloadScenario.decision) "download checkpoint reports expected decision for $($downloadScenario.name)"
            Need ($downloadScenarioJson.decision.exitCode -eq 60) "download checkpoint reports blocker exit code for $($downloadScenario.name)"
            Need ($downloadScenarioJson.source.metadataComplete -eq $false) "download checkpoint reports incomplete metadata for $($downloadScenario.name)"
            Need ($downloadScenarioJson.source.downloadEnabled -eq $false) "download checkpoint keeps download disabled for $($downloadScenario.name)"
        }
    }

    $wingetMissingJson = Invoke-CheckpointJson -Path $wingetCheckpointPath -Arguments @('-OutputMode', 'Json', '-TestScenario', 'missing') -ExpectedExitCode 60
    if ($null -ne $wingetMissingJson) {
        Need ($wingetMissingJson.decision.status -eq 'missing') 'winget checkpoint blocks missing dependency state'
        Need ($wingetMissingJson.decision.exitCode -eq 60) 'winget checkpoint reports missing as dependency blocker exit code'
        Need ($wingetMissingJson.discovery.appxDeployment.repairLikelySupported -eq $true) 'winget missing scenario reports Appx repair likely supported'
    }

    $wingetAppxUnavailableJson = Invoke-CheckpointJson -Path $wingetCheckpointPath -Arguments @('-OutputMode', 'Json', '-TestScenario', 'appx_unavailable') -ExpectedExitCode 60
    if ($null -ne $wingetAppxUnavailableJson) {
        Need ($wingetAppxUnavailableJson.decision.status -eq 'appx_deployment_unavailable') 'winget checkpoint blocks missing winget when Appx deployment is unavailable'
        Need ($wingetAppxUnavailableJson.decision.decision -eq 'abort') 'winget checkpoint aborts when Appx deployment is unavailable'
        Need ($wingetAppxUnavailableJson.decision.exitCode -eq 60) 'winget checkpoint reports Appx deployment unavailable as dependency blocker exit code'
        Need ($wingetAppxUnavailableJson.discovery.appxDeployment.repairLikelySupported -eq $false) 'winget appx_unavailable scenario reports Appx repair unsupported'
    }

    $wingetSourceUntrustedJson = Invoke-CheckpointJson -Path $wingetCheckpointPath -Arguments @('-OutputMode', 'Json', '-TestScenario', 'source_untrusted') -ExpectedExitCode 60
    if ($null -ne $wingetSourceUntrustedJson) {
        Need ($wingetSourceUntrustedJson.decision.status -eq 'source_untrusted') 'winget checkpoint blocks untrusted source state'
        Need ($wingetSourceUntrustedJson.decision.exitCode -eq 60) 'winget checkpoint reports untrusted source as dependency blocker exit code'
    }

    $gitMissingJson = Invoke-CheckpointJson -Path $gitCheckpointPath -Arguments @('-OutputMode', 'Json', '-TestScenario', 'missing') -ExpectedExitCode 60
    if ($null -ne $gitMissingJson) {
        Need ($gitMissingJson.decision.status -eq 'missing') 'Git checkpoint blocks missing dependency state'
        Need ($gitMissingJson.decision.exitCode -eq 60) 'Git checkpoint reports missing as dependency blocker exit code'
    }

    $gitVersionTooOldJson = Invoke-CheckpointJson -Path $gitCheckpointPath -Arguments @('-OutputMode', 'Json', '-TestScenario', 'version_too_old') -ExpectedExitCode 60
    if ($null -ne $gitVersionTooOldJson) {
        Need ($gitVersionTooOldJson.decision.status -eq 'version_too_old') 'Git checkpoint blocks old version state'
        Need ($gitVersionTooOldJson.decision.exitCode -eq 60) 'Git checkpoint reports old version as dependency blocker exit code'
    }

    $gitPathUntrustedJson = Invoke-CheckpointJson -Path $gitCheckpointPath -Arguments @('-OutputMode', 'Json', '-TestScenario', 'path_untrusted') -ExpectedExitCode 60
    if ($null -ne $gitPathUntrustedJson) {
        Need ($gitPathUntrustedJson.decision.status -eq 'identity_untrusted') 'Git checkpoint blocks untrusted identity state'
        Need ($gitPathUntrustedJson.decision.exitCode -eq 60) 'Git checkpoint reports untrusted identity as dependency blocker exit code'
    }

    Need (-not ($mainCmd -split "`r?`n" | Where-Object { $_ -like 'powershell.exe * -Command "*' } | Select-Object -First 1)) 'main.cmd does not embed startup acceptance PowerShell'
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
