# 新机安装 Claude Code + CCR + ccr-claude

在一台全新的 Windows 11 机器上，从零装到能跑 `ccr-claude`。
按顺序做，每步都有验证命令；验证不过就别往下走。

> 适用范围：Windows 11 + PowerShell。WSL 侧见 §7。
> 本文对应 ccr-claude **v0.2.1**（2026-11-01 发布）。

---

## 0. 先搞清楚：什么能自动，什么不能

| 步骤 | 能自动化吗 | 说明 |
| --- | --- | --- |
| ① 装 Claude Code CLI | ✅ | 官方安装器一条命令 |
| ② 装 CCR Desktop | ⚠️ 半自动 | 能下载安装包，但 GUI 点击要你自己来 |
| ③ 在 CCR 里加供应商 + 填 API Key | ❌ **不行** | Key 只有你有；没有任何脚本能替你做 |
| ④ 装 ccr-claude 启动器 | ✅ | `install.ps1`，带前置检查 |

所以 **"一键部署"的真实终点是第 ③ 步之前**：环境装好，然后你打开 CCR 填 Key。
任何声称能全自动的方案，要么在偷传 Key，要么直接改写 CCR 的 `config.sqlite` —— 不建议，
那个库有 schema 迁移（刚从 `config.json` 迁到 SQLite），运行时还会被 CCR 锁住。

---

## 1. 前置依赖：Python 3（**最容易漏**）

ccr-claude 用 python 读 CCR 的 SQLite 数据库。**PowerShell 和 bash 都没有内置 SQLite**，
所以这是硬依赖，不是可选项。

```powershell
winget install Python.Python.3.12
```

**新开一个终端**再验证（PATH 要刷新）：

```powershell
python -c "import sqlite3; print(1)"
# 必须输出 1
```

> ⚠️ **不要用 Microsoft Store 的 python。** 那是应用执行别名（存根），没装 Python 时
> 它会弹商店并以 9009 静默退出。ccr-claude 会主动跳过
> `%LOCALAPPDATA%\Microsoft\WindowsApps\` 下的 python，所以你装了存根等于没装。

---

## 2. 装 Claude Code CLI

**官方源：**

```powershell
irm https://claude.ai/install.ps1 | iex
```

**官方源不可达时**，用镜像手动装：

1. 打开 https://github.com/ProjectAILeap/claude-code-releases
2. 找到最新的 `[CLI] Claude Code vX.Y.Z`（**不要**选 `desktop-v*` 开头的，那是桌面客户端）
3. 下载 `claude-<版本>-win32-x64.exe`
4. 校验（同页 `sha256sums.txt` 里有对应值）：

```powershell
Get-FileHash .\claude-<版本>-win32-x64.exe -Algorithm SHA256
# 与 sha256sums.txt 中该行的哈希逐字比对
```

5. 装：

```powershell
.\claude-<版本>-win32-x64.exe install
```

> **这一步需要联网**，见下面的「离线安装」。官方源连不上时它会失败在第 5 步。

> **镜像的信任边界**：`sha256sums.txt` 是镜像自己生成的，只能证明「下载没损坏、与该 tag 自洽」，
> **不能证明上游没被改动**。能访问官方源时，建议对照官方
> `https://downloads.claude.ai/claude-code-releases/<版本>/manifest.json` 里的 `checksum`。
> （2026-11-01 实测：镜像 v2.1.316 的 `win32-x64` 哈希与官方 manifest 完全一致。）

**验证：**

```powershell
claude --version
# 期望：2.1.xxx (Claude Code)
```

装完后 `claude.exe` 在 `%USERPROFILE%\.local\bin\claude.exe`。

> **到这里先别急着 `/login`。** 如果你打算用 CCR，`claude` 不需要登录官方账号——
> 后面的 `ccr-claude` 会用自己的网关和 profile 密钥启动它。装完 §3–§5 再回来验证即可。
> 现在 `claude --version` 有输出就说明 CLI 本身没问题，继续下一步。

### 离线安装（官方源完全连不上时）

两种典型报错，含义不同：

```
# A. 立即失败 —— 连接被拒绝（防火墙/被墙）
Failed to fetch version from .../latest after 3 attempt(s):
connect ECONNREFUSED 35.190.46.17:443

# B. 卡 10 秒后失败 —— 丢包超时（网络静默丢弃）
✘ Installation failed
timeout of 10000ms exceeded
Try running with --force to override checks
```

