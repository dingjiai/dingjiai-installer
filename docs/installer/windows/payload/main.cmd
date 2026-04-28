@echo off
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
set "DEFERRED_PAYLOAD_READY="

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

fltmc >nul 2>nul
if errorlevel 1 goto not_admin

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%PAYLOAD_ROOT%\lib\windows\console_guard.ps1"
if errorlevel 1 goto console_failed

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%PAYLOAD_ROOT%\lib\windows\startup_accept.ps1" -StartupId "%STARTUP_ID%" -WorkspaceRoot "%WORKSPACE_ROOT%" -StatePath "%STATE_PATH%" -LogPath "%LOG_PATH%" -PayloadRoot "%PAYLOAD_ROOT%" -MainEntryPath "%MAIN_ENTRY_PATH%" -Source "%SOURCE%" -SelfPath "%SELF_PATH%"
if errorlevel 1 goto state_failed

title dingjiai installer
color 07
mode con: cols=76 lines=30 >nul 2>nul
cls

:main_menu
cls
call :render_ui main
if errorlevel 1 exit /b %errorlevel%
choice /C:1230 /N /M "              Press a key [1,2,3,0]: "
if errorlevel 4 exit
if errorlevel 3 goto flow_uninstall
if errorlevel 2 goto flow_update
if errorlevel 1 goto flow_install
goto main_menu

:flow_install
cls
call :render_ui install
if errorlevel 1 exit /b %errorlevel%
call :ensure_deferred_payload
if errorlevel 1 goto main_menu
call "%PAYLOAD_ROOT%\flows\windows\install\entry.cmd"
echo(
pause
cls
goto main_menu

:flow_update
cls
call :render_ui update
if errorlevel 1 exit /b %errorlevel%
call :ensure_deferred_payload
if errorlevel 1 goto main_menu
call "%PAYLOAD_ROOT%\flows\windows\update\entry.cmd"
echo(
pause
cls
goto main_menu

:flow_uninstall
cls
call :render_ui uninstall
if errorlevel 1 exit /b %errorlevel%
call :ensure_deferred_payload
if errorlevel 1 goto main_menu
call "%PAYLOAD_ROOT%\flows\windows\uninstall\entry.cmd"
echo(
pause
cls
goto main_menu

:ensure_deferred_payload
if "%DEFERRED_PAYLOAD_READY%"=="1" exit /b 0
echo 正在准备启动文件，请稍等...
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%PAYLOAD_ROOT%\lib\windows\deferred_payload_sync.ps1" -WorkspaceRoot "%WORKSPACE_ROOT%" -PayloadRoot "%PAYLOAD_ROOT%" -ManifestPath "%WORKSPACE_ROOT%\manifest.json" -StatePath "%STATE_PATH%" -BaseUrl "https://get.dingjiai.com/installer/windows"
if errorlevel 1 goto deferred_payload_failed
set "DEFERRED_PAYLOAD_READY=1"
exit /b 0

:deferred_payload_failed
echo 启动文件准备失败，请检查网络后重试。
pause
exit /b 1

:render_ui
if not exist "%PAYLOAD_ROOT%\ui.ps1" goto ui_failed
chcp 65001 >nul
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%PAYLOAD_ROOT%\ui.ps1" -Page "%~1"
if errorlevel 1 goto ui_failed
exit /b 0

:ui_failed
echo UI render failed.
pause
exit /b 5

:bad_args
echo Startup arguments are incomplete.
pause
exit /b 2

:not_admin
echo Please run this entry from an administrator CMD window.
pause
exit /b 4

:console_failed
echo Console setup failed.
pause
exit /b 6

:state_failed
echo Startup state update failed.
pause
exit /b 3
