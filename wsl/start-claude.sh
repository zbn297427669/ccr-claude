#!/usr/bin/env bash
#
# ccr-claude — 在 Linux/WSL 上按 CCR Agent profile 启动 Claude Code
#
# 不含任何密钥或本机路径。所需信息一律从环境变量或本地 CCR 安装目录发现：
#   - CCR 数据目录（config.sqlite / profiles / api key helpers）
#   - 网关地址（config 内 routerEndpoint / gateway，或 CCR_BASE_URL）
#   - 客户端密钥（api_keys 表或 bin/ccr-claude-code-api-key-*.cmd）
#   - 模型名（profile.model / settings.json / wrapper.cmd）
#
# 可选环境变量：
#   CCR_DIR              CCR 数据目录（含 config.sqlite）
#   CCR_BASE_URL         网关地址，默认从配置读，再回退 http://127.0.0.1:3456
#   CLAUDE_CONFIG_DIR    global-scope Claude settings 目录（含 settings.json）
#   CCR_PROFILE          直接指定 profile id / 名称片段
#   CCR_NO_PICK=1        多个 enabled 时不交互（优先上次选择，否则最近修改）
#   CCR_SKIP_CHECK=1     跳过网关 / token 预检
#   MODEL                临时覆盖模型（支持 CCR 长名，会转成短名）
#
set -euo pipefail

STATE_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/ccr-claude"
LAST_PROFILE_FILE="${CCR_LAST_PROFILE_FILE:-$STATE_DIR/last-profile}"

ccr_to_short_model() {
  local m="$1"
  m="${m##*/}"
  m="${m%%\[*}"
  printf '%s' "$m"
}

discover_ccr_dir() {
  if [[ -n "${CCR_DIR:-}" && -f "${CCR_DIR}/config.sqlite" ]]; then
    printf '%s' "$CCR_DIR"
    return 0
  fi

  local c
  for c in \
    "${XDG_CONFIG_HOME:-$HOME/.config}/claude-code-router" \
    "$HOME/.claude-code-router" \
    "$HOME/AppData/Roaming/claude-code-router"
  do
    if [[ -f "$c/config.sqlite" ]]; then
      printf '%s' "$c"
      return 0
    fi
  done

  local d
  if [[ -d /mnt/c/Users ]]; then
    for d in /mnt/c/Users/*/AppData/Roaming/claude-code-router; do
      if [[ -f "$d/config.sqlite" ]]; then
        printf '%s' "$d"
        return 0
      fi
    done
  fi

  return 1
}

discover_claude_config_dir() {
  if [[ -n "${CLAUDE_CONFIG_DIR:-}" && -d "$CLAUDE_CONFIG_DIR" ]]; then
    printf '%s' "$CLAUDE_CONFIG_DIR"
    return 0
  fi
  if [[ -n "${WIN_CLAUDE_HOME:-}" && -d "$WIN_CLAUDE_HOME" ]]; then
    printf '%s' "$WIN_CLAUDE_HOME"
    return 0
  fi

  local ccr="$1"
  if [[ "$ccr" =~ ^(.*/Users/[^/]+)/AppData/Roaming/claude-code-router$ ]]; then
    if [[ -d "${BASH_REMATCH[1]}/.claude" ]]; then
      printf '%s' "${BASH_REMATCH[1]}/.claude"
      return 0
    fi
  fi

  if [[ -d "$HOME/.claude" ]]; then
    printf '%s' "$HOME/.claude"
    return 0
  fi

  printf '%s' "$HOME/.claude"
}

discover_base_url() {
  if [[ -n "${CCR_BASE_URL:-}" ]]; then
    printf '%s' "$CCR_BASE_URL"
    return 0
  fi
  if [[ -n "${ANTHROPIC_BASE_URL:-}" ]]; then
    printf '%s' "$ANTHROPIC_BASE_URL"
    return 0
  fi

  local ccr="$1"
  local url
  url="$(python3 - "$ccr" <<'PY' 2>/dev/null || true
import json, shutil, sqlite3, sys, tempfile
from pathlib import Path
ccr = Path(sys.argv[1])
td = Path(tempfile.mkdtemp(prefix="ccr-url-"))
try:
    for n in ("config.sqlite", "config.sqlite-wal", "config.sqlite-shm"):
        p = ccr / n
        if p.exists():
            shutil.copy2(p, td / n)
    con = sqlite3.connect(f"file:{td / 'config.sqlite'}?mode=ro", uri=True)
    row = con.execute("select value_json from app_config where key='default'").fetchone()
    if not row:
        raise SystemExit(1)
    cfg = json.loads(row[0])
    ep = (cfg.get("routerEndpoint") or "").strip()
    if ep:
        print(ep.rstrip("/"))
        raise SystemExit(0)
    gw = cfg.get("gateway") or {}
    host = gw.get("host") or cfg.get("HOST") or "127.0.0.1"
    port = gw.get("port") or cfg.get("PORT") or 3456
    if host in ("0.0.0.0", "::"):
        host = "127.0.0.1"
    print(f"http://{host}:{port}")
finally:
    shutil.rmtree(td, ignore_errors=True)
PY
)"
  if [[ -n "$url" ]]; then
    printf '%s' "$url"
  else
    printf '%s' "http://127.0.0.1:3456"
  fi
}

