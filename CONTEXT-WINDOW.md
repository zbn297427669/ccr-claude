# CCR × Claude Code 上下文窗口排查笔记

这份文档记录 2026-10-23 一次完整排查的结论。起因是一个很朴素的问题：
**本地模型的上下文只有 262144，Claude Code 却按 800000 在压缩——它怎么知道窗口多大？**

答案牵扯出 CCR 和 Claude Code 之间一处没有通道的缝隙，以及若干会让人
「以为配好了、其实没生效」的坑。记下来，方便以后遇到同类现象时直接对照。

所有结论都用 `claude --debug --debug-file <file>` 输出的
`autocompact: tokens=… level=… effectiveWindow=<N>` 这一行验证过。
`effectiveWindow` 是 Claude Code 实际使用的窗口，就是它说了算。

---

## 一、两个程序之间没有窗口通道

这是所有问题的根源。

**CCR 知道**每个模型的窗口：它探测供应商的 `/v1/models`，把 `context_window`
存进 `Providers[].modelMetadata`，界面上「上下文窗口（Token）」那一栏显示的就是它。

**Claude Code 也知道**自己该用多大窗口，但它**问不到 CCR**：

| 环节 | 实际情况 |
| --- | --- |
| CCR 的 `/v1/models` 返回给 Claude Code 什么 | 只有 `{id, object, created, owned_by, type}`，**没有窗口字段** |
| Claude Code 的网关缓存 schema | `{id, display_name, server_display_name, icon_url, server_id, …}`，**没有地方放窗口** |
| 二进制里 `context_window` 那 24 处用法 | 全部是状态行的 `used_percentage`，不是用来定窗口的 |

**结论：CCR 面板里那个窗口值是给 CCR 自己看的，改它不会影响 Claude Code 的压缩。**

未识别模型的默认假定是 **200000**（实测：什么都不设时 `effectiveWindow=180000`，
即 200000 − 20000 输出预留）。

---

## 二、真正决定压缩点的是什么

优先级从高到低（全部实测）：

```
顶层 autoCompactWindow                        （settings.json 根级）
  > modelSettings.<完整模型名>.autoCompactWindow
    > CLAUDE_CODE_MAX_CONTEXT_TOKENS          ← 会 clamp 上面两层
      > modelSettings.settings（兜底）
        > 模型默认窗口 − 20000 − 13000
```

几条容易看错的：

- **`modelSettings.settings` 是兜底，不是全局覆盖。** 有具体模型条目时，具体条目赢。
- **顶层 `autoCompactWindow` 才是真正的「一刀切」**，它压过所有 per-model 值。
- **`CLAUDE_CODE_MAX_CONTEXT_TOKENS` 能把 `modelSettings` 里偏大的值压下来。**
  实测：`modelSettings=500000` + `MAX=262144` → `effectiveWindow=242144`。
  这使得「只设一个环境变量」是可行的，不必逐个改 `modelSettings`。

有效窗口 = `窗口 − min(maxOutputTokens, 20000)`；
触发压缩 = `min(⌊有效窗口 × PCT/100⌋, 有效窗口 − 13000)`。

---

## 三、CCR 侧的坑

### 3.1 读 config 必须带上 `-wal`

`config.sqlite` 是 WAL 模式。**只拷主库会读到旧快照**，导致「供应商不存在」
这类误判。排查时先拷齐三个文件：

```bash
cp config.sqlite config.sqlite-wal config.sqlite-shm /tmp/
```

我第一次就是因为漏了 WAL，得出「CCR 里全是云端供应商」的错误结论，
其实本地供应商 `XM` 一直都在。

### 3.2 三个 profile 共用一个 settings 文件

```
default-claude-code     settingsFile=~/.claude/settings.json
claude-code-deepseek    settingsFile=~/.claude/settings.json
claude-code            settingsFile=~/.claude/settings.json
```

