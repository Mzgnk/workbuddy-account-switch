# ============================================================
#  WorkBuddy Account Switcher  (WorkBuddy 账号切换器) v3.0
#  菜单/命令行入口。核心逻辑在 switcher-core.ps1 (单一正本)
#  图形界面入口见 switcher-gui.ps1
#
#  用法:
#   (无参数)              交互菜单
#   -Action runjob        读取并执行 pending-job.json
#   -Action switch -Name X / -Action save -Name X   非交互执行
#   -Action list / accounts / selftest              只读查询
# ============================================================
param(
    [string]$Action = "menu",
    [string]$Name = "",
    [int]$DelaySeconds = 0
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "switcher-core.ps1")

# ============================================================
#  只读: 账号扫描清单
# ============================================================
function Show-Accounts {
    $list = Get-KnownAccounts
    Write-Host ""
    Write-Host "  ===== 本机 WorkBuddy 账号扫描 =====" -ForegroundColor Cyan
    foreach ($a in $list) {
        $disp = if ($a.Nick) { $a.Nick } else { "账号 " + $a.Uid.Substring(0, [Math]::Min(8, $a.Uid.Length)) }
        $status = if ($a.IsLive) { "当前登录" } elseif ($a.HasProfile) { "已建档" } else { "需登录一次建档" }
        $prof  = if ($a.ProfileName) { "  档案:$($a.ProfileName)" } else { "" }
        $seen  = if ($a.LastSeen) { "  最近登录:" + $a.LastSeen.ToString("MM-dd HH:mm") } else { "" }
        $mark  = if ($a.IsLive) { "  <-- 你现在在这里" } else { "" }
        Write-Host ("   - {0}  [{1}]{2}{3}{4}" -f $disp, $status, $prof, $seen, $mark)
    }
    Write-Host ""
}

# ============================================================
#  交互菜单
# ============================================================
function Save-Profile([string]$Name) {
    $pdir = Join-Path $ProfRoot $Name
    if (Test-Path $pdir) {
        $a = Read-Host "  档案 [$Name] 已存在, 覆盖? (y/N)"
        if ($a -ne "y" -and $a -ne "Y") { Write-Host "  已取消。"; return }
    }
    if (-not (Ensure-AppClosed)) { Write-Host "  已取消。"; return }
    $acc = Get-LiveAccount
    if (-not $acc) { Write-Host "  [X] 读取不到当前登录账号。" -ForegroundColor Red; return }
    Write-Host "  >> 正在保存登录态 (约 40MB, 几秒钟) ..."
    try { Save-SwapSet (Join-Path $ProfRoot "$Name\live") } catch { Write-Host "  [X] 保存失败: $_" -ForegroundColor Red; return }
    $old = Read-ProfileMeta $Name
    Write-ProfileMeta $Name $acc.Uid $acc.Nick $acc.Type (-not $old)
    Set-CurrentProfile $Name
    Write-Log "SAVE OK [$Name] (menu) account=$($acc.Nick)"
    Write-Host ""
    Write-Host "  [OK] 已保存档案 [$Name]  账号: $($acc.Nick)" -ForegroundColor Green
    $a = Read-Host "  现在重新启动 WorkBuddy? (Y/n)"
    if ($a -ne "n" -and $a -ne "N") { Start-WorkBuddy | Out-Null }
}