`35.190.46.17` 是 Google Cloud 的地址（`downloads.claude.ai` 托管在 GCS 上）。
**`install` 在 "Checking installation status..." 阶段就要联网**，所以文件在手里也可能失败。

> ⚠️ **别被那行 `Try running with --force` 误导。** `--force` 不是「跳过下载」，它是
> **跳过「已安装」的检查去强制重装**——也就是更确定地走网络。实测：断网时
> `install --force` 直接失败，而**不加** `--force` 反而能靠本地缓存成功。

#### 首选：`windows\install-claude.ps1`（一条命令）

仓库自带一个独立的安装脚本，专门解决这个问题：**下载好 exe 之后，它不需要任何网络
就能装完**。它做的事和 `install` 一样（放二进制、加 PATH），但会先校验再写。

**最简用法**——在下载目录里直接跑，不用传路径：

```powershell
cd $env:USERPROFILE\Downloads
.\install-claude.ps1 -Apply
```

脚本会自动找 `claude-<版本>-win32-x64.exe`，依次搜：**当前目录 → 脚本所在目录 →
`Downloads`**。找到多份时用最新的那个（并列出全部，让你确认没选错）。

不想直接写就先去掉了 `-Apply` 跑一次，它只打印计划、把哈希算一遍，不写任何东西：

```powershell
.\install-claude.ps1
```

**完全离线**（连 `sha256sums.txt` 都拉不到）时，把哈希直接传进去：

```powershell
.\install-claude.ps1 -Apply `
    -ExpectedHash e896a9d8da519353a49bf69ca4a695ba7e09067752687c675b3969041e632d52
```

脚本在动手前会拦下两类最容易出事的输入：

- **不是 Windows 可执行文件**（没有 `MZ` 头）——被墙时下载常把 HTML 错误页存成 `.exe`
- **哈希不符**——文件损坏、被替换、或下错了平台/版本

版本号从文件名解析，所以文件名必须是发布时的形式（`claude-<版本>-win32-x64.exe`）。
路径也可以显式给：`.\install-claude.ps1 <路径> -Apply`。

其他开关：

| 开关 | 作用 |
| --- | --- |
| `-Cache` | 额外写入 `~\.local\share\claude\versions\<版本>`，让以后 `install <版本>` 能离线工作 |
| `-HardLink` | 配合 `-Cache`，用硬链接代替第二份拷贝（须同一分区） |
| `-SumsUrl` | 换一个 `sha256sums.txt` 地址 |
| `-SkipHashCheck` | 跳过哈希校验（不推荐） |

脚本是幂等的：已经装好同一份文件时重跑不会重写，PATH 也不会重复添加。

#### 手工等价操作

不想跑脚本就手做，效果一样：

```powershell
# 1. 校验（见同页 sha256sums.txt；2026-11-01 的 2.1.316 win32-x64 应为：）
Get-FileHash .\claude-2.1.316-win32-x64.exe -Algorithm SHA256
# e896a9d8da519353a49bf69ca4a695ba7e09067752687c675b3969041e632d52

# 2. 放到 .local\bin\claude.exe
New-Item -ItemType Directory -Force "$env:USERPROFILE\.local\bin" | Out-Null
Copy-Item .\claude-2.1.316-win32-x64.exe "$env:USERPROFILE\.local\bin\claude.exe"

# 3. 加入用户 PATH（已有就跳过）
$p = [Environment]::GetEnvironmentVariable('Path','User')
if ($p -notlike "*\.local\bin*") {
    [Environment]::SetEnvironmentVariable('Path', "$env:USERPROFILE\.local\bin;$p", 'User')
}

# 4. 新开终端验证
claude --version
```

**实测结论**：在代理指向不可路由地址（外网完全不通）的条件下，只放 `\.local\bin\claude.exe`
一个文件即可正常启动：`--version` 0.4 秒返回 `2.1.316 (Claude Code)`，`claude -p` 3.3 秒
正常响应。**唯一代价是程序无法自我更新**，对配合 CCR 使用的场景没有影响。

#### 次选：让 `install` 走本地缓存

`install` 会**先检查本地有没有该版本**。缓存就绪时它不联网：

```powershell
$ver = '2.1.316'
$exe = ".\claude-$ver-win32-x64.exe"
$cache = "$env:USERPROFILE\.local\share\claude\versions"
New-Item -ItemType Directory -Force $cache | Out-Null
Copy-Item $exe "$cache\$ver"

