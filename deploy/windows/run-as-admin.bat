@echo off
:: =============================================================================
:: run-as-admin.bat — 以管理员权限启动 PowerShell 并进入 conMon 部署目录
:: 双击运行即可打开管理员 PowerShell 并进入 deploy\windows 目录
:: =============================================================================
chcp 65001 >nul 2>&1
set "SCRIPT_DIR=%~dp0"

powershell.exe -Command ^
    "Start-Process powershell.exe -ArgumentList '-NoExit','-ExecutionPolicy','Bypass','-Command','Set-Location ''%SCRIPT_DIR%''; Write-Host ''conMon 部署管理终端（管理员）'' -ForegroundColor Cyan; Write-Host ''可用脚本: check | install | upgrade | backup | uninstall | docker | compose'' -ForegroundColor Yellow' -Verb RunAs"
