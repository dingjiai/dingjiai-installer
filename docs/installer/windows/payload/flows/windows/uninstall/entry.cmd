@echo off
chcp 65001 >NUL
setlocal EnableExtensions

echo 卸载 Claude 和依赖 flow 已进入。
echo 当前 flow 仍包含未实现 checkpoint；遇到 NOT_IMPLEMENTED 会停止，不会伪装完成。
echo.
call "%~dp0checkpoints\00_preflight.cmd"
if errorlevel 1 exit /b %errorlevel%
call "%~dp0checkpoints\30_claude.cmd"
if errorlevel 1 exit /b %errorlevel%
call "%~dp0checkpoints\40_enhancements.cmd"
if errorlevel 1 exit /b %errorlevel%
call "%~dp0checkpoints\90_finalize.cmd"
if errorlevel 1 exit /b %errorlevel%
echo.
echo 卸载 Claude 和依赖 flow 已完成当前可执行样板。
exit /b 0