# 一次读出全部 Claude Code profiles（JSON 数组），供后续逻辑复用
load_profiles_json() {
  python3 - "$CCR_DIR" "$CLAUDE_CONFIG_DIR" <<'PY'
import json, re, shutil, sqlite3, sys, tempfile
from pathlib import Path

ccr = Path(sys.argv[1])
claude_home = Path(sys.argv[2])

def short(m: str) -> str:
    m = (m or "").strip()
    m = m.rsplit("/", 1)[-1]
    return m.split("[", 1)[0]

def open_db():
    td = Path(tempfile.mkdtemp(prefix="ccr-db-"))
    for n in ("config.sqlite", "config.sqlite-wal", "config.sqlite-shm"):
        p = ccr / n
        if p.exists():
            shutil.copy2(p, td / n)
    con = sqlite3.connect(f"file:{td / 'config.sqlite'}?mode=ro", uri=True)
    return con, td

def token_for(con, pid: str) -> str:
    row = con.execute(
        "select encrypted_key, encryption from api_keys where id=?",
        (f"profile:{pid}",),
    ).fetchone()
    if row and row[0]:
        enc = (row[1] or "plain").lower()
        if enc == "plain":
            return row[0].strip()
        return ""  # encrypted: cannot use from this script
    for name in (
        f"ccr-claude-code-api-key-{pid}.cmd",
        f"ccr-claude-code-api-key-{pid}.sh",
    ):
        f = ccr / "bin" / name
        if not f.is_file():
            continue
        text = f.read_text(encoding="utf-8", errors="ignore")
        m = re.search(r"ccr-profile-[A-Za-z0-9_-]+", text)
        if m:
            return m.group(0)
    return ""

def settings_model(pid: str, scope: str) -> str:
    candidates = []
    if scope == "global":
        candidates.append(claude_home / "settings.json")
    candidates.append(ccr / "profiles" / pid / "claude" / "settings.json")
    for s in candidates:
        if not s.is_file():
            continue
        try:
            env = json.loads(s.read_text(encoding="utf-8")).get("env") or {}
        except Exception:
            continue
        for k in (
            "ANTHROPIC_MODEL",
            "CCR_CLAUDE_CODE_MODEL",
            "ANTHROPIC_DEFAULT_SONNET_MODEL",
        ):
            v = env.get(k)
            if isinstance(v, str) and v.strip():
                return v.strip()
    w = ccr / "bin" / f"ccr-claude-code-wrapper-{pid}.cmd"
    if w.is_file():
        m = re.search(
            r"^set ANTHROPIC_MODEL=(.+)$",
            w.read_text(encoding="utf-8", errors="ignore"),
            re.M,
        )
        if m:
            return m.group(1).strip().replace("^(", "(").replace("^)", ")")
    return ""

def mtime_for(pid: str, scope: str) -> float:
    paths = []
    if scope == "global":
        paths.append(claude_home / "settings.json")
    paths += [
        ccr / "profiles" / pid / "claude" / "settings.json",
        ccr / "bin" / f"ccr-claude-code-wrapper-{pid}.cmd",
    ]
    best = 0.0
    for p in paths:
        try:
            if p.is_file():
                best = max(best, p.stat().st_mtime)
        except OSError:
            pass
    return best

con, td = open_db()
try:
    row = con.execute("select value_json from app_config where key='default'").fetchone()
    cfg = json.loads(row[0]) if row else {}
    out = []
    for p in cfg.get("profile", {}).get("profiles") or []:
        if p.get("agent") != "claude-code":
            continue
        pid = p.get("id") or ""
        scope = p.get("scope") or "global"
        model = (p.get("model") or p.get("sonnetModel") or "").strip()
        if not model:
            model = settings_model(pid, scope)
        token = token_for(con, pid)
        # The profile's allowed models, so the launcher can offer them as a
        # menu. Kept as the gateway spells them (Provider/model) because that
        # is what --model has to receive; the picker shows the short form and
        # passes the long one through untouched.
        avail = p.get("availableModels") or p.get("available_models") or []
        avail = [m for m in avail if isinstance(m, str) and m.strip()]
        if model and model not in avail:
            avail.insert(0, model)
        out.append(
            {
                "id": pid,
                "name": p.get("name") or pid,
                "model": model,
                "short": short(model),
                "enabled": bool(p.get("enabled", True)),
                "scope": scope,
                "mtime": mtime_for(pid, scope),
                "has_token": bool(token),
                "available": avail,
            }
        )
    json.dump(out, sys.stdout, ensure_ascii=False)
finally:
    con.close()
    shutil.rmtree(td, ignore_errors=True)
PY
}

# 对缓存的 profiles JSON 文件查询（不再反复读 sqlite）
profiles_query() {
  python3 - "$PROFILES_JSON_FILE" "$@" <<'PY'
import json, sys
from pathlib import Path

profiles = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
mode = sys.argv[2]
arg = sys.argv[3] if len(sys.argv) > 3 else ""
last = sys.argv[4] if len(sys.argv) > 4 else ""

def active():
    cands = [
        p
        for p in profiles
        if p.get("enabled") and p.get("model") and p.get("has_token")
    ]
    cands.sort(key=lambda p: p.get("mtime") or 0, reverse=True)
    if last:
        preferred = [p for p in cands if p.get("id") == last]
        others = [p for p in cands if p.get("id") != last]
        if preferred:
            return preferred + others
    return cands

if mode == "all":
    for p in sorted(profiles, key=lambda x: x.get("id") or ""):
        print(
            "\t".join(
                [
                    p.get("id") or "",
                    p.get("name") or "",
                    p.get("scope") or "",
                    p.get("model") or "",
                    str(int(bool(p.get("enabled")))),
                    str(int(bool(p.get("has_token")))),
                ]
            )
        )
elif mode == "active":
    cands = active()
    if not cands:
        sys.exit(1)
    for p in cands:
        print(f"{p.get('id') or ''}\t{p.get('name') or ''}\t{p.get('short') or ''}")
elif mode == "models":
    # One line per selectable model for a profile: long\tname\tshort
    # where long is what --model must receive. The profile's current model is
    # already first in the list, so an empty answer picks the default.
    # `short` lives in the shell, not in this heredoc, so it is spelled out.
    def _short(m):
        m = (m or "").strip()
        m = m.rsplit("/", 1)[-1]
        return m.split("[", 1)[0]

    want = arg
    for p in profiles:
        if want and p.get("id") != want:
            continue
        for m in (p.get("available") or []):
            print(f"{m}\t{_short(m)}\t{p.get('id') or ''}")
elif mode == "resolve":
    want = arg
    matches = []
    for p in profiles:
        pid, name = p.get("id") or "", p.get("name") or ""
        if want == pid or want == name or want in pid or want in name:
            matches.append(p)
    exact = [
        p
        for p in matches
        if want == (p.get("id") or "") or want == (p.get("name") or "")
    ]
    use = exact or matches
    if len(use) == 0:
        sys.exit(1)
    if len(use) > 1:
        for p in use:
            print(f"{p.get('id') or ''}\t{p.get('name') or ''}", file=sys.stderr)
        sys.exit(2)
    print(use[0]["id"])
elif mode == "field":
    pid, field = arg.split("\t", 1) if "\t" in arg else (arg, "model")
    for p in profiles:
        if p.get("id") == pid:
            val = p.get(field) or ""
            if field == "model" and not val:
                val = ""
            if val:
                print(val)
                sys.exit(0)
            sys.exit(1)
    sys.exit(1)
else:
    sys.exit(2)
PY
}

