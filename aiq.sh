#!/usr/bin/env bash
# aiq — switch between multiple Claude Code / Codex CLI accounts, and read their quota.
# Single file. Linux, macOS, Windows (Git Bash).
#
# Why this exists: copying auth files around breaks OAuth refresh-token rotation
# and gets your device de-authorised. See README, "The re-login trap".
set -uo pipefail

AIQ_VERSION="1.0.0"
US=$''   # field separator between the python engine and this script

# ------------------------------------------------------------------ paths ---
# Capture what the shell actually set, before the defaults below overwrite it —
# that is how we know whether this shell is already inside a workspace.
AIQ_IN_CLAUDE="${CLAUDE_CONFIG_DIR:-}"
AIQ_IN_CODEX="${CODEX_HOME:-}"

CLAUDE_HOME="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
CLAUDE_CRED="$CLAUDE_HOME/.credentials.json"
# Claude Code keeps account metadata beside its config dir when one is set.
if [ -n "${CLAUDE_CONFIG_DIR:-}" ] && [ -f "$CLAUDE_CONFIG_DIR/.claude.json" ]; then
  CLAUDE_SESSION="$CLAUDE_CONFIG_DIR/.claude.json"
else
  CLAUDE_SESSION="${AIQ_CLAUDE_SESSION:-$HOME/.claude.json}"
fi
CLAUDE_PROFILES="$CLAUDE_HOME/profiles"

CODEX_HOME="${CODEX_HOME:-$HOME/.codex}"
CODEX_AUTH="$CODEX_HOME/auth.json"
CODEX_PROFILES="$CODEX_HOME/profiles"

AIQ_DIR="${AIQ_DIR:-$HOME/.aiq}"
AIQ_BACKUPS="$AIQ_DIR/backups"
AIQ_ENVS="$AIQ_DIR/envs"
AIQ_KEEP_BACKUPS="${AIQ_KEEP_BACKUPS:-40}"

# ---------------------------------------------------------------- colours ---
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  C_RST=$'\033[0m'; C_DIM=$'\033[2m'; C_B=$'\033[1m'
  C_RED=$'\033[31m'; C_GRN=$'\033[32m'; C_YEL=$'\033[33m'; C_CYA=$'\033[36m'
else
  C_RST=""; C_DIM=""; C_B=""; C_RED=""; C_GRN=""; C_YEL=""; C_CYA=""
fi

die()  { printf '%saiq: %s%s\n' "$C_RED" "$*" "$C_RST" >&2; exit 1; }
warn() { printf '%s!  %s%s\n'   "$C_YEL" "$*" "$C_RST" >&2; }
info() { printf '%s%s%s\n'      "$C_DIM" "$*" "$C_RST"; }

# ----------------------------------------------------------------- python ---
AIQ_PY_BIN=""
_find_py() {
  [ -n "$AIQ_PY_BIN" ] && return 0
  for c in python3 python py; do
    if command -v "$c" >/dev/null 2>&1 && "$c" -c 'import json,base64,hashlib' >/dev/null 2>&1; then
      AIQ_PY_BIN="$c"; return 0
    fi
  done
  return 1
}

# Unix path -> native path, so a Windows python understands it under Git Bash.
_np() {
  if command -v cygpath >/dev/null 2>&1; then cygpath -w "$1" 2>/dev/null || printf '%s' "$1"
  else printf '%s' "$1"; fi
}

read -r -d '' AIQ_PY <<'PYCODE'
import sys, json, base64, os, time, hashlib
from datetime import datetime, timezone

# Windows Python emits CRLF; the shell reading these rows splits on LF and
# would keep a stray CR on the last field of every line.
try:
    sys.stdout.reconfigure(newline=chr(10), encoding="utf-8", errors="replace")
except Exception:
    pass

# Keys of ~/.claude.json that belong to the ACCOUNT. Everything else in that file
# (projects, mcpServers, history, tips) belongs to the machine and is never touched.
ACCOUNT_KEYS = ["oauthAccount", "cachedUsageUtilization", "hasAvailableSubscription",
                "cachedExtraUsageDisabledReason", "subscriptionNoticeCount",
                "claudeCodeFirstTokenDate", "additionalModelCostsCache"]


def jload(p):
    try:
        with open(p, "r", encoding="utf-8") as f:
            return json.load(f)
    except Exception:
        return None


def ms_local(ms):
    try:
        return datetime.fromtimestamp(int(ms) / 1000).strftime("%Y-%m-%d %H:%M")
    except Exception:
        return ""


def ms_days(ms):
    try:
        return "%.1f" % ((int(ms) / 1000 - time.time()) / 86400.0)
    except Exception:
        return ""


def iso_dt(s):
    try:
        d = datetime.fromisoformat(str(s).replace("Z", "+00:00"))
        return d if d.tzinfo else d.replace(tzinfo=timezone.utc)
    except Exception:
        return None


def iso_local(s):
    d = iso_dt(s)
    return d.astimezone().strftime("%Y-%m-%d %H:%M") if d else ""


def iso_days(s):
    d = iso_dt(s)
    return "%.1f" % ((d.timestamp() - time.time()) / 86400.0) if d else ""


def jwt_payload(tok):
    try:
        p = str(tok).split(".")[1]
        p += "=" * (-len(p) % 4)
        return json.loads(base64.urlsafe_b64decode(p))
    except Exception:
        return {}


def sha(path):
    try:
        h = hashlib.sha256()
        with open(path, "rb") as f:
            for chunk in iter(lambda: f.read(65536), b""):
                h.update(chunk)
        return h.hexdigest()
    except Exception:
        return ""


def row(*cells):
    # \x1f, not a tab: bash `read` collapses runs of whitespace delimiters,
    # which silently shifts every column that follows an empty one.
    print("\x1f".join("" if c is None else str(c) for c in cells))


# ---------------------------------------------------------------- claude ---
def claude_read(cred, session):
    d = {}
    o = (jload(cred) or {}).get("claudeAiOauth") or {}
    d["token_at"] = ms_local(o.get("expiresAt"))
    d["token_days"] = ms_days(o.get("expiresAt"))
    d["token_ms"] = str(o.get("expiresAt") or "")
    d["refresh_at"] = ms_local(o.get("refreshTokenExpiresAt"))
    d["refresh_days"] = ms_days(o.get("refreshTokenExpiresAt"))
    d["plan"] = o.get("subscriptionType") or ""
    d["has_cred"] = "1" if o else "0"

    s = jload(session) or {}
    oa = s.get("oauthAccount") or {}
    d["email"] = oa.get("emailAddress") or ""
    d["id"] = oa.get("accountUuid") or ""
    d["org"] = oa.get("organizationType") or ""

    cu = s.get("cachedUsageUtilization") or {}
    u = cu.get("utilization") or {}
    # Claude Code only refreshes this cache when its /usage screen is opened, so
    # it goes stale quickly. Reporting a stale 0% is worse than reporting nothing:
    # past the cutoff we show blank and let `aiq quota` fetch the live figure.
    fresh = True
    try:
        fresh = (time.time() - int(cu.get("fetchedAtMs")) / 1000) < float(
            os.environ.get("AIQ_CACHE_MAX_AGE", "21600"))
    except Exception:
        fresh = False
    for key, tag in (("five_hour", "q5h"), ("seven_day", "q7d")):
        b = u.get(key) or {}
        v = b.get("utilization")
        d[tag] = "" if (v is None or not fresh) else str(v)
        d[tag + "_reset"] = iso_local(b.get("resets_at"))
    d["q_at"] = ms_local(cu.get("fetchedAtMs"))
    d["sub_at"] = ""
    d["sub_days"] = ""
    return d


