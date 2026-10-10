# ccr-claude (`start-claude.sh`)

[English](./README.md) | [简体中文](./README.zh-CN.md)

在 Linux / WSL 上通过本地 [Claude Code Router (CCR)](https://github.com/musistudio/claude-code-router) 网关启动 [Claude Code](https://code.claude.com/)，并复用 CCR 桌面端里的 Agent 配置。

## 为什么需要它

CCR 桌面端会把各 Agent 的客户端密钥、模型等写在本机（常见是 Windows）。本脚本在运行时自动发现这些数据，让 WSL / Linux 能直接启动 `claude`，而无需在脚本里写死密钥或用户路径。

## 应用场景

适合：**已经在用 CCR 做本地网关**，又希望在 Unix shell 里用 **Claude Code CLI** 复用同一套 Agent。

| 场景 | 能解决什么 |
| --- | --- |
| **Windows 跑 CCR，WSL 里用 Claude Code** | CCR 桌面端在 Windows 监听网关（如 `localhost:3456`）；你在 WSL 项目目录工作，用 `ccr-claude` 启动，而不用每次手动 `export` 一堆环境变量。 |
| **多个 CCR Agent / 多家上游** | 例如一个 Agent 走国内模型，另一个走 DeepSeek。脚本会列出 CCR 里 **已启用** 的 Claude Code Agent，用序号选择，或用 `--profile` 指定。 |
| **启动器可开源，凭证留在本机** | 仓库不包含密钥和本机用户名；每台机器运行时读取自己的 CCR `config.sqlite` / profile 辅助脚本。 |
| **任意项目目录启动** | 安装到 `PATH` 后，`cd` 进任意仓库再运行 `ccr-claude`，当前目录即为 Claude Code 的项目根目录。 |

### 运行前提

- CCR 网关已启动且可访问（默认 `http://127.0.0.1:3456`）
- CCR 中至少有一个 **已启用** 的 Claude Code Agent，并具备有效的客户端密钥与模型
- Linux / WSL 侧已安装官方 `claude` CLI

### 不在范围内

- 替代 CCR 桌面端做供应商 / Agent 配置
- **不经过 CCR** 直连 Anthropic 或其他上游
- 在 WSL 内直接使用 Windows 专用的 `ccr-app "…"`（本脚本是对应的 Linux/WSL 启动方式）

## 安装

```bash
chmod +x start-claude.sh
ln -sfn "$(pwd)/start-claude.sh" ~/.local/bin/ccr-claude
```

依赖：`bash`、`python3`、PATH 中的 `claude`，以及已启动的 CCR 网关。

## 用法

```bash
ccr-claude                 # 多个 enabled Agent 时交互选序号
ccr-claude --list-profiles
ccr-claude --profile <id-或-名称片段>
ccr-claude --model <名称>
```

## 配置（仓库内不含密钥）

| 变量 | 作用 |
| --- | --- |
| `CCR_DIR` | CCR 数据目录（含 `config.sqlite`） |
| `CCR_BASE_URL` | 网关地址（未设置时从 CCR 配置读取） |
| `CLAUDE_CONFIG_DIR` | 全局 Claude `settings.json` 所在目录 |
| `CCR_PROFILE` / `--profile` | 指定 Agent |
| `CCR_NO_PICK=1` | 不弹出选择菜单 |
| `MODEL` / `--model` | 临时覆盖模型 |

### `CCR_DIR` 自动发现顺序

1. 若已设置 `$CCR_DIR`  
2. `$XDG_CONFIG_HOME/claude-code-router` 或 `~/.config/claude-code-router`  
3. `~/AppData/Roaming/claude-code-router`  
4. WSL：第一个存在 `config.sqlite` 的 `/mnt/c/Users/*/AppData/Roaming/claude-code-router`

### 运行时读取的字段（不要提交进 Git）

| 字段 | 来源 |
| --- | --- |
| Profile 列表 / enabled / 模型 | `config.sqlite` → `app_config.default.profile.profiles` |
| 客户端密钥 | `api_keys` 中 `profile:<id>`，或 `bin/ccr-claude-code-api-key-<id>.cmd` |
| 网关地址 | `routerEndpoint` / `gateway.host:port` |
| 全局 settings 中的模型 | `$CLAUDE_CONFIG_DIR/settings.json`，或由路径推导的 `…/Users/<name>/.claude` |

CCR 长模型名（如 `Provider/model[1m]`）会规范成上游短名（`model`）。

## 安全说明

- 不要把 `ccr-profile-…` 密钥、上游 API Key 或本机绝对路径写进脚本。  
- 密钥仅通过 `ANTHROPIC_AUTH_TOKEN` 传给子进程 `claude`。  
- 状态输出只打印 profile id 与模型名，不打印密钥。  
- 若某 profile 返回 401，请在 CCR 桌面端重新保存/启用该 Agent（或重启网关），不要把密钥贴进 Git。

## 许可

可自由使用与修改；不做任何担保。
