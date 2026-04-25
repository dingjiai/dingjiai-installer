@echo off
chcp 65001 >NUL
setlocal EnableExtensions

echo 更新 Claude 和依赖 flow 已进入。
echo 当前 flow 只包含 checkpoint 占位，不会修改系统。
echo.
call "%~dp0checkpoints\00_preflight.cmd"
if errorlevel 1 exit /b %errorlevel%
call "%~dp0checkpoints\20_git.cmd"
if errorlevel 1 exit /b %errorlevel%
call "%~dp0checkpoints\30_claude.cmd"
if errorlevel 1 exit /b %errorlevel%
call "%~dp0checkpoints\40_enhancements.cmd"
if errorlevel 1 exit /b %errorlevel%
call "%~dp0checkpoints\90_finalize.cmd"
if errorlevel 1 exit /b %errorlevel%
echo.
echo 更新 Claude 和依赖 flow 占位已结束。
exit /b 0
