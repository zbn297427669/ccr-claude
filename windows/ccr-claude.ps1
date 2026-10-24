<#
.SYNOPSIS
  按 CCR Agent profile 启动 Windows 版 Claude Code。

.DESCRIPTION
  与 WSL 侧的 ccr-claude/wsl/start-claude.sh 对等，但直接跑本目录下的
  claude-*-win32-x64.exe，不经过 CCR 生成的 wrapper 中间层。

  所需信息一律从 CCR 安装目录发现，脚本内不含密钥：
    - CCR 数据目录（config.sqlite / bin/api-key）
    - 网关地址（config 内 routerEndpoint，或 CCR_BASE_URL）
    - 客户端密钥（api_keys 表，或 bin/ccr-claude-code-api-key-*.cmd）
    - 模型名（profile.model，或 profile 内的 settings.json）

.PARAMETER ProfileId
  直接指定 profile id 或名称片段（也可用环境变量 CCR_PROFILE）。

.PARAMETER ModelName
  覆盖模型名（支持 CCR 长名，会转成短名传给 ANTHROPIC_MODEL）。

.PARAMETER ContextWindow
  设定 CLAUDE_CODE_MAX_CONTEXT_TOKENS。传 off 就什么都不设，让 Claude Code
  自己决定（目录 → settings.json 的 autoCompactWindow → 200000）。不传则
  由启动器解析，见 CONTEXT-WINDOW.md。
  Claude Code 实际用的是 MAX − 20000（预留输出），不再有 800000 硬顶。

.PARAMETER ListProfiles
  列出所有 Claude Code profile 后退出。

.PARAMETER Pick
  强制交互选择，即使只有一个 enabled profile。

.PARAMETER PickModel
  强制列出该 profile 允许的模型，即使只有一个、或调用方带了 -p。
  不加这个开关时，菜单只在"多个模型 + 交互终端 + 没有 -p + CCR_NO_PICK 未设"
  时才会出现，直接回车等于保持 profile 当前的模型。

.PARAMETER SkipCheck
  跳过网关与 token 预检。

.EXAMPLE
  .\ccr-claude.ps1
  .\ccr-claude.ps1 --profile claude-code
  .\ccr-claude.ps1 --list-profiles
  .\ccr-claude.ps1 --pick-model
  .\ccr-claude.ps1 --model XM/bonsai-heretic
  .\ccr-claude.ps1 -p "解释这个仓库"
#>

# 不出现在 param 块里：启动器自己的开关全用双横线，单横线的全部原样
# 透传给 claude。PowerShell 的参数绑定是按前缀匹配的，只要声明了
# -ProfileId，claude 自己的 -p / --model / --continue 就会被抢走。
$ErrorActionPreference = 'Stop'

$ProfileId = $env:CCR_PROFILE
$ModelName = ''
# 字符串而不是 [int]：--context-window off 也得能传，它表示"什么都别设"。
$ContextWindow = ''
$ContextWindowOff = $false
$ListProfiles = $false
$Pick = $false
$PickModel = $false
$SkipCheck = $false
$PassArgs = New-Object System.Collections.Generic.List[string]

$i = 0
while ($i -lt $args.Count) {
    $a = [string]$args[$i]
    switch -Regex ($a) {
        '^--(profile|profile-id)$' { $ProfileId = [string]$args[++$i]; break }
        '^--model$' { $ModelName = [string]$args[++$i]; break }
        '^--context-window$' {
            $ContextWindow = [string]$args[++$i]
            # 这里还不能用 Stop-With：函数定义在参数循环之后才执行到。
            if (-not $ContextWindow) { [Console]::Error.WriteLine("ccr-claude: missing --context-window value"); exit 1 }
            break
        }
        '^--context-window=(.*)$' { $ContextWindow = $Matches[1]; break }
        '^--list-profiles$' { $ListProfiles = $true; break }
        '^--pick$' { $Pick = $true; break }
        '^--pick-model$' { $PickModel = $true; break }
        '^--skip-check$' { $SkipCheck = $true; break }
        '^(--h|--help|-h)$' { $ShowHelp = $true; break }
        default { $PassArgs.Add($a) }
    }
    $i++
}

if ($ShowHelp) {
    Get-Help $PSCommandPath -Detailed
    exit 0
}

function Write-Note([string]$Msg) { [Console]::Error.WriteLine($Msg) }
function Stop-With([string]$Msg) { Write-Note "ccr-claude: $Msg"; exit 1 }

# CCR 里 Provider/model 这种长名，Claude Code 只认最后一段、去掉 [1m] 后缀。
function ConvertTo-ShortModel([string]$M) {
    if (-not $M) { return '' }
    $M = $M.Trim()
    $M = $M.Substring($M.LastIndexOf('/') + 1)
    $i = $M.IndexOf('[')
    if ($i -ge 0) { $M = $M.Substring(0, $i) }
    return $M
}

# 窗口在菜单里写成什么。
#
# 百万以上给一位小数的 M —— 正好是 100K 一步，够分清 1.0M 和 1.1M，
# 这一列要干的就这件事。百万以下留在 K：把 128K 舍成 "100K" 会凭空差 28%，
# 而 "128K" 既准又短。四舍五入过的值前面加 "~"。
function Format-WindowLabel([string]$N) {
    if ($N -notmatch '^\d+$') { return '' }
    $n = [long]$N
    if ($n -ge 1000000) {
        $m = [long][Math]::Round($n / 100000.0, 0, [MidpointRounding]::AwayFromZero)
        $approx = if ($m * 100000 -ne $n) { '~' } else { '' }
        return ('{0}{1}.{2}M' -f $approx, [Math]::Floor($m / 10), ($m % 10))
    }
    $k = [long][Math]::Round($n / 1000.0, 0, [MidpointRounding]::AwayFromZero)
    $approx = if ($k * 1000 -ne $n) { '~' } else { '' }
    return ('{0}{1}K' -f $approx, $k)
}