- **已启动的进程不受影响**（环境变量在启动那一刻固定）
- 但切换 profile 会**重写这个文件**，两个 profile 会争抢
- 且这个路径是 **Windows 路径**，管不到 WSL 的 `~/.claude/settings.json`

### 3.3 「已自动检测」是 placeholder，不是结果

界面里上下文窗口那栏显示「已自动检测」，对应的代码是：

```jsx
<Fe placeholder={f("Detected automatically")} value={G ?? ""} />
```

`placeholder` = 输入框为空时的灰字。**它不代表已经检测到什么。**
只有供应商探测成功时，值才会真正填进去。

探测的数据源是 `/v1/models` 的 `context_window`。**探测时引擎若没启动，
这次就永远是空的**——它就是空着的。

### 3.4 profile 的模型白名单是精确匹配

`availableModels` 里的名字必须逐字对上，否则：

```
403 Gateway plugin "ccr-router-request-transform" request transform failed:
    Model "XM/bonsai-v3" is not allowed for this profile.
```

白名单里写的是 `XM/ninfer-local`，写成 `XM/bonsai-v3` 就被挡。

### 3.5 `/v1/models` 不列出所有白名单模型

实测：`availableModels` 有三个，`/v1/models` 只返回两个：

```json
{"id":"Go/deepseek-v4-flash"}, {"id":"OD/deepseek-v4.1-flash"}
```

**`XM/ninfer-local` 不在里面**，即使引擎正常在跑（8091 返回 200）。
这直接导致 §4.1 的问题。

### 3.6 本地引擎的模型名和 CCR 里写的不一致

| 位置 | 名字 |
| --- | --- |
| 引擎 `/v1/models` 实际报的 | `bonsai-heretic` |
| CCR provider 的 `models` 字段 | `bonsai-v3` |
| CCR profile 的白名单 | `ninfer-local` |
| Claude Code 的网关别名 | `anthropic/claude-ccr-h584d2f6e696e6665722d6c6f63616c` |

四个名字指同一个模型。排查时对不上号是常态，别以为配置错了。

那个 hex 就是模型名的十六进制：

```bash
python3 -c "print(bytes.fromhex('584d2f6e696e6665722d6c6f63616c').decode())"
# → XM/ninfer-local
```

### 3.7 `managedCompact` 会让 Claude Code 的压缩完全不跑

profile 里 `managedCompact: true`（界面上的 **「CCR compact for Claude Code」**）
时，压缩由 CCR 的 context archive 接管。此时 `--debug` 里**完全没有
`autocompact:` 行**——不是值错了，是根本没跑。

排查压缩问题前先确认它是关的。三个 profile 都要关（`contextArchive.enabled`
也会跟着变 `false`）。

### 3.8 wrapper 里的 `CLAUDE_CODE_MAX_CONTEXT_TOKENS` 是硬编码的

CCR 生成 `bin/ccr-claude-code-wrapper-<profile>.cmd` 时会写：

```bat
set CLAUDE_CODE_MAX_CONTEXT_TOKENS=1000000
```

这个值**会被 Claude Code 换算成 980000**（`MAX − 20000`，2.1.310 实测）。
早期版本会截到 800000，现已无此硬顶。

改的地方是 **CCR → 设置 → Claude Code → profile → Environment**，
不是直接改 wrapper（会被重新生成覆盖）。

---

## 四、Claude Code 侧的坑

### 4.1 不在网关列表里的模型，autocompact 整段跳过

这是本次最难发现的一个。

同一个本地模型，用不同名字跑，行为完全不同：

| `--model` 写法 | autocompact 是否运行 |
| --- | --- |
| `anthropic/claude-ccr-h584d2f6e696e6665722d6c6f63616c` | ✅ 运行 |
| `ninfer-local` / `XM/ninfer-local` / `bonsai-v3` | ❌ **完全不检查** |
| `deepseek-v4.1-flash`（云端） | ✅ 运行 |
| `OD/deepseek-v4.1-flash` | ❌ 不检查 |

