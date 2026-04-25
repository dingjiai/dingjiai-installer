@echo off
chcp 65001 >NUL
setlocal EnableExtensions

echo 安装 Claude 和依赖 flow 已进入。
echo 当前 flow 包含只读 checkpoint 样板，不会安装、修复或修改系统。
echo.
call "%~dp0checkpoints\00_preflight.cmd"
if errorlevel 1 exit /b %errorlevel%
call "%~dp0checkpoints\10_winget.cmd"
if errorlevel 1 exit /b %errorlevel%
call "%~dp0checkpoints\15_app_installer_download.cmd"
if errorlevel 1 exit /b %errorlevel%
call "%~dp0checkpoints\20_git.cmd"
if errorlevel 1 exit /b %errorlevel%
call "%~dp0checkpoints\30_claude.cmd"
if errorlevel 1 exit /b %errorlevel%
call "%~dp0checkpoints\40_enhancements.cmd"
if errorlevel 1 exit /b %errorlevel%
call "%~dp0checkpoints\50_config.cmd"
if errorlevel 1 exit /b %errorlevel%
call "%~dp0checkpoints\90_finalize.cmd"
if errorlevel 1 exit /b %errorlevel%
echo.
echo 安装 Claude 和依赖 flow 样板已结束。
exit /b 0
