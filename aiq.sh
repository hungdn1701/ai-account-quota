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
# Scratch CODEX_HOMEs for quota reads. Kept between runs so the model catalog
# is fetched once per account rather than on every `aiq codex quota`.
AIQ_CACHE="$AIQ_DIR/cache"
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


def epoch_iso(sec):
    # Codex reports reset points as unix seconds; Claude as ISO. Normalise to
    # ISO so one cache shape and one formatter serve both providers.
    try:
        return datetime.fromtimestamp(int(sec), timezone.utc).isoformat()
    except Exception:
        return ""


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
    if d["plan"].lower() == "free":
        d["sub_at"] = ""
        d["sub_days"] = ""
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
    # Both providers cache into the same usage.json shape, so one reader serves
    # both. A stale reset time is worse than none, hence the freshness window.
    usage = jload(os.path.join(pdir, "usage.json")) or {}
    fetched = usage.get("_fetched_at")
    try:
        fresh = fetched and (time.time() - float(fetched)) < float(
            os.environ.get("AIQ_USAGE_CACHE_MAX_AGE", "21600"))
    except Exception:
        fresh = False
    if fresh:
        for key, tag in (("five_hour", "q5h"), ("seven_day", "q7d")):
            window = usage.get(key) or {}
            if window.get("utilization") is not None:
                d[tag] = str(window["utilization"])
            if window.get("resets_at"):
                d[tag + "_reset"] = iso_local(window["resets_at"])
            # Codex meters whatever windows the plan has — 5h + weekly on
            # plus/pro, one monthly window on free. Carry the length so the
            # column can say which it is instead of assuming.
            if window.get("window_minutes"):
                d[tag + "_win"] = str(window["window_minutes"])
        d["q_at"] = ms_local(float(fetched) * 1000)
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
    """ok | expiring | dead | unknown -- whether local auth is usable."""
    if provider == "codex":
        # Subscription metadata is not an authentication verdict. Free users
        # can have an expired subscription timestamp and still use Codex.
        return "ok" if d.get("has_cred") == "1" else "dead"
    v = d.get("refresh_days")
    if v in (None, ""):
        return "unknown"
    try:
        f = float(v)
    except Exception:
        return "unknown"
    if f <= 0:
        return "dead"
    return "expiring" if f < 7 else "ok"

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
    rows = []
    for name in profiles_of(root, archived=arch):
        d = prof_read(provider, os.path.join(base, name))
        rows.append((name, d, sha(d["cred_path"])))

    active_name = ""
    if aid:
        same = [item for item in rows if item[1].get("id") == aid]
        exact = [item for item in same if item[2] == ahash]
        if exact:
            active_name = exact[0][0]
        elif same:
            active_name = same[0][0]
    elif ahash:
        exact = [item for item in rows if item[2] == ahash]
        if exact:
            active_name = exact[0][0]

    for name, d, cred_hash in rows:
        mark, stale = " ", ""
        same_id = bool(aid and d.get("id") and aid == d["id"])
        if name == active_name:
            mark = "*"
            if cred_hash != ahash:
                mark, stale = "~", "1"
        elif same_id:
            mark = "=" if cred_hash == ahash else "~"
            stale = "1" if mark == "~" else ""
        elif not aid and cred_hash == ahash:
            mark = "="
        row(mark, name, d.get("alias") or "-", d.get("email") or "-", d.get("plan") or "-",
            d.get("token_days"), d.get("refresh_days"), d.get("q5h"), d.get("q7d"),
            d.get("q5h_reset"), d.get("q7d_reset"), d.get("q5h_win"), d.get("q7d_win"),
            stale, "1" if d.get("id") else "",
            d.get("sub_days"), d.get("saved_at"),
            health(provider, d))


def cmd_match(argv):
    """provider root active_cred [active_session] -> profile name holding the live account"""
    provider, root = argv[0], argv[1]
    _, acred, act = active_of([provider] + argv[2:])
    aid, ahash = act.get("id", ""), sha(acred)
    candidates = []
    fallback = ""
    for name in profiles_of(root):
        d = prof_read(provider, os.path.join(root, name))
        cred_hash = sha(d.get("cred_path", ""))
        if aid and d.get("id") and aid == d["id"]:
            candidates.append((name, cred_hash))
        if ahash and d.get("cred_path") and cred_hash == ahash:
            fallback = name
    exact = [name for name, cred_hash in candidates if cred_hash == ahash]
    if exact:
        print(exact[0])
    elif candidates:
        print(candidates[0][0])
    else:
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
        msg = {401: "access token expired - switch to it and run the CLI once",
               403: "access token expired - switch to it and run the CLI once",
               429: "rate limited by the API - try again shortly"}.get(
                   code, "HTTP %d" % code)
        print("error	" + msg)
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
        if isinstance(w, dict):
            if w.get("utilization") is not None:
                print(tag + "\t" + str(w["utilization"]))
            if w.get("resets_at"):
                print(tag + "_reset\t" + iso_local(w.get("resets_at")))
    for lim in body.get("limits") or []:
        if lim.get("severity") not in (None, "normal"):
            print("warn	%s at %s%% (%s)" % (lim.get("kind"), lim.get("percent"),
                                              lim.get("severity")))
    print("ok	1")


def codex_bin():
    """The codex executable, or "". AIQ_CODEX_BIN wins — a direct path to the
    vendored .exe skips two shim processes."""
    import shutil
    b = os.environ.get("AIQ_CODEX_BIN") or ""
    if b and os.path.exists(b):
        return b
    for n in ("codex.exe", "codex"):
        p = shutil.which(n)
        if p:
            return p
    return ""


def codex_ask(exe, home, auth, timeout):
    """Ask a codex app-server for this account's rate limits.

    Codex has no usage endpoint we can GET the way Claude does — the numbers
    ride along on the responses call and only the CLI knows how to ask. But
    `codex app-server` speaks JSON-RPC and answers account/rateLimits/read, and
    it reads whichever account $CODEX_HOME points at. So: stage the profile's
    auth.json in a scratch home and ask there. The profile directory stays
    clean, and the saved token is never handed to something that might rotate
    it."""
    import shutil, subprocess, threading
    try:
        os.makedirs(home, exist_ok=True)
        shutil.copyfile(auth, os.path.join(home, "auth.json"))
    except Exception as e:
        return {"error": "cannot stage auth.json (%s)" % type(e).__name__}
    env = dict(os.environ)
    env["CODEX_HOME"] = home
    argv = [exe, "app-server"]
    # CreateProcess cannot run a .cmd shim directly, and npm installs one.
    if os.name == "nt" and exe.lower().endswith((".cmd", ".bat")):
        argv = [env.get("COMSPEC") or "cmd.exe", "/c", exe, "app-server"]
    try:
        p = subprocess.Popen(argv, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                             stderr=subprocess.DEVNULL, env=env, text=True,
                             encoding="utf-8", bufsize=1)
    except Exception as e:
        return {"error": "cannot run codex (%s)" % type(e).__name__}
    got = {}

    def pump():
        for line in p.stdout:
            try:
                o = json.loads(line)
            except Exception:
                continue
            if o.get("id") == 2:
                got["account"] = o.get("result") or {}
            elif o.get("id") == 3:
                got["limits"] = (o.get("result") or {}).get("rateLimits") or {}
                got["rpc_error"] = o.get("error")
                break
    try:
        for msg in ({"jsonrpc": "2.0", "id": 1, "method": "initialize",
                     "params": {"clientInfo": {"name": "aiq", "version": "1.0.0"}}},
                    {"jsonrpc": "2.0", "method": "initialized", "params": None},
                    {"jsonrpc": "2.0", "id": 2, "method": "account/read", "params": {}},
                    {"jsonrpc": "2.0", "id": 3, "method": "account/rateLimits/read",
                     "params": None}):
            p.stdin.write(json.dumps(msg) + "\n")
            p.stdin.flush()
    except Exception:
        pass
    t = threading.Thread(target=pump)
    t.daemon = True
    t.start()
    t.join(timeout)
    try:
        p.kill()
    except Exception:
        pass
    if got.get("rpc_error"):
        return {"error": str((got["rpc_error"] or {}).get("message") or "rpc error")}
    if "limits" not in got:
        return {"error": "no answer from codex app-server (%.0fs)" % timeout}
    return got


