#!/usr/bin/env bash
# aiq — switch between multiple Claude Code / Codex CLI accounts, and read their quota.
# Single file. Linux, macOS, Windows (Git Bash).
#
# Why this exists: copying auth files around breaks OAuth refresh-token rotation
# and gets your device de-authorised. See README, "The re-login trap".
set -uo pipefail

AIQ_VERSION="1.2.0"
AIQ_SOURCE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
US=$''   # field separator between the python engine and this script

# ------------------------------------------------------------------ paths ---
# Capture what the shell actually set, before the defaults below overwrite it —
# that is how we know whether this shell is already inside a workspace.
AIQ_IN_CLAUDE="${CLAUDE_CONFIG_DIR:-}"
AIQ_IN_CODEX="${CODEX_HOME:-}"

CLAUDE_HOME="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
CLAUDE_CRED="$CLAUDE_HOME/.credentials.json"
# Claude Code resolves this as join(CLAUDE_CONFIG_DIR || homedir(), ".claude.json").
# Follow that exactly: keying off whether the file exists yet meant a lane whose
# config had not been written pointed at the HOST's session file instead.
if [ -n "${AIQ_CLAUDE_SESSION:-}" ]; then
  CLAUDE_SESSION="$AIQ_CLAUDE_SESSION"
elif [ -n "${CLAUDE_CONFIG_DIR:-}" ]; then
  CLAUDE_SESSION="$CLAUDE_CONFIG_DIR/.claude.json"
else
  CLAUDE_SESSION="$HOME/.claude.json"
fi

CODEX_HOME="${CODEX_HOME:-$HOME/.codex}"
CODEX_AUTH="$CODEX_HOME/auth.json"

AIQ_DIR="${AIQ_DIR:-$HOME/.aiq}"
AIQ_BACKUPS="$AIQ_DIR/backups"
AIQ_ENVS="$AIQ_DIR/envs"
# Scratch CODEX_HOMEs for quota reads. Kept between runs so the model catalog
# is fetched once per account rather than on every `aiq codex quota`.
AIQ_CACHE="$AIQ_DIR/cache"
AIQ_KEEP_BACKUPS="${AIQ_KEEP_BACKUPS:-40}"

# Claude Code keeps conversation transcripts in $CLAUDE_CONFIG_DIR/projects, so
# a lane would record its own and `claude --continue` after a switch would find
# nothing. Lanes link that directory back to the host's, and export the host
# path so aiq running inside a lane can still find it.
if [ -n "${AIQ_HOST_CLAUDE:-}" ]; then
  CLAUDE_HOST="$AIQ_HOST_CLAUDE"
elif [ -n "$AIQ_IN_CLAUDE" ]; then
  CLAUDE_HOST="$(dirname "$AIQ_DIR")/.claude"   # lanes export AIQ_DIR too
else
  CLAUDE_HOST="$CLAUDE_HOME"
fi
# The host's own .claude.json sits beside its config dir, not inside it.
CLAUDE_HOST_SESSION="$(dirname "$CLAUDE_HOST")/.claude.json"
# Saved accounts are aiq's, not a lane's: inside a lane, still use the real ones.
if [ -n "${AIQ_HOST_CLAUDE:-}" ]; then CLAUDE_PROFILES="$AIQ_HOST_CLAUDE/profiles"
else CLAUDE_PROFILES="$CLAUDE_HOME/profiles"; fi

# Codex has the same split: everything lives under CODEX_HOME, so a lane keeps
# its own conversation history, skills and plugins unless we say otherwise.
if [ -n "${AIQ_HOST_CODEX:-}" ]; then
  CODEX_HOST="$AIQ_HOST_CODEX"
elif [ -n "$AIQ_IN_CODEX" ]; then
  CODEX_HOST="$(dirname "$AIQ_DIR")/.codex"
else
  CODEX_HOST="$CODEX_HOME"
fi
if [ -n "${AIQ_HOST_CODEX:-}" ]; then CODEX_PROFILES="$AIQ_HOST_CODEX/profiles"
else CODEX_PROFILES="$CODEX_HOME/profiles"; fi

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
import sys, json, base64, os, time, hashlib, re
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
    access = o.get("accessToken") or ""
    refresh = o.get("refreshToken") or ""
    d["token_at"] = ms_local(o.get("expiresAt"))
    d["token_days"] = ms_days(o.get("expiresAt"))
    d["token_ms"] = str(o.get("expiresAt") or "")
    d["refresh_at"] = ms_local(o.get("refreshTokenExpiresAt"))
    d["refresh_days"] = ms_days(o.get("refreshTokenExpiresAt"))
    d["plan"] = o.get("subscriptionType") or ""
    # Claude leaves an OAuth object behind after logout; only non-empty token
    # strings are evidence that a saved credential is usable.
    d["has_cred"] = "1" if (access or refresh) else "0"

    s = jload(session) or {}
    oa = s.get("oauthAccount") or {}
    d["email"] = oa.get("emailAddress") or ""
    d["id"] = oa.get("accountUuid") or ""
    d["org"] = oa.get("organizationType") or ""

    cu = s.get("cachedUsageUtilization") or {}
    u = cu.get("utilization") or {}
    cache_id = cu.get("accountUuid") or ""
    d["usage_mismatch"] = "1" if (cache_id and d["id"] and cache_id != d["id"]) else "0"
    if d["usage_mismatch"] == "1":
        # A shared ~/.claude.json can contain the previous account's cache.
        # Do not display or persist it under the current owner.
        u = {}
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
        # The reset time is as stale as the percentage it belongs to. Showing it
        # after blanking the number invites reading a spent window as current.
        d[tag + "_reset"] = "" if not fresh else iso_local(b.get("resets_at"))
    d["q_at"] = "" if d["usage_mismatch"] == "1" else ms_local(cu.get("fetchedAtMs"))
    d["sub_at"] = ""
    d["sub_days"] = ""
    return d


def claude_slice(session):
    s = jload(session) or {}
    result = {k: s[k] for k in ACCOUNT_KEYS if k in s}
    oa = s.get("oauthAccount") or {}
    cu = result.get("cachedUsageUtilization") or {}
    if (cu.get("accountUuid") and oa.get("accountUuid") and
            cu.get("accountUuid") != oa.get("accountUuid")):
        result.pop("cachedUsageUtilization", None)
    return result


def text_snippet(value, limit=180):
    """Human-readable transcript text; bounded and stripped of token-shaped data."""
    bits = []
    if isinstance(value, str):
        bits.append(value)
    elif isinstance(value, list):
        for item in value:
            if isinstance(item, str):
                bits.append(item)
            elif isinstance(item, dict) and item.get("type") == "text":
                bits.append(str(item.get("text") or ""))
    elif isinstance(value, dict):
        bits.append(str(value.get("text") or ""))
    text = " ".join(bits)
    text = re.sub(r"(?i)(bearer\s+\S+|sk-ant-[A-Za-z0-9_-]+|eyJ[A-Za-z0-9_.-]{30,})",
                  "<redacted>", text)
    text = re.sub(r"[\r\n\t\x1f]+", " ", text)
    text = re.sub(r"\s+", " ", text).strip()
    return text[:limit] + ("..." if len(text) > limit else "")


def claude_project_dir(projects_root, project):
    """Resolve a working directory to Claude's projects/<encoded-path> store."""
    if not os.path.isdir(projects_root):
        return ""
    raw = os.path.abspath(project or os.getcwd())
    if os.path.isdir(raw) and os.path.dirname(raw) == os.path.abspath(projects_root):
        return raw
    key = re.sub(r"[^A-Za-z0-9._-]", "-", raw.replace("\\", "/"))
    candidate = os.path.join(projects_root, key)
    if os.path.isdir(candidate):
        return candidate
    wanted = key.lower()
    for name in os.listdir(projects_root):
        if name.lower() == wanted and os.path.isdir(os.path.join(projects_root, name)):
            return os.path.join(projects_root, name)
    return ""


def claude_session_info(path, profiles_root=""):
    info = {"id": os.path.basename(path).rsplit(".jsonl", 1)[0], "owner": "",
            "email": "", "profile": "", "updated": "", "branch": "",
            "cwd": "", "state": "open", "request": "", "reply": "", "path": path}
    last_ts = 0.0
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as stream:
            for raw in stream:
                try:
                    obj = json.loads(raw)
                except Exception:
                    continue
                if not isinstance(obj, dict):
                    continue
                if obj.get("sessionId"):
                    info["id"] = str(obj["sessionId"])
                if obj.get("ownerAccountUuid") and not info["owner"]:
                    info["owner"] = str(obj["ownerAccountUuid"])
                info["cwd"] = info["cwd"] or str(obj.get("cwd") or "")
                info["branch"] = info["branch"] or str(obj.get("gitBranch") or "")
                stamp = obj.get("timestamp") or ""
                try:
                    parsed = iso_dt(stamp).timestamp() if stamp else 0.0
                except Exception:
                    parsed = 0.0
                if parsed >= last_ts:
                    last_ts = parsed
                    info["updated"] = iso_local(stamp)
                message = obj.get("message") or {}
                role = message.get("role") if isinstance(message, dict) else ""
                content = message.get("content") if isinstance(message, dict) else ""
                origin = obj.get("origin") or {}
                human = (obj.get("promptSource") == "typed" or origin.get("kind") == "human" or
                         (obj.get("type") == "user" and isinstance(content, str)))
                if role == "user" and human:
                    snippet = text_snippet(content)
                    if snippet:
                        info["request"] = snippet
                if role == "assistant":
                    snippet = text_snippet(content)
                    if snippet:
                        info["reply"] = snippet
                cause = str(obj.get("cause") or "")
                if (obj.get("type") == "history-suppression" and "owner_mismatch" in cause) or \
                        "authentication_failed" in raw:
                    info["state"] = "auth-error"
    except Exception:
        info["state"] = "unreadable"
    try:
        info["mtime"] = os.path.getmtime(path)
    except Exception:
        info["mtime"] = 0.0
    if info["owner"] and profiles_root:
        for name in profiles_of(profiles_root):
            profile = prof_read("claude", os.path.join(profiles_root, name))
            if profile.get("id") == info["owner"]:
                info["profile"] = name
                info["email"] = profile.get("email") or ""
                break
    return info


def claude_sessions(projects_root, project, profiles_root=""):
    directory = claude_project_dir(projects_root, project)
    if not directory:
        return "", []
    rows = []
    for name in os.listdir(directory):
        path = os.path.join(directory, name)
        if name.lower().endswith(".jsonl") and os.path.isfile(path):
            rows.append(claude_session_info(path, profiles_root))
    rows.sort(key=lambda item: item.get("mtime", 0), reverse=True)
    return directory, rows


def cmd_sessions(argv):
    """projects_root project profiles_root [limit] -> project-local Claude sessions."""
    projects_root, project, profiles_root = argv[0], argv[1], argv[2]
    try:
        limit = max(1, min(200, int(argv[3]))) if len(argv) > 3 else 30
    except Exception:
        limit = 30
    directory, sessions = claude_sessions(projects_root, project, profiles_root)
    if not directory:
        print("error\tno Claude transcript directory for " + project)
        return
    for item in sessions[:limit]:
        row(item["id"], item["owner"], item["email"], item["profile"], item["updated"],
            item["state"], item["branch"], item["request"], item["path"])


def handoff_markdown(item, project_dir):
    owner = item.get("email") or ("account UUID " + item.get("owner", "unknown"))
    return "\n".join([
        "# Claude session handoff", "",
        "This is a handoff into a **new Claude session**. Do not run `--resume` on the source session:",
        "Claude binds that session to its original account owner.", "",
        "- Source session: `" + item.get("id", "") + "`",
        "- Source owner: `" + owner + "`" + (" (" + item.get("owner") + ")" if item.get("owner") else "") + "`",
        "- Project transcript directory: `" + project_dir + "`",
        "- Last activity: `" + (item.get("updated") or "unknown") + "`",
        "- Branch: `" + (item.get("branch") or "unknown") + "`", "",
        "## Required next steps", "",
        "1. Read the source transcript at `" + item.get("path", "") + "` and extract the unfinished task, decisions, files changed, errors, and next action.",
        "2. Inspect the current worktree (`git status`, diff, relevant files and tests); the transcript is context, not ground truth.",
        "3. Verify the current state and continue the unfinished work under this account.",
        "4. Before another account switch, write a fresh checkpoint into this handoff file or a project checkpoint file.", "",
        "## Last human request (hint)", item.get("request") or "(not available)", "",
        "## Last assistant update (hint)", item.get("reply") or "(not available)", "",
        "Source transcript is read-only for this handoff: `" + item.get("path", "") + "`", ""
    ])


def cmd_handoff(argv):
    """projects_root project profiles_root selector output -> write handoff."""
    projects_root, project, profiles_root, selector, output = argv[:5]
    directory, sessions = claude_sessions(projects_root, project, profiles_root)
    selected = None
    if selector in ("", "latest", "last"):
        selected = sessions[0] if sessions else None
    else:
        selected = next((item for item in sessions if item["id"] == selector), None)
    if not selected:
        print("error\tno Claude session found: " + selector)
        return
    content = handoff_markdown(selected, directory)
    content = content.replace(chr(96) + chr(32) + chr(40), chr(32) + chr(40))
    if output:
        parent = os.path.dirname(output)
        if parent:
            os.makedirs(parent, exist_ok=True)
        with open(output, "w", encoding="utf-8", newline="\n") as stream:
            stream.write(content)
        print("written\t" + output)
    else:
        print(content, end="")


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
    # The access token is what the API checks (10 days); the id token lapses
    # within the hour and says nothing about whether the login still works.
    exp = jwt_payload(t.get("access_token", "")).get("exp") or p.get("exp")
    d["token_at"] = ms_local(int(exp) * 1000) if exp else ""
    d["token_days"] = ms_days(int(exp) * 1000) if exp else ""
    d["token_ms"] = str(int(exp) * 1000) if exp else ""
    d["refresh_days"] = ""
    # Codex refreshes a login once it is about a week old, or once the access
    # token has lapsed. Anything that may trigger that must not run against a
    # login that is live somewhere else: one of the two would then replay a
    # spent refresh token, and OpenAI signs the account out everywhere.
    last = iso_dt(a.get("last_refresh"))
    due = (last is None or time.time() - last.timestamp() > 7 * 86400 or
           (exp and float(exp) < time.time() + 3600))
    d["refresh_due"] = "1" if due else "0"
    d["has_cred"] = "1" if (t.get("id_token") or a.get("OPENAI_API_KEY")) else "0"
    d["org"] = ""
    for k in ("q5h", "q7d", "q5h_reset", "q7d_reset", "q_at"):
        d[k] = ""
    return d


# ----------------------------------------------------------- one login ---
# A profile, its lane and the quota scratch dir can each hold a copy of the same
# login, and each copy refreshes on its own. Only the most recently refreshed
# one still holds a live refresh token; restoring any other replays a spent one.
def lane_files(provider, lane):
    if provider == "claude":
        return os.path.join(lane, ".credentials.json"), os.path.join(lane, ".claude.json")
    return os.path.join(lane, "auth.json"), ""


def cred_fresh(provider, cred, sess=""):
    """(freshness, account id) of one copy of a login; (None, "") if unusable."""
    a = jload(cred) if cred else None
    if not isinstance(a, dict):
        return None, ""
    if provider == "claude":
        o = a.get("claudeAiOauth") or {}
        if not (o.get("accessToken") or o.get("refreshToken")):
            return None, ""
        ident = claude_read(cred, sess).get("id") or ""
        try:
            key = float(o.get("expiresAt") or 0) / 1000.0
        except Exception:
            key = 0.0
    else:
        t = a.get("tokens") or {}
        if not (t.get("refresh_token") or t.get("access_token")):
            return None, ""
        ident = codex_read(cred).get("id") or ""
        last = iso_dt(a.get("last_refresh"))
        key = last.timestamp() if last else float(
            jwt_payload(t.get("access_token", "")).get("iat") or 0)
    if not key:
        try:
            key = os.path.getmtime(cred)
        except Exception:
            key = 0.0
    if not ident:
        ident = (jload(os.path.join(os.path.dirname(cred), "profile.json")) or {}).get("id") or ""
    return key, ident


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
        # Banked resets ride in the same snapshot, under the same freshness rule.
        rc = usage.get("reset_credits") or {}
        if rc.get("available") is not None:
            d["bank"] = str(rc["available"])
        if rc.get("expires_at"):
            d["bank_exp"] = iso_local(rc["expires_at"])
        if rc.get("title"):
            d["bank_title"] = rc["title"]
        # Everything the old quota row printed after the columns, kept as one
        # trailing note. A spent window is already visible as 100%, so only an
        # unusual reason for it is worth the space.
        notes = []
        bal = usage.get("credits_balance")
        if bal not in (None, "", "0"):
            notes.append("credits " + str(bal))
        hit = usage.get("limit_reached")
        if hit and hit != "rate_limit_reached":
            notes.append(str(hit).replace("_", " "))
        for cap in usage.get("limits") or []:
            if isinstance(cap, dict) and cap.get("severity") not in (None, "normal"):
                notes.append("%s at %s%% (%s)" % (cap.get("kind"), cap.get("percent"),
                                                  cap.get("severity")))
        if notes:
            d["note"] = " · ".join(notes)
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
    if d.get("has_cred") != "1":
        return "dead"
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


