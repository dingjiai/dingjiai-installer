@echo off
chcp 65001 >nul
setlocal EnableExtensions

set "STARTUP_ID="
set "STATE_PATH="
set "PAYLOAD_ROOT="
set "HANDOFF_MODE="

:parse_args
if "%~1"=="" goto after_parse
if /I "%~1"=="--startup-id" (
  set "STARTUP_ID=%~2"
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
if /I "%~1"=="--payload-root" (
  set "PAYLOAD_ROOT=%~2"
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
if not defined STATE_PATH goto bad_args
if not defined PAYLOAD_ROOT goto bad_args
if /I not "%HANDOFF_MODE%"=="admin-cmd" goto bad_args

net session >nul 2>nul
if errorlevel 1 goto not_admin

powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "$statePath = [Environment]::GetEnvironmentVariable('STATE_PATH', 'Process'); $startupId = [Environment]::GetEnvironmentVariable('STARTUP_ID', 'Process'); $payloadRoot = [Environment]::GetEnvironmentVariable('PAYLOAD_ROOT', 'Process'); $state = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json; if ($state.startupId -ne $startupId) { throw 'startupId mismatch' }; $state.stage = 'completed'; $state.handoffAccepted = $true; $state.handoffAcceptedAt = (Get-Date).ToString('o'); $state.acceptedPayloadRoot = $payloadRoot; $state | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $statePath -Encoding UTF8"
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