# 注意：用带 .exe 的原始文件调用。缓存文件没有扩展名，
# PowerShell 不会把它当可执行文件（报「无法在管道中间运行文档」）
& $exe install $ver

# 千万不要加 --force：那会强制重新下载
```

> **版本号必须精确匹配。** `install latest` / `install stable` 会去联网解析，断网照样失败。

这条路依赖一个前提：`install` 的本地检查确实能通过。你新机报的是 「Checking installation
status 阶段 10 秒超时」，说明**连这个本地检查都在等网络**，所以它可能仍然失败——
那就用上面的手工方案，效果一样。

#### 装完统一处理

关掉自动更新，免得它反复尝试联网（`%USERPROFILE%\.claude.json`）：

```json
"autoUpdates": false
```


---

## 3. 装 CCR Desktop

下载并运行安装包（当前最新 v3.1.3，99 MB）：

```
https://github.com/musistudio/claude-code-router/releases/download/v3.1.3/Claude-Code-Router_3.1.3.exe
```

装完启动它。配置会落在：

```
%APPDATA%\claude-code-router\config.sqlite
```

> CCR 在 v3 已从旧的 `config.json` 迁移到 SQLite。ccr-claude 两个版本都支持自动发现，
> 但只读 `config.sqlite`。

---

## 4. 在 CCR 里配置（**这步必须手填**）

### 4.1 加供应商

CCR → **供应商** → 添加，以智谱为例（国内直连快）：

| 字段 | 值 |
| --- | --- |
| 类型 | `openai_chat_completions` |
| Base URL | `https://open.bigmodel.cn/api/paas/v4` |
| API Key | 你自己的 Key |
| 模型 | `glm-5.3-flash` / `glm-5.3` / `glm-5.3-flashx` |

备选 DeepSeek：Base URL `https://api.deepseek.com`，模型 `deepseek-flash` / `deepseek-v4-pro`。

### 4.2 启用 Claude Code Agent

CCR → **服务** → 确认网关已启动、监听 `127.0.0.1:3456`。
然后 **Agent 配置** → 选 Claude Code → 指定模型 → 应用。

### 4.3 验证网关活着

```powershell
curl.exe -s http://127.0.0.1:3456/health
# 期望：{"runtimeId":"...","status":"ok",...}
```

---

## 5. 装 ccr-claude 启动器

### 5.1 获取

**方式 A：git clone（推荐，无 MOTW 问题）**

```powershell
git clone https://github.com/zbn297427669/ccr-claude.git C:\tools\ccr-claude
```

**方式 B：下载发布包**

从 https://github.com/zbn297427669/ccr-claude/releases/latest 下
`ccr-claude-v0.2.1-windows.zip`，解压到**本地盘**（不能放 `\\wsl.localhost\...` 这类 UNC 路径，
`RemoteSigned` 策略下那儿 `.ps1` 根本跑不起来）。

解压后**必须**先清掉 Mark of the Web，否则 `.ps1` 会报 `SecurityError: UnauthorizedAccess`：

```powershell
cd <解压目录>\ccr-claude-v0.2.1-windows
Get-ChildItem -Recurse -Include *.ps1, *.cmd | Unblock-File
```

### 5.2 安装

```powershell
cd C:\tools\ccr-claude

# 先试运行：只打印计划，不写任何东西
.\windows\install.ps1

# 确认无误后写入
.\windows\install.ps1 -Apply
```

`-Apply` 会：

- 把 `windows\` 加进用户 PATH
- 把 `CCR_CLAUDE_EXE` 指向 `claude.exe`（不必和脚本同目录）
- 写入前备份原值到 `%LOCALAPPDATA%\ccr-claude\install-backup-<时间>.txt`

### 5.3 看懂 Preflight

试运行和 `-Apply` 都会先打印一段前置检查：

```
Preflight (what the launcher needs at run time):
  ok   python with sqlite3: C:\Python312\python.exe
  ok   CCR data dir: C:\Users\me\AppData\Roaming\claude-code-router
  ok   gateway reachable: http://127.0.0.1:3456