def cmd_codex_usage(argv):
    """home auth [cache_out] -> live quota for ONE codex profile.

    primary/secondary are whatever windows the plan has: 5h + weekly on
    plus/pro, a single 30d window on free. Report the window length so the
    caller can label them honestly instead of assuming."""
    home, auth = argv[0], argv[1]
    cache = argv[2] if len(argv) > 2 else ""
    exe = codex_bin()
    if not exe:
        print("error	codex CLI not found on PATH — set AIQ_CODEX_BIN")
        return
    got = codex_ask(exe, home, auth,
                    float(os.environ.get("AIQ_CODEX_TIMEOUT", "45")))
    if got.get("error"):
        print("error	" + got["error"])
        return
    lim = got.get("limits") or {}
    acct = ((got.get("account") or {}).get("account") or {})
    body = {"_fetched_at": time.time()}
    for src, tag, key in (("primary", "q5h", "five_hour"),
                          ("secondary", "q7d", "seven_day")):
        w = lim.get(src)
        if not isinstance(w, dict):
            continue
        pct, at = w.get("usedPercent"), epoch_iso(w.get("resetsAt"))
        if pct is not None:
            print(tag + "\t" + str(pct))
        if at:
            print(tag + "_reset\t" + iso_local(at))
        if w.get("windowDurationMins"):
            print(tag + "_win\t" + str(w["windowDurationMins"]))
        body[key] = {"utilization": pct, "resets_at": at,
                     "window_minutes": w.get("windowDurationMins")}
    if acct.get("email"):
        print("email\t" + acct["email"])
    if lim.get("planType") or acct.get("planType"):
        print("plan\t" + str(lim.get("planType") or acct.get("planType")))
    bal = (lim.get("credits") or {}).get("balance")
    if bal not in (None, "", "0"):
        print("credits\t" + str(bal))
    if lim.get("rateLimitReachedType"):
        print("warn\tlimit reached (%s)" % lim["rateLimitReachedType"])
    if cache:
        try:
            with open(cache, "w", encoding="utf-8") as f:
                json.dump(body, f, indent=2)
        except Exception:
            pass
    print("ok\t1")


def cmd_dead(argv):
    """provider root -> names of profiles that can no longer be used"""
    provider, root = argv[0], argv[1]
    for name in profiles_of(root):
        d = prof_read(provider, os.path.join(root, name))
        if health(provider, d) == "dead":
            print(name + "	" + (d.get("email") or "-"))


CMDS = {"dead": cmd_dead, "active": cmd_active, "list": cmd_list, "match": cmd_match, "resolve": cmd_resolve,
        "meta": cmd_meta, "slice": cmd_slice, "merge": cmd_merge, "cmp": cmd_cmp, "usage": cmd_usage,
        "codex_usage": cmd_codex_usage}

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
    codex|cx|gpt|chatgpt|openai)
      PROV=codex; P_ACTIVE="$CODEX_AUTH"; P_SESSION=""
      P_ROOT="$CODEX_PROFILES"; P_CREDNAME="auth.json"; P_LABEL="Codex CLI"
      P_ENVVAR="CODEX_HOME"; P_CLI="codex" ;;
    *) return 1 ;;
  esac
  P_ENVROOT="$AIQ_ENVS/$PROV"
  # "gpt" was the internal name before 1.1; move anything left under it.
  if [ "$PROV" = codex ]; then
    [ -d "$AIQ_ENVS/gpt" ] && [ ! -e "$P_ENVROOT" ] && mv "$AIQ_ENVS/gpt" "$P_ENVROOT" 2>/dev/null
    [ -d "$AIQ_BACKUPS/gpt" ] && [ ! -e "$AIQ_BACKUPS/codex" ] && mv "$AIQ_BACKUPS/gpt" "$AIQ_BACKUPS/codex" 2>/dev/null
  fi
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
    _py meta codex "$(_np "$d/$P_CREDNAME")" "$(_np "$d/profile.json")" >/dev/null || return 1
    # keep profile.email so the older shell scripts still read correctly
    _py active codex "$(_np "$d/$P_CREDNAME")" 2>/dev/null \
      | awk -F'\t' '$1=="email" && $2!="" {print $2}' > "$d/profile.email"
    [ -s "$d/profile.email" ] || rm -f "$d/profile.email"
  fi
  return 0
}

