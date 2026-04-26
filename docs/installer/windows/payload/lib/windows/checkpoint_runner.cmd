@echo off
chcp 65001 >NUL
setlocal EnableExtensions

set "HELPER=%DINGJIAI_CHECKPOINT_HELPER%"
set "FLOW_NAME=%DINGJIAI_CHECKPOINT_FLOW%"
set "CHECKPOINT_NAME=%DINGJIAI_CHECKPOINT_NAME%"

if "%HELPER%"=="" goto missing_required
if "%FLOW_NAME%"=="" goto missing_required
if "%CHECKPOINT_NAME%"=="" goto missing_required

if not exist "%HELPER%" (
  echo checkpoint helper missing: %HELPER%
  exit /b 20
)

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%HELPER%" -FlowName "%FLOW_NAME%" -CheckpointName "%CHECKPOINT_NAME%" %*
exit /b %errorlevel%

:missing_required
echo checkpoint runner requires DINGJIAI_CHECKPOINT_HELPER, DINGJIAI_CHECKPOINT_FLOW, and DINGJIAI_CHECKPOINT_NAME.
exit /b 70
