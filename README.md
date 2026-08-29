# aiq — multi-account manager for Claude Code and Codex CLI

Run **two AI coding accounts side by side**, switch between them safely, and see
how much quota each one has left. One bash script. Linux, macOS, Windows (Git Bash).

```
$ aiq ls
Claude Code
@  PROFILE                  ALIAS            ACCOUNT                        PLAN  STATUS     REFRESH    5H    7D         5H RESET         7D RESET
*  personal                 main             me@example.com                 pro   ok          24.1d   39%   25% 2026-03-04 18:20 2026-03-09 07:00
   work                     team             me@work.example                max   expiring     4.2d    8%   12% 2026-03-04 21:45 2026-03-10 07:00
   old                      -                stale@example.com              pro   dead      expired     -     -                -                -
  ^ profiles: what plain `claude` uses.  * = active now.  switch: aiq claude use <name>

Lanes  (isolated; `run <name>` / `env <name>` — separate from the account above)
  LANE             ACCOUNT                        PLAN   BELONGS TO
  work             me@work.example                max    profile work

Codex CLI
@  PROFILE                  ALIAS            ACCOUNT                            PLAN  STATUS     SUB ENDS   PRIMARY SECONDARY   PRIMARY RESETS SECONDARY RESETS
*  main                     personal         me@example.com                     plus  ok           22.4d    5h 12%    7d 63% 2026-03-04 18:13 2026-03-09 09:51
   spare                    -                other@example.com                  free  ok               -  30d 100%         - 2026-03-28 14:57                -
```

Percentages and reset times only appear while they are fresh (6h by default).
Past that both go blank rather than showing you a spent window as if it were
current — `aiq quota` fetches live numbers.

## The re-login trap

If you juggle several Claude Code or Codex accounts by copying `.credentials.json`
or `auth.json` around, you have probably hit this: **switching accounts keeps
logging you out of your device, while staying on one account never does.**

That is not a bug in the CLI. It is OAuth refresh-token rotation:

1. You restore account **A**'s saved auth file and start working.
2. The CLI silently refreshes A's token. The provider issues a **new** refresh
   token and **invalidates the old one**. Your saved copy is now stale.
3. You switch to **B** without saving A first. A's newest token is overwritten
   and lost.
4. Later you restore A's stale copy. The provider sees a **spent refresh token
   being replayed** — the classic signature of a stolen token — and revokes the
   whole token family. You are asked to sign in on this device again.

`aiq` closes that hole in both of the ways you can change account:

- **Switching (`use`).** Every command writes the live token back into the
  profile it belongs to *before* overwriting anything, so a rotated token is
  never lost and a spent one is never replayed. This is the everyday path: one
  active account, every terminal follows it.
- **Lanes (`run` / `env`).** Each account gets its own config directory and the
  CLI is pointed at it with one environment variable. Nothing is copied at all,
  each CLI refreshes its own token in place, and **two accounts can run at the
  same time in two terminals**.

Neither loses your work: a switch leaves conversations untouched, and a lane
shares them with your real config. See *Two scopes* below.

Internally it matches accounts by stable identity (`accountUuid` for Claude,
`chatgpt_account_id` for Codex), not by file hash. A file hash changes on every
token refresh, which is why hash-based switchers lose track of which account is
signed in.

## Install

```sh
git clone https://github.com/hungdn1701/ai-account-quota.git
cd ai-account-quota
./install.sh
```

That copies `aiq` into `~/.local/bin`. Add it to `PATH` if it is not there yet.
Or just run the script in place — it has no build step:

```sh
./aiq.sh ls
```

**Requirements:** bash 3.2+ and Python 3.6+ (used only to parse JSON and decode
JWTs — no packages to install). `jq` is *not* required.

**On Windows**, `install.sh` also drops an `aiq.cmd` launcher next to `aiq`, so
the command works from PowerShell and `cmd.exe` as well as Git Bash. The launcher
locates Git Bash on its own; set `AIQ_BASH` to override it. It deliberately
ignores `bash` on `PATH`, because that is usually WSL's bash, which cannot see
the `~/.claude` and `~/.codex` your Windows CLIs actually use.

## Accounts and lanes

Use one account name everywhere. `aiq` keeps the saved profile and the isolated
lane under that same name, so normal commands need no `--workspace` flag.

```powershell
aiq claude login noob          # first login: creates and saves the account
aiq claude use noob            # switch the global CLI to it
aiq claude run noob            # run it in its own lane instead
aiq claude rename noob work    # rename profile and lane together
aiq claude ls                  # list accounts, and the lanes underneath
```

Run another account in a second terminal with another `aiq <provider> run
<account>`. "Lane" and "workspace" are the same thing — the older `workspace`,
`envs`, `env` and `--workspace` forms all still work.