_save_workspace() {
  local workspace="$1" d="$2" src email
  src="$(_env_dir "$workspace")"
  [ -d "$src" ] || { warn "no workspace '$workspace' - see: aiq $PROV_CLI envs"; return 1; }
  _env_paths "$src"
  [ -f "$EV_CRED" ] || { warn "workspace '$workspace' is not signed in"; return 1; }
  if [ "$PROV" = claude ]; then
    [ -f "$EV_SESS" ] || { warn "workspace '$workspace' has no Claude session metadata"; return 1; }
  fi
  if _running; then
    warn "a $P_LABEL process is running; close it before saving workspace '$workspace'"
    return 1
  fi
  [ -f "$d/$P_CREDNAME" ] && _backup "$(_cred_in "$d")" "presave"
  [ -f "$d/claude.json" ] && _backup "$d/claude.json" "presave"
  mkdir -p "$d" || return 1
  cp -f "$EV_CRED" "$d/$P_CREDNAME" || return 1
  if [ "$PROV" = claude ]; then
    _py slice "$(_np "$EV_SESS")" "$(_np "$d/claude.json")" || return 1
    _py meta claude "$(_np "$d/$P_CREDNAME")" "$(_np "$d/claude.json")" \
      "$(_np "$d/profile.json")" >/dev/null || return 1
  else
    _py meta codex "$(_np "$d/$P_CREDNAME")" "$(_np "$d/profile.json")" >/dev/null || return 1
    _py active codex "$(_np "$d/$P_CREDNAME")" 2>/dev/null \
      | awk -F'\t' '$1=="email" && $2!="" {print $2}' > "$d/profile.email"
    [ -s "$d/profile.email" ] || rm -f "$d/profile.email"
  fi
  email="$(_field "$(_py active "$PROV" "$(_np "$EV_CRED")" ${EV_SESS:+"$(_np "$EV_SESS")"} 2>/dev/null)" email)"
  printf '%s' "$email"
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

# An account that was never saved has no profile to be written back into, so
# _sync cannot protect it and overwriting the auth file would lose it outright.
# Give it a profile of its own first, named after the account, and say so.
_rescue_unsaved() {
  [ -f "$P_ACTIVE" ] || return 0
  [ -n "$(_match)" ] && return 0          # already lives in a profile

  local email name n=2
  email="$(_field "$(_py active "$PROV" "${P_ARGS[@]}" 2>/dev/null)" email)"
  name="$(printf '%s' "${email%%@*}" | tr -c 'A-Za-z0-9._-' '-' | sed 's/-*$//')"
  [ -z "$name" ] && name="unsaved-$(date +%Y%m%d-%H%M%S)"
  while [ -e "$P_ROOT/$name" ]; do name="${name%-[0-9]*}-$n"; n=$((n + 1)); done

  if _store "$P_ROOT/$name"; then
    printf '%ssaved the account you were signed in as%s %s%s%s%s\n' \
      "$C_YEL" "$C_RST" "$C_B" "$name" "$C_RST" "${email:+  $email}"
    info "  it had never been saved; without this it would have been lost here"
  else
    warn "could not save the current account - aborting the switch to be safe"
    return 1
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
  local mark name alias email plan td rd q5 q7 q5r q7r q5w q7w stale hasid subd savedat st mcol
  if [ "$PROV" = claude ]; then
    printf '%s%-2s %-24s %-16s %-30s %-5s %-8s %9s %5s %5s %16s %16s%s\n' "$C_DIM" \
      "@" "PROFILE" "ALIAS" "ACCOUNT" "PLAN" "STATUS" "REFRESH" "5H" "7D" "5H RESET" "7D RESET" "$C_RST"
  else
    printf '%s%-2s %-24s %-16s %-34s %-5s %-8s %10s %9s %9s %16s %16s%s\n' "$C_DIM" \
      "@" "PROFILE" "ALIAS" "ACCOUNT" "PLAN" "STATUS" "SUB ENDS" "PRIMARY" "SECONDARY" \
      "PRIMARY RESETS" "SECONDARY RESETS" "$C_RST"
  fi
  while IFS=$US read -r mark name alias email plan td rd q5 q7 q5r q7r q5w q7w stale hasid subd savedat st; do
    [ -z "$name" ] && continue
    shown=1
    case "$mark" in
      '*') mcol="${C_GRN}* ${C_RST}" ;;
      '=') mcol="${C_DIM}= ${C_RST}" ;;
      '~') mcol="${C_YEL}~ ${C_RST}" ;;
      *)   mcol="  " ;;
    esac
    printf '%s' "$mcol"
    if [ "$PROV" = claude ]; then
      printf '%-24s %-16.16s %-30.30s %-5.5s ' "$name" "$alias" "$email" "$plan"
      _health_cell "$st"; printf ' '
      # The refresh token is the real lifetime. The access token above it is
      # short-lived by design and the CLI renews it on every run.
      _days_cell "$rd" 7; printf ' '
      _pct_cell "$q5"; printf ' '; _pct_cell "$q7"; printf ' '; _reset_cell "$q5r"; printf ' '; _reset_cell "$q7r"
    else
      printf '%-24s %-16.16s %-34.34s %-5.5s ' "$name" "$alias" "$email" "$plan"
      _health_cell "$st"; printf ' '; _days_cell "$subd" 3; printf ' '
      # Codex names its windows by length, not by role, so the cell carries the
      # label: "5h 12%" on plus, "30d 100%" on free.
      _win_cell "$q5" "$q5w"; printf ' '; _win_cell "$q7" "$q7w"; printf ' '
      _reset_cell "$q5r"; printf ' '; _reset_cell "$q7r"
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

