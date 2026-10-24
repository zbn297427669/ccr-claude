# ccr-claude — Windows 版（`ccr-claude.ps1`）

[English](./README.md) | [简体中文](./README.zh-CN.md) | [全平台总览](../README.zh-CN.md)

`ccr-claude.ps1` 是正式入口，`ccr-claude.cmd` 只是双击 / cmd 用的薄壳。两者对等：
同样从 CCR 的 `config.sqlite` 发现 profile、密钥、网关地址和模型窗口，脚本里不含
任何密钥或本机路径。

## 为什么推荐直接跑 .ps1

`.cmd` 用 `%*` 转发参数，批处理会在传参前**无条件做一次百分号展开**，而且关不掉
（`EnableDelayedExpansion` 也不行）。实测同一个调用方、同一个参数：

```
输入: 50% off and PATH=%PATH% done
.cmd → 50% off and PATH=C:\WINDOWS\system32;...\GitHub CLI done
.ps1 → 50% off and PATH=%PATH% done
```

`call ccr-claude.cmd` 还会二次解析，参数里的 `>` 会多出一个 `^`。`.ps1` 没有这
一层：参数从 `$args` 原样取得，直接交给 claude。

所以：**传代码片段、正则、含 `%` 的文本时用 `.ps1`**；双击启动、或在 cmd 里敲命令
时 `.cmd` 仍然好用。两者退出码都如实透传（成功 0，出错非 0）。

## 装成命令：`ccr-claude`

把 `windows` 子目录加到用户 PATH 一次，两个 shell 就都能直接敲 `ccr-claude`
（下面把仓库位置写成 `<repo>`，换成你自己的路径）：

```powershell
$repo = '<repo>'   # 例如 C:\tools\ccr-claude
[Environment]::SetEnvironmentVariable(
  'Path', "$repo\windows;" + [Environment]::GetEnvironmentVariable('Path','User'), 'User')
```

新开的终端里生效。之后不用写路径、不用指定解释器：

```bat
ccr-claude                       :: PowerShell 解析到 ccr-claude.ps1
ccr-claude --pick                :: cmd 解析到 ccr-claude.cmd
where ccr-claude                 :: <repo>\windows\ccr-claude.cmd
```

同名两个文件不用做任何包装：PowerShell 的 `Get-Command` 按 `PATHEXT` 优先取 `.ps1`，
cmd 的 `where` 取 `.cmd`。**在 PowerShell 里敲 `ccr-claude` 走的是 `.ps1`**，上面
关于 `%*` 的两个坑自动绕开。

### claude.exe 不必和脚本同目录

脚本按这个顺序找 `claude`：

1. `CCR_CLAUDE_EXE` —— 指向 exe 本身，或指向含 `claude*` 可执行文件的目录
2. `PATH` 上的 `claude`
3. 脚本同目录的 `claude-*-win32-x64.exe`

只留下载好、并留在原处的 exe，然后：

```powershell
[Environment]::SetEnvironmentVariable(
  'CCR_CLAUDE_EXE', 'C:\path\to\claude', 'User')   # 目录，或直接写 exe 的完整路径
```

早先只能靠第 3 条，于是脚本被迫和 296MB 的 exe 手抄到一个目录里，仓库一更新
那个副本就过期。现在脚本留在仓库里跟着 git 走，exe 留在原处。

## 用法

```bat
:: 推荐
powershell -NoProfile -File <repo>\windows\ccr-claude.ps1 -p "解释这个仓库"

:: 双击 / cmd 里
<repo>\windows\ccr-claude.cmd
<repo>\windows\ccr-claude.cmd --pick
<repo>\windows\ccr-claude.cmd --pick-model
<repo>\windows\ccr-claude.cmd --list-profiles
<repo>\windows\ccr-claude.cmd --profile <id>       :: 或设 CCR_PROFILE
<repo>\windows\ccr-claude.cmd --model XM/bonsai-heretic
<repo>\windows\ccr-claude.cmd --context-window 262144
<repo>\windows\ccr-claude.cmd --skip-check
<repo>\windows\ccr-claude.cmd --continue
<repo>\windows\ccr-claude.cmd --resume
```

启动器自己的开关一律用双横线；`-p`、`--model`、`--continue` 等其余参数全部原样
交给 `claude`。之所以不声明 PowerShell `param` 块，是因为 PowerShell 按前缀匹配参数，
一旦声明 `-ProfileId`，`claude` 自己的 `-p` 就会被抢走（实测报
`AmbiguousParameter`）。

启动信息（profile / 模型 / 窗口）写到 **stderr**，回答写到 stdout。所以
`2>/dev/null` 只留模型输出，`2>&1` 才看得到诊断。

### 两个菜单

**profile 菜单**：CCR 里有多于一个可用的 Claude Code Agent 时出现，上次用过的排第一
并标 `(last)`。静默条件：只有一个可用 profile、stdin 不是终端、`CCR_NO_PICK=1`、
转发参数里有 `-p`/`--print`。`--pick` 可以强行让它出现。

