# WorkBuddy 账号切换

> 在本机多个 WorkBuddy 账号之间一键切换 —— 不用退出登录，不用重新扫码或输验证码，点一下就换，几秒钟完成。

> **本项目是个人开源的第三方工具，与 WorkBuddy 官方无关，未获官方背书。** 它通过替换本地登录态文件实现切换，属于对第三方软件的外部辅助手段，请阅读文末[安全与风险](#安全与风险)后再决定是否使用。

![platform](https://img.shields.io/badge/platform-Windows-lightgrey)
![powershell](https://img.shields.io/badge/PowerShell-5.1%2B-blue)
![version](https://img.shields.io/badge/version-v3.7-green)

---

## 这是什么

WorkBuddy 桌面版本身不提供账号切换功能，换号必须先退出、再登录，扫码账号和验证码账号尤其麻烦。

本项目是一个**外部辅助工具**：它不动 WorkBuddy 的代码，只做一件事 —— 把「当前登录态」按账号备份成档案，切换时整体换过去。

实测切换一次约 3 秒，全程不需要任何认证操作。

**效果对照：**

| | 原生 WorkBuddy | 本工具 |
|---|---|---|
| 换账号 | 退出登录 → 重新扫码/输验证码 | 点一下账号名 |
| 历史对话 | 换号后看不到另一个号的对话 | 默认共享同一份历史（可关闭） |
| 数据 | 只保留当前账号 | 每个账号独立档案，互不污染 |

---

## 原理（为什么能做到"秒切"）

三句话讲完：

1. **各账号的数据本来就并存**。WorkBuddy 会把登录过的每个账号的界面状态、连接器绑定、云端配置分别存在自己的目录里，不会因为换号删掉。
2. **「当前是谁」只由一小部分文件决定**。真正需要切换的是登录态（Cookies、LocalStorage、按账号分的凭证库、设备级自动登录凭证、外部登录会话文件等），合计约 40MB。
3. **切换 = 换掉这一小部分**。其余机器级文件（设备 ID、密钥、设置）刻意不动 —— 动了会导致凭证解密失败或被判定异常登录。

所以本工具的档案本质上是一份「登录态快照」。

> **为什么首次要给每个账号建档？**
> 退出登录的那一刻，WorkBuddy 会销毁该账号的登录凭证（磁盘上只剩数据，没有凭证）。所以旧账号必须**再登录一次**，让工具抓到有效凭证存档。这是一次性成本，之后永远免登录切换。

---

## 系统要求

- Windows 10 / 11
- PowerShell 5.1（系统自带）
- WorkBuddy 桌面版
- Python 3（**仅「会话互通」功能需要**；会自动优先使用 WorkBuddy 自带的 Python，通常无需另装）

---

## 安装

1. 把本仓库下载或 clone 到任意目录（下称 `<APP>`），例如：

   ```powershell
   git clone https://github.com/Mzgnk/workbuddy-account-switch.git "$env:USERPROFILE\workbuddy-account-switch"
   ```

   也可以在仓库页点头部的 **Code → Download ZIP** 直接下载解压（不需要装 git）。

2. 双击 `Run.bat` —— 第一次运行会弹出账号窗口。
3. （可选）给 `Run.bat` 建个桌面快捷方式，或发送到开始菜单。

> 脚本内所有路径都是**自动探测**的：用户目录取 `%USERPROFILE%`，WorkBuddy 主程序按「运行中进程 → 常见安装位置」依次查找。换电脑不用改任何代码。
> 若 WorkBuddy 装在特殊位置，把绝对路径填进 `switcher-core.ps1` 顶部的 `$WbExeOverride` 即可。

---

## 使用

### 一、首次建档（一次性，每个账号做一次）

窗口里点 **【保存当前登录】** → 起个名字 → 完成。

然后**手动**在 WorkBuddy 里退出登录、登录第二个账号，再点一次【保存当前登录】。

> 这一步必须手动，因为涉及扫码 / 验证码 / 密码，工具不碰认证环节。

### 二、日常切换

双击 `Run.bat` → 窗口列出所有账号 → **点一下要切的那个**。

程序会自动完成：关闭 WorkBuddy → 备份当前状态 → 换档案 → 统一会话归属 → 清列表缓存 → 重启。全程几秒钟。

窗口里每个账号会标注：当前登录（绿色）、已建档、最近登录时间、账号 uid 前缀。

### 三、命令行 / 脚本调用

```powershell
# 查看自检
powershell -NoProfile -ExecutionPolicy Bypass -File .\switcher.ps1 -Action selftest

# 扫描本机所有账号
powershell -NoProfile -ExecutionPolicy Bypass -File .\switcher.ps1 -Action accounts

# 核验上一次切换是否真的生效
powershell -NoProfile -ExecutionPolicy Bypass -File .\switcher.ps1 -Action verify

# 档案体检
powershell -NoProfile -ExecutionPolicy Bypass -File .\switcher.ps1 -Action doctor
```

### 四、作为 WorkBuddy 技能使用（可选）

把 `skill/SKILL.md` 复制到 `%USERPROFILE%\.workbuddy\skills\workbuddy-account-switch\`，重启 WorkBuddy 后即可在聊天里说「切换到工作号」，由 AI 完成查询、确认、准备任务，你只需双击一次 `Run.bat`。

> 技能把 `<APP>` 作为占位符，请按你实际的安装路径替换。

---

## 会话互通

默认开启：**所有账号共享同一份会话历史**，切到任何账号都能看到全部历史对话并接着聊。

实现方式不是搬数据，而是改标签 —— WorkBuddy 的会话都存在同一个数据库里，每条带「属于哪个账号」的字段，界面按当前账号过滤。把归属统一到目标账号即可，同时清掉侧边栏缓存迫使界面重建。

归属统一会在**三个时机**触发，不要求用户额外操作：

| 时机 | 说明 |
|---|---|
| 切换账号 | 换档案 → 统一归属 → 清缓存 → 重启 |
| 保存当前登录（建档） | v3.7 新增。新账号建档当场就并入全部历史，不必再切一次 |
| 点【同步会话历史】/ `-Action sync` | 兜底修复：手动在 App 里换过账号时使用 |

窗口底部常驻一行「会话归属」状态：绿色表示归属一致（并显示名下条数），红色表示有 N 条属于别的账号、当前账号看不到，此时按钮会亮起，点一下即修。

```powershell
# 只查（不关程序、不改库）
powershell -NoProfile -ExecutionPolicy Bypass -File .\switcher.ps1 -Action synccheck

# 修复（会关闭并重启 WorkBuddy）
powershell -NoProfile -ExecutionPolicy Bypass -File .\switcher.ps1 -Action sync
```

**关闭方式**：把 `switcher-core.ps1` 里的 `$ShareConversations` 改成 `$false`，恢复各账号独立。

依赖说明：

- 需要一个 Python 运行时执行归属改写（脚本源码已内嵌在核心库，`merge-sessions.py` 被删也能跑）
- 探测顺序：WorkBuddy 自带 Python → 系统 PATH → 常见安装目录
- **找不到 Python 不影响账号切换**，只是历史只显示本账号的，界面会明确黄字提示

---

## 常见问题

**Q：切换后 WorkBuddy 启动一瞬间像成功了，随后又弹回原账号？**

说明切换清单缺了某个「回弹指针」。这类 Electron 应用常见于：
- `security\<账号UUID>\` 这种按账号分目录的凭证库
- 根目录的设备级自动登录凭证（如 `login-device-nonce`）
- 位于用户数据目录**之外**的登录会话文件（如 `%LOCALAPPDATA%\CodeBuddyExtension\Data\Public\auth\`）

本项目已覆盖上述位置。若 WorkBuddy 大版本更新后再次出现，先跑 `-Action verify` 看日志，再把新增的凭证目录补进 `switcher-core.ps1` 顶部的 `$SwapDirs`。

**Q：切换后会话列表只有几条，是不是丢了？**

不是。侧边栏按**工作区**分组，你看到的是当前工作区的会话数。换到别的项目目录才会显示对应工作区的会话。可跑 `-Action verify` 或直接查数据库确认总数。

**Q：刚加的新账号，切过去侧边栏是空的 / 只有它自己的几条？**

v3.7 之前的已知缺陷：归属统一只挂在「切换」动作上，「建档」不触发，于是新账号继承的是上一个账号的标签，界面把会话全过滤掉了（同时还留着一份登录瞬间生成的空侧边栏缓存）。

现在建档时会自动并入。若仍遇到：看图窗底部「会话归属」那一行，红色就点【同步会话历史】，或跑 `-Action synccheck` 查看、`-Action sync` 修复。

**Q：档案为什么这么大（约 84MB）？**

主要是两个目录：按账号分的凭证库（`security`）和账号级数据（`storage`）。都是切换必须的，压缩会失败。

**Q：能不能做成 WorkBuddy 内置插件 / 在软件界面里点？**

不能。切换必须**关闭 WorkBuddy**（登录态文件被运行中进程锁定），而任何跑在 WorkBuddy 内部的代码都会随它一起退出，切换会中断在半路。这是物理限制，不是实现偷懒。

**Q：换电脑能用吗？**

档案**不能跨机使用** —— 里面含本机设备密钥加密的凭证，拷到别的机器无效。但程序本身可以，路径全部自适应，重新建档即可。

---

## 安全与风险

**请务必读完这一节。**

1. **档案目录 `%USERPROFILE%\.workbuddy-profiles\` 等价于登录凭证**。拿到它 ≈ 拿到账号。不要拷贝、不要上传、不要发给任何人。
2. **这是第三方外挂工具，不是官方功能**。使用可能与你所在平台/软件的用户协议存在冲突，风险自负。
3. **软件更新可能使其失效**。WorkBuddy 大版本升级后若出现「弹回原账号」，属正常现象，按上文 FAQ 修复即可。
4. **作者不对数据丢失负责**。工具已做三重保护（切换前自动回存 + 每次覆盖前完整备份 + 保留最近 3 份），但请自行评估是否用于重要账号。
5. **不要在共用电脑上使用**。档案没有额外的密码保护。

---

## 目录结构

```
workbuddy-account-switch/
├── Run.bat                 启动器（双击即用）
├── switcher-core.ps1       核心库：路径探测、切换清单、档案读写、会话互通
├── switcher.ps1            命令行 / 菜单入口
├── switcher-gui.ps1        图形界面（账号列表 + 点选切换）
├── merge-sessions.py       会话归属改写脚本（核心库内也有内嵌副本）
├── 使用说明.md              面向使用者的详细说明
├── skill/SKILL.md          WorkBuddy 技能定义（可选安装）
├── LICENSE
└── README.md
```

运行时产物（档案、备份、日志）全部落在 `%USERPROFILE%\.workbuddy-profiles\`，**不在仓库内**。

---

## 版本

| 版本 | 变更 |
|---|---|
| v3.7 | 建档即互通：新账号保存登录态时立即并入历史；新增「会话归属」状态行与【同步会话历史】按钮 / `-Action sync` |
| v3.6 | 会话互通自包含化：运行时自动探测、源码内嵌兜底、失败不再静默 |
| v3.5 | 保存时自动清理档案内会话副本；磁盘占用降约 40% |
| v3.4 | 新增会话互通（跨账号共享历史） |
| v3.2 | 补入外部登录会话文件，解决「启动后弹回原账号」 |
| v3.1 | 补入 `security/`、`login-device-nonce` 等凭证位；加入档案版本守卫 |
| v3.0 | 图形界面版：自动扫描账号、点选切换 |
| v1.0 | 首版：命令行菜单切换 |

---

## 协议

[MIT](LICENSE) —— 随便用、随便改，出事别找我。