_list_workspaces() {
  local d name out email plan here shown=0
  for d in "$P_ENVROOT"/*/; do
    [ -d "$d" ] || continue
    _env_paths "${d%/}"
    [ -f "$EV_CRED" ] || continue
    [ "$shown" = 0 ] && {
      printf '\n%sParallel workspaces%s\n' "$C_B" "$C_RST"
      printf '%s  %-24s %-32s %-6s %s%s\n' "$C_DIM" "NAME" "ACCOUNT" "PLAN" "STATE" "$C_RST"
      shown=1
    }
    name="$(basename "${d%/}")"
    out="$(_py active "$PROV" "$(_np "$EV_CRED")" ${EV_SESS:+"$(_np "$EV_SESS")"} 2>/dev/null)"
    email="$(_field "$out" email)"; plan="$(_field "$out" plan)"
    here=""
    [ "$name" = "$(_env_current_name)" ] && here="  <- this shell"
    printf '  %-24s %-32.32s %-6.6s signed in%s\n' "$name" "${email:--}" "${plan:--}" "$here"
  done
  [ "$shown" = 1 ] && info "  run one with: aiq $PROV_CLI run <name>"
}
_reset_cell() {
  [ -n "$1" ] && printf '%16.16s' "$1" || printf '%16s' "-"
}

_win_label() {
  # Window length in minutes -> the name a Codex user recognises. Plans differ:
  # plus/pro meter 5h + weekly, free meters one monthly window.
  case "${1:-}" in
    300)   printf '5h' ;;
    10080) printf '7d' ;;
    43200) printf '30d' ;;
    "")    printf '?' ;;
    *)     awk -v m="$1" 'BEGIN{ if (m%1440==0) printf "%dd", m/1440;
                                 else if (m%60==0) printf "%dh", m/60;
                                 else printf "%dm", m }' ;;
  esac
}

_win_cell() {
  # "<window> <pct>" in one 9-wide column, red once it is nearly spent.
  local p="$1" w="$2" txt
  if [ -z "$p" ]; then printf '%9s' "-"; return; fi
  txt="$(_win_label "$w") ${p}%"
  if awk -v p="$p" 'BEGIN{exit !(p+0 >= 80)}'; then
    printf '%s%9s%s' "$C_RED" "$txt" "$C_RST"
  else
    printf '%9s' "$txt"
  fi
}

_codex_quota_cell() {
  # Live percentages for one saved codex profile, printed on the current row.
  local name="$1" d home out err q5 q7 r5 r7 w5 w7 bal warn
  d="$P_ROOT/$name"
  home="$AIQ_CACHE/codex/$name"
  out="$(_py codex_usage "$(_np "$home")" "$(_np "$(_cred_in "$d")")" \
        "$(_np "$d/usage.json")" 2>/dev/null)"
  err="$(_field "$out" error)"
  if [ -n "$err" ]; then
    printf '   %s%s%s' "$C_DIM" "$err" "$C_RST"; return 0
  fi
  q5="$(_field "$out" q5h)"; q7="$(_field "$out" q7d)"
  r5="$(_field "$out" q5h_reset)"; r7="$(_field "$out" q7d_reset)"
  w5="$(_field "$out" q5h_win)"; w7="$(_field "$out" q7d_win)"
  bal="$(_field "$out" credits)"; warn="$(_field "$out" warn)"
  [ -n "$q5" ] && { printf '   %s ' "$(_win_label "$w5")"; _pct_cell "$q5"; }
  [ -n "$q7" ] && { printf '   %s ' "$(_win_label "$w7")"; _pct_cell "$q7"; }
  # At a high percentage the only question that matters is when it clears.
  [ -n "$r5" ] && printf '   %s%s resets %s%s' "$C_DIM" "$(_win_label "$w5")" "${r5#* }" "$C_RST"
  [ -n "$r7" ] && printf '   %s%s resets %s%s' "$C_DIM" "$(_win_label "$w7")" "${r7#* }" "$C_RST"
  [ -n "$bal" ] && printf '   %scredits %s%s' "$C_DIM" "$bal" "$C_RST"
  [ -n "$warn" ] && printf '   %s%s%s' "$C_YEL" "$warn" "$C_RST"
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
  _list_workspaces
  info "  * = active global CLI; workspaces below are independent"
  if [ "$PROV" = claude ]; then
    info "  5H/7D here is Claude Code's own cache; for live numbers: aiq claude quota"
  else
    info "  PRIMARY/SECONDARY is the last aiq codex quota; for live numbers run it again"
  fi
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

act_rename() {
  local from="${1:-}" to="${2:-}" profile_name existing_profile workspace_name=""
  local profile_src profile_dst workspace_src workspace_dst has_profile=0 has_workspace=0
  [ -n "$from" ] && [ -n "$to" ] || die "usage: aiq $PROV_CLI rename <old> <new>"
  [ "$from" != "$to" ] || die "old and new account names are identical"
  case "$to" in
    .|..|*/*|*\\*) die "invalid account name '$to'" ;;
  esac
  profile_name="$(_py resolve "$(_np "$P_ROOT")" "$from" 2>/dev/null | head -n1)"
  if [ -n "$profile_name" ] && [ -d "$P_ROOT/$profile_name" ]; then
    has_profile=1
    profile_src="$P_ROOT/$profile_name"
    profile_dst="$P_ROOT/$to"
  fi
  if [ -d "$(_env_dir "$from")" ]; then
    workspace_name="$from"
  elif [ -n "$profile_name" ] && [ -d "$(_env_dir "$profile_name")" ]; then
    workspace_name="$profile_name"
  fi
  if [ -n "$workspace_name" ]; then
    has_workspace=1
    workspace_src="$(_env_dir "$workspace_name")"
    workspace_dst="$(_env_dir "$to")"
  fi
  [ "$has_profile" = 1 ] || [ "$has_workspace" = 1 ] || die "no account, profile, or workspace called '$from'"
  existing_profile="$(_py resolve "$(_np "$P_ROOT")" "$to" 2>/dev/null | head -n1)"
  [ -z "$existing_profile" ] || [ "$existing_profile" = "$profile_name" ] || die "account or alias '$to' already exists"
  [ "$has_profile" = 0 ] || [ ! -e "$profile_dst" ] || die "profile '$to' already exists"
  [ "$has_workspace" = 0 ] || [ ! -e "$workspace_dst" ] || die "workspace '$to' already exists"
  [ "$has_workspace" = 0 ] || { [ "$(_env_current_name)" != "$workspace_name" ] || die "workspace '$workspace_name' is active in this shell"; }
  [ "$has_workspace" = 0 ] || { _running && die "a $P_LABEL process is running; close it before renaming an account"; }
  if [ "$has_profile" = 1 ]; then
    mv "$profile_src" "$profile_dst" || die "could not rename profile '$profile_name'"
  fi
  if [ "$has_workspace" = 1 ]; then
    if ! mv "$workspace_src" "$workspace_dst"; then
      [ "$has_profile" = 0 ] || mv "$profile_dst" "$profile_src"
      die "could not rename workspace '$workspace_name'"
    fi
  fi
  printf 'account %s%s%s renamed to %s%s%s\n' "$C_B" "$from" "$C_RST" "$C_B" "$to" "$C_RST"
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
  local name="" alias="" workspace="" d email arg
  while [ "$#" -gt 0 ]; do
    arg="$1"
    case "$arg" in
      --workspace|-w)
        [ "$#" -ge 2 ] || die "usage: aiq $PROV_CLI save <name> [alias] [--workspace <workspace>]"
        workspace="$2"; shift 2 ;;
      --*) die "unknown save option '$arg'" ;;
      *)
        if [ -z "$name" ]; then name="$arg"
        elif [ -z "$alias" ]; then alias="$arg"
        else die "usage: aiq $PROV_CLI save <name> [alias] [--workspace <workspace>]"; fi
        shift ;;
    esac
  done
  if [ -z "$name" ] && [ -n "$workspace" ]; then
    die "usage: aiq $PROV_CLI save <name> [alias] --workspace <workspace>"
  fi
  [ -f "$P_ACTIVE" ] || [ -n "$workspace" ] || die "not signed in — $P_ACTIVE does not exist"
  if [ -z "$name" ]; then
    name="$(_match)"
    [ -z "$name" ] && die "usage: aiq $PROV_CLI save <name> [alias]"
    info "updating the profile that already holds this account: $name"
  fi
  if [ -z "$workspace" ] && [ -n "$name" ]; then
    local candidate="$name" resolved
    resolved="$(_py resolve "$(_np "$P_ROOT")" "$name" 2>/dev/null | head -n1)"
    [ -n "$resolved" ] && { candidate="$resolved"; name="$resolved"; }
    _env_paths "$(_env_dir "$candidate")"
    [ -f "$EV_CRED" ] && workspace="$candidate"
  fi
  d="$P_ROOT/$name"
  if [ -n "$workspace" ]; then
    email="$(_save_workspace "$workspace" "$d")" || die "could not import workspace '$workspace'"
    [ -n "$alias" ] && printf '%s\n' "$alias" > "$d/profile.alias"
    printf '%ssaved%s %s%s%s%s%s\n' "$C_GRN" "$C_RST" "$C_B" "$name" "$C_RST" \
      "${email:+  $email}" "  from workspace $workspace"
    return 0
  fi
  [ -d "$d" ] && _backup "$(_cred_in "$d")" "presave"
  _store "$d" || die "could not save profile '$name'"
  [ -n "$alias" ] && printf '%s\n' "$alias" > "$d/profile.alias"
  email="$(_field "$(_py active "$PROV" "${P_ARGS[@]}" 2>/dev/null)" email)"
  printf '%ssaved%s %s%s%s%s\n' "$C_GRN" "$C_RST" "$C_B" "$name" "$C_RST" "${email:+  $email}"
}