规律是：**模型名必须在 Claude Code 的网关缓存里有条目**
（`~/.claude/cache/gateway-models.json`），否则压缩检查直接不跑。
而那个缓存是从 CCR 的 `/v1/models` 拉的——见 §3.5，本地模型不在里面。

**后果**：你以为设了窗口就安全了，其实根本没在压缩，会一路撞到引擎的
上下文上限才失败。

### 4.2 `[1m]` 后缀的模型没有 autocompact

`settings.json` 里 `ANTHROPIC_DEFAULT_*_MODEL` 都写成 `Go/deepseek-v4-flash[1m]`。
带 `[1m]` 后缀的模型，`--debug` 里没有 `autocompact:` 行。

### 4.3 `CLAUDE_CODE_MAX_CONTEXT_TOKENS` 的换算

实测映射（Claude Code 2.1.310）：

```
400000 → 380000      700000 → 680000
799999 → 779999      800000 → 780000
800001 → 800001      1000000 → 980000      1048576 → 1028576
```

规则就是 **`effectiveWindow = MAX − 20000`**（20000 是输出预留）。

> **更正（2026-10-24）**：本文早期版本说「800000 是天花板，超过的部分直接丢弃」，
> 那是旧版本的行为。2.1.310 上已无此硬顶，`1000000` 实测给到 `980000`。
> 未设 MAX 时退回模型默认 200000（`effectiveWindow=180000`）。

### 4.4 `CLAUDE_CODE_DISABLE_UNKNOWN_MODEL_WINDOW_ENFORCEMENT=1` 会关掉 autocompact

**更正（2026-10-24）**：本节早期版本说「没关掉 autocompact」，实测是**错的**。

`--debug --debug-file` 输出的 `autocompact: … effectiveWindow=` 这一行：

| 配置 | `autocompact` 行 |
| --- | --- |
| `DISABLE=1` + 任意 MAX | **整行消失**，阈值检查被跳过 |
| `DISABLE=0` | 正常出现，值 = MAX − 20000 |

同一模型、同一 MAX 只翻这一个开关，行为就反转。后果是会话一路长到引擎拒绝为止，
没有任何提示。**保持 `0`。**

### 4.5 `--settings` 是合并，不是替换

用 `--settings /tmp/x.json` 测试时，真实 `settings.json` 里的
`modelSettings` 仍然生效并可能胜出。做隔离实验必须用
`CLAUDE_CONFIG_DIR=<空目录>`，且要预置 `.claude.json`（否则保存配置报
`ENOENT`）。

### 4.6 `modelSettings` 的键名只认完整别名

实测五种写法，只有一种生效：

| 键名 | 是否生效 |
| --- | --- |
| `anthropic/claude-ccr-h584d2f6e696e6665722d6c6f63616c` | ✅ |
| `XM/ninfer-local` / `ninfer-local` / `bonsai-v3` / `bonsai-heretic` | ❌ |

这些键是 `/autocompact` 命令按当时会话的模型名写进去的，所以会随着
历史使用积累出多种形式（`deepseek-v4-flash`、`deepseek-v4.1-flash`、
`settings` 兜底……）。

---

## 五、启动器（`wsl/start-claude.sh` / `windows/ccr-claude.ps1`）的处理

已知 CCR 和 Claude Code 之间没有窗口通道，所以脚本自己补上这一环：
启动前解析出当前模型的真实窗口，通过 `CLAUDE_CODE_MAX_CONTEXT_TOKENS`
传进去（实测它能 clamp 掉 `modelSettings` 里的陈旧值）。

解析顺序（只有这个模型**自己**的名字算候选；供应商里别的模型的元数据不算，
否则邻居在 `models.json` 里的读数会被继承过来）：