def lane_state(provider, envroot, name, ident):
    """The account's lane, as one word: - | idle | running | empty | other."""
    lane = os.path.join(envroot, name) if envroot else ""
    if not lane or not os.path.isdir(lane):
        return "-"
    lc, lsess = lane_files(provider, lane)
    key, li = cred_fresh(provider, lc, lsess) if os.path.isfile(lc) else (None, "")
    if key is None:
        return "empty"
    if ident and li and li != ident:
        return "other"
    info = jload(os.path.join(lane, "app-server-daemon", "daemon.pid")) or {}
    return "running" if pid_file_alive(info) else "idle"


def cmd_list(argv):
    """provider root active_cred [active_session] [--archived] [--lanes envroot]
    -> one row per profile"""
    provider, root = argv[0], argv[1]
    rest = argv[2:]
    arch = "--archived" in rest
    rest = [a for a in rest if a != "--archived"]
    envroot = ""
    if "--lanes" in rest:
        i = rest.index("--lanes")
        envroot = rest[i + 1] if i + 1 < len(rest) else ""
        rest = rest[:i] + rest[i + 2:]
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
            health(provider, d), d.get("q_at"),
            d.get("bank"), d.get("bank_exp"), d.get("bank_title"),
            d.get("note"), lane_state(provider, envroot, name, d.get("id") or ""))


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


def preferred(provider, root, names, envroot="", global_name=""):
    """Names of one account, the one worth keeping first: the account in use
    everywhere, then the newest login, then the one running in its lane."""
    def score(n):
        cred, sess = prof_files(provider, os.path.join(root, n))
        key = cred_fresh(provider, cred, sess)[0] if cred else None
        live = 0
        if envroot:
            info = jload(os.path.join(envroot, n, "app-server-daemon", "daemon.pid")) or {}
            live = 1 if pid_file_alive(info) else 0
        return (0 if n == global_name else 1, -(key if key is not None else float("-inf")), -live, n)
    return sorted(names, key=score)


def match_key(provider, root, key):
    """What a key typed by a person means: a name, an alias, an email, or the
    start of an email. -> (names, ids): every profile it fits, and how many
    distinct accounts those are. Emails are only tried when provider is given."""
    names = profiles_of(root)
    if key in names:
        return [key], 1
    for name in names:
        try:
            with open(os.path.join(root, name, "profile.alias")) as f:
                if f.read().strip() == key:
                    return [name], 1
        except Exception:
            pass
    if not provider or len(key) < 3:
        return [], 0
    k = key.lower()
    exact, start = [], []
    for name in names:
        d = prof_read(provider, os.path.join(root, name))
        email = (d.get("email") or "").lower()
        if email == k:
            exact.append((name, d.get("id") or name))
        elif email.startswith(k):
            start.append((name, d.get("id") or name))
    hits = exact or start
    return [n for n, _ in hits], len({i for _, i in hits})


def cmd_resolve(argv):
    """root key [provider envroot global] -> the profile a name, alias or email
    (or its start) means; "" if none; "ambiguous<TAB>names" if it fits several
    accounts."""
    root, key = argv[0], argv[1]
    provider = argv[2] if len(argv) > 2 else ""
    envroot = argv[3] if len(argv) > 3 else ""
    global_name = argv[4] if len(argv) > 4 else ""
    names, ids = match_key(provider, root, key)
    if ids > 1:
        print("ambiguous\t" + " ".join(names))
    elif len(names) > 1:
        # One account saved under several names: the copy worth using.
        print(preferred(provider, root, names, envroot, global_name)[0])
    else:
        print(names[0] if names else "")


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
    # Account keys only, even if the saved file holds more (older layouts kept
    # a whole ~/.claude.json): the rest is this machine's, not the account's.
    live.update({k: sl[k] for k in ACCOUNT_KEYS if k in sl})
    with open(argv[1], "w", encoding="utf-8") as f:
        json.dump(live, f, indent=2)


def _positive_seconds(value):
    try:
        value = float(value)
        return value if value > 0 else 0.0
    except Exception:
        return 0.0


def _atomic_json(path, value):
    """Replace a credential JSON atomically, without printing its contents."""
    import tempfile, stat
    parent = os.path.dirname(os.path.abspath(path)) or "."
    fd, tmp = tempfile.mkstemp(prefix=".aiq-refresh-", suffix=".json", dir=parent,
                               text=True)
    try:
        with os.fdopen(fd, "w", encoding="utf-8", newline="\n") as stream:
            json.dump(value, stream, indent=2)
            stream.write("\n")
            stream.flush()
            os.fsync(stream.fileno())
        try:
            os.chmod(tmp, stat.S_IRUSR | stat.S_IWUSR)
        except Exception:
            pass
        os.replace(tmp, path)
    finally:
        try:
            os.unlink(tmp)
        except FileNotFoundError:
            pass


def cmd_refresh(argv):
    """Refresh one Claude credential using Claude Code's OAuth consumer flow."""
    import urllib.request, urllib.error
    if not argv:
        print("error\tcredential path is required")
        return 1
    cred = argv[0]
    document = jload(cred)
    if not isinstance(document, dict):
        print("error\tcredential file is not a JSON object")
        return 1
    oauth = document.get("claudeAiOauth") or {}
    if not isinstance(oauth, dict):
        print("error\tcredential file has invalid claudeAiOauth data")
        return 1
    refresh = oauth.get("refreshToken") or ""
    if not isinstance(refresh, str) or not refresh:
        print("error\tno refresh token in " + os.path.basename(cred))
        return 1

    now_ms = int(time.time() * 1000)
    try:
        refresh_at = int(oauth.get("refreshTokenExpiresAt") or 0)
    except Exception:
        refresh_at = 0
    if refresh_at and refresh_at <= now_ms:
        print("error\trefresh token expired; run 'claude' and /login again")
        return 1

    payload = {
        "grant_type": "refresh_token",
        "refresh_token": refresh,
        "client_id": "9d1c250a-e61b-44d9-88ed-5944d1962f5e",
        "scope": " ".join(("user:profile", "user:inference", "user:sessions:claude_code",
                            "user:mcp_servers", "user:file_upload")),
    }
    request = urllib.request.Request(
        "https://platform.claude.com/v1/oauth/token",
        data=json.dumps(payload).encode("utf-8"), method="POST",
        headers={"Content-Type": "application/json", "Accept": "application/json",
                 "User-Agent": "aiq"})
    try:
        with urllib.request.urlopen(request,
                                    timeout=float(os.environ.get("AIQ_TIMEOUT", "30"))) as response:
            body = json.loads(response.read().decode("utf-8"))
    except urllib.error.HTTPError as exc:
        if exc.code in (400, 401, 403):
            message = "refresh rejected (token expired or revoked); run 'claude' and /login again"
        elif exc.code == 429:
            message = "refresh rate limited by Anthropic; try again shortly"
        else:
            message = "refresh failed (HTTP %d)" % exc.code
        print("error\t" + message)
        return 1
    except Exception as exc:
        print("error\trefresh failed (" + type(exc).__name__ + ")")
        return 1

    if not isinstance(body, dict):
        print("error\trefresh returned an invalid response")
        return 1
    access = body.get("access_token") or ""
    access_seconds = _positive_seconds(body.get("expires_in"))
    if not isinstance(access, str) or not access or not access_seconds:
        print("error\trefresh response did not contain a usable access token")
        return 1
    rotated = body.get("refresh_token")
    if not isinstance(rotated, str) or not rotated:
        rotated = refresh

    updated = dict(document)
    updated_oauth = dict(oauth)
    updated_oauth["accessToken"] = access
    updated_oauth["refreshToken"] = rotated
    updated_oauth["expiresAt"] = now_ms + int(access_seconds * 1000)
    refresh_seconds = _positive_seconds(body.get("refresh_token_expires_in"))
    if refresh_seconds:
        updated_oauth["refreshTokenExpiresAt"] = now_ms + int(refresh_seconds * 1000)
    scope = body.get("scope")
    if isinstance(scope, str) and scope.strip():
        updated_oauth["scopes"] = scope.split()
    elif isinstance(scope, list) and scope:
        updated_oauth["scopes"] = scope
    updated["claudeAiOauth"] = updated_oauth
    try:
        _atomic_json(cred, updated)
    except Exception as exc:
        print("error\tcould not save refreshed credentials (" + type(exc).__name__ + ")")
        return 1
    print("ok\t1")
    print("access_days\t%.1f" % (access_seconds / 86400.0))
    if refresh_seconds:
        print("refresh_days\t%.1f" % (refresh_seconds / 86400.0))
    return 0


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
                got["result"] = o.get("result") or {}
                got["limits"] = got["result"].get("rateLimits") or {}
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
    res = got.get("result") or {}
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
    # Banked resets: one-off grants that clear a spent window early. The count
    # is what you compare between accounts; the expiry is the deadline to beat,
    # so report the credit that lapses first rather than the whole list.
    rc = res.get("rateLimitResetCredits") or {}
    avail = rc.get("availableCount")
    if isinstance(avail, int):
        print("bank\t" + str(avail))
        body["reset_credits"] = {"available": avail}
    first = None
    for c in rc.get("credits") or []:
        if not isinstance(c, dict) or c.get("status") != "available":
            continue
        when = c.get("expiresAt")
        if when and (first is None or when < first[0]):
            first = (when, c.get("title") or "")
    if first:
        at = epoch_iso(first[0])
        print("bank_exp\t" + iso_local(at))
        if first[1]:
            print("bank_title\t" + first[1])
        body.setdefault("reset_credits", {}).update(
            {"expires_at": at, "title": first[1]})
    if bal not in (None, ""):
        body["credits_balance"] = str(bal)
    if lim.get("rateLimitReachedType"):
        print("warn\tlimit reached (%s)" % lim["rateLimitReachedType"])
        body["limit_reached"] = lim["rateLimitReachedType"]
    if cache:
        try:
            with open(cache, "w", encoding="utf-8") as f:
                json.dump(body, f, indent=2)
        except Exception:
            pass
    print("ok\t1")


def cmd_seed_projects(argv):
    """host_json lane_json -> give a lane the host's per-project settings.

    `.claude.json` lives inside CLAUDE_CONFIG_DIR, so a lane necessarily has its
    own and re-asks the trust dialog for every directory you have already
    approved. The `projects` map is machine state, not account state, so a lane
    can be handed it. Existing lane entries always win: this only fills gaps."""
    host = jload(argv[0]) or {}
    lane_path = argv[1]
    lane = jload(lane_path)
    fresh = lane is None
    if fresh:
        lane = {}
    hp = host.get("projects") or {}
    lp = lane.get("projects") or {}
    added = 0
    for key, val in hp.items():
        if key not in lp:
            lp[key] = val
            added += 1
    if not added and not fresh:
        print("added\t0")
        return
    lane["projects"] = lp
    try:
        with open(lane_path, "w", encoding="utf-8") as f:
            json.dump(lane, f, indent=2)
    except Exception as e:
        print("error\t" + type(e).__name__)
        return
    print("added\t%d" % added)


def merge_tree(src, dst, lane):
    """Move everything under src into dst. A directory both sides have is merged
    into, not renamed: Codex files sessions by date (sessions/2026/10/...), so
    the lane and the host share most directory names, and a renamed one would
    hide its conversations from Codex. A file both sides have keeps both: the
    lane's copy is suffixed with its name rather than overwriting yours."""
    import shutil
    moved = left = 0
    for entry in sorted(os.listdir(src)):
        a = os.path.join(src, entry)
        b = os.path.join(dst, entry)
        if os.path.isdir(a) and not os.path.islink(a) and os.path.isdir(b):
            m, l = merge_tree(a, b, lane)
            moved, left = moved + m, left + l
            try:
                os.rmdir(a)
            except Exception:
                left += 1
            continue
        if os.path.exists(b):
            stem, ext = os.path.splitext(entry)
            b = os.path.join(dst, "%s.lane-%s%s" % (stem, lane, ext))
            if os.path.exists(b):
                left += 1
                continue
        try:
            shutil.move(a, b)
            moved += 1
        except Exception:
            left += 1
    return moved, left


def cmd_lane_projects(argv):
    """src dst lane -> move a lane's transcripts into the shared store."""
    src, dst, lane = argv[0], argv[1], argv[2]
    try:
        os.makedirs(dst, exist_ok=True)
        moved, left = merge_tree(src, dst, lane)
    except Exception:
        moved, left = 0, 1
    print("moved\t%d" % moved)
    print("left\t%d" % left)


def cmd_dead(argv):
    """provider root -> names of profiles that can no longer be used"""
    provider, root = argv[0], argv[1]
    for name in profiles_of(root):
        d = prof_read(provider, os.path.join(root, name))
        if health(provider, d) == "dead":
            print(name + "	" + (d.get("email") or "-"))


def cmd_newer(argv):
    """provider credA sessA credB sessB -> a | b | same | other | unknown
    Which of two copies of one login was refreshed last."""
    provider = argv[0]
    ka, ia = cred_fresh(provider, argv[1], argv[2])
    kb, ib = cred_fresh(provider, argv[3], argv[4])
    if ka is None or kb is None or not ia or not ib:
        print("unknown")
    elif ia != ib:
        print("other")
    else:
        print("a" if ka > kb else "b" if kb > ka else "same")


def cmd_plan(argv):
    """provider root envroot cacheroot [name...] -> name, pull, lane

    pull  which copy the profile should be refreshed from: lane | scratch | ""
    lane  none | ok | older | empty | other | unknown -- the account's lane,
          compared with the profile as it will be once pulled."""
    provider, root, envroot, cacheroot = argv[:4]
    for name in argv[4:] or profiles_of(root):
        pdir = os.path.join(root, name)
        ip = prof_read(provider, pdir).get("id") or "" if os.path.isdir(pdir) else ""
        pc, ps = prof_files(provider, pdir)
        kp = cred_fresh(provider, pc, ps)[0] if pc and os.path.isfile(pc) else None
        lane = os.path.join(envroot, name)
        lc, lsess = lane_files(provider, lane)
        kl, il = cred_fresh(provider, lc, lsess) if os.path.isfile(lc) else (None, "")
        sc = os.path.join(cacheroot, name, "auth.json") if provider == "codex" else ""
        ks, isc = cred_fresh(provider, sc) if sc and os.path.isfile(sc) else (None, "")
        best = kp if kp is not None else float("-inf")
        pull = ""
        if ip:
            if kl is not None and il == ip and kl > best:
                best, pull = kl, "lane"
            if ks is not None and isc == ip and ks > best:
                best, pull = ks, "scratch"
        if not os.path.isdir(lane):
            state = "none"
        elif kl is None:
            state = "empty"
        elif not ip or not il:
            state = "unknown"
        elif il != ip:
            state = "other"
        else:
            state = "older" if kl < best else "ok"
        row(name, pull, state)


def kernel32():
    """kernel32 with real signatures: ctypes would otherwise pass and return
    every HANDLE as a 32-bit int."""
    import ctypes
    from ctypes import wintypes
    k = ctypes.WinDLL("kernel32", use_last_error=True)
    k.OpenProcess.restype = wintypes.HANDLE
    k.OpenProcess.argtypes = [wintypes.DWORD, wintypes.BOOL, wintypes.DWORD]
    k.CloseHandle.argtypes = [wintypes.HANDLE]
    k.GetExitCodeProcess.argtypes = [wintypes.HANDLE, ctypes.POINTER(wintypes.DWORD)]
    k.GetProcessTimes.argtypes = [wintypes.HANDLE] + [ctypes.POINTER(wintypes.FILETIME)] * 4
    k.TerminateProcess.argtypes = [wintypes.HANDLE, wintypes.UINT]
    k.WaitForSingleObject.argtypes = [wintypes.HANDLE, wintypes.DWORD]
    return k


def pid_alive(pid):
    try:
        pid = int(pid)
    except Exception:
        return False
    if pid <= 0:
        return False
    if os.name == "nt":
        # os.kill(pid, 0) would TERMINATE the process on Windows; ask instead.
        import ctypes
        from ctypes import wintypes
        k32 = kernel32()
        handle = k32.OpenProcess(0x1000, False, pid)   # PROCESS_QUERY_LIMITED_INFORMATION
        if not handle:
            return False
        code = wintypes.DWORD(0)
        ok = k32.GetExitCodeProcess(handle, ctypes.byref(code))
        k32.CloseHandle(handle)
        return bool(ok) and code.value == 259          # STILL_ACTIVE
    try:
        os.kill(pid, 0)
        return True
    except PermissionError:
        return True
    except Exception:
        return False


def win_start_time(pid):
    """Creation time of a Windows process as a FILETIME integer, or None."""
    import ctypes
    from ctypes import wintypes
    k32 = kernel32()
    handle = k32.OpenProcess(0x1000, False, int(pid))
    if not handle:
        return None
    times = [wintypes.FILETIME() for _ in range(4)]
    ok = k32.GetProcessTimes(handle, *[ctypes.byref(t) for t in times])
    k32.CloseHandle(handle)
    return (times[0].dwHighDateTime << 32) | times[0].dwLowDateTime if ok else None


def pid_file_alive(info):
    """Is the process a Codex pid file names still that process? The file also
    records when it started, so a pid Windows has since handed to some other
    program does not count."""
    pid = info.get("pid")
    if not pid_alive(pid):
        return False
    want = str(info.get("processStartTime") or "")
    if os.name == "nt" and want.isdigit():
        return str(win_start_time(pid)) == want
    return True