### Two scopes: global switch vs. lane

`aiq` changes accounts two ways and never guesses which you want — you pick the
command, and every run prints a `scope:` line back.

| | scope | what it touches |
|---|---|---|
| `aiq <p> use <name>` | **GLOBAL** | the one shared `~/.<cli>` — every terminal, and the next one you open |
| `aiq <p> run <name>` / `env` | **LANE** | an isolated config dir via one env var — this terminal only |

**Which command do I run?**

| I want to… | run |
|---|---|
| change which account I use, everywhere | `aiq <p> use <name>` |
| …and keep this conversation going on it | `aiq <p> use <name> -c` |
| …and pick which past conversation first | `aiq <p> use <name> --resume` |
| run two accounts at once, a terminal each | `aiq <p> run <name>` in each |
| …but stay in this shell | `eval "$(aiq <p> env <name>)"` |
| try another account for one command only | `aiq <p> run <name> -- <cmd>` |
| change the account a lane is signed into | `aiq <p> login <name> --force` (from a normal terminal) |

Asserting the wrong scope is a clean error, not a surprise: `use --lane` and
`run --global` both refuse and name the right command, `use` inside a lane shell
is refused outright, and `use --global` / `run --lane` are no-ops that document
intent. `aiq help scope` has the same guide in the terminal.

## Switch a single account

```sh
aiq claude save personal main    # save the signed-in account as a profile
aiq claude use work              # switch (GLOBAL — every terminal)
aiq claude use work -c           # switch, then `claude --continue` the chat
aiq codex rename acc6 a6          # rename a saved profile; alias is kept
aiq claude active                # who am I right now?
```

Before any switch, `aiq` writes the live token back into its own profile, backs
up what it is about to overwrite, and refuses to run while a CLI session is open
(that session would rewrite the auth file on exit and undo the switch).

For Claude it copies only the *account* keys of `~/.claude.json` — your projects,
MCP servers, history, and conversation transcripts stay exactly where they are,
so a switched-to account can `--continue` / `--resume` the same conversation.
`-c` / `--resume` on `use` (and `run`) just fold that second command into the
switch.

Lanes get there a different way. Both CLIs keep conversations, skills and
plugins inside the config directory, so an isolated lane would start empty and
`--continue` would find nothing. A lane isolates the *login*, not the *work*, so
`aiq` shares those directories back — a junction on Windows (no admin rights
needed), a symlink elsewhere:

| | shared with your real config |
|---|---|
| Claude | `projects/` `skills/` `plugins/` |
| Codex | `sessions/` `skills/` `plugins/` + `$CODEX_SQLITE_HOME` |

Codex keeps its newer conversation history in SQLite rather than under the
config dir, so lanes point `CODEX_SQLITE_HOME` at your real `~/.codex`. That is
the same store your global `codex` already writes to. Measured inside a lane,
before and after: `threads=0 skills=9` → `threads=25 skills=39`, identical to
what global sees.

Whatever a lane recorded on its own is moved into the shared store the first
time you enter it; a session file whose name is already taken is kept alongside
as `<name>.lane-<lane>.jsonl` rather than overwriting anything. A lane's
`skills/` and `plugins/` only ever hold re-downloadable caches, so those are set
aside as `<name>.lane-backup` instead of merged.

Still per-lane on purpose: the credentials, and each CLI's own settings file
(`settings.json`, `config.toml`) — that is where a per-account model or
permission choice belongs.

A lane sets its CLI's config-dir variable (`CLAUDE_CONFIG_DIR` / `CODEX_HOME`),
plus `CODEX_SQLITE_HOME` for Codex and two `AIQ_*` variables `aiq` reads back to
find your real config from inside a lane. Nothing else — in particular it no
longer sets `HOME` and `USERPROFILE`. That was never needed for isolation
(Claude Code resolves its config as `join(CLAUDE_CONFIG_DIR || homedir(),
".claude.json")`, so the config dir alone is enough) and it had a real cost:
every *other* tool you ran in that shell wrote into the lane instead of your
home directory. One lane here had collected 835MB of `AppData`, `.vscode`,
`.local` and `.m2` that way.

Because `.claude.json` is resolved *inside* the config dir, a lane cannot share
that file — its identity lives there. Only half of it is account state, though:
the `projects` map is trust and per-directory settings. Entering a lane copies
in the entries it is missing, so you are not re-asked to trust directories you
already approved. Entries the lane already has are never overwritten.

## Check quota

```sh
aiq quota                        # both providers
aiq claude quota                 # per profile
```

