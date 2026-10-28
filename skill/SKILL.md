---
name: workbuddy-account-switch
description: 本机 WorkBuddy 多账号切换器。当用户提到"切换账号、切到XX号、换个账号、保存当前账号、建账号档案、看看有哪些账号"等本机 WorkBuddy 账号管理需求时使用此技能。AI 负责查询/确认/准备任务文件，用户双击桌面图标打开图形界面一键切换。
agent_created: true
---

# WorkBuddy 账号切换

本技能管理本机多个 WorkBuddy 账号：扫描账号、建档、切换、查状态。核心逻辑单一正本为 `<APP>\switcher-core.ps1`（勿复制副本，勿改动其中的切换清单）；用户执行入口是桌面「WorkBuddy账号切换.bat」，双击后打开图形界面（有待执行任务时则直接执行）。

## 关键路径

| 用途 | 路径 |
|---|---|
| 核心库（单一正本） | <APP>\switcher-core.ps1 |
| 菜单/命令行入口 | <APP>\switcher.ps1 |
| 图形界面入口 | <APP>\switcher-gui.ps1 |
| 档案库（含登录凭证） | %USERPROFILE%\.workbuddy-profiles\ |
| 待执行任务文件 | %USERPROFILE%\.workbuddy-profiles\pending-job.json |
| 待核验记录 | %USERPROFILE%\.workbuddy-profiles\expect.json |
| 执行日志 | %USERPROFILE%\.workbuddy-profiles\switch-log.txt |

## 核心约束（必须遵守）

1. **绝不在会话内执行 `-Action switch` / `-Action save` / `-Action runjob`** —— 这些操作会关闭 WorkBuddy，等于杀死当前 AI 会话。执行者只能是用户双击桌面「WorkBuddy账号切换.bat」。
2. 会话内只允许执行只读操作：`-Action accounts`（账号扫描）、`-Action list`（档案列表）、`-Action selftest`、`-Action doctor`、`-Action synccheck`（会话归属只查不改）。`-Action sync` 会关程序，属禁止项。
3. 档案库 `%USERPROFILE%\.workbuddy-profiles\` 含登录凭证：禁止拷贝、压缩、上传、外发，禁止将其内容展示给任何人。
4. `pending-job.json` 超过 30 分钟自动作废；作废后重新写一份即可。
5. 切换会中断当前所有 WorkBuddy 内的 AI 对话，触发前必须告知用户。
6. 旧账号的登录态在退出登录时已被销毁，无法凭空恢复——每个账号需要登录一次建档（扫码/验证码均可），此后切换免登录。向用户解释时用这个事实，不要承诺"免登录读取旧账号"。

## 工作流

### 查看本机有哪些账号（只读，可随时执行）

```
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "<APP>\switcher.ps1" -Action accounts
```

输出自动扫描的账号清单：昵称（仅当前登录和已建档的账号能读到昵称）、状态（当前登录/需登录一次建档）、最近登录时间。查看已保存档案用 `-Action list`。

### 核验切换是否真的生效（只读，优先执行）

```
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "<APP>\switcher.ps1" -Action verify
```

切换时程序会写 `expect.json`（记录目标账号 uid）；用户重开 WorkBuddy 后执行 verify，程序比对「实时登录 uid」与「目标 uid」，把 `VERIFY OK` / `VERIFY MISMATCH` 写进日志。**用户说"切换没成功"时，先跑 verify，不要凭感觉判断。**

### 档案体检（只读）

```
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "<APP>\switcher.ps1" -Action doctor
```

逐条列出：实时登录账号、每个档案记录的 uid 与档案内快照 uid 是否一致、档案体积、是否有多个档案指向同一账号。**判断"切换没反应"时必跑**：若目标档案的 uid 与当前登录 uid 相同，切换必然无变化（不是故障）。

### 引导用户切换（推荐：让用户自己用图形界面）

直接告诉用户：**双击桌面「WorkBuddy账号切换」，在列表里点账号 → 点【切换到选中账号】**。这是最顺畅的路径，AI 不需要写任务文件。

仅在用户明确要求 AI 代为准备时才走任务文件流程：
1. 执行 `-Action accounts` 确认目标账号已建档（`HasProfile`）
2. 与用户确认目标档案名
3. 写任务文件（`<档案名>` 换成实际名称）：

```
@{ action='switch'; name='<档案名>'; delaySeconds=0; createdAt=(Get-Date -Format o) } | ConvertTo-Json | Set-Content '%USERPROFILE%\.workbuddy-profiles\pending-job.json' -Encoding UTF8
```

4. 回复用户：**「已就绪：双击桌面『WorkBuddy账号切换』，会直接执行切换（程序自动关闭并重启，当前对话会中断）。」**

### 保存当前账号（建档）

图形界面点【保存当前登录】是首选。AI 代准备时任务文件把 action 改为 `save`。档案名规则：不能含 `\ / : * ? " < > |`，不能叫 `backup`；同名档案属于别的账号会被程序拒绝。

**建档必须"人对着账号"**：档案记录的是「保存那一刻正在登录的账号」。若档案名里写了手机号而该手机号与当前登录账号对不上，程序会直接拒绝保存（防止把 B 号的名字贴到 A 号的登录态上，进而误判"切换无效"）。