def claude_slice(session):
    s = jload(session) or {}
    return {k: s[k] for k in ACCOUNT_KEYS if k in s}


# ----------------------------------------------------------------- codex ---
def codex_read(auth):
    d = {}
    a = jload(auth) or {}
    t = a.get("tokens") or {}
    p = jwt_payload(t.get("id_token", ""))
    oai = p.get("https://api.openai.com/auth") or {}
    d["email"] = p.get("email") or ""
    d["id"] = oai.get("chatgpt_account_id") or oai.get("chatgpt_user_id") or ""
    d["plan"] = oai.get("chatgpt_plan_type") or ""
    d["sub_at"] = iso_local(oai.get("chatgpt_subscription_active_until"))
    d["sub_days"] = iso_days(oai.get("chatgpt_subscription_active_until"))
    d["auth_mode"] = a.get("auth_mode") or ""
    d["refresh_at"] = iso_local(a.get("last_refresh"))
    exp = p.get("exp")
    d["token_at"] = ms_local(int(exp) * 1000) if exp else ""
    d["token_days"] = ms_days(int(exp) * 1000) if exp else ""
    d["token_ms"] = str(int(exp) * 1000) if exp else ""
    d["refresh_days"] = ""
    d["has_cred"] = "1" if (t.get("id_token") or a.get("OPENAI_API_KEY")) else "0"
    d["org"] = ""
    for k in ("q5h", "q7d", "q5h_reset", "q7d_reset", "q_at"):
        d[k] = ""
    return d


# ------------------------------------------------------------- profile io ---
def prof_files(provider, pdir):
    """Credential + session file inside a profile dir, tolerating older layouts."""
    if provider == "claude":
        cred = ""
        for n in (".credentials.json", "credentials.json"):
            q = os.path.join(pdir, n)
            if os.path.isfile(q):
                cred = q
                break
        sess = ""
        for n in ("claude.json", "session.json"):
            q = os.path.join(pdir, n)
            if os.path.isfile(q):
                sess = q
                break
        return cred, sess
    return os.path.join(pdir, "auth.json"), ""


def prof_read(provider, pdir):
    cred, sess = prof_files(provider, pdir)
    d = claude_read(cred, sess) if provider == "claude" else codex_read(cred)
    meta = jload(os.path.join(pdir, "profile.json")) or {}
    if not d.get("id"):
        d["id"] = meta.get("id") or ""
    if not d.get("email"):
        d["email"] = meta.get("email") or ""
    if not d.get("email"):
        try:
            with open(os.path.join(pdir, "profile.email")) as f:
                d["email"] = f.read().strip()
        except Exception:
            pass
    try:
        with open(os.path.join(pdir, "profile.alias")) as f:
            d["alias"] = f.read().strip()
    except Exception:
        d["alias"] = ""
    d["saved_at"] = meta.get("saved_at") or ""
    d["cred_path"] = cred
    return d


def profiles_of(root, archived=False):
    """Live profiles, or the archived ones under <root>/.archive."""
    if archived:
        root = os.path.join(root, ".archive")
    try:
        return sorted(d for d in os.listdir(root)
                      if os.path.isdir(os.path.join(root, d)) and not d.startswith("."))
    except Exception:
        return []


def health(provider, d):
    """ok | expiring | dead | unknown — is this profile still usable?

    Claude dies when the REFRESH token lapses (~27 days), not when the short
    access token does; the CLI mints a new access token on every run.
    Codex dies when the ChatGPT subscription window closes."""
    v = d.get("refresh_days") if provider == "claude" else d.get("sub_days")
    if v in (None, ""):
        return "unknown"
    try:
        f = float(v)
    except Exception:
        return "unknown"
    if f < 0:
        return "dead"
    return "expiring" if f < (7 if provider == "claude" else 3) else "ok"


def active_of(argv):
    provider, cred = argv[0], argv[1]
    sess = argv[2] if len(argv) > 2 else ""
    return provider, cred, (claude_read(cred, sess) if provider == "claude" else codex_read(cred))


# --------------------------------------------------------------- commands ---
def cmd_active(argv):
    _, _, d = active_of(argv)
    for k in sorted(d):
        print(k + "\t" + str(d[k]))


def cmd_list(argv):
    """provider root active_cred [active_session] [--archived] -> one row per profile"""
    provider, root = argv[0], argv[1]
    rest = argv[2:]
    arch = "--archived" in rest
    rest = [a for a in rest if a != "--archived"]
    _, acred, act = active_of([provider] + rest)
    aid, ahash = act.get("id", ""), sha(acred)
    base = os.path.join(root, ".archive") if arch else root

    for name in profiles_of(root, archived=arch):
        d = prof_read(provider, os.path.join(base, name))
        mark, stale = " ", ""
        if aid and d.get("id") and aid == d["id"]:
            mark = "*"
            if sha(d["cred_path"]) != ahash:
                mark, stale = "~", "1"
        elif not aid and ahash and d.get("cred_path") and sha(d["cred_path"]) == ahash:
            mark = "*"
        row(mark, name, d.get("alias") or "-", d.get("email") or "-", d.get("plan") or "-",
            d.get("token_days"), d.get("refresh_days"), d.get("q5h"), d.get("q7d"),
            stale, "1" if d.get("id") else "", d.get("sub_days"), d.get("saved_at"),
            health(provider, d))


def cmd_match(argv):
    """provider root active_cred [active_session] -> profile name holding the live account"""
    provider, root = argv[0], argv[1]
    _, acred, act = active_of([provider] + argv[2:])
    aid, ahash = act.get("id", ""), sha(acred)
    fallback = ""
    for name in profiles_of(root):
        d = prof_read(provider, os.path.join(root, name))
        if aid and d.get("id") and aid == d["id"]:
            print(name)
            return
        if ahash and d.get("cred_path") and sha(d["cred_path"]) == ahash:
            fallback = name
    print(fallback)


