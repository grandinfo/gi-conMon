@echo off
:: =============================================================================
:: conmon-docker.bat — conMon Docker 管理快捷入口（CMD）
:: =============================================================================
chcp 65001 >nul 2>&1
setlocal

set "SCRIPT_DIR=%~dp0"
set "CMD=%~1"
if "%CMD%"=="" set "CMD=help"
shift

:: 转发到 PowerShell 脚本
powershell.exe -NonInteractive -ExecutionPolicy Bypass ^
    -File "%SCRIPT_DIR%docker.ps1" %CMD% %1 %2 %3 %4 %5

endlocal
