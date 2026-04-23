param(
    [string]$Action = '',
    [string]$MenuFilePath = '',
    [switch]$SkipStartupPreflight
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$MenuFile = if ([string]::IsNullOrWhiteSpace($MenuFilePath)) {
    Join-Path $ScriptDir 'menu.txt'
}
else {
    $MenuFilePath
}
$InstallRoot = if ([string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) {
    ''
}
else {
    Join-Path $env:LOCALAPPDATA 'dingjiai-installer'
}
$StartupProbeUrl = 'https://get.dingjiai.com/win.ps1'
$Title = ''
$Subtitle = ''
$MenuOrder = [System.Collections.Generic.List[string]]::new()
$MenuLabels = @{}
$MenuMessages = @{}
$script:StartupProfile = [ordered]@{
    Facts = [ordered]@{}
    Results = [System.Collections.Generic.List[object]]::new()
    Summary = [ordered]@{}
}
$script:ValidationShellPath = ''
$script:GitMinimumVersion = [Version]'2.40.0'
$script:GitPackageId = 'Git.Git'

function Import-Menu {
    if (-not (Test-Path -LiteralPath $MenuFile)) {
        throw "缺少菜单定义：$MenuFile"
    }

    foreach ($line in Get-Content -LiteralPath $MenuFile -Encoding UTF8) {
        if ([string]::IsNullOrWhiteSpace($line)) {
            continue
        }

        if ($line.StartsWith('TITLE=')) {
            $script:Title = $line.Substring(6)
            continue
        }

        if ($line.StartsWith('SUBTITLE=')) {
            $script:Subtitle = $line.Substring(9)
            continue
        }

        $parts = $line.Split('|', 3)
        if ($parts.Count -eq 3) {
            $key = $parts[0]
            $script:MenuOrder.Add($key)
            $script:MenuLabels[$key] = $parts[1]
            $script:MenuMessages[$key] = $parts[2]
        }
    }
}

function Get-StartupStatusPrefix([string]$Status) {
    switch ($Status) {
        '已就绪' { return '[已就绪]' }
        '将自动适配' { return '[将自动适配]' }
        '稍后处理' { return '[稍后处理]' }
        '仅提示' { return '[仅提示]' }
        default { return '[信息]' }
    }
}

function Add-StartupResult([string]$Status, [string]$TitleText, [string]$Detail) {
    $result = [pscustomobject]@{
        Status = $Status
        Title = $TitleText
        Detail = $Detail
    }

    $script:StartupProfile.Results.Add($result)

    $prefix = Get-StartupStatusPrefix -Status $Status
    if ([string]::IsNullOrWhiteSpace($Detail)) {
        Write-Host "$prefix $TitleText"
        return
    }

    Write-Host "$prefix $TitleText：$Detail"
}

function Test-DirectoryWritable([string]$Path) {
    if ([string]::IsNullOrWhiteSpace($Path)) {
        return $false
    }

    $probePath = if (Test-Path -LiteralPath $Path) {
        $Path
    }
    else {
        Split-Path -Parent $Path
    }

    if ([string]::IsNullOrWhiteSpace($probePath) -or -not (Test-Path -LiteralPath $probePath)) {
        return $false
    }

    $probeFile = Join-Path $probePath ("dingjiai-write-test-$(Get-Random).tmp")

    try {
        [System.IO.File]::WriteAllText($probeFile, '')
        Remove-Item -LiteralPath $probeFile -Force -ErrorAction SilentlyContinue
        return $true
    }
    catch {
        if (Test-Path -LiteralPath $probeFile) {
            Remove-Item -LiteralPath $probeFile -Force -ErrorAction SilentlyContinue
        }

        return $false
    }
}

function Test-UrlReachable([string]$Uri) {
    try {
        $request = [System.Net.WebRequest]::Create($Uri)
        $request.Method = 'HEAD'
        $request.Timeout = 4000
        $response = $request.GetResponse()
        $response.Close()
        return $true
    }
    catch {
        return $false
    }
}

function Get-CommandExecutablePath($CommandInfo) {
    if ($null -eq $CommandInfo) {
        return ''
    }

    foreach ($propertyName in @('Source', 'Path', 'Definition')) {
        $property = $CommandInfo.PSObject.Properties[$propertyName]
        if ($null -ne $property -and -not [string]::IsNullOrWhiteSpace([string]$property.Value)) {
            return [string]$property.Value
        }
    }

    return ''
}

function Invoke-NativeCommand([string]$FilePath, [string[]]$Arguments) {
    try {
        $output = & $FilePath @Arguments 2>&1
        $exitCode = if ($null -ne $LASTEXITCODE) {
            [int]$LASTEXITCODE
        }
        else {
            0
        }
    }
    catch {
        return [pscustomobject]@{
            ExitCode = 1
            Output = @($_.Exception.Message)
        }
    }

    return [pscustomobject]@{
        ExitCode = $exitCode
        Output = @($output | ForEach-Object { "$_" })
    }
}

function Get-CmdExecutablePath {
    if (-not [string]::IsNullOrWhiteSpace($env:ComSpec) -and (Test-Path -LiteralPath $env:ComSpec)) {
        return $env:ComSpec
    }

    $commandInfo = Get-Command cmd.exe -ErrorAction SilentlyContinue
    if ($null -eq $commandInfo) {
        return ''
    }

    return Get-CommandExecutablePath -CommandInfo $commandInfo
}

function Get-CmdAutorunValue([string]$RegistryPath) {
    try {
        $item = Get-ItemProperty -LiteralPath $RegistryPath -Name AutoRun -ErrorAction Stop
        return [string]$item.AutoRun
    }
    catch {
        return ''
    }
}

function Invoke-BootstrapHandoffChecks {
    $script:StartupProfile = [ordered]@{
        Facts = [ordered]@{}
        Results = [System.Collections.Generic.List[object]]::new()
        Summary = [ordered]@{}
    }

    Write-Host ''
    Write-Host 'dingjiai 安装器'
    Write-Host '正在准备管理员 CMD 主窗口...'

    $detectedWindows = $false
    if ($PSVersionTable.ContainsKey('Platform')) {
        $detectedWindows = $PSVersionTable.Platform -eq 'Win32NT'
    }
    elseif (-not [string]::IsNullOrWhiteSpace($env:OS)) {
        $detectedWindows = $env:OS -eq 'Windows_NT'
    }

    Add-StartupResult -Status ($(if ($detectedWindows) { '已就绪' } else { '稍后处理' })) -TitleText 'Windows 运行环境' -Detail ($(if ($detectedWindows) { '已识别为 Windows' } else { '当前不是 Windows，无法继续打开 Windows 主界面' }))
    if (-not $detectedWindows) {
        return $false
    }

    $powerShellVersion = $PSVersionTable.PSVersion.ToString()
    $powerShellEdition = if ($PSVersionTable.ContainsKey('PSEdition')) { $PSVersionTable.PSEdition } else { 'Unknown' }
    Add-StartupResult -Status '仅提示' -TitleText '启动壳' -Detail "$powerShellVersion ($powerShellEdition)"

    $mainCmdPath = Join-Path $ScriptDir 'main.cmd'
    Add-StartupResult -Status ($(if (Test-Path -LiteralPath $mainCmdPath) { '已就绪' } else { '稍后处理' })) -TitleText '主菜单脚本' -Detail ($(if (Test-Path -LiteralPath $mainCmdPath) { $mainCmdPath } else { '缺少 main.cmd' }))
    if (-not (Test-Path -LiteralPath $mainCmdPath)) {
        return $false
    }

    Add-StartupResult -Status '已就绪' -TitleText 'PowerShell 后端' -Detail $PSCommandPath

    $cmdPath = Get-CmdExecutablePath
    if ([string]::IsNullOrWhiteSpace($cmdPath)) {
        Add-StartupResult -Status '稍后处理' -TitleText 'CMD 宿主' -Detail '找不到 cmd.exe'
        return $false
    }

    $cmdCheck = Invoke-NativeCommand -FilePath $cmdPath -Arguments @('/d', '/c', 'echo CMD is working')
    if ($cmdCheck.ExitCode -eq 0 -and (($cmdCheck.Output -join ' ') -match 'CMD is working')) {
        Add-StartupResult -Status '已就绪' -TitleText 'CMD 宿主' -Detail $cmdPath
    }
    else {
        Add-StartupResult -Status '稍后处理' -TitleText 'CMD 宿主' -Detail 'cmd.exe 不能正常响应'
        return $false
    }

    $hkcuAutorun = Get-CmdAutorunValue -RegistryPath 'HKCU:\Software\Microsoft\Command Processor'
    if (-not [string]::IsNullOrWhiteSpace($hkcuAutorun)) {
        Add-StartupResult -Status '仅提示' -TitleText 'CMD AutoRun(HKCU)' -Detail $hkcuAutorun
    }

    $hklmAutorun = Get-CmdAutorunValue -RegistryPath 'HKLM:\Software\Microsoft\Command Processor'
    if (-not [string]::IsNullOrWhiteSpace($hklmAutorun)) {
        Add-StartupResult -Status '仅提示' -TitleText 'CMD AutoRun(HKLM)' -Detail $hklmAutorun
    }

    $readyCount = @($script:StartupProfile.Results | Where-Object { $_.Status -eq '已就绪' }).Count
    $laterCount = @($script:StartupProfile.Results | Where-Object { $_.Status -eq '稍后处理' }).Count
    $infoCount = @($script:StartupProfile.Results | Where-Object { $_.Status -eq '仅提示' }).Count
    Write-Host ''
    Write-Host "准备完成：已就绪 $readyCount 项，稍后处理 $laterCount 项，仅提示 $infoCount 项。"
    return $laterCount -eq 0
}

function Get-ValidationShellPath {
    if (-not [string]::IsNullOrWhiteSpace($script:ValidationShellPath)) {
        return $script:ValidationShellPath
    }

    $candidatePaths = @(
        (Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'),
        (Join-Path $env:WINDIR 'Sysnative\WindowsPowerShell\v1.0\powershell.exe')
    )

    foreach ($candidatePath in $candidatePaths) {
        if (-not [string]::IsNullOrWhiteSpace($candidatePath) -and (Test-Path -LiteralPath $candidatePath)) {
            $script:ValidationShellPath = $candidatePath
            return $candidatePath
        }
    }

    $commandInfo = Get-Command powershell.exe -ErrorAction SilentlyContinue
    if ($null -ne $commandInfo) {
        $resolvedPath = Get-CommandExecutablePath -CommandInfo $commandInfo
        if (-not [string]::IsNullOrWhiteSpace($resolvedPath)) {
            $script:ValidationShellPath = $resolvedPath
            return $resolvedPath
        }
    }

    throw '找不到用于新 shell 校验的 PowerShell。'
}

function Invoke-NewShellCommand([string]$CommandText) {
    $shellPath = Get-ValidationShellPath
    return Invoke-NativeCommand -FilePath $shellPath -Arguments @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-Command', $CommandText)
}

function Get-VersionFromText([string]$Text) {
    if ([string]::IsNullOrWhiteSpace($Text)) {
        return $null
    }

    $match = [regex]::Match($Text, '(\d+\.\d+\.\d+)')
    if (-not $match.Success) {
        return $null
    }

    return [Version]$match.Groups[1].Value
}

function Test-GitTrustedPathShape([string]$Path) {
    if ([string]::IsNullOrWhiteSpace($Path)) {
        return $false
    }

    $normalizedPath = $Path.Replace('/', '\').Trim()
    if ($normalizedPath -match '^[A-Za-z]:\\Program Files\\Git\\(cmd|bin|mingw64\\bin)\\git\.exe$') {
        return $true
    }

    if ($normalizedPath -match '^[A-Za-z]:\\Users\\[^\\]+\\AppData\\Local\\Programs\\Git\\(cmd|bin|mingw64\\bin)\\git\.exe$') {
        return $true
    }

    return $false
}

function Test-WingetNewShellValidation {
    $result = Invoke-NewShellCommand -CommandText 'winget --version'
    $versionText = ($result.Output -join ' ').Trim()

    return [pscustomobject]@{
        Healthy = $result.ExitCode -eq 0 -and -not [string]::IsNullOrWhiteSpace($versionText)
        VersionText = $versionText
        Output = ($result.Output -join [Environment]::NewLine).Trim()
    }
}

function Get-WingetDiscovery {
    $commandInfo = Get-Command winget -ErrorAction SilentlyContinue
    $commandPath = Get-CommandExecutablePath -CommandInfo $commandInfo
    $versionText = ''
    $versionHealthy = $false
    $sourceListHealthy = $false
    $sourceOutput = ''

    if ($null -ne $commandInfo -and -not [string]::IsNullOrWhiteSpace($commandPath)) {
        $versionResult = Invoke-NativeCommand -FilePath $commandPath -Arguments @('--version')
        $versionText = ($versionResult.Output -join ' ').Trim()
        $versionHealthy = $versionResult.ExitCode -eq 0 -and -not [string]::IsNullOrWhiteSpace($versionText)

        $sourceResult = Invoke-NativeCommand -FilePath $commandPath -Arguments @('source', 'list')
        $sourceOutput = ($sourceResult.Output -join [Environment]::NewLine).Trim()
        $sourceListHealthy = $sourceResult.ExitCode -eq 0
    }

    $newShellValidation = Test-WingetNewShellValidation

    return [pscustomobject]@{
        CommandFound = $null -ne $commandInfo
        CommandPath = $commandPath
        VersionText = $versionText
        VersionHealthy = $versionHealthy
        SourceListHealthy = $sourceListHealthy
        SourceOutput = $sourceOutput
        NewShellHealthy = $newShellValidation.Healthy
        NewShellVersionText = $newShellValidation.VersionText
        NewShellOutput = $newShellValidation.Output
        Healthy = ($null -ne $commandInfo) -and $versionHealthy -and $sourceListHealthy -and $newShellValidation.Healthy
    }
}

function Get-WingetAllowance($Discovery) {
    if ($Discovery.Healthy) {
        return 'skip'
    }

    if (-not $Discovery.CommandFound) {
        return 'install'
    }

    if ($Discovery.VersionHealthy -or $Discovery.SourceListHealthy -or $Discovery.NewShellHealthy) {
        return 'repair'
    }

    return 'reinstall'
}

function Invoke-WingetAction([string]$Allowance, $Discovery) {
    switch ($Allowance) {
        'skip' {
            Write-Host "winget 已就绪：$($Discovery.VersionText)"
            return
        }
        'repair' {
            Write-Host '正在尝试修复 winget 源。'
            $resetResult = Invoke-NativeCommand -FilePath $Discovery.CommandPath -Arguments @('source', 'reset', '--force')
            if ($resetResult.ExitCode -eq 0) {
                Write-Host '已执行 winget source reset --force。'
            }
            else {
                Write-Host 'winget source reset 未成功，将继续做最终校验。'
            }

            $updateResult = Invoke-NativeCommand -FilePath $Discovery.CommandPath -Arguments @('source', 'update')
            if ($updateResult.ExitCode -eq 0) {
                Write-Host '已执行 winget source update。'
            }
            else {
                Write-Host 'winget source update 未成功，将继续做最终校验。'
            }
            return
        }
        'install' {
            Write-Host '当前里程碑还未接入 winget 自动安装。'
            Write-Host '请先修复或安装 App Installer，然后重新运行此选项。'
            return
        }
        'reinstall' {
            Write-Host '当前里程碑还未接入 winget 自动重装。'
            Write-Host '请先修复或安装 App Installer，然后重新运行此选项。'
            return
        }
        default {
            Write-Host "未识别的 winget 处理分支：$Allowance"
            return
        }
    }
}

function Invoke-WingetCheckpoint {
    Write-Step '开始处理 winget checkpoint'

    $discovery = Get-WingetDiscovery
    $allowance = Get-WingetAllowance -Discovery $discovery
    Write-Host "winget 当前判定：$allowance"

    if ($allowance -eq 'skip') {
        Write-Host "winget 已通过最终校验：$($discovery.NewShellVersionText)"
        return $true
    }

    Invoke-WingetAction -Allowance $allowance -Discovery $discovery

    $finalDiscovery = Get-WingetDiscovery
    if ($finalDiscovery.Healthy) {
        Write-Host "winget 已通过最终校验：$($finalDiscovery.NewShellVersionText)"
        return $true
    }

    if ($allowance -in @('install', 'reinstall')) {
        Write-Host '当前阶段在 winget 缺失或损坏时还不能自动补齐 App Installer。'
        return $false
    }

    if (-not [string]::IsNullOrWhiteSpace($finalDiscovery.SourceOutput)) {
        Write-Host 'winget 最后一次 source 输出仍未恢复正常。'
    }

    Write-Host 'winget 最终校验未通过，当前停止在 winget checkpoint。'
    return $false
}

function Test-GitNewShellValidation {
    $commandText = @'
$command = Get-Command git -ErrorAction SilentlyContinue
if ($null -eq $command) {
    exit 1
}
$path = if ($command.Source) { $command.Source } elseif ($command.Path) { $command.Path } else { $command.Definition }
Write-Output ('PATH=' + $path)
$versionText = git --version
Write-Output ('VERSION=' + $versionText)
'@

    $result = Invoke-NewShellCommand -CommandText $commandText
    $pathLine = ''
    $versionLine = ''

    foreach ($line in $result.Output) {
        if ([string]::IsNullOrWhiteSpace($pathLine) -and $line -like 'PATH=*') {
            $pathLine = $line
        }

        if ([string]::IsNullOrWhiteSpace($versionLine) -and $line -like 'VERSION=*') {
            $versionLine = $line
        }
    }

    $commandPath = if ([string]::IsNullOrWhiteSpace($pathLine)) {
        ''
    }
    else {
        $pathLine.Substring(5)
    }
    $versionText = if ([string]::IsNullOrWhiteSpace($versionLine)) {
        ''
    }
    else {
        $versionLine.Substring(8)
    }

    return [pscustomobject]@{
        Healthy = $result.ExitCode -eq 0 -and -not [string]::IsNullOrWhiteSpace($commandPath) -and -not [string]::IsNullOrWhiteSpace($versionText)
        CommandPath = $commandPath
        VersionText = $versionText
        Output = ($result.Output -join [Environment]::NewLine).Trim()
    }
}

function Get-GitDiscovery {
    $commandInfo = Get-Command git -ErrorAction SilentlyContinue
    $commandPath = Get-CommandExecutablePath -CommandInfo $commandInfo
    $versionText = ''
    $parsedVersion = $null
    $versionMarkerMatched = $false
    $pathShapeMatched = $false
    $productNameMatched = $false
    $minimumVersionMatched = $false

    if ($null -ne $commandInfo -and -not [string]::IsNullOrWhiteSpace($commandPath)) {
        $versionResult = Invoke-NativeCommand -FilePath $commandPath -Arguments @('--version')
        $versionText = ($versionResult.Output -join ' ').Trim()
        $parsedVersion = Get-VersionFromText -Text $versionText
        $versionMarkerMatched = $versionText -match 'windows\.'
        $pathShapeMatched = Test-GitTrustedPathShape -Path $commandPath
        $productNameMatched = $true

        if ($null -ne $parsedVersion) {
            $minimumVersionMatched = $parsedVersion -ge $script:GitMinimumVersion
        }
    }

    $placeholderIdentityMatched = $versionMarkerMatched -and $pathShapeMatched -and $productNameMatched
    $newShellValidation = Test-GitNewShellValidation
    $newShellPathShapeMatched = Test-GitTrustedPathShape -Path $newShellValidation.CommandPath
    $newShellVersionMarkerMatched = $newShellValidation.VersionText -match 'windows\.'
    $healthy = ($null -ne $commandInfo) -and $placeholderIdentityMatched -and $minimumVersionMatched -and $newShellValidation.Healthy -and $newShellPathShapeMatched -and $newShellVersionMarkerMatched

    return [pscustomobject]@{
        CommandFound = $null -ne $commandInfo
        CommandPath = $commandPath
        VersionText = $versionText
        ParsedVersionText = if ($null -ne $parsedVersion) { $parsedVersion.ToString() } else { '' }
        MinimumAllowedVersion = $script:GitMinimumVersion.ToString()
        MinimumVersionMatched = $minimumVersionMatched
        VersionMarkerMatched = $versionMarkerMatched
        PathShapeMatched = $pathShapeMatched
        ProductNameMatched = $productNameMatched
        OfficialIdentityMatched = $placeholderIdentityMatched
        PublisherMatched = $placeholderIdentityMatched
        PackageIdentityExpected = $script:GitPackageId
        PackageIdentityMatched = $placeholderIdentityMatched
        TrustedIdentityMatched = $placeholderIdentityMatched
        NewShellHealthy = $newShellValidation.Healthy
        NewShellCommandPath = $newShellValidation.CommandPath
        NewShellVersionText = $newShellValidation.VersionText
        NewShellPathShapeMatched = $newShellPathShapeMatched
        NewShellVersionMarkerMatched = $newShellVersionMarkerMatched
        NewShellOutput = $newShellValidation.Output
        Healthy = $healthy
    }
}

function Get-GitAllowance($Discovery) {
    if ($Discovery.Healthy) {
        return 'skip'
    }

    if (-not $Discovery.CommandFound) {
        return 'install'
    }

    if ($Discovery.TrustedIdentityMatched -and -not $Discovery.MinimumVersionMatched) {
        return 'upgrade'
    }

    if ($Discovery.PathShapeMatched -or $Discovery.VersionMarkerMatched) {
        return 'repair'
    }

    return 'reinstall'
}

function Get-GitInstallScope($Discovery) {
    if ($null -eq $Discovery -or [string]::IsNullOrWhiteSpace($Discovery.CommandPath)) {
        return 'user'
    }

    $normalizedPath = $Discovery.CommandPath.Replace('/', '\').Trim()
    if ($normalizedPath -match '^[A-Za-z]:\\Program Files\\') {
        return 'machine'
    }

    if ($normalizedPath -match '^[A-Za-z]:\\Users\\[^\\]+\\AppData\\Local\\Programs\\') {
        return 'user'
    }

    return 'user'
}

function Get-GitActionPlan([string]$Allowance, $Discovery) {
    switch ($Allowance) {
        'skip' {
            return [pscustomobject]@{
                ShouldRun = $false
                Scope = ''
                Arguments = @()
                NeedsAdminPrompt = $false
                Summary = 'Git 已满足当前里程碑要求。'
            }
        }
        'install' {
            $scope = 'user'
            $arguments = @('install', '--id', $script:GitPackageId, '-e', '--accept-package-agreements', '--accept-source-agreements', '--scope', $scope)
        }
        'upgrade' {
            $scope = Get-GitInstallScope -Discovery $Discovery
            $arguments = @('upgrade', '--id', $script:GitPackageId, '-e', '--accept-package-agreements', '--accept-source-agreements', '--scope', $scope)
        }
        'repair' {
            $scope = Get-GitInstallScope -Discovery $Discovery
            $arguments = @('install', '--id', $script:GitPackageId, '-e', '--accept-package-agreements', '--accept-source-agreements', '--scope', $scope, '--force')
        }
        'reinstall' {
            $scope = Get-GitInstallScope -Discovery $Discovery
            $arguments = @('install', '--id', $script:GitPackageId, '-e', '--accept-package-agreements', '--accept-source-agreements', '--scope', $scope, '--force')
        }
        default {
            return $null
        }
    }

    return [pscustomobject]@{
        ShouldRun = $true
        Scope = $scope
        Arguments = $arguments
        NeedsAdminPrompt = $scope -eq 'machine'
        Summary = 'winget ' + ($arguments -join ' ')
    }
}

function Invoke-GitAction([string]$Allowance, $Discovery) {
    $plan = Get-GitActionPlan -Allowance $Allowance -Discovery $Discovery
    if ($null -eq $plan) {
        Write-Host "未识别的 Git 处理分支：$Allowance"
        return $false
    }

    if (-not $plan.ShouldRun) {
        Write-Host $plan.Summary
        return $true
    }

    $wingetCommand = Get-Command winget -ErrorAction SilentlyContinue
    if ($null -eq $wingetCommand) {
        Write-Host '当前无法调用 winget，Git checkpoint 不能继续。'
        return $false
    }

    $wingetPath = Get-CommandExecutablePath -CommandInfo $wingetCommand
    if ([string]::IsNullOrWhiteSpace($wingetPath)) {
        Write-Host '当前无法解析 winget 路径，Git checkpoint 不能继续。'
        return $false
    }

    if ($plan.NeedsAdminPrompt) {
        Write-Host '当前 Git 看起来是机器级安装，winget 可能会请求管理员权限。'
    }
    else {
        Write-Host '当前将优先使用用户级 Git 安装路径。'
    }

    Write-Host "Git 动作计划：$($plan.Summary)"
    Write-Host "正在通过 winget 处理 Git：$Allowance"
    $result = Invoke-NativeCommand -FilePath $wingetPath -Arguments $plan.Arguments
    if ($result.ExitCode -eq 0) {
        Write-Host 'winget 已执行完成。'
        return $true
    }

    Write-Host 'winget 执行未成功。'
    if ($result.Output.Count -gt 0) {
        Write-Host (($result.Output | Select-Object -Last 5) -join [Environment]::NewLine)
    }

    return $false
}

function Test-GitFinalRevalidation {
    return Get-GitDiscovery
}

function Invoke-GitCheckpoint {
    Write-Step '开始处理 Git checkpoint'

    $discovery = Get-GitDiscovery
    $allowance = Get-GitAllowance -Discovery $discovery
    Write-Host "Git 当前判定：$allowance"

    if ($allowance -eq 'skip') {
        Write-Host "Git 已通过最终校验：$($discovery.NewShellVersionText)"
        Write-Host "活动命令路径：$($discovery.NewShellCommandPath)"
        return $true
    }

    $actionSucceeded = Invoke-GitAction -Allowance $allowance -Discovery $discovery
    if (-not $actionSucceeded) {
        Write-Host 'Git 动作未成功完成，当前停止在 Git checkpoint。'
        return $false
    }

    $finalDiscovery = Test-GitFinalRevalidation
    if ($finalDiscovery.Healthy) {
        Write-Host "Git 已通过最终校验：$($finalDiscovery.NewShellVersionText)"
        Write-Host "活动命令路径：$($finalDiscovery.NewShellCommandPath)"
        return $true
    }

    Write-Host 'Git 最终校验未通过，当前停止在 Git checkpoint。'
    if (-not [string]::IsNullOrWhiteSpace($finalDiscovery.NewShellOutput)) {
        Write-Host '新 shell 校验输出仍不符合要求。'
    }

    return $false
}

function Invoke-InstallOption1Flow {
    Write-Host ''
    Write-Host '当前阶段只接入 winget 和 Git。'
    Write-Host 'Claude 与默认增强工具将在后续阶段接入。'

    if (-not $script:StartupProfile.Facts.IsWindows) {
        Write-Host '当前环境不是 Windows，无法继续执行此选项。'
        return
    }

    if (-not (Invoke-WingetCheckpoint)) {
        return
    }

    if (-not (Invoke-GitCheckpoint)) {
        return
    }

    Write-Host ''
    Write-Host '已完成首个真实里程碑：winget + Git。'
    Write-Host '当前流程在 Git checkpoint 后停止。'
}

function Invoke-StartupPreflight {
    if ($SkipStartupPreflight) {
        return
    }

    if ([Environment]::Is64BitProcess -or -not [Environment]::Is64BitOperatingSystem) {
        return
    }

    $targetPowerShell = Join-Path $env:WINDIR 'Sysnative\WindowsPowerShell\v1.0\powershell.exe'
    if (-not (Test-Path -LiteralPath $targetPowerShell)) {
        return
    }

    Write-Host ''
    Write-Host '[将自动适配] 检测到当前是 32 位 PowerShell，正在切换到 64 位环境...'

    try {
        & $targetPowerShell -NoProfile -ExecutionPolicy Bypass -File $PSCommandPath -MenuFilePath $MenuFile -SkipStartupPreflight
        $exitCode = if ($null -ne $LASTEXITCODE) {
            [int]$LASTEXITCODE
        }
        else {
            0
        }

        exit $exitCode
    }
    catch {
        throw "切换到 64 位 PowerShell 失败：$($_.Exception.Message)"
    }
}

function Invoke-StartupDetection {
    $script:StartupProfile = [ordered]@{
        Facts = [ordered]@{}
        Results = [System.Collections.Generic.List[object]]::new()
        Summary = [ordered]@{}
    }

    Write-Host ''
    Write-Host 'dingjiai 安装器'
    Write-Host '正在识别当前环境...'

    $detectedWindows = $false
    if ($PSVersionTable.ContainsKey('Platform')) {
        $detectedWindows = $PSVersionTable.Platform -eq 'Win32NT'
    }
    elseif (-not [string]::IsNullOrWhiteSpace($env:OS)) {
        $detectedWindows = $env:OS -eq 'Windows_NT'
    }

    $script:StartupProfile.Facts.IsWindows = $detectedWindows
    if ($detectedWindows) {
        Add-StartupResult -Status '已就绪' -TitleText 'Windows 运行环境' -Detail '已识别为 Windows'
    }
    else {
        Add-StartupResult -Status '稍后处理' -TitleText '运行环境' -Detail '当前不是 Windows，建议改用 ./unix.sh'
    }

    $powerShellVersion = $PSVersionTable.PSVersion.ToString()
    $powerShellEdition = if ($PSVersionTable.ContainsKey('PSEdition')) {
        $PSVersionTable.PSEdition
    }
    else {
        'Unknown'
    }

    $script:StartupProfile.Facts.PowerShellVersion = $powerShellVersion
    $script:StartupProfile.Facts.PowerShellEdition = $powerShellEdition
    if ($PSVersionTable.PSVersion -ge [Version]'5.1') {
        Add-StartupResult -Status '已就绪' -TitleText 'PowerShell 版本' -Detail "$powerShellVersion ($powerShellEdition)"
    }
    else {
        Add-StartupResult -Status '稍后处理' -TitleText 'PowerShell 版本' -Detail "$powerShellVersion ($powerShellEdition)，版本偏旧，后续阶段会继续兼容处理"
    }

    $is64BitProcess = [Environment]::Is64BitProcess
    $is64BitOperatingSystem = [Environment]::Is64BitOperatingSystem
    $script:StartupProfile.Facts.Is64BitProcess = $is64BitProcess
    $script:StartupProfile.Facts.Is64BitOperatingSystem = $is64BitOperatingSystem

    if ($is64BitProcess) {
        Add-StartupResult -Status '已就绪' -TitleText '64 位 PowerShell 进程' -Detail '当前正在使用 64 位进程'
    }
    elseif ($is64BitOperatingSystem) {
        Add-StartupResult -Status '将自动适配' -TitleText '64 位 PowerShell 进程' -Detail '当前是 32 位进程，启动时会尝试切换到 64 位环境'
    }
    else {
        Add-StartupResult -Status '稍后处理' -TitleText '64 位 PowerShell 进程' -Detail '当前系统不是 64 位，后续阶段会按实际环境继续处理'
    }

    try {
        $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
        $principal = [Security.Principal.WindowsPrincipal]::new($identity)
        $isAdmin = $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    }
    catch {
        $isAdmin = $false
    }

    $script:StartupProfile.Facts.IsAdmin = $isAdmin
    if ($isAdmin) {
        Add-StartupResult -Status '仅提示' -TitleText '运行权限' -Detail '当前为管理员模式，仅在需要全局安装时才会使用'
    }
    else {
        Add-StartupResult -Status '仅提示' -TitleText '运行权限' -Detail '当前为普通用户模式，默认优先使用用户级安装'
    }

    $script:StartupProfile.Facts.InstallRoot = $InstallRoot
    $installRootWritable = Test-DirectoryWritable -Path $InstallRoot
    $script:StartupProfile.Facts.InstallRootWritable = $installRootWritable
    if ($installRootWritable) {
        Add-StartupResult -Status '已就绪' -TitleText '用户目录写入能力' -Detail "可使用 $InstallRoot"
    }
    else {
        Add-StartupResult -Status '稍后处理' -TitleText '用户目录写入能力' -Detail '暂时无法确认 LOCALAPPDATA 安装目录可写，后续阶段会继续处理'
    }

    $networkReachable = Test-UrlReachable -Uri $StartupProbeUrl
    $script:StartupProfile.Facts.StartupProbeUrl = $StartupProbeUrl
    $script:StartupProfile.Facts.NetworkReachable = $networkReachable
    if ($networkReachable) {
        Add-StartupResult -Status '已就绪' -TitleText '网络连接' -Detail '已确认 get.dingjiai.com 可访问'
    }
    else {
        Add-StartupResult -Status '稍后处理' -TitleText '网络连接' -Detail '暂时无法确认 get.dingjiai.com 可达，安装和更新阶段会继续处理'
    }
}

function Show-StartupSummary {
    $readyCount = @($script:StartupProfile.Results | Where-Object { $_.Status -eq '已就绪' }).Count
    $autoCount = @($script:StartupProfile.Results | Where-Object { $_.Status -eq '将自动适配' }).Count
    $laterCount = @($script:StartupProfile.Results | Where-Object { $_.Status -eq '稍后处理' }).Count
    $infoCount = @($script:StartupProfile.Results | Where-Object { $_.Status -eq '仅提示' }).Count

    $script:StartupProfile.Summary = [ordered]@{
        Ready = $readyCount
        AutoAdapt = $autoCount
        Defer = $laterCount
        Info = $infoCount
    }

    Write-Host ''
    Write-Host "环境识别完成：已就绪 $readyCount 项，将自动适配 $autoCount 项，稍后处理 $laterCount 项，仅提示 $infoCount 项。"
}

function Show-Menu {
    Write-Host ''
    Write-Host '================================'
    Write-Host " $Title"
    Write-Host " $Subtitle"
    Write-Host '================================'

    foreach ($key in $MenuOrder) {
        Write-Host "[$key] $($MenuLabels[$key])"
    }

    Write-Host ''
}

function Invoke-Choice([string]$Choice) {
    if (-not $MenuMessages.ContainsKey($Choice)) {
        Write-Host "`n无效选项。"
        return
    }

    switch ($Choice) {
        '0' {
            Write-Host "`n$($MenuMessages[$Choice])"
            exit 0
        }
        '1' {
            Invoke-InstallOption1Flow
            return
        }
        default {
            Write-Host "`n$($MenuMessages[$Choice])"
            return
        }
    }
}

function Start-CmdMainUi {
    if (-not (Invoke-BootstrapHandoffChecks)) {
        throw '管理员 CMD 主窗口准备检查未通过。'
    }

    $mainCmdPath = Join-Path $ScriptDir 'main.cmd'
    if (-not (Test-Path -LiteralPath $mainCmdPath)) {
        throw "缺少主菜单脚本：$mainCmdPath"
    }

    $quotedMainCmdPath = '"' + $mainCmdPath + '"'
    $arguments = "/k $quotedMainCmdPath"

    Start-Process -FilePath 'cmd.exe' -ArgumentList $arguments -Verb RunAs | Out-Null
    Write-Host ''
    Write-Host '已打开管理员 CMD 主窗口，请在新窗口中继续操作。'
    exit 0
}

Import-Menu

if (-not [string]::IsNullOrWhiteSpace($Action)) {
    switch ($Action) {
        'install' {
            Invoke-StartupPreflight
            Invoke-StartupDetection
            Show-StartupSummary
            if (-not $script:StartupProfile.Facts.IsWindows) {
                throw '当前环境不是 Windows，无法继续执行安装流程。'
            }

            if (-not (Invoke-WingetCheckpoint)) {
                exit 1
            }

            if (-not (Invoke-GitCheckpoint)) {
                exit 1
            }

            Write-Host ''
            Write-Host '已完成首个真实里程碑：winget + Git。'
            Write-Host '当前流程在 Git checkpoint 后停止。'
            exit 0
        }
        'bootstrap-checks' {
            if (Invoke-BootstrapHandoffChecks) {
                exit 0
            }

            exit 1
        }
        'update' {
            Write-Host '更新功能正在准备中，当前版本暂未开放。'
            exit 0
        }
        'uninstall' {
            Write-Host '卸载功能正在准备中，当前版本暂未开放。'
            exit 0
        }
        default {
            throw "未识别的 Action：$Action"
        }
    }
}

Start-CmdMainUi