1. **CCR 存储的 `modelMetadata.contextWindow`** —— CCR 上次探测的结果
2. **供应商的 `/v1/models`** —— 仅当它是本机回环地址。单模型端点直接采信
   （本地引擎常见：CCR 里叫 `bonsai-v3`，实际答 `bonsai-heretic`）。
   端点返回的窗口字段有五种形状，`window_of()` 全部试一遍：
   平铺的 `context_window` / `contextWindow` / `max_context_window` /
   `max_model_len`、嵌套的 `limits.contextTokens`（CCR 自带目录的形状），
   以及嵌套的 **`meta.n_ctx`**（llama.cpp 系：Strata 的服务器答
   `{"id":…,"meta":{"n_ctx":32768}}`，ninfer 的 ring 构建同理。
   ninfer 自己的 `lib/engine-status.ps1` 也是三种都读）
3. **CCR 自带的总 catalog** `models.json`，读 `limits.contextTokens`
   （`limits.inputTokens` 兜底）。同名对上多条时要求一致：差 10% 以内算同一个
   模型、取小值（只会提前压缩，不会滞后）；差更多说明这名字真是两个东西，
   那份文件就什么也没说
4. **每机 catalog** `~/.codex/ccr-model-catalog.json`。它给没有元数据的模型一律
   写 128000（CCR bundle 里的 `KFe=128e3`）——那是默认值不是读数，所以这一档的
   128000 直接跳过
5. **都没有 → 不设任何值**，让 Claude Code 走自己的链条
   （目录 → `settings.json` 的 `autoCompactWindow` → 200000），并在启动信息里说明

宁可留空也不猜：值猜错了，压缩会在错误的位置静默发生。

模型菜单里每行后面也带这一列（`1.0M` / `128K` / 解析不出时 `unknown`）。
整张菜单一次解析完，不再逐行重读同一个库和目录。

覆盖方式：

```bash
ccr-claude --context-window 131072     # 手动指定（WSL 与 Windows 写法一致）
CCR_CONTEXT_WINDOW=131072 ccr-claude   # 同上，用环境变量
ccr-claude --context-window off        # 关掉自动解析，什么都不设
```

启动时会打印一行，例如：

```
Context window: 262144 tokens
```

解析不到时说：

```
Context window: unresolved here; Claude Code falls back to
                autoCompactWindow in settings.json, else 200000
```

早先这里写的是「Claude Code will assume 200000」，并不对：只有 `settings.json`
也没钉值时才轮到 200000。

### 能力探测：这个模型 Claude Code 能用吗

窗口解析解决「压在哪里」，但还有一层能不能用的问题。Claude Code 每次请求都会给
一个内置占位工具加 `defer_loading: true`，没有 deferred tool loader 的上游会
**拒绝整个请求**（不是拒绝那个工具）。

客户端侧关不掉：

| 尝试 | 结果 |
| --- | --- |
| `--disallowedTools ToolSearch` | 仍然发送 |
| `--disallowedTools ToolSearch DeferredToolPlaceholder` | 仍然发送 |
| `--strict-mcp-config` + 空 MCP | 仍然发送 |

MCP 服务有一个 `alwaysLoad` 逃生舱（等价于 `defer_loading: false`），但只对用户
自己配的 MCP 服务有效，管不到这个内置占位工具。抓包确认，请求里 12 个工具，只有
`DeferredToolPlaceholder` 带这个标记。

所以脚本在启动前发一个最小的探测请求，把结论打在启动信息里，而不是让会话跑到
一半才撞上 400：

```
Tools: UNUSABLE -- this model rejects defer_loading, which Claude Code
       sends on every request. Use a cloud model for now; see
       CONTEXT-WINDOW.md. Set CCR_CAPABILITY_CHECK=off to skip this check.
```

只有上游明确用「不支持 deferred」这类措辞拒绝时才报这句。超时、401、连接不上
都归为「无法确认」，不当作结论——免得把网络问题说成能力问题。

```bash
CCR_CAPABILITY_CHECK=off ccr-claude   # 跳过探测
```

这条针对的是引擎侧的限制（NInfer 明确返回 `deferred_tools_not_supported`），
客户端和 CCR 都改不了。已提 CCR 侧 issue #1912。