For Claude this calls `GET /api/oauth/usage` — the same endpoint the CLI's
`/usage` screen uses — **for every saved profile**, so you can see which account
still has headroom before you switch to it. It is a read-only call and never
refreshes a token. `AIQ_OFFLINE=1` falls back to the last saved snapshot.

For Codex this asks each account's own `codex app-server` for its live rate
limits — the same numbers as Codex's own `/status`. It reads the saved
`auth.json` without rotating it. Plans meter different windows: plus/pro report a
5h and a weekly window, free reports a single monthly one, so each column is
labelled by length (`5h` / `7d` / `30d`). `AIQ_OFFLINE=1` falls back to the last
saved snapshot; set `AIQ_CODEX_BIN` if the `codex` CLI is not on `PATH`.

## Retire accounts you no longer use

```sh
aiq claude prune                 # list profiles that can no longer authenticate
aiq claude prune --yes           # archive them (moved, never deleted)
aiq claude ls --archived
aiq claude restore old
```

`STATUS` tells you what is still usable:

| status | meaning |
|---|---|
| `ok` | signed in and good |
| `expiring` | Claude: refresh token under 7 days left; Codex: subscription metadata is informational |
| `dead` | no usable local credential; sign in again or log in again |

For Claude, `dead` is driven by the **refresh** token (~27 day life), not the
short-lived access token. An expired access token is normal; the CLI mints a new
one on the next run.

## Commands

```
aiq ls | quota | active            both providers
aiq doctor                         environment check
aiq <provider> <action> [args]     provider: claude (cl) · codex (cx)

accounts     ls [--archived|--all] · login · save · use · rename · active
             quota · rm · archive · restore · prune [--yes] · sync
lanes        envs · env <name> · env rm <name> · run <name> [-- cmd...]
             workspace (ws) · workspace rename          (legacy forms)

use  <name> [--global] [-c | --resume]      run <name> [--lane] [-c | --resume]
```

Built-in help explains when to use which:

```
aiq help              start here - common tasks, in plain words
aiq help scope        global switch vs. lane, and which to run
aiq help profiles     switching a single active account
aiq help workspaces   running several accounts side by side
aiq help quota        usage numbers, and what STATUS means
aiq help why          why copying auth files logs you out of your device
aiq help all          everything
aiq claude help       the two modes, for one provider
```

## Where things live

| path | what |
|---|---|
| `~/.claude/profiles/<name>/` | saved Claude profiles |
| `~/.codex/profiles/<name>/` | saved Codex profiles |
| `<profile>/usage.json` | last quota snapshot, what `ls` shows while it is fresh |
| `~/.aiq/envs/<provider>/<name>/` | lanes |
| `<lane>/*.lane-backup` | a lane's old `skills/` or `plugins/` cache, set aside when it started sharing yours |
| `~/.aiq/backups/<provider>/` | rolling backups of every overwrite |
| `~/.aiq/cache/codex/<name>/` | scratch `CODEX_HOME` a quota read stages `auth.json` into; safe to delete |

The only things that leave your machine are the usage reads: the Claude request
to `api.anthropic.com`, and the Codex `app-server` call to OpenAI's backend, each
with that account's own token. `aiq` never prints or transmits a token, and never
writes one outside the directories above.

## Environment

| variable | effect |
|---|---|
| `AIQ_OFFLINE=1` | never call the network; use the last saved usage snapshot |
| `AIQ_FORCE=1` | switch even while a CLI is running |
| `AIQ_CODEX_BIN` | path to the `codex` executable when it is not on `PATH` |
| `AIQ_CODEX_TIMEOUT` | seconds to wait for a Codex quota read (default 45) |
| `AIQ_TIMEOUT` | seconds to wait for the Claude usage request (default 8) |
| `AIQ_CACHE_MAX_AGE` | how long Claude Code's own usage cache is trusted (default 21600 = 6h) |
| `AIQ_USAGE_CACHE_MAX_AGE` | same, for the snapshot `aiq quota` saves (default 21600) |
| `AIQ_DIR` | where lanes, backups and the quota cache live (default `~/.aiq`) |
| `AIQ_KEEP_BACKUPS` | how many backups to keep (default 40) |
| `NO_COLOR=1` | plain output |
| `CLAUDE_CONFIG_DIR`, `CODEX_HOME` | respected, so `aiq` works inside a lane |

Set inside a lane, for the lane's CLI and for `aiq` itself — you do not set these:

| variable | effect |
|---|---|
| `CODEX_SQLITE_HOME` | points a Codex lane's conversation history at your real `~/.codex` |
| `AIQ_HOST_CLAUDE`, `AIQ_HOST_CODEX` | where the real config dir is, so `aiq` can find it from inside a lane |

## License

MIT