### 首次使用（还没有任何档案时）

1. 引导用户保存当前登录（图形界面【保存当前登录】，名称默认自动填当前账号昵称）。
2. 提示用户在 WorkBuddy 内**正常退出登录 → 登录另一个账号**（此步必须手动，扫码/验证码均可）。
3. 再保存第二个账号。此后列表里点谁切谁。

### 会话互通（v3.4 起默认开启，v3.6 自包含化，v3.7 建档即互通）

各账号共享同一份会话历史：**不搬移** `projects` / `sessions` / `workbuddy.db`，只在 WorkBuddy 关闭状态下把会话库 `sessions.user_id` 统一改写成目标账号 uid，并清掉该 uid 目录下的 `sidebar-list-snapshot.json`（否则界面仍读旧缓存）。

**三个触发点**（同一实现 `Sync-SessionAfterProfileChange` / `Invoke-AutoSync`）：

```
① 切换：点切换 → 关程序 → 换档案 → 归属归一 → 清缓存 → 重启
② 建档：点【保存当前登录】→ 关程序 → 存档案 → 归属归一 → 清缓存 → 重启   ← v3.7 补上
③ 兜底：GUI【同步会话历史】按钮 / -Action sync（命令行 synccheck 只查不改）
```

> ①③ 是用户可感知的入口，② 是静默的。向用户解释时**先说"不用管，建档时就并好了"**，不要把一个缺陷修复讲成需要他学的新步骤。

- 开关：核心库 `$ShareConversations`（`$true` 共享 / `$false` 恢复各账号独立）
- 执行体：`Merge-SessionOwners [-Check]`，运行时按序探测 Python —— ① WorkBuddy 自带 `~/.workbuddy/binaries/python/versions/*` ② PATH（跳过 WindowsStore 占位符）③ 常见安装目录。**不得再写死带用户名的绝对路径**（换电脑即失效）
- 兜底：`merge-sessions.py` 丢失时自动用核心库内嵌的 `$MergeSessionPySrc` 生成临时脚本执行，互通不中断
- 返回值：`@{Ok; Reason; Moved; Total; Before}`。失败时切换**照常完成**，但界面会打黄字警告并写 `SWITCH WARN: conversation merge skipped (<Reason>)` —— 属"登录正常、历史只显示本账号"的降级态，不是切换失败
- 运行中保护：`Test-AppRunning` 为真时拒绝改库（库被独占，写了会被回滚），改提示用户跑 `-Action sync`
- 日志证据：`merge-sessions [uid8] check=False via <python路径> (exit=0): {"ok":true,...,"moved":N,"total":M}`
- 自检：`-Action selftest` 打「互通组件」「运行时」「归属一致性」三行；`-Action doctor` 另报「会话归属」与库内 uid 分布
- 切换前会话库索引仍会单独备份到 `backup\<时间戳>\workbuddy.db*`
- 若用户反馈"**新加的账号看不到历史**"：这是 v3.6 及以前的缺陷（建档不触发归属归一），v3.7 已修。现场判断用 `-Action synccheck`：报 `有 N 条属于别的账号` 即命中，`-Action sync` 一次修好
- 若用户反馈"切换后看不到历史会话"：先看日志 `merge-sessions` 行是否 `exit=0`；再看 `Reason`（`no-python` / `helper-missing` 属环境问题，可修）；都正常则疑服务端会话列表覆盖（服务端限制，文件层面无解，只能等或退回 `$false`）
- 若用户反馈"两个账号的会话混在一起了"：这是本功能的设计效果，不是故障；想分开就把开关改成 `$false`

### 故障排查

| 现象 | 处理 |
|---|---|
| 双击后提示"任务已过期" | 任务文件超 30 分钟，重新写一份或让用户直接用图形界面 |
| 日志有 `SWITCH FAIL` | 读 `switch-log.txt` 向用户报告失败原因；backup\ 目录有切换前完整备份 |
| 切换后账号没变 | **先跑 `-Action doctor`**：若两个档案 uid 相同（同一账号存了两次），切换本就不会有变化，删掉多余档案并纠正名字即可；若 uid 不同则跑 `-Action verify`，看日志是 `VERIFY MISMATCH` 还是读不到状态（程序未启动） |
| `VERIFY MISMATCH` 但 `Preferences` 哈希与目标档案一致（文件确实换对了） | 真身登录会话在 `.workbuddy` 之外：`%LOCALAPPDATA%\CodeBuddyExtension\Data\Public\auth\workbuddy-desktop.info`。该文件未纳入清单时，应用启动 7 秒内会用旧会话覆盖快照（日志 `FileAuthStorage.restore ... uid=<旧账号>` → `[wb-path] 首次绑定 uid=<旧账号>`）。已在 v3 清单纳入，须重建档案 |
| 列表里某账号显示"需登录一次建档" | 该账号登录态已销毁，需用户手动登录一次并保存 |
| 日志反复 `VERIFY MISMATCH` | 登录态覆盖不全：对比 `backup\` 与目标档案差异，扩充切换清单；必要时把差异文件补进 `switcher-core.ps1` 顶部清单 |