act_use() {
  local key="${1:-}" name d out email plan td rd same newer resume="" want=""
  [ -z "$key" ] && die "usage: aiq $PROV_CLI use <name|alias> [--global] [-c|--resume]"
  shift
  # -c/--resume: an in-progress conversation lives in the transcript files and
  # project history, neither of which a switch touches, so after moving the
  # account you can pick the session straight back up — this does it in one step.
  # --global: documents the scope (use is always global); --lane is rejected
  # with a pointer to `run`, so a wrong mental model fails loudly not silently.
  while [ $# -gt 0 ]; do
    case "$1" in
      -c|--continue) resume=continue ;;
      --resume)      resume=resume ;;
      -g|--global)   want=global ;;
      -l|--lane)     want=lane ;;
      --)            shift; break ;;
      -*)            die "aiq $PROV_CLI use: unknown option '$1'" ;;
      *)             die "aiq $PROV_CLI use: unexpected argument '$1' (name goes first)" ;;
    esac
    shift
  done

  # `use` is GLOBAL scope: it rewrites the one shared config every terminal
  # reads. Inside an aiq lane shell the config dir AND the profile store are the
  # lane's own, so `use` there would silently operate on the lane instead —
  # refuse, and point at the tools that do fit. `run`/`env` are the lane verbs.
  [ "$want" = lane ] && die "\`use\` only does global switches — there is no --lane mode. For a lane:  aiq $PROV_CLI run $key"
  local lane; lane="$(_env_current_name)"
  if [ -n "$lane" ]; then
    die "this shell is inside lane \"$lane\"; \`use\` (global switch) does not apply here. Open a normal terminal for a global switch, or re-sign-in the lane with:  aiq $PROV_CLI login $lane --force"
  fi

  name="$(_py resolve "$(_np "$P_ROOT")" "$key" 2>/dev/null | head -n1)"
  [ -z "$name" ] && die "no profile or alias called '$key' — see: aiq $PROV_CLI ls"
  d="$P_ROOT/$name"
  info "scope: GLOBAL — $name is now the $P_LABEL account for every terminal"

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
    if [ -n "$resume" ]; then _use_resume "$resume" "$@"; fi
    return 0
  fi

  _rescue_unsaved || exit 1
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

  if [ -n "$resume" ]; then _use_resume "$resume" "$@"; fi
}

_use_resume() {
  # Hand straight over to the CLI to continue the current session, now billed to
  # the account we just switched to. Reached only when no CLI was running (the
  # switch would have refused otherwise), so there is nothing to clobber.
  local mode="$1"; shift
  if ! command -v "$P_CLI" >/dev/null 2>&1; then
    warn "$P_CLI is not on PATH — the account is switched; resume the session yourself"
    return 0
  fi
  if [ "$PROV" = claude ]; then
    [ "$mode" = continue ] && set -- --continue "$@" || set -- --resume "$@"
  else
    [ "$mode" = continue ] && set -- resume --last "$@" || set -- resume "$@"
  fi
  info "continuing your session:  $P_CLI $*"
  exec "$P_CLI" "$@"
}

act_active() {
  _sync quiet
  printf '%s%s%s\n' "$C_B" "$P_LABEL" "$C_RST"
  if [ ! -f "$P_ACTIVE" ]; then warn "not signed in ($P_ACTIVE missing)"; return 1; fi
  local workspace; workspace="$(_env_current_name)"
  if [ -n "$workspace" ]; then
    printf '  %-13s %s\n' "workspace" "$workspace"
  fi
  local name; name="$(_match)"
  [ -n "$workspace" ] && name="workspace-only"
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
    local mark name alias email plan td rd q5 q7 q5r q7r q5w q7w stale hasid subd savedat
    while IFS=$US read -r mark name alias email plan td rd q5 q7 q5r q7r q5w q7w stale hasid subd savedat; do
      [ -z "$name" ] && continue
      printf '  %s %-12.12s %-38.38s %-5s ' "${mark:- }" "$name" "$email" "$plan"
      _days_cell "$subd" 3
      if [ "${AIQ_OFFLINE:-}" = 1 ]; then
        [ -n "$q5" ] && { printf '   %s ' "$(_win_label "$q5w")"; _pct_cell "$q5"; }
        [ -n "$q7" ] && { printf '   %s ' "$(_win_label "$q7w")"; _pct_cell "$q7"; }
        [ -n "$q5r" ] && printf '   %s%s resets %s%s' "$C_DIM" "$(_win_label "$q5w")" "${q5r#* }" "$C_RST"
        [ -n "$q7r" ] && printf '   %s%s resets %s%s' "$C_DIM" "$(_win_label "$q7w")" "${q7r#* }" "$C_RST"
        [ -n "$q5$q7" ] && printf '   %scached%s' "$C_DIM" "$C_RST"
      else
        _codex_quota_cell "$name"
      fi
      printf '\n'
    done < <(_py list codex "$(_np "$P_ROOT")" "${P_ARGS[@]}" 2>/dev/null)
    if [ "${AIQ_OFFLINE:-}" = 1 ]; then
      info "  offline: last saved snapshot only. Unset AIQ_OFFLINE for live numbers."
    else
      info "  live from each account's own codex app-server — the same numbers as /status."
    fi
    return 0
  fi

  # Claude: ask Anthropic for each saved account, not just the signed-in one.
  local mark name alias email plan td rd q5 q7 q5r q7r q5w q7w stale hasid subd savedat
  # The signed-in account may not be saved anywhere yet — show it first, and say so.
  if [ -f "$P_ACTIVE" ] && [ -z "$(_match)" ]; then
    local aout aerr a5 a7 r5 r7
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
        r5="$(_field "$aout" q5h_reset)"; r7="$(_field "$aout" q7d_reset)"
        printf '5h '; _pct_cell "$a5"; printf '   7d '; _pct_cell "$a7"
        [ -n "$r5" ] && printf '   5h reset %s' "$r5"
        [ -n "$r7" ] && printf '   7d reset %s' "$r7"
        printf '   %sNOT SAVED — run: aiq claude save <name>%s
' "$C_YEL" "$C_RST"
      fi
    fi
  fi
  while IFS=$US read -r mark name alias email plan td rd q5 q7 q5r q7r q5w q7w stale hasid subd savedat; do
    [ -z "$name" ] && continue
    printf '  %s %-12.12s %-30.30s ' "${mark:- }" "$name" "$email"
    local src="cache" out="" err r5="" r7=""
    # An expired access token cannot read usage, and asking anyway just burns
    # requests until the API rate-limits us.
    case "$td" in
      ""|-*)
        printf '%saccess token expired - aiq claude use %s, then run claude once%s\n' "$C_DIM" "$name" "$C_RST"
        continue ;;
    esac
    if [ "${AIQ_OFFLINE:-}" != 1 ]; then
      out="$(_py usage "$(_np "$(_cred_in "$P_ROOT/$name")")" "$(_np "$P_ROOT/$name/usage.json")" 2>/dev/null)"
      err="$(_field "$out" error)"
      if [ -n "$err" ]; then
        printf '%s%s%s
