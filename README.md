# aiq — multi-account manager for Claude Code and Codex CLI

Keep **several AI coding accounts on one machine under one name each**: switch
between them safely, run two side by side, and see how much quota each one has
left. One bash script. Linux, macOS, Windows (Git Bash).

```
$ aiq ls
Claude Code
@  PROFILE        ALIAS      ACCOUNT                                PLAN  STATUS    REFRESH    5H    7D         5H RESET         7D RESET
*  personal       main       me@example.com                         pro   ok          24.1d   39%   25% 2026-03-04 18:20 2026-03-09 07:00
   work           team       me@work.example                        max   expiring     4.2d    8%   12% 2026-03-04 21:45 2026-03-10 07:00
   old            -          stale@example.com                      pro   dead      expired     -     -                -                -
  * = in use in every terminal.  switch: aiq claude use <name>  ·  side by side: aiq claude run <name>
  5H/7D: cached (taken 2026-03-04 14:02) — live for every saved account: aiq claude quota

Lanes  (aiq claude run <name>: that account in one terminal, next to the others)
  LANE             ACCOUNT                        PLAN   NOTE
  work             me@work.example                max

Codex CLI
@  PROFILE        ALIAS      ACCOUNT                                PLAN  STATUS   SUB ENDS   PRIMARY SECONDARY BANK   PRIMARY RESETS SECONDARY RESETS
*  main           personal   me@example.com                         plus  ok          22.4d    5h 12%    7d 63%    1 2026-03-04 18:13 2026-03-09 09:51
   spare          -          other@example.com                      free  ok              -  30d 100%         -    - 2026-03-28 14:57                -
  bank  main           1 reset — Full reset (Weekly + 5 hr), expires 2026-04-02
  PRIMARY/SECONDARY/BANK: cached (taken 2026-03-04 14:02) — live: aiq codex quota
```

## Commands

```
aiq ls                       every account, both CLIs
aiq quota                    the same table, with live usage numbers
aiq <cli> add <name>         sign in a new account and save it as <name>
aiq <cli> use <name>         switch: every terminal uses <name> from now on
aiq <cli> run <name>         run <name> in this terminal only, next to the others
aiq <cli> rename <old> <new>
aiq <cli> rm <name>          remove an account's login; conversations, skills and settings stay
aiq <cli> restore <name>     undo rm
aiq <cli> save <name>        save the account the CLI is signed in as right now
aiq <cli> who                which account is signed in here
```

`<cli>` is `claude` (`cl`) or `codex` (`cx`). Every account has **one name**,
and every command takes it. Behind that name aiq keeps the saved login, the copy
`run` uses, and the quota numbers, and it keeps them from drifting apart.

| I want to… | run |
|---|---|
| switch account, everywhere | `aiq <cli> use <name>` |
| …and continue the last conversation | `aiq <cli> use <name> -c` |
| …and pick a conversation first | `aiq <cli> use <name> --resume` |
| two accounts at once, a terminal each | `aiq <cli> run <name>` in each |
| …but keep this shell | `eval "$(aiq <cli> env <name>)"` |
| one command as another account | `aiq <cli> run <name> -- <cmd>` |
| sign an account in again | `aiq <cli> add <name> --force` |
| delete an account (login only) | `aiq <cli> rm <name>` |
| drop an account's side-by-side copy, keep the account | `aiq <cli> rm <name> --lane` |
| remove every account that can no longer sign in | `aiq <cli> prune --yes` |
| inspect Claude sessions and their owners | `aiq claude sessions` |
| hand unfinished Claude work to another account | `aiq claude handoff <session-id>` |
| refresh an expired Claude access token now | `aiq claude refresh [name]` |

Older forms still work: `login`/`new` (= `add`), `switch` (= `use`),
`del`/`delete`/`remove`/`archive` (= `rm`), `envs`, `env rm <name>`
(= `rm <name> --lane`), `workspace`, `active`.

## Add, use, run, rm

