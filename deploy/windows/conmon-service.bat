@echo off
:: =============================================================================
:: conmon-service.bat — conMon Windows Service 快捷管理（CMD 入口）
:: 需要以管理员身份运行
:: =============================================================================
chcp 65001 >nul 2>&1
setlocal EnableDelayedExpansion

set "SCRIPT_DIR=%~dp0"
set "SERVICE_NAME=conmon"

:: 检查管理员权限
net session >nul 2>&1
if %errorlevel% neq 0 (
    echo [错误] 请以管理员身份运行此脚本
    echo 右键点击 → 以管理员身份运行
    pause
    exit /b 1
)

set "CMD=%~1"
if "%CMD%"=="" set "CMD=help"

if /i "%CMD%"=="start"   goto :start
if /i "%CMD%"=="stop"    goto :stop
if /i "%CMD%"=="restart" goto :restart
if /i "%CMD%"=="status"  goto :status
if /i "%CMD%"=="install" goto :install
if /i "%CMD%"=="uninstall" goto :uninstall
if /i "%CMD%"=="logs"    goto :logs
goto :help

:start
echo [启动] conMon 服务...
sc start %SERVICE_NAME%
if %errorlevel%==0 (
    echo [OK] 服务已启动
) else (
    echo [警告] 启动失败或服务已在运行
)
goto :wait

:stop
echo [停止] conMon 服务...
sc stop %SERVICE_NAME%
if %errorlevel%==0 (
    echo [OK] 服务已停止
) else (
    echo [警告] 停止失败或服务未运行
)
goto :wait

:restart
call :stop
timeout /t 2 /nobreak >nul
call :start
goto :end

:status
echo.
echo === 服务状态 ===
sc query %SERVICE_NAME%
echo.
echo === 健康检查 ===
curl -sf http://localhost:8080/health 2>nul || echo [警告] API 未响应
echo.
goto :end

:install
echo [安装] 运行 PowerShell 安装脚本...
powershell.exe -NonInteractive -ExecutionPolicy Bypass ^
    -File "%SCRIPT_DIR%install.ps1" %~2 %~3 %~4 %~5
goto :end

:uninstall
echo [卸载] 运行 PowerShell 卸载脚本...
powershell.exe -NonInteractive -ExecutionPolicy Bypass ^
    -File "%SCRIPT_DIR%uninstall.ps1" %~2 %~3
goto :end

:logs
echo [日志] 最近 50 条 Windows 事件日志...
powershell.exe -Command ^
    "Get-EventLog -LogName Application -Source conmon -Newest 50 -ErrorAction SilentlyContinue | Format-Table TimeGenerated,EntryType,Message -AutoSize"
goto :end

:help
echo.
echo conMon Windows Service 管理工具
echo.
echo 用法: conmon-service.bat ^<命令^>
echo.
echo 命令:
echo   start      启动服务
echo   stop       停止服务
echo   restart    重启服务
echo   status     查看服务状态和健康检查
echo   install    安装 conMon（运行 install.ps1）
echo   uninstall  卸载 conMon（运行 uninstall.ps1）
echo   logs       查看最近日志
echo.
echo 注意：需要以管理员身份运行
goto :end

:wait
timeout /t 1 /nobreak >nul
:end
endlocal
