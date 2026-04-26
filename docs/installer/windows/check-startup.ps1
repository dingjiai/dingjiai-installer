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

$manifestPath = Join-Path $PSScriptRoot 'manifest.json'
$payloadRoot = Join-Path $PSScriptRoot 'payload'
$winEntryPath = Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) 'win.ps1'

Need (Test-Path -LiteralPath $manifestPath -PathType Leaf) "manifest exists: $manifestPath"
Need (Test-Path -LiteralPath $payloadRoot -PathType Container) "payload directory exists: $payloadRoot"
Need (Test-Path -LiteralPath $winEntryPath -PathType Leaf) "Windows bootstrap exists: $winEntryPath"

if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
    exit 1
}

$manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
Need ($manifest.schemaVersion -eq 1) 'manifest schemaVersion is 1'
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
    $pathKey = $payloadPath.ToLowerInvariant()

    Need (-not $seenPaths.ContainsKey($pathKey)) "payload path is unique: $payloadPath"
    $seenPaths[$pathKey] = $true

    Need (Test-Path -LiteralPath $localPath -PathType Leaf) "payload file exists: $payloadPath"
    Need (-not [string]::IsNullOrWhiteSpace([string] $file.sha256)) "payload file has sha256: $payloadPath"
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
            Need ($flowText.Contains('exit /b 0')) "flow entry returns success from placeholder path: $flowEntry"
        }
    }



    $wingetCheckpointPath = Join-Path $payloadRoot 'flows/windows/install/checkpoints/10_winget.cmd'
    Need (Test-Path -LiteralPath $wingetCheckpointPath -PathType Leaf) 'winget checkpoint cmd exists'
    if (Test-Path -LiteralPath $wingetCheckpointPath -PathType Leaf) {
        $wingetCheckpoint = Get-Content -LiteralPath $wingetCheckpointPath -Raw
        Need ($wingetCheckpoint.Contains('lib\windows\winget.ps1')) 'winget checkpoint delegates to winget.ps1 helper'
        Need ($wingetCheckpoint.Contains('powershell.exe -NoProfile -ExecutionPolicy Bypass -File')) 'winget checkpoint uses PowerShell helper bridge'
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
        Need ($wingetHelper.Contains('https://cdn.winget.microsoft.com/cache')) 'winget.ps1 requires the official winget source URL'
        Need ($wingetHelper.Contains('sourceHasWinget')) 'winget.ps1 reports official winget source presence'
        Need ($wingetHelper.Contains('officialSource')) 'winget.ps1 reports official source trust facts'
        Need ($wingetHelper.Contains('environment') -and $wingetHelper.Contains('versionProbe') -and $wingetHelper.Contains('sourceProbe')) 'winget.ps1 reports structured discovery facts'
        Need ($wingetHelper.Contains('HelperFailureExitCode = 70')) 'winget.ps1 separates helper failure exit code'
        Need ($wingetHelper.Contains('exitCodeContract')) 'winget.ps1 reports exit code contract'
        Need ($wingetHelper.Contains('Get-Command winget.exe')) 'winget.ps1 discovers active winget command'
        Need ($wingetHelper.Contains("'--version'")) 'winget.ps1 probes winget version'
        Need ($wingetHelper.Contains("'source', 'list'")) 'winget.ps1 probes winget sources'
        Need ($wingetHelper.Contains('mutationAllowed')) 'winget.ps1 reports mutation boundary'
        Need ($wingetHelper.Contains('actionMode')) 'winget.ps1 reports action boundary'
        Need ($wingetHelper.Contains('AllowedStatuses')) 'winget.ps1 locks status enum contract'
        Need ($wingetHelper.Contains('AllowedDecisions')) 'winget.ps1 locks decision enum contract'
        foreach ($status in @('healthy', 'missing', 'command_broken', 'command_timeout', 'source_broken', 'source_timeout', 'source_missing', 'source_untrusted', 'helper_failed')) {
            Need ($wingetHelper.Contains("'$status'")) "winget.ps1 status enum includes $status"
        }
        Need ($wingetHelper.Contains('DecisionReportExitCode = 0')) 'winget.ps1 locks decision report exit code'
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
        foreach ($scenario in @('healthy', 'missing', 'version_failed', 'version_timeout', 'source_failed', 'source_timeout', 'source_missing', 'source_untrusted', 'helper_failed')) {
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
        Need ($downloadCheckpoint.Contains('lib\windows\download.ps1')) 'App Installer download checkpoint delegates to download.ps1 helper'
        Need ($downloadCheckpoint.Contains('powershell.exe -NoProfile -ExecutionPolicy Bypass -File')) 'App Installer download checkpoint uses PowerShell helper bridge'
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
        Need ($downloadHelper.Contains('download-only-staging')) 'download.ps1 stays in download-only staging mode'
        Need ($downloadHelper.Contains('DownloadFailureExitCode = 60')) 'download.ps1 separates download failure exit code'
        Need ($downloadHelper.Contains('HelperFailureExitCode = 70')) 'download.ps1 separates helper failure exit code'
        Need ($downloadHelper.Contains('DecisionReportExitCode = 0')) 'download.ps1 locks decision report exit code'
        Need ($downloadHelper.Contains('AllowedStatuses')) 'download.ps1 locks status enum contract'
        Need ($downloadHelper.Contains('AllowedDecisions')) 'download.ps1 locks decision enum contract'
        Need ($downloadHelper.Contains('ExpectedSha256')) 'download.ps1 requires expected sha256 for real downloads'
        Need ($downloadHelper.Contains('AllowedHosts')) 'download.ps1 requires an allowed host list for real downloads'
        Need ($downloadHelper.Contains('AllowDownload')) 'download.ps1 keeps real download behind explicit opt-in'
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
        Need ($gitCheckpoint.Contains('lib\windows\git.ps1')) 'Git checkpoint delegates to git.ps1 helper'
        Need ($gitCheckpoint.Contains('powershell.exe -NoProfile -ExecutionPolicy Bypass -File')) 'Git checkpoint uses PowerShell helper bridge'
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

    $embeddedLine = $mainCmd -split "`r?`n" | Where-Object { $_ -like 'powershell.exe * -Command "*' } | Select-Object -First 1
    Need (-not [string]::IsNullOrWhiteSpace($embeddedLine)) 'main.cmd has embedded PowerShell state writer'

    if (-not [string]::IsNullOrWhiteSpace($embeddedLine)) {
        $embeddedScript = $embeddedLine -replace '^.* -Command "', '' -replace '"\s*$', ''
        try {
            [scriptblock]::Create($embeddedScript) | Out-Null
            Pass 'embedded PowerShell syntax ok: main.cmd'
        } catch {
            Fail "embedded PowerShell syntax error: $($_.Exception.Message)"
        }
    }
}

if (Test-Path -LiteralPath $winEntryPath -PathType Leaf) {
    Need (Test-Utf8Bom -Path $winEntryPath) 'win.ps1 uses UTF-8 BOM for Windows PowerShell 5.1'
    Test-PowerShellFileSyntax -Path $winEntryPath

    $winEntry = Get-Content -LiteralPath $winEntryPath -Raw
    Need ($winEntry -match '\$script:MinimumPowerShellVersion\s*=\s*\[version\]''5\.1''') 'win.ps1 requires PowerShell 5.1+'
    Need ($winEntry -match '\$script:MinimumWindowsBuild\s*=\s*17763') 'win.ps1 requires Windows build 17763+'
    Need ($winEntry -match 'function Get-StartupFailureSuggestion') 'win.ps1 has failure suggestion mapper'
    Need ($winEntry -match "'handoff_denied_or_failed'") 'win.ps1 maps handoff denial failure suggestion'
    Need ($winEntry -match 'function Write-StartupFailureMessage') 'win.ps1 has unified failure message writer'
    Need ($winEntry -match 'failureSuggestion') 'win.ps1 writes failure suggestion to state'
    Need ($winEntry -match 'failureLogPath') 'win.ps1 writes failure log path to state'
    Need ($winEntry -match 'function Test-HandoffAcceptedState') 'win.ps1 validates handoff accepted state'
    Need ($winEntry -match 'acceptedWorkspaceRoot' -and $winEntry -match 'acceptedStatePath' -and $winEntry -match 'acceptedLogPath' -and $winEntry -match 'acceptedPayloadRoot' -and $winEntry -match 'acceptedMainEntryPath' -and $winEntry -match 'acceptedSource' -and $winEntry -match 'acceptedHandoffMode') 'win.ps1 checks handoff accepted identity fields'
    Need ($winEntry -match "Add-StartupCheck -Name 'windows_build'") 'win.ps1 checks Windows build'
    Need ($winEntry -match "Add-StartupCheck -Name 'powershell_version'") 'win.ps1 checks PowerShell version'
    Need ($winEntry -match '\$missingCapabilities') 'win.ps1 checks runtime capabilities'
    Need ($winEntry -match '\$cmdArguments\s*=\s*''/c') 'win.ps1 launches administrator cmd with /c'
}

if ($script:Failed) {
    Write-Host 'Windows startup self-check failed.' -ForegroundColor Red
    exit 1
}

Write-Host 'Windows startup self-check passed.'
