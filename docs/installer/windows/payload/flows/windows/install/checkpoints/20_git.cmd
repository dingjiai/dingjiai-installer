@echo off
chcp 65001 >NUL
setlocal EnableExtensions

set "GIT_HELPER=%~dp0..\..\..\..\lib\windows\git.ps1"
if not exist "%GIT_HELPER%" (
  echo Git checkpoint helper missing.
  exit /b 20
)

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%GIT_HELPER%" -FlowName "install" -CheckpointName "git" %*
exit /b %errorlevel%