```sh
aiq codex add work           # browser sign-in; saved as "work"
aiq codex use work           # every terminal is now "work"
aiq codex run personal       # this terminal only: "personal", next to "work"
aiq codex rm old             # the login goes; everything you made with it stays
aiq codex restore old        # changed your mind
```

**`add`** signs in from a throwaway directory (`claude auth login` /
`codex login`), saves the login, and deletes the directory. The account you are
using is not touched and nothing is left behind. If that login is already saved
under another name, that account is updated instead of being saved twice. Use
`--force` to sign an existing name in again.

**`use`** writes the live token back into the account it belongs to, backs up
what it is about to overwrite, and refuses while a CLI session is open (that
session would rewrite the auth file on exit and undo the switch). For Claude it
copies only the *account* keys of `~/.claude.json`, so your projects, MCP
servers and history stay where they are.

**`run`** starts the account in this terminal only, from a config directory of
its own (a *lane*). The first `run` makes the lane from the saved login, so
there is nothing to sign in or set up. When the account is already the one every
terminal uses, `run` simply runs it, without a lane (see below).

**`rm`** takes the login out of use, and nothing else. Conversations, skills,
plugins, rules and settings are yours, so they stay. Conversations the lane
recorded on its own are merged into yours first, and the links a lane has into
your config are removed as links, never followed. The login and the lane's own
settings are moved under `.archive/`, not deleted, which is why `restore` can
bring them back. Only caches that re-download are dropped; for Codex that is the
~460 MB of daemon binaries each lane carries.

## Codex: the background daemon

Since 0.15x, `codex` no longer runs the agent itself. It starts one long-lived
`codex app-server --managed-daemon` per config directory and talks to it, and
that daemon stays up for days. It loads `auth.json` once and never reads it
again. Swapping the file under it (which is all a switch used to do) changes
nothing, and the daemon's next token refresh writes the *old* account back over
the new one. When its token goes bad it does not recover either: it keeps
failing with `401 … invalidated oauth token` even after a valid login is on disk.

So `aiq codex use` now stops the global daemon before it switches. The next
`codex` starts a fresh daemon with the new account. It also stops the target
account's lane daemon, because one login must not be live in two places. An
editor extension (the VS Code ChatGPT extension) runs its own `app-server` and
holds its own copy of the login; `use` warns when one is running, and reloading
the editor window picks up the new account.

With the global daemon down, a codex session that is still open belongs to a
lane, so it no longer blocks `use`. `aiq doctor` lists which daemons are running.

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

The same thing happens without any switching, as soon as one login exists in
two copies that both refresh. A lane is such a copy, and so is the scratch
directory a Codex quota read runs in. aiq closes each of these paths:

- **Write-back.** Before anything overwrites a login, aiq writes the live token
  back into the account it belongs to, so a rotated token is never lost.
- **Newest wins.** Every copy of a login (saved, lane, quota scratch) is
  compared by when it was last refreshed. Before `ls`, `quota`, `use`, `run`,
  `rm` and `rename`, aiq takes the newest copy back into the saved account, and
  `run` brings the lane up to it. An older copy never overwrites a newer one.
- **One live copy.** `run` on the account every terminal already uses runs it
  directly instead of making a second copy, and `use` stops that account's lane
  daemon. `quota` does not read an account that is in use somewhere *and* due
  for a refresh, because the refresh would leave the copy in use with a spent
  token.
- **One name.** `add` and `save` refuse to save a login a second time under
  another name, and `ls` names the accounts that already are, newest first:
  `same account saved as a6 = a88 = a66 — keep the newest: aiq codex rm a88 a66`.

Accounts are matched by stable identity (`accountUuid` for Claude,
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
JWTs — no packages to install). `jq` is *not* required. Filling a Codex lane's
`config.toml` from yours needs Python 3.11+ (`tomllib`); older Pythons skip it.

