# ============================================================
#  WorkBuddy Account Switcher - 图形界面 (v3.0)
#  一列账号, 点选切换。核心逻辑在 switcher-core.ps1 (单一正本)
# ============================================================
param([switch]$SmokeTest)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "switcher-core.ps1")

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName Microsoft.VisualBasic
[System.Windows.Forms.Application]::EnableVisualStyles()

$font = New-Object System.Drawing.Font("Microsoft YaHei", 9)

# ---------- 窗体 ----------
$form = New-Object System.Windows.Forms.Form
$form.Text = "WorkBuddy 账号切换"
$form.ClientSize = New-Object System.Drawing.Size(440, 400)
$form.FormBorderStyle = "FixedDialog"
$form.MaximizeBox = $false
$form.StartPosition = "CenterScreen"
$form.Font = $font

# ---------- 标题与当前状态 ----------
$lblTitle = New-Object System.Windows.Forms.Label
$lblTitle.Text = "WorkBuddy 账号切换"
$lblTitle.Location = New-Object System.Drawing.Point(12, 8)
$lblTitle.AutoSize = $true
$lblTitle.Font = New-Object System.Drawing.Font("Microsoft YaHei", 11, [System.Drawing.FontStyle]::Bold)
$form.Controls.Add($lblTitle)

$lblCurrent = New-Object System.Windows.Forms.Label
$lblCurrent.Location = New-Object System.Drawing.Point(12, 36)
$lblCurrent.AutoSize = $true
$lblCurrent.ForeColor = [System.Drawing.Color]::DimGray
$form.Controls.Add($lblCurrent)

# ---------- 账号列表 ----------
$lv = New-Object System.Windows.Forms.ListView
$lv.View = "Details"
$lv.FullRowSelect = $true
$lv.MultiSelect = $false
$lv.HideSelection = $false
$lv.Location = New-Object System.Drawing.Point(12, 62)
$lv.Size = New-Object System.Drawing.Size(416, 240)
[void]$lv.Columns.Add("账号", 150)
[void]$lv.Columns.Add("状态", 110)
[void]$lv.Columns.Add("档案", 90)
[void]$lv.Columns.Add("最近登录", 66)
$form.Controls.Add($lv)

# ---------- 按钮 ----------
$btnSwitch = New-Object System.Windows.Forms.Button
$btnSwitch.Text = "切换到选中账号"
$btnSwitch.Location = New-Object System.Drawing.Point(12, 312)
$btnSwitch.Size = New-Object System.Drawing.Size(130, 32)
$form.Controls.Add($btnSwitch)

$btnSave = New-Object System.Windows.Forms.Button
$btnSave.Text = "保存当前登录..."
$btnSave.Location = New-Object System.Drawing.Point(154, 312)
$btnSave.Size = New-Object System.Drawing.Size(130, 32)
$form.Controls.Add($btnSave)

$btnRefresh = New-Object System.Windows.Forms.Button
$btnRefresh.Text = "刷新"
$btnRefresh.Location = New-Object System.Drawing.Point(296, 312)
$btnRefresh.Size = New-Object System.Drawing.Size(132, 32)
$form.Controls.Add($btnRefresh)

# ---------- 状态栏 ----------
$lblStatus = New-Object System.Windows.Forms.Label
$lblStatus.Location = New-Object System.Drawing.Point(12, 356)
$lblStatus.Size = New-Object System.Drawing.Size(416, 36)
$lblStatus.ForeColor = [System.Drawing.Color]::DimGray
$form.Controls.Add($lblStatus)

function Set-Status([string]$Msg, [bool]$IsError = $false) {
    $lblStatus.Text = $Msg
    $lblStatus.ForeColor = if ($IsError) { [System.Drawing.Color]::Firebrick } else { [System.Drawing.Color]::DimGray }
    $form.Refresh()
    [System.Windows.Forms.Application]::DoEvents()
}

function Get-LastLogLine {
    if (Test-Path $LogFile) { return (Get-Content $LogFile -Tail 1) }
    return ""
}

# ---------- 刷新列表 ----------
function Refresh-List {
    $lv.Items.Clear()
    $accounts = Get-KnownAccounts
    $acc = Get-LiveAccount
    $curProfile = Get-CurrentProfile
    if ($acc) {
        $profTxt = if ($curProfile) { $curProfile } else { "(未建档)" }
        $lblCurrent.Text = "当前登录: $($acc.Nick)    档案: $profTxt"
    } else {
        $lblCurrent.Text = "当前登录: 读取失败 (可能未登录)"
    }
    foreach ($a in $accounts) {
        $disp = if ($a.Nick) { $a.Nick } elseif ($a.Uid) { "账号 " + $a.Uid.Substring(0, [Math]::Min(8, $a.Uid.Length)) } else { $a.ProfileName }
        $status = if ($a.IsLive) { "● 当前登录" } elseif ($a.HasProfile) { "已建档" } else { "需登录一次建档" }
        $seen = if ($a.LastSeen) { $a.LastSeen.ToString("MM-dd") } else { "" }
        $item = New-Object System.Windows.Forms.ListViewItem($disp)
        [void]$item.SubItems.Add($status)
        [void]$item.SubItems.Add($a.ProfileName)
        [void]$item.SubItems.Add($seen)
        if ($a.IsLive) { $item.ForeColor = [System.Drawing.Color]::SeaGreen; $item.Font = New-Object System.Drawing.Font($font, [System.Drawing.FontStyle]::Bold) }
        elseif (-not $a.HasProfile) { $item.ForeColor = [System.Drawing.Color]::Gray }
        $item.Tag = $a
        [void]$lv.Items.Add($item)
    }
    if ($lv.Items.Count -gt 0) { $lv.Items[0].Selected = $true }
}

