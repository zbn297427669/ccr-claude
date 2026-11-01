# ccr-claude

[English](./README.md) | [简体中文](./README.zh-CN.md)

通过本地 [Claude Code Router (CCR)](https://github.com/musistudio/claude-code-router) 网关启动 [Claude Code](https://code.claude.com/)，直接复用 CCR 桌面端里已配好的 Agent。

两个平台的启动器，同一套行为：

| 平台 | 入口 | 文档 |
| --- | --- | --- |
| Windows | `windows/ccr-claude.ps1`（附 `ccr-claude.cmd` 薄壳） | [windows/README.zh-CN.md](./windows/README.zh-CN.md) |
| Linux / WSL | `wsl/start-claude.sh` | [wsl/README.zh-CN.md](./wsl/README.zh-CN.md) |

两者都在运行时自己发现 CCR 数据目录、网关地址、profile 的客户端密钥和模型的真实上下文窗口。**仓库里不含任何密钥或本机路径**。

## 为什么要两套

两个平台的坑不一样，补法也就不一样：

- **Linux / WSL** —— `claude` 本来就在 `PATH` 里，启动器的主要工作是从 `/mnt/c` 跨过去找到 Windows 的 CCR 数据库。settings 由脚本自己写。
- **Windows** —— CCR 桌面端生成的 `settings.json` 和 wrapper `.cmd` 会把关键项硬编码进去，而 `settings.json` 的 `env` 又压过进程环境变量。所以 PowerShell 版额外写一份 `--settings` 覆盖层把它们压回来，并且绕开生成的 wrapper。

其余部分——选哪个 profile、哪个模型、窗口多大——两边是同一套逻辑。CCR 没告诉 Claude Code 的那些事、启动器怎么补，见 [CONTEXT-WINDOW.md](./CONTEXT-WINDOW.md)。

## 目录结构

```
.
├── README.md            本文件
├── README.zh-CN.md
├── SETUP.zh-CN.md       全新 Windows 机器的从零安装指南（中文）
├── CONTEXT-WINDOW.md    为什么窗口要由启动器自己传
├── CHANGELOG.md         每个版本改了什么
├── RELEASING.md         怎么发版、发布包必须包含什么
├── LICENSE              MIT
├── .github/workflows/
│   └── check.yml        两个启动器内嵌代码的语法检查
├── tools/
│   ├── check.py         同一套检查，本地可跑
│   └── release.py       发版：检查、打 tag、构建、验证
├── windows/
│   ├── ccr-claude.ps1   正式入口
│   ├── ccr-claude.cmd   双击 / cmd 用的薄壳
│   ├── README.md
│   └── README.zh-CN.md
└── wsl/
    ├── start-claude.sh  正式入口
    ├── README.md
    └── README.zh-CN.md
```

改任一启动器之前先跑检查——它会解析两个脚本里内嵌的 Python，那段代码平时
没有任何解释器从磁盘上读过：

```bash
python3 -I tools/check.py --verbose
```

## 前置要求

> **全新机器？** 看 [SETUP.zh-CN.md](./SETUP.zh-CN.md)：从装 python、装 Claude Code CLI、
> 装 CCR 到 `ccr-claude` 跑通，一步步带验证，含官方源连不上时的离线安装办法。

这个项目是**启动器**，不是安装器。它假定下面三样东西已经在你机器上：

| 需要什么 | 为什么 | 怎么装 |
| --- | --- | --- |
| **运行中的 CCR 网关** | 启动器从它的 `config.sqlite` 里读 profile、密钥、模型和窗口 | [CCR Desktop 下载](https://github.com/musistudio/claude-code-router/releases) |
| **一个已启用的 Claude Code Agent** | 只列「已启用 + 有模型 + 有明文 client key」的 profile | 在 CCR 里加供应商 → 启用 Claude Code Agent |
| **`python3`（带 `sqlite3`）** | PowerShell 和 bash 都没有内置 SQLite，启动器借 python 读库 | Windows：`winget install Python.Python.3.12`<br>WSL/Linux：`sudo apt install python3` |

外加官方的 `claude` CLI 本身（Windows 也可用 `winget install Anthropic.ClaudeCode`）。

两点容易踩的：

- **`python3` 是硬依赖，不是可选项。** 少了它启动器直接退出并报
  `no python on PATH`。Microsoft Store 的那个 `python` 存根**不行**——启动器会主动跳过
  `%LOCALAPPDATA%\Microsoft\WindowsApps\` 下的它（没装 Python 时它弹商店然后静默退出）。
- **厂商 API Key 只有你自己有。** 没有任何脚本能替你在 CCR 里填。所以「一键部署」的
  终点是装好启动器，然后你去 CCR 里填 key。

Windows 上的 `install.ps1` 会替你检查前三项，缺什么直接打印对应的安装命令。

**Claude Code 下载**：官方源 `https://claude.ai/install.ps1`。若官方源不可达，可先用
镜像 `https://github.com/ProjectAILeap/claude-code-releases`（每 4 小时同步官方二进制，
release 里附 `sha256sums.txt`）。镜像的校验和只能证明「下载没损坏、与该 tag 自洽」，
不能证明上游未被改动；能访问官方源时建议对照官方
`https://downloads.claude.ai/claude-code-releases/<版本>/manifest.json` 的 `checksum`。

## 快速开始

**Windows**（PowerShell）——仓库 clone 到本地盘，然后：

```powershell
.\windows\install.ps1 -ClaudeExe 'C:\path\to\claude'   # 试运行，只打印计划
.\windows\install.ps1 -ClaudeExe 'C:\path\to\claude' -Apply
```

第二条会把 `windows\` 加进用户 PATH，把 `CCR_CLAUDE_EXE` 指向 `claude.exe`
实际所在的位置（不必和脚本同目录），并在写入前备份这两项原值。

试运行会先打印一段 **Preflight**，逐项报告 python、CCR 数据目录、网关是否就绪；
缺失项标 `!` 并给出修复命令。它**只报告、不中断**——先装启动器、后配 CCR 也是
合法顺序。确认环境齐备后再加 `-Apply`。

```bat
ccr-claude                      :: 多个 enabled Agent 时选 profile
ccr-claude --pick-model         :: 再选模型
ccr-claude -p "解释这个仓库"
```

**Linux / WSL**：

```bash
cd wsl
chmod +x start-claude.sh
ln -sfn "$(pwd)/start-claude.sh" ~/.local/bin/ccr-claude

ccr-claude --list-profiles
```

## 两边一致的行为

| 概念 | 两个平台的表现 |
| --- | --- |
| 选 profile | 只列 **已启用**、且有模型、有客户端密钥的 Claude Code Agent。上次选择会记住并排第一。 |
| 选模型 | 菜单来自 profile 的 `availableModels`——就是 CCR 网关的准入清单，列出来的都一定能路由。显示短名，传下去的是完整 CCR 名。 |
| 默认不打扰 | 只有一个选项、stdin 不是终端、转发参数里带 `-p`/`--print`、或设了 `CCR_NO_PICK=1` 时都不弹菜单。`--pick` / `--pick-model` 可强制。 |
| 上下文窗口 | 依次问：供应商的 `/v1/models`（仅回环）、CCR 的 `modelMetadata`、每机 catalog。都没有就不设——猜错了压缩点会静默偏移。 |
| 诊断输出 | 启动信息（profile / 模型 / 网关 / 窗口）走 **stderr**，只有 Claude 的回答走 **stdout**，所以 `2>/dev/null` 是安全的。 |

## 安全说明

- 仓库不提交任何 token、上游 API Key 或本机绝对路径。每台机器运行时读自己的 CCR `config.sqlite` 与 profile 辅助脚本。
- 密钥只通过 `ANTHROPIC_AUTH_TOKEN` 传给子进程 `claude`。
- 状态输出只打印 profile id 和模型名，从不打印密钥。
- 某个 profile 返回 401，就去 CCR 桌面端重新保存 / 启用那个 Agent，不要把密钥贴进 Git。

## 许可

[MIT](./LICENSE)