---

## 六、多会话并发

多个 Claude Code 会话同时连本地模型，实测结果分两段。

### 能工作，但串行

中间层自己支持并发：`ThreadingHTTPServer` 每请求一线程，3 并发、6 并发、
「长流式 + 两个短请求 + 一个 GET」的混合负载全部成功，互不阻塞。

变慢的是引擎侧。6 个并发请求的单次耗时是 0.5 / 2.0 / 3.2 秒，总耗时 3.2 秒
——**等于最慢那个**，说明请求在引擎里排队。引擎以 `--max-concurrency 1`
启动（`bin\ninfer.bat` 固定传这个值），这是设计如此，不是中间层造成的。

### 出现过一次串话，未能复现

第一轮测试中，三个并发会话要求各自回答「会话1/2/3」，其中会话 2 回答的是
一段完全无关的系统进程描述。之后两轮 6 次全部正确，没有复现。

当时的引擎状态：

```
context cache | 1 active + 1 cached device states | host 8 states | 8.00 GiB KV
              | private 2 | shared 0 | anchors 2
```

`shared 0` 说明共享前缀缓存已经关掉了（`--max-shared-prefixes 0`），所以不是
跨请求共享缓存串味。剩下的可能就是**状态换入换出**：三个请求排队，唯一那个
活跃槽位要反复装卸，偶发地把上一个会话的状态带进了下一个。

这只影响那一次回答的质量，不会崩溃、不会写错数据。但如果你要同时开多个会话
跑重要任务，值得知道它可能发生。

能彻底隔离的做法是多个引擎实例（各占一份显存），代价是显存翻倍——27B 模型
在这个配置下余量不够。`--no-prefix-reuse` 可以进一步降低复用，但会让多轮对话
明显变慢，而且它与现有的 `--max-shared-prefixes` 互斥，需要改启动参数。

---

## 七、还剩下什么没解决

- **§4.1 那个问题脚本补不了。** 本地模型的别名不在网关缓存里，
  autocompact 就不跑——窗口设得再对也没用。这需要在 CCR 侧让
  `/v1/models` 列出 `XM/ninfer-local`，或者让网关给出的 id 带上窗口信息。
- **云端模型的 128000 未必是真的。** CCR 的 per-install catalog 里
  `OD/deepseek-v4.1-flash` 标 128000，但 CCR 自带的总 catalog
  （`models.json`）里同名条目标的是一百万量级。启动器现在按上面第五节的顺序
  解析，并且把 per-install catalog 里的 128000 当占位符跳过，这就是为什么
  `OD/deepseek-v4.1-flash` 解析出的是 1000000 而不是 128000。
- **`Go/qwen3.8-max` 标 1048576（`models.json`），实际压缩点是 `min(窗口, 钉值)`。**
  2.1.310 上没有 800000 硬顶，但用户 `settings.json` 的
  `modelSettings.settings.autoCompactWindow` 若钉了更低的值，运行时会取小。
  要用满必须显式给 MAX（`--context-window 1048576`），它同样会被
  `Math.min` 与钉值取小。

---

## 八、排查用的命令

```bash
# 当前实际使用的窗口与档位
claude --debug --debug-file /tmp/cc.log -p "hi" >/dev/null 2>&1
grep -o "autocompact:[^|]*" /tmp/cc.log

# 引擎自己报的窗口
curl -s http://127.0.0.1:8091/v1/models | python3 -m json.tool | head -20

# CCR 网关给了 Claude Code 什么
curl -s -H "authorization: Bearer $ANTHROPIC_AUTH_TOKEN" \
     http://127.0.0.1:3456/v1/models

# Claude Code 缓存了哪些网关模型
cat ~/.claude/cache/gateway-models.json

# 模型名 → 网关别名
python3 -c "print('anthropic/claude-ccr-h' + 'XM/ninfer-local'.encode().hex())"
```