# 仅在选定 profile 后读一次密钥（不把 token 放进缓存 JSON / argv）
read_profile_token() {
  python3 - "$CCR_DIR" "$1" <<'PY'
import re, shutil, sqlite3, sys, tempfile
from pathlib import Path

ccr = Path(sys.argv[1])
pid = sys.argv[2]
td = Path(tempfile.mkdtemp(prefix="ccr-tok-"))
try:
    for n in ("config.sqlite", "config.sqlite-wal", "config.sqlite-shm"):
        p = ccr / n
        if p.exists():
            shutil.copy2(p, td / n)
    con = sqlite3.connect(f"file:{td / 'config.sqlite'}?mode=ro", uri=True)
    row = con.execute(
        "select encrypted_key, encryption from api_keys where id=?",
        (f"profile:{pid}",),
    ).fetchone()
    if row and row[0] and (row[1] or "plain").lower() == "plain":
        print(row[0].strip())
        raise SystemExit(0)
    for name in (
        f"ccr-claude-code-api-key-{pid}.cmd",
        f"ccr-claude-code-api-key-{pid}.sh",
    ):
        f = ccr / "bin" / name
        if not f.is_file():
            continue
        m = re.search(
            r"ccr-profile-[A-Za-z0-9_-]+",
            f.read_text(encoding="utf-8", errors="ignore"),
        )
        if m:
            print(m.group(0))
            raise SystemExit(0)
    raise SystemExit(1)
finally:
    shutil.rmtree(td, ignore_errors=True)
PY
}

read_last_profile() {
  [[ -f "$LAST_PROFILE_FILE" ]] || return 1
  local id
  id="$(tr -d '[:space:]' <"$LAST_PROFILE_FILE" || true)"
  [[ -n "$id" ]] || return 1
  printf '%s' "$id"
}

save_last_profile() {
  local id="$1"
  mkdir -p "$STATE_DIR" 2>/dev/null || return 0
  printf '%s\n' "$id" >"$LAST_PROFILE_FILE" 2>/dev/null || true
}

# CCR Desktop writes environment variables into the selected profile's
# Windows wrapper (.cmd), but a Claude process launched inside WSL cannot
# inherit them. Import only path-independent, non-secret keys; an existing
# WSL value always wins.
import_ccr_wrapper_env() {
  local pid="$1" wrapper line key value
  wrapper="$CCR_DIR/bin/ccr-claude-code-wrapper-${pid}.cmd"
  [[ -f "$wrapper" ]] || return 0

  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ "$line" =~ ^[[:space:]]*set[[:space:]]+([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]] || continue
    key="${BASH_REMATCH[1]}"
    value="${BASH_REMATCH[2]%$'\r'}"
    case "$key" in
      CLAUDE_CODE_MAX_CONTEXT_TOKENS|\
      CLAUDE_CODE_DISABLE_UNKNOWN_MODEL_WINDOW_ENFORCEMENT|\
      CLAUDE_CODE_ENABLE_GATEWAY_MODEL_DISCOVERY)
        ;;
      *) continue ;;
    esac
    [[ -n "$value" ]] || continue
    if [[ ! -v "$key" ]]; then
      printf -v "$key" '%s' "$value"
      export "$key"
    fi
  done <"$wrapper"
}

# Can this model accept the request shape Claude Code sends?
#
# Claude Code puts defer_loading: true on one built-in placeholder tool in every
# request. An upstream that has no deferred tool loader rejects the whole request
# with a 400 -- not the tool, the request -- so the model cannot be used at all.
# Neither side is wrong: Claude Code is optimising, and the engine is entitled
# to refuse a field it cannot honour. They simply never agreed.
#
# On the client side this cannot be turned off. --disallowedTools does not reach
# the placeholder, an empty --mcp-config does not remove it, and the documented
# alwaysLoad escape hatch only covers user-configured MCP servers.
#
# So probe instead of guessing: send the smallest request that carries the flag,
# and report what came back. A model that answers is fine; one that refuses with
# deferred-tool language is unusable through Claude Code until CCR or the engine
# changes. Any other failure (not running, auth, timeout) says nothing about this
# capability and is reported as unknown rather than as a verdict.
#
# Returns: ok | no-defer | unknown | (empty, when there is nothing to probe)
# Disable with CCR_CAPABILITY_CHECK=off.
probe_defer_support() {
  local model="$1" token="$2" base="$3"
  [[ "${CCR_CAPABILITY_CHECK:-}" == "off" ]] && return 0
  [[ -n "$model" && -n "$base" ]] || return 0

  python3 - "$base" "$model" "$token" <<'PY' 2>/dev/null || true
import json, sys, urllib.error, urllib.request

base, model, token = sys.argv[1], sys.argv[2], sys.argv[3]
body = {
    "model": model,
    "max_tokens": 1,
    "messages": [{"role": "user", "content": "ping"}],
    "tools": [{
        "name": "probe",
        "description": "capability probe",
        "input_schema": {"type": "object", "properties": {}},
        "defer_loading": True,
    }],
}
req = urllib.request.Request(
    base.rstrip("/") + "/v1/messages",
    data=json.dumps(body).encode(),
    headers={"content-type": "application/json", "authorization": "Bearer " + token},
    method="POST",
)
try:
    # A local engine cold-starts this in about 19 s here: the prompt is tiny but
    # the first request pays the KV setup. 8 s reported "could not verify" on a
    # model that was working, which is worse than saying nothing -- the operator
    # reads it as a fault.
    with urllib.request.urlopen(req, timeout=45) as r:
        r.read(4096)
    print("ok")
except urllib.error.HTTPError as e:
    text = ""
    try:
        text = e.read().decode("utf-8", "replace")
    except Exception:
        pass
    low = text.lower()
    if "defer" in low and ("not support" in low or "unsupported" in low
                           or "does not provide" in low):
        print("no-defer")
    elif e.code in (401, 403):
        print("unknown")
    else:
        print("unknown")
except Exception:
    print("unknown")
PY
}