def cmd_resolve(argv):
    """root key -> directory name matching a profile name or an alias"""
    root, key = argv[0], argv[1]
    for name in profiles_of(root):
        if name == key:
            print(name)
            return
        try:
            with open(os.path.join(root, name, "profile.alias")) as f:
                if f.read().strip() == key:
                    print(name)
                    return
        except Exception:
            pass
    print("")


def cmd_cmp(argv):
    """provider profile_dir active_cred [active_session]
    -> same_account<TAB>0|1  and  live_is_newer<TAB>0|1
    Guards against restoring a stale refresh token over a fresher one."""
    provider, pdir = argv[0], argv[1]
    _, _, act = active_of([provider] + argv[2:])
    d = prof_read(provider, pdir)
    same = "1" if (act.get("id") and d.get("id") and act["id"] == d["id"]) else "0"
    newer = "0"
    try:
        if int(act.get("token_ms") or 0) > int(d.get("token_ms") or 0):
            newer = "1"
    except Exception:
        pass
    print("same\t" + same)
    print("newer\t" + newer)


def cmd_meta(argv):
    """provider cred [session] out -> write profile.json"""
    provider, cred, out = argv[0], argv[1], argv[-1]
    sess = argv[2] if len(argv) > 3 else ""
    d = claude_read(cred, sess) if provider == "claude" else codex_read(cred)
    meta = {"provider": provider, "id": d.get("id", ""), "email": d.get("email", ""),
            "plan": d.get("plan", ""),
            "saved_at": datetime.now().astimezone().strftime("%Y-%m-%d %H:%M:%S%z")}
    with open(out, "w", encoding="utf-8") as f:
        json.dump(meta, f, indent=2)
    print(d.get("email", ""))


def cmd_slice(argv):
    """session out -> account-only slice of ~/.claude.json"""
    with open(argv[1], "w", encoding="utf-8") as f:
        json.dump(claude_slice(argv[0]), f, indent=2)


def cmd_merge(argv):
    """slice live -> put the account keys of <slice> into <live>, keep the rest"""
    sl = jload(argv[0]) or {}
    live = jload(argv[1])
    if live is None:
        live = {}
    for k in ACCOUNT_KEYS:
        live.pop(k, None)
    live.update(sl)
    with open(argv[1], "w", encoding="utf-8") as f:
        json.dump(live, f, indent=2)


def cmd_usage(argv):
    """cred [cache_out] -> live quota for THIS account from Anthropic's OAuth
    usage endpoint: the same call the Claude Code /usage screen makes.
    Read-only. It never refreshes, so it cannot rotate a refresh token."""
    import urllib.request, urllib.error
    cred = argv[0]
    cache = argv[1] if len(argv) > 1 else ""
    tok = ((jload(cred) or {}).get("claudeAiOauth") or {}).get("accessToken") or ""
    if not tok:
        print("error	no access token in " + os.path.basename(cred))
        return
    req = urllib.request.Request(
        "https://api.anthropic.com/api/oauth/usage",
        headers={"Authorization": "Bearer " + tok,
                 "anthropic-beta": "oauth-2025-04-20",
                 "User-Agent": "aiq"})
    try:
        with urllib.request.urlopen(req, timeout=float(os.environ.get("AIQ_TIMEOUT", "8"))) as r:
            body = json.loads(r.read().decode("utf-8"))
    except urllib.error.HTTPError as e:
        code = e.code
        print("error	" + ("access token expired - switch to it and run the CLI once"
                           if code in (401, 403) else "HTTP %d" % code))
        return
    except Exception as e:
        print("error	" + type(e).__name__)
        return
    if cache:
        try:
            body["_fetched_at"] = time.time()
            with open(cache, "w", encoding="utf-8") as f:
                json.dump(body, f, indent=2)
        except Exception:
            pass
    for key, tag in (("five_hour", "q5h"), ("seven_day", "q7d"),
                     ("seven_day_opus", "qopus"), ("seven_day_sonnet", "qsonnet")):
        w = body.get(key)
        if isinstance(w, dict) and w.get("utilization") is not None:
            print(tag + "	" + str(w["utilization"]))
            print(tag + "_reset	" + iso_local(w.get("resets_at")))
    for lim in body.get("limits") or []:
        if lim.get("severity") not in (None, "normal"):
            print("warn	%s at %s%% (%s)" % (lim.get("kind"), lim.get("percent"),
                                              lim.get("severity")))
    print("ok	1")


def cmd_dead(argv):
    """provider root -> names of profiles that can no longer be used"""
    provider, root = argv[0], argv[1]
    for name in profiles_of(root):
        d = prof_read(provider, os.path.join(root, name))
        if health(provider, d) == "dead":
            print(name + "	" + (d.get("email") or "-"))


CMDS = {"dead": cmd_dead, "active": cmd_active, "list": cmd_list, "match": cmd_match, "resolve": cmd_resolve,
        "meta": cmd_meta, "slice": cmd_slice, "merge": cmd_merge, "cmp": cmd_cmp, "usage": cmd_usage}

if __name__ == "__main__":
    if len(sys.argv) < 2 or sys.argv[1] not in CMDS:
        sys.exit(2)
    CMDS[sys.argv[1]](sys.argv[2:])
PYCODE

_py() {
  _find_py || die "python3 (or python) is required — run: aiq doctor"
  "$AIQ_PY_BIN" -c "$AIQ_PY" "$@"
}

# -------------------------------------------------------------- provider ---
PROV=""; P_ACTIVE=""; P_SESSION=""; P_ROOT=""; P_CREDNAME=""; P_LABEL=""; PROV_CLI=""
P_ENVROOT=""; P_ENVVAR=""; P_CLI=""
declare -a P_ARGS=()

_set_provider() {
  case "${1:-}" in
    claude|cl|anthropic)
      PROV=claude; P_ACTIVE="$CLAUDE_CRED"; P_SESSION="$CLAUDE_SESSION"
      P_ROOT="$CLAUDE_PROFILES"; P_CREDNAME=".credentials.json"; P_LABEL="Claude Code"
      P_ENVVAR="CLAUDE_CONFIG_DIR"; P_CLI="claude" ;;
    gpt|codex|cx|chatgpt|openai)
      PROV=gpt; P_ACTIVE="$CODEX_AUTH"; P_SESSION=""
      P_ROOT="$CODEX_PROFILES"; P_CREDNAME="auth.json"; P_LABEL="Codex CLI"
      P_ENVVAR="CODEX_HOME"; P_CLI="codex" ;;
    *) return 1 ;;
  esac
  P_ENVROOT="$AIQ_ENVS/$PROV"
  mkdir -p "$P_ROOT" "$AIQ_DIR" 2>/dev/null
  if [ "$PROV" = claude ]; then P_ARGS=("$(_np "$P_ACTIVE")" "$(_np "$P_SESSION")")
  else P_ARGS=("$(_np "$P_ACTIVE")"); fi
  return 0
}