function Switch-Profile([string]$Name) {
    if (-not (Test-Path (Join-Path $ProfRoot "$Name\live"))) {
        Write-Host "  [X] 档案 [$Name] 不存在或已损坏。" -ForegroundColor Red
        return
    }
    if (-not (Ensure-AppClosed)) { Write-Host "  已取消。"; return }
    $cur = Get-CurrentProfile
    $acc = Get-LiveAccount
    if ($cur -and $cur -ne $Name) {
        $curMeta = Read-ProfileMeta $cur
        if ($curMeta -and $acc -and $curMeta.uid -and ($curMeta.uid -ne $acc.Uid)) {
            Write-Host ""
            Write-Host "  [!] 检测到当前登录账号($($acc.Nick))与档案 [$cur] 记录的账号不一致。" -ForegroundColor Yellow
            Write-Host "      可能你手动退出/换过账号。直接切换会把当前状态误存进 [$cur]。"
            $a = Read-Host "  [1]把当前状态另存为新档案  [2]仍存入[$cur]  [3]不保存直接切换  [C]取消"
            if ($a -eq "1") {
                $n = Clean-Name (Read-Host "  新档案名称")
                if (-not $n) { Write-Host "  名称无效, 已取消。"; return }
                Save-SwapSet (Join-Path $ProfRoot "$n\live")
                Write-ProfileMeta $n $acc.Uid $acc.Nick $acc.Type $true
                Set-CurrentProfile $n
                $cur = $n
            } elseif ($a -eq "2") {
                Save-SwapSet (Join-Path $ProfRoot "$cur\live")
            } elseif ($a -eq "C" -or $a -eq "c") {
                Write-Host "  已取消。"; return
            }
        } else {
            Write-Host "  >> 自动保存当前登录态到档案 [$cur] ..."
            Save-SwapSet (Join-Path $ProfRoot "$cur\live")
            if ($curMeta) { Write-ProfileMeta $cur $curMeta.uid $curMeta.nickname $curMeta.accountType $false }
        }
    } elseif (-not $cur) {
        Write-Host ""
        $a = Read-Host "  当前登录态还没有档案。切换前先保存吗? 输入名称保存 / 直接回车跳过"
        if ($a.Trim() -ne "") {
            $n = Clean-Name $a
            if ($n) {
                Save-SwapSet (Join-Path $ProfRoot "$n\live")
                $acc2 = Get-LiveAccount
                Write-ProfileMeta $n $(if($acc2){$acc2.Uid}else{""}) $(if($acc2){$acc2.Nick}else{""}) $(if($acc2){$acc2.Type}else{""}) $true
                Set-CurrentProfile $n
            }
        }
    }
    Backup-Live
    Write-Host "  >> 正在切换到档案 [$Name] ..."
    try { Restore-SwapSet (Join-Path $ProfRoot "$Name\live") }
    catch { Write-Host "  [X] 切换失败: $_" -ForegroundColor Red; return }
    Set-CurrentProfile $Name
    $meta = Read-ProfileMeta $Name
    $nick = if ($meta) { $meta.nickname } else { "?" }
    Write-Log "SWITCH OK -> [$Name] ($nick) (menu)"
    Write-Host ""
    Write-Host "  [OK] 切换完成! 启动后应显示账号: $nick" -ForegroundColor Green
    $a = Read-Host "  现在启动 WorkBuddy? (Y/n)"
    if ($a -ne "n" -and $a -ne "N") { Start-WorkBuddy | Out-Null }
}

function Show-List {
    $cur = Get-CurrentProfile
    $acc = Get-LiveAccount
    $list = Get-Profiles
    Write-Host ""
    Write-Host "  ===== WorkBuddy 账号档案 =====" -ForegroundColor Cyan
    if ($acc) { Write-Host "  当前登录: $($acc.Nick)  (uid $($acc.Uid.Substring(0,8))...)" }
    if (-not $cur) { Write-Host "  当前登录态未建档" -ForegroundColor Yellow } else { Write-Host "  当前档案: $cur" }
    if ($list.Count -eq 0) {
        Write-Host "  (还没有任何档案, 用菜单 1 先保存一个)" -ForegroundColor Yellow
    } else {
        $list | ForEach-Object {
            $mark = if ($_.Name -eq $cur) { " <- 当前" } else { "" }
            Write-Host ("   - {0}  账号:{1}  保存于:{2}{3}" -f $_.Name, $(if($_.Nick){$_.Nick}else{"?"}), $_.Saved, $mark)
        }
    }
    Write-Host ""
}

function Remove-Profile([string]$Name) {
    $pdir = Join-Path $ProfRoot $Name
    if (-not (Test-Path $pdir)) { Write-Host "  [X] 档案 [$Name] 不存在。" -ForegroundColor Red; return }
    $cur = Get-CurrentProfile
    if ($cur -eq $Name) { Write-Host "  [X] [$Name] 是当前使用中的档案, 不能删除。" -ForegroundColor Red; return }
    $a = Read-Host "  确认删除档案 [$Name] ? 此操作不可恢复 (y/N)"
    if ($a -eq "y" -or $a -eq "Y") {
        Remove-Item $pdir -Recurse -Force
        Write-Log "profile deleted: [$Name]"
        Write-Host "  [OK] 已删除 [$Name]。" -ForegroundColor Green
    } else { Write-Host "  已取消。" }
}

