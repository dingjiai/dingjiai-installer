param(
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

    Write-Host "`n$($MenuMessages[$Choice])"

    if ($Choice -eq '0') {
        exit 0
    }
}

Import-Menu
Invoke-StartupPreflight
Invoke-StartupDetection
Show-StartupSummary

while ($true) {
    Show-Menu
    $choice = Read-Host '请选择一个选项'
    Invoke-Choice $choice
    Read-Host '按回车继续' | Out-Null
}