# Ask the model how big its context is, instead of asking the user.
#
# Why this exists: Claude Code and CCR have no channel for this value. CCR knows
# a model's window (it probes /v1/models and stores contextWindow), and its
# gateway even advertises the model to Claude Code -- but the gateway's model
# list carries no window field, and Claude Code's gateway cache schema
# ({id, display_name, icon_url, ...}) has nowhere to put one. Claude Code
# therefore assumes 200000 for anything it does not recognise, and the
# "Detected automatically" placeholder in CCR's model panel is a placeholder,
# not a reading. The value that actually decides where compaction fires is
# CLAUDE_CODE_MAX_CONTEXT_TOKENS (it clamps modelSettings.*.autoCompactWindow,
# verified), so this sets that one.
#
# Sources, best first:
#   1. the provider's own /v1/models, when it is a loopback endpoint we can reach
#   2. the provider's stored modelMetadata.contextWindow (CCR's last probe)
#   3. CCR's shipped catalog (models.json), then the per-install catalog under
#      ~/.codex -- but only when the entries agree, and only when the value is
#      not CCR's own 128000 placeholder for "no metadata"
# Nothing found: stay silent and set nothing. Leaving it unset is better than
# guessing -- a wrong value is a silent compaction at the wrong point. Source 3
# is the one that broke this rule: its file stores a default, not a reading.
#
# Override with CCR_CONTEXT_WINDOW=<tokens>, or disable with
# CCR_CONTEXT_WINDOW=off.
#
# Takes many models and prints `model<TAB>tokens` for each one that resolves,
# because the picker wants the whole menu at once. One call opens config.sqlite
# and the catalogs once and probes a loopback provider once, however many models
# ask about it; doing this per menu line would re-read the same files a dozen
# times. Resolving one model is a list of one.
resolve_context_windows() {
  [[ $# -gt 0 ]] || return 0
  local m
  [[ "${CCR_CONTEXT_WINDOW:-}" == "off" ]] && return 0
  if [[ "${CCR_CONTEXT_WINDOW:-}" =~ ^[0-9]+$ ]]; then
    # A forced value applies to every model, which is what the menu should show.
    for m in "$@"; do
      printf '%s\t%s\n' "$m" "$CCR_CONTEXT_WINDOW"
    done
    return 0
  fi

  python3 - "$CCR_DIR" "$@" <<'PY' 2>/dev/null || true
import json, re, shutil, sqlite3, sys, tempfile, urllib.request
from pathlib import Path

ccr = Path(sys.argv[1])
raws = [a.strip() for a in sys.argv[2:] if (a or "").strip()]
if not raws:
    sys.exit(0)


def open_db():
    td = Path(tempfile.mkdtemp(prefix="ccr-ctx-"))
    for n in ("config.sqlite", "config.sqlite-wal", "config.sqlite-shm"):
        p = ccr / n
        if p.exists():
            shutil.copy2(p, td / n)
    return sqlite3.connect(f"file:{td / 'config.sqlite'}?mode=ro", uri=True), td


def to_int(v):
    try:
        n = int(float(v))
    except (TypeError, ValueError):
        return None
    return n if 0 < n <= 10_000_000 else None


# The window CCR invents for a model it has no metadata for. Verified in its
# bundle (`var VX="Fusion",KFe=128e3,zFe=95`), and it reproduces all 14 entries
# of a real per-install catalog. A value equal to this in that file carries no
# information: it is what "unknown" looks like.
CCR_PLACEHOLDER_WINDOW = 128000


def split_name(name):
    provider, _, part = name.partition("/")
    if not part:
        provider, part = "", name
    return provider, part


def window_of(entry):
    """Every shape a window shows up in, in one place.

    Flat fields are what an endpoint returns. `limits` is what CCR's shipped
    catalog uses -- and that catalog had been read with the flat-field loop
    alone, so this branch never matched a single entry.
    """
    for f in ("context_window", "contextWindow", "max_context_window",
              "max_model_len"):
        v = to_int(entry.get(f))
        if v:
            return v
    lim = entry.get("limits")
    if isinstance(lim, dict):
        return to_int(lim.get("contextTokens")) or to_int(lim.get("inputTokens"))
    return None


# ---- provider metadata, read once for the whole list -----------------------

providers = {}     # CCR provider name -> {base, key, meta}
try:
    con, td = open_db()
except Exception:
    con, td = None, None
try:
    if con is not None:
        row = con.execute(
            "select value_json from app_config where key='default'"
        ).fetchone()
        cfg = json.loads(row[0]) if row else {}
        for p in cfg.get("Providers") or []:
            entry = {
                "base": (p.get("api_base_url") or p.get("baseUrl") or "").rstrip("/"),
                "key": p.get("api_key") or "",
                "meta": p.get("modelMetadata") or {},
            }
            for n in {p.get("name"), p.get("id")} - {None, ""}:
                providers[n] = entry
finally:
    if con is not None:
        try:
            con.close()
        finally:
            shutil.rmtree(td, ignore_errors=True)


# ---- catalogs, loaded at most once ----------------------------------------

catalogs = []      # [(label, data)]


def catalog_data():
    if catalogs:
        return catalogs
    paths = [("models.json", ccr / "models.json")]
    if re.match(r"^/mnt/[a-z]/", str(ccr)):
        # .../AppData/Roaming/claude-code-router -> .../.codex/ccr-model-catalog.json
        paths.append(("catalog", ccr.parents[2] / ".codex" / "ccr-model-catalog.json"))
    else:
        paths.append(("catalog", Path.home() / ".codex" / "ccr-model-catalog.json"))
    for label, path in paths:
        if not path.is_file():
            continue
        try:
            catalogs.append((label, json.loads(path.read_text(encoding="utf-8"))))
        except Exception:
            pass
    return catalogs


probed = {}        # provider base -> {model id: window, "__single__": window}


def probed_windows(base, key):
    """Every window the provider advertises, keyed by each id it answers to.

    One map per provider, because a menu asks about a dozen models behind the
    same endpoint and each request costs a round trip (and, for a local engine,
    a cold start).

    A local endpoint often serves one model under the id it was built with,
    which need not be the name CCR or the profile uses (here: CCR says
    bonsai-v3, the artifact answers as bonsai-heretic). A single-model endpoint
    is unambiguous, so its window is also filed under "__single__" -- the
    caller uses that only for models whose provider is this same endpoint, so a
    cloud model never inherits a local window.
    """
    if base not in probed:
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
                # A timeout means something is listening but not answering --
                # an engine that is cold or mid-load. The second path is the
                # same server, so it would time out too; only a refusal or a
                # 404 (answered instantly) is worth a second try. Without this
                # a dead local engine stalls the menu for 3s instead of 1.5s.
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
            if len(entries) == 1 and found:
                found["__single__"] = next(iter(found.values()))
            if found:
                break
        probed[base] = found
    return probed[base]


def resolve(name):
    provider, part = split_name(name)
    p = providers.get(provider) or {}
    meta = p.get("meta") or {}
    # Only this model's own names. The provider's other models are not
    # candidates: an earlier version also matched every name in its metadata,
    # which made `deepseek-v4.1-flash` inherit whatever its neighbours in
    # models.json happened to declare.
    wanted = {part, name}

    # 2. CCR's own last probe, stored on the provider
    for key in (part, name):
        v = to_int((meta.get(key) or {}).get("contextWindow")
                   or (meta.get(key) or {}).get("context_window"))
        if v:
            return v

    # 1. the endpoint itself, when it is on this machine
    base = p.get("base") or ""
    if re.match(r"^https?://(127\.|localhost|\[::1\])", base):
        found = probed_windows(base, p.get("key") or "")
        for k in wanted:
            if k in found:
                return found[k]
        if "__single__" in found:
            return found["__single__"]

    # 3. Catalogs. `models.json` first: it ships with CCR and is built from
    #    provider metadata, so a value there is a reading. The per-install
    #    catalog under .codex is generated for Codex and fills in a hard-coded
    #    128000 whenever a model has no provider metadata -- a guess (see below).
    for label, data in catalog_data():
        # One model name can map to several entries -- `deepseek/deepseek-v4.1-flash`
        # says 1050000, `alibaba/...` says 1000000, and both list the same model
        # name. Taking whichever came first would be a coin flip, so require
        # them to agree. "Agree" means within 10%: a 5% spread is the same model
        # seen by two providers, and the smaller number is the safe one (it can
        # only compact early, never late). A wider spread means the name really
        # does mean two different things, and then this file knows nothing.
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
        # CCR writes 128000 for any model it has no metadata for (KFe in its
        # bundle: `function p1e(e,t=jt(e)){return si(t)||KFe}`). That is its
        # default, not a probe, so it cannot be told apart from "CCR does not
        # know" -- and treating it as a reading is what silently pulled an
        # explicitly configured 800000 down to 128000 here.
        if label == "catalog" and v == CCR_PLACEHOLDER_WINDOW:
            continue
        return v
    return None


# The caller passes the names exactly as the menu shows them and gets them back
# the same way, tab-separated from the window, so a name containing a slash or
# a [1m] marker still lines up with its row. Repeated spellings of the same
# model resolve once and are all printed, because the menu may list both.
cache = {}
for raw in raws:
    n = (raw or "").split("[", 1)[0].strip()
    if not n:
        continue
    if n not in cache:
        cache[n] = resolve(n)
    if cache[n]:
        print(f"{raw}\t{cache[n]}")
PY
}

# One model's window, for the launch-time export. Wraps the list version so the
# two can never disagree about where a number came from.
resolve_context_window() {
  local out
  out="$(resolve_context_windows "$1" 2>/dev/null || true)"
  [[ -n "$out" ]] || return 0
  printf '%s' "${out#*$'\t'}"
}

# A window as a menu label.
#
# One decimal of M above a million, which is exactly a 100K step: enough to
# tell 1.0M from 1.1M, and that is the whole job of the column. Below a million
# it stays in K, because rounding 128K to "100K" would cost 28% -- there a plain
# "128K" is both more honest and shorter. A "~" marks a value that was rounded.
fmt_window() {
  local n="${1:-}" m k approx
  [[ "$n" =~ ^[0-9]+$ ]] || return 0
  if (( n >= 1000000 )); then
    m=$(( (n + 50000) / 100000 ))
    approx=""
    if (( m * 100000 != n )); then approx="~"; fi
    printf '%s%d.%dM' "$approx" "$(( m / 10 ))" "$(( m % 10 ))"
  else
    k=$(( (n + 500) / 1000 ))
    approx=""
    if (( k * 1000 != n )); then approx="~"; fi
    printf '%s%dK' "$approx" "$k"
  fi
}

resolve_profile_id() {
  local want="$1" out rc
  set +e
  out="$(profiles_query resolve "$want" 2>/tmp/ccr-claude-resolve.err)"
  rc=$?
  set -e
  if [[ $rc -eq 0 && -n "$out" ]]; then
    printf '%s' "$out"
    return 0
  fi
  if [[ $rc -eq 2 ]]; then
    echo "Profile \"$want\" is ambiguous; matches:" >&2
    sed 's/^/  /' /tmp/ccr-claude-resolve.err >&2 || true
    echo "Use a more specific --profile id/name." >&2
    return 2
  fi
  return 1
}

pick_profile() {
  local force_pick="${1:-0}"
  local -a ids names models
  local id name model i choice last default_idx=1 mark

  last="$(read_last_profile || true)"

  while IFS=$'\t' read -r id name model; do
    [[ -z "$id" ]] && continue
    ids+=("$id")
    names+=("$name")
    models+=("$model")
  done < <(profiles_query active "" "$last")

  [[ ${#ids[@]} -gt 0 ]] || return 1

  if [[ ${#ids[@]} -eq 1 ]]; then
    printf '%s' "${ids[0]}"
    return 0
  fi

  # 默认序号：上次用过的排在第 1（active 已重排），保持 1
  default_idx=1

  if [[ "$force_pick" != "1" ]]; then
    if [[ ! -t 0 || "${CCR_NO_PICK:-0}" == "1" ]]; then
      printf '%s' "${ids[0]}"
      return 0
    fi
    for a in "${PASS_ARGS[@]+"${PASS_ARGS[@]}"}"; do
      if [[ "$a" == "-p" || "$a" == "--print" ]]; then
        printf '%s' "${ids[0]}"
        return 0
      fi
    done
  fi

  {
    echo "Multiple enabled CCR Claude Code agents — pick one:"
    for i in "${!ids[@]}"; do
      mark=""
      if [[ -n "$last" && "${ids[i]}" == "$last" ]]; then
        mark="  (last)"
      fi
      printf "  %d) %s  [%s]  (%s)%s\n" "$((i + 1))" "${names[i]}" "${models[i]}" "${ids[i]}" "$mark"
    done
    echo "  0) cancel"
  } >&2

  while true; do
    choice=""
    if [[ -t 0 ]]; then
      read -r -p "Number [${default_idx}]: " choice || choice=""
    else
      read -r choice || choice=""
    fi
    choice="${choice:-$default_idx}"
    if [[ "$choice" == "0" ]]; then
      echo "Cancelled." >&2
      exit 130
    fi
    if [[ "$choice" =~ ^[0-9]+$ ]] && ((choice >= 1 && choice <= ${#ids[@]})); then
      printf '%s' "${ids[choice - 1]}"
      return 0
    fi
    echo "Invalid number, try again." >&2
  done
}

# Which model to use for this profile.
#
# Only offered when the profile allows more than one and stdin is a terminal.
# A piped run, a -p run, or a single-model profile all take the default without
# asking: a prompt in a script is a hang, and a menu of one is noise.
#
# The list comes from the profile's availableModels, which is also what CCR's
# gateway enforces -- so anything offered here is something the gateway will
# accept. The current model is first, so pressing Enter keeps today's behaviour.
#
# Each row carries the model's own context window, because the choice is
# otherwise made blind: two models 4x apart in context look identical in a list
# of names. The number is resolved once for the whole menu, in one Python
# process, rather than once per row.
#
# It is the model's window, not necessarily where compaction fires: when
# settings.json pins a lower autoCompactWindow for that model, Claude Code takes
# min(window, pin) at runtime. The pin is not applied here, because the same
# resolver feeds CLAUDE_CODE_MAX_CONTEXT_TOKENS, which must stay a statement
# about the model.
pick_model() {
  local pid="$1" force="${2:-0}"
  # Declared non-empty: `set -u` treats an unset array as an error even when
  # the reference is guarded by a count check, because the count itself was
  # read from an unset variable.
  local -a longs=() shorts=() windows=()
  local long short_line i choice default_idx=1 mark win_label

  while IFS=$'\t' read -r long short_line _; do
    [[ -z "$long" ]] && continue
    longs+=("$long")
    shorts+=("$short_line")
  done < <(profiles_query models "$pid" || true)

  [[ ${#longs[@]} -gt 0 ]] || return 1

  # One choice is still worth showing when asked for explicitly: the caller
  # then gets confirmation of what will run instead of silence.
  if [[ ${#longs[@]} -eq 1 && "$force" != "1" ]]; then
    printf '%s' "${longs[0]}"
    return 0
  fi

  if [[ "$force" != "1" ]]; then
    [[ -t 0 ]] || { printf '%s' "${longs[0]}"; return 0; }
    [[ "${CCR_NO_PICK:-0}" == "1" ]] && { printf '%s' "${longs[0]}"; return 0; }
    for a in "${PASS_ARGS[@]+"${PASS_ARGS[@]}"}"; do
      [[ "$a" == "-p" || "$a" == "--print" ]] && { printf '%s' "${longs[0]}"; return 0; }
    done
  fi

  local -A win_of=()
  while IFS=$'\t' read -r long win_label; do
    [[ -n "$long" ]] || continue
    win_of["$long"]="$win_label"
  done < <(resolve_context_windows "${longs[@]}" || true)

  {
    echo "Models this profile allows — pick one (context window in brackets):"
    for i in "${!longs[@]}"; do
      mark=""
      ((i == 0)) && mark="  (current)"
      win_label="$(fmt_window "${win_of["${longs[i]}"]:-}")"
      [[ -n "$win_label" ]] || win_label="unknown"
      printf "  %d) %s  [%s]%s\n" "$((i + 1))" "${shorts[i]}" "$win_label" "$mark"
    done
    echo "  0) cancel"
  } >&2

  while true; do
    choice=""
    if [[ -t 0 ]]; then
      read -r -p "Number [${default_idx}]: " choice || choice=""
    else
      read -r choice || choice=""
    fi
    choice="${choice:-$default_idx}"
    if [[ "$choice" == "0" ]]; then
      echo "Cancelled." >&2
      exit 130
    fi
    if [[ "$choice" =~ ^[0-9]+$ ]] && ((choice >= 1 && choice <= ${#longs[@]})); then
      printf '%s' "${longs[choice - 1]}"
      return 0
    fi
    echo "Invalid number, try again." >&2
  done
}

# 网关可达 + 当前 profile token 可用
preflight_check() {
  local base="$1" token="$2" profile="$3"
  local code body

  if ! command -v curl >/dev/null 2>&1; then
    echo "warning: curl not found; skipping gateway preflight." >&2
    return 0
  fi

  if ! curl -fsS -m 3 "$base/" >/dev/null 2>&1 && \
     ! curl -fsS -m 3 "$base/health" >/dev/null 2>&1; then
    echo "CCR gateway unreachable: $base" >&2
    echo "Start CCR Desktop / gateway, or set CCR_BASE_URL." >&2
    return 1
  fi

  body="$(mktemp)"
  code="$(curl -sS -m 8 -o "$body" -w '%{http_code}' \
    -H "Authorization: Bearer ${token}" \
    "$base/v1/models" 2>/dev/null || echo "000")"

  if [[ "$code" == "200" ]]; then
    rm -f "$body"
    return 0
  fi

  echo "CCR auth/preflight failed for profile \"$profile\" (HTTP $code)." >&2
  if [[ "$code" == "401" || "$code" == "403" ]]; then
    echo "Client key looks invalid or not allowed. Re-save/enable the agent in CCR Desktop, then retry." >&2
  elif [[ "$code" == "000" ]]; then
    echo "Could not complete request to $base/v1/models." >&2
  else
    head -c 300 "$body" >&2 || true
    echo >&2
  fi
  rm -f "$body"
  return 1
}

usage() {
  cat <<'EOF'
Usage:
  ccr-claude                      # interactive pick when multiple agents enabled
  ccr-claude --pick               # force menu
  ccr-claude --profile <id|name>  # select by id / name substring (errors if ambiguous)
  ccr-claude --list-profiles
  ccr-claude --model <short-or-long-name>
  ccr-claude --context-window <tokens|off>
  MODEL=<name> ccr-claude

Environment:
  CCR_DIR             CCR data dir (contains config.sqlite)
  CCR_BASE_URL        Gateway URL (else read from CCR config)
  CLAUDE_CONFIG_DIR   Global Claude settings dir (else derived / ~/.claude)
  CCR_PROFILE         Same as --profile
  CCR_NO_PICK=1       Never prompt; prefer last used, else most recently modified
  CCR_SKIP_CHECK=1    Skip gateway / token preflight
  CCR_CONTEXT_WINDOW  Same as --context-window
  MODEL               Temporary model override

Context window:
  By default the window comes from the provider's own metadata, a loopback
  endpoint's /models, or CCR's catalogs -- see CONTEXT-WINDOW.md. The menu
  shows the resolved value per model. --context-window overrides all of it;
  "off" means set nothing and let Claude Code decide.

Last selected profile is stored in:
  ${XDG_CONFIG_HOME:-~/.config}/ccr-claude/last-profile
EOF
}

# ---------- resolve install paths ----------
CCR_DIR="$(discover_ccr_dir)" || {
  echo "CCR data directory not found (need config.sqlite)." >&2
  echo "Set CCR_DIR, e.g. export CCR_DIR=\"\$HOME/AppData/Roaming/claude-code-router\"" >&2
  echo "WSL example: export CCR_DIR=\"/mnt/c/Users/<you>/AppData/Roaming/claude-code-router\"" >&2
  exit 1
}
CLAUDE_CONFIG_DIR="$(discover_claude_config_dir "$CCR_DIR")"
CCR_BASE_URL="$(discover_base_url "$CCR_DIR")"

PROFILES_JSON_FILE="$(mktemp "${TMPDIR:-/tmp}/ccr-claude-profiles.XXXXXX")"
cleanup_profiles_cache() { rm -f "$PROFILES_JSON_FILE"; }
trap cleanup_profiles_cache EXIT

load_profiles_json >"$PROFILES_JSON_FILE" || {
  echo "Failed to read CCR profiles from: $CCR_DIR" >&2
  exit 1
}

PROFILE_WANT="${CCR_PROFILE:-}"
RAW_MODEL="${MODEL:-}"
MODEL_SOURCE=""
FORCE_PICK=0
FORCE_PICK_MODEL=0
SKIP_CHECK="${CCR_SKIP_CHECK:-0}"
PASS_ARGS=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --list-profiles)
      printf '%s\n' "ID	NAME	ENABLED	TOKEN	MODEL"
      while IFS=$'\t' read -r id name scope model enabled has_token; do
        short="$(ccr_to_short_model "$model")"
        en="no"; [[ "$enabled" == "1" ]] && en="yes"
        tok="no"; [[ "$has_token" == "1" ]] && tok="yes"
        printf '%s\t%s\t%s\t%s\t%s\n' "$id" "$name" "$en" "$tok" "${short:-"(none)"}"
      done < <(profiles_query all)
      echo "CCR_DIR=$CCR_DIR" >&2
      echo "CCR_BASE_URL=$CCR_BASE_URL" >&2
      if last="$(read_last_profile || true)"; [[ -n "${last:-}" ]]; then
        echo "LAST_PROFILE=$last" >&2
      fi
      exit 0
      ;;
    --pick) FORCE_PICK=1; shift ;;
    --pick-model) FORCE_PICK_MODEL=1; shift ;;
    --skip-check) SKIP_CHECK=1; shift ;;
    # Consumed here rather than passed through: `claude` has no such flag, and
    # the value is exported as CLAUDE_CODE_MAX_CONTEXT_TOKENS lower down.
    --context-window)
      CCR_CONTEXT_WINDOW="${2:-}"
      [[ -n "$CCR_CONTEXT_WINDOW" ]] || { echo "missing --context-window value" >&2; exit 1; }
      shift 2
      ;;
    --context-window=*)
      CCR_CONTEXT_WINDOW="${1#--context-window=}"
      shift
      ;;
    --profile)
      PROFILE_WANT="${2:-}"
      [[ -n "$PROFILE_WANT" ]] || { echo "missing --profile value" >&2; exit 1; }
      shift 2
      ;;
    --profile=*) PROFILE_WANT="${1#--profile=}"; shift ;;
    --model)
      RAW_MODEL="${2:-}"
      MODEL_SOURCE="--model"
      [[ -n "$RAW_MODEL" ]] || { echo "missing --model value" >&2; exit 1; }
      PASS_ARGS+=("$1" "$2")
      shift 2
      ;;
    --model=*)
      RAW_MODEL="${1#--model=}"
      MODEL_SOURCE="--model"
      PASS_ARGS+=("$1")
      shift
      ;;
    *) PASS_ARGS+=("$1"); shift ;;
  esac
done

if [[ -n "$PROFILE_WANT" ]]; then
  set +e
  PROFILE_ID="$(resolve_profile_id "$PROFILE_WANT")"
  resolve_rc=$?
  set -e
  if [[ $resolve_rc -eq 2 ]]; then
    exit 1
  fi
  if [[ $resolve_rc -ne 0 || -z "${PROFILE_ID:-}" ]]; then
    echo "CCR profile not found: $PROFILE_WANT" >&2
    profiles_query all | awk -F'\t' '{print "  "$1"  "$2}' >&2
    exit 1
  fi
else
  PROFILE_ID="$(pick_profile "$FORCE_PICK")" || {
    echo "No enabled Claude Code profile with model + token in CCR." >&2
    echo "CCR_DIR=$CCR_DIR" >&2
    exit 1
  }
fi

TOKEN="$(read_profile_token "$PROFILE_ID")" || {
  echo "No API token for profile: $PROFILE_ID" >&2
  echo "Re-save/enable the agent in CCR Desktop, then retry." >&2
  exit 1
}

PROFILE_MODEL="$(profiles_query field "${PROFILE_ID}"$'\t'"model" || true)"

# A model named on the command line (or in MODEL) is a decision already made;
# only the fall-through-to-the-profile case offers the menu.
MODEL_PICKED=""
if [[ -n "${MODEL:-}" && -z "$MODEL_SOURCE" ]]; then
  RAW_MODEL="$MODEL"
  MODEL_SOURCE="MODEL env"
elif [[ -z "$RAW_MODEL" ]]; then
  if [[ -n "$PROFILE_MODEL" ]]; then
    RAW_MODEL="$PROFILE_MODEL"
    MODEL_SOURCE="CCR profile:$PROFILE_ID"
  else
    echo "Profile $PROFILE_ID has no model configured." >&2
    exit 1
  fi
  # Offer the profile's other models. pick_model prints the default and asks
  # nothing when the profile allows one model, when stdin is not a terminal, or
  # when -p is among the forwarded arguments -- so a script never sees a prompt.
  if picked="$(pick_model "$PROFILE_ID" "${FORCE_PICK_MODEL:-0}")" && [[ -n "$picked" ]]; then
    if [[ "$picked" != "$RAW_MODEL" ]]; then
      MODEL_PICKED="$picked"
      RAW_MODEL="$picked"
      MODEL_SOURCE="picked"
    fi
  fi
elif [[ -z "$MODEL_SOURCE" ]]; then
  MODEL_SOURCE="arg"
fi

DEFAULT_MODEL="$(ccr_to_short_model "$RAW_MODEL")"
[[ -n "$DEFAULT_MODEL" ]] || { echo "Empty model after normalization." >&2; exit 1; }

if ! command -v claude >/dev/null 2>&1; then
  echo "claude CLI not found in PATH." >&2
  exit 1
fi

if [[ "$SKIP_CHECK" != "1" ]]; then
  preflight_check "$CCR_BASE_URL" "$TOKEN" "$PROFILE_ID" || exit 1
fi

# Pull path-independent settings written by CCR Desktop for this profile.
import_ccr_wrapper_env "$PROFILE_ID"

export ANTHROPIC_BASE_URL="$CCR_BASE_URL"
export ANTHROPIC_AUTH_TOKEN="$TOKEN"
unset ANTHROPIC_API_KEY

export ANTHROPIC_MODEL="$DEFAULT_MODEL"
export ANTHROPIC_DEFAULT_SONNET_MODEL="$DEFAULT_MODEL"
export ANTHROPIC_DEFAULT_OPUS_MODEL="$DEFAULT_MODEL"
export ANTHROPIC_DEFAULT_HAIKU_MODEL="$DEFAULT_MODEL"

export CLAUDE_CODE_ENABLE_GATEWAY_MODEL_DISCOVERY=1

# CCR sets this to 1 unconditionally (its asar has a one-line function that
# does nothing else), and the wrapper import above honours that. It has to be
# turned off here, because of what "1" means.
#
# With it at 1, Claude Code reverts to "wait for the API to complain" for any
# model it has no catalogue entry for: it does not compact on its own, it waits
# for the server to reject the request. That is a defensible choice for a hosted
# API, which answers `prompt too long` and lets the client retry.
#
# It is the wrong choice for this engine, which answers by failing. Measured:
# the same local model with MAX_CONTEXT_TOKENS=262144 compacts at 242144 when
# this is 0, and skips the threshold check entirely when it is 1 -- no
# `autocompact:` line in --debug at all, so a session grows until the engine
# refuses it.
#
# Setting it to 0 costs nothing for cloud models: they are in the gateway
# catalogue, so they resolve before this variable is consulted. Verified -- a
# cloud model measures effectiveWindow=108000 with the flag at either value.
export CLAUDE_CODE_DISABLE_UNKNOWN_MODEL_WINDOW_ENFORCEMENT=0

# The window Claude Code should assume for this model. Set after the wrapper
# import above, so a value CCR wrote is still honoured if the model cannot be
# resolved; and it may lower a value from modelSettings, which is what makes it
# worth setting even when /autocompact once left a stale 800000 behind.
#
# CCR_CONTEXT_WINDOW="off" means "set nothing": the resolver stays silent and
# Claude Code uses its own chain (catalog, then modelSettings, then 200000).
# A number is used verbatim, including when the catalogs disagree with it.
CTX_WINDOW=''
[[ "${CCR_CONTEXT_WINDOW:-}" == "off" ]] || CTX_WINDOW="$(resolve_context_window "$RAW_MODEL" || true)"
if [[ -n "${CTX_WINDOW:-}" ]]; then
  export CLAUDE_CODE_MAX_CONTEXT_TOKENS="$CTX_WINDOW"
fi

# Whether Claude Code can talk to this model at all. Probed before launch so the
# answer appears above the session rather than as a 400 halfway through it.
#
# Off by default. A local engine cold-starts the probe in about 19 s here -- the
# prompt is one token but the first request pays KV setup -- and that is a long
# silence before anything appears, spent predicting a failure that a compat shim
# in front of the engine already prevents. The probe was written when the shim
# did not exist; now that it does, the common case is a model that works.
#
# CCR_CAPABILITY_CHECK=on probes anyway. The function is kept because the
# failure it detects is real for anyone running without the shim.
if [[ "${CCR_CAPABILITY_CHECK:-}" == "on" ]]; then
  DEFER_CAP="$(probe_defer_support "$DEFAULT_MODEL" "$TOKEN" "$CCR_BASE_URL" || true)"
fi

save_last_profile "$PROFILE_ID"

# Optional: refresh pet statusline FX rate (USD→CNY etc.) if stale
maybe_update_fx_rate() {
  [[ "${PET_FX_UPDATE:-1}" == "0" ]] && return 0
  local here updater
  here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  for updater in \
    "${PET_FX_UPDATE_SCRIPT:-}" \
    "$HOME/.claude/claude-pet/update-fx-rate.sh" \
    "$here/../claudePet/scripts/update-fx-rate.sh"
  do
    [[ -n "$updater" && -x "$updater" ]] || continue
    # fail-soft; keep launch fast
    if command -v timeout >/dev/null 2>&1; then
      timeout "${PET_FX_TIMEOUT:-3}" "$updater" 2>/dev/null || true
    else
      "$updater" 2>/dev/null || true
    fi
    return 0
  done
}
maybe_update_fx_rate

# Optional: refresh per-model $/MTok pricing table (same TTL pattern as FX)
maybe_update_model_pricing() {
  [[ "${PET_PRICING_UPDATE:-1}" == "0" ]] && return 0
  local here updater
  here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  for updater in \
    "${PET_PRICING_UPDATE_SCRIPT:-}" \
    "$HOME/.claude/claude-pet/update-model-pricing.sh" \
    "$here/../claudePet/scripts/update-model-pricing.sh"
  do
    [[ -n "$updater" && -x "$updater" ]] || continue
    if command -v timeout >/dev/null 2>&1; then
      timeout "${PET_PRICING_TIMEOUT:-5}" "$updater" 2>/dev/null || true
    else
      "$updater" 2>/dev/null || true
    fi
    return 0
  done
}
maybe_update_model_pricing

{
  echo "CCR profile: $PROFILE_ID"
  if [[ "$RAW_MODEL" == "$DEFAULT_MODEL" ]]; then
    echo "Claude model: $DEFAULT_MODEL  (from $MODEL_SOURCE)"
  else
    echo "Claude model: $DEFAULT_MODEL  ← $RAW_MODEL  (from $MODEL_SOURCE)"
  fi
  echo "CCR: $ANTHROPIC_BASE_URL"
  # Said plainly, because "unresolved" used to claim a 200000 that was no longer
  # true: when this script sets nothing, Claude Code still applies whatever
  # autoCompactWindow says in settings.json, and only falls back to 200000 after
  # that. A value here is one this script exported and nothing can raise.
  if [[ -n "${CTX_WINDOW:-}" ]]; then
    echo "Context window: $CTX_WINDOW tokens"
  elif [[ "${CCR_CONTEXT_WINDOW:-}" == "off" ]]; then
    echo "Context window: not set (--context-window off; Claude Code decides)"
  else
    echo "Context window: unresolved here; Claude Code falls back to"
    echo "                autoCompactWindow in settings.json, else 200000"
  fi
  case "${DEFER_CAP:-}" in
    no-defer)
      echo "Tools: UNUSABLE -- this model rejects defer_loading, which Claude Code"
      echo "       sends on every request. Use a cloud model for now; see"
      echo "       CONTEXT-WINDOW.md. Set CCR_CAPABILITY_CHECK=off to skip this check."
      ;;
    unknown)
      echo "Tools: could not verify (probe failed or was refused); not a verdict"
      ;;
  esac
} >&2

exec claude "${PASS_ARGS[@]}"