' "$C_DIM" "$err" "$C_RST"
        continue
      fi
      q5="$(_field "$out" q5h)"; q7="$(_field "$out" q7d)"; src="live"
      r5="$(_field "$out" q5h_reset)"; r7="$(_field "$out" q7d_reset)"
    fi
    printf '5h '; _pct_cell "$q5"; printf '   7d '; _pct_cell "$q7"
    # At a high percentage the only question that matters is when it clears.
    [ -n "$r5" ] && printf '   %s5h reset %s%s' "$C_DIM" "${r5#* }" "$C_RST"
    [ -n "$r7" ] && printf '   %s7d reset %s%s' "$C_DIM" "${r7#* }" "$C_RST"
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
  # Print environment assignments for the current shell.
  local name="${1:-}" fmt="${2:-}" d native aiq_native
  [ -z "$name" ] && die "usage: eval \"\$(aiq $PROV_CLI env <name>)\""
  d="$(_env_dir "$name")"
  [ -d "$d" ] || die "no workspace '$name' - create it with: aiq $PROV_CLI login $name"
  native="$(_np "$d")"; aiq_native="$(_np "$AIQ_DIR")"
  case "$fmt" in
    --powershell|--pwsh)
      printf '$env:%s = "%s"\n' "$P_ENVVAR" "$native"
      if [ "$PROV" = claude ]; then
        printf '$env:HOME = "%s"\n' "$native"
        printf '$env:USERPROFILE = "%s"\n' "$native"
        printf '$env:AIQ_DIR = "%s"\n' "$aiq_native"
      fi ;;
    --cmd)
      printf 'set %s=%s\n' "$P_ENVVAR" "$native"
      if [ "$PROV" = claude ]; then
        printf 'set HOME=%s\n' "$native"
        printf 'set USERPROFILE=%s\n' "$native"
        printf 'set AIQ_DIR=%s\n' "$aiq_native"
      fi ;;
    --fish)
      printf 'set -x %s '\''%s'\''\n' "$P_ENVVAR" "$native"
      if [ "$PROV" = claude ]; then
        printf 'set -x HOME '\''%s'\''\n' "$d"
        printf 'set -x USERPROFILE '\''%s'\''\n' "$native"
        printf 'set -x AIQ_DIR '\''%s'\''\n' "$AIQ_DIR"
      fi ;;
    *)
      printf 'export %s='\''%s'\''\n' "$P_ENVVAR" "$native"
      if [ "$PROV" = claude ]; then
        printf 'export HOME='\''%s'\''\n' "$d"
        printf 'export USERPROFILE='\''%s'\''\n' "$native"
        printf 'export AIQ_DIR='\''%s'\''\n' "$AIQ_DIR"
      fi ;;
  esac
}
act_run() {
  local key="${1:-}" name profile_name d native resume=""
  [ -n "$key" ] || die "usage: aiq $PROV_CLI run <account> [--lane] [-c|--resume] [-- command...]"
  shift
  # Leading aiq flags, then everything else is the command to run in the lane.
  # --lane is an explicit no-op: `run` is always a lane. -c/--resume launch the
  # CLI straight into a continued/resumed conversation, inside the lane.
  while [ $# -gt 0 ]; do
    case "$1" in
      -c|--continue) resume=continue ;;
      --resume)      resume=resume ;;
      --lane)        : ;;
      -g|--global)   die "aiq $PROV_CLI run is always a lane. For a global switch:  aiq $PROV_CLI use $key" ;;
      --)            shift; break ;;
      *)             break ;;
    esac
    shift
  done
  profile_name="$(_py resolve "$(_np "$P_ROOT")" "$key" 2>/dev/null | head -n1)"
  if [ -n "$profile_name" ]; then
    name="$profile_name"
  elif [ -d "$(_env_dir "$key")" ]; then
    name="$key"
  else
    die "no account '$key' - see: aiq $PROV_CLI ls or envs"
  fi
  d="$(_env_dir "$name")"
  if [ ! -d "$d" ] && [ -n "$profile_name" ]; then
    info "creating workspace '$name' from profile '$profile_name'"
    act_workspace "$profile_name" "$name" >/dev/null || die "could not create workspace '$name'"
  fi
  [ -d "$d" ] || die "account '$name' has no workspace"
  info "scope: LANE \"$name\" (this command only) — your global account is untouched"
  [ "${1:-}" = "--" ] && shift
  if [ $# -eq 0 ] && [ -n "$resume" ]; then
    if [ "$PROV" = claude ]; then
      [ "$resume" = continue ] && set -- "$P_CLI" --continue || set -- "$P_CLI" --resume
    else
      [ "$resume" = continue ] && set -- "$P_CLI" resume --last || set -- "$P_CLI" resume
    fi
  fi
  if [ $# -eq 0 ]; then set -- "$P_CLI"; fi
  native="$(_np "$d")"
  if [ "$PROV" = claude ]; then
    env "$P_ENVVAR=$native" HOME="$d" USERPROFILE="$native" AIQ_DIR="$AIQ_DIR" "$@"
  else
    env "$P_ENVVAR=$native" "$@"
  fi
}
act_login() {
  local name="${1:-}" force="" d native rc email
  [ -z "$name" ] && die "usage: aiq $PROV_CLI login <account> [--force]"
  case "${2:-}" in -f|--force) force=1 ;; esac
  d="$(_env_dir "$name")"
  if [ -d "$d" ]; then
    _env_paths "$d"
    if [ -f "$EV_CRED" ] && [ -z "$force" ]; then
      local who; who="$(_field "$(_py active "$PROV" "$(_np "$EV_CRED")" ${EV_SESS:+"$(_np "$EV_SESS")"} 2>/dev/null)" email)"
      warn "account '$name' already holds ${who:-an account}. Pick another name, or pass --force."
      die "refusing to overwrite account '$name'"
    fi
  fi
  mkdir -p "$d" || die "could not create $d"
  _env_paths "$d"
  native="$(_np "$d")"
  info "account: $name"
  [ "$PROV" = claude ] && info "sign in with /login once $P_CLI starts"
  if [ "$PROV" = claude ]; then
    env "$P_ENVVAR=$native" HOME="$d" USERPROFILE="$native" AIQ_DIR="$AIQ_DIR" "$P_CLI"
  else
    env "$P_ENVVAR=$native" "$P_CLI"
  fi
  rc=$?
  _env_paths "$d"
  if [ -f "$EV_CRED" ]; then
    email="$(_save_workspace "$name" "$P_ROOT/$name" 2>/dev/null)" || email=""
    [ -n "$email" ] && info "saved account: $name  $email"
  fi
  return "$rc"
}
act_workspace_rename() {
  local from="${1:-}" to="${2:-}" src dst current
  [ -n "$from" ] && [ -n "$to" ] || die "usage: aiq $PROV_CLI workspace rename <old> <new>"
  [ "$from" != "$to" ] || die "old and new workspace names are identical"
  src="$(_env_dir "$from")"; dst="$(_env_dir "$to")"
  [ -d "$src" ] || die "no workspace '$from' - see: aiq $PROV_CLI envs"
  [ ! -e "$dst" ] || die "workspace '$to' already exists"
  current="$(_env_current_name)"
  [ "$current" != "$from" ] || die "workspace '$from' is active in this shell; open a new shell before renaming it"
  if _running; then
    warn "a $P_LABEL process is running; close it before renaming a workspace"
    return 1
  fi
  mv "$src" "$dst" || die "could not rename workspace '$from'"
  printf 'workspace %s%s%s renamed to %s%s%s\n' "$C_B" "$from" "$C_RST" "$C_B" "$to" "$C_RST"
}

