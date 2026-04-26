@echo off
chcp 65001 >NUL
setlocal EnableExtensions

echo [uninstall/90_finalize] NOT_IMPLEMENTED
echo 当前 checkpoint 尚未实现，不会安装、修复、卸载或修改系统。
echo 后续版本接入真实逻辑前，必须先补齐 checkpoint.v1 契约和自检。
exit /b 11
