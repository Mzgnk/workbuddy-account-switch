# ============================================================
#  WorkBuddy Account Switcher - 共享核心库 (v3.0)
#  被 switcher.ps1(菜单/命令行) 和 switcher-gui.ps1(图形界面) 共用
#  本文件只定义函数与路径, 不执行任何操作
#  注意: 档案目录(.workbuddy-profiles)内含登录凭证, 切勿拷给别人
# ============================================================

# ---------- 路径配置(自动探测, 换电脑不用改任何东西) ----------
$UserHome = [Environment]::GetFolderPath('UserProfile')
if (-not $UserHome) { $UserHome = $env:USERPROFILE }

# WorkBuddy 的用户数据目录(默认在用户主目录下的 .workbuddy)
# 若你的 WorkBuddy 把它指到别处, 设环境变量 WB_USER_DATA_DIR 覆盖即可
$WbRoot = if ($env:WB_USER_DATA_DIR) { $env:WB_USER_DATA_DIR } else { Join-Path $UserHome ".workbuddy" }

$ProfRoot    = Join-Path $UserHome ".workbuddy-profiles"
$CurrentFile = Join-Path $ProfRoot "current.json"
$BackupRoot  = Join-Path $ProfRoot "backup"
$JobFile     = Join-Path $ProfRoot "pending-job.json"
$LogFile     = Join-Path $ProfRoot "switch-log.txt"

# WorkBuddy 主程序: 优先取运行中进程的真实路径, 其次常见安装位置
# 都探测不到时, 手动把绝对路径填进 $WbExeOverride
$WbExeOverride = ""
function Find-WorkBuddyExe {
    $p = Get-Process -Name "WorkBuddy" -ErrorAction SilentlyContinue |
         Where-Object { $_.Path } | Select-Object -First 1
    if ($p) { return $p.Path }
    $cands = @((Join-Path $env:LOCALAPPDATA "Programs\WorkBuddy\WorkBuddy.exe"))
    if ($env:ProgramFiles)      { $cands += (Join-Path $env:ProgramFiles "WorkBuddy\WorkBuddy.exe") }
    if (${env:ProgramFiles(x86)}) { $cands += (Join-Path ${env:ProgramFiles(x86)} "WorkBuddy\WorkBuddy.exe") }
    foreach ($c in $cands) { if ($c -and (Test-Path $c)) { return $c } }
    return $null
}
$WbExe = if ($WbExeOverride) { $WbExeOverride } else { Find-WorkBuddyExe }

# ---------- 切换清单: 目录(整目录镜像) ----------
# ⚠ 如发现切换后有数据串号, 把对应目录加进这个列表即可
$SwapDirs = @(
    "app\session\Network",          # Cookies 等登录凭证
    "app\session\Local Storage",    # 网页本地存储(含当前账号指针)
    "app\session\Session Storage",
    "app\session\IndexedDB",
    "app\session\WebStorage",
    "app\session\Partitions",       # 分区(可能含独立 Cookie 罐)
    "app\session\Service Worker",   # SW 注册/缓存(可能含凭证)
    "local_storage",                # 应用级 KV 存储
    "storage",                      # 含 account-snapshot.json(当前账号声明)
    "security",                     # 按账号 UUID 分目录的凭证库(2026-10-28 弹回元凶)
    "connectors",                   # 连接器绑定状态
    "projects",                     # 本地会话记录
    "tasks",
    "sessions",
    "skill-cloud-sync"
)

# ---------- 切换清单: 单个文件 ----------
$SwapFiles = @(
    "app\session\Preferences",
    "app\session\Local State",      # os_crypt 密钥等(与 Cookies 配套)
    "app\session\DIPS",
    "app\session\DIPS-wal",
    "login-device-nonce",           # 设备级自动登录凭证(2026-10-28 弹回元凶嫌疑)
    "workbuddy.db",
    "workbuddy.db-wal",
    "workbuddy.db-shm",
    "edge-sync-mapping-v4.db",
    "edge-sync-mapping-v4.db-wal",
    "edge-sync-mapping-v4.db-shm",
    "plugin-status-daily.json",
    "models.json"
)

# ---------- 切换清单: 仓库外的绝对路径目录 (v3) ----------
# 真身登录会话不在 .workbuddy 里。应用启动时由 FileAuthStorage 读
# <sharedDataPath>\auth\workbuddy-desktop.info 决定"我是谁"; 不换它,
# 上面那些文件全换对了, 启动 7 秒后仍会被旧会话覆盖回原账号。
$ExtDataBase = Join-Path ([Environment]::GetFolderPath("LocalApplicationData")) "CodeBuddyExtension\Data"
$SwapExtDirs = @(
    @{ Live = (Join-Path $ExtDataBase "Public\auth"); Store = "_external\Data\Public\auth" }
)

# 清单版本: 每次增删切换项必须 +1。旧版本存的档案缺新项, 还原会弹回 → 切换时强制拒绝
$SwapListVersion = 3   # v3: 2026-10-28 加入 CodeBuddyExtension\Data\Public\auth (真身登录会话)

# ---------- 会话互通 (v3.4) ----------
# WorkBuddy 的会话不是按账号分库存的: 所有账号的会话都躺在同一个 workbuddy.db 里,
# 每条会话带 user_id 标签, 界面按"当前登录账号"过滤显示。
#   $true  = 各账号共享会话历史: 切换时不搬会话数据, 只把会话归属统一到当前账号
#   $false = 各账号各自独立(旧行为): 切换时整体搬运 projects/sessions/workbuddy.db
# 想退回独立模式: 把下面改成 $false 即可 (数据库索引每次切换前仍会自动备份)
$ShareConversations = $true
$ConvDirs  = @("projects", "sessions", "tasks")
$ConvFiles = @("workbuddy.db", "workbuddy.db-wal", "workbuddy.db-shm")

# 会话互通的执行体(内嵌): 磁盘上有 merge-sessions.py 就用它(便于调试),
# 没有则用这段源码现场生成 → 互通能力内聚在插件内, 不依赖散落的外部文件
$MergeSessionPySrc = @'
import json
import sqlite3
import sys


def stats(con):
    rows = con.execute("SELECT user_id, count(*) FROM sessions GROUP BY user_id").fetchall()
    return {("" if k is None else k): v for k, v in rows}