act_workspace() {  # Copy a saved switch-profile into a workspace, so nothing has to be re-logged-in.
  local key="${1:-}" as="${2:-}" name d src
  [ -z "$key" ] && die "usage: aiq $PROV_CLI workspace <profile|alias> [workspace-name]"
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
  for p in claude codex; do
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
  for p in claude codex; do
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
  cat <<'AIQHELP'
aiq - run and switch between several Claude Code / Codex CLI accounts

USAGE
  aiq <provider> <action> [args]      provider:  claude (cl)  |  codex (cx)
  aiq ls | quota | active | doctor    both providers at once

START HERE
  aiq doctor                  check the setup and see where files live
  aiq ls                      which accounts exist, which one is in use
  aiq claude save main        remember the account you are signed in as
                              ^ do this first: an account you have not saved
                                is lost the moment you switch away from it
  aiq quota                   how much of the plan each account has used

WHICH COMMAND?  pick by what you want; aiq assumes nothing and prints the scope
  I want to...                                  then run
  --------------------------------------------  ----------------------------------
  switch account, in every terminal             aiq <p> use <name>
    ^ and keep this conversation going          aiq <p> use <name> -c
    ^ and pick which past conversation first    aiq <p> use <name> --resume
  run two accounts at once, a terminal each     aiq <p> run <name>    (in each)
    ^ but stay in this shell                    eval "$(aiq <p> env <name>)"
  try another account for one command only      aiq <p> run <name> -- <cmd>
  change the account a lane is signed into      aiq <p> login <name> --force
  see who's who / how much quota is left        aiq ls  ·  aiq quota
  save the account I'm signed in as (do first)  aiq <p> save <name>
  retire accounts that no longer authenticate   aiq <p> prune [--yes]

  SCOPE   use        -> GLOBAL: the one shared ~/.<cli>, every terminal follows
          run / env  -> LANE:   an isolated config dir, this terminal only
          Both print a `scope:` line. `use --lane` / `run --global` are errors
          that name the right command; `use` inside a lane shell is refused.
          Full guide:  aiq help scope

MORE HELP
  aiq help scope        global switch vs lane — exactly what to run when
  aiq help profiles     switching the one active account
  aiq help workspaces   running several accounts side by side (lanes)
  aiq help quota        usage numbers, and what STATUS means
  aiq help why          why copying auth files logs you out of your device
  aiq help all          all of the above

Docs: https://github.com/hungdn1701/ai-account-quota
AIQHELP
}

help_profiles() {
  cat <<'AIQHELP'
ACCOUNTS - one active account at a time

  aiq <p> ls                    list accounts
  aiq <p> ls --all              include archived ones
  aiq <p> save [name] [alias]   save the signed-in account.
  aiq <p> login <name>          create account + workspace, then sign in
  aiq <p> use <name|alias>      switch to it. `switch` is the same command.
                                The account you are leaving is always saved
                                first - into its own profile, or into a new
                                one if it had never been saved.
                                Always GLOBAL scope: the one shared config every
                                terminal reads. Prints a `scope:` line. Refused
                                inside a lane shell (that config is separate).
      --global                  assert it - a no-op that documents intent
      -c | --continue           after switching, run `<cli> --continue`
      --resume                  after switching, run `<cli> --resume` (a picker)
                                Transcripts and history survive a switch, so the
                                conversation just carries on under the new
                                account - these flags only save you a command.
  aiq <p> active                show the signed-in account
  aiq <p> run <name> [-c]       run it in an isolated lane (this command only);
                                -c / --resume launch straight into the CLI
  aiq <p> rename <old> <new>   rename account and workspace together
  ls markers: * active profile, = duplicate account, ~ stale snapshot
  aiq <p> rm <name|alias>       delete a profile (credentials backed up first)
  aiq <p> archive <name|alias>  hide it from ls, keep every file
  aiq <p> restore <name>        bring an archived profile back
  aiq <p> prune [--yes]         list profiles that can no longer authenticate;
                                --yes archives them, and never deletes
  aiq <p> sync                  force the write-back below

  Example
    aiq claude save work team     # save the current account as "work"
    aiq claude use team           # come back to it later by alias

  Before anything that overwrites an auth file, aiq copies the live token back
  into the profile it belongs to, and backs up what it is about to replace
  (~/.aiq/backups). It refuses to switch while the CLI is running, because that
  session rewrites the auth file when it exits and would undo the switch; pass
  AIQ_FORCE=1 if you really mean to.

  For Claude only the account keys of ~/.claude.json are carried across. Your
  projects, MCP servers and history stay where they are.
AIQHELP
}

help_workspaces() {
  cat <<'AIQHELP'
WORKSPACES - several accounts at the same time

  Each account has one name and one isolated config directory (a "lane"). `run`
  and `env` are LANE scope: this terminal only, other terminals and the global
  account untouched. `use` is GLOBAL scope: the one shared config every terminal
  reads. aiq prints a `scope:` line on every one so there is no guessing.

  aiq <p> login <name>          create an account, lane, and sign in
  aiq <p> envs                  list lanes, and which one this shell uses
  aiq <p> env <name>            print the line to put THIS shell in a lane
  aiq <p> run <name> [cmd...]   run a command in that lane (default: the CLI)
      --lane                    explicit no-op; `run` is always a lane
      -c | --continue           launch the CLI with `--continue`, in the lane
      --resume                  launch the CLI with `--resume`, in the lane
  aiq <p> workspace <profile>   legacy conversion; normally use `run` instead
  aiq <p> workspace rename <old> <new>  legacy: rename workspace only

  Import a workspace into a classic profile:
    aiq claude save <profile> [alias] --workspace <workspace>
    Close Claude first; the old profile is backed up automatically.

  Two terminals, two accounts
    # terminal A                        # terminal B
    eval "$(aiq claude env work)"       eval "$(aiq claude env personal)"
    claude                              claude

  One-off, without changing your shell
    aiq claude run work
    aiq claude run work -- claude -p "summarise this"

  PowerShell           Invoke-Expression (aiq claude env work --powershell)
  fish                 aiq claude env work --fish | source

  login refuses to sign in over a workspace that already holds an account,
  so a new login can never land on top of an existing one. Use --force to
  override, or just pick another name.
AIQHELP
}

help_quota() {
  cat <<'AIQHELP'
QUOTA AND STATUS

  aiq quota            both providers
  aiq <p> quota        per profile

  For Claude this asks Anthropic directly - the same source as the /usage screen
  in Claude Code - for every saved profile, so you can see which account still
  has room BEFORE switching to it. It is a read-only call and never refreshes a
  token. Profiles whose access token has already expired are skipped, since the
  call cannot succeed. AIQ_OFFLINE=1 uses the last saved snapshot instead.

  The 5H/7D columns in `ls` come from Claude Code's own cache, which it only
  updates when you open /usage. Anything older than 6 hours is left blank rather
  than shown as a stale number. Use `aiq claude quota` for live figures.

  For Codex this asks each account's own `codex app-server` for its live rate
  limits - the same numbers as Codex's own /status. It reads the saved auth.json
  and never rotates it. Plans meter different windows: plus/pro report a 5h and a
  weekly window, free reports a single monthly one, so each column is labelled by
  length (5h / 7d / 30d) rather than by role. AIQ_OFFLINE=1 uses the last saved
  snapshot; set AIQ_CODEX_BIN if the codex CLI is not on PATH.

  The PRIMARY/SECONDARY columns in `ls` are whatever the last `aiq codex quota`
  saved; run it again for live figures.

  STATUS
    ok         usable
    expiring   Claude: refresh token under 7 days left
               Codex: subscription metadata only; not authentication health
    dead       no usable local credential; sign in again
    ?          not enough information (an old profile saved without identity;
               run `aiq <p> save <name>` while signed in as it to fix)

  For Claude, dead is decided by the REFRESH token, which lives about 27 days -
  not by the access token. An expired access token is normal: the CLI mints a
  new one every run.
AIQHELP
}