# Claude Code 的网关缓存把模型名编码成 anthropic/claude-ccr-h<hex>，其中
# <hex> 就是原始名（"OD/deepseek-v4.1-flash" -> 4f442f + "deepseek-v4.1-flash"）。
# 是可逆的，所以用缓存里的长名也能找回 CCR 那边的供应商和模型。
function Expand-GatewayModel([string]$Name) {
    if (-not $Name) { return $Name }
    # 变量名不要叫 $m：PowerShell 的变量名大小写不敏感，$m 就是 $Name，
    # 后面的 Substring 会把原始值也改掉，于是"原样返回"那两条路都返回半截名字。
    $work = $Name.Trim()
    $orig = $Name
    # [1m] 这类后缀是 Claude Code 的窗口标注，不在十六进制里。剥掉再解码，
    # 解完要原样接回去——"Go/deepseek-v4-flash[1m]" 和 "Go/deepseek-v4-flash"
    # 在网关那边是两个条目。
    $suffix = ''
    $i = $work.IndexOf('[')
    if ($i -ge 0) { $suffix = $work.Substring($i); $work = $work.Substring(0, $i) }
    if ($work -notmatch 'claude-ccr-h((?:[0-9a-fA-F]{2})+)$') { return $orig }
    $hex = $Matches[1]
    try {
        $bytes = New-Object byte[] ($hex.Length / 2)
        for ($k = 0; $k -lt $bytes.Length; $k++) {
            $bytes[$k] = [Convert]::ToByte($hex.Substring($k * 2, 2), 16)
        }
        $decoded = [Text.Encoding]::UTF8.GetString($bytes)
        if ($decoded) { return $decoded + $suffix }
    }
    catch { }
    return $orig
}

# ---------------------------------------------------------------- 找 CCR
function Find-CcrDir {
    if ($env:CCR_DIR -and (Test-Path (Join-Path $env:CCR_DIR 'config.sqlite'))) {
        return $env:CCR_DIR
    }
    $candidates = @()
    if ($env:APPDATA) { $candidates += (Join-Path $env:APPDATA 'claude-code-router') }
    if ($env:LOCALAPPDATA) { $candidates += (Join-Path $env:LOCALAPPDATA 'claude-code-router') }
    $candidates += (Join-Path $HOME '.claude-code-router')
    foreach ($c in $candidates) {
        if ($c -and (Test-Path (Join-Path $c 'config.sqlite'))) { return $c }
    }
    return $null
}

# ---------------------------------------------------------------- 读库
# SQLite 从 PowerShell 读不了，借 python。三个库文件一起拷（WAL 里可能有
# 还没落盘的最新配置），在副本上只读打开，避免锁住 CCR 桌面端。
$PyProfiles = @'
import json, re, shutil, sqlite3, sys, tempfile
from pathlib import Path

ccr = Path(sys.argv[1])
mode = sys.argv[2] if len(sys.argv) > 2 else "list"

def open_db():
    td = Path(tempfile.mkdtemp(prefix="ccr-claude-"))
    for n in ("config.sqlite", "config.sqlite-wal", "config.sqlite-shm"):
        p = ccr / n
        if p.exists():
            shutil.copy2(p, td / n)
    return sqlite3.connect(str(td / "config.sqlite")), td

def token_for(con, pid):
    try:
        row = con.execute(
            "select encrypted_key, encryption from api_keys where id=?",
            (f"profile:{pid}",),
        ).fetchone()
    except sqlite3.Error:
        row = None
    if row and row[0] and (row[1] or "plain").lower() == "plain":
        return row[0].strip()
    for name in (f"ccr-claude-code-api-key-{pid}.cmd",
                 f"ccr-claude-code-api-key-{pid}.sh"):
        f = ccr / "bin" / name
        if not f.is_file():
            continue
        text = f.read_text(encoding="utf-8", errors="ignore")
        m = re.search(r"ccr-profile-[A-Za-z0-9_-]+", text)
        if m:
            return m.group(0)
    return ""

def settings_model(pid):
    settings = ccr / "profiles" / pid / "claude" / "settings.json"
    if not settings.is_file():
        return ""
    try:
        env = json.loads(settings.read_text(encoding="utf-8")).get("env") or {}
    except Exception:
        return ""
    for k in ("ANTHROPIC_MODEL", "CCR_CLAUDE_CODE_MODEL",
              "ANTHROPIC_DEFAULT_SONNET_MODEL"):
        v = env.get(k)
        if isinstance(v, str) and v.strip():
            return v.strip()
    return ""