**模型菜单**：profile 的 `availableModels` 里有两个以上模型时出现，当前模型排第一并标
`(current)`，直接回车就是保持现状。列表同时就是网关的准入清单——菜单里列出来的网关
一定接受；显示的是短名（`/` 之后、去掉 `[1m]`），传给 Claude Code 的是完整 CCR 名。
静默条件和 profile 菜单一样，外加"只有一个模型"；`--pick-model` 可以越过全部四条。

`MODEL` / `--model` 已经指定了模型时，模型菜单不出现——那是显式覆盖。

## 它做了什么

| 项 | 来源 |
| --- | --- |
| CCR 数据目录 | `CCR_DIR`，否则 `%APPDATA%\claude-code-router` |
| 网关地址 | `CCR_BASE_URL`，否则 config 里的 `routerEndpoint`，否则 `gateway.host:port` |
| 客户端密钥 | `api_keys` 表（仅 `encryption == plain`），否则 `bin\ccr-claude-code-api-key-<pid>.cmd` 里的 `ccr-profile-…` |
| 模型 | `--model` / `MODEL` / profile 的 `model` / 菜单选择 |
| 上下文窗口 | CCR 的 `modelMetadata.contextWindow` → 回环 `/v1/models` → `models.json`（`limits.contextTokens`）→ 每机 catalog，详见 [CONTEXT-WINDOW.md](../CONTEXT-WINDOW.md) |
| `claude` 可执行文件 | `CCR_CLAUDE_EXE` → `PATH` → 脚本同目录 |

密钥只在运行时读取，写进进程环境变量，不落盘。`python` 是必需的：PowerShell 没有
内置 SQLite，读库靠它，三个库文件（含 `-wal`/`-shm`）先拷到临时目录再只读打开，不
锁 CCR。

## 六个必须知道的坑

### 1. `settings.json` 的 `env` 盖过进程环境变量

实测：进程里 `ANTHROPIC_BASE_URL=…:3456`，`settings.json` 的 `env` 写 `…:1`，
请求打到 `:1` 并 `ECONNREFUSED`。也就是说 CCR 生成的 wrapper 和用户已存的
`settings.json` 里的 `CLAUDE_CODE_MAX_CONTEXT_TOKENS` 会把启动器设的值全部吃掉。

所以启动器额外生成一份 `%LOCALAPPDATA%\ccr-claude\settings.json`，用
`--settings` 传进去。实测 `--settings` 的 `env` 能压过 `settings.json` 的 `env`
（同一个坏地址实验，加上覆盖层后正常连上 `3456`）。覆盖层只写非密钥项，token 仍
只走进程环境变量。

> 例外：`ANTHROPIC_AUTH_TOKEN` 不受影响——实测进程里的 token 能压过
> `settings.json` 的 `apiKeyHelper`（故意给个假 token 会 401，说明用的是进程里的）。

### 2. 模型名必须命中网关缓存，否则 autocompact 不跑

`~/.claude/cache/gateway-models.json` 里没有的模型名，Claude Code 会整段跳过
autocompact 的阈值检查，会话一路长到引擎拒绝为止。缓存里是长名：

```
OD/deepseek-v4.1-flash  ->  anthropic/claude-ccr-h4f442f646565707365656b2d76342e312d666c617368
```

`h` 后面是原始名的十六进制（`4f442f` = `OD/`），可逆。启动器做两件事：

- 把用户给的短名 / display_name 折算成缓存里的 `id` 再设 `ANTHROPIC_MODEL`；
- 把用户直接抄来的长名反解成 `OD/deepseek-v4.1-flash` 去查供应商和窗口。

`[claude-code:unrecognized_model]` 是 telemetry 日志，不是错误，请求正常返回。

### 3. 覆盖层里必须把 `apiKeyHelper` 置空

`settings.json` 里有 `apiKeyHelper`，启动器又把 token 放进 `ANTHROPIC_AUTH_TOKEN`，
TUI 就会挂一条横幅：

```
Both ANTHROPIC_AUTH_TOKEN and apiKeyHelper set · auth may not work as expected
```

2.1.310 的判定是 `ua().source !== "none" && kp().source !== "none"`。`Ng()` 的第一行
是 `return pe("flagSettings")?.apiKeyHelper`，而 `--settings` 正属于 flagSettings——
所以在覆盖层里写 `"apiKeyHelper": ""` 就能让它返回假值，两条来源都落到 `none`，
横幅不成立，helper 也不会被执行（marker 探针实测：设真值时 CALLED，设空串时
NOT-CALLED）。

**不能写 `null`**：`apiKeyHelper: [REDACTED] string, but received null` —— 这条设置
会被判非法直接丢弃并报 ERROR。

### 4. 菜单里的 `Custom …` 要传 CCR 名，不能传 display_name

`ANTHROPIC_DEFAULT_{OPUS,SONNET,HAIKU,FABLE}_MODEL` 决定 `/model` 菜单那几条的
显示文本。传缓存长名 `anthropic/claude-ccr-h<hex>` 就是一堆编号，所以启动器先
反解成 CCR 名再传。

