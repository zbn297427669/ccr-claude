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
#   CCR_NO_PICK=1        多个 enabled 时不交互，用最近修改的
#   MODEL                临时覆盖模型（支持 CCR 长名，会转成短名）
#
set -euo pipefail

ccr_to_short_model() {
  local m="$1"
  m="${m##*/}"
  m="${m%%\[*}"
  printf '%s' "$m"
}

# 发现 CCR 数据目录（绝不写死用户名）
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

  # WSL：扫描 Windows 用户目录下的 Roaming 安装
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

# 从 CCR_DIR 推导 Windows/本机 Claude 配置目录
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
  # .../Users/<name>/AppData/Roaming/claude-code-router → .../Users/<name>/.claude
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

  # 允许不存在：global scope 时再报错
  printf '%s' "$HOME/.claude"
}

# 从 config.sqlite 读网关 URL；失败则默认本地
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

# 用法: ccr_query all|active|model <id>|token <id>
ccr_query() {
  python3 - "$CCR_DIR" "$CLAUDE_CONFIG_DIR" "$@" <<'PY'
import json, re, shutil, sqlite3, sys, tempfile
from pathlib import Path

ccr = Path(sys.argv[1])
claude_home = Path(sys.argv[2])
mode = sys.argv[3]
arg = sys.argv[4] if len(sys.argv) > 4 else ""

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

def load_profiles(con):
    row = con.execute("select value_json from app_config where key='default'").fetchone()
    if not row:
        return []
    cfg = json.loads(row[0])
    return [
        p for p in (cfg.get("profile", {}).get("profiles") or [])
        if p.get("agent") == "claude-code"
    ]

def token_for(con, pid: str) -> str:
    row = con.execute(
        "select encrypted_key, encryption from api_keys where id=?",
        (f"profile:{pid}",),
    ).fetchone()
    if row and row[0] and (row[1] or "plain") == "plain":
        return row[0].strip()
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

def enrich(con, p):
    pid = p.get("id") or ""
    scope = p.get("scope") or "global"
    model = (p.get("model") or p.get("sonnetModel") or "").strip()
    if not model:
        model = settings_model(pid, scope)
    return {
        "id": pid,
        "name": p.get("name") or pid,
        "model": model,
        "short": short(model),
        "enabled": bool(p.get("enabled", True)),
        "scope": scope,
        "mtime": mtime_for(pid, scope),
        "token": token_for(con, pid),
    }

con, td = open_db()
try:
    profiles = [enrich(con, p) for p in load_profiles(con)]

    if mode == "all":
        for p in sorted(profiles, key=lambda x: x["id"]):
            print(
                f"{p['id']}\t{p['name']}\t{p['scope']}\t{p['model']}\t{int(p['enabled'])}"
            )
    elif mode == "active":
        cands = [p for p in profiles if p["enabled"] and p["model"] and p["token"]]
        if not cands:
            sys.exit(1)
        cands.sort(key=lambda x: x["mtime"], reverse=True)
        for p in cands:
            print(f"{p['id']}\t{p['name']}\t{p['short']}")
    elif mode == "model":
        for p in profiles:
            if p["id"] == arg and p["model"]:
                print(p["model"])
                sys.exit(0)
        sys.exit(1)
    elif mode == "token":
        for p in profiles:
            if p["id"] == arg and p["token"]:
                print(p["token"])
                sys.exit(0)
        tok = token_for(con, arg)
        if tok:
            print(tok)
            sys.exit(0)
        sys.exit(1)
    else:
        sys.exit(2)
finally:
    con.close()
    shutil.rmtree(td, ignore_errors=True)
PY
}

list_ccr_profiles() { ccr_query all; }
list_active_profiles() { ccr_query active; }
read_profile_token() { ccr_query token "$1"; }
read_profile_model() { ccr_query model "$1"; }

resolve_profile_id() {
  local want="$1" id name scope model enabled
  while IFS=$'\t' read -r id name scope model enabled; do
    [[ -z "$id" ]] && continue
    if [[ "$want" == "$id" || "$want" == "$name" ]]; then
      printf '%s' "$id"
      return 0
    fi
    if [[ "$id" == *"$want"* || "$name" == *"$want"* ]]; then
      printf '%s' "$id"
      return 0
    fi
  done < <(list_ccr_profiles)
  return 1
}