def cmd_daemons(argv):
    """home... -> 1 or 0 per home: is that CODEX_HOME's managed app-server up?"""
    for home in argv:
        info = jload(os.path.join(home, "app-server-daemon", "daemon.pid")) or {}
        print("1" if pid_file_alive(info) else "0")


def cmd_stop_updater(argv):
    """home -> stop that CODEX_HOME's daemon auto-updater.

    `codex app-server daemon stop` stops the daemon but not its updater
    (`app-server daemon pid-update-loop`), which keeps running from the home's
    own copy of the binary with its log open. Until it is gone, the home can be
    neither moved nor removed. The next `codex` in that home starts a new one."""
    import signal, subprocess
    info = jload(os.path.join(argv[0], "app-server-daemon", "daemon-updater.pid")) or {}
    if not pid_file_alive(info):
        print("stopped\t0")
        return
    pid = int(info["pid"])
    if os.name == "nt":
        k32 = kernel32()
        handle = k32.OpenProcess(0x0001 | 0x00100000, False, pid)   # TERMINATE | SYNCHRONIZE
        if not handle:
            print("error\tcannot open process %d" % pid)
            return
        k32.TerminateProcess(handle, 1)
        k32.WaitForSingleObject(handle, 5000)
        k32.CloseHandle(handle)
    else:
        try:
            args = subprocess.run(["ps", "-p", str(pid), "-o", "args="], stdout=subprocess.PIPE,
                                  universal_newlines=True).stdout
        except Exception:
            args = ""
        if "pid-update-loop" not in args:
            print("stopped\t0")
            return
        os.kill(pid, signal.SIGTERM)
        for _ in range(50):
            if not pid_alive(pid):
                break
            time.sleep(0.1)
    print("stopped\t1")


def cmd_dupes(argv):
    """provider root [envroot] [global] -> one line per account saved under
    several names, the one worth keeping first"""
    provider, root = argv[0], argv[1]
    envroot = argv[2] if len(argv) > 2 else ""
    global_name = argv[3] if len(argv) > 3 else ""
    seen = {}
    for name in profiles_of(root):
        ident = prof_read(provider, os.path.join(root, name)).get("id") or ""
        if ident:
            seen.setdefault(ident, []).append(name)
    for names in seen.values():
        if len(names) > 1:
            print(" ".join(preferred(provider, root, names, envroot, global_name)))


def cmd_keep(argv):
    """provider root envroot global key... -> what `keep` would do, one row each:
    keep  name email note  |  drop  name email reason  |  error  key message"""
    provider, root, envroot, global_name = argv[:4]
    kept = {}                                   # account id -> kept name
    errors = 0
    for key in argv[4:]:
        names, ids = match_key(provider, root, key)
        if not names:
            row("error", key, "no account matches it")
            errors += 1
        elif ids > 1:
            row("error", key, "fits several accounts: " + " ".join(names) + " — be more specific")
            errors += 1
        else:
            ident = prof_read(provider, os.path.join(root, names[0])).get("id") or names[0]
            # The name you typed wins; otherwise the copy worth keeping.
            kept.setdefault(ident, key if key in names else
                            preferred(provider, root, names, envroot, global_name)[0])
    if errors:
        return
    for name in profiles_of(root):
        d = prof_read(provider, os.path.join(root, name))
        ident = d.get("id") or name
        email = d.get("email") or "-"
        info = jload(os.path.join(envroot, name, "app-server-daemon", "daemon.pid")) or {}
        running = "; its lane is running" if pid_file_alive(info) else ""
        if kept.get(ident) == name:
            row("keep", name, email, "in use now" if name == global_name else "")
        elif name == global_name:
            row("drop", name, email, "in use now — switch to another account first")
        elif ident in kept:
            row("drop", name, email, "same account as " + kept[ident] + running)
        else:
            row("drop", name, email, "not in your list" + running)


# Settings that pick an account or a credential store. A lane holds a different
# account, so these stay whatever the lane says, or unset.
SEED_SKIP = {"toml": {"cli_auth_credentials_store", "forced_login_method",
                      "forced_chatgpt_workspace_id", "preferred_auth_method"},
             "json": {"apiKeyHelper", "forceLoginMethod", "forceLoginOrgUUID"}}


def fill_gaps(base, extra, skip=()):
    """Copy into base every key of extra it lacks, recursively. base wins."""
    added = 0
    for k, v in extra.items():
        if k in skip:
            continue
        if k not in base:
            base[k] = v
            added += 1
        elif isinstance(base[k], dict) and isinstance(v, dict):
            added += fill_gaps(base[k], v)
    return added


BARE_KEY = re.compile(r"^[A-Za-z0-9_-]+$")


def toml_key(k):
    return k if BARE_KEY.match(k) else json.dumps(k, ensure_ascii=False)


def toml_value(v):
    import datetime as dt
    if isinstance(v, bool):
        return "true" if v else "false"
    if isinstance(v, int):
        return str(v)
    if isinstance(v, float):
        if v != v:
            return "nan"
        if v in (float("inf"), float("-inf")):
            return "inf" if v > 0 else "-inf"
        return repr(v)
    if isinstance(v, str):
        return json.dumps(v, ensure_ascii=False)
    if isinstance(v, (dt.datetime, dt.date, dt.time)):
        return v.isoformat()
    if isinstance(v, list):
        return "[" + ", ".join(toml_value(x) for x in v) + "]"
    if isinstance(v, dict):
        return "{" + ", ".join(toml_key(k) + " = " + toml_value(x) for k, x in v.items()) + "}"
    raise TypeError(type(v).__name__)


def toml_dump(doc):
    """Enough TOML for a CLI config. The caller re-parses the result and keeps
    the original file unless it reads back identical."""
    lines = []

    def is_aot(v):
        return isinstance(v, list) and v and all(isinstance(x, dict) for x in v)

    def emit(path, table):
        plain = [(k, v) for k, v in table.items() if not isinstance(v, dict) and not is_aot(v)]
        if path and (plain or not table):
            lines.append("[" + ".".join(toml_key(p) for p in path) + "]")
        for k, v in plain:
            lines.append(toml_key(k) + " = " + toml_value(v))
        if plain or (path and not table):
            lines.append("")
        for k, v in table.items():
            if isinstance(v, dict):
                emit(path + [k], v)
            elif is_aot(v):
                for item in v:
                    lines.append("[[" + ".".join(toml_key(p) for p in path + [k]) + "]]")
                    for ik, iv in item.items():
                        lines.append(toml_key(ik) + " = " + toml_value(iv))
                    lines.append("")
    emit([], doc)
    return "\n".join(lines).rstrip("\n") + "\n"


def cmd_seed_config(argv):
    """toml|json host lane -> fill the lane's settings file from the host's.

    A lane used to start from an empty config.toml / settings.json, so every
    new one meant setting the model, trusted projects and the rest again. Now
    it starts from yours: keys it lacks are copied in, keys it has are kept."""
    fmt, host, lane = argv[0], argv[1], argv[2]
    try:
        if fmt == "toml":
            import tomllib
            with open(host, "rb") as f:
                src = tomllib.load(f)
            dst = {}
            if os.path.isfile(lane):
                with open(lane, "rb") as f:
                    dst = tomllib.load(f)
        else:
            src = jload(host)
            dst = jload(lane) if os.path.isfile(lane) else {}
            if not isinstance(src, dict) or not isinstance(dst, dict):
                raise ValueError("not a JSON object")
    except Exception as e:
        print("skip\t" + type(e).__name__)
        return
    added = fill_gaps(dst, src, SEED_SKIP.get(fmt, ()))
    if not added:
        print("added\t0")
        return
    if fmt == "toml":
        text = toml_dump(dst)
        try:
            if tomllib.loads(text) != dst:
                raise ValueError("round trip")
        except Exception as e:
            print("skip\t" + type(e).__name__)
            return
    else:
        text = json.dumps(dst, indent=2, ensure_ascii=False) + "\n"
    # The rewrite drops comments, so the lane's own file is kept once, as it was.
    keep = lane + ".before-aiq"
    if os.path.isfile(lane) and not os.path.exists(keep):
        import shutil
        shutil.copyfile(lane, keep)
    tmp = lane + ".aiq-tmp"
    with open(tmp, "w", encoding="utf-8", newline="\n") as f:
        f.write(text)
    os.replace(tmp, lane)
    print("added\t%d" % added)


CMDS = {"dead": cmd_dead, "active": cmd_active, "list": cmd_list, "match": cmd_match, "resolve": cmd_resolve,
        "meta": cmd_meta, "slice": cmd_slice, "merge": cmd_merge, "cmp": cmd_cmp, "refresh": cmd_refresh, "usage": cmd_usage,
        "codex_usage": cmd_codex_usage, "lane_projects": cmd_lane_projects,
        "seed_projects": cmd_seed_projects, "sessions": cmd_sessions, "handoff": cmd_handoff,
        "newer": cmd_newer, "plan": cmd_plan, "daemons": cmd_daemons, "dupes": cmd_dupes,
        "seed_config": cmd_seed_config, "keep": cmd_keep, "stop_updater": cmd_stop_updater}

if __name__ == "__main__":
    if len(sys.argv) < 2 or sys.argv[1] not in CMDS:
        sys.exit(2)
    result = CMDS[sys.argv[1]](sys.argv[2:])
    if isinstance(result, int):
        sys.exit(result)
PYCODE

_py() {
  _find_py || die "python3 (or python) is required — run: aiq doctor"
  # Feed the embedded engine over stdin; Windows CreateProcess has a short
  # command-line limit that the session/handoff parser can exceed.
  printf '%s\n' "$AIQ_PY" | "$AIQ_PY_BIN" - "$@"
}

# -------------------------------------------------------------- provider ---
PROV=""; P_ACTIVE=""; P_SESSION=""; P_ROOT=""; P_CREDNAME=""; P_LABEL=""; PROV_CLI=""
P_ENVROOT=""; P_ENVVAR=""; P_CLI=""; P_HOST=""
declare -a P_ARGS=()

_set_provider() {
  PROCS=""; PROCS_DONE=""
  case "${1:-}" in
    claude|cl|anthropic)
      PROV=claude; P_ACTIVE="$CLAUDE_CRED"; P_SESSION="$CLAUDE_SESSION"
      P_ROOT="$CLAUDE_PROFILES"; P_CREDNAME=".credentials.json"; P_LABEL="Claude Code"
      P_ENVVAR="CLAUDE_CONFIG_DIR"; P_CLI="claude"; P_HOST="$CLAUDE_HOST" ;;
    codex|cx|gpt|chatgpt|openai)
      PROV=codex; P_ACTIVE="$CODEX_AUTH"; P_SESSION=""
      P_ROOT="$CODEX_PROFILES"; P_CREDNAME="auth.json"; P_LABEL="Codex CLI"
      P_ENVVAR="CODEX_HOME"; P_CLI="codex"; P_HOST="$CODEX_HOST" ;;
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

# Every running process of this provider's CLI, one per line as "<kind> <cmdline>":
#   tui     an interactive session, or exec / resume / login: it holds a login
#   daemon  Codex's managed app-server, one per CODEX_HOME; sessions are its clients
#   ide     another app-server: an editor extension (VS Code, JetBrains) holding the
#           global login for as long as the editor is open
#   helper  MCP servers and the like
# Read once per provider and cached: on Windows it costs a PowerShell start.
PROCS=""; PROCS_DONE=""
_procs_load() {
  [ -n "$PROCS_DONE" ] && return 0
  local exe raw=""; [ "$PROV" = claude ] && exe="claude" || exe="codex"
  if command -v powershell.exe >/dev/null 2>&1; then
    raw="$(powershell.exe -NoProfile -Command \
      "Get-CimInstance Win32_Process -Filter \"name='$exe.exe'\" | ForEach-Object { [string]\$_.CommandLine }" \
      2>/dev/null | tr -d '\r')"
  elif command -v ps >/dev/null 2>&1; then
    # Match on the executable's own name: `pgrep -x codex` used to count the
    # daemon too, which made every switch look blocked.
    raw="$(ps -A -o args= 2>/dev/null | awk -v e="$exe" '{ n = $1; sub(/.*\//, "", n); if (n == e) print }')"
  fi
  PROCS="$(printf '%s\n' "$raw" | awk 'NF {
      k = "tui"
      if ($0 ~ /--managed-daemon|app-server daemon/) k = "daemon"
      else if ($0 ~ /app-server/) k = "ide"
      else if ($0 ~ /(^| )mcp( |$)|mcp-serve|--mcp/) k = "helper"
      print k " " $0 }')"
  PROCS_DONE=1
}

# True only if an *interactive* CLI session is up — the kind that holds a login.
_running() { _procs_load; printf '%s\n' "$PROCS" | grep -q '^tui '; }
_ide_running() { _procs_load; printf '%s\n' "$PROCS" | grep -q '^ide '; }

# --------------------------------------------------------- codex daemons ---
# Since 0.15x, `codex` no longer runs the agent itself. It starts one long-lived
# `codex app-server --managed-daemon` per CODEX_HOME and talks to it; the daemon
# stays up for days. It loads auth.json once and never re-reads it: swapping the
# file under it changes nothing, and its next refresh writes the login it started
# with back over the one we put there. Changing a home's login needs it stopped.
_codex_exe() {
  if [ -n "${AIQ_CODEX_BIN:-}" ]; then printf '%s' "$AIQ_CODEX_BIN"
  else command -v codex 2>/dev/null; fi
}

_daemon_up() {
  # _daemon_up <codex-home> -> 1 if its managed daemon is running, else 0
  if [ "$PROV" != codex ] || [ ! -f "$1/app-server-daemon/daemon.pid" ]; then
    printf 0; return 0
  fi
  _py daemons "$(_np "$1")" 2>/dev/null | head -n1
}

_daemon_stop() {
  # _daemon_stop <codex-home> <label> — stop that home's daemon; the next `codex`
  # starts a fresh one with whatever login the home holds by then.
  local home="$1" label="$2" exe i
  [ "$(_daemon_up "$home")" = 1 ] || return 0
  exe="$(_codex_exe)"
  [ -n "$exe" ] || { warn "cannot stop the Codex daemon for $label: codex is not on PATH (set AIQ_CODEX_BIN)"; return 1; }
  CODEX_HOME="$(_np "$home")" "$exe" app-server daemon stop >/dev/null 2>&1
  for i in 1 2 3 4 5 6 7 8 9 10; do
    [ "$(_daemon_up "$home")" = 0 ] && break
    sleep 0.5
  done
  if [ "$(_daemon_up "$home")" = 1 ]; then
    warn "could not stop the Codex daemon for $label"
    return 1
  fi
  printf '%s  stopped the Codex background daemon for %s (it held the old login)%s\n' \
    "$C_DIM" "$label" "$C_RST" >&2
  return 0
}

_lane_quiesce() {
  # _lane_quiesce <codex-home> <label> — nothing of Codex left running from a
  # home that is about to be moved: the daemon, and the auto-updater `daemon
  # stop` leaves behind with files open ("Permission denied" on the move).
  [ "$PROV" = codex ] || return 0
  _daemon_stop "$1" "$2" || return 1
  [ -f "$1/app-server-daemon/daemon-updater.pid" ] || return 0
  [ -n "$(_field "$(_py stop_updater "$(_np "$1")" 2>/dev/null)" error)" ] || return 0
  warn "could not stop the Codex updater for $2"
  return 1
}

_move_dir() {
  # _move_dir <from> <to> — Windows lets go of a stopped process's files a
  # moment after it exits; try again briefly before giving up.
  local i
  for i in 1 2 3 4 5 6; do
    mv "$1" "$2" 2>/dev/null && return 0
    sleep 0.5
  done
  mv "$1" "$2"
}

_store() {
  # _store <profile-dir> [cred] [session] — a login -> profile. Default: the live one.
  local d="$1" cred="${2:-$P_ACTIVE}" sess="${3-$P_SESSION}"
  mkdir -p "$d" || return 1
  cp -f "$cred" "$d/$P_CREDNAME" || return 1
  [ -f "$d/credentials.json" ] && [ "$P_CREDNAME" != "credentials.json" ] && rm -f "$d/credentials.json"
  if [ "$PROV" = claude ] && [ -n "$sess" ] && [ -f "$sess" ]; then
    _py slice "$(_np "$sess")" "$(_np "$d/claude.json")" || return 1
  fi
  _refresh_meta "$d" || return 1
  return 0
}

_refresh_meta() {
  # _refresh_meta <profile-dir> — profile.json (and the older profile.email)
  # describe whatever credential the profile holds now.
  local d="$1"
  if [ "$PROV" = claude ]; then
    if [ -f "$d/claude.json" ]; then
      _py meta claude "$(_np "$(_cred_in "$d")")" "$(_np "$d/claude.json")" "$(_np "$d/profile.json")" >/dev/null || return 1
    else
      _py meta claude "$(_np "$(_cred_in "$d")")" "$(_np "$d/profile.json")" >/dev/null || return 1
    fi
    return 0
  fi
  _py meta codex "$(_np "$d/$P_CREDNAME")" "$(_np "$d/profile.json")" >/dev/null || return 1
  # keep profile.email so the older shell scripts still read correctly
  _py active codex "$(_np "$d/$P_CREDNAME")" 2>/dev/null \
    | awk -F'\t' '$1=="email" && $2!="" {print $2}' > "$d/profile.email"
  [ -s "$d/profile.email" ] || rm -f "$d/profile.email"
  return 0
}