_cred_in() {
  # _cred_in <profile-dir> -> path of the credential file that actually exists
  if [ -f "$1/$P_CREDNAME" ]; then printf '%s' "$1/$P_CREDNAME"
  elif [ -f "$1/credentials.json" ]; then printf '%s' "$1/credentials.json"
  else printf '%s' "$1/$P_CREDNAME"; fi
}

_backup() {
  # _backup <file> <tag> — every overwrite is recoverable
  [ -f "$1" ] || return 0
  local dir="$AIQ_BACKUPS/$PROV"
  mkdir -p "$dir"
  cp -p "$1" "$dir/$(date +%Y%m%d-%H%M%S)-$2-$(basename "$1")" 2>/dev/null
  ls -1t "$dir" 2>/dev/null | tail -n "+$((AIQ_KEEP_BACKUPS + 1))" | while read -r old; do
    rm -f "$dir/$old"
  done
}

_running() {
  local pat; [ "$PROV" = claude ] && pat="claude" || pat="codex"
  if command -v pgrep >/dev/null 2>&1; then
    pgrep -x "$pat" >/dev/null 2>&1 && return 0
  fi
  if command -v tasklist >/dev/null 2>&1; then
    tasklist //FI "IMAGENAME eq $pat.exe" 2>/dev/null | grep -qi "$pat\.exe" && return 0
  fi
  return 1
}

_store() {
  # _store <profile-dir> — live account -> profile
  local d="$1"
  mkdir -p "$d" || return 1
  cp -f "$P_ACTIVE" "$d/$P_CREDNAME" || return 1
  [ -f "$d/credentials.json" ] && [ "$P_CREDNAME" != "credentials.json" ] && rm -f "$d/credentials.json"
  if [ "$PROV" = claude ] && [ -f "$P_SESSION" ]; then
    _py slice "$(_np "$P_SESSION")" "$(_np "$d/claude.json")" || return 1
    _py meta claude "$(_np "$d/$P_CREDNAME")" "$(_np "$d/claude.json")" "$(_np "$d/profile.json")" >/dev/null || return 1
  else
    _py meta gpt "$(_np "$d/$P_CREDNAME")" "$(_np "$d/profile.json")" >/dev/null || return 1
    # keep profile.email so the older shell scripts still read correctly
    _py active gpt "$(_np "$d/$P_CREDNAME")" 2>/dev/null \
      | awk -F'\t' '$1=="email" && $2!="" {print $2}' > "$d/profile.email"
    [ -s "$d/profile.email" ] || rm -f "$d/profile.email"
  fi
  return 0
}

_load() {
  # _load <profile-dir> — profile -> live account
  local d="$1" cred
  cred="$(_cred_in "$d")"
  [ -f "$cred" ] || { warn "profile '$(basename "$d")' has no credential file"; return 1; }
  mkdir -p "$(dirname "$P_ACTIVE")"
  cp -f "$cred" "$P_ACTIVE" || return 1
  if [ "$PROV" = claude ] && [ -f "$d/claude.json" ]; then
    _py merge "$(_np "$d/claude.json")" "$(_np "$P_SESSION")" || return 1
  fi
  return 0
}

_match() { _py match "$PROV" "$(_np "$P_ROOT")" "${P_ARGS[@]}" 2>/dev/null | head -n1; }

# --------------------------------------------------------------- autosync ---
# The core of this tool. A running CLI silently rotates its refresh token and
# rewrites the live auth file. If we overwrite that file without copying it back
# first, the newest refresh token is lost forever and the next restore replays a
# spent one — which providers treat as token theft and answer by de-authorising
# the device. So: write back before every overwrite, always.
_sync() {
  [ -f "$P_ACTIVE" ] || return 0
  local match cred
  match="$(_match)"
  [ -z "$match" ] && return 0
  cred="$(_cred_in "$P_ROOT/$match")"
  if [ -f "$cred" ] && cmp -s "$P_ACTIVE" "$cred" && [ "$PROV" != claude ]; then
    return 0
  fi
  _backup "$cred" "presync"
  _store "$P_ROOT/$match" || return 1
  if [ "${1:-}" != quiet ] && ! cmp -s "$P_ACTIVE" "$cred" 2>/dev/null; then
    info "wrote the live token back into '$match' first"
  fi
  return 0
}

# ----------------------------------------------------------------- render ---
_days_cell() {
  local d="$1" w="$2"
  if [ -z "$d" ]; then printf '%8s' "-"; return; fi
  case "$d" in -*) printf '%s%8s%s' "$C_RED" "expired" "$C_RST"; return ;; esac
  if awk -v d="$d" -v w="$w" 'BEGIN{exit !(d+0 < w+0)}'; then
    printf '%s%8s%s' "$C_YEL" "${d}d" "$C_RST"
  else
    printf '%8s' "${d}d"
  fi
}

_pct_cell() {
  local p="$1"
  if [ -z "$p" ]; then printf '%5s' "-"; return; fi
  if awk -v p="$p" 'BEGIN{exit !(p+0 >= 80)}'; then
    printf '%s%5s%s' "$C_RED" "${p}%" "$C_RST"
  else
    printf '%5s' "${p}%"
  fi
}

_health_cell() {
  case "$1" in
    ok)       printf '%s%-8s%s' "$C_GRN" "ok"       "$C_RST" ;;
    expiring) printf '%s%-8s%s' "$C_YEL" "expiring" "$C_RST" ;;
    dead)     printf '%s%-8s%s' "$C_RED" "dead"     "$C_RST" ;;
    *)        printf '%-8s' "?" ;;
  esac
}