def main() -> int:
    argv = [a for a in sys.argv[1:] if not a.startswith("--")]
    check = "--check" in sys.argv
    as_json = "--json" in sys.argv
    if len(argv) < 2:
        print("usage: merge-sessions.py <db> <uid> [--check] [--json]")
        return 2
    db, uid = argv[0], argv[1]

    try:
        con = sqlite3.connect(db, timeout=10)
    except sqlite3.Error as e:
        out = {"ok": False, "reason": "open-failed: {}".format(e)}
        print(json.dumps(out, ensure_ascii=False) if as_json else out["reason"])
        return 1

    try:
        before = stats(con)
        if check:
            moved = sum(v for k, v in before.items() if k != uid)
            total = before.get(uid, 0) + moved
        else:
            cur = con.execute(
                "UPDATE sessions SET user_id = ? "
                "WHERE user_id IS NULL OR user_id <> ?",
                (uid, uid),
            )
            moved = cur.rowcount
            con.commit()
            total = con.execute(
                "SELECT count(*) FROM sessions WHERE user_id = ?", (uid,)
            ).fetchone()[0]
        out = {
            "ok": True,
            "check": check,
            "uid": uid,
            "moved": moved,
            "total": total,
            "before": before,
        }
        if as_json:
            print(json.dumps(out, ensure_ascii=False))
        else:
            print("moved={} total_for_target={} before={}".format(moved, total, before))
        return 0
    except sqlite3.Error as e:
        out = {"ok": False, "reason": "sql-failed: {}".format(e)}
        print(json.dumps(out, ensure_ascii=False) if as_json else out["reason"])
        return 1
    finally:
        con.close()


if __name__ == "__main__":
    sys.exit(main())
'@

if ($ShareConversations) {
    $SwapDirs  = @($SwapDirs  | Where-Object { $ConvDirs  -notcontains $_ })
    $SwapFiles = @($SwapFiles | Where-Object { $ConvFiles -notcontains $_ })
}


# ⛔ 以下内容刻意不换: device-id / keyblob / settings.json / mcp.json /
#    plugins / skills / 各类缓存日志 —— 它们是机器级或共享配置, 换了会出问题

# ============================================================
#  基础函数
# ============================================================
function Write-Log([string]$Msg) {
    if (-not (Test-Path $ProfRoot)) { New-Item -ItemType Directory -Path $ProfRoot -Force | Out-Null }
    $line = "[{0}] {1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $Msg
    Add-Content -Path $LogFile -Value $line -Encoding UTF8
}

function Get-LiveAccount {
    $f = Join-Path $WbRoot "storage\skeleton\account-snapshot.json"
    if (-not (Test-Path $f)) { return $null }
    try {
        $j = Get-Content $f -Raw -Encoding UTF8 | ConvertFrom-Json
        $ms = 0
        try { $ms = [long]$j.primary.savedAt } catch {}
        return @{ Uid = $j.primary.uid; Nick = $j.primary.nickname; Type = $j.primary.type; SavedAtMs = $ms }
    } catch { return $null }
}

function Get-ShortUid([string]$Uid) {
    if (-not $Uid) { return "?" }
    return $Uid.Substring(0, [Math]::Min(8, $Uid.Length))
}

function Get-CurrentProfile {
    if (Test-Path $CurrentFile) {
        try { return (Get-Content $CurrentFile -Raw -Encoding UTF8 | ConvertFrom-Json).profile }
        catch { return $null }
    }
    return $null
}

function Set-CurrentProfile([string]$ProfName) {
    if (-not (Test-Path $ProfRoot)) { New-Item -ItemType Directory -Path $ProfRoot -Force | Out-Null }
    @{ profile = $ProfName; switchedAt = (Get-Date -Format "yyyy-MM-dd HH:mm:ss") } |
        ConvertTo-Json | Set-Content $CurrentFile -Encoding UTF8
}

function Read-ProfileMeta([string]$ProfName) {
    $meta = Join-Path $ProfRoot "$ProfName\profile.json"
    if (Test-Path $meta) {
        try { return Get-Content $meta -Raw -Encoding UTF8 | ConvertFrom-Json } catch { return $null }
    }
    return $null
}

function Write-ProfileMeta([string]$ProfName, [string]$Uid, [string]$Nick, [string]$Type, [bool]$New) {
    $pdir = Join-Path $ProfRoot $ProfName
    if (-not (Test-Path $pdir)) { New-Item -ItemType Directory -Path $pdir -Force | Out-Null }
    $old = Read-ProfileMeta $ProfName
    $meta = @{
        name        = $ProfName
        uid         = $Uid
        nickname    = $Nick
        accountType = $Type
        createdAt   = if ($New) { Get-Date -Format "yyyy-MM-dd HH:mm:ss" } elseif ($old) { $old.createdAt } else { Get-Date -Format "yyyy-MM-dd HH:mm:ss" }
        lastSavedAt = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
        listVersion = $SwapListVersion
    }
    $meta | ConvertTo-Json | Set-Content (Join-Path $pdir "profile.json") -Encoding UTF8
}

function Get-Profiles {
    if (-not (Test-Path $ProfRoot)) { return @() }
    $out = @()
    Get-ChildItem $ProfRoot -Directory | Where-Object { $_.Name -ne "backup" } | ForEach-Object {
        $info = Read-ProfileMeta $_.Name
        $out += [PSCustomObject]@{
            Name  = $_.Name
            Nick  = if ($info) { $info.nickname } else { "" }
            Uid   = if ($info) { $info.uid } else { "" }
            Saved = if ($info) { $info.lastSavedAt } else { "" }
        }
    }
    return $out
}