_save_workspace() {
  local workspace="$1" d="$2" src
  src="$(_env_dir "$workspace")"
  [ -d "$src" ] || { warn "no lane '$workspace' - see: aiq $PROV_CLI ls"; return 1; }
  _env_paths "$src"
  [ -f "$EV_CRED" ] || { warn "lane '$workspace' is not signed in"; return 1; }
  if [ "$PROV" = claude ]; then
    [ -f "$EV_SESS" ] || { warn "lane '$workspace' has no Claude session metadata"; return 1; }
  fi
  if _running; then
    warn "a $P_LABEL process is running; close it before saving lane '$workspace'"
    return 1
  fi
  [ -f "$d/$P_CREDNAME" ] && _backup "$(_cred_in "$d")" "presave"
  [ -f "$d/claude.json" ] && _backup "$d/claude.json" "presave"
  _store "$d" "$EV_CRED" "$EV_SESS" || return 1
  _field "$(_py active "$PROV" "$(_np "$EV_CRED")" ${EV_SESS:+"$(_np "$EV_SESS")"} 2>/dev/null)" email
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

_claude_refresh_profile() {
  [ "$PROV" = claude ] || return 1
  local d="$1" force="${2:-}" cred before td rd out msg active_name access_days refresh_days line
  cred="$(_cred_in "$d")"
  [ -f "$cred" ] || { warn "profile '$(basename "$d")' has no credential file"; return 1; }

  before="$(_py active claude "$(_np "$cred")" "$(_np "$d/claude.json")" 2>/dev/null)"
  td="$(_field "$before" token_days)"; rd="$(_field "$before" refresh_days)"
  case "$td" in
    ""|*-*) ;;
    *) [ "$force" = force ] || return 0 ;;
  esac
  case "$rd" in
    ""|*-*)
      warn "Claude profile '$(basename "$d")' has no usable refresh token"
      return 1 ;;
  esac

  active_name="$(_match)"
  _backup "$cred" "prerefresh"
  out="$(_py refresh "$(_np "$cred")" 2>&1)" || {
    msg="$(_field "$out" error)"
    [ -n "$msg" ] || msg="unknown error"
    warn "Claude refresh for '$(basename "$d")' failed: $msg"
    return 1
  }
  if [ -f "$d/claude.json" ]; then
    _py meta claude "$(_np "$cred")" "$(_np "$d/claude.json")"       "$(_np "$d/profile.json")" >/dev/null 2>&1 || true
  else
    _py meta claude "$(_np "$cred")" "$(_np "$d/profile.json")" >/dev/null 2>&1 || true
  fi
  if [ "$active_name" = "$(basename "$d")" ]; then
    cp -f "$cred" "$P_ACTIVE" || return 1
  fi
  access_days="$(_field "$out" access_days)"
  refresh_days="$(_field "$out" refresh_days)"
  line="refreshed Claude access token for '$(basename "$d")'"
  [ -n "$access_days" ] && line="$line (access $access_days""d)"
  [ -n "$refresh_days" ] && line="$line; refresh $refresh_days""d"
  info "$line"
  return 0
}

_match() { _py match "$PROV" "$(_np "$P_ROOT")" "${P_ARGS[@]}" 2>/dev/null | head -n1; }

_resolve() {
  # _resolve <name|alias|email> -> the saved account it means, or "". An email,
  # or its start, works too: `aiq codex use kevin` instead of looking up `a1`.
  local out
  out="$(_py resolve "$(_np "$P_ROOT")" "$1" "$PROV" "$(_np "$P_ENVROOT")" "$(_global_name)" 2>/dev/null | head -n1)"
  case "$out" in
    ambiguous*) warn "'$1' fits several accounts (${out#ambiguous?}) — type more of it, or the name"
                return 0 ;;
  esac
  printf '%s' "$out"
}

# --------------------------------------------------------------- autosync ---
# The core of this tool. A running CLI silently rotates its refresh token and
# rewrites the live auth file. If we overwrite that file without copying it back
# first, the newest refresh token is lost forever and the next restore replays a
# spent one — which providers treat as token theft and answer by de-authorising
# the device. So: write back before every overwrite, always.
# Explicit refresh action; autosync below still protects rotated tokens on switches.

act_refresh() {
  [ "$PROV" = claude ] || die "refresh is only available for Claude Code"
  local key="${1:-}" name d active_name
  [ "$#" -le 1 ] || die "usage: aiq claude refresh [profile|alias]"
  if [ -n "$key" ]; then
    name="$(_resolve "$key")"
    [ -n "$name" ] || die "no profile or alias called '$key' ? see: aiq claude ls"
  else
    name="$(_match)"
    [ -n "$name" ] || die "no active Claude profile ? pass a profile name"
  fi
  d="$P_ROOT/$name"
  [ -f "$(_cred_in "$d")" ] || die "profile '$name' has no credential file"
  active_name="$(_match)"
  if [ "$active_name" = "$name" ] && _running; then
    die "a Claude process is running; close it before refreshing the active profile"
  fi
  info "refreshing Claude profile: $name"
  _claude_refresh_profile "$d" force
}

_sync() {
  [ -f "$P_ACTIVE" ] || return 0
  local match cred
  # Claude leaves an empty OAuth object after logout. Metadata can still name
  # the account, but copying that empty object would destroy its saved token.
  if [ "$PROV" = claude ]; then
    local live_has
    live_has="$(_field "$(_py active claude "${P_ARGS[@]}" 2>/dev/null)" has_cred)"
    [ "$live_has" = 1 ] || return 0
  fi
  match="$(_match)"
  [ -z "$match" ] && return 0
  cred="$(_cred_in "$P_ROOT/$match")"
  if [ -f "$cred" ] && cmp -s "$P_ACTIVE" "$cred" && [ "$PROV" != claude ]; then
    return 0
  fi
  # The profile may have been brought up to date from its lane since; then the
  # live copy is the older one, and writing it back would undo exactly that.
  if [ -f "$cred" ] && [ "$(_py newer "$PROV" "$(_np "$P_ACTIVE")" "$(_np "$P_SESSION")" \
        "$(_np "$cred")" "$(_np "$P_ROOT/$match/claude.json")" 2>/dev/null)" = b ]; then
    return 0
  fi
  _backup "$cred" "presync"
  _store "$P_ROOT/$match" || return 1
  if [ "${1:-}" != quiet ] && ! cmp -s "$P_ACTIVE" "$cred" 2>/dev/null; then
    info "wrote the live token back into '$match' first"
  fi
  return 0
}

# One account, one live login. `run` makes a lane from the saved profile and
# `quota` stages it into a scratch dir; from then on each copy refreshes on its
# own, and only the one refreshed last still holds a refresh token that works.
# Restoring any other replays a spent token, and the provider answers by signing
# the account out everywhere. So before an account is used or read, the newest
# copy is taken into the profile (pull), and when it is about to run in its
# lane, from the profile into the lane (push).
_plan() {
  _py plan "$PROV" "$(_np "$P_ROOT")" "$(_np "$P_ENVROOT")" "$(_np "$AIQ_CACHE/codex")" "$@" 2>/dev/null
}

_reconcile() {
  # _reconcile <name> [push]
  local row pull state
  row="$(_plan "$1" | head -n1)"
  [ -n "$row" ] || return 0
  IFS=$US read -r _ pull state <<< "$row"
  _reconcile_apply "$1" "$pull" "$state" "${2:-}"
}

_reconcile_all() {
  # Pull only. Pushing into a lane could land under a running daemon.
  local name pull state
  while IFS=$US read -r name pull state; do
    [ -n "$name" ] && [ -n "$pull" ] || continue
    _reconcile_apply "$name" "$pull" "$state" || true
  done < <(_plan)
  return 0
}

_reconcile_apply() {
  local name="$1" pull="$2" state="$3" push="${4:-}" d lane src
  d="$P_ROOT/$name"; lane="$(_env_dir "$name")"
  case "$pull" in
    lane)    _env_paths "$lane"; src="$EV_CRED" ;;
    scratch) src="$AIQ_CACHE/codex/$name/auth.json" ;;
    *)       src="" ;;
  esac
  if [ -n "$src" ] && [ -f "$src" ]; then
    _backup "$(_cred_in "$d")" "prepull"
    cp -f "$src" "$d/$P_CREDNAME" || return 1
    [ -f "$d/credentials.json" ] && [ "$P_CREDNAME" != "credentials.json" ] && rm -f "$d/credentials.json"
    _refresh_meta "$d" || true
    printf '%s  %s: saved the newer login from its %s copy%s\n' "$C_DIM" "$name" \
      "$([ "$pull" = lane ] && echo lane || echo quota-cache)" "$C_RST" >&2
  fi
  [ -n "$push" ] || return 0
  _env_paths "$lane"
  case "$state" in
    older|empty)
      if [ "$state" = older ]; then
        # Its daemon has the spent token in memory; a fresh one reads the new file.
        _daemon_stop "$lane" "lane '$name'" || return 1
        _backup "$EV_CRED" "prepush"
      fi
      cp -f "$(_cred_in "$d")" "$EV_CRED" || return 1
      if [ "$PROV" = claude ] && [ ! -f "$EV_SESS" ] && [ -f "$d/claude.json" ]; then
        cp -f "$d/claude.json" "$EV_SESS"
      fi
      [ "$state" = older ] && printf '%s  %s: lane was behind its saved login; brought it up to date%s\n' \
        "$C_DIM" "$name" "$C_RST" >&2 ;;
    other)
      warn "lane '$name' is signed in as a different account than profile '$name'"
      warn "  to put the saved account back in it: aiq $PROV_CLI add $name --force" ;;
  esac
  return 0
}

_global_name() {
  # Saved name of the account the default config dir (~/.claude, ~/.codex) is
  # signed in as — also from inside a lane, where P_ACTIVE is the lane's.
  local cred sess=""
  if [ "$PROV" = claude ]; then cred="$CLAUDE_HOST/.credentials.json"; sess="$CLAUDE_HOST_SESSION"
  else cred="$CODEX_HOST/auth.json"; fi
  [ -f "$cred" ] || return 0
  _py match "$PROV" "$(_np "$P_ROOT")" "$(_np "$cred")" ${sess:+"$(_np "$sess")"} 2>/dev/null | head -n1
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
  case "$p" in *.*) p="$(awk -v v="$p" 'BEGIN{ r=int(v+0.5); if (r==0 && v+0>0) r=1; printf "%d", r }')" ;; esac
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

# `ls` and `quota` differ in where the numbers come from, not in what they mean,
# so they share this one table. `quota` refreshes the snapshot first; `ls` reads
# whatever the last refresh left behind. Anything the refresh could not reach
# carries the reason on its own row.
LIST_AS_OF=""; LIST_BANKS=""; QUOTA_ERR=""; LIST_LANE_WARN=""

_lane_cell() {
  # The account's copy for `run`: none, at rest, or with its codex up.
  case "$1" in
    running)     printf '%s%-7s%s' "$C_GRN" "running" "$C_RST" ;;
    idle)        printf '%-7s' "idle" ;;
    other|empty) printf '%s%-7s%s' "$C_YEL" "$1" "$C_RST" ;;
    *)           printf '%s%-7s%s' "$C_DIM" "-" "$C_RST" ;;
  esac
}

_list_one() {
  # _list_one [--archived]
  local arch="${1:-}" shown=0
  local mark name alias email plan td rd q5 q7 q5r q7r q5w q7w stale hasid subd savedat
  local st qat bank bankexp banktitle note lane mcol
  local -a lanes=()
  LIST_AS_OF=""; LIST_BANKS=""; LIST_LANE_WARN=""
  [ -z "$arch" ] && lanes=(--lanes "$(_np "$P_ENVROOT")")
  if [ "$PROV" = claude ]; then
    printf '%s%-2s %-14s %-10s %-38s %-5s %-8s %-7s %8s %5s %5s %16s %16s%s\n' "$C_DIM" \
      "@" "PROFILE" "ALIAS" "ACCOUNT" "PLAN" "STATUS" "LANE" "REFRESH" "5H" "7D" "5H RESET" "7D RESET" "$C_RST"
  else
    printf '%s%-2s %-14s %-10s %-38s %-5s %-8s %-7s %8s %9s %9s %4s %16s %16s%s\n' "$C_DIM" \
      "@" "PROFILE" "ALIAS" "ACCOUNT" "PLAN" "STATUS" "LANE" "SUB ENDS" "PRIMARY" "SECONDARY" "BANK" \
      "PRIMARY RESETS" "SECONDARY RESETS" "$C_RST"
  fi
  while IFS=$US read -r mark name alias email plan td rd q5 q7 q5r q7r q5w q7w stale hasid \
                        subd savedat st qat bank bankexp banktitle note lane; do
    [ -z "$name" ] && continue
    shown=1
    [ -n "$qat" ] && LIST_AS_OF="$qat"
    # Three wide, to line up under the "@ " header plus its separating space.
    case "$mark" in
      '*') mcol="${C_GRN}*  ${C_RST}" ;;
      '=') mcol="${C_DIM}=  ${C_RST}" ;;
      '~') mcol="${C_YEL}~  ${C_RST}" ;;
      *)   mcol="   " ;;
    esac
    printf '%s' "$mcol"
    printf '%-14.14s %-10.10s %-38.38s %-5.5s ' "$name" "$alias" "$email" "$plan"
    _health_cell "$st"; printf ' '
    _lane_cell "$lane"; printf ' '
    # Only a lane that needs something gets a line under the table.
    case "$lane" in
      other) LIST_LANE_WARN="$LIST_LANE_WARN  lane $name is signed in as another account — aiq $PROV_CLI add $name --force
" ;;
      running) [ "$mark" = '*' ] && LIST_LANE_WARN="$LIST_LANE_WARN  lane $name runs your global account a second time — aiq $PROV_CLI rm $name --lane
" ;;
    esac
    if [ "$PROV" = claude ]; then
      # The refresh token is the real lifetime. The access token above it is
      # short-lived by design and the CLI renews it on every run.
      _days_cell "$rd" 7; printf ' '
      _pct_cell "$q5"; printf ' '; _pct_cell "$q7"; printf ' '; _reset_cell "$q5r"; printf ' '; _reset_cell "$q7r"
    else
      _days_cell "$subd" 3; printf ' '
      # Codex names its windows by length, not by role, so the cell carries the
      # label: "5h 12%" on plus, "30d 100%" on free.
      _win_cell "$q5" "$q5w"; printf ' '; _win_cell "$q7" "$q7w"; printf ' '
      _bank_cell "$bank" "$q5" "$q7"; printf ' '
      _reset_cell "$q5r"; printf ' '; _reset_cell "$q7r"
      case "${bank:-0}" in
        ""|0) ;;
        *) LIST_BANKS="$LIST_BANKS$name$US$bank$US$bankexp$US$banktitle
" ;;
      esac
    fi
    [ -n "$note" ] && printf '  %s%s%s' "$C_DIM" "$note" "$C_RST"
    [ -z "$hasid" ] && printf '  %sno identity — run: aiq %s save %s%s' "$C_DIM" "$PROV_CLI" "$name" "$C_RST"
    _quota_err_note "$name"
    printf '\n'
  done < <(_py list "$PROV" "$(_np "$P_ROOT")" "${P_ARGS[@]}" $arch ${lanes[@]+"${lanes[@]}"} 2>/dev/null)
  if [ "$shown" = 0 ]; then
    if [ -n "$arch" ]; then info "  nothing archived"
    else info "  no accounts yet — add one: aiq $PROV_CLI add <name>"; fi
  fi
  return 0
}

_quota_err_note() {
  # Why one row could not be refreshed, printed on that row rather than in a
  # heap at the bottom where it would no longer say which account it belongs to.
  local msg
  [ -n "$QUOTA_ERR" ] || return 0
  msg="$(printf '%s' "$QUOTA_ERR" | awk -F"$US" -v k="$1" '$1==k{print $2; exit}')"
  [ -n "$msg" ] && printf '  %s%s%s' "$C_DIM" "$msg" "$C_RST"
  return 0
}

_bank_notes() {
  # What each banked reset actually is, and the date it lapses. Kept off the
  # table because the count is what you compare; this is what you act on.
  [ -n "$LIST_BANKS" ] || return 0
  local name n exp title line
  while IFS=$US read -r name n exp title; do
    [ -n "$name" ] || continue
    line="$n reset"; [ "$n" = 1 ] || line="${line}s"
    [ -n "$title" ] && line="$line — $title"
    # A month out: the date is the deadline, the clock time is noise.
    [ -n "$exp" ] && line="$line, expires ${exp%% *}"
    printf '  %sbank  %-14.14s %s%s\n' "$C_DIM" "$name" "$line" "$C_RST"
  done <<EOF
$LIST_BANKS
EOF
  return 0
}