pick_profile() {
  local force_pick="${1:-0}"
  local -a ids names models
  local id name model i choice

  while IFS=$'\t' read -r id name model; do
    [[ -z "$id" ]] && continue
    ids+=("$id")
    names+=("$name")
    models+=("$model")
  done < <(list_active_profiles)

  [[ ${#ids[@]} -gt 0 ]] || return 1
  if [[ ${#ids[@]} -eq 1 ]]; then
    printf '%s' "${ids[0]}"
    return 0
  fi

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
      printf "  %d) %s  [%s]  (%s)\n" "$((i + 1))" "${names[i]}" "${models[i]}" "${ids[i]}"
    done
    echo "  0) cancel"
  } >&2

  while true; do
    choice=""
    if [[ -t 0 ]]; then
      read -r -p "Number [1]: " choice || choice=""
    else
      read -r choice || choice=""
    fi
    choice="${choice:-1}"
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

usage() {
  cat <<'EOF'
Usage:
  ccr-claude                      # interactive pick when multiple agents enabled
  ccr-claude --pick               # force menu
  ccr-claude --profile <id|name>  # select by id / name substring
  ccr-claude --list-profiles
  ccr-claude --model <short-or-long-name>
  MODEL=<name> ccr-claude

Environment:
  CCR_DIR             CCR data dir (contains config.sqlite)
  CCR_BASE_URL        Gateway URL (else read from CCR config)
  CLAUDE_CONFIG_DIR   Global Claude settings dir (else derived / ~/.claude)
  CCR_PROFILE         Same as --profile
  CCR_NO_PICK=1       Never prompt; use most recently modified agent
  MODEL               Temporary model override

Secrets are never stored in this script. Profile tokens are read at runtime from
CCR's local api_keys table or bin/ccr-claude-code-api-key-*.cmd helpers.
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

PROFILE_WANT="${CCR_PROFILE:-}"
RAW_MODEL="${MODEL:-}"
MODEL_SOURCE=""
FORCE_PICK=0
PASS_ARGS=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --list-profiles)
      printf '%s\n' "ID	NAME	ENABLED	MODEL"
      while IFS=$'\t' read -r id name scope model enabled; do
        short="$(ccr_to_short_model "$model")"
        en="no"; [[ "$enabled" == "1" ]] && en="yes"
        printf '%s\t%s\t%s\t%s\n' "$id" "$name" "$en" "${short:-"(none)"}"
      done < <(list_ccr_profiles)
      echo "CCR_DIR=$CCR_DIR" >&2
      echo "CCR_BASE_URL=$CCR_BASE_URL" >&2
      exit 0
      ;;
    --pick) FORCE_PICK=1; shift ;;
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
  PROFILE_ID="$(resolve_profile_id "$PROFILE_WANT")" || {
    echo "CCR profile not found: $PROFILE_WANT" >&2
    list_ccr_profiles | awk -F'\t' '{print "  "$1"  "$2}' >&2
    exit 1
  }
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

PROFILE_MODEL="$(read_profile_model "$PROFILE_ID" || true)"

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
elif [[ -z "$MODEL_SOURCE" ]]; then
  MODEL_SOURCE="arg"
fi

DEFAULT_MODEL="$(ccr_to_short_model "$RAW_MODEL")"
[[ -n "$DEFAULT_MODEL" ]] || { echo "Empty model after normalization." >&2; exit 1; }

if ! command -v claude >/dev/null 2>&1; then
  echo "claude CLI not found in PATH." >&2
  exit 1
fi

export ANTHROPIC_BASE_URL="$CCR_BASE_URL"
export ANTHROPIC_AUTH_TOKEN="$TOKEN"
unset ANTHROPIC_API_KEY

export ANTHROPIC_MODEL="$DEFAULT_MODEL"
export ANTHROPIC_DEFAULT_SONNET_MODEL="$DEFAULT_MODEL"
export ANTHROPIC_DEFAULT_OPUS_MODEL="$DEFAULT_MODEL"
export ANTHROPIC_DEFAULT_HAIKU_MODEL="$DEFAULT_MODEL"

export CLAUDE_CODE_ENABLE_GATEWAY_MODEL_DISCOVERY=1
export CLAUDE_CODE_DISABLE_UNKNOWN_MODEL_WINDOW_ENFORCEMENT=1

{
  echo "CCR profile: $PROFILE_ID"
  if [[ "$RAW_MODEL" == "$DEFAULT_MODEL" ]]; then
    echo "Claude model: $DEFAULT_MODEL  (from $MODEL_SOURCE)"
  else
    echo "Claude model: $DEFAULT_MODEL  ← $RAW_MODEL  (from $MODEL_SOURCE)"
  fi
  echo "CCR: $ANTHROPIC_BASE_URL"
} >&2

exec claude "${PASS_ARGS[@]}"
