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
  MODEL=<name> ccr-claude

Environment:
  CCR_DIR             CCR data dir (contains config.sqlite)
  CCR_BASE_URL        Gateway URL (else read from CCR config)
  CLAUDE_CONFIG_DIR   Global Claude settings dir (else derived / ~/.claude)
  CCR_PROFILE         Same as --profile
  CCR_NO_PICK=1       Never prompt; prefer last used, else most recently modified
  CCR_SKIP_CHECK=1    Skip gateway / token preflight
  MODEL               Temporary model override

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
    --skip-check) SKIP_CHECK=1; shift ;;
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

if [[ "$SKIP_CHECK" != "1" ]]; then
  preflight_check "$CCR_BASE_URL" "$TOKEN" "$PROFILE_ID" || exit 1
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

save_last_profile "$PROFILE_ID"

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