_lane_notes() {
  # Lanes are the LANE column of the table above. Below it, only what needs
  # doing: a lane in a bad state, or one the table has no row for.
  local d name email cur
  [ -n "$LIST_LANE_WARN" ] && printf '%s%s%s' "$C_YEL" "$LIST_LANE_WARN" "$C_RST"
  for d in "$P_ENVROOT"/*/; do
    [ -d "$d" ] || continue
    name="$(basename "${d%/}")"
    [ -d "$P_ROOT/$name" ] && continue
    _env_paths "${d%/}"
    [ -f "$EV_CRED" ] || continue
    email="$(_field "$(_py active "$PROV" "$(_np "$EV_CRED")" ${EV_SESS:+"$(_np "$EV_SESS")"} 2>/dev/null)" email)"
    printf '  %slane %s holds %s, which is not a saved account — aiq %s save %s --workspace %s%s\n' \
      "$C_YEL" "$name" "${email:-a login}" "$PROV_CLI" "$name" "$name" "$C_RST"
  done
  cur="$(_env_current_name)"
  [ -n "$cur" ] && info "  this shell runs in lane $cur"
  return 0
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

_bank_cell() {
  # Banked resets: one-off grants that clear a spent window early. Worth
  # highlighting only once a window is actually spent — that is when you would
  # spend one. Dim otherwise, so it reads as inventory and not as an alarm.
  local n="$1" p5="$2" p7="$3"
  case "${n:-0}" in ""|0) printf '%4s' "-"; return ;; esac
  if awk -v a="${p5:-0}" -v b="${p7:-0}" 'BEGIN{exit !(a+0 >= 80 || b+0 >= 80)}'; then
    printf '%s%4s%s' "$C_GRN" "$n" "$C_RST"
  else
    printf '%s%4s%s' "$C_DIM" "$n" "$C_RST"
  fi
}

_field() { printf '%s' "$1" | awk -F'\t' -v k="$2" '$1==k{print $2}'; }

_list_dupes() {
  # One account under several names means several copies of one login, which
  # refresh apart until one of them is replayed. Name the one to keep: the one
  # in use, else the newest, else the one whose lane is running.
  local names rest
  while IFS= read -r names; do
    [ -n "$names" ] || continue
    rest="${names#* }"
    printf '  %ssame account saved as %s — keep %s: aiq %s rm %s%s\n' \
      "$C_YEL" "${names// / = }" "${names%% *}" "$PROV_CLI" "$rest" "$C_RST"
  done < <(_py dupes "$PROV" "$(_np "$P_ROOT")" "$(_np "$P_ENVROOT")" "$(_global_name)" 2>/dev/null)
  return 0
}

# ---------------------------------------------------------------- actions ---
act_sessions() {
  [ "$PROV" = claude ] || die "session listing is only available for Claude Code"
  local project="$PWD" limit=30
  while [ $# -gt 0 ]; do
    case "$1" in
      --project|-p) [ $# -ge 2 ] || die "usage: aiq claude sessions [--project <dir>] [--limit <n>]"; project="$2"; shift 2 ;;
      --limit|-n) [ $# -ge 2 ] || die "usage: aiq claude sessions [--project <dir>] [--limit <n>]"; limit="$2"; shift 2 ;;
      --) shift; break ;;
      -*) die "aiq claude sessions: unknown option '$1'" ;;
      *) project="$1"; shift ;;
    esac
  done
  printf '%sClaude sessions%s  %s%s%s\n' "$C_B" "$C_RST" "$C_DIM" "$project" "$C_RST"
  printf '%-2s %-38s %-28s %-12s %-16s %-11s %-12s %s\n' \
    "@" "SESSION" "OWNER" "PROFILE" "UPDATED" "STATE" "BRANCH" "LAST REQUEST"
  local active_id; active_id="$(_field "$(_py active claude "${P_ARGS[@]}" 2>/dev/null)" id)"
  local sid owner email profile updated state branch request path mark owner_cell
  while IFS=$US read -r sid owner email profile updated state branch request path; do
    [ -n "$sid" ] || continue
    mark=" "; [ -n "$active_id" ] && [ "$owner" = "$active_id" ] && mark="*"
    owner_cell="${email:-${owner:+uuid:${owner:0:8}}}"
    [ -n "$owner_cell" ] || owner_cell="unknown"
    printf '%s  %-38.38s %-28.28s %-12.12s %-16.16s %-11.11s %-12.12s %s\n' \
      "$mark" "$sid" "$owner_cell" "${profile:--}" "${updated:--}" "${state:--}" \
      "${branch:--}" "${request:-(no human request found)}"
  done < <(_py sessions "$(_np "$P_HOST/projects")" "$(_np "$project")" "$(_np "$P_ROOT")" "$limit")
  info "  * = session owner matches the account in this shell"
  info "  handoff: aiq claude handoff <session-id>"
}

act_handoff() {
  [ "$PROV" = claude ] || die "handoff is only available for Claude Code"
  local selector="latest" project="$PWD" output=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --project|-p) [ $# -ge 2 ] || die "usage: aiq claude handoff [<session>] [--project <dir>] [--out <file>]"; project="$2"; shift 2 ;;
      --out|-o) [ $# -ge 2 ] || die "usage: aiq claude handoff [<session>] [--project <dir>] [--out <file>]"; output="$2"; shift 2 ;;
      --) shift; break ;;
      -*) die "aiq claude handoff: unknown option '$1'" ;;
      *) selector="$1"; shift ;;
    esac
  done
  [ -n "$output" ] || output="$AIQ_DIR/handoffs/${selector}.md"
  mkdir -p "$(dirname "$output")" || die "could not create handoff directory"
  local out; out="$(_py handoff "$(_np "$P_HOST/projects")" "$(_np "$project")" "$(_np "$P_ROOT")" "$selector" "$(_np "$output")" 2>/dev/null)"
  local err; err="$(_field "$out" error)"
  [ -z "$err" ] || die "$err"
  info "handoff written: $output"
  info "start a new Claude session under the target account and tell it to read this file, inspect the worktree, and continue the unfinished work"
}

act_ls() {
  case "${1:-}" in --live|--refresh) act_quota; return $? ;; esac
  _sync quiet
  _reconcile_all
  printf '%s%s%s\n' "$C_B" "$P_LABEL" "$C_RST"
  case "${1:-}" in
    --archived|--deleted|--removed)
                _list_one --archived
                info "  bring one back: aiq $PROV_CLI restore <name>"; return 0 ;;
    --all)      _list_one
                printf '%s  removed%s\n' "$C_DIM" "$C_RST"
                _list_one --archived; return 0 ;;
  esac
  _list_one
  _bank_notes
  info "  * = in use in every terminal (aiq $PROV_CLI use <name>)  ·  LANE = its copy for running side by side (aiq $PROV_CLI run <name>)"
  # Same columns as `quota`, older numbers. Naming the moment they were taken
  # beats "run it again" — it says whether running it again would change much.
  local asof=""
  [ -n "$LIST_AS_OF" ] && asof=" (taken $LIST_AS_OF)"
  if [ "$PROV" = claude ]; then
    info "  5H/7D: cached$asof — live for every saved account: aiq claude quota"
  else
    info "  PRIMARY/SECONDARY/BANK: cached$asof — live: aiq codex quota"
  fi
  _list_dupes
  _lane_notes
  local nd; nd="$(_py dead "$PROV" "$(_np "$P_ROOT")" 2>/dev/null | wc -l | tr -d ' ')"
  [ "${nd:-0}" -gt 0 ] && info "  $nd account(s) can no longer sign in — review with: aiq $PROV_CLI prune"
  return 0
}


act_restore() {
  local key="${1:-}" did=0
  [ -z "$key" ] && die "usage: aiq $PROV_CLI restore <name>   ·   see: aiq $PROV_CLI ls --deleted"
  if [ -d "$P_ROOT/.archive/$key" ]; then
    [ -e "$P_ROOT/$key" ] && die "an account called '$key' already exists"
    mv "$P_ROOT/.archive/$key" "$P_ROOT/$key" || die "could not restore '$key'"
    did=1
  fi
  if [ -d "$P_ENVROOT/.archive/$key" ]; then
    if [ -e "$(_env_dir "$key")" ]; then
      warn "lane '$key' already exists; left the removed one in $P_ENVROOT/.archive"
    else
      mv "$P_ENVROOT/.archive/$key" "$(_env_dir "$key")" && did=1
    fi
  fi
  [ "$did" = 1 ] || die "nothing removed under '$key' — see: aiq $PROV_CLI ls --deleted"
  printf 'restored %s%s%s\n' "$C_B" "$key" "$C_RST"
}

act_rename() {
  local from="${1:-}" to="${2:-}" profile_name existing_profile workspace_name=""
  local profile_src profile_dst workspace_src workspace_dst has_profile=0 has_workspace=0
  [ -n "$from" ] && [ -n "$to" ] || die "usage: aiq $PROV_CLI rename <old> <new>"
  [ "$from" != "$to" ] || die "old and new account names are identical"
  _check_name "$to"
  profile_name="$(_resolve "$from")"
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
  [ "$has_profile" = 1 ] || [ "$has_workspace" = 1 ] || die "no account called '$from'"
  existing_profile="$(_py resolve "$(_np "$P_ROOT")" "$to" 2>/dev/null | head -n1)"
  [ -z "$existing_profile" ] || [ "$existing_profile" = "$profile_name" ] || die "account or alias '$to' already exists"
  [ "$has_profile" = 0 ] || [ ! -e "$profile_dst" ] || die "account '$to' already exists"
  [ "$has_workspace" = 0 ] || [ ! -e "$workspace_dst" ] || die "lane '$to' already exists"
  [ "$has_workspace" = 0 ] || { [ "$(_env_current_name)" != "$workspace_name" ] || die "lane '$workspace_name' is active in this shell"; }
  [ "$has_workspace" = 0 ] || { _running && die "a $P_LABEL process is running; close it before renaming an account"; }
  # The quota scratch dir and the lane are found by name; settle which copy is
  # newest while the names still match.
  [ "$has_profile" = 1 ] && _reconcile "$profile_name"
  if [ "$has_workspace" = 1 ]; then
    _lane_quiesce "$workspace_src" "lane '$workspace_name'" || die "could not rename '$from'"
  fi
  if [ "$has_profile" = 1 ]; then
    mv "$profile_src" "$profile_dst" || die "could not rename account '$profile_name'"
  fi
  if [ "$has_workspace" = 1 ]; then
    if ! _move_dir "$workspace_src" "$workspace_dst"; then
      [ "$has_profile" = 0 ] || mv "$profile_dst" "$profile_src"
      die "could not rename lane '$workspace_name'"
    fi
  fi
  [ "$PROV" = codex ] && [ -n "$profile_name" ] && rm -rf "${AIQ_CACHE:?}/codex/${profile_name:?}"
  printf 'account %s%s%s renamed to %s%s%s\n' "$C_B" "$from" "$C_RST" "$C_B" "$to" "$C_RST"
}
# prune only ever archives, like rm: nothing aiq does deletes a login.
act_prune() {
  local yes="" line name email count=0
  local -a dead=()
  case "${1:-}" in -y|--yes) yes=1 ;; esac
  while IFS= read -r line; do [ -n "$line" ] && dead+=("$line"); done \
    < <(_py dead "$PROV" "$(_np "$P_ROOT")" 2>/dev/null)
  for line in ${dead[@]+"${dead[@]}"}; do
    name="${line%%$'\t'*}"; email="${line#*$'\t'}"
    count=$((count + 1))
    if [ -n "$yes" ]; then
      _rm_account "$name" "" brief || true
    else
      printf '  %-12s %s\n' "$name" "$email"
    fi
  done

  if [ "$count" = 0 ]; then
    info "nothing to prune — every $P_LABEL account can still sign in"
  elif [ -n "$yes" ]; then
    info "  only the logins went; undo any of them: aiq $PROV_CLI restore <name>"
  elif [ -z "$yes" ]; then
    printf '\n'
    info "$count account(s) above can no longer sign in."
    info "Remove them with:  aiq $PROV_CLI prune --yes    (archived; undo with: aiq $PROV_CLI restore <name>)"
  fi
}

act_save() {
  local name="" alias="" workspace="" d email arg dup out
  while [ "$#" -gt 0 ]; do
    arg="$1"
    case "$arg" in
      --workspace|-w|--lane)
        [ "$#" -ge 2 ] || die "usage: aiq $PROV_CLI save <name> [alias] [--workspace <lane>]"
        workspace="$2"; shift 2 ;;
      --*) die "unknown save option '$arg'" ;;
      *)
        if [ -z "$name" ]; then name="$arg"
        elif [ -z "$alias" ]; then alias="$arg"
        else die "usage: aiq $PROV_CLI save <name> [alias] [--workspace <lane>]"; fi
        shift ;;
    esac
  done
  if [ -z "$name" ] && [ -n "$workspace" ]; then
    die "usage: aiq $PROV_CLI save <name> [alias] --workspace <lane>"
  fi
  [ -f "$P_ACTIVE" ] || [ -n "$workspace" ] || die "not signed in — $P_ACTIVE does not exist"
  if [ -z "$name" ]; then
    name="$(_match)"
    [ -z "$name" ] && die "usage: aiq $PROV_CLI save <name> [alias]"
    info "updating the account that already holds this login: $name"
  fi
  [ -n "$name" ] && _check_name "$name"
  d="$P_ROOT/$name"
  if [ -n "$workspace" ]; then
    email="$(_save_workspace "$workspace" "$d")" || die "could not import lane '$workspace'"
    [ -n "$alias" ] && printf '%s\n' "$alias" > "$d/profile.alias"
    printf '%ssaved%s %s%s%s%s%s\n' "$C_GRN" "$C_RST" "$C_B" "$name" "$C_RST" \
      "${email:+  $email}" "  from lane $workspace"
    return 0
  fi
  local resolved; resolved="$(_py resolve "$(_np "$P_ROOT")" "$name" 2>/dev/null | head -n1)"
  [ -n "$resolved" ] && { name="$resolved"; d="$P_ROOT/$name"; }
  # One account, one name: a second name would be a second copy of the login.
  dup="$(_match)"
  if [ -n "$dup" ] && [ "$dup" != "$name" ]; then
    info "this account is already saved as '$dup' — updated that instead of saving it twice"
    info "  to call it '$name' instead: aiq $PROV_CLI rename $dup $name"
    name="$dup"; d="$P_ROOT/$name"
  elif [ -d "$d" ]; then
    out="$(_py cmp "$PROV" "$(_np "$d")" "${P_ARGS[@]}" 2>/dev/null)"
    if [ "$(_field "$out" same)" = 0 ] && [ -n "$(_field "$(_py active "$PROV" "$(_np "$(_cred_in "$d")")" "$(_np "$d/claude.json")" 2>/dev/null)" id)" ]; then
      warn "'$name' held another account; replaced it (the old login is in $AIQ_BACKUPS/$PROV)"
    fi
  fi
  [ -d "$d" ] && _backup "$(_cred_in "$d")" "presave"
  _store "$d" || die "could not save account '$name'"
  [ -n "$alias" ] && printf '%s\n' "$alias" > "$d/profile.alias"
  email="$(_field "$(_py active "$PROV" "${P_ARGS[@]}" 2>/dev/null)" email)"
  printf '%ssaved%s %s%s%s%s\n' "$C_GRN" "$C_RST" "$C_B" "$name" "$C_RST" "${email:+  $email}"
}

_switch_blocked() {
  # Would changing the global login pull it out from under an open session?
  _running || return 1
  # Codex sessions are clients of their home's daemon. With the global daemon
  # down, an open session belongs to a lane and is not using the global login.
  if [ "$PROV" = codex ] && [ -d "$CODEX_HOME/app-server-daemon" ] && \
     [ "$(_daemon_up "$CODEX_HOME")" = 0 ]; then
    return 1
  fi
  return 0
}

act_use() {
  # Claude resume is owner-aware; a foreign session is handed off to a fresh session.
  local key="${1:-}" name d out email plan td rd same newer resume="" want="" lane_dir
  [ -z "$key" ] && die "usage: aiq $PROV_CLI use <name|alias> [-c|--resume]"
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
      -f|--force)    AIQ_FORCE=1 ;;   # the same as AIQ_FORCE=1, which PowerShell cannot prefix
      --)            shift; break ;;
      -*)            die "aiq $PROV_CLI use: unknown option '$1'" ;;
      *)             die "aiq $PROV_CLI use: unexpected argument '$1' (name goes first)" ;;
    esac
    shift
  done

  # `use` is GLOBAL scope: it rewrites the one shared config every terminal
  # reads. Inside an aiq lane shell this CLI's config dir is the lane's own, so
  # `use` there would quietly switch the lane instead — refuse, and point at
  # the commands that do fit.
  [ "$want" = lane ] && die "\`use\` only does global switches — there is no --lane mode. For a lane:  aiq $PROV_CLI run $key"
  local lane; lane="$(_env_current_name)"
  if [ -n "$lane" ]; then
    die "this shell is inside lane \"$lane\"; \`use\` (global switch) does not apply here. Open a normal terminal for a global switch, or run another account here with:  aiq $PROV_CLI run <name>"
  fi

  name="$(_resolve "$key")"
  [ -z "$name" ] && die "no account matches '$key' — see: aiq $PROV_CLI ls"
  d="$P_ROOT/$name"
  lane_dir="$(_env_dir "$name")"
  info "scope: GLOBAL — $name is now the $P_LABEL account for every terminal"

  if _switch_blocked; then
    warn "a $P_LABEL session is open. It holds the account it started with and would"
    warn "put that account back, undoing this switch. Close it first."
    [ "$PROV" = codex ] && warn "If every open codex runs in a lane:  aiq codex use $name --force"
    [ "$PROV" = claude ] && warn "Or add --force if you really mean to."
    [ "${AIQ_FORCE:-}" = 1 ] || exit 1
  fi

  if [ "$PROV" = codex ]; then
    # The global daemon would keep the old login in memory and write it back.
    _daemon_stop "$CODEX_HOME" "your global codex" || [ "${AIQ_FORCE:-}" = 1 ] || \
      die "not switching: the old login would come back the next time that daemon refreshed it"
    # The account leaves its lane: one login must not be live in two places.
    if [ "$(_daemon_up "$lane_dir")" = 1 ]; then
      _running && [ "${AIQ_FORCE:-}" != 1 ] && \
        die "'$name' may be open in its lane in another terminal — close it there first"
      _daemon_stop "$lane_dir" "lane '$name'" || die "not switching: '$name' would be live in two places"
    fi
  fi
  _reconcile "$name"

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
  [ "$PROV" = claude ] && _claude_refresh_profile "$d" || true
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
          *)     info "access token expired; run 'aiq claude refresh $name' (refresh good for ${rd}d)" ;;
        esac
      else
        info "access token expired; codex refreshes it on first use"
      fi ;;
  esac
  if [ "$PROV" = codex ] && _ide_running; then
    warn "an editor's Codex extension is running and still holds the previous account."
    warn "Reload that window (VS Code: Developer: Reload Window), or it may put it back."
  fi

  if [ -n "$resume" ]; then _use_resume "$resume" "$@"; fi
}

_claude_resume_owner() {
  local row sid owner email profile updated state branch request path target_id handoff out
  row="$(_py sessions "$(_np "$P_HOST/projects")" "$(_np "$PWD")" "$(_np "$P_ROOT")" 1 2>/dev/null)"
  [ -n "$row" ] || return 0
  IFS=$US read -r sid owner email profile updated state branch request path <<< "$row"
  [ -n "$sid" ] || return 0
  target_id="$(_field "$(_py active claude "${P_ARGS[@]}" 2>/dev/null)" id)"
  [ -z "$owner" ] || [ -z "$target_id" ] || [ "$owner" = "$target_id" ] && return 0
  handoff="$AIQ_DIR/handoffs/${sid}.md"
  mkdir -p "$(dirname "$handoff")" || true
  out="$(_py handoff "$(_np "$P_HOST/projects")" "$(_np "$PWD")" "$(_np "$P_ROOT")" "$sid" "$(_np "$handoff")" 2>/dev/null)"
  if [ -n "$(_field "$out" error)" ]; then
    warn "cannot create handoff for foreign Claude session '$sid'"
    return 1
  fi
  warn "Claude session '$sid' belongs to ${email:-another account}; it cannot be resumed with this account"
  info "created handoff: $handoff"
  if command -v "$P_CLI" >/dev/null 2>&1; then
    info "starting a fresh Claude session and asking it to extract the unfinished work"
    exec "$P_CLI" "Read the handoff file at '$handoff', inspect the current worktree, verify the unfinished task, and continue it. Do not resume the source session."
  fi
  warn "$P_CLI is not on PATH; start a new session and read '$handoff'"
  return 1
}

_use_resume() {
  # Hand straight over to the CLI to continue the current session, now billed to
  # the account we just switched to. Reached only when no CLI was running (the
  # switch would have refused otherwise), so there is nothing to clobber.
  local mode="$1"; shift
  if [ "$PROV" = claude ]; then
    _claude_resume_owner || return 0
  fi
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
  local lane name; lane="$(_env_current_name)"
  [ -n "$lane" ] && printf '  %-13s %s\n' "lane" "$lane"
  name="$(_match)"
  printf '  %-13s %s\n' "account" "${name:-<unsaved — run: aiq $PROV_CLI save <name>>}"
  _py active "$PROV" "${P_ARGS[@]}" 2>/dev/null \
    | awk -F'\t' '$2!="" && $1!~/^(has_cred|token_ms|refresh_due)$/ {printf "  %-13s %s\n",$1,$2}'
}

act_keep() {
  # aiq <cli> keep <name|email>... [--yes] — say which accounts you use; every
  # other one is removed the way `rm` removes it (archived, restorable), and so
  # is any second name of a kept account. Without --yes it only shows the plan.
  local yes="" verb name email note out rc=0 n=0
  local -a keys=() drops=() running=()
  while [ $# -gt 0 ]; do
    case "$1" in
      -y|--yes)   yes=1 ;;
      -f|--force) AIQ_FORCE=1 ;;
      -*)         die "aiq $PROV_CLI keep: unknown option '$1'" ;;
      *)        keys+=("$1") ;;
    esac
    shift
  done
  [ "${#keys[@]}" -gt 0 ] || die "usage: aiq $PROV_CLI keep <name|email>... [--yes]"
  _sync quiet
  _reconcile_all
  out="$(_py keep "$PROV" "$(_np "$P_ROOT")" "$(_np "$P_ENVROOT")" "$(_global_name)" "${keys[@]}" 2>/dev/null)"
  if printf '%s\n' "$out" | grep -q "^error$US"; then
    printf '%s\n' "$out" | while IFS=$US read -r verb name note; do
      [ "$verb" = error ] && warn "'$name': $note"
    done
    die "nothing changed — see: aiq $PROV_CLI ls"
  fi
  printf '%s%s%s\n' "$C_B" "$P_LABEL" "$C_RST"
  while IFS=$US read -r verb name email note; do
    case "$verb" in
      keep) printf '  %skeep  %s  %-14.14s %-38.38s %s%s%s\n' "$C_GRN" "$C_RST" "$name" "$email" "$C_DIM" "$note" "$C_RST" ;;
      drop) printf '  %sremove%s  %-14.14s %-38.38s %s%s%s\n' "$C_YEL" "$C_RST" "$name" "$email" "$C_DIM" "$note" "$C_RST"
            case "$note" in "in use now"*) ;; *) drops+=("$name") ;; esac
            case "$note" in *"lane is running"*) running+=("$name") ;; esac ;;
    esac
  done <<EOF
$out
EOF
  if [ "${#drops[@]}" = 0 ]; then
    info "nothing to remove"; return 0
  fi
  if [ -z "$yes" ]; then
    printf '\n'
    info "Remove them:  aiq $PROV_CLI keep ${keys[*]} --yes"
    info "  only the logins go, archived (undo: aiq $PROV_CLI restore <name>); conversations and settings stay"
    return 0
  fi
  # A running lane's daemon is stopped on the way out, which would cut off a
  # session still using it. Check once, up front, not halfway through.
  if [ "${#running[@]}" -gt 0 ] && _running && [ "${AIQ_FORCE:-}" != 1 ]; then
    warn "lanes still running: ${running[*]}, and a $P_LABEL window is open."
    warn "Close the windows using those accounts, or if none of them do:"
    die  "aiq $PROV_CLI keep ${keys[*]} --yes --force"
  fi
  printf '\n'
  for name in "${drops[@]}"; do
    _rm_account "$name" "" brief && n=$((n + 1)) || rc=1
  done
  info "removed $n login(s); conversations, skills and settings are untouched"
  info "  undo any of them: aiq $PROV_CLI restore <name>   ·   see them: aiq $PROV_CLI ls --deleted"
  return "$rc"
}

act_rm() {
  local only="" key rc=0
  local -a keys=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --lane) only=lane ;;
      -y|--yes)   ;;            # nothing to confirm: rm archives, it never deletes
      -f|--force) AIQ_FORCE=1 ;;
      -*) die "aiq $PROV_CLI rm: unknown option '$1'" ;;
      *)  keys+=("$1") ;;
    esac
    shift
  done
  [ "${#keys[@]}" -gt 0 ] || die "usage: aiq $PROV_CLI rm <name>... [--lane]"
  for key in "${keys[@]}"; do
    _rm_account "$key" "$only" || rc=1
  done
  return "$rc"
}

_rm_account() {
  # _rm_account <name> [lane] — take an account's login out of use, and nothing
  # else. Conversations, skills and settings are yours and stay where they are;
  # what the lane recorded on its own is merged into them first. The login is
  # archived, not deleted: `restore` brings it back.
  local key="$1" only="${2:-}" name has_profile=0 has_lane=0 lane email dest=""
  name="$(_resolve "$key")"
  if [ -n "$name" ]; then has_profile=1; else name="$key"; fi
  lane="$(_env_dir "$name")"
  [ -d "$lane" ] && has_lane=1
  if [ "$has_profile" = 0 ] && [ "$has_lane" = 0 ]; then
    warn "no account called '$key' — see: aiq $PROV_CLI ls"; return 1
  fi
  if [ "$only" = lane ] && [ "$has_lane" = 0 ]; then
    warn "'$name' has no lane"; return 1
  fi
  if [ "$only" != lane ] && [ "$has_profile" = 1 ] && [ "$name" = "$(_global_name)" ]; then
    warn "'$name' is the account every terminal uses now — switch away first: aiq $PROV_CLI use <other>"
    return 1
  fi
  [ "$has_profile" = 1 ] && email="$(_field "$(_py active "$PROV" \
    "$(_np "$(_cred_in "$P_ROOT/$name")")" "$(_np "$P_ROOT/$name/claude.json")" 2>/dev/null)" email)"

  if [ "$has_lane" = 1 ]; then
    if [ "$(_env_current_name)" = "$name" ]; then
      warn "this shell is inside lane '$name' — run this from another terminal"; return 1
    fi
    if [ "$PROV" = codex ] && [ "$(_daemon_up "$lane")" = 1 ]; then
      if _running && [ "${AIQ_FORCE:-}" != 1 ]; then
        warn "a codex session may be running as '$name'. Close it, or add --force."
        return 1
      fi
      _daemon_stop "$lane" "lane '$name'" || return 1
    elif [ "$PROV" = claude ] && _running && [ "${AIQ_FORCE:-}" != 1 ]; then
      warn "a Claude session is running; if it is in lane '$name', removing the lane would"
      warn "break it. Close it, or add --force."
      return 1
    fi
  fi
  # Whatever is kept must be the newest copy of the login.
  [ "$has_profile" = 1 ] && _reconcile "$name"
  if [ "$has_lane" = 1 ]; then
    _lane_retire "$lane" "$name" || return 1
  fi
  if [ "$only" = lane ]; then
    printf 'removed lane %s%s%s' "$C_B" "$name" "$C_RST"
    if [ "$has_profile" = 1 ]; then
      printf ' — the account is still saved; `aiq %s run %s` makes a fresh lane\n' "$PROV_CLI" "$name"
    else
      printf '\n'
      info "  it was not saved as an account; undo: aiq $PROV_CLI restore $name"
    fi
    return 0
  fi
  if [ "$has_profile" = 1 ]; then
    dest="$(_archive_slot "$P_ROOT/.archive" "$name")" || return 1
    mv "$P_ROOT/$name" "$dest" || { warn "could not remove account '$name'"; return 1; }
    [ "$PROV" = codex ] && rm -rf "${AIQ_CACHE:?}/codex/${name:?}"
  fi
  printf 'removed %s%s%s%s\n' "$C_B" "$name" "$C_RST" "${email:+  $email}"
  [ "${3:-}" = brief ] && return 0
  info "  only the login: conversations, skills and settings are untouched"
  info "  undo: aiq $PROV_CLI restore $(basename "${dest:-$name}")"
  return 0
}

_quota_refresh() {
  # Fetch live numbers for every saved profile into the same usage.json that
  # `ls` reads. Fetching and rendering are separate on purpose: one table then
  # serves both commands, and a profile that could not be reached keeps its last
  # snapshot with the reason printed beside it.
  QUOTA_ERR=""
  local rows n mark name rest out err global=""
  rows="$(_py list "$PROV" "$(_np "$P_ROOT")" "${P_ARGS[@]}" 2>/dev/null)"
  n="$(printf '%s' "$rows" | grep -c . 2>/dev/null)"
  [ "${n:-0}" -gt 0 ] || return 0
  [ "$PROV" = codex ] && global="$(_global_name)"
  printf '%s  fetching live numbers for %s account(s)…%s\n' "$C_DIM" "$n" "$C_RST" >&2
  while IFS=$US read -r mark name rest; do
    [ -n "$name" ] || continue
    if [ "$PROV" = claude ]; then
      # An expired access token cannot read usage, and asking anyway just burns
      # requests until the API rate-limits us.
      case "$(printf '%s' "$rest" | cut -d"$US" -f4)" in
        ""|-*) QUOTA_ERR="$QUOTA_ERR$name${US}access token expired — aiq claude refresh $name
"; continue ;;
      esac
      out="$(_py usage "$(_np "$(_cred_in "$P_ROOT/$name")")" \
             "$(_np "$P_ROOT/$name/usage.json")" 2>/dev/null)"
    else
      # codex app-server refreshes a login that is due before it answers. For a
      # login that is also live elsewhere that would leave the live copy with a
      # spent refresh token, so it is not read until its owner has refreshed it.
      if { [ "$name" = "$global" ] || [ "$(_daemon_up "$(_env_dir "$name")")" = 1 ]; } && \
         [ "$(_field "$(_py active codex "$(_np "$(_cred_in "$P_ROOT/$name")")" 2>/dev/null)" refresh_due)" = 1 ]; then
        QUOTA_ERR="$QUOTA_ERR$name${US}not read: in use, and its login is due for a refresh that codex will do
"; continue
      fi
      out="$(_py codex_usage "$(_np "$AIQ_CACHE/codex/$name")" \
             "$(_np "$(_cred_in "$P_ROOT/$name")")" \
             "$(_np "$P_ROOT/$name/usage.json")" 2>/dev/null)"
      # That read may have refreshed the login inside the scratch dir.
      _reconcile "$name"
    fi
    err="$(_field "$out" error)"
    [ -n "$err" ] && QUOTA_ERR="$QUOTA_ERR$name${US}$err
"
  done <<EOF
$rows
EOF
  return 0
}

act_quota() {
  _sync quiet
  _reconcile_all
  printf '%s%s%s\n' "$C_B" "$P_LABEL" "$C_RST"
  # The signed-in account may not be saved anywhere yet, in which case it has no
  # row below. Say so before the table rather than leaving a silent gap.
  if [ -f "$P_ACTIVE" ] && [ -z "$(_match)" ]; then
    warn "signed in as $(_field "$(_py active "$PROV" "${P_ARGS[@]}" 2>/dev/null)" email) is not saved — aiq $PROV_CLI save <name>"
  fi
  if [ "${AIQ_OFFLINE:-}" = 1 ]; then QUOTA_ERR=""; else _quota_refresh; fi
  _list_one
  _bank_notes
  if [ "${AIQ_OFFLINE:-}" = 1 ]; then
    info "  offline: last saved snapshot only. Unset AIQ_OFFLINE for live numbers."
  elif [ "$PROV" = claude ]; then
    info "  live from Anthropic's OAuth usage endpoint — the same source as /usage in Claude Code."
  else
    info "  live from each account's own codex app-server — the same numbers as /status."
  fi
  _list_dupes
  _lane_notes
  return 0
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

_link_dir() {
  # _link_dir <target> <link> — one directory serving two paths. On Windows a
  # junction, which needs no admin rights and no developer mode; a symlink
  # everywhere else.
  local target="$1" link="$2"
  case "$(uname -s 2>/dev/null)" in
    MINGW*|MSYS*|CYGWIN*)
      MSYS_NO_PATHCONV=1 cmd /c mklink /J "$(_np "$link")" "$(_np "$target")" \
        >/dev/null 2>&1 ;;
    *) ln -s "$target" "$link" 2>/dev/null ;;
  esac
}

_lane_link() {
  # _lane_link <lane-dir> <lane-name> <subdir> <merge|park> — make one directory
  # inside a lane be the host's directory instead of a copy.
  #   merge  transcripts: the lane's own recordings are real work, so they are
  #          moved into the shared store before the link replaces the directory.
  #   park   skills and plugins: whatever a lane has there is a re-downloaded
  #          cache, so it is set aside rather than merged by rules we'd invent.
  local d="$1" name="$2" sub="$3" mode="$4" link shared out moved parked
  link="$d/$sub"; shared="$P_HOST/$sub"
  [ -L "$link" ] && return 0
  [ "$link" = "$shared" ] && return 0
  mkdir -p "$shared" 2>/dev/null || return 0
  if [ -d "$link" ]; then
    if [ "$mode" = merge ]; then
      out="$(_py lane_projects "$(_np "$link")" "$(_np "$shared")" "$name" 2>/dev/null)"
      moved="$(_field "$out" moved)"
      [ "${moved:-0}" -gt 0 ] && warn "moved ${moved} transcript(s) from lane '$name' into $shared"
      rmdir "$link" 2>/dev/null
    elif [ -n "$(ls -A "$link" 2>/dev/null)" ]; then
      parked="$link.lane-backup"
      [ -e "$parked" ] || { mv "$link" "$parked" 2>/dev/null && \
        warn "set aside lane '$name' $sub/ as $(basename "$parked") — now sharing yours"; }
    else
      rmdir "$link" 2>/dev/null
    fi
  fi
  if [ -e "$link" ] && [ ! -L "$link" ]; then
    warn "lane '$name' still has its own $sub/ — leaving it unshared"
    return 0
  fi
  _link_dir "$shared" "$link" || true
  [ -L "$link" ] || warn "could not link $link -> $shared; lane '$name' keeps its own $sub/"
  return 0
}

_lane_share_projects() {
  # Only the credentials make a lane; the work does not. Share the directories
  # that hold work — conversations, skills, plugins, rules — with the host.
  local d="$1" name="$2" sub extra
  if [ "$PROV" = claude ]; then
    _lane_link "$d" "$name" projects merge
    extra="agents commands"
  else
    # Codex keeps legacy rollout transcripts here; the newer thread history is
    # SQLite, which CODEX_SQLITE_HOME points at the host instead.
    _lane_link "$d" "$name" sessions merge
    extra="rules memories"
  fi
  _lane_link "$d" "$name" skills park
  _lane_link "$d" "$name" plugins park
  # Only where you have them: linking would otherwise set aside a lane's own
  # copy in favour of an empty directory.
  for sub in $extra; do
    [ -d "$P_HOST/$sub" ] && _lane_link "$d" "$name" "$sub" park
  done
  return 0
}

_lane_seed_config() {
  # _lane_seed_config <lane-dir> <name> — a lane starts from your settings
  # (config.toml / settings.json): anything it lacks is copied in, anything it
  # sets itself is kept. Before this, every new lane began empty — no model,
  # no trusted projects, no features — and had to be set up again by hand.
  local d="$1" name="$2" fmt host lane out added
  if [ "$PROV" = codex ]; then fmt=toml; host="$P_HOST/config.toml"; lane="$d/config.toml"
  else fmt=json; host="$P_HOST/settings.json"; lane="$d/settings.json"; fi
  [ -f "$host" ] || return 0
  [ "$host" = "$lane" ] && return 0
  out="$(_py seed_config "$fmt" "$(_np "$host")" "$(_np "$lane")" 2>/dev/null)"
  added="$(_field "$out" added)"
  [ "${added:-0}" -gt 0 ] && warn "lane '$name': filled ${added} setting(s) it lacked from your global $(basename "$host")"
  return 0
}

_lane_prepare() {
  # Everything a lane needs before the CLI starts in it.
  _lane_share_projects "$1" "$2"
  _lane_seed_projects "$1"
  _lane_seed_config "$1" "$2"
}

_lane_create() {
  # _lane_create <name> — a lane made from the saved profile; nobody signs in again.
  local name="$1" d src
  d="$(_env_dir "$name")"
  [ -e "$d" ] && return 0
  src="$(_cred_in "$P_ROOT/$name")"
  [ -f "$src" ] || { warn "profile '$name' has no credential file"; return 1; }
  mkdir -p "$d" || return 1
  _env_paths "$d"
  cp -f "$src" "$EV_CRED" || return 1
  if [ "$PROV" = claude ] && [ -f "$P_ROOT/$name/claude.json" ]; then
    cp -f "$P_ROOT/$name/claude.json" "$EV_SESS"
  fi
  printf '%s  created lane %s from its saved login%s\n' "$C_DIM" "$name" "$C_RST" >&2
}

_archive_slot() {
  # _archive_slot <dir> <name> -> a free path under <dir> to move <name> to
  local dir="$1" name="$2"
  mkdir -p "$dir" || return 1
  if [ -e "$dir/$name" ]; then printf '%s' "$dir/$name-$(date +%Y%m%d-%H%M%S)"
  else printf '%s' "$dir/$name"; fi
}

_unlink() {
  # Remove a link, never what it points to. On Windows these are junctions,
  # and `rmdir` drops a junction without touching its target.
  case "$(uname -s 2>/dev/null)" in
    MINGW*|MSYS*|CYGWIN*) MSYS_NO_PATHCONV=1 cmd /c rmdir "$(_np "$1")" >/dev/null 2>&1 || rm -f "$1" ;;
    *) rm -f "$1" ;;
  esac
  [ ! -L "$1" ] && [ ! -e "$1" ]
}

_lane_retire() {
  # _lane_retire <lane-dir> <name> — take a lane out of use and lose nothing:
  # work recorded in it goes to the shared store first, the links into your
  # own config are removed as links, and the rest is archived. Only caches
  # that re-download are dropped — for Codex that is ~460MB of daemon binary.
  local d="$1" name="$2" e dest
  _lane_quiesce "$d" "lane '$name'" || return 1
  _lane_share_projects "$d" "$name"
  for e in "$d"/* "$d"/.[!.]*; do
    [ -L "$e" ] || continue
    _unlink "$e" || { warn "could not unlink $e; lane '$name' left as it was"; return 1; }
  done
  if [ "$PROV" = codex ]; then
    # packages/: the daemon (~460MB); .sandbox-bin/: the sandbox's copy of codex
    # (~300MB). Both are rebuilt by codex the next time the lane runs.
    for e in packages .sandbox-bin cache tmp .tmp; do
      [ -e "$d/$e" ] && [ ! -L "$d/$e" ] && rm -rf "${d:?}/$e"
    done
  fi
  dest="$(_archive_slot "$P_ENVROOT/.archive" "$name")" || return 1
  _move_dir "$d" "$dest" || { warn "could not archive lane '$name': a program still has files open in it"; return 1; }
  return 0
}

_lane_seed_projects() {
  # _lane_seed_projects <lane-dir> — hand the lane the directories you have
  # already trusted. .claude.json is resolved inside CLAUDE_CONFIG_DIR, so a
  # lane cannot share the file itself; it can be given the half that is machine
  # state rather than account state.
  local d="$1" out added
  [ "$PROV" = claude ] || return 0
  [ -f "$CLAUDE_HOST_SESSION" ] || return 0
  [ "$CLAUDE_HOST_SESSION" = "$d/.claude.json" ] && return 0
  out="$(_py seed_projects "$(_np "$CLAUDE_HOST_SESSION")" \
        "$(_np "$d/.claude.json")" 2>/dev/null)"
  added="$(_field "$out" added)"
  [ "${added:-0}" -gt 0 ] && warn "seeded ${added} trusted project(s) into lane from your global config"
  return 0
}

_env_paths() {
  # _env_paths <dir> -> sets EV_CRED / EV_SESS for that workspace
  if [ "$PROV" = claude ]; then EV_CRED="$1/.credentials.json"; EV_SESS="$1/.claude.json"
  else EV_CRED="$1/auth.json"; EV_SESS=""; fi
}



_env_unset() {
  # The lines that take a shell back out of whatever lane it was in.
  local fmt="$1" k
  local -a kn
  if [ "$PROV" = claude ]; then kn=(CLAUDE_CONFIG_DIR AIQ_HOST_CLAUDE)
  else kn=(CODEX_HOME CODEX_SQLITE_HOME AIQ_HOST_CODEX); fi
  for k in "${kn[@]}"; do
    case "$fmt" in
      --powershell|--pwsh) printf 'Remove-Item Env:%s -ErrorAction SilentlyContinue\n' "$k" ;;
      --cmd)               printf 'set %s=\n' "$k" ;;
      --fish)              printf 'set -e %s\n' "$k" ;;
      *)                   printf 'unset %s\n' "$k" ;;
    esac
  done
}

_lane_for() {
  # _lane_for <key> — resolve an account to its lane, making the lane from the
  # saved login when it has none yet and bringing it up to the newest login.
  # Sets LANE_NAME and LANE_DIR. Messages go to stderr: `env` output is eval'd.
  local key="$1" profile_name
  profile_name="$(_resolve "$key")"
  if [ -n "$profile_name" ]; then LANE_NAME="$profile_name"
  elif [ -d "$(_env_dir "$key")" ]; then LANE_NAME="$key"
  else die "no account '$key' — see: aiq $PROV_CLI ls"; fi
  LANE_DIR="$(_env_dir "$LANE_NAME")"
  if [ ! -d "$LANE_DIR" ]; then
    _lane_create "$LANE_NAME" || die "could not create lane '$LANE_NAME'"
  fi
  if [ -n "$profile_name" ]; then
    _reconcile "$LANE_NAME" push || die "could not bring lane '$LANE_NAME' up to date"
  fi
  _lane_prepare "$LANE_DIR" "$LANE_NAME"
}

act_env() {
  # Print environment assignments for the current shell.
  local name="${1:-}" fmt="${2:-}" native aiq_native host_native profile_name
  [ -z "$name" ] && die "usage: eval \"\$(aiq $PROV_CLI env <name>)\""
  profile_name="$(_resolve "$name")"
  # The global account needs no lane, and must not get a second live copy.
  if [ -n "$profile_name" ] && [ "$profile_name" = "$(_global_name)" ]; then
    printf "'%s' is your global account; this shell leaves any lane it was in\n" "$profile_name" >&2
    _env_unset "$fmt"
    return 0
  fi
  _lane_for "$name"
  native="$(_np "$LANE_DIR")"; aiq_native="$(_np "$AIQ_DIR")"
  host_native="$(_np "$P_HOST")"
  # One list, four dialects. The CLIs are native binaries so their own variables
  # are always native paths; the AIQ_* ones are read back by this script, which
  # wants POSIX paths in a POSIX shell.
  local -a kn=() ku=() kv=()
  kn+=("$P_ENVVAR");         ku+=("$native");      kv+=("$native")
  kn+=(AIQ_DIR);             ku+=("$AIQ_DIR");     kv+=("$aiq_native")
  if [ "$PROV" = claude ]; then
    kn+=(AIQ_HOST_CLAUDE);   ku+=("$P_HOST");      kv+=("$host_native")
  else
    # Codex keeps conversation history in SQLite under this directory rather
    # than in the config dir, so it is pointed at the host's separately.
    kn+=(CODEX_SQLITE_HOME); ku+=("$host_native"); kv+=("$host_native")
    kn+=(AIQ_HOST_CODEX);    ku+=("$P_HOST");      kv+=("$host_native")
  fi
  local i
  case "$fmt" in
    --powershell|--pwsh)
      for i in "${!kn[@]}"; do printf '$env:%s = "%s"\n' "${kn[$i]}" "${kv[$i]}"; done ;;
    --cmd)
      for i in "${!kn[@]}"; do printf 'set %s=%s\n' "${kn[$i]}" "${kv[$i]}"; done ;;
    --fish)
      for i in "${!kn[@]}"; do printf 'set -x %s '\''%s'\''\n' "${kn[$i]}" "${ku[$i]}"; done ;;
    *)
      for i in "${!kn[@]}"; do printf 'export %s='\''%s'\''\n' "${kn[$i]}" "${ku[$i]}"; done ;;
  esac
}
act_run() {
  local key="${1:-}" profile_name native resume=""
  [ -n "$key" ] || die "usage: aiq $PROV_CLI run <name> [-c|--resume] [-- command...]"
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
  [ "${1:-}" = "--" ] && shift
  if [ $# -eq 0 ] && [ -n "$resume" ]; then
    if [ "$PROV" = claude ]; then
      [ "$resume" = continue ] && set -- "$P_CLI" --continue || set -- "$P_CLI" --resume
    else
      [ "$resume" = continue ] && set -- "$P_CLI" resume --last || set -- "$P_CLI" resume
    fi
  fi
  if [ $# -eq 0 ]; then set -- "$P_CLI"; fi

  # The account the global config is signed in as needs no lane, and must not
  # get one: a second live copy of one login refreshes on its own, and the
  # provider then signs both out.
  profile_name="$(_resolve "$key")"
  if [ -n "$profile_name" ] && [ "$profile_name" = "$(_global_name)" ]; then
    info "scope: GLOBAL — '$profile_name' is already the account every terminal uses; running it here"
    # An idle lane daemon for this account would refresh its own copy sooner or later.
    if [ "$(_daemon_up "$(_env_dir "$profile_name")")" = 1 ]; then
      if _running; then warn "lane '$profile_name' runs this account too; close it there"
      else _daemon_stop "$(_env_dir "$profile_name")" "lane '$profile_name'" || true; fi
    fi
    if [ "$PROV" = claude ]; then env -u CLAUDE_CONFIG_DIR -u AIQ_HOST_CLAUDE "$@"
    else env -u CODEX_HOME -u CODEX_SQLITE_HOME -u AIQ_HOST_CODEX "$@"; fi
    return $?
  fi

  _lane_for "$key"
  info "scope: LANE \"$LANE_NAME\" (this command only) — your global account is untouched"
  native="$(_np "$LANE_DIR")"
  if [ "$PROV" = claude ]; then
    env "$P_ENVVAR=$native" AIQ_DIR="$AIQ_DIR" AIQ_HOST_CLAUDE="$CLAUDE_HOST" "$@"
  else
    env "$P_ENVVAR=$native" CODEX_SQLITE_HOME="$(_np "$CODEX_HOST")" \
        AIQ_DIR="$AIQ_DIR" AIQ_HOST_CODEX="$CODEX_HOST" "$@"
  fi
}

act_workspace() {
  # Legacy. `run` makes the lane when it is first needed; this only makes it early.
  local key="${1:-}" name
  [ -n "$key" ] || die "usage: aiq $PROV_CLI run <name>   (makes the lane when needed)"
  name="$(_resolve "$key")"
  [ -n "$name" ] || die "no account called '$key'"
  [ -e "$(_env_dir "$name")" ] && die "lane '$name' already exists"
  _lane_create "$name" || die "could not create lane '$name'"
  info "  start it with: aiq $PROV_CLI run $name"
}

_check_name() {
  case "$1" in
    ""|.|..|-*|*/*|*\\*|*" "*) die "invalid account name '$1'" ;;
  esac
}

