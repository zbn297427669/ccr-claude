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
├── CONTEXT-WINDOW.md    为什么窗口要由启动器自己传
├── CHANGELOG.md         每个版本改了什么
├── RELEASING.md         怎么发版、发布包必须包含什么
├── LICENSE              MIT
├── .github/workflows/
│   └── check.yml        两个启动器内嵌代码的语法检查
├── tools/
│   └── check.py         同一套检查，本地可跑
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

## 快速开始

**Windows**（PowerShell）——仓库 clone 到本地盘，然后：

```powershell
.\windows\install.ps1 -ClaudeExe 'C:\path\to\claude'   # 试运行，只打印计划
.\windows\install.ps1 -ClaudeExe 'C:\path\to\claude' -Apply
```

第二条会把 `windows\` 加进用户 PATH，把 `CCR_CLAUDE_EXE` 指向 `claude.exe`
实际所在的位置（不必和脚本同目录），并在写入前备份这两项原值。

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