**On Windows**, `install.sh` also drops an `aiq.cmd` launcher next to `aiq`, so
the command works from PowerShell and `cmd.exe` as well as Git Bash. The launcher
locates Git Bash on its own; set `AIQ_BASH` to override it. It deliberately
ignores `bash` on `PATH`, because that is usually WSL's bash, which cannot see
the `~/.claude` and `~/.codex` your Windows CLIs actually use.

## Two scopes: global switch vs. lane

`aiq` changes accounts two ways and never guesses which you want: you pick the
command, and every run prints a `scope:` line back.

| | scope | what it touches |
|---|---|---|
| `aiq <cli> use <name>` | **GLOBAL** | the one shared `~/.<cli>`: every terminal, and the next one you open |
| `aiq <cli> run <name>` / `env` | **LANE** | the account's own config dir via one env var: this terminal only |

Asserting the wrong scope is a clean error, not a surprise: `use --lane` and
`run --global` both refuse and name the right command, `use` inside a lane shell
is refused outright, and `use --global` / `run --lane` are no-ops that document
intent. `aiq help scope` has the same guide in the terminal.

Claude binds each conversation session to the account that created it, so
`--continue` / `--resume` can only reopen a session the selected account owns.
`aiq claude sessions` shows the owners. `aiq claude handoff <session-id>` writes
a compact-style handoff, and `use`/`run -c` opens a fresh session with that
handoff automatically when the owner differs.

## Lanes: what is shared

A lane isolates the *login*, not the *work*. Both CLIs keep conversations,
skills and plugins inside the config directory, so an isolated lane would start
empty and `--continue` would find nothing. `aiq` shares those directories back,
as a junction on Windows (no admin rights needed) and a symlink elsewhere:

| | shared with your real config |
|---|---|
| Claude | `projects/` `skills/` `plugins/` `agents/` `commands/` |
| Codex | `sessions/` `skills/` `plugins/` `rules/` `memories/` + `$CODEX_SQLITE_HOME` |

`agents/`, `commands/`, `rules/` and `memories/` are shared only when you have
them yourself. Codex keeps its newer conversation history in SQLite rather than
under the config dir, so lanes point `CODEX_SQLITE_HOME` at your real `~/.codex`,
the same store your global `codex` already writes to.

**Settings start from yours.** A lane's `settings.json` (Claude) or
`config.toml` (Codex) is filled from your global one each time you enter it.
Keys the lane lacks (model, reasoning effort, features, trusted projects, MCP
servers, status line) are copied in, and keys the lane sets itself are kept, so
a per-account choice still belongs there. Keys that pick an account or a
credential store (`forced_chatgpt_workspace_id`, `cli_auth_credentials_store`,
`apiKeyHelper`, …) are never copied. The rewrite drops comments, so the lane's
own file is kept once as `<file>.before-aiq`. Before this, every new lane began
with an empty config and had to be set up again by hand.

For Claude, `.claude.json` is resolved *inside* the config dir, so a lane keeps
its own identity there. Only half of that file is account state, though; the
`projects` map is trust and per-directory settings. Entering a lane copies in
the entries it is missing, so you are not re-asked to trust directories you
already approved.

Whatever a lane recorded on its own is moved into the shared store the first
time you enter it, merging into directories both sides have. A file whose name
is already taken is kept alongside as `<name>.lane-<lane>.jsonl` rather than
overwriting anything. A lane's own `skills/`, `plugins/`, `rules/` … are set
aside as `<name>.lane-backup` instead of merged.

A lane sets its CLI's config-dir variable (`CLAUDE_CONFIG_DIR` / `CODEX_HOME`),
plus `CODEX_SQLITE_HOME` for Codex and two `AIQ_*` variables `aiq` reads back to
find your real config, and your saved accounts, from inside a lane. Nothing
else: it does not set `HOME` or `USERPROFILE`.

## Check quota

```sh
aiq quota                        # both providers
aiq claude quota                 # one provider
```