但**不能**传缓存里的 `display_name`（`Go/DeepSeek V4 Flash (1M context)`）：实测网关
只认 CCR 短名和长名，`display_name` 和伪造名字一样直接 403——菜单选它发不出请求。
反解出来的 `OD/deepseek-v4.1-flash` 既可路由又是人话。

反解时要保住 `[1m]` 后缀（`Go/deepseek-v4-flash[1m]` 和 `Go/deepseek-v4-flash` 在网关
是两个条目），并且函数里的局部变量别叫 `$m`——PowerShell 变量名大小写不敏感，
`$m` 就是参数 `$M`，`Substring` 会把原始值一起改掉。

### 5. `$ErrorActionPreference='Stop'` 会被 stderr 重定向变成致命错误

claude 往 stderr 写 telemetry。当**调用方**把 stderr 重定向掉（`2>$null`、`2>&1`）时，
PowerShell 5.1 会把 native 程序的每一行 stderr 记成 `NativeCommandError`。脚本本身开了
`$ErrorActionPreference = 'Stop'`，于是这行日志在往外抛的那一刻就中断了调用方。

症状很误导：直接 `powershell -File ccr-claude.ps1` 一切正常，被别的脚本 `&` 调用就断在
启动那一行，看起来像启动器挂了。

所以启动器在 `& $ClaudeExe` 前后临时放宽：

```powershell
$ErrorActionPreference = 'Continue'
& $ClaudeExe @PassArgs
$rc = $LASTEXITCODE
$ErrorActionPreference = 'Stop'
exit $rc
```

自己在脚本里调用 `ccr-claude.ps1` 时如果也踩到，按同样方式处理，或改用 `.cmd`。

### 6. 管道喂给 python 的代码受 `$OutputEncoding` 摆布

早期版本用 `$Code | python -` 传递内嵌的 Python 代码。这条管道会按
**`$OutputEncoding`**——一个**会话级**变量——把文本编码成字节流。同一个脚本，
在不同终端里结果完全不同：

| `$OutputEncoding` | 结果 |
| --- | --- |
| UTF-8（有无 BOM 皆可） | ✅ |
| ASCII | ✅（代码全 ASCII 时） |
| GB2312 / GB18030 | ❌ `SyntaxError: Non-UTF-8 code ... on line 76` |
| UTF-16 / UTF-16BE | ❌ `SyntaxError ... starting with '\xff' on line 1` |

代码里有中文注释，所以 GB2312 会在注释那一行炸；UTF-16 则连 BOM 都对不上，报在
第 1 行。配合 `2>$null`，你只会看到一行 `python.exe : File "<stdin>", line 1`，
真正的原因被吞掉了。

现在改成写临时文件（UTF-8 无 BOM，路径用 GUID 防撞），跑完即删，编码自己定死。
`Find-Python` 同时跳过 `WindowsApps` 下的应用执行别名（微软商店存根，rc=9009），
并用 `import sqlite3` 探针确认是真解释器。

## 与 WSL 版的差异

- **参数透传规则不同**：这里启动器自己的开关全用双横线（`--pick`、
  `--list-profiles`），其余参数一律原样交给 `claude`；原因是 PowerShell 的参数绑定
  按前缀匹配，声明了 `-ProfileId` 之后 `-p` 就归它了。
- **多了 `--settings` 覆盖层**：WSL 侧的 `settings.json` 是脚本自己写的，不必对抗；
  Windows 侧的用户 `settings.json` 由 CCR 生成，会反过来盖掉环境变量，只能靠
  `--settings` 压回去。
- **本文件必须是 UTF-8 with BOM**：PowerShell 5.1 读无 BOM 的 `.ps1` 会按 GBK 解码，
  中文注释变乱码，甚至解析失败。

## 已知缺口：本地模型的窗口

`XM/bonsai-heretic` 在 CCR 的 `modelMetadata` 里 `contextWindow` 为空，引擎没启动时
`/v1/models` 也问不到。此时启动器**不设** `CLAUDE_CODE_MAX_CONTEXT_TOKENS`（宁可留空
也不猜），Claude Code 会按 200000 的默认值算。

按 `ninfer\launcher\config.bat`，当前引擎变体是 `ternary`、窗口配到 524288；换成
`kvmem-0.18.0` 时启动器会把它压到 262144。要跑满就显式给：

```bat
ccr-claude.cmd --model XM/bonsai-heretic --context-window 524288
```

注意 Claude Code 的换算规则是 **`effectiveWindow = MAX − 20000`**。2.1.310 上**没有**
800000 硬顶（`1000000` 实测给到 `980000`），早期版本笔记里的「780000 天花板」已经
不适用。

### `CLAUDE_CODE_MAX_CONTEXT_TOKENS` 是全局的

它会 clamp **所有**模型，不只当前这个。用户 `settings.json` 里现在写 `128000`
（`OD/deepseek-v4.1-flash` 的真实窗口，CCR 的 `contextWindowPinned` 和每机 catalog
两处都对得上），代价是 `Go/qwen3.8-max` 这种真实 1048576 的模型也被压到 108000。
要用满就显式覆盖：

```bat
ccr-claude.cmd --model Go/qwen3.8-max --context-window 1048576
```
