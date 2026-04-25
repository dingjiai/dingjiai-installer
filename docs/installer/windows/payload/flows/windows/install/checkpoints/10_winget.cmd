@echo off
chcp 65001 >NUL
setlocal EnableExtensions

set "WINGET_HELPER=%~dp0..\..\..\..\lib\windows\winget.ps1"
if not exist "%WINGET_HELPER%" (
  echo winget checkpoint helper missing.
  exit /b 20
)

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%WINGET_HELPER%" -FlowName "install" -CheckpointName "winget" %*
exit /b %errorlevel%