_list_one() {
  # _list_one [--archived]
  local arch="${1:-}" shown=0
  local mark name alias email plan td rd q5 q7 stale hasid subd savedat st mcol
  if [ "$PROV" = claude ]; then
    printf '%s%-2s %-12s %-12s %-30s %-5s %-8s %9s %5s %5s%s\n' "$C_DIM" \
      "@" "PROFILE" "ALIAS" "ACCOUNT" "PLAN" "STATUS" "REFRESH" "5H" "7D" "$C_RST"
  else
    printf '%s%-2s %-12s %-12s %-38s %-5s %-8s %10s%s\n' "$C_DIM" \
      "@" "PROFILE" "ALIAS" "ACCOUNT" "PLAN" "STATUS" "SUB ENDS" "$C_RST"
  fi
  while IFS=$US read -r mark name alias email plan td rd q5 q7 stale hasid subd savedat st; do
    [ -z "$name" ] && continue
    shown=1
    case "$mark" in
      '*') mcol="${C_GRN}* ${C_RST}" ;;
      '~') mcol="${C_YEL}~ ${C_RST}" ;;
      *)   mcol="  " ;;
    esac
    printf '%s' "$mcol"
    if [ "$PROV" = claude ]; then
      printf '%-12.12s %-12.12s %-30.30s %-5.5s ' "$name" "$alias" "$email" "$plan"
      _health_cell "$st"; printf ' '
      # The refresh token is the real lifetime. The access token above it is
      # short-lived by design and the CLI renews it on every run.
      _days_cell "$rd" 7; printf ' '
      _pct_cell "$q5"; printf ' '; _pct_cell "$q7"
    else
      printf '%-12.12s %-12.12s %-38.38s %-5.5s ' "$name" "$alias" "$email" "$plan"
      _health_cell "$st"; printf ' '; _days_cell "$subd" 3
    fi
    [ -z "$hasid" ] && printf '  %sno identity — run: aiq %s save %s%s' "$C_DIM" "$PROV_CLI" "$name" "$C_RST"
    printf '\n'
  done < <(_py list "$PROV" "$(_np "$P_ROOT")" "${P_ARGS[@]}" $arch 2>/dev/null)
  if [ "$shown" = 0 ]; then
    if [ -n "$arch" ]; then info "  nothing archived"
    else info "  no profiles yet — sign in, then: aiq $PROV_CLI save <name> [alias]"; fi
  fi
  return 0
}

_field() { printf '%s' "$1" | awk -F'\t' -v k="$2" '$1==k{print $2}'; }

# ---------------------------------------------------------------- actions ---
act_ls() {
  _sync quiet
  printf '%s%s%s\n' "$C_B" "$P_LABEL" "$C_RST"
  case "${1:-}" in
    --archived) _list_one --archived; return 0 ;;
    --all)      _list_one
                printf '%s  archived%s\n' "$C_DIM" "$C_RST"
                _list_one --archived; return 0 ;;
  esac
  _list_one
  [ "$PROV" = claude ] && info "  5H/7D here is Claude Code's own cache; for live numbers: aiq claude quota"
  local nd; nd="$(_py dead "$PROV" "$(_np "$P_ROOT")" 2>/dev/null | wc -l | tr -d ' ')"
  [ "${nd:-0}" -gt 0 ] && info "  $nd unusable profile(s) — review with: aiq $PROV_CLI prune"
  return 0
}

# Archiving keeps every file. It only takes the profile out of `ls`, so a dead
# account can never be picked by mistake. Nothing is deleted.
act_archive() {
  local key="${1:-}" name
  [ -z "$key" ] && die "usage: aiq $PROV_CLI archive <name|alias>"
  name="$(_py resolve "$(_np "$P_ROOT")" "$key" 2>/dev/null | head -n1)"
  [ -z "$name" ] && die "no profile or alias called '$key'"
  if [ "$name" = "$(_match)" ]; then
    die "'$name' is the account you are signed in as — switch away before archiving it"
  fi
  mkdir -p "$P_ROOT/.archive"
  [ -e "$P_ROOT/.archive/$name" ] && die "an archived profile called '$name' already exists"
  mv "$P_ROOT/$name" "$P_ROOT/.archive/$name" || die "could not archive '$name'"
  printf 'archived %s%s%s  ->  %s\n' "$C_B" "$name" "$C_RST" "$P_ROOT/.archive/$name"
}

act_restore() {
  local key="${1:-}"
  [ -z "$key" ] && die "usage: aiq $PROV_CLI restore <name>"
  [ -d "$P_ROOT/.archive/$key" ] || die "nothing archived under '$key' — see: aiq $PROV_CLI ls --archived"
  [ -e "$P_ROOT/$key" ] && die "a live profile called '$key' already exists"
  mv "$P_ROOT/.archive/$key" "$P_ROOT/$key" || die "could not restore '$key'"
  printf 'restored %s%s%s\n' "$C_B" "$key" "$C_RST"
}

# prune only ever ARCHIVES. Deleting stays a separate, explicit `rm`.
act_prune() {
  local yes="" name email count=0
  case "${1:-}" in -y|--yes) yes=1 ;; esac
  while IFS=$'\t' read -r name email; do
    [ -z "$name" ] && continue
    count=$((count + 1))
    if [ -n "$yes" ]; then
      if [ "$name" = "$(_match)" ]; then
        warn "skipped '$name' — it is the account you are signed in as"
        continue
      fi
      mkdir -p "$P_ROOT/.archive"
      if [ -e "$P_ROOT/.archive/$name" ]; then
        warn "skipped '$name' — already archived under that name"
      else
        mv "$P_ROOT/$name" "$P_ROOT/.archive/$name" && printf '  archived %-12s %s\n' "$name" "$email"
      fi
    else
      printf '  %-12s %s\n' "$name" "$email"
    fi
  done < <(_py dead "$PROV" "$(_np "$P_ROOT")" 2>/dev/null)

  if [ "$count" = 0 ]; then
    info "nothing to prune — every $P_LABEL profile is still usable"
  elif [ -z "$yes" ]; then
    printf '\n'
    info "$count profile(s) above can no longer authenticate."
    info "Archive them with:  aiq $PROV_CLI prune --yes    (moved, not deleted)"
  fi
}

act_save() {
  local name="${1:-}" alias="${2:-}" d email
  [ -f "$P_ACTIVE" ] || die "not signed in — $P_ACTIVE does not exist"
  if [ -z "$name" ]; then
    name="$(_match)"
    [ -z "$name" ] && die "usage: aiq $PROV_CLI save <name> [alias]"
    info "updating the profile that already holds this account: $name"
  fi
  d="$P_ROOT/$name"
  [ -d "$d" ] && _backup "$(_cred_in "$d")" "presave"
  _store "$d" || die "could not save profile '$name'"
  [ -n "$alias" ] && printf '%s\n' "$alias" > "$d/profile.alias"
  email="$(_field "$(_py active "$PROV" "${P_ARGS[@]}" 2>/dev/null)" email)"
  printf '%ssaved%s %s%s%s%s\n' "$C_GRN" "$C_RST" "$C_B" "$name" "$C_RST" "${email:+  $email}"
}

