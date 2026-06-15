# conMon Windows 部署脚本说明

`deploy/windows/` 目录包含 conMon 在 Windows 环境下的完整部署、运维自动化脚本。

---

## 脚本列表

| 脚本 | 类型 | 用途 | 权限 |
|------|------|------|------|
| `check.ps1` | PowerShell | 部署前环境预检 | 普通用户 |
| `install.ps1` | PowerShell | 一键安装 + Windows Service 注册 | **管理员** |
| `docker.ps1` | PowerShell | Docker 单机部署管理 | 普通用户 |
| `compose.ps1` | PowerShell | Docker Compose 全栈部署 | 普通用户 |
| `upgrade.ps1` | PowerShell | 自动升级（自动识别部署方式） | 视部署方式 |
| `backup.ps1` | PowerShell | 数据备份与恢复 | 普通用户 |
| `uninstall.ps1` | PowerShell | 卸载 | **管理员** |
| `conmon-service.bat` | CMD | Windows Service 快捷管理 | **管理员** |
| `conmon-docker.bat` | CMD | Docker 快捷管理 | 普通用户 |
| `run-as-admin.bat` | CMD | 一键打开管理员 PowerShell | — |

---

## 快速开始

### 第一步：允许执行 PowerShell 脚本

以**管理员身份**打开 PowerShell，执行一次：

```powershell
Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope LocalMachine
```

> 或者每次执行时加 `-ExecutionPolicy Bypass` 参数（推荐脚本内部已内置）

### 第二步：环境检查

```powershell
cd deploy\windows

# 基础环境检查
.\check.ps1

# 指定部署模式检查
.\check.ps1 -Mode docker
.\check.ps1 -Mode all
```

### 第三步：选择部署方式

---

## 方式 A：Windows Service（推荐裸机/VM，无 Docker）

```powershell
# 以管理员身份运行（双击 run-as-admin.bat 或右键 → 以管理员身份运行 PowerShell）

# 1. 安装（下载二进制 + 注册 Windows Service）
.\install.ps1

# 也可指定版本
.\install.ps1 -Version v2.0.0

# 2. 启动服务
Start-Service conmon

# 3. 验证
Invoke-RestMethod http://localhost:11080/health
```

**快捷方式（CMD，双击 conmon-service.bat）：**

```bat
conmon-service.bat start
conmon-service.bat status
conmon-service.bat stop
conmon-service.bat restart
```

**服务管理（PowerShell）：**

```powershell
Get-Service conmon               # 查看状态
Start-Service conmon             # 启动
Stop-Service conmon              # 停止
Restart-Service conmon           # 重启

# 查看事件日志
Get-EventLog -LogName Application -Source conmon -Newest 50

# 设置开机自启（已默认配置）
Set-Service conmon -StartupType Automatic
```

---

## 方式 B：Docker（需要 Docker Desktop for Windows）

```powershell
# 1. 启动
.\docker.ps1 start

# 指定版本
.\docker.ps1 start -Version v2.0.0

# 2. 查看状态
.\docker.ps1 status

# 3. 实时日志
.\docker.ps1 logs -Follow

# 4. 更新到新版本
.\docker.ps1 update v2.1.0

# 5. 停止
.\docker.ps1 stop
```

**CMD 快捷方式：**

```bat
conmon-docker.bat start
conmon-docker.bat status
conmon-docker.bat logs
```

---

## 方式 C：Docker Compose（完整栈：conmon + PostgreSQL + Grafana）

```powershell
# 1. 初始化（生成 .env，自动随机化密钥）
.\compose.ps1 init

# 2. 启动全栈
.\compose.ps1 up

# 3. 查看状态
.\compose.ps1 status

# 4. 实时日志
.\compose.ps1 logs -Follow

# 5. 升级
.\compose.ps1 upgrade v2.1.0

# 6. 停止
.\compose.ps1 down
```

---

## 升级

```powershell
# 自动检测部署方式并升级到最新版
.\upgrade.ps1

# 指定版本
.\upgrade.ps1 -Version v2.1.0

# 预览（不实际执行）
.\upgrade.ps1 -DryRun
```

---

## 备份与恢复

```powershell
# 全量备份（配置 + SQLite + 日志）
.\backup.ps1

# 指定备份目录
.\backup.ps1 -BackupDest D:\backups\conmon

# 查看所有备份
.\backup.ps1 -List

# 恢复指定备份
.\backup.ps1 -RestoreTimestamp 20260615_030000
```

**自动定时备份：** 首次运行时脚本会询问是否创建 Windows 任务计划程序任务（每天 03:00 自动备份）。

也可手动创建任务：

```powershell
# 手动创建定时备份任务
$action  = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument '-NonInteractive -ExecutionPolicy Bypass -File "C:\path\to\deploy\windows\backup.ps1"'
$trigger = New-ScheduledTaskTrigger -Daily -At '03:00'
Register-ScheduledTask -TaskName 'conMon-DailyBackup' -Action $action -Trigger $trigger -RunLevel Highest
```

---

## 卸载

```powershell
# 卸载但保留数据
.\uninstall.ps1

# 完全卸载（删除所有数据，不可恢复！）
.\uninstall.ps1 -RemoveData

# 预览将执行的操作
.\uninstall.ps1 -DryRun
```

**CMD 方式：**

```bat
conmon-service.bat uninstall
```

---

## 配置文件位置

| 文件 | 位置 |
|------|------|
| 主配置文件 | `C:\ProgramData\conmon\config\conmon.yaml` |
| 环境变量配置 | `C:\ProgramData\conmon\config\conmon.env` |
| SQLite 数据库 | `C:\ProgramData\conmon\conmon.db` |
| 日志目录 | `C:\ProgramData\conmon\logs\` |
| 二进制文件 | `C:\Program Files\conmon\conmon.exe` |

---

## 环境变量

脚本支持以下 PowerShell 环境变量：

```powershell
$env:CONMON_VERSION    = 'v2.0.0'     # 镜像/二进制版本
$env:CONMON_HTTP_PORT  = '11080'       # HTTP 端口
$env:CONMON_CONFIG     = 'D:\conmon.yaml'  # 配置文件路径
$env:JWT_SECRET        = 'my-secret'  # JWT 密钥
$env:DB_PASSWORD       = 'db-pass'    # 数据库密码
```

---

## 常见问题

**Q: 执行脚本报「无法加载文件，因为在此系统上禁止运行脚本」**

```powershell
# 以管理员 PowerShell 执行一次：
Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope LocalMachine
```

**Q: install.ps1 报「不是内部或外部命令」**

确保以**管理员身份**运行 PowerShell（双击 `run-as-admin.bat`）。

**Q: 服务启动后 `http://localhost:11080/health` 无响应**

```powershell
# 查看服务状态
Get-Service conmon

# 查看启动日志
Get-EventLog -LogName Application -Source conmon -Newest 20 | Format-List

# 检查防火墙
Test-NetConnection -ComputerName localhost -Port 11080
```

**Q: Docker Desktop 不能启动**

确保已启用 WSL2（Windows Subsystem for Linux 2）：

```powershell
# 以管理员运行
wsl --install
wsl --set-default-version 2
```

**Q: 配置修改后如何热重载**

```powershell
# Windows Service 模式：发送信号（conmon 支持配置热重载）
# 目前需要重启服务
Restart-Service conmon
```

更多问题参见 [故障排查指南](../../docs/troubleshooting.md)。
