@echo off
chcp 65001 >nul
setlocal EnableExtensions
set "SELF_PATH=%~f0"

set "STARTUP_ID="
set "WORKSPACE_ROOT="
set "STATE_PATH="
set "LOG_PATH="
set "PAYLOAD_ROOT="
set "MAIN_ENTRY_PATH="
set "SOURCE="
set "HANDOFF_MODE="

:parse_args
if "%~1"=="" goto after_parse
if /I "%~1"=="--startup-id" (
  set "STARTUP_ID=%~2"
  shift
  shift
  goto parse_args
)
if /I "%~1"=="--workspace-root" (
  set "WORKSPACE_ROOT=%~2"
  shift
  shift
  goto parse_args
)
if /I "%~1"=="--state" (
  set "STATE_PATH=%~2"
  shift
  shift
  goto parse_args
)
if /I "%~1"=="--log-path" (
  set "LOG_PATH=%~2"
  shift
  shift
  goto parse_args
)
if /I "%~1"=="--payload-root" (
  set "PAYLOAD_ROOT=%~2"
  shift
  shift
  goto parse_args
)
if /I "%~1"=="--main-entry-path" (
  set "MAIN_ENTRY_PATH=%~2"
  shift
  shift
  goto parse_args
)
if /I "%~1"=="--source" (
  set "SOURCE=%~2"
  shift
  shift
  goto parse_args
)
if /I "%~1"=="--handoff-mode" (
  set "HANDOFF_MODE=%~2"
  shift
  shift
  goto parse_args
)
shift
goto parse_args

:after_parse
if not defined STARTUP_ID goto bad_args
if not defined WORKSPACE_ROOT goto bad_args
if not defined STATE_PATH goto bad_args
if not defined LOG_PATH goto bad_args
if not defined PAYLOAD_ROOT goto bad_args
if not defined MAIN_ENTRY_PATH goto bad_args
if not defined SOURCE goto bad_args
if /I not "%HANDOFF_MODE%"=="admin-cmd" goto bad_args
if not exist "%WORKSPACE_ROOT%\" goto bad_args
if not exist "%STATE_PATH%" goto bad_args
if not exist "%PAYLOAD_ROOT%\" goto bad_args
if /I not "%SELF_PATH%"=="%MAIN_ENTRY_PATH%" goto bad_args

net session >nul 2>nul
if errorlevel 1 goto not_admin

powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "$ErrorActionPreference = 'Stop'; function Full([string]$Path) { if ([string]::IsNullOrWhiteSpace($Path)) { throw 'empty path' }; [System.IO.Path]::GetFullPath($Path).TrimEnd([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar) }; function Same([string]$Left, [string]$Right) { (Full $Left).Equals((Full $Right), [System.StringComparison]::OrdinalIgnoreCase) }; function Under([string]$Child, [string]$Parent) { $childFull = Full $Child; $parentFull = Full $Parent; $separator = [System.IO.Path]::DirectorySeparatorChar; $childFull.Equals($parentFull, [System.StringComparison]::OrdinalIgnoreCase) -or $childFull.StartsWith($parentFull + $separator, [System.StringComparison]::OrdinalIgnoreCase) }; function Need($Condition, [string]$Message) { if (-not $Condition) { throw $Message } }; $startupId = [Environment]::GetEnvironmentVariable('STARTUP_ID', 'Process'); $workspaceRoot = [Environment]::GetEnvironmentVariable('WORKSPACE_ROOT', 'Process'); $statePath = [Environment]::GetEnvironmentVariable('STATE_PATH', 'Process'); $logPath = [Environment]::GetEnvironmentVariable('LOG_PATH', 'Process'); $payloadRoot = [Environment]::GetEnvironmentVariable('PAYLOAD_ROOT', 'Process'); $mainEntryPath = [Environment]::GetEnvironmentVariable('MAIN_ENTRY_PATH', 'Process'); $source = [Environment]::GetEnvironmentVariable('SOURCE', 'Process'); $selfPath = [Environment]::GetEnvironmentVariable('SELF_PATH', 'Process'); Need (Test-Path -LiteralPath $workspaceRoot -PathType Container) 'workspace missing'; Need (Test-Path -LiteralPath $statePath -PathType Leaf) 'state missing'; Need (Test-Path -LiteralPath $payloadRoot -PathType Container) 'payload missing'; Need (Same $payloadRoot (Join-Path (Full $workspaceRoot) 'payload')) 'payload root mismatch'; Need (Same ([System.IO.Path]::GetDirectoryName((Full $statePath))) (Join-Path (Full $workspaceRoot) 'state')) 'state path outside workspace'; Need (Same ([System.IO.Path]::GetDirectoryName((Full $logPath))) (Join-Path (Full $workspaceRoot) 'logs')) 'log path outside workspace'; Need (Under $mainEntryPath $payloadRoot) 'main entry outside payload root'; Need (Same $mainEntryPath $selfPath) 'main entry self mismatch'; $state = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json; Need ($state.startupId -eq $startupId) 'startupId mismatch'; Need ($state.stage -ne 'failed') 'startup already failed'; Need (Same $state.workspaceRoot $workspaceRoot) 'state workspace mismatch'; Need (Same $state.payloadRoot $payloadRoot) 'state payload mismatch'; Need (Same $state.mainEntryPath $mainEntryPath) 'state main entry mismatch'; Need ($state.source -eq $source) 'state source mismatch'; if (-not ($state.stage -eq 'completed' -and $state.handoffAccepted -eq $true)) { $values = @{ stage = 'completed'; handoffAccepted = $true; handoffAcceptedAt = (Get-Date).ToString('o'); acceptedWorkspaceRoot = $workspaceRoot; acceptedStatePath = $statePath; acceptedLogPath = $logPath; acceptedPayloadRoot = $payloadRoot; acceptedMainEntryPath = $mainEntryPath; acceptedSource = $source; acceptedHandoffMode = 'admin-cmd' }; foreach ($key in $values.Keys) { $state | Add-Member -NotePropertyName $key -NotePropertyValue $values[$key] -Force }; $stateJson = $state | ConvertTo-Json -Depth 8; $directory = [System.IO.Path]::GetDirectoryName($statePath); $fileName = [System.IO.Path]::GetFileName($statePath); $tempPath = [System.IO.Path]::Combine($directory, ('{0}.{1}.tmp' -f $fileName, [guid]::NewGuid().ToString('N'))); $backupPath = [System.IO.Path]::Combine($directory, ('{0}.{1}.bak' -f $fileName, [guid]::NewGuid().ToString('N'))); try { Set-Content -LiteralPath $tempPath -Value $stateJson -Encoding UTF8; if ([System.IO.File]::Exists($statePath)) { [System.IO.File]::Replace($tempPath, $statePath, $backupPath) } else { [System.IO.File]::Move($tempPath, $statePath) } } finally { if ([System.IO.File]::Exists($tempPath)) { Remove-Item -LiteralPath $tempPath -Force -ErrorAction SilentlyContinue }; if ([System.IO.File]::Exists($backupPath)) { Remove-Item -LiteralPath $backupPath -Force -ErrorAction SilentlyContinue } } }"
if errorlevel 1 goto state_failed

cls

:main_menu
echo dingjiai installer
echo.
echo 启动阶段已完成，管理员 CMD 主窗口已接管。
echo.
echo 当前菜单仍是占位，安装 / 更新 / 卸载尚未接入。
echo.
echo 1 安装 Claude 和依赖（未接入）
echo 2 更新 Claude 和依赖（未接入）
echo 3 卸载 Claude 和依赖（未接入）
echo 0 退出
echo.
set "MENU_CHOICE="
set /p "MENU_CHOICE=请选择："
if "%MENU_CHOICE%"=="1" goto placeholder_install
if "%MENU_CHOICE%"=="2" goto placeholder_update
if "%MENU_CHOICE%"=="3" goto placeholder_uninstall
if "%MENU_CHOICE%"=="0" exit /b 0
cls
echo 输入无效，请重新选择。
echo.
goto main_menu

:placeholder_install
cls
echo 正在进入安装任务...
echo.
call "%PAYLOAD_ROOT%\tasks\install.cmd"
echo.
pause
cls
goto main_menu

:placeholder_update
cls
echo 正在进入更新任务...
echo.
call "%PAYLOAD_ROOT%\tasks\update.cmd"
echo.
pause
cls
goto main_menu

:placeholder_uninstall
cls
echo 正在进入卸载任务...
echo.
call "%PAYLOAD_ROOT%\tasks\uninstall.cmd"
echo.
pause
cls
goto main_menu

:bad_args
echo 启动参数不完整，无法接管主窗口。
pause
exit /b 2

:not_admin
echo 请在管理员 CMD 主窗口中运行此入口。
pause
exit /b 4

:state_failed
echo 启动状态写入失败，无法确认接管。
pause
exit /b 3