act_use() {
  local key="${1:-}" name d out email plan td rd same newer
  [ -z "$key" ] && die "usage: aiq $PROV_CLI use <name|alias>"
  name="$(_py resolve "$(_np "$P_ROOT")" "$key" 2>/dev/null | head -n1)"
  [ -z "$name" ] && die "no profile or alias called '$key' — see: aiq $PROV_CLI ls"
  d="$P_ROOT/$name"

  if _running; then
    warn "a $P_LABEL process is running. It keeps its token in memory and will"
    warn "rewrite the auth file when it exits, undoing this switch."
    warn "Close it first, or re-run with AIQ_FORCE=1."
    [ "${AIQ_FORCE:-}" = 1 ] || exit 1
  fi

  # Same account already signed in? Restoring an older copy over it would replay a
  # spent refresh token, so refuse and refresh the stored copy instead.
  out="$(_py cmp "$PROV" "$(_np "$d")" "${P_ARGS[@]}" 2>/dev/null)"
  same="$(_field "$out" same)"; newer="$(_field "$out" newer)"
  if [ "$same" = 1 ] && [ "$newer" = 1 ]; then
    _sync quiet
    printf '%salready signed in as%s %s%s%s — kept the live token (it is newer than the saved one)\n' \
      "$C_CYA" "$C_RST" "$C_B" "$name" "$C_RST"
    return 0
  fi

  _sync
  _backup "$P_ACTIVE" "preuse"
  [ "$PROV" = claude ] && _backup "$P_SESSION" "preuse"
  _load "$d" || die "could not switch to '$name'"

  out="$(_py active "$PROV" "${P_ARGS[@]}" 2>/dev/null)"
  email="$(_field "$out" email)"; plan="$(_field "$out" plan)"
  td="$(_field "$out" token_days)"; rd="$(_field "$out" refresh_days)"
  printf '%susing%s %s%s%s%s%s\n' "$C_CYA" "$C_RST" "$C_B" "$name" "$C_RST" \
    "${email:+  $email}" "${plan:+  ($plan)}"

  case "$td" in
    ""|-*)
      if [ "$PROV" = claude ]; then
        case "$rd" in
          ""|-*) warn "access AND refresh token are expired — run 'claude' and /login again" ;;
          *)     info "access token expired; the CLI refreshes it on next run (refresh good for ${rd}d)" ;;
        esac
      else
        info "id token expired; the CLI refreshes it on next run"
      fi ;;
  esac
}

act_active() {
  _sync quiet
  printf '%s%s%s\n' "$C_B" "$P_LABEL" "$C_RST"
  if [ ! -f "$P_ACTIVE" ]; then warn "not signed in ($P_ACTIVE missing)"; return 1; fi
  local name; name="$(_match)"
  printf '  %-13s %s\n' "profile" "${name:-<unsaved — run: aiq $PROV_CLI save <name>>}"
  _py active "$PROV" "${P_ARGS[@]}" 2>/dev/null \
    | awk -F'\t' '$2!="" && $1!~/^(has_cred|token_ms)$/ {printf "  %-13s %s\n",$1,$2}'
}

act_rm() {
  local key="${1:-}" name
  [ -z "$key" ] && die "usage: aiq $PROV_CLI rm <name|alias>"
  name="$(_py resolve "$(_np "$P_ROOT")" "$key" 2>/dev/null | head -n1)"
  [ -z "$name" ] && die "no profile or alias called '$key'"
  _backup "$(_cred_in "$P_ROOT/$name")" "prerm"
  rm -rf "${P_ROOT:?}/${name:?}"
  printf 'removed %s — its credentials are in %s\n' "$name" "$AIQ_BACKUPS/$PROV"
}

act_quota() {
  _sync quiet
  printf '%s%s%s
' "$C_B" "$P_LABEL" "$C_RST"
  if [ "$PROV" != claude ]; then
    local mark name alias email plan td rd q5 q7 stale hasid subd savedat
    while IFS=$US read -r mark name alias email plan td rd q5 q7 stale hasid subd savedat; do
      [ -z "$name" ] && continue
      printf '  %s %-12.12s %-38.38s %-5s ' "${mark:- }" "$name" "$email" "$plan"
      _days_cell "$subd" 3; printf '
'
    done < <(_py list gpt "$(_np "$P_ROOT")" "${P_ARGS[@]}" 2>/dev/null)
    info "  Codex publishes no usage counters locally — plan and subscription window only."
    return 0
  fi

  # Claude: ask Anthropic for each saved account, not just the signed-in one.
  local mark name alias email plan td rd q5 q7 stale hasid subd savedat
  # The signed-in account may not be saved anywhere yet — show it first, and say so.
  if [ -f "$P_ACTIVE" ] && [ -z "$(_match)" ]; then
    local aout aerr a5 a7
    printf '  %s %-12.12s %-30.30s ' "!" "<signed in>"       "$(_field "$(_py active claude "${P_ARGS[@]}" 2>/dev/null)" email)"
    if [ "${AIQ_OFFLINE:-}" = 1 ]; then
      printf '%soffline%s
' "$C_DIM" "$C_RST"
    else
      aout="$(_py usage "$(_np "$P_ACTIVE")" 2>/dev/null)"
      aerr="$(_field "$aout" error)"
      if [ -n "$aerr" ]; then printf '%s%s%s
' "$C_DIM" "$aerr" "$C_RST"
      else
        a5="$(_field "$aout" q5h)"; a7="$(_field "$aout" q7d)"
        printf '5h '; _pct_cell "$a5"; printf '   7d '; _pct_cell "$a7"
        printf '   %sNOT SAVED — run: aiq claude save <name>%s
' "$C_YEL" "$C_RST"
      fi
    fi
  fi
  while IFS=$US read -r mark name alias email plan td rd q5 q7 stale hasid subd savedat; do
    [ -z "$name" ] && continue
    printf '  %s %-12.12s %-30.30s ' "${mark:- }" "$name" "$email"
    local src="cache" out err
    if [ "${AIQ_OFFLINE:-}" != 1 ]; then
      out="$(_py usage "$(_np "$(_cred_in "$P_ROOT/$name")")" "$(_np "$P_ROOT/$name/usage.json")" 2>/dev/null)"
      err="$(_field "$out" error)"
      if [ -n "$err" ]; then
        printf '%s%s%s
' "$C_DIM" "$err" "$C_RST"
        continue
      fi
      q5="$(_field "$out" q5h)"; q7="$(_field "$out" q7d)"; src="live"
    fi
    printf '5h '; _pct_cell "$q5"; printf '   7d '; _pct_cell "$q7"
    [ "$src" = cache ] && printf '   %scached%s' "$C_DIM" "$C_RST"
    local w; w="$(_field "$out" warn)"
    [ -n "$w" ] && printf '   %s%s%s' "$C_YEL" "$w" "$C_RST"
    printf '
'
  done < <(_py list claude "$(_np "$P_ROOT")" "${P_ARGS[@]}" 2>/dev/null)
  if [ "${AIQ_OFFLINE:-}" = 1 ]; then
    info "  offline: last saved snapshot only. Unset AIQ_OFFLINE for live numbers."
  else
    info "  live from Anthropic's OAuth usage endpoint — the same source as /usage in Claude Code."
  fi
}

# ---------------------------------------------------- parallel workspaces ---
# Switching copies one auth file in and out of a single shared location, so two
# sessions can never run at once and a rotated token can be clobbered.
# A workspace avoids all of that: each account gets its own config directory and
# the CLI is pointed at it with one environment variable. Two terminals, two
# accounts, at the same time — and each CLI refreshes its own token in place.
_env_dir() { printf '%s/%s' "$P_ENVROOT" "$1"; }

