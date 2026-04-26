@echo off
chcp 65001 >NUL
setlocal EnableExtensions

set "RUNNER=%~dp0..\..\..\..\lib\windows\checkpoint_runner.cmd"
set "WINGET_HELPER=%~dp0..\..\..\..\lib\windows\winget.ps1"
if not exist "%RUNNER%" (
  echo checkpoint runner missing.
  exit /b 20
)

set "DINGJIAI_CHECKPOINT_HELPER=%WINGET_HELPER%"
set "DINGJIAI_CHECKPOINT_FLOW=install"
set "DINGJIAI_CHECKPOINT_NAME=winget"
call "%RUNNER%" %*
exit /b %errorlevel%