_signin_cleanup() {
  # The sign-in dir only ever held a login that is saved by now.
  local tmp="$1"
  _daemon_stop "$tmp" "the sign-in dir" >/dev/null 2>&1 || true
  rm -rf "$tmp" 2>/dev/null || warn "could not remove $tmp; it is safe to delete"
}

_lane_resync() {
  # After signing a name in again, its lane follows the new login — even where
  # it held another account: that is what signing the name in again means.
  local name="$1" lane row state
  lane="$(_env_dir "$name")"
  [ -d "$lane" ] || return 0
  row="$(_plan "$name" | head -n1)"
  IFS=$US read -r _ _ state <<< "$row"
  case "$state" in
    older|empty) _reconcile_apply "$name" "" "$state" push ;;
    other|unknown)
      _daemon_stop "$lane" "lane '$name'" || return 1
      _env_paths "$lane"
      _backup "$EV_CRED" "preadd"
      cp -f "$(_cred_in "$P_ROOT/$name")" "$EV_CRED" || return 1
      if [ "$PROV" = claude ] && [ -f "$P_ROOT/$name/claude.json" ]; then
        _backup "$EV_SESS" "preadd"
        _py merge "$(_np "$P_ROOT/$name/claude.json")" "$(_np "$EV_SESS")" || return 1
      fi
      printf '%s  lane %s now holds the new login too%s\n' "$C_DIM" "$name" "$C_RST" >&2 ;;
  esac
  return 0
}