help_why() {
  cat <<'AIQHELP'
WHY THIS EXISTS

  Copying .credentials.json or auth.json around to change accounts keeps logging
  you out of your device, while staying on one account never does. That is not a
  bug in the CLI. It is OAuth refresh-token rotation:

    1. You restore account A's saved auth file and start working.
    2. The CLI refreshes A's token. The provider issues a NEW refresh token and
       invalidates the old one. Your saved copy is now stale.
    3. You switch to B without saving A first. A's newest token is overwritten
       and gone.
    4. Later you restore A's stale copy. The provider sees a spent refresh token
       being replayed - the signature of a stolen token - and revokes the whole
       family. You are asked to sign in on this device again.

  aiq answers this twice over:

    - workspaces never copy anything, so the problem cannot arise (recommended)
    - switching writes the live token back into its own profile first, so the
      rotated token is never the one that gets lost

  It also matches profiles by account identity (accountUuid for Claude,
  chatgpt_account_id for Codex) rather than by file hash. A hash changes on every
  refresh, which is why hash-based switchers lose track of who is signed in.
AIQHELP
}

help_scope() {
  cat <<'AIQHELP'
SCOPE - global switch vs. lane

  aiq changes accounts two different ways. It never guesses which you want:
  you pick the command, and every run prints a `scope:` line back.

  GLOBAL   aiq <p> use <name>
    Rewrites the one config directory the CLI reads by default (~/.claude,
    ~/.codex). EVERY terminal - and the next one you open - now uses <name>.
    The account you leave is saved first. Refuses while the CLI is running.
    Use this when you just want to be "on" a different account for a while.

  LANE     aiq <p> run <name>        (one command / one terminal)
           eval "$(aiq <p> env <name>)"   (rest of this shell)
    Points the CLI at an isolated config dir via one env var. Only this
    process is affected; other terminals and the global account do not move.
    Each lane refreshes its own token in place, so several can run at once.
    Use this to run two accounts side by side.

  WHICH DO I RUN?
    just switch, everywhere ............... aiq <p> use <name>
    switch + keep this chat going ......... aiq <p> use <name> -c
    switch + pick a chat to resume ....... aiq <p> use <name> --resume
    two accounts, two terminals .......... aiq <p> run <name>   in each
    two accounts, keep this shell ........ eval "$(aiq <p> env <name>)"
    one account for a single command ..... aiq <p> run <name> -- <cmd>
    change what account a lane holds ..... aiq <p> login <name> --force
                                            (from a normal terminal)

  ASSERTING SCOPE (optional, for scripts or certainty)
    aiq <p> use <name> --global    ok in a normal terminal; a no-op that
                                   documents intent
    aiq <p> use <name> --lane      error -> "use is global; for a lane: run"
    aiq <p> run <name> --global    error -> "run is always a lane; use: use"
    aiq <p> run <name> --lane      ok; a no-op
    aiq <p> use <name>  (in a lane shell)   refused - that shell's config and
                                   profile store are the lane's own, so `use`
                                   there would not mean what it looks like

  -c / --resume work on both `use` and `run`. They map to `claude --continue`
  / `claude --resume`, and `codex resume --last` / `codex resume`. A switch
  never touches transcripts or project history, so the conversation simply
  carries on under the new account - the flag only saves you a second command.
AIQHELP
}

help_topic() {
  case "${1:-}" in
    scope|lane|lanes|global)      help_scope ;;
    profile|profiles|switch)      help_profiles ;;
    workspace|workspaces|env|envs|parallel) help_workspaces ;;
    quota|usage|status)           help_quota ;;
    why|background|trap)          help_why ;;
    all)
      usage; printf '\n'; help_scope; printf '\n'; help_profiles; printf '\n'
      help_workspaces; printf '\n'; help_quota; printf '\n'; help_why ;;
    ""|help)                      usage ;;
    *)
      printf 'no help topic "%s"\n\n' "$1" >&2
      printf 'topics: scope · profiles · workspaces · quota · why · all\n' >&2
      return 1 ;;
  esac
}

# ------------------------------------------------------------------- main ---
main() {
  case "${1:-}" in
    ""|-h|--help)      usage; return 0 ;;
    help)              help_topic "${2:-}"; return $? ;;
    -V|--version)      printf 'aiq %s\n' "$AIQ_VERSION"; return 0 ;;
    doctor)            act_doctor; return 0 ;;
    ls|list)           AIQ_LS_FLAG="${2:-}"; act_both ls; return 0 ;;
    quota)             act_both quota; return 0 ;;
    active|status|who) act_both active; return 0 ;;
  esac

  if ! _set_provider "$1"; then
    printf '%saiq: "%s" is not a provider or a command%s\n\n' "$C_RED" "$1" "$C_RST" >&2
    printf 'providers:  claude (cl)   codex (cx)\n' >&2
    printf 'commands:   ls · quota · active · doctor · help\n' >&2
    case "$1" in
      # they typed an action but left out which CLI it applies to
      ls|list|use|switch|save|add|who|rm|remove|delete|archive|restore|prune|sync|\
      login|new|envs|env|run|workspace|ws|import|adopt|rename|mv)
        printf '\ndid you mean:  aiq claude %s    (or: aiq codex %s)\n' "$1" "$1" >&2 ;;
      c|cl|cla*|anthropic*|antropic)
        printf '\ndid you mean:  aiq claude ...\n' >&2 ;;
      co|cod*|cx*|gpt*|chat*|open*)
        printf '\ndid you mean:  aiq codex ...\n' >&2 ;;
      *)
        printf '\nfull help:  aiq help\n' >&2 ;;
    esac
    exit 1
  fi
  PROV_CLI="$1"; shift
  local action="${1:-ls}"; [ $# -gt 0 ] && shift
  case "$action" in
    ls|list)          act_ls "${1:-}" ;;
    use|switch)       act_use "$@" ;;
    archive)          act_archive "${1:-}" ;;
    restore|unarchive) act_restore "${1:-}" ;;
    prune)            act_prune "${1:-}" ;;
    envs|workspaces)  act_envs ;;
    env)              act_env "${1:-}" "${2:-}" ;;
    run)              shift 0; act_run "$@" ;;
    login|new)        act_login "${1:-}" ;;
    workspace|ws|import|adopt)
      if [ "${1:-}" = rename ] || [ "${1:-}" = mv ]; then shift; act_workspace_rename "$@"
      else act_workspace "${1:-}" "${2:-}"; fi ;;
    rename|mv)         act_rename "$@" ;;
    save|add)         act_save "$@" ;;
    active|who)       act_active ;;
    quota|usage)      act_quota ;;
    rm|remove|delete) act_rm "${1:-}" ;;
    sync)             _sync ;;
    help|-h|--help)
      if [ -n "${1:-}" ]; then
        help_topic "$1"
      else
        help_scope; printf '\n'; help_profiles; printf '\n'; help_workspaces
        printf '\nAlso: aiq help quota · aiq help why · aiq help all\n'
      fi ;;
    *)                printf '%saiq: %s has no action "%s"%s\n' "$C_RED" "$PROV_CLI" "$action" "$C_RST" >&2
                      printf '\ntry one of:\n  %s ls · use · save · active · quota · prune\n' "$PROV_CLI" >&2
                      printf '  %s login | envs | env | run | workspace (ws) | rename\n\n' "$PROV_CLI"
                      printf 'full help:  aiq help\n' >&2
                      exit 1 ;;
  esac
}

main "$@"
