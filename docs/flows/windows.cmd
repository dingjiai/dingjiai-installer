@echo off
chcp 65001 >nul
setlocal EnableExtensions

set "WORKSPACE_ROOT="
set "PAYLOAD_ROOT="
set "STATE_PATH="
set "DEFERRED_PAYLOAD_READY="
set "ACTION_A=winget"
set "MENU_1_ACTIONS=A"

:parse_args
if "%~1"=="" goto after_parse
if /I "%~1"=="--workspace-root" (
  set "WORKSPACE_ROOT=%~2"
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
if /I "%~1"=="--state" (
  set "STATE_PATH=%~2"
  shift
  shift
  goto parse_args
)
shift
goto parse_args

:after_parse
if not defined WORKSPACE_ROOT goto bad_args
if not defined PAYLOAD_ROOT goto bad_args
if not defined STATE_PATH goto bad_args

:main_menu
cls
call :render_ui main
if errorlevel 1 exit /b %errorlevel%
choice /C:1230 /N /M "              Press a key [1,2,3,0]: "
if errorlevel 4 exit /b 0
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
call :run_menu_1_actions
echo(
pause
cls
goto main_menu

:run_menu_1_actions
for %%A in (%MENU_1_ACTIONS%) do call :run_action %%A
exit /b %errorlevel%

:run_action
if /I "%~1"=="A" (
  call "%PAYLOAD_ROOT%\actions\winget.cmd" ensure -FlowName install -CheckpointName winget
  exit /b %errorlevel%
)
echo NOT_IMPLEMENTED: unknown action %~1
exit /b 11

:flow_update
cls
call :render_ui update
if errorlevel 1 exit /b %errorlevel%
echo NOT_IMPLEMENTED: 更新 flow 暂未迁移到动作层。
echo(
pause
cls
goto main_menu

:flow_uninstall
cls
call :render_ui uninstall
if errorlevel 1 exit /b %errorlevel%
echo NOT_IMPLEMENTED: 卸载 flow 暂未迁移到动作层。
echo(
pause
cls
goto main_menu

:ensure_deferred_payload
if "%DEFERRED_PAYLOAD_READY%"=="1" exit /b 0
echo 正在准备任务文件，请稍等...
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%PAYLOAD_ROOT%\startup\deferred_payload_sync.ps1" -WorkspaceRoot "%WORKSPACE_ROOT%" -PayloadRoot "%PAYLOAD_ROOT%" -ManifestPath "%WORKSPACE_ROOT%\manifest.json" -StatePath "%STATE_PATH%" -BaseUrl "https://get.dingjiai.com"
if errorlevel 1 goto deferred_payload_failed
set "DEFERRED_PAYLOAD_READY=1"
exit /b 0

:deferred_payload_failed
echo 任务文件准备失败，请退出后重新运行。
pause
exit /b 1

:render_ui
if not exist "%PAYLOAD_ROOT%\startup\ui.ps1" goto ui_failed
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%PAYLOAD_ROOT%\startup\ui.ps1" -Page "%~1"
if errorlevel 1 goto ui_failed
exit /b 0

:ui_failed
echo UI render failed.
pause
exit /b 5

:bad_args
echo Flow arguments are incomplete.
pause
exit /b 2