_env_current() {
  # Path this shell had set for the provider, if any.
  if [ "$PROV" = claude ]; then printf '%s' "$AIQ_IN_CLAUDE"
  else printf '%s' "$AIQ_IN_CODEX"; fi
}

_env_current_name() {
  # Name of the workspace this shell is in, or empty.
  local cur d
  cur="$(_env_current)"
  [ -z "$cur" ] && return 0
  for d in "$P_ENVROOT"/*/; do
    [ -d "$d" ] || continue
    if [ "$(cd "${d%/}" && pwd)" = "$(cd "$cur" 2>/dev/null && pwd)" ]; then
      basename "${d%/}"; return 0
    fi
  done
  return 0
}

_env_paths() {
  # _env_paths <dir> -> sets EV_CRED / EV_SESS for that workspace
  if [ "$PROV" = claude ]; then EV_CRED="$1/.credentials.json"; EV_SESS="$1/.claude.json"
  else EV_CRED="$1/auth.json"; EV_SESS=""; fi
}

act_envs() {
  local d name out email plan shown=0 cur
  cur="$(_env_current_name)"
  mkdir -p "$P_ENVROOT"
  printf '%s%s workspaces%s   %s%s%s\n' "$C_B" "$P_LABEL" "$C_RST" "$C_DIM" "$P_ENVROOT" "$C_RST"
  printf '%s%-14s %-32s %-6s %s%s\n' "$C_DIM" "NAME" "ACCOUNT" "PLAN" "STATE" "$C_RST"
  for d in "$P_ENVROOT"/*/; do
    [ -d "$d" ] || continue
    shown=1
    name="$(basename "$d")"
    _env_paths "${d%/}"
    local here=""
    [ "$name" = "$cur" ] && here="  ${C_CYA}<- this shell${C_RST}"
    if [ -f "$EV_CRED" ]; then
      out="$(_py active "$PROV" "$(_np "$EV_CRED")" ${EV_SESS:+"$(_np "$EV_SESS")"} 2>/dev/null)"
      email="$(_field "$out" email)"; plan="$(_field "$out" plan)"
      printf '%-14.14s %-32.32s %-6.6s %ssigned in%s%b\n' "$name" "${email:--}" "${plan:--}" "$C_GRN" "$C_RST" "$here"
    else
      printf '%-14.14s %-32.32s %-6.6s %sempty — run: aiq %s login %s%s%b\n' \
        "$name" "-" "-" "$C_YEL" "$PROV_CLI" "$name" "$C_RST" "$here"
    fi
  done
  [ "$shown" = 0 ] && info "  none yet — create one with: aiq $PROV_CLI login <name>"
  [ "$shown" = 1 ] && info "  use one:  eval \"\$(aiq $PROV_CLI env <name>)\"   then run $P_CLI"
  return 0
}

act_env() {
  # Print the export line for the current shell. Meant for: eval "$(aiq claude env work)"
  local name="${1:-}" fmt="${2:-}" d
  [ -z "$name" ] && die "usage: eval \"\$(aiq $PROV_CLI env <name>)\""
  d="$(_env_dir "$name")"
  [ -d "$d" ] || die "no workspace '$name' — create it with: aiq $PROV_CLI login $name"
  # Windows paths carry backslashes. Every form below is quoted so the
  # receiving shell keeps them instead of eating them as escapes.
  case "$fmt" in
    --powershell|--pwsh) printf '$env:%s = "%s"\n' "$P_ENVVAR" "$(_np "$d")" ;;
    --cmd)               printf 'set %s=%s\n' "$P_ENVVAR" "$(_np "$d")" ;;
    --fish)              printf 'set -x %s '"'"'%s'"'"'\n' "$P_ENVVAR" "$(_np "$d")" ;;
    *)                   printf 'export %s='"'"'%s'"'"'\n' "$P_ENVVAR" "$(_np "$d")" ;;
  esac
}

act_run() {
  # Run a command with this workspace active. Defaults to the provider's CLI.
  local name="${1:-}" d
  [ -z "$name" ] && die "usage: aiq $PROV_CLI run <name> [command...]"
  shift
  d="$(_env_dir "$name")"
  [ -d "$d" ] || die "no workspace '$name' — create it with: aiq $PROV_CLI login $name"
  [ "${1:-}" = "--" ] && shift
  if [ $# -eq 0 ]; then set -- "$P_CLI"; fi
  env "$P_ENVVAR=$(_np "$d")" "$@"
}

act_login() {
  # Create a workspace and run the CLI's own login flow *inside* it.
  # A new account can only ever be written into the directory named here, so
  # signing in can never land on top of an account that already exists.
  local name="${1:-}" force="" d
  [ -z "$name" ] && die "usage: aiq $PROV_CLI login <name> [--force]"
  case "${2:-}" in -f|--force) force=1 ;; esac
  d="$(_env_dir "$name")"

  if [ -d "$d" ]; then
    _env_paths "$d"
    if [ -f "$EV_CRED" ] && [ -z "$force" ]; then
      local who; who="$(_field "$(_py active "$PROV" "$(_np "$EV_CRED")" ${EV_SESS:+"$(_np "$EV_SESS")"} 2>/dev/null)" email)"
      warn "workspace '$name' already holds an account${who:+ ($who)}."
      warn "Signing in again would replace it. Pick another name, or pass --force."
      die "refusing to overwrite workspace '$name'"
    fi
  fi

  mkdir -p "$d" || die "could not create $d"
  _env_paths "$d"

  local inenv; inenv="$(_env_current_name)"
  if [ -n "$inenv" ] && [ "$inenv" != "$name" ]; then
    info "note: this shell is currently inside workspace '$inenv'; the login below"
    info "      runs in '$name' regardless, because aiq sets $P_ENVVAR for that call only."
  fi

  info "workspace: $d"
  [ "$PROV" = claude ] && info "sign in with /login once $P_CLI starts"
  env "$P_ENVVAR=$(_np "$d")" "$P_CLI"
}

act_adopt() {
  # Copy a saved switch-profile into a workspace, so nothing has to be re-logged-in.
  local key="${1:-}" as="${2:-}" name d src
  [ -z "$key" ] && die "usage: aiq $PROV_CLI adopt <profile|alias> [workspace-name]"
  name="$(_py resolve "$(_np "$P_ROOT")" "$key" 2>/dev/null | head -n1)"
  [ -z "$name" ] && die "no profile or alias called '$key'"
  [ -z "$as" ] && as="$name"
  d="$(_env_dir "$as")"
  [ -e "$d" ] && die "workspace '$as' already exists"
  mkdir -p "$d" || die "could not create $d"
  src="$(_cred_in "$P_ROOT/$name")"
  [ -f "$src" ] || die "profile '$name' has no credential file"
  _env_paths "$d"
  cp -f "$src" "$EV_CRED" || die "copy failed"
  if [ "$PROV" = claude ] && [ -f "$P_ROOT/$name/claude.json" ]; then
    cp -f "$P_ROOT/$name/claude.json" "$EV_SESS"
  fi
  printf 'workspace %s%s%s created from profile %s\n' "$C_B" "$as" "$C_RST" "$name"
  info "  eval \"\$(aiq $PROV_CLI env $as)\"   then run $P_CLI"
}