con, td = open_db()
try:
    row = con.execute(
        "select value_json from app_config where key='default'"
    ).fetchone()
    cfg = json.loads(row[0]) if row else {}

    if mode == "url":
        ep = (cfg.get("routerEndpoint") or "").strip()
        if ep:
            print(ep.rstrip("/"))
        else:
            gw = cfg.get("gateway") or {}
            host = gw.get("host") or cfg.get("HOST") or "127.0.0.1"
            port = gw.get("port") or cfg.get("PORT") or 3456
            if host in ("0.0.0.0", "::"):
                host = "127.0.0.1"
            print(f"http://{host}:{port}")
        raise SystemExit(0)

    if mode == "token":
        print(token_for(con, sys.argv[3]))
        raise SystemExit(0)

    if mode == "ctx":
        # Claude Code 与 CCR 之间没有传递窗口的通道，所以由启动器问出来。
        # 来源依次：供应商 /v1/models（仅回环）、CCR 存的 modelMetadata、
        # 每机 catalog。都没有就什么都不输出 —— 留空好过猜。
        #
        # 一次问一串，因为菜单有十几个模型：逐个调用会把同一个库、同一份目录
        # 读十几遍，还会对同一个回环端点反复探测（本地引擎每次都要付冷启动）。
        import urllib.request

        raws = [a.strip() for a in sys.argv[3:] if (a or "").strip()]
        if not raws:
            raise SystemExit(0)

        def to_int(v):
            try:
                n = int(float(v))
            except (TypeError, ValueError):
                return None
            return n if 0 < n <= 10_000_000 else None

        def window_of(entry):
            # 平面字段是端点返回的形状；limits 是 CCR 自带目录的形状 ——
            # 以前只认平面字段，于是那个目录一条都没匹配上。
            for f in ("context_window", "contextWindow",
                      "max_context_window", "max_model_len"):
                v = to_int(entry.get(f))
                if v:
                    return v
            lim = entry.get("limits")
            if isinstance(lim, dict):
                return to_int(lim.get("contextTokens")) or to_int(lim.get("inputTokens"))
            return None

        # CCR 对没有元数据的模型一律写 128000（bundle 里 KFe=128e3）。那是它的
        # 默认值，不是探测结果，和"CCR 不知道"分不开，所以不能当读数。
        PLACEHOLDER = 128000

        providers = {}
        for p in cfg.get("Providers") or []:
            entry = {
                "base": (p.get("api_base_url") or p.get("baseUrl") or "").rstrip("/"),
                "key": p.get("api_key") or "",
                "meta": p.get("modelMetadata") or {},
            }
            for n in {p.get("name"), p.get("id")} - {None, ""}:
                providers[n] = entry

        catalogs = []

        def catalog_data():
            if catalogs:
                return catalogs
            paths = [("models.json", ccr / "models.json"),
                     ("catalog", ccr.parents[2] / ".codex" / "ccr-model-catalog.json")]
            for label, path in paths:
                if not path.is_file():
                    continue
                try:
                    catalogs.append((label, json.loads(path.read_text(encoding="utf-8"))))
                except Exception:
                    pass
            return catalogs

        probed = {}

        def probed_windows(base, key):
            if base in probed:
                return probed[base]
            found = {}
            for suffix in ("/models", "/v1/models"):
                try:
                    req = urllib.request.Request(base + suffix)
                    if key:
                        req.add_header("authorization", "Bearer " + key)
                        req.add_header("x-api-key", key)
                    with urllib.request.urlopen(req, timeout=1.5) as r:
                        data = json.loads(r.read().decode("utf-8", "replace"))
                except Exception as exc:
                    # 超时说明端口有人听但不应答（引擎冷启动或加载中），同一个
                    # 服务器的另一个路径也会超时；只有立即被拒或 404 值得再试。
                    if isinstance(exc, TimeoutError) or "timed out" in str(exc):
                        break
                    continue
                entries = data.get("data") or data.get("models") or []
                for m in entries:
                    v = window_of(m)
                    if not v:
                        continue
                    for k in {m.get("id"), (m.get("id") or "").split("/")[-1]} - {None, ""}:
                        found.setdefault(k, v)
                # 本地端点常常只挂一个模型，它用的名字未必和 CCR 记的一致
                if len(entries) == 1 and found:
                    found["__single__"] = next(iter(found.values()))
                if found:
                    break
            probed[base] = found
            return found

        def resolve(model):
            # [1m] 是 Claude Code 的窗口标注，目录和 modelMetadata 里都不带它。
            name = model.split("[", 1)[0].strip()
            prov, _, part = name.partition("/")
            if not part:
                prov, part = "", name
            p = providers.get(prov) or {}
            meta = p.get("meta") or {}
            # 只认这个模型自己的名字。早期版本把 provider 元数据里其它模型的
            # 名字也放进候选集，结果 deepseek-v4.1-flash 继承了邻居在
            # models.json 里写的值。
            wanted = {part, name}

            # 1. CCR 上次探测的结果，存在 provider 上
            for k in (part, name):
                v = to_int((meta.get(k) or {}).get("contextWindow")
                           or (meta.get(k) or {}).get("context_window"))
                if v:
                    return v

            # 2. 端点自己，仅回环
            base = p.get("base") or ""
            if re.match(r"^https?://(127\.|localhost|\[::1\])", base):
                found = probed_windows(base, p.get("key") or "")
                for k in (part, name):
                    if k in found:
                        return found[k]
                if "__single__" in found:
                    return found["__single__"]

            # 3. 目录。同一个模型名可能对上多条（deepseek/deepseek-v4.1-flash
            #    写 1050000，alibaba/... 写 1000000），取先出现的等于掷硬币。
            #    要求它们一致：10% 以内算同一个模型，取小的那个（只会提前压缩，
            #    不会滞后）；差距更大说明这名字确实是两个东西，那这份文件就
            #    什么也没说。
            for label, data in catalog_data():
                vals = set()
                for m in data.get("models") or []:
                    if wanted & {m.get("id"), m.get("slug"), m.get("model")}:
                        v = window_of(m)
                        if v:
                            vals.add(v)
                if not vals:
                    continue
                v = min(vals)
                if max(vals) - v > v * 0.1:
                    continue
                if label == "catalog" and v == PLACEHOLDER:
                    continue
                return v
            return None

        cache = {}
        for raw in raws:
            key = raw.split("[", 1)[0].strip()
            if not key:
                continue
            if key not in cache:
                cache[key] = resolve(raw)
            if cache[key]:
                print(f"{raw}\t{cache[key]}")
        raise SystemExit(0)

    out = []
    for p in (cfg.get("profile") or {}).get("profiles") or []:
        if p.get("agent") != "claude-code":
            continue
        pid = p.get("id") or ""
        model = (p.get("model") or p.get("sonnetModel") or "").strip()
        if not model:
            model = settings_model(pid)
        avail = p.get("availableModels") or p.get("available_models") or []
        avail = [m for m in avail if isinstance(m, str) and m.strip()]
        if model and model not in avail:
            avail.insert(0, model)
        out.append({
            "id": pid,
            "name": p.get("name") or pid,
            "model": model,
            "enabled": bool(p.get("enabled", True)),
            "scope": p.get("scope") or "global",
            "has_token": bool(token_for(con, pid)),
            "available": avail,
        })
    json.dump(out, sys.stdout, ensure_ascii=False)