# ---------- 切换 ----------
function Do-Switch {
    if (-not $lv.SelectedItems.Count -gt 0) { return }
    $a = $lv.SelectedItems[0].Tag
    if ($a.IsLive) { [void][System.Windows.Forms.MessageBox]::Show("这个账号就是当前登录的账号。", "提示"); return }
    if (-not $a.HasProfile) {
        [void][System.Windows.Forms.MessageBox]::Show(
            "这个账号还没有登录态档案, 无法直接切换。`n`n做法: 在 WorkBuddy 里登录这个账号 (扫码/验证码均可),`n然后回来点【保存当前登录】, 建档一次后以后就能秒切。",
            "需要先建档")
        return
    }
    $nick = if ($a.Nick) { $a.Nick } else { $a.ProfileName }
    $confirm = [System.Windows.Forms.MessageBox]::Show(
        "确定切换到 [$nick] 吗?`n`n· 当前账号的状态会自动保存, 不会丢`n· WorkBuddy 将自动关闭、切换并重启`n· 正在进行的 AI 对话会被中断",
        "确认切换", "OKCancel", "Warning", "Button1")
    if ($confirm -ne [System.Windows.Forms.DialogResult]::OK) { return }
    $btnSwitch.Enabled = $false; $btnSave.Enabled = $false
    Set-Status "正在切换到 [$nick] ... (关闭程序 → 搬运登录态 → 重启, 约几秒到十几秒)"
    $ok = $false
    try { $ok = Invoke-AutoSwitch $a.ProfileName } catch { Set-Status "切换出错: $_" $true; $btnSwitch.Enabled = $true; $btnSave.Enabled = $true; return }
    if ($ok) {
        Set-Status "切换完成! WorkBuddy 正在启动, 本窗口即将关闭。"
        Start-Sleep -Seconds 2
        $form.Close()
    } else {
        Set-Status "切换失败: $(Get-LastLogLine)" $true
        $btnSwitch.Enabled = $true; $btnSave.Enabled = $true
    }
}

# ---------- 保存当前登录 ----------
function Do-Save {
    $acc = Get-LiveAccount
    if (-not $acc) { [void][System.Windows.Forms.MessageBox]::Show("读取不到当前登录账号。", "提示"); return }
    $default = Clean-Name $acc.Nick
    if (-not $default) { $default = "账号" + $acc.Uid.Substring(0, 4) }
    $name = [Microsoft.VisualBasic.Interaction]::InputBox(
        "给这个账号的档案起个名字 (用来在列表里认出它):`n当前账号: $($acc.Nick)",
        "保存当前登录", $default)
    if ([string]::IsNullOrWhiteSpace($name)) { return }
    $n = Clean-Name $name
    if (-not $n) { [void][System.Windows.Forms.MessageBox]::Show("名称无效。", "提示"); return }
    $btnSwitch.Enabled = $false; $btnSave.Enabled = $false
    Set-Status "正在保存当前登录为档案 [$n] ... (关闭程序 → 备份登录态 → 重启)"
    $ok = $false
    try { $ok = Invoke-AutoSave $n } catch { Set-Status "保存出错: $_" $true; $btnSwitch.Enabled = $true; $btnSave.Enabled = $true; return }
    if ($ok) {
        Set-Status "已保存档案 [$n] (账号: $($acc.Nick))。以后在列表里点它就能一键切换。"
        Refresh-List
    } else {
        Set-Status "保存失败: $(Get-LastLogLine)" $true
    }
    $btnSwitch.Enabled = $true; $btnSave.Enabled = $true
}

# ---------- 事件绑定 ----------
$btnSwitch.Add_Click({ Do-Switch })
$btnSave.Add_Click({ Do-Save })
$btnRefresh.Add_Click({ Refresh-List; Set-Status "已刷新。" })
$lv.Add_DoubleClick({ Do-Switch })

# ---------- 启动 ----------
Refresh-List
$verifyResult = $null
if (Test-Path (Join-Path $ProfRoot "expect.json")) {
    try { $verifyResult = Invoke-Verify } catch {}
}
if ($verifyResult -eq $true) {
    Set-Status "上次切换核验通过: 当前登录账号已按预期切换。"
} elseif ($verifyResult -eq $false) {
    Set-Status "上次切换未生效: 账号没有真正切换(详见 switch-log.txt)。可再试一次或运行体检。" $true
} else {
    Set-Status "双击账号行或点【切换到选中账号】即可切换; 首次使用先【保存当前登录】。"
}

if ($SmokeTest) {
    $timer = New-Object System.Windows.Forms.Timer
    $timer.Interval = 500
    $timer.Add_Tick({ $form.Close() })
    $timer.Start()
}

[void]$form.ShowDialog()