act_add() {
  # Sign a new account in, in a throwaway config dir, and save it under one
  # name. The global login is not touched, and no 500MB lane is left behind.
  local name="" force="" existing who tmp cred sess="" target dup rc email
  local -a pass=()
  while [ $# -gt 0 ]; do
    case "$1" in
      -f|--force) force=1 ;;
      --)         shift; pass+=("$@"); break ;;
      -*)         pass+=("$1") ;;   # handed to the CLI's own login
      *)          [ -z "$name" ] || die "usage: aiq $PROV_CLI add <name> [--force]"; name="$1" ;;
    esac
    shift
  done
  [ -n "$name" ] || die "usage: aiq $PROV_CLI add <name> [--force]"
  _check_name "$name"
  existing="$(_py resolve "$(_np "$P_ROOT")" "$name" 2>/dev/null | head -n1)"
  if [ -n "$existing" ] && [ -z "$force" ]; then
    who="$(_field "$(_py active "$PROV" "$(_np "$(_cred_in "$P_ROOT/$existing")")" \
      "$(_np "$P_ROOT/$existing/claude.json")" 2>/dev/null)" email)"
    die "account '$existing' already exists${who:+ ($who)}. To sign it in again: aiq $PROV_CLI add $existing --force"
  fi
  [ -n "$existing" ] && name="$existing"
  command -v "$P_CLI" >/dev/null 2>&1 || die "$P_CLI is not on PATH"

  tmp="$AIQ_DIR/signin/$PROV-$name"
  rm -rf "$tmp"; mkdir -p "$tmp" || die "could not create $tmp"
  info "signing in a $P_LABEL account as '$name' — finish in the browser"
  if [ "$PROV" = claude ]; then
    env CLAUDE_CONFIG_DIR="$(_np "$tmp")" "$P_CLI" auth login ${pass[@]+"${pass[@]}"}
    rc=$?
    cred="$tmp/.credentials.json"; sess="$tmp/.claude.json"
  else
    env CODEX_HOME="$(_np "$tmp")" "$P_CLI" login ${pass[@]+"${pass[@]}"}
    rc=$?
    cred="$tmp/auth.json"
  fi
  if [ ! -f "$cred" ] || [ "$(_field "$(_py active "$PROV" "$(_np "$cred")" \
       ${sess:+"$(_np "$sess")"} 2>/dev/null)" has_cred)" != 1 ]; then
    _signin_cleanup "$tmp"
    die "sign-in did not finish (exit $rc) — nothing was saved"
  fi

  # One account, one name: a login that is already saved updates that account.
  target="$name"
  dup="$(_py match "$PROV" "$(_np "$P_ROOT")" "$(_np "$cred")" ${sess:+"$(_np "$sess")"} 2>/dev/null | head -n1)"
  if [ -n "$dup" ] && [ "$dup" != "$name" ]; then
    target="$dup"
    warn "that account is already saved as '$dup'; updated it instead of saving it twice"
    info "  to call it '$name' instead: aiq $PROV_CLI rename $dup $name"
  fi
  [ -d "$P_ROOT/$target" ] && _backup "$(_cred_in "$P_ROOT/$target")" "preadd"
  _store "$P_ROOT/$target" "$cred" "$sess" || { _signin_cleanup "$tmp"; die "could not save '$target'"; }
  _signin_cleanup "$tmp"
  _lane_resync "$target" || warn "lane '$target' still holds its old login"

  email="$(_field "$(_py active "$PROV" "$(_np "$(_cred_in "$P_ROOT/$target")")" \
    "$(_np "$P_ROOT/$target/claude.json")" 2>/dev/null)" email)"
  printf '%ssaved%s %s%s%s%s\n' "$C_GRN" "$C_RST" "$C_B" "$target" "$C_RST" "${email:+  $email}"
  info "  everywhere: aiq $PROV_CLI use $target   ·   one terminal: aiq $PROV_CLI run $target"
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
  for t in cygpath powershell.exe ps cmp; do
    command -v "$t" >/dev/null 2>&1 && extra="$extra $t"
  done
  printf '  %-12s%s\n' "helpers" "${extra:-  none}"
  printf '\n'
  local p l up
  for p in claude codex; do
    _set_provider "$p"
    printf '  %s%s%s\n' "$C_B" "$P_LABEL" "$C_RST"
    if [ -f "$P_ACTIVE" ]; then printf '    %-10s %s\n' "auth" "$P_ACTIVE"
    else printf '    %-10s %snot signed in%s\n' "auth" "$C_YEL" "$C_RST"; fi
    if [ "$PROV" = claude ]; then
      if [ -f "$P_SESSION" ]; then printf '    %-10s %s\n' "session" "$P_SESSION"
      else printf '    %-10s %smissing — account identity unavailable%s\n' "session" "$C_YEL" "$C_RST"; fi
    fi
    printf '    %-10s %s  (%s saved)\n' "accounts" "$P_ROOT" \
      "$(ls -1 "$P_ROOT" 2>/dev/null | grep -v '^\.' | wc -l | tr -d ' ')"
    printf '    %-10s %s  (%s)  $%s\n' "lanes" "$P_ENVROOT" \
      "$(ls -1 "$P_ENVROOT" 2>/dev/null | wc -l | tr -d ' ')" "$P_ENVVAR"
    if [ "$PROV" = codex ]; then
      # One per config dir; each holds its login in memory until stopped.
      up=""
      [ "$(_daemon_up "$CODEX_HOME")" = 1 ] && up=" global"
      for l in "$P_ENVROOT"/*/; do
        [ -d "$l" ] && [ "$(_daemon_up "${l%/}")" = 1 ] && up="$up $(basename "$l")"
      done
      up="${up# }"
      printf '    %-10s %s\n' "daemons" "${up:-none running}"
    fi
    local cur; cur="$(_env_current)"
    if [ -n "$cur" ]; then
      printf '    %-10s %s%s%s\n' "this shell" "$C_CYA" "$cur" "$C_RST"
    fi
  done
  printf '    %-10s %s\n' "backups" "$AIQ_BACKUPS"
  # Scratch CODEX_HOMEs for quota reads. Safe to delete at any time; the next
  # `aiq codex quota` rebuilds them. Sized here because they are not small.
  if [ -d "$AIQ_CACHE" ]; then
    local sz; sz="$(du -sh "$AIQ_CACHE" 2>/dev/null | cut -f1)"
    printf '    %-10s %s  (%s, safe to delete)\n' "cache" "$AIQ_CACHE" "${sz:-?}"
  fi
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
aiq - several Claude Code / Codex CLI accounts on one machine, one name each

USAGE
  aiq <cli> <command> [name]        cli:  claude (cl)  |  codex (cx)
  aiq ls | quota | who | doctor     both CLIs at once

ACCOUNTS
  aiq ls                     every account, and which one is in use
  aiq quota                  the same table, with live usage numbers
  aiq <cli> add <name>       sign in a new account and save it as <name>
  aiq <cli> use <name>       switch: every terminal uses <name> from now on
  aiq <cli> run <name>       run <name> in this terminal only, next to the others
  aiq <cli> rename <old> <new>
  aiq <cli> rm <name>        remove an account's login. Conversations, skills and
                             settings stay; nothing is deleted:
  aiq <cli> restore <name>     ...brings it back
  aiq <cli> save <name>      save the account the CLI is signed in as right now
  aiq <cli> who              which account is signed in here
  aiq <cli> keep <name>...   keep only these accounts; remove every other one

  <name> can also be the account's email, or its start: aiq codex use kevin
  One name per account. aiq keeps the saved login, the copy `run` uses, and
  the quota numbers under that name, and keeps them from drifting apart.

WHICH ONE?
  switch account, everywhere ................. aiq <cli> use <name>
    ^ and continue the last conversation ..... aiq <cli> use <name> -c
  two accounts at once, a terminal each ...... aiq <cli> run <name>
    ^ but keep this shell .................... eval "$(aiq <cli> env <name>)"
  one command as another account ............. aiq <cli> run <name> -- <cmd>
  sign an account in again ................... aiq <cli> add <name> --force
  drop the side-by-side copy, keep account ... aiq <cli> rm <name> --lane
  remove accounts that can no longer sign in . aiq <cli> prune --yes
  keep only the accounts I use ............... aiq <cli> keep <name|email>... [--yes]
  Claude: sessions and who owns them ......... aiq claude sessions

MORE HELP
  aiq help accounts     add, use, rm and the rest, in detail
  aiq help lanes        running several accounts side by side
  aiq help quota        usage numbers, and what STATUS means
  aiq help why          why copying auth files logs you out of your device
  aiq help all          everything

Docs: https://github.com/hungdn1701/ai-account-quota
AIQHELP
}

help_profiles() {
  cat <<'AIQHELP'
ACCOUNTS

  aiq <cli> ls [--live]          list accounts. --live is the same as `quota`
  aiq <cli> ls --deleted         accounts taken out with rm
  aiq <cli> add <name>           sign a new account in (in the browser) and save it.
      --force                    sign an existing name in again
                                 It signs in from a throwaway directory, so the
                                 account you are using is not touched. A login
                                 that is already saved under another name updates
                                 that account instead of being saved twice.
  aiq <cli> save <name> [alias]  save the account the CLI is signed in as now
  aiq <cli> use <name|alias>     switch every terminal to it. `switch` works too.
      -c | --continue            then continue the last conversation
      --resume                   then pick a conversation to resume
                                 Claude sessions stay bound to the account that
                                 started them; for another account aiq writes a
                                 handoff and starts a fresh session instead.
  aiq <cli> rename <old> <new>   rename an account (and its lane)
  aiq <cli> rm <name>...         take an account's login out of use. Its
                                 conversations, skills and settings are yours and
                                 stay; whatever its lane recorded on its own is
                                 merged into them first. Archived, not deleted.
      --lane                     remove only the lane; the account stays saved
  aiq <cli> restore <name>       undo rm
  aiq <cli> keep <name|email>... keep only these accounts: shows what would go;
      --yes                      removes every other account, the same way as rm,
                                 and every second name of a kept account
  aiq <cli> prune [--yes]        list accounts that can no longer sign in;
                                 --yes removes them, the same way as rm
  aiq <cli> who                  who is signed in, here
  aiq claude refresh [name]      mint a fresh Claude access token now
  aiq claude sessions            Claude conversations here, and who owns each
  aiq claude handoff <id>        carry a conversation over to another account

  Wherever a command takes an existing account, its email works too, or just
  the start of it, as long as that fits one account:  aiq codex use kevin

  ls marks: * in use   = same account as the one in use   ~ that copy is older

  Before anything overwrites a login, aiq saves the live one back into its
  account and backs up what it replaces (~/.aiq/backups). `use` refuses while a
  session is open, because that session would put its own login back; add
  --force if you really mean to (rm and keep take it too).

  For Claude only the account keys of ~/.claude.json are carried across. Your
  projects, MCP servers and history stay where they are.

  CODEX: since 0.15x `codex` runs a background daemon per config dir that keeps
  the login in memory and never re-reads auth.json. `use` stops that daemon
  before switching; the next `codex` starts a fresh one as the new account. An
  editor extension (VS Code) holds its own copy: reload its window.
AIQHELP
}

help_workspaces() {
  cat <<'AIQHELP'
LANES - several accounts at the same time

  aiq <cli> run <name> [-c|--resume] [-- command...]
  eval "$(aiq <cli> env <name>)"            this shell, from now on
  PowerShell:  aiq <cli> env <name> --powershell | Invoke-Expression
  fish:        aiq <cli> env <name> --fish | source

  `use` changes the one account every terminal uses. `run` starts <name> in
  this terminal only, from a config dir of its own (a lane), so another account
  can run next to it. The first `run` makes the lane from the saved login;
  there is nothing to sign in or set up. When <name> is already the account
  every terminal uses, `run` simply runs it: no lane is needed.

  A lane isolates the LOGIN, not the work. These are yours, shared:
    Claude   projects/  skills/  plugins/  agents/  commands/
    Codex    sessions/  skills/  plugins/  rules/  memories/  + CODEX_SQLITE_HOME
  (a junction on Windows, a symlink elsewhere). Its settings file -
  settings.json / config.toml - starts from yours: whatever the lane lacks is
  filled in from your global one each time you enter it, and whatever it sets
  itself is kept. The lane's own file is kept once, as <file>.before-aiq.

  ONE LOGIN, ONE LIVE COPY
  A lane holds a copy of the saved login, and each copy refreshes on its own.
  Only the one refreshed last still works; restoring an older one replays a
  spent refresh token, and the provider signs the account out everywhere. So
  before ls, quota, use, run, rm and rename, aiq takes the newest copy back into
  the saved account, and `run` brings the lane up to it. `use` stops a Codex
  lane's daemon before that account becomes the global one.

  aiq <cli> rm <name> --lane     drop just the lane (for Codex, ~0.5GB of daemon
                                 binaries); the account stays, and the next
                                 `run` makes a fresh lane

  Two terminals, two accounts
    # terminal A                        # terminal B
    aiq claude run work                 aiq claude run personal

  One-off, without changing your shell
    aiq claude run work -- claude -p "summarise this"
AIQHELP
}

help_quota() {
  cat <<'AIQHELP'
QUOTA AND STATUS

  aiq quota            both providers
  aiq <cli> quota      one provider

  For Claude this asks Anthropic directly - the same source as the /usage screen
  in Claude Code - for every saved account, so you can see which one still has
  room BEFORE switching to it. It is a read-only call and never refreshes a
  token. Accounts whose access token has already expired are skipped, since the
  call cannot succeed. AIQ_OFFLINE=1 uses the last saved snapshot instead.

  For Codex this asks each account's own `codex app-server` for its live rate
  limits - the same numbers as Codex's own /status. Plans meter different
  windows: plus/pro report a 5h and a weekly window, free reports a single
  monthly one, so each column is labelled by length (5h / 7d / 30d).
  The app-server refreshes a login that is due before it answers. aiq takes
  that refreshed login back into the account afterwards, and does not read an
  account that is in use somewhere AND due, since the copy in use would then
  hold a spent token. AIQ_CODEX_BIN points at codex if it is not on PATH.

  BANK is Codex's banked resets: one-off grants that clear a spent window early.
  The column is the count; the `bank` line under the table says what each one
  resets and the date it lapses. It turns green once a window is spent.

  ONE TABLE, TWO AGES
  `ls` and `quota` print the same table. `ls` reads the last snapshot and names
  the moment it was taken; `quota` refreshes it first. Numbers older than 6
  hours are left blank rather than shown as if current. An account the refresh
  could not reach keeps its old numbers and carries the reason on its own row.

  STATUS
    ok         usable
    expiring   Claude: refresh token under 7 days left
               Codex: subscription metadata only; not authentication health
    dead       no usable local credential; sign in again: aiq <cli> add <name> --force
    ?          not enough information (saved without identity; run
               `aiq <cli> save <name>` while signed in as it)

  For Claude, dead is decided by the REFRESH token, which lives about 27 days -
  not by the access token. An expired access token is normal: use
  aiq claude refresh [name] to mint one immediately from the saved refresh token.
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

  aiq closes each way that can happen:

    - before overwriting a login it writes the live one back into its account
    - every copy of one login (saved, lane, quota scratch) is compared by when
      it was last refreshed, and the newest wins before anything uses one
    - one login is never live in two places: `run` on the account every
      terminal uses runs it directly, and `use` stops that account's lane
    - for Codex, it stops the background daemon that would otherwise keep the
      old login in memory and write it back after a switch

  It also matches accounts by identity (accountUuid for Claude,
  chatgpt_account_id for Codex) rather than by file hash. A hash changes on every
  refresh, which is why hash-based switchers lose track of who is signed in.
AIQHELP
}

help_scope() {
  cat <<'AIQHELP'
SCOPE - global switch vs. lane

  aiq changes accounts two different ways. It never guesses which you want:
  you pick the command, and every run prints a `scope:` line back.

  GLOBAL   aiq <cli> use <name>
    Rewrites the one config directory the CLI reads by default (~/.claude,
    ~/.codex). EVERY terminal - and the next one you open - now uses <name>.
    The account you leave is saved first. Refuses while a session is open.

  LANE     aiq <cli> run <name>             (one command / one terminal)
           eval "$(aiq <cli> env <name>)"   (rest of this shell)
    Points the CLI at the account's own config dir via one env var. Only this
    process is affected; other terminals and the global account do not move.
    Conversations are shared with the global config; for Claude, --continue
    works across scopes only when the selected account owns the session.

  ASSERTING SCOPE (optional, for scripts or certainty)
    aiq <cli> use <name> --global    a no-op that documents intent
    aiq <cli> use <name> --lane      error -> "use is global; for a lane: run"
    aiq <cli> run <name> --global    error -> "run is always a lane; use: use"
    aiq <cli> use <name>  (inside a lane shell)   refused

  -c / --resume work on both `use` and `run`. They map to `claude --continue`
  / `claude --resume`, and `codex resume --last` / `codex resume`.
AIQHELP
}

help_topic() {
  case "${1:-}" in
    scope|global)                                  help_scope ;;
    account|accounts|profile|profiles|switch)      help_profiles ;;
    lane|lanes|workspace|workspaces|env|envs|run|parallel) help_workspaces ;;
    quota|usage|status)                            help_quota ;;
    why|background|trap)                           help_why ;;
    all)
      usage; printf '\n'; help_profiles; printf '\n'; help_workspaces; printf '\n'
      help_scope; printf '\n'; help_quota; printf '\n'; help_why ;;
    ""|help)                                       usage ;;
    *)
      printf 'no help topic "%s"\n\n' "$1" >&2
      printf 'topics: accounts · lanes · scope · quota · why · all\n' >&2
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
    printf 'commands:   ls · quota · who · doctor · help\n' >&2
    case "$1" in
      # they typed an action but left out which CLI it applies to
      add|use|switch|run|env|save|rename|mv|rm|del|delete|remove|restore|prune|keep|refresh|\
      login|new|archive|envs|workspace|ws|sync)
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
    ls|list)                     act_ls "${1:-}" ;;
    add|login|new)               act_add "$@" ;;
    save)                        act_save "$@" ;;
    use|switch)                  act_use "$@" ;;
    run)                         act_run "$@" ;;
    env)
      case "${1:-}" in
        rm|remove|delete|del)    shift; _rm_account "${1:-}" lane || exit 1 ;;   # legacy
        *)                       act_env "${1:-}" "${2:-}" ;;
      esac ;;
    rename|mv)                   act_rename "$@" ;;
    rm|del|delete|remove|archive) act_rm "$@" ;;
    restore|unarchive|undelete)  act_restore "${1:-}" ;;
    prune)                       act_prune "${1:-}" ;;
    keep)                        act_keep "$@" ;;
    who|active|status)           act_active ;;
    quota|usage)                 act_quota ;;
    refresh)                     act_refresh "$@" ;;
    sessions|session-list|list-sessions) act_sessions "$@" ;;
    handoff)                     act_handoff "$@" ;;
    session)
      case "${1:-}" in
        list|ls) shift; act_sessions "$@" ;;
        handoff) shift; act_handoff "$@" ;;
        *) act_sessions "$@" ;;
      esac ;;
    # legacy forms, kept so old habits and scripts still work
    envs|workspaces|lanes)       act_ls ;;
    workspace|ws|import|adopt)
      if [ "${1:-}" = rename ] || [ "${1:-}" = mv ]; then shift; act_rename "$@"
      else act_workspace "${1:-}"; fi ;;
    sync)                        _sync ;;
    help|-h|--help)
      if [ -n "${1:-}" ]; then help_topic "$1"
      else help_profiles; printf '\n'; help_workspaces
        printf '\nAlso: aiq help quota · aiq help why · aiq help all\n'
      fi ;;
    *)  printf '%saiq: %s has no command "%s"%s\n' "$C_RED" "$PROV_CLI" "$action" "$C_RST" >&2
        printf '\ntry one of:\n  ls · add · use · run · rename · rm · restore · keep · who · quota\n\n' >&2
        printf 'full help:  aiq help\n' >&2
        exit 1 ;;
  esac
}

main "$@"