`ls` and `quota` print the **same table**. The only difference is where the
numbers come from: `ls` reads the last snapshot and says when it was taken,
`quota` refreshes it first (`aiq <cli> ls --live` is the same thing). `ls` stays
instant because refreshing means one network call, or one `codex app-server`,
per account. Percentages and reset times only appear while the snapshot is
fresh (6h by default); past that both go blank rather than showing you a spent
window as if it were current.

For Claude this calls `GET /api/oauth/usage` — the same endpoint the CLI's
`/usage` screen uses — **for every saved account**, so you can see which one
still has headroom before you switch to it. It is a read-only call and never
refreshes a token.

For Codex this asks each account's own `codex app-server`, run in a scratch
directory, for its live rate limits and banked resets — the same numbers as
Codex's own `/status`. The app-server refreshes a login that is due before it
answers. aiq takes that refreshed login back into the account afterwards, and
skips an account that is in use somewhere and due (the row says so). Plans
meter different windows: plus/pro report a 5h and a weekly window, free reports
a single monthly one, so each column is labelled by length (`5h` / `7d` / `30d`).

**BANK** is Codex's *banked resets* — one-off grants that clear a spent window
early. The column is the count, so you can see at a glance which account still
has one; the `bank` line under the table says what it resets and when it lapses.
It turns green once a window is actually spent, which is when you would use it.

An account that could not be reached keeps its previous numbers and carries the
reason on its own row, instead of quietly going blank. `AIQ_OFFLINE=1` falls
back to the last saved snapshot.

`STATUS` tells you what is still usable:

| status | meaning |
|---|---|
| `ok` | signed in and good |
| `expiring` | Claude: refresh token under 7 days left; Codex: subscription metadata is informational |
| `dead` | no usable local credential: `aiq <cli> add <name> --force`, or `prune` it |

For Claude, `dead` is driven by the **refresh** token (~27 day life), not the
short-lived access token. An expired access token is normal: `aiq claude refresh`
mints one immediately from the saved refresh token.

## Built-in help

```
aiq help              start here: common tasks, in plain words
aiq help accounts     add, use, rm and the rest, in detail
aiq help lanes        running several accounts side by side
aiq help scope        global switch vs. lane, and which to run
aiq help quota        usage numbers, and what STATUS means
aiq help why          why copying auth files logs you out of your device
aiq help all          everything
```

## Where things live

| path | what |
|---|---|
| `~/.claude/profiles/<name>/` | saved Claude accounts |
| `~/.codex/profiles/<name>/` | saved Codex accounts |
| `<profiles>/.archive/<name>/` | accounts taken out with `rm`; `restore` brings them back |
| `<profile>/usage.json` | last quota snapshot, what `ls` shows while it is fresh |
| `~/.aiq/envs/<cli>/<name>/` | lanes |
| `~/.aiq/envs/<cli>/.archive/<name>/` | lanes taken out with `rm`: the lane's own settings and anything set aside |
| `<lane>/<file>.before-aiq` | a lane's settings file as it was before aiq first filled it from yours |
| `<lane>/*.lane-backup` | a lane's own `skills/`, `plugins/`… set aside when it started sharing yours |
| `~/.aiq/backups/<cli>/` | rolling backups of every credential overwrite |
| `~/.aiq/cache/codex/<name>/` | scratch `CODEX_HOME` a quota read stages `auth.json` into |
| `~/.aiq/signin/` | where `add` signs in; empty unless a sign-in was interrupted |

The only things that leave your machine are the usage reads: the Claude request
to `api.anthropic.com`, and the Codex `app-server` call to OpenAI's backend, each
with that account's own token. `aiq` never prints or transmits a token, and never
writes one outside the directories above.

## Environment

| variable | effect |
|---|---|
| `AIQ_OFFLINE=1` | never call the network; use the last saved usage snapshot |
| `AIQ_FORCE=1` | switch even while a CLI session is open (e.g. when every open codex runs in a lane) |
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
| `AIQ_HOST_CLAUDE`, `AIQ_HOST_CODEX` | where the real config dir is, so `aiq` finds it, and your saved accounts, from inside a lane |

## License

MIT