function Copy-DirMirror([string]$Src, [string]$Dst) {
    if (-not (Test-Path $Src)) { return }
    $parent = Split-Path $Dst -Parent
    if (-not (Test-Path $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
    robocopy $Src $Dst /MIR /R:3 /W:2 /NFL /NDL /NJH /NJS /NP | Out-Null
    if ($LASTEXITCODE -ge 8) { throw "robocopy failed: $Src -> $Dst (code $LASTEXITCODE)" }
}

function Copy-FileMirror([string]$Src, [string]$Dst) {
    $parent = Split-Path $Dst -Parent
    if (Test-Path $Src) {
        if (-not (Test-Path $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
        Copy-Item $Src $Dst -Force
    } elseif (Test-Path $Dst) {
        Remove-Item $Dst -Force
    }
}

function Save-SwapSet([string]$DestLive) {
    foreach ($rel in $SwapDirs)  { Copy-DirMirror  (Join-Path $WbRoot $rel) (Join-Path $DestLive $rel) }
    foreach ($rel in $SwapFiles) { Copy-FileMirror (Join-Path $WbRoot $rel) (Join-Path $DestLive $rel) }
    foreach ($e in $SwapExtDirs) { Copy-DirMirror  $e.Live (Join-Path $DestLive $e.Store) }
    # 会话互通模式下, 档案不再需要会话副本(切换根本不搬会话) -> 清掉历史遗留, 防止每保存一次多囤约 10MB
    # 注: Backup-Live 在本函数之后会单独再复制会话库索引(workbuddy.db*), 所以备份不受影响
    if ($ShareConversations) {
        foreach ($d in $ConvDirs)  { $p = Join-Path $DestLive $d; if (Test-Path $p) { Remove-Item $p -Recurse -Force -ErrorAction SilentlyContinue } }
        foreach ($f in $ConvFiles) { $p = Join-Path $DestLive $f; if (Test-Path $p) { Remove-Item $p -Force -ErrorAction SilentlyContinue } }
    }
}

function Restore-SwapSet([string]$SrcLive) {
    foreach ($rel in $SwapDirs)  { Copy-DirMirror  (Join-Path $SrcLive $rel) (Join-Path $WbRoot $rel) }
    foreach ($rel in $SwapFiles) { Copy-FileMirror (Join-Path $SrcLive $rel) (Join-Path $WbRoot $rel) }
    foreach ($e in $SwapExtDirs) { Copy-DirMirror  (Join-Path $SrcLive $e.Store) $e.Live }
}

function Start-WorkBuddy {
    # 统一启动入口: 主程序路径探测不到时给明确指引, 而不是抛一句看不懂的异常
    if (-not $WbExe) {
        Write-Host "[X] 找不到 WorkBuddy 主程序, 请手动启动它。" -ForegroundColor Red
        Write-Host "    若装在特殊位置, 把完整路径填进 switcher-core.ps1 顶部的 `$WbExeOverride" -ForegroundColor Yellow
        Write-Log "START FAIL: WorkBuddy exe not found"
        return $false
    }
    try { Start-Process $WbExe; return $true }
    catch { Write-Log "START FAIL: $_"; return $false }
}

function Stop-WorkBuddy {
    Get-Process -Name "WorkBuddy" -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 3
    return (-not (Get-Process -Name "WorkBuddy" -ErrorAction SilentlyContinue))
}

function Close-AppAuto {
    # 非交互模式: 先温柔关, 超时强杀, 不问人
    $procs = Get-Process -Name "WorkBuddy" -ErrorAction SilentlyContinue
    if (-not $procs) { return $true }
    $procs | ForEach-Object { try { $_.CloseMainWindow() | Out-Null } catch {} }
    for ($i = 0; $i -lt 30; $i++) {
        Start-Sleep -Milliseconds 500
        if (-not (Get-Process -Name "WorkBuddy" -ErrorAction SilentlyContinue)) { return $true }
    }
    return (Stop-WorkBuddy)
}

function Ensure-AppClosed {
    # 交互模式用: 询问后关闭
    $procs = Get-Process -Name "WorkBuddy" -ErrorAction SilentlyContinue
    if (-not $procs) { return $true }
    Write-Host ""
    Write-Host "  [!] WorkBuddy 正在运行, 需要先关闭它 (正在进行的 AI 对话会被中断)。" -ForegroundColor Yellow
    $a = Read-Host "  现在关闭? (Y=正常关闭 / F=强制结束 / C=取消)"
    if ($a -eq "C" -or $a -eq "c") { return $false }
    if ($a -eq "F" -or $a -eq "f") { return (Stop-WorkBuddy) }
    $procs | ForEach-Object { try { $_.CloseMainWindow() | Out-Null } catch {} }
    for ($i = 0; $i -lt 20; $i++) {
        Start-Sleep -Milliseconds 500
        if (-not (Get-Process -Name "WorkBuddy" -ErrorAction SilentlyContinue)) { return $true }
    }
    Write-Host "  [!] 程序似乎还在后台(托盘)。需要强制结束吗?" -ForegroundColor Yellow
    $b = Read-Host "  强制结束? (Y/n)"
    if ($b -eq "n" -or $b -eq "N") { return $false }
    return (Stop-WorkBuddy)
}

function Backup-Live {
    if (-not (Test-Path $BackupRoot)) { New-Item -ItemType Directory -Path $BackupRoot -Force | Out-Null }
    $tag = Get-Date -Format "yyyyMMdd-HHmmss"
    $dst = Join-Path $BackupRoot $tag
    Write-Log "backup live -> backup\$tag"
    Save-SwapSet $dst
    # 会话共享模式下会话库不在切换清单里, 但它会被改写归属 → 单独备份索引
    if ($ShareConversations) {
        foreach ($rel in $ConvFiles) { Copy-FileMirror (Join-Path $WbRoot $rel) (Join-Path $dst $rel) }
    }
    Get-ChildItem $BackupRoot -Directory | Sort-Object Name -Descending |
        Select-Object -Skip 3 | ForEach-Object { Remove-Item $_.FullName -Recurse -Force }
}

# ============================================================
#  会话互通: 把会话库里的归属统一到目标账号
#  必须在 WorkBuddy 关闭状态下执行(数据库被占用时写不进去)
# ============================================================
function Find-PythonExe {
    # 探测顺序刻意如此: 优先"跟着 WorkBuddy 走的运行时", 换电脑不用另装 Python
    # 1) WorkBuddy 自带 Python (推荐, 与软件同生同死)
    $binRoot = Join-Path $WbRoot "binaries\python\versions"
    if (Test-Path $binRoot) {
        $hit = Get-ChildItem $binRoot -Directory -ErrorAction SilentlyContinue |
               Sort-Object Name -Descending |
               ForEach-Object { Join-Path $_.FullName "python.exe" } |
               Where-Object { Test-Path $_ } | Select-Object -First 1
        if ($hit) { return $hit }
    }
    # 2) PATH 里的 python (排除微软商店占位符, 那个会弹应用商店)
    foreach ($nm in @("python.exe", "python3.exe")) {
        $cmd = Get-Command $nm -ErrorAction SilentlyContinue
        if ($cmd -and $cmd.Source -and ($cmd.Source -notlike "*WindowsApps*")) { return $cmd.Source }
    }
    # 3) 常见安装目录, 取版本号最大的
    foreach ($pat in @("$env:LOCALAPPDATA\Programs\Python\Python*", "$env:ProgramFiles\Python*", "C:\Python*")) {
        $hit = Get-ChildItem $pat -Directory -ErrorAction SilentlyContinue |
               Sort-Object Name -Descending |
               ForEach-Object { Join-Path $_.FullName "python.exe" } |
               Where-Object { Test-Path $_ } | Select-Object -First 1
        if ($hit) { return $hit }
    }
    return $null
}

function Test-AppRunning {
    # 会话库由 App 独占打开 → 改写归属前必须让程序先退出, 否则写入会被回滚/锁住
    return [bool](Get-Process -Name "WorkBuddy" -ErrorAction SilentlyContinue)
}

function Merge-SessionOwners([string]$Uid, [switch]$Check) {
    # 返回值: Ok / Reason / Moved(本次改归的会话数) / Total(目标账号名下会话数) / Before(改前分布)
    $res = @{ Ok = $true; Reason = ""; Moved = 0; Total = 0; Before = @{} }
    if (-not $ShareConversations) { $res.Reason = "disabled"; return $res }
    if (-not $Uid) { Write-Log "merge-sessions SKIP: no target uid"; $res.Ok = $false; $res.Reason = "no-uid"; return $res }
    $db = Join-Path $WbRoot "workbuddy.db"
    if (-not (Test-Path $db)) { Write-Log "merge-sessions SKIP: db missing"; $res.Ok = $false; $res.Reason = "db-missing"; return $res }
    $py = Join-Path $PSScriptRoot "merge-sessions.py"
    $tmpPy = $null
    if (-not (Test-Path $py)) {
        # 外部文件丢了也不影响: 用内嵌源码现场生成临时脚本
        $tmpPy = Join-Path $env:TEMP ("wb-merge-" + [guid]::NewGuid().ToString("N") + ".py")
        try {
            [IO.File]::WriteAllText($tmpPy, $MergeSessionPySrc, [Text.UTF8Encoding]::new($false))
            $py = $tmpPy
            Write-Log "merge-sessions: using embedded helper (side-car file missing)"
        } catch {
            Write-Log "merge-sessions FAIL: cannot materialize embedded helper: $_"
            $res.Ok = $false; $res.Reason = "helper-missing"
            return $res
        }
    }
    $exe = Find-PythonExe
    if (-not $exe) {
        if ($tmpPy -and (Test-Path $tmpPy)) { Remove-Item $tmpPy -Force -ErrorAction SilentlyContinue }
        Write-Log "merge-sessions FAIL: 本机找不到可用 Python(WorkBuddy 自带与 PATH 均无)"
        $res.Ok = $false; $res.Reason = "no-python"
        return $res
    }
    $pyArgs = @($py, $db, $Uid, "--json")
    if ($Check) { $pyArgs += "--check" }
    try {
        $out = & $exe @pyArgs 2>&1
        $code = $LASTEXITCODE
        $jline = @($out | ForEach-Object { "$_" } | Where-Object { $_.Trim().StartsWith("{") }) | Select-Object -Last 1
        Write-Log ("merge-sessions [" + (Get-ShortUid $Uid) + "] check=" + [bool]$Check + " via $exe (exit=$code): $jline")
        if ($code -ne 0) {
            Write-Log "merge-sessions FAIL [$Uid]: non-zero exit $code"
            $res.Ok = $false; $res.Reason = "exit-$code"
            return $res
        }
        if ($jline) {
            try {
                $j = $jline | ConvertFrom-Json
                $res.Moved = [int]$j.moved
                $res.Total = [int]$j.total
                if ($j.before) {
                    $b = @{}
                    foreach ($pp in $j.before.PSObject.Properties) { $b[$pp.Name] = [int]$pp.Value }
                    $res.Before = $b
                }
            } catch { Write-Log "merge-sessions WARN: cannot parse helper output" }
        }
    } catch {
        Write-Log "merge-sessions FAIL [$Uid]: $_"
        $res.Ok = $false; $res.Reason = "exec-error"
        return $res
    } finally {
        if ($tmpPy -and (Test-Path $tmpPy)) { Remove-Item $tmpPy -Force -ErrorAction SilentlyContinue }
    }
    if ($Check) { $res.Reason = "checked"; return $res }
    # 目标账号目录里有份"侧边栏会话快照"缓存, 只列该账号自己的会话。
    # 清掉它, 界面启动时才会按数据库重建完整列表(原文件改名 .bak 保留)
    Clear-SidebarSnapshot $Uid
    $res.Reason = "merged"
    return $res
}

function Clear-SidebarSnapshot([string]$Uid) {
    # 每个账号一份侧边栏缓存(items 为数组)。不清它, 即使库里归属已改好, 界面仍显示旧列表
    if (-not $Uid) { return }
    $snapFile = Join-Path (Join-Path $WbRoot $Uid) "sidebar-list-snapshot.json"
    if (-not (Test-Path $snapFile)) { return }
    try {
        Copy-Item $snapFile "$snapFile.bak" -Force
        Remove-Item $snapFile -Force
        Write-Log "sidebar-snapshot cleared for $(Get-ShortUid $Uid) (rebuilt from db on next launch)"
    } catch { Write-Log "sidebar-snapshot clear FAIL: $_" }
}

function Clean-Name([string]$N) {
    $n = ($N -replace '[\\/:*?"<>|]', "").Trim()
    if ($n -eq "" -or $n -eq "backup") { return $null }
    return $n
}

# ============================================================
#  账号扫描: 汇合 当前登录 + 已建档 + 历史登录痕迹
# ============================================================
function Get-KnownAccounts {
    $map = @{}
    $uuid = '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}'
    # 1) 已建档
    foreach ($p in Get-Profiles) {
        if ($p.Uid -match "^$uuid`$") {
            if (-not $map.ContainsKey($p.Uid)) { $map[$p.Uid] = @{ Uid = $p.Uid; Nick = ""; ProfileName = ""; IsLive = $false; HasProfile = $false; LastSeen = $null } }
            $map[$p.Uid].ProfileName = $p.Name
            $map[$p.Uid].HasProfile  = $true
            if (-not $map[$p.Uid].Nick) { $map[$p.Uid].Nick = $p.Nick }
        } else {
            # 档案没有 uid 记录(异常档案), 也列出
            $key = "profile:" + $p.Name
            if (-not $map.ContainsKey($key)) {
                $map[$key] = @{ Uid = ""; Nick = $p.Nick; ProfileName = $p.Name; IsLive = $false; HasProfile = $true; LastSeen = $null }
            }
        }
    }
    # 2) 历史登录痕迹 (storage/user-* 目录)
    Get-ChildItem (Join-Path $WbRoot "storage") -Directory -Filter "user-*" -ErrorAction SilentlyContinue | ForEach-Object {
        if ($_.Name -match "^user-($uuid)(-personal)?$") {
            $u = $Matches[1]
            if (-not $map.ContainsKey($u)) { $map[$u] = @{ Uid = $u; Nick = ""; ProfileName = ""; IsLive = $false; HasProfile = $false; LastSeen = $null } }
        }
    }
    # 3) 根目录下的账号 UUID 目录
    Get-ChildItem $WbRoot -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -match "^$uuid`$" } | ForEach-Object {
        if (-not $map.ContainsKey($_.Name)) { $map[$_.Name] = @{ Uid = $_.Name; Nick = ""; ProfileName = ""; IsLive = $false; HasProfile = $false; LastSeen = $null } }
    }
    # 4) 记住的账号注册表 (local_storage 里形如 uid|personal|... 的键, 取最后登录时间)
    Get-ChildItem (Join-Path $WbRoot "local_storage") -Filter "*.info" -ErrorAction SilentlyContinue | ForEach-Object {
        try {
            $j = Get-Content $_.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($j -is [System.Array]) {
                foreach ($item in $j) {
                    if ($item.key -and ($item.key -match "^($uuid)\|") -and $item.savedAt) {
                        $u = $Matches[1]
                        if (-not $map.ContainsKey($u)) { $map[$u] = @{ Uid = $u; Nick = ""; ProfileName = ""; IsLive = $false; HasProfile = $false; LastSeen = $null } }
                        $t = [DateTimeOffset]::FromUnixTimeMilliseconds([long]$item.savedAt).LocalDateTime
                        if (-not $map[$u].LastSeen -or $t -gt $map[$u].LastSeen) { $map[$u].LastSeen = $t }
                    }
                }
            }
        } catch {}
    }
    # 5) 当前登录信息最后合并 (昵称以实时为准)
    $acc = Get-LiveAccount
    if ($acc) {
        if (-not $map.ContainsKey($acc.Uid)) { $map[$acc.Uid] = @{ Uid = $acc.Uid; Nick = ""; ProfileName = ""; IsLive = $false; HasProfile = $false; LastSeen = $null } }
        $map[$acc.Uid].IsLive = $true
        $map[$acc.Uid].Nick   = $acc.Nick
    }
    # 排序: 当前登录 > 已建档 > 其他, 组内按最近登录时间倒序
    return @($map.Values | Sort-Object -Property @{Expression={ if ($_.IsLive) { 0 } elseif ($_.HasProfile) { 1 } else { 2 } }}, @{Expression="LastSeen";Descending=$true})
}

# ============================================================
#  非交互核心操作
# ============================================================
function Invoke-AutoSave([string]$ProfName) {
    $acc = Get-LiveAccount
    if (-not $acc) { Write-Log "SAVE FAIL [$ProfName]: no live account"; Write-Host "[X] 读取不到当前登录账号"; return $false }
    # 防呆: 档案名里写了手机号, 但与当前登录账号的手机号对不上 => 拒绝
    $pm = [regex]::Match($ProfName, '\d{11}')
    if ($pm.Success -and $acc.Nick) {
        $mm = [regex]::Match($acc.Nick, '^(\d{3})\*+(\d{4})$')
        if ($mm.Success) {
            $phone = $pm.Value
            $pre = $mm.Groups[1].Value; $suf = $mm.Groups[2].Value
            if (($phone.Substring(0,3) -ne $pre) -or ($phone.Substring(7,4) -ne $suf)) {
                Write-Log "SAVE REFUSED [$ProfName]: 名字里的手机号 $phone 与当前登录账号 $($acc.Nick) 不符"
                Write-Host "[X] 档案名里有手机号 $phone, 但你现在登录的是 $($acc.Nick)。" -ForegroundColor Red
                Write-Host "    这样保存会把 [$ProfName] 记到错误的账号名下(正是上次切换'没反应'的原因)。" -ForegroundColor Yellow
                Write-Host "    要么换个名字, 要么先切换到 $phone 那个账号再保存。" -ForegroundColor Yellow
                return $false
            }
        }
    }
    $old = Read-ProfileMeta $ProfName
    if ($old -and $old.uid -and ($old.uid -ne $acc.Uid)) {
        Write-Log "SAVE FAIL [$ProfName]: name already used by uid $($old.uid)"
        Write-Host "[X] 档案名 [$ProfName] 已属于另一个账号($($old.nickname)), 换个名字。"
        return $false
    }
    if (-not (Close-AppAuto)) { Write-Log "SAVE FAIL [$ProfName]: cannot close app"; Write-Host "[X] 无法关闭 WorkBuddy"; return $false }
    Write-Host ">> 正在保存登录态 ..."
    try { Save-SwapSet (Join-Path $ProfRoot "$ProfName\live") }
    catch { Write-Log "SAVE FAIL [$ProfName]: $_"; Write-Host "[X] 保存失败: $_"; return $false }
    Write-ProfileMeta $ProfName $acc.Uid $acc.Nick $acc.Type (-not $old)
    Set-CurrentProfile $ProfName
    Write-Log "SAVE OK [$ProfName] account=$($acc.Nick)"
    Write-Host "[OK] 已保存档案 [$ProfName]  账号: $($acc.Nick)" -ForegroundColor Green
    # 建档即互通(v3.5): 新账号登录后, 库里会话归属仍是上一个账号, 界面按自己 uid 过滤 → 一片空白。
    # 这里趁程序还关着, 立刻把归属统一到本账号并清掉侧边栏缓存 —— 一步到位, 不必再切一次才通。
    Sync-SessionAfterProfileChange -Uid $acc.Uid -Stage "SAVE"
    Start-WorkBuddy | Out-Null
    return $true
}

function Sync-SessionAfterProfileChange([string]$Uid, [string]$Stage) {
    # 保存档案 / 切换账号 之后的统一收尾: 归属归一 + 侧边栏缓存清理 + 人话反馈
    if (-not $ShareConversations) { return }
    if (Test-AppRunning) {
        Write-Host "[!] WorkBuddy 仍在运行, 跳过会话同步(库被占用)。请关闭程序后运行 -Action sync。" -ForegroundColor Yellow
        Write-Log "$Stage WARN: app still running, session sync skipped"
        return
    }
    Write-Host ">> 正在把会话历史并入该账号(互通) ..." -ForegroundColor DarkGray
    $mr = Merge-SessionOwners $Uid
    if ($mr.Ok) {
        if ($mr.Moved -gt 0) {
            Write-Host ("     会话互通完成: 本次并入 {0} 条, 该账号名下共 {1} 条。" -f $mr.Moved, $mr.Total) -ForegroundColor DarkGray
        } else {
            Write-Host ("     会话归属已一致: 该账号名下 {0} 条, 无需改动。" -f $mr.Total) -ForegroundColor DarkGray
        }
    } else {
        Write-Host ("     [!] 会话互通未执行 ({0})" -f $mr.Reason) -ForegroundColor Yellow
        Write-Host "         登录不受影响; 但历史会话可能只显示该账号自己的。" -ForegroundColor Yellow
        Write-Log "$Stage WARN: conversation merge skipped ($($mr.Reason))"
    }
}

function Invoke-AutoSwitch([string]$ProfName) {
    # 防并发锁: 同一时刻只许一个切换进程 (双击两次/菜单+GUI 同跑会互相覆盖)
    $mtx = New-Object System.Threading.Mutex($false, "WBSwitcherSwitchLock")
    if (-not $mtx.WaitOne(0)) {
        Write-Log "SWITCH FAIL: another switch is already running"
        Write-Host "[X] 已有另一个切换正在执行, 请等它结束后再试。" -ForegroundColor Red
        return $false
    }
    if (-not (Test-Path (Join-Path $ProfRoot "$ProfName\live"))) {
        Write-Log "SWITCH FAIL: profile missing [$ProfName]"
        Write-Host "[X] 档案 [$ProfName] 不存在或已损坏。" -ForegroundColor Red
        $mtx.ReleaseMutex() | Out-Null; $mtx.Dispose()
        return $false
    }
    # 档案版本守卫: 旧清单存的档案缺关键凭证文件, 还原必然弹回旧账号 → 拒绝执行
    $metaChk = Read-ProfileMeta $ProfName
    $metaVer = if ($metaChk -and $metaChk.PSObject.Properties["listVersion"]) { [int]$metaChk.listVersion } else { 0 }
    if ($metaVer -lt $SwapListVersion) {
        Write-Log "SWITCH REFUSED [$ProfName]: profile listVersion=$metaVer < $SwapListVersion (需重新保存)"
        Write-Host "[X] 档案 [$ProfName] 是旧版本清单存的, 缺关键登录凭证, 切了也会被弹回。" -ForegroundColor Red
        Write-Host "    修复方法: 登录该账号一次, 在窗口里点【保存当前登录】, 名字沿用 [$ProfName]。" -ForegroundColor Yellow
        $mtx.ReleaseMutex() | Out-Null; $mtx.Dispose()
        return $false
    }
    if (-not (Close-AppAuto)) { Write-Log "SWITCH FAIL: cannot close app"; Write-Host "[X] 无法关闭 WorkBuddy"; $mtx.ReleaseMutex() | Out-Null; $mtx.Dispose(); return $false }

    # 切换前: 把当前登录态自动存回它自己的档案
    $cur = Get-CurrentProfile
    $acc = Get-LiveAccount
    if ($cur -and ($cur -ne $ProfName)) {
        $curMeta = Read-ProfileMeta $cur
        if ($curMeta -and $acc -and $curMeta.uid -and ($curMeta.uid -eq $acc.Uid)) {
            Write-Host ">> 自动保存当前登录态到档案 [$cur] ..."
            try { Save-SwapSet (Join-Path $ProfRoot "$cur\live") } catch { Write-Log "WARN: auto-save [$cur] failed: $_" }
            Write-ProfileMeta $cur $acc.Uid $acc.Nick $acc.Type $false
            Write-Log "auto-saved [$cur] before switch"
        } else {
            Write-Log "WARN: uid mismatch or unknown, skipped auto-save of [$cur]"
            Write-Host "[!] 当前登录账号与档案 [$cur] 记录不一致, 跳过自动保存" -ForegroundColor Yellow
        }
    }

    Backup-Live
    Write-Host ">> 正在切换到档案 [$ProfName] ..."
    try {
        Restore-SwapSet (Join-Path $ProfRoot "$ProfName\live")
    } catch {
        Write-Log "SWITCH FAIL [$ProfName]: $_"
        Write-Host "[X] 切换失败: $_ (原状态已备份在 backup\)" -ForegroundColor Red
        $mtx.ReleaseMutex() | Out-Null; $mtx.Dispose()
        return $false
    }
    Set-CurrentProfile $ProfName
    $meta = Read-ProfileMeta $ProfName
    $nick = if ($meta) { $meta.nickname } else { "?" }
    $expectUid = if ($meta) { $meta.uid } else { "" }
    # 写"待验证"记录: WorkBuddy 启动后由 verify 动作核对真实登录账号
    try {
        @{ profile = $ProfName; nick = $nick; expectUid = $expectUid; atMs = [DateTimeOffset]::Now.ToUnixTimeMilliseconds() } |
            ConvertTo-Json | Set-Content (Join-Path $ProfRoot "expect.json") -Encoding UTF8
    } catch {}
    Write-Log "SWITCH DONE -> [$ProfName] ($nick) uid=$(Get-ShortUid $expectUid) [待验证]"
    Write-Host "[OK] 文件已切换, 正在启动 WorkBuddy ..." -ForegroundColor Green
    Sync-SessionAfterProfileChange -Uid $expectUid -Stage "SWITCH"
    Write-Host "     启动约 10 秒后会自动核对登录账号, 结果写入日志。" -ForegroundColor DarkGray
    Start-WorkBuddy | Out-Null
    $mtx.ReleaseMutex() | Out-Null; $mtx.Dispose()
    return $true
}

# ============================================================
#  会话归属修复 (v3.5): 把库里所有会话统一归到"当前登录账号"
#  用途: 手动在 App 里换过账号(没走插件) / 新账号建档后仍看不到历史
# ============================================================
function Invoke-AutoSync([switch]$CheckOnly) {
    $acc = Get-LiveAccount
    if (-not $acc) {
        Write-Log "SYNC FAIL: no live account"
        Write-Host "[X] 读取不到当前登录账号(可能未登录)" -ForegroundColor Red
        return $false
    }
    if ($CheckOnly) {
        $r = Merge-SessionOwners $acc.Uid -Check
        if (-not $r.Ok) { Write-Host "[X] 检查失败: $($r.Reason)" -ForegroundColor Red; return $false }
        Write-Host ("  当前登录 : {0} (uid={1})" -f $acc.Nick, (Get-ShortUid $acc.Uid))
        if ($r.Moved -gt 0) {
            Write-Host ("  [!] 归属不一致: 有 {0} 条会话属于别的账号, 本账号看不到" -f $r.Moved) -ForegroundColor Yellow
            Write-Host ("      修复: -Action sync (会关闭并重启 WorkBuddy)" ) -ForegroundColor DarkGray
        } else {
            Write-Host ("  [OK] 归属一致: 本账号名下 {0} 条会话" -f $r.Total) -ForegroundColor Green
        }
        return $true
    }
    $mtx = New-Object System.Threading.Mutex($false, "WBSwitcherSwitchLock")
    if (-not $mtx.WaitOne(0)) {
        Write-Log "SYNC FAIL: another switch is already running"
        Write-Host "[X] 已有另一个切换正在执行, 请等它结束后再试。" -ForegroundColor Red
        return $false
    }
    try {
        if (-not (Close-AppAuto)) {
            Write-Log "SYNC FAIL: cannot close app"
            Write-Host "[X] 无法关闭 WorkBuddy" -ForegroundColor Red
            return $false
        }
        Write-Host ">> 正在同步会话归属到 [$($acc.Nick)] ..."
        $mr = Merge-SessionOwners $acc.Uid
        if (-not $mr.Ok) {
            Write-Log "SYNC FAIL: merge reason=$($mr.Reason)"
            Write-Host "[X] 同步失败: $($mr.Reason)" -ForegroundColor Red
            Start-WorkBuddy | Out-Null
            return $false
        }
        Write-Host ("[OK] 同步完成: 并入 {0} 条, 名下共 {1} 条" -f $mr.Moved, $mr.Total) -ForegroundColor Green
        Write-Log "SYNC OK uid=$(Get-ShortUid $acc.Uid) moved=$($mr.Moved) total=$($mr.Total)"
        Start-WorkBuddy | Out-Null
        return $true
    } finally {
        $mtx.ReleaseMutex() | Out-Null; $mtx.Dispose()
    }
}

# ============================================================
#  切换结果核验: 对比"切换前记录的目标账号"与"启动后的真实登录账号"
# ============================================================
function Invoke-Verify {
    $ef = Join-Path $ProfRoot "expect.json"
    if (-not (Test-Path $ef)) { Write-Host "  没有待核验的切换记录。"; return $null }
    $e = $null
    try { $e = Get-Content $ef -Raw -Encoding UTF8 | ConvertFrom-Json } catch {}
    if (-not $e) { Remove-Item $ef -Force -ErrorAction SilentlyContinue; Write-Host "  核验记录损坏, 已清除。"; return $null }
    $acc = Get-LiveAccount
    if (-not $acc) { Write-Host "  读不到当前登录状态(程序可能未启动或未登录), 稍后再试。" -ForegroundColor Yellow; return $null }
    $refreshed = ($acc.SavedAtMs -ge ([long]$e.atMs - 5000))
    if (-not $refreshed) {
        Write-Host "  WorkBuddy 还没刷新登录状态(可能仍在启动), 稍后再核验一次。" -ForegroundColor Yellow
        return $null
    }
    $ok = ($e.expectUid -and ($acc.Uid -eq $e.expectUid))
    if ($ok) {
        Write-Log "VERIFY OK [$($e.profile)] 实际登录=$($acc.Nick) uid=$(Get-ShortUid $acc.Uid)"
        Write-Host "  [OK] 切换成功核验通过: 实际登录账号 = $($acc.Nick)" -ForegroundColor Green
    } else {
        Write-Log "VERIFY MISMATCH [$($e.profile)] 期望=$(Get-ShortUid $e.expectUid) 实际=$(Get-ShortUid $acc.Uid) ($($acc.Nick))"
        Write-Host "  [X] 切换未生效: 期望 uid=$(Get-ShortUid $e.expectUid), 实际 uid=$(Get-ShortUid $acc.Uid) ($($acc.Nick))" -ForegroundColor Red
    }
    Remove-Item $ef -Force -ErrorAction SilentlyContinue
    return $ok
}

function Invoke-RunJob {
    if (-not (Test-Path $JobFile)) { Write-Host "没有待执行任务。"; return $false }
    $job = $null
    try { $job = Get-Content $JobFile -Raw -Encoding UTF8 | ConvertFrom-Json } catch {}
    if (-not $job -or -not $job.action -or -not $job.name) {
        Write-Host "任务文件无效, 已忽略。" -ForegroundColor Yellow
        Remove-Item $JobFile -Force -ErrorAction SilentlyContinue
        return $false
    }
    try {
        $age = (Get-Date) - [datetime]$job.createdAt
        if ($age.TotalMinutes -gt 30) {
            Write-Host "任务已过期(超过30分钟), 已忽略。" -ForegroundColor Yellow
            Remove-Item $JobFile -Force
            return $false
        }
    } catch {}
    Remove-Item $JobFile -Force -ErrorAction SilentlyContinue
    if ($job.delaySeconds -gt 0) { Start-Sleep -Seconds $job.delaySeconds }
    Write-Log "runjob: action=$($job.action) name=$($job.name)"
    switch ($job.action) {
        "switch"   { return (Invoke-AutoSwitch $job.name) }
        "save"     { return (Invoke-AutoSave $job.name) }
        "selftest" { Invoke-SelfTest; return $true }
        default    { Write-Host "未知任务类型: $($job.action)" -ForegroundColor Red; return $false }
    }
}

function Invoke-SelfTest {
    Write-Host "  === 自检 ==="
    Write-Host ("  WorkBuddy 数据目录 : " + $(if (Test-Path $WbRoot) { "OK" } else { "缺失!" }))
    Write-Host ("  WorkBuddy 主程序   : " + $(if ($WbExe -and (Test-Path $WbExe)) { "OK" } else { "缺失! 请检查安装位置或填 `$WbExeOverride" }))
    $ok = 0; $miss = 0
    foreach ($rel in ($SwapDirs + $SwapFiles)) {
        if (Test-Path (Join-Path $WbRoot $rel)) { $ok++ } else { Write-Host "  (提示) 切换项不存在(可能正常): $rel" -ForegroundColor DarkGray; $miss++ }
    }
    Write-Host "  切换清单: $ok 项存在, $miss 项缺失"
    foreach ($e in $SwapExtDirs) {
        Write-Host ("  外部登录会话: " + $e.Live + "  " + $(if (Test-Path $e.Live) { "OK" } else { "缺失!" }))
    }
    Write-Host ("  清单版本           : v" + $SwapListVersion)
    if ($ShareConversations) {
        $helper = Join-Path $PSScriptRoot "merge-sessions.py"
        $pyexe  = Find-PythonExe
        Write-Host "  会话互通           : 开启(各账号共享会话历史)"
        Write-Host ("    互通组件         : " + $(if (Test-Path $helper) { "OK (merge-sessions.py)" } else { "缺失! 会话互通将不可用" }))
        Write-Host ("    运行时           : " + $(if ($pyexe) { "OK ($pyexe)" } else { "缺失! 找不到 Python, 会话互通将不可用" }))
        $acc0 = Get-LiveAccount
        if ($acc0 -and $pyexe) {
            $ck = Merge-SessionOwners $acc0.Uid -Check
            if ($ck.Ok) {
                if ($ck.Moved -gt 0) {
                    Write-Host ("    归属一致性       : [!] 有 {0} 条属于别的账号, 本账号看不到 → 用 -Action sync 修复" -f $ck.Moved) -ForegroundColor Yellow
                } else {
                    Write-Host ("    归属一致性       : OK (名下 {0} 条, 全部一致)" -f $ck.Total) -ForegroundColor Green
                }
            } else {
                Write-Host ("    归属一致性       : 无法检查 ($($ck.Reason))") -ForegroundColor Yellow
            }
        }
    } else {
        Write-Host "  会话互通           : 关闭(各账号独立)"
    }
    $acc = Get-LiveAccount
    Write-Host ("  当前登录账号       : " + $(if ($acc) { "$($acc.Nick) ($($acc.Type))" } else { "读取失败(程序可能未登录)" }))
    Write-Host "  === 自检结束 ==="
}

# ============================================================
#  体检: 档案与真实账号是否对得上 (只读, 不改任何东西)
# ============================================================
function Invoke-Doctor {
    Write-Host ""
    Write-Host "  ===== 档案体检 =====" -ForegroundColor Cyan
    $acc  = Get-LiveAccount
    $cur  = Get-CurrentProfile
    $curProfUid = ""
    if ($cur) { $m = Read-ProfileMeta $cur; if ($m) { $curProfUid = $m.uid } }
    Write-Host ("  实时登录账号 : " + $(if ($acc) { "$($acc.Nick)  uid=$(Get-ShortUid $acc.Uid)" } else { "读取失败" }))
    Write-Host ("  当前档案     : " + $(if ($cur) { $cur } else { "(无)" }))
    if ($acc -and $curProfUid -and ($acc.Uid -ne $curProfUid)) {
        Write-Host "  [!] 当前档案记录的账号与实时登录不一致 => 上次切换可能未生效" -ForegroundColor Yellow
    }
    # 会话归属(互通)体检: 归属与当前登录不一致 => 侧边栏就看不到老会话
    if ($ShareConversations -and $acc) {
        $ck = Merge-SessionOwners $acc.Uid -Check
        if ($ck.Ok) {
            if ($ck.Moved -gt 0) {
                Write-Host ("  会话归属     : [!] {0} 条属于别的账号 => 本账号看不到 (运行 -Action sync 修复)" -f $ck.Moved) -ForegroundColor Yellow
            } else {
                Write-Host ("  会话归属     : OK (名下 {0} 条, 归属一致)" -f $ck.Total)
            }
            if ($ck.Before.Count -gt 1) {
                $dist = (@($ck.Before.GetEnumerator()) | Sort-Object Value -Descending | ForEach-Object { "$(Get-ShortUid $_.Key)=$($_.Value)" }) -join "  "
                Write-Host ("    库内分布   : $dist") -ForegroundColor DarkGray
            }
        } else {
            Write-Host ("  会话归属     : 无法检查 ($($ck.Reason))") -ForegroundColor Yellow
        }
    }
    $ef = Join-Path $ProfRoot "expect.json"
    if (Test-Path $ef) {
        try {
            $e = Get-Content $ef -Raw -Encoding UTF8 | ConvertFrom-Json
            Write-Host ("  [!] 有一次切换尚未核验: 目标 [$($e.profile)] uid=$(Get-ShortUid $e.expectUid)") -ForegroundColor Yellow
            Write-Host "      运行 -Action verify 即可核验" -ForegroundColor DarkGray
        } catch {}
    }
    $list = Get-Profiles
    if ($list.Count -eq 0) { Write-Host "  (没有任何档案)"; return }
    $uidCount = @{}
    Write-Host ""
    foreach ($p in $list) {
        $plive = Join-Path $ProfRoot "$($p.Name)\live"
        $snapUid = ""
        $sf = Join-Path $plive "storage\skeleton\account-snapshot.json"
        if (Test-Path $sf) {
            try { $snapUid = (Get-Content $sf -Raw -Encoding UTF8 | ConvertFrom-Json).primary.uid } catch {}
        }
        $mb = 0
        if (Test-Path $plive) {
            $sum = (Get-ChildItem $plive -Recurse -File -ErrorAction SilentlyContinue | Measure-Object -Property Length -Sum).Sum
            if ($sum) { $mb = [math]::Round($sum / 1MB, 1) }
        }
        $flags = @()
        $pmeta = Read-ProfileMeta $p.Name
        $plv = if ($pmeta -and $pmeta.PSObject.Properties["listVersion"]) { [int]$pmeta.listVersion } else { 0 }
        if ($plv -lt $SwapListVersion) { $flags += "清单 v$plv 过旧, 需登录该账号重新保存" }
        if (-not $p.Uid) { $flags += "档案未记录账号" }
        if (-not (Test-Path $plive)) { $flags += "档案内容缺失" }
        if ($p.Uid -and $snapUid -and ($p.Uid -ne $snapUid)) { $flags += "记录uid与内容不符" }
        if ($p.Uid) { if ($uidCount.ContainsKey($p.Uid)) { $uidCount[$p.Uid]++ } else { $uidCount[$p.Uid] = 1 } }
        $mark = if ($cur -eq $p.Name) { "  <-当前" } else { "" }
        $flagTxt = if ($flags.Count -gt 0) { "  [问题] " + ($flags -join " / ") } else { "" }
        $color = if ($flags.Count -gt 0) { "Yellow" } else { "Gray" }
        Write-Host ("   - {0}  账号:{1}  uid={2}  {3}MB  存于{4}{5}{6}" -f $p.Name, $(if($p.Nick){$p.Nick}else{"?"}), (Get-ShortUid $p.Uid), $mb, $p.Saved, $mark, $flagTxt) -ForegroundColor $color
    }
    foreach ($k in $uidCount.Keys) {
        if ($uidCount[$k] -gt 1) {
            Write-Host ("  [!] 有 $($uidCount[$k]) 个档案指向同一个账号 uid=$(Get-ShortUid $k) —— 切它们不会有任何变化") -ForegroundColor Yellow
        }
    }
    Write-Host ""
    Write-Host "  档案目录: $ProfRoot" -ForegroundColor DarkGray
    Write-Host ""
}