function Show-Menu {
    Write-Host ""
    Write-Host "  ==============================================" -ForegroundColor Cyan
    Write-Host "        WorkBuddy 账号切换器 v3.0" -ForegroundColor Cyan
    Write-Host "  ==============================================" -ForegroundColor Cyan
    Write-Host "  档案目录: $ProfRoot"
    Write-Host "  (档案内含登录凭证, 不要拷贝给他人)"
    $acc = Get-LiveAccount
    if ($acc) { Write-Host "  当前登录: $($acc.Nick)" }

    while ($true) {
        $cur = Get-CurrentProfile
        Write-Host ""
        Write-Host "  --------------------------------"
        Write-Host "   1. 保存当前登录为新档案   当前档案: $(if($cur){$cur} else {'(无)'})"
        Write-Host "   2. 切换账号"
        Write-Host "   3. 查看账号/档案列表"
        Write-Host "   4. 删除档案"
        Write-Host "   5. 退出"
        $c = Read-Host "  请选择 (1-5)"
        switch ($c) {
            "1" {
                $n = Clean-Name (Read-Host "  档案名称 (比如: 主号 / 工作号)")
                if ($n) { Save-Profile $n } else { Write-Host "  名称无效。" -ForegroundColor Red }
            }
            "2" {
                $list = Get-Profiles
                if ($list.Count -eq 0) { Write-Host "  还没有档案, 请先用 1 保存当前账号。" -ForegroundColor Yellow; continue }
                for ($i = 0; $i -lt $list.Count; $i++) {
                    Write-Host ("   [{0}] {1}  账号:{2}" -f ($i+1), $list[$i].Name, $list[$i].Nick)
                }
                $k = Read-Host "  切换到第几个 (输入数字, C 取消)"
                if ($k -match '^\d+$' -and [int]$k -ge 1 -and [int]$k -le $list.Count) {
                    Switch-Profile $list[[int]$k - 1].Name
                } elseif ($k -eq "C" -or $k -eq "c") { }
                else { Write-Host "  无效选择。" -ForegroundColor Red }
            }
            "3" { Show-Accounts }
            "4" {
                $list = Get-Profiles
                if ($list.Count -eq 0) { Write-Host "  没有可删除的档案。"; continue }
                for ($i = 0; $i -lt $list.Count; $i++) {
                    Write-Host ("   [{0}] {1}  账号:{2}" -f ($i+1), $list[$i].Name, $list[$i].Nick)
                }
                $k = Read-Host "  删除第几个 (输入数字, C 取消)"
                if ($k -match '^\d+$' -and [int]$k -ge 1 -and [int]$k -le $list.Count) {
                    Remove-Profile $list[[int]$k - 1].Name
                }
            }
            "5" { break }
            default { Write-Host "  请输入 1-5。" -ForegroundColor Red }
        }
    }
}

# ============================================================
#  入口
# ============================================================
if (-not (Test-Path $ProfRoot)) { New-Item -ItemType Directory -Path $ProfRoot -Force | Out-Null }

switch ($Action) {
    "list"     { Show-List }
    "accounts" { Show-Accounts }
    "selftest" { Invoke-SelfTest }
    "doctor"   { Invoke-Doctor }
    "verify"   { [void](Invoke-Verify) }
    "runjob"   { [void](Invoke-RunJob) }
    "switch"   {
        if (-not $Name) { Write-Host "用法: -Action switch -Name <档案名>"; exit 1 }
        if ($DelaySeconds -gt 0) { Start-Sleep -Seconds $DelaySeconds }
        if (-not (Invoke-AutoSwitch $Name)) { exit 1 }
    }
    "save"     {
        if (-not $Name) { Write-Host "用法: -Action save -Name <档案名>"; exit 1 }
        if ($DelaySeconds -gt 0) { Start-Sleep -Seconds $DelaySeconds }
        if (-not (Invoke-AutoSave $Name)) { exit 1 }
    }
    default    { Show-Menu }
}