act_doctor() {
  printf '%saiq %s%s\n' "$C_B" "$AIQ_VERSION" "$C_RST"
  printf '  %-12s %s\n' "bash" "${BASH_VERSION:-unknown}"
  printf '  %-12s %s\n' "system" "$(uname -s 2>/dev/null || echo unknown)"
  if _find_py; then
    printf '  %-12s %s%s%s  %s\n' "python" "$C_GRN" "$AIQ_PY_BIN" "$C_RST" "$(command -v "$AIQ_PY_BIN")"
  else
    printf '  %-12s %smissing — install python3%s\n' "python" "$C_RED" "$C_RST"
  fi
  local extra=""
  for t in cygpath pgrep tasklist cmp; do
    command -v "$t" >/dev/null 2>&1 && extra="$extra $t"
  done
  printf '  %-12s%s\n' "helpers" "${extra:-  none}"
  printf '\n'
  local p
  for p in claude gpt; do
    _set_provider "$p"
    printf '  %s%s%s\n' "$C_B" "$P_LABEL" "$C_RST"
    if [ -f "$P_ACTIVE" ]; then printf '    %-10s %s\n' "auth" "$P_ACTIVE"
    else printf '    %-10s %snot signed in%s\n' "auth" "$C_YEL" "$C_RST"; fi
    if [ "$PROV" = claude ]; then
      if [ -f "$P_SESSION" ]; then printf '    %-10s %s\n' "session" "$P_SESSION"
      else printf '    %-10s %smissing — account identity unavailable%s\n' "session" "$C_YEL" "$C_RST"; fi
    fi
    printf '    %-10s %s  (%s saved)\n' "profiles" "$P_ROOT" \
      "$(ls -1 "$P_ROOT" 2>/dev/null | grep -v '^\.' | wc -l | tr -d ' ')"
    printf '    %-10s %s  (%s)  $%s\n' "workspaces" "$P_ENVROOT" \
      "$(ls -1 "$P_ENVROOT" 2>/dev/null | wc -l | tr -d ' ')" "$P_ENVVAR"
    local cur; cur="$(_env_current)"
    if [ -n "$cur" ]; then
      printf '    %-10s %s%s%s\n' "this shell" "$C_CYA" "$cur" "$C_RST"
    fi
  done
  printf '    %-10s %s\n' "backups" "$AIQ_BACKUPS"
}

AIQ_LS_FLAG=""
act_both() {
  local what="$1" p
  for p in claude gpt; do
    _set_provider "$p"; PROV_CLI="$p"
    case "$what" in
      ls)     act_ls "$AIQ_LS_FLAG" ;;
      quota)  act_quota ;;
      active) act_active ;;
    esac
    printf '\n'
  done
}

usage() {
  cat <<'USAGE'
aiq — switch Claude Code / Codex CLI accounts, and read their quota

  aiq ls | quota | active           both providers at once
  aiq doctor                        environment check
  aiq <provider> <action> [args]

providers   claude (cl)    gpt (codex, cx)

actions
  ls                      list profiles: account, plan, token life, quota
  use   <name|alias>      switch to a profile
  save  [name] [alias]    save the signed-in account; without a name it updates
                          the profile that already holds this account
  active                  show the signed-in account
  quota                   usage against plan limits
  rm    <name|alias>      delete a profile (credentials are backed up first)
  archive <name|alias>    move a profile aside — kept on disk, hidden from ls
  restore <name>          bring an archived profile back
  prune [--yes]           show profiles that can no longer authenticate;
                          --yes archives them (never deletes)
  sync                    force the write-back described below

  ls also takes --all or --archived.

run two accounts at once (no switching involved)
  login <name>            create a workspace and sign in inside it
  envs                    list workspaces
  env   <name>            print the export line for this shell
  run   <name> [cmd...]   run a command (default: the CLI) in that workspace
  adopt <profile> [name]  turn an existing saved profile into a workspace

  # terminal A                        # terminal B
  eval "$(aiq claude env work)"       eval "$(aiq claude env personal)"
  claude                              claude

  Each workspace is its own config directory, so both CLIs refresh their own
  tokens in place and neither can overwrite the other. `login` refuses to sign
  in over a workspace that already holds an account unless you pass --force.

examples
  aiq claude save a1 personal
  aiq gpt use work
  aiq ls

Before anything that overwrites an auth file, aiq writes the live token back into
the profile it belongs to. That is what stops a rotated refresh token from being
lost — the mistake that gets your device de-authorised. AIQ_FORCE=1 switches even
while a CLI is running (not recommended).
USAGE
}

# ------------------------------------------------------------------- main ---
main() {
  case "${1:-}" in
    ""|-h|--help|help) usage; return 0 ;;
    -V|--version)      printf 'aiq %s\n' "$AIQ_VERSION"; return 0 ;;
    doctor)            act_doctor; return 0 ;;
    ls|list)           AIQ_LS_FLAG="${2:-}"; act_both ls; return 0 ;;
    quota)             act_both quota; return 0 ;;
    active|status|who) act_both active; return 0 ;;
  esac

  _set_provider "$1" || die "unknown provider '$1' — expected claude or gpt (see: aiq --help)"
  PROV_CLI="$1"; shift
  local action="${1:-ls}"; [ $# -gt 0 ] && shift
  case "$action" in
    ls|list)          act_ls "${1:-}" ;;
    use|switch)       act_use "${1:-}" ;;
    archive)          act_archive "${1:-}" ;;
    restore|unarchive) act_restore "${1:-}" ;;
    prune)            act_prune "${1:-}" ;;
    envs|workspaces)  act_envs ;;
    env)              act_env "${1:-}" "${2:-}" ;;
    run)              shift 0; act_run "$@" ;;
    login|new)        act_login "${1:-}" ;;
    adopt)            act_adopt "${1:-}" "${2:-}" ;;
    save|add)         act_save "${1:-}" "${2:-}" ;;
    active|who)       act_active ;;
    quota|usage)      act_quota ;;
    rm|remove|delete) act_rm "${1:-}" ;;
    sync)             _sync ;;
    *)                die "unknown action '$action' — see: aiq --help" ;;
  esac
}

main "$@"