finally:
    con.close()
    shutil.rmtree(td, ignore_errors=True)
'@

function Find-Python {
    foreach ($n in @('python', 'python3', 'py')) {
        $c = Get-Command $n -ErrorAction SilentlyContinue
        if (-not $c -or -not $c.Source) { continue }
        # WindowsApps 下的是应用执行别名（商店存根），没装 Python 时它会弹商店
        # 并以 9009 退出，不报错也不干活。
        if ($c.Source -like '*\WindowsApps\*') { continue }
        # 能跑通一段完整代码才算真解释器：存根、缺 sqlite 的都在这筛掉。
        $probe = & $c.Source -c 'import sqlite3; print(1)' 2>$null
        if ($LASTEXITCODE -eq 0 -and "$probe".Trim() -eq '1') { return $c.Source }
    }
    # CCR 自带 Electron，可以当 node 用，但没有 sqlite 模块；这里只认 python。
    return $null
}

$PythonExe = Find-Python

function Invoke-CcrPy([string]$Code, [string[]]$PyArgs) {
    # 不要把代码经管道喂给 python（`$Code | python -`）。那条管道按
    # $OutputEncoding 编码，而它是**会话级**变量：GB2312/GB18030 会让中文注释
    # 变成非法 UTF-8（SyntaxError at line 76），UTF-16 更是连 BOM 都对不上
    # （SyntaxError at line 1）。同一个脚本在不同终端里时好时坏，就是这么来的。
    # 落成临时文件再传路径，编码由我们自己定死。
    $tmp = Join-Path ([IO.Path]::GetTempPath()) ("ccr-claude-{0}.py" -f [Guid]::NewGuid().ToString('N'))
    $old = $env:PYTHONIOENCODING
    $env:PYTHONIOENCODING = 'utf-8'
    try {
        [IO.File]::WriteAllText($tmp, $Code, (New-Object Text.UTF8Encoding($false)))
        & $PythonExe $tmp @PyArgs 2>$null
    }
    finally {
        Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
        if ($null -eq $old) { Remove-Item Env:PYTHONIOENCODING -ErrorAction SilentlyContinue }
        else { $env:PYTHONIOENCODING = $old }
    }
}

# ---------------------------------------------------------------- 定位
$CcrDir = Find-CcrDir
if (-not $CcrDir) {
    Stop-With "no CCR data dir (needs config.sqlite). Set `$env:CCR_DIR, e.g. $env:APPDATA\claude-code-router"
}

$BaseUrl = $env:CCR_BASE_URL
if (-not $BaseUrl) { $BaseUrl = $env:ANTHROPIC_BASE_URL }
if (-not $BaseUrl) {
    if (-not $PythonExe) {
        Stop-With "python is needed to read the CCR config; or just set `$env:CCR_BASE_URL"
    }
    $BaseUrl = (Invoke-CcrPy $PyProfiles @($CcrDir, 'url')).Trim()
}
if (-not $BaseUrl) { $BaseUrl = 'http://127.0.0.1:3456' }

if (-not $PythonExe) {
    Stop-With "no python on PATH. Install Python, or set `$env:CCR_DIR / `$env:CCR_BASE_URL / `$env:ANTHROPIC_AUTH_TOKEN yourself."
}

$json = Invoke-CcrPy $PyProfiles @($CcrDir, 'list')
if (-not $json) { Stop-With "could not read CCR profiles from $CcrDir" }
$Profiles = $json | ConvertFrom-Json
if (-not $Profiles -or $Profiles.Count -eq 0) { Stop-With "no Claude Code profile in CCR." }

# ---------------------------------------------------------------- 列 profile
if ($ListProfiles) {
    '{0,-24} {1,-28} {2,-6} {3,-6} {4}' -f 'ID', 'NAME', 'ENABLED', 'TOKEN', 'MODEL'
    foreach ($p in ($Profiles | Sort-Object id)) {
        $en = if ($p.enabled) { 'yes' } else { 'no' }
        $tk = if ($p.has_token) { 'yes' } else { 'no' }
        $md = ConvertTo-ShortModel $p.model
        if (-not $md) { $md = '(none)' }
        '{0,-24} {1,-28} {2,-6} {3,-6} {4}' -f $p.id, $p.name, $en, $tk, $md
    }
    Write-Note "CCR_DIR=$CcrDir"
    Write-Note "CCR_BASE_URL=$BaseUrl"
    exit 0
}

# ---------------------------------------------------------------- 选 profile
$Want = if ($ProfileId) { $ProfileId } else { $env:CCR_PROFILE }

# 上次用过的记在 %APPDATA%\ccr-claude\last-profile
$StateDir = Join-Path $env:APPDATA 'ccr-claude'
$LastFile = Join-Path $StateDir 'last-profile'
$LastId = ''
if (Test-Path $LastFile) {
    $LastId = (Get-Content -Raw $LastFile -ErrorAction SilentlyContinue)
    if ($LastId) { $LastId = $LastId.Trim() }
}

$Usable = @($Profiles | Where-Object { $_.enabled -and $_.model -and $_.has_token })
if ($Usable.Count -eq 0) {
    Stop-With "no usable profile: need enabled + a model + a client key. Enable a Claude Code agent in CCR."
}