```

标 `!` 的项会跟一行 `fix:`，照它做。它**只报告、不中断**——先装启动器、后配 CCR 是合法顺序。
不想看就加 `-SkipChecks`。

### 5.4 验证

**新开一个终端**（当前窗口的 PATH 还是旧的）：

```powershell
where ccr-claude
ccr-claude --list-profiles
```

期望看到 `TOKEN` 列为 `yes` 的 profile，例如：

```
ID                       NAME                         ENABLED TOKEN  MODEL
claude-code              Claude Code (opencode)       yes    yes    glm-5.3-flash
```

然后真正跑一次：

```powershell
ccr-claude -p "回复 ok"
```

能回答就是成功了。也可以直接 `ccr-claude` 进交互界面。

### 5.5 `claude` 和 `ccr-claude` 是什么关系

**不是切换，是并存。** 两个命令一直在，`ccr-claude` 只是一个包装器：

```
claude       → 直连 Anthropic 官方（要 /login 登录）
ccr-claude   → 读 CCR 的 config.sqlite → 设好网关地址和 profile 密钥 → 调用 claude
```

所以「切到 ccr-claude」只是**换成敲另一个命令**，`claude` 本身不用卸载、不用改。
装 ccr-claude 之前的 `claude` 直连能力完全保留。

日常对照：

| 想做什么 | 用哪个 |
| --- | --- |
| 走 CCR 里的供应商（国产模型、本地模型） | `ccr-claude` |
| 走 Anthropic 官方账号 | `claude` |
| 看 CCR 里有哪些 profile | `ccr-claude --list-profiles` |
| 临时换模型 | `ccr-claude --model <名称>` 或 `ccr-claude --pick-model` |

启动器的状态输出（用了哪个 profile、哪个模型、窗口多大）都走 **stderr**，
只有 Claude 的正文走 stdout，所以 `ccr-claude -p "..." 2>/dev/null` 是安全的。

### 5.6 想退回只直连官方

不想用了就把安装时改的两项撤掉（原值在
`%LOCALAPPDATA%\ccr-claude\install-backup-<时间>.txt` 里）：

```powershell
# 从用户 PATH 里摘掉 ccr-claude 的 windows 目录
$dir = 'C:\tools\ccr-claude\windows'
$p = [Environment]::GetEnvironmentVariable('Path','User')
$new = ($p.Split(';') | Where-Object { $_ -and $_.TrimEnd('\') -ne $dir.TrimEnd('\') }) -join ';'
[Environment]::SetEnvironmentVariable('Path', $new, 'User')

# 清掉 CCR_CLAUDE_EXE
[Environment]::SetEnvironmentVariable('CCR_CLAUDE_EXE', $null, 'User')
```

新开终端后 `ccr-claude` 就没了，`claude` 照常可用。Claude Code 本身完全不受影响。


## 6. 常见故障对照

| 现象 | 原因 | 解决 |
| --- | --- | --- |
| `install` 报 `ECONNREFUSED 35.190.46.17:443` | 官方源连不上，而 `install` 要联网 | 见 §2「离线安装」：手工放置，不要用 `install` |
| `install` 报 `timeout of 10000ms exceeded` | 同上，但网络是丢包而非拒绝 | 同上；**别加 `--force`**，那会强制重新下载 |
| `install --force` 失败（不加反而能过） | `--force` 是强制重装、跳过本地缓存，必然走网络 | 去掉 `--force`，或直接手工放置 |
| `no python on PATH` | 没装 python，或装的是 Store 存根 | 装 python.org / winget 版，新开终端 |
| `no CCR data dir (needs config.sqlite)` | CCR 没装或没启动过 | 装 CCR 并运行一次 |
| `CCR gateway unreachable` | 网关没起 | 开 CCR，确认服务已启动；或加 `--skip-check` |
| `profile "x" has no plaintext client key` | Agent 没保存好 | 去 CCR 重新保存/启用该 Agent |
| `Model "..." is not allowed for this profile` | 模型名不在白名单 | 在 CCR 里把该模型加进 profile 白名单，注意逐字匹配 |
| `.ps1` 报 `SecurityError: UnauthorizedAccess` | 下载的 zip 带 MOTW | `Get-ChildItem -Recurse -Include *.ps1,*.cmd \| Unblock-File` |
| `.ps1` 报 UNC 路径相关错误 | 仓库放在了 WSL 共享路径 | 挪到本地盘（如 `C:\tools\`） |
| 按了 Ctrl+C 后终端乱码 | 正常现象 | 新开终端 |
| `irm ... \| iex` 报 cannot locate the repo | 管道执行时 `$PSScriptRoot` 为空 | 这是预期行为，clone 下来跑，或传 `-RepoPath` |
| 装完 `ccr-claude` 提示找不到命令 | 当前终端 PATH 还是旧的 | **新开一个终端**，`where ccr-claude` 确认 |
| `claude` 能跑、`ccr-claude` 不行 | 后者依赖 CCR；两者不是替代关系 | 查 §5.5，先确认网关和 profile 正常 |
| 想改回只用 `claude` | — | §5.6 有撤销步骤，Claude Code 本身不受影响 |

---

## 7. WSL 侧（可选）

如果还要在 WSL 里跑，**Windows 侧必须先装好 CCR 并保持运行**——WSL 通过
`127.0.0.1:3456` 连同一个网关。

```bash
# WSL 里也需要 python3（读同一个 config.sqlite）
sudo apt install -y python3 curl

# 用发布包
tar -xzf ccr-claude-v0.2.1-wsl.tar.gz
cd ccr-claude-v0.2.1-wsl/wsl
chmod +x start-claude.sh
mkdir -p ~/.local/bin
ln -sfn "$(pwd)/start-claude.sh" ~/.local/bin/ccr-claude

ccr-claude --list-profiles
```

> WSL 侧脚本会跨 `/mnt/c` 自动发现 Windows 的 CCR 数据目录，不需要额外配置。

---

## 8. 不要做的事

**别把旧机器的 `~/.claude` 整个拷过来。**

那份 `settings.json` 里的 hooks、`apiKeyHelper`、`statusLine` 全是**绝对路径**，
写死了旧机器的用户名和目录。新机用户名不同时它们会静默失效（不报错，只是不执行）。

正确做法是让新机的 CCR 和 ccr-claude 自己生成配置。需要的话再单独装对应组件。

另外，旧 `settings.json` 里如果残留这两项，**别抄**：

- `CLAUDE_CODE_MAX_CONTEXT_TOKENS` —— 启动器会自己算并通过 `--settings` 覆盖层压回去
- `CLAUDE_CODE_DISABLE_UNKNOWN_MODEL_WINDOW_ENFORCEMENT=1` —— 这个值会**关掉 autocompact**，
  会话会一路长到引擎拒绝为止，且没有任何提示

---

## 9. 装完后的核对清单

```powershell
# 1. python 带 sqlite3
python -c "import sqlite3; print(1)"

# 2. claude 可用
claude --version

# 3. 网关活着
curl.exe -s http://127.0.0.1:3456/health

# 4. 启动器就位
where ccr-claude

# 5. profile 有密钥
ccr-claude --list-profiles

# 6. 真正跑一次
ccr-claude -p "回复 ok"
```

六条全过，环境就完整了。

每条的含义：

| # | 验证什么 | 不通过的典型原因 |
| --- | --- | --- |
| 1 | python 能读 SQLite | 装的是 Store 存根，或没新开终端 |
| 2 | CLI 二进制完整 | 下载损坏；对比 sha256 |
| 3 | CCR 网关在跑 | CCR 没启动，或服务没开 |
| 4 | 启动器进了 PATH | 装完没新开终端 |
| 5 | profile 有明文密钥 | CCR 里 Agent 没保存/没启用 |
| 6 | 端到端通了 | 供应商 Key 错、模型名不在白名单 |

第 6 条通过后，日常用 `ccr-claude`；需要直连官方时仍可敲 `claude`，两者并存。详见 §5.5。

---

## 附：版本与来源

| 组件 | 本文对应版本 | 来源 |
| --- | --- | --- |
| Claude Code | 2.1.316 | https://claude.ai/install.ps1 |
| CCR Desktop | 3.1.3 | https://github.com/musistudio/claude-code-router/releases |
| ccr-claude | 0.2.1 | https://github.com/zbn297427669/ccr-claude/releases |

> 上下文窗口相关的实测数据（`effectiveWindow = MAX − 20000` 等）对应 Claude Code 2.1.310，
> 细节见 ccr-claude 仓库的 `CONTEXT-WINDOW.md`。
