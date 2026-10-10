# ccr-claude (`start-claude.sh`)

[English](./README.md) | [简体中文](./README.zh-CN.md)

在 Linux / WSL 上通过本地 [Claude Code Router (CCR)](https://github.com/musistudio/claude-code-router) 网关启动 [Claude Code](https://code.claude.com/)，并复用 CCR 桌面端里的 Agent 配置。

## 为什么需要它

CCR 桌面端会把各 Agent 的客户端密钥、模型等写在本机（常见是 Windows）。本脚本在运行时自动发现这些数据，让 WSL / Linux 能直接启动 `claude`，而无需在脚本里写死密钥或用户路径。

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