$Chosen = $null
if ($Want) {
    $exact = @($Usable | Where-Object { $_.id -eq $Want -or $_.name -eq $Want })
    if ($exact.Count -eq 1) {
        $Chosen = $exact[0]
    }
    else {
        $fuzzy = @($Usable | Where-Object { $_.id -like "*$Want*" -or $_.name -like "*$Want*" })
        if ($fuzzy.Count -eq 1) { $Chosen = $fuzzy[0] }
        elseif ($fuzzy.Count -gt 1) {
            Write-Note "profile `"$Want`" is ambiguous:"
            $fuzzy | ForEach-Object { Write-Note ("  {0}  {1}" -f $_.id, $_.name) }
            exit 1
        }
        else { Stop-With "no usable profile matching `"$Want`" (see --list-profiles)" }
    }
}
elseif ($Usable.Count -eq 1 -and -not $Pick) {
    $Chosen = $Usable[0]
}
else {
    # 上次的选择排在最前，其余按名字排
    $ordered = @()
    if ($LastId) { $ordered += @($Usable | Where-Object { $_.id -eq $LastId }) }
    $ordered += @($Usable | Where-Object { $_.id -ne $LastId } | Sort-Object id)
    $ordered = @($ordered | Where-Object { $_ })

    if ($ordered.Count -eq 1) {
        $Chosen = $ordered[0]
    }
    else {
        # 静默条件和下面的模型菜单同一套：stdin 不是终端、CCR_NO_PICK=1、
        # 转发参数里有 -p。脚本里弹提示就是挂住。$ordered[0] 已经是"上次用过
        # 的优先"，静默时取它，和 start-claude.sh 的 pick_profile 一致。
        $AskProfile = $true
        if (-not $Pick) {
            if (-not $Host.UI.RawUI -or [Console]::IsInputRedirected) { $AskProfile = $false }
            if ($env:CCR_NO_PICK -eq '1') { $AskProfile = $false }
            foreach ($pa in $PassArgs) {
                if ($pa -eq '-p' -or $pa -eq '--print') { $AskProfile = $false; break }
            }
        }

        if (-not $AskProfile) { $Chosen = $ordered[0] }
        else {
            Write-Note "Claude Code profiles:"
            for ($i = 0; $i -lt $ordered.Count; $i++) {
                $p = $ordered[$i]
                $mark = if ($p.id -eq $LastId) { ' (last)' } else { '' }
                Write-Note ("  {0}) {1,-40} {2}{3}" -f ($i + 1), $p.name, (ConvertTo-ShortModel $p.model), $mark)
            }
            $answer = Read-Host "Select [1] "
            if ([string]::IsNullOrWhiteSpace($answer)) { $Chosen = $ordered[0] }
            elseif ($answer -match '^\d+$' -and [int]$answer -ge 1 -and [int]$answer -le $ordered.Count) {
                $Chosen = $ordered[[int]$answer - 1]
            }
            else { Stop-With "not a valid choice: `"$answer`"" }
        }
    }
}

$ProfileId = $Chosen.id

# ---------------------------------------------------------------- 选模型
# 用户可能给的是 CCR 的 XM/xxx，也可能直接抄了网关缓存里的 anthropic/claude-ccr-h<hex>。
# 先把后者还原成 CCR 认识的名字，否则查不到供应商，窗口也就无从解析。
$RawModel = if ($ModelName) { $ModelName } else { $env:MODEL }
$ModelSource = if ($ModelName) { '--model' } elseif ($env:MODEL) { 'MODEL' } else { '' }
if (-not $RawModel) {
    $RawModel = $Chosen.model
    $ModelSource = 'profile'

    # profile 里还配了别的模型时给个菜单。列表来自 CCR 的 availableModels，
    # 它同时是网关的准入清单——菜单里列出来的网关一定接受。当前模型排第一，
    # 直接回车就是保持现状。
    #
    # 什么都不问的四种情况（和 start-claude.sh 的 pick_model 一致）：只有一个
    # 模型、stdin 不是终端、CCR_NO_PICK=1、转发参数里有 -p。最后一条最要紧：
    # 脚本调用时弹提示就是挂住。
    $Avail = @($Chosen.model) + @($Chosen.available | Where-Object { $_ -and $_ -ne $Chosen.model })
    $Avail = @($Avail | Where-Object { $_ } | Select-Object -Unique)

    $Ask = $true
    if ($Avail.Count -le 1 -and -not $PickModel) { $Ask = $false }
    if (-not $PickModel) {
        if (-not $Host.UI.RawUI -or [Console]::IsInputRedirected) { $Ask = $false }
        if ($env:CCR_NO_PICK -eq '1') { $Ask = $false }
        foreach ($pa in $PassArgs) {
            if ($pa -eq '-p' -or $pa -eq '--print') { $Ask = $false; break }
        }
    }

    if ($Ask) {
        # 每行带上这个模型自己的上下文窗口。不给这一列，菜单就是在盲选：上下文
        # 差四倍的两个模型在一列名字里长得一模一样。整张菜单只调一次 python
        # （模式是批量的），逐个调用会把同一个库和目录读十几遍。
        #
        # 列的是模型窗口，未必是压缩发生的地方：settings.json 给某个模型钉了
        # 更低的 autoCompactWindow 时，运行时取 min(窗口, 钉值)。这里不套那个
        # 钉值，因为同一个解析器还要喂 CLAUDE_CODE_MAX_CONTEXT_TOKENS，而它
        # 必须是对模型的陈述。
        $winOf = @{}
        if ($env:CCR_CONTEXT_WINDOW -match '^\d+$') {
            foreach ($m in $Avail) { $winOf[$m] = $env:CCR_CONTEXT_WINDOW }
        }
        elseif ($env:CCR_CONTEXT_WINDOW -ne 'off') {
            $ctxArgs = @($CcrDir, 'ctx') + $Avail
            foreach ($line in @(Invoke-CcrPy $PyProfiles $ctxArgs)) {
                if ("$line" -match '^(.*)\t(\d+)\s*$') { $winOf[$Matches[1]] = $Matches[2] }
            }
        }
        # 控制台代码页是 OEM（中文机器上常见 936），非 ASCII 的破折号会变成
        # 乱码，所以这里的交互文案一律用 ASCII。
        Write-Note "Models this profile allows - pick one (context window in brackets):"
        for ($k = 0; $k -lt $Avail.Count; $k++) {
            $mark = if ($k -eq 0) { '  (current)' } else { '' }
            $winLabel = Format-WindowLabel $winOf[$Avail[$k]]
            if (-not $winLabel) { $winLabel = 'unknown' }
            Write-Note ("  {0}) {1}  [{2}]{3}" -f ($k + 1), (ConvertTo-ShortModel $Avail[$k]), $winLabel, $mark)
        }
        Write-Note "  0) cancel"
        $answer = Read-Host "Select [1] "
        if ([string]::IsNullOrWhiteSpace($answer)) { $RawModel = $Avail[0] }
        elseif ($answer -eq '0') { Write-Note "Cancelled."; exit 130 }
        elseif ($answer -match '^\d+$' -and [int]$answer -ge 1 -and [int]$answer -le $Avail.Count) {
            $RawModel = $Avail[[int]$answer - 1]
        }
        else { Stop-With "not a valid choice: `"$answer`"" }
        if ($RawModel -ne $Chosen.model) { $ModelSource = 'picked' }
    }
}

# 网关缓存里的长名可还原成 CCR 的写法；ANTHROPIC_MODEL 仍传用户原样给的名字，
# 因为 Claude Code 的 autocompact 只在名字命中缓存时才跑。
$CcrModel = Expand-GatewayModel $RawModel
if ($CcrModel -ne $RawModel) {
    $ModelSource = "$ModelSource, decoded to $CcrModel"
}

# ---------------------------------------------------------------- 取密钥
$Token = ((Invoke-CcrPy $PyProfiles @($CcrDir, 'token', $ProfileId)) -join '').Trim()
if (-not $Token) {
    Stop-With "profile `"$ProfileId`" has no plaintext client key. Re-save that agent in CCR."
}

# ---------------------------------------------------------------- 预检
if (-not $SkipCheck) {
    $ok = $false
    foreach ($probe in @("$BaseUrl/", "$BaseUrl/health")) {
        try {
            $r = Invoke-WebRequest -UseBasicParsing -TimeoutSec 3 -Uri $probe
            if ($r.StatusCode -ge 200 -and $r.StatusCode -lt 500) { $ok = $true; break }
        }
        catch { }
    }
    if (-not $ok) {
        Write-Note "CCR gateway unreachable: $BaseUrl"
        Write-Note "Start CCR (or the gateway), pass --skip-check, or set CCR_BASE_URL."
        exit 1
    }
    try {
        $r = Invoke-WebRequest -UseBasicParsing -TimeoutSec 8 -Uri "$BaseUrl/v1/models" `
            -Headers @{ Authorization = "Bearer $Token" }
        if ($r.StatusCode -ne 200) { throw "HTTP $($r.StatusCode)" }
    }
    catch {
        $code = ''
        if ($_.Exception.Response) { $code = [int]$_.Exception.Response.StatusCode }
        Write-Note "gateway preflight failed for profile `"$ProfileId`" (HTTP $code)."
        if ($code -eq 401 -or $code -eq 403) {
            Write-Note "The client key is invalid or not permitted. Re-save/re-enable that agent in CCR."
        }
        else {
            Write-Note "$($_.Exception.Message)"
        }
        exit 1
    }
}

# ---------------------------------------------------------------- 环境变量
# 关键：ANTHROPIC_MODEL 必须命中网关缓存里的条目，否则 Claude Code 找不到
# 目录项，autocompact 整段跳过（会话一路长到引擎拒绝为止）。用户给的名字
# 可能是 CCR 短名、display_name、或缓存长名，统一折算成缓存里的 id。
function Resolve-CanonicalModel([string]$Want, [string]$CcrName) {
    $cacheFile = Join-Path $env:USERPROFILE '.claude\cache\gateway-models.json'
    if (-not (Test-Path $cacheFile)) { return $Want }
    try { $models = (Get-Content -Raw $cacheFile | ConvertFrom-Json).models }
    catch { return $Want }
    if (-not $models) { return $Want }

    $stripSuffix = { param($s) if ($s -match '^(.*?)(\[[^\]]*\])?$') { $Matches[1] } }
    $wantBase = & $stripSuffix $Want

    # 1. 原样命中
    foreach ($m in $models) { if ($m.id -eq $Want) { return $m.id } }
    # 2. display_name 命中
    foreach ($m in $models) {
        if ($m.display_name -eq $Want -or $m.display_name -eq $CcrName) { return $m.id }
    }
    # 3. 去掉 [1m] 之类后缀后再比一次，命中则保留缓存里的完整写法
    foreach ($m in $models) {
        if ((& $stripSuffix $m.id) -eq $wantBase -or
            (& $stripSuffix $m.display_name) -eq $wantBase) { return $m.id }
    }
    return $Want
}

$CanonicalModel = Resolve-CanonicalModel $RawModel $CcrModel
if ($CanonicalModel -ne $RawModel) {
    $ModelSource = "$ModelSource, canonicalized to $CanonicalModel"
    $RawModel = $CanonicalModel
}
if (-not $RawModel) { Stop-With "model name is empty." }
# 原样传下去：CCR 的写法（OD/deepseek-v4.1-flash）和缓存长名
# （anthropic/claude-ccr-h<hex>）都能被网关接受。不要截成最后一段——
# 那样既丢前缀又对不上缓存。
$ModelForEnv = $RawModel

# ANTHROPIC_DEFAULT_{OPUS,SONNET,HAIKU,FABLE}_MODEL 决定 /model 菜单里那几条
# "Custom …" 显示的文本。以前四个都塞 $ModelForEnv，而它常是缓存长名
# anthropic/claude-ccr-h<hex>，菜单里就是一堆编号。
#
# 这里不能填缓存的 display_name（"Go/DeepSeek V4 Flash (1M context)"）：实测
# 网关只认 CCR 短名和长名，display_name 和伪造名字一样直接 403——菜单选它
# 就发不出请求。反解回 CCR 名（"OD/deepseek-v4.1-flash"）既可路由又是人话。
$ModelLabel = Expand-GatewayModel $ModelForEnv
if (-not $ModelLabel) { $ModelLabel = $ModelForEnv }

$env:ANTHROPIC_BASE_URL = $BaseUrl
$env:ANTHROPIC_API_BASE_URL = $BaseUrl
$env:CLAUDE_AGENT_API_BASE_URL = $BaseUrl
$env:ANTHROPIC_AUTH_TOKEN = $Token
Remove-Item Env:ANTHROPIC_API_KEY -ErrorAction SilentlyContinue

$env:ANTHROPIC_MODEL = $ModelForEnv
$env:ANTHROPIC_DEFAULT_SONNET_MODEL = $ModelLabel
$env:ANTHROPIC_DEFAULT_OPUS_MODEL = $ModelLabel
$env:ANTHROPIC_DEFAULT_HAIKU_MODEL = $ModelLabel
$env:ANTHROPIC_DEFAULT_FABLE_MODEL = $ModelLabel

$env:CLAUDE_CODE_ENABLE_GATEWAY_MODEL_DISCOVERY = '1'

# CCR 无条件写 1，但 1 的含义是"等 API 报错再处理"：对没有目录条目的模型，
# Claude Code 会整段跳过 autocompact 的阈值检查（--debug 里连 autocompact:
# 行都没有），会话一路长到引擎拒绝为止。本地模型必须为 0。
$env:CLAUDE_CODE_DISABLE_UNKNOWN_MODEL_WINDOW_ENFORCEMENT = '0'

# 本机网关和引擎都在 127.0.0.1，别让它绕到 WSL 的代理上
$env:NO_PROXY = '127.0.0.1,localhost,::1'
$env:no_proxy = '127.0.0.1,localhost,::1'

$CtxForced = $false
$ContextWindowOff = $false
if ($ContextWindow -match '^\d+$' -and [int]$ContextWindow -gt 0) {
    $env:CLAUDE_CODE_MAX_CONTEXT_TOKENS = "$([int]$ContextWindow)"
    $CtxForced = $true
}
elseif ($ContextWindow -eq 'off' -or $env:CCR_CONTEXT_WINDOW -eq 'off') {
    # off：什么都不设，让 Claude Code 自己走它的链条（目录 → settings.json
    # 的 autoCompactWindow → 200000）。
    $ContextWindowOff = $true
    Remove-Item Env:CLAUDE_CODE_MAX_CONTEXT_TOKENS -ErrorAction SilentlyContinue
}
elseif ($ContextWindow -and $ContextWindow -notmatch '^0+$') {
    [Console]::Error.WriteLine("ccr-claude: --context-window takes a token count or 'off', got `"$ContextWindow`"")
    exit 1
}
elseif ($env:CCR_CONTEXT_WINDOW -match '^\d+$') {
    $env:CLAUDE_CODE_MAX_CONTEXT_TOKENS = $env:CCR_CONTEXT_WINDOW
    $CtxForced = $true
}
else {
    # 不猜：解析不到就沿用 settings.json，并在下面报告实际取值
    # 注意别写成 [string](Invoke-CcrPy ...)：python 什么都没打印时，括号里是
    # 空管道而不是 $null 值，强制转换对"没有对象"不生效，$resolved 仍是 $null，
    # 下一行 .Trim() 直接抛 InvalidOperation（开了 Stop，整个启动中止）。
    # 目录里查不到的模型（比如刚加的本地模型）就会走到这条路。
    # ctx 模式输出 "model<TAB>tokens"，取 Tab 后面那段。
    $resolved = ((Invoke-CcrPy $PyProfiles @($CcrDir, 'ctx', $CcrModel)) -join "`n")
    if ($resolved -match '(?m)^[^\t\r\n]*\t(\d+)\s*$') { $resolved = $Matches[1] }
    if ($resolved -match '^\s*(\d+)\s*$') {
        $env:CLAUDE_CODE_MAX_CONTEXT_TOKENS = $Matches[1]
        $CtxForced = $true
    }
}

# ------------------------------------------------- settings 覆盖层
# 实测：settings.json 的 env 会盖掉进程环境变量，而 --settings 的 env 又能
# 盖掉 settings.json。所以只靠 set 环境变量是不够的——CCR 生成的 wrapper 和
# 用户已存的 settings.json 里都有 CLAUDE_CODE_DISABLE_UNKNOWN_MODEL_WINDOW_
# ENFORCEMENT=1 和 MAX_CONTEXT_TOKENS=1000000，会把上面这些全部吃掉。
#
# 这一层只写非密钥项（地址、模型名、开关），token 仍只走进程环境变量。
$OverrideDir = Join-Path $env:LOCALAPPDATA 'ccr-claude'
$OverrideFile = Join-Path $OverrideDir 'settings.json'
try {
    if (-not (Test-Path $OverrideDir)) { New-Item -ItemType Directory -Path $OverrideDir -Force | Out-Null }
    # 注意：不能写成 [ordered]@{...} 字面量——PowerShell 的键名不区分大小写，
    # NO_PROXY 和 no_proxy 会被判成重复键。先建空表再加。
    $overrideEnv = New-Object System.Collections.Specialized.OrderedDictionary
    $overrideEnv['ANTHROPIC_BASE_URL'] = $BaseUrl
    $overrideEnv['ANTHROPIC_API_BASE_URL'] = $BaseUrl
    $overrideEnv['CLAUDE_AGENT_API_BASE_URL'] = $BaseUrl
    $overrideEnv['ANTHROPIC_MODEL'] = $ModelForEnv
    $overrideEnv['ANTHROPIC_DEFAULT_SONNET_MODEL'] = $ModelLabel
    $overrideEnv['ANTHROPIC_DEFAULT_OPUS_MODEL'] = $ModelLabel
    $overrideEnv['ANTHROPIC_DEFAULT_HAIKU_MODEL'] = $ModelLabel
    $overrideEnv['ANTHROPIC_DEFAULT_FABLE_MODEL'] = $ModelLabel
    $overrideEnv['CLAUDE_CODE_ENABLE_GATEWAY_MODEL_DISCOVERY'] = '1'
    $overrideEnv['CLAUDE_CODE_DISABLE_UNKNOWN_MODEL_WINDOW_ENFORCEMENT'] = '0'
    if ($CtxForced) {
        $overrideEnv['CLAUDE_CODE_MAX_CONTEXT_TOKENS'] = $env:CLAUDE_CODE_MAX_CONTEXT_TOKENS
    }
    # 关掉 settings.json 里的 apiKeyHelper：本启动器已经把 token 放进
    # ANTHROPIC_AUTH_TOKEN，两者同时存在时 TUI 会挂一条
    # "Both ANTHROPIC_AUTH_TOKEN and apiKeyHelper set · auth may not work"
    # 的横幅。判定逻辑（2.1.310 二进制）是 ua().source !== "none" &&
    # kp().source !== "none"：把 helper 设成空串后 Ng() 返回假值，两条
    # 来源都落到 none，横幅不成立；同时 helper 也不会被执行（实测 marker
    # 探针：设真值时 CALLED，设空串时 NOT-CALLED）。
    # 注意不能写 null——会被判为非法设置直接丢弃并报 ERROR。
    $jsonOut = [ordered]@{ apiKeyHelper = ''; env = $overrideEnv } | ConvertTo-Json -Depth 4
    [IO.File]::WriteAllText($OverrideFile, $jsonOut, (New-Object Text.UTF8Encoding($false)))
    $PassArgs.Insert(0, $OverrideFile)
    $PassArgs.Insert(0, '--settings')
}
catch {
    Write-Note "ccr-claude: could not write the --settings overlay: $($_.Exception.Message)"
    Write-Note "  Keys of the same name in settings.json may override this run."
}

# ---------------------------------------------------------------- 记下选择
try {
    if (-not (Test-Path $StateDir)) { New-Item -ItemType Directory -Path $StateDir -Force | Out-Null }
    Set-Content -Path $LastFile -Value $ProfileId -Encoding Ascii -ErrorAction SilentlyContinue
}
catch { }

# ---------------------------------------------------------------- 找 claude
function Find-ClaudeExe {
    $c = Get-Command claude -ErrorAction SilentlyContinue
    if ($c) { return $c.Source }
    $here = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
    $local = Get-ChildItem -Path $here -Filter 'claude-*-win32-x64.exe' -File -ErrorAction SilentlyContinue |
        Sort-Object Name -Descending | Select-Object -First 1
    if ($local) { return $local.FullName }
    return $null
}

$ClaudeExe = Find-ClaudeExe
if (-not $ClaudeExe) {
    Stop-With "claude executable not found. Put it next to this script, or on PATH."
}

# ---------------------------------------------------------------- 报告
Write-Note "CCR profile: $ProfileId"
$ModelLine = $ModelForEnv
if ($ModelLabel -and $ModelLabel -ne $ModelForEnv) { $ModelLine = "$ModelForEnv ($ModelLabel)" }
Write-Note "Claude model: $ModelLine  (from $ModelSource)"
Write-Note "CCR: $BaseUrl"
# "没解析到就当作 200000" 是错的：本脚本什么都不设时，Claude Code 仍然会用
# settings.json 里的 autoCompactWindow，200000 只是最后兜底。
if ($env:CLAUDE_CODE_MAX_CONTEXT_TOKENS) {
    Write-Note "Context window: $env:CLAUDE_CODE_MAX_CONTEXT_TOKENS tokens"
}
elseif ($ContextWindowOff) {
    Write-Note "Context window: not set (--context-window off; Claude Code decides)"
}
else {
    Write-Note "Context window: unresolved here; Claude Code falls back to"
    Write-Note "                autoCompactWindow in settings.json, else 200000"
}

# ---------------------------------------------------------------- 启动
# claude 往 stderr 写 telemetry（[claude-code:unrecognized_model] 等）。当调用方
# 重定向 stderr（2>$null / 2>&1）时，PowerShell 5.1 会把这行当成 NativeCommandError
# 记录；而本脚本开了 $ErrorActionPreference='Stop'，于是 —— 哪怕命中的是
# Continue —— 它在往外抛的那一刻就中断了调用方。实测：直接 `-File` 跑没事，
# 被别的脚本 & 调用就断在启动那一行。启动前后临时放宽，不要影响后面的退出码。
$ErrorActionPreference = 'Continue'
& $ClaudeExe @PassArgs
$rc = $LASTEXITCODE
$ErrorActionPreference = 'Stop'
exit $rc
