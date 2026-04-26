@echo off
chcp 65001 >NUL
setlocal EnableExtensions

set "RUNNER=%~dp0..\..\..\..\lib\windows\checkpoint_runner.cmd"
set "DOWNLOAD_HELPER=%~dp0..\..\..\..\lib\windows\download.ps1"
if not exist "%RUNNER%" (
  echo checkpoint runner missing.
  exit /b 20
)

set "DINGJIAI_CHECKPOINT_HELPER=%DOWNLOAD_HELPER%"
set "DINGJIAI_CHECKPOINT_FLOW=install"
set "DINGJIAI_CHECKPOINT_NAME=app-installer-download"
call "%RUNNER%" -ArtifactKind "AppInstaller" -ArtifactName "app-installer.msixbundle" %*
exit /b %errorlevel%
