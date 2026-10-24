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
  设定 CLAUDE_CODE_MAX_CONTEXT_TOKENS。不传就不设，沿用 settings.json。
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
$ContextWindow = 0
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
        '^--context-window$' { $ContextWindow = [int]$args[++$i]; break }
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
        import urllib.request

        model = (sys.argv[3] or "").strip()
        if not model:
            raise SystemExit(0)
        # [1m] 是 Claude Code 的窗口标注，目录和 modelMetadata 里都不带它。
        base_name = model.split("[", 1)[0].strip()
        prov, _, part = base_name.partition("/")
        if not part:
            prov, part = "", base_name
        model = base_name

        def to_int(v):
            try:
                n = int(float(v))
            except (TypeError, ValueError):
                return None
            return n if 0 < n <= 10_000_000 else None

        base, key, ctx, meta_names = "", "", None, []
        for p in cfg.get("Providers") or []:
            if prov not in ({p.get("name"), p.get("id")} - {None, ""}):
                continue
            base = (p.get("api_base_url") or p.get("baseUrl") or "").rstrip("/")
            key = p.get("api_key") or ""
            meta = p.get("modelMetadata") or {}
            meta_names = list(meta.keys())
            for name in (part, model):
                m = meta.get(name) or {}
                ctx = to_int(m.get("contextWindow") or m.get("context_window"))
                if ctx:
                    break
            break

        def probe(url, wanted):
            req = urllib.request.Request(url)
            if key:
                req.add_header("authorization", "Bearer " + key)
                req.add_header("x-api-key", key)
            with urllib.request.urlopen(req, timeout=1.5) as r:
                data = json.loads(r.read().decode("utf-8", "replace"))
            entries = data.get("data") or data.get("models") or []
            fields = ("context_window", "contextWindow",
                      "max_context_window", "max_model_len")
            for m in entries:
                ids = {m.get("id"), (m.get("id") or "").split("/")[-1]}
                if wanted & ids:
                    for f in fields:
                        v = to_int(m.get(f))
                        if v:
                            return v
            # 本地端点常常只挂一个模型，名字未必和 CCR 记的一致
            if len(entries) == 1:
                for f in fields:
                    v = to_int(entries[0].get(f))
                    if v:
                        return v
            return None

        wanted = {part, model} | set(meta_names)
        if ctx is None and re.match(r"^https?://(127\.|localhost|\[::1\])", base):
            for suffix in ("/models", "/v1/models"):
                try:
                    ctx = probe(base + suffix, wanted)
                except Exception:
                    ctx = None
                if ctx:
                    break

        if ctx is None:
            cats = [ccr / "models.json", ccr.parents[2] / ".codex" / "ccr-model-catalog.json"]
            for cat in cats:
                if not cat.is_file():
                    continue
                try:
                    data = json.loads(cat.read_text(encoding="utf-8"))
                except Exception:
                    continue
                for m in data.get("models") or []:
                    if wanted & {m.get("id"), m.get("slug"), m.get("model")}:
                        for f in ("context_window", "contextWindow",
                                  "max_context_window", "max_model_len"):
                            v = to_int(m.get(f))
                            if v:
                                ctx = v
                                break
                    if ctx:
                        break
                if ctx:
                    break

        if ctx:
            print(ctx)
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
        Write-Note "Models this profile allows:"
        for ($k = 0; $k -lt $Avail.Count; $k++) {
            $mark = if ($k -eq 0) { '  (current)' } else { '' }
            Write-Note ("  {0}) {1}{2}" -f ($k + 1), (ConvertTo-ShortModel $Avail[$k]), $mark)
        }
        $answer = Read-Host "Select [1] "
        if ([string]::IsNullOrWhiteSpace($answer)) { $RawModel = $Avail[0] }
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
if ($ContextWindow -gt 0) {
    $env:CLAUDE_CODE_MAX_CONTEXT_TOKENS = "$ContextWindow"
    $CtxForced = $true
}
elseif ($env:CCR_CONTEXT_WINDOW -eq 'off') {
    Remove-Item Env:CLAUDE_CODE_MAX_CONTEXT_TOKENS -ErrorAction SilentlyContinue
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
    $resolved = ((Invoke-CcrPy $PyProfiles @($CcrDir, 'ctx', $CcrModel)) -join '').Trim()
    if ($resolved -match '^\d+$') {
        $env:CLAUDE_CODE_MAX_CONTEXT_TOKENS = $resolved
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
if ($env:CLAUDE_CODE_MAX_CONTEXT_TOKENS) {
    Write-Note "Context window: $env:CLAUDE_CODE_MAX_CONTEXT_TOKENS tokens"
}
else {
    Write-Note "Context window: not set here; settings.json decides"
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
