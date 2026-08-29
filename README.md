# aiq — multi-account manager for Claude Code and Codex CLI

Run **two AI coding accounts side by side**, switch between them safely, and see
how much quota each one has left. One bash script. Linux, macOS, Windows (Git Bash).

```
$ aiq ls
Claude Code
@  PROFILE      ALIAS        ACCOUNT                        PLAN  STATUS     REFRESH    5H    7D
*  personal     main         me@example.com                 pro   ok          24.1d   39%   25%
   work         team         me@work.example                max   expiring     4.2d    8%   12%
   old          -            stale@example.com              pro   dead      expired     -     -

Codex CLI
@  PROFILE      ALIAS        ACCOUNT                        PLAN  STATUS    SUB ENDS
*  main         personal     me@example.com                 plus  ok           22.4d
```

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

`aiq` fixes this two ways:

- **Workspaces (recommended).** Each account gets its own config directory and
  the CLI is pointed at it with one environment variable. Nothing is ever copied,
  each CLI refreshes its own token in place, and **two accounts can run at the
  same time in two terminals**.
- **Profiles (classic switching).** If you prefer a single active account, every
  command writes the live token back into the profile it belongs to *before*
  overwriting anything — so a rotated token can never be lost.

Profiles are matched by **account identity** (`accountUuid` for Claude,
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

## Run two accounts at once

```sh
aiq claude login work          # creates a workspace, signs in inside it
aiq claude login personal      # a second, fully separate one
aiq claude envs                # list them
```

Then, in two terminals:

```sh
# terminal A                            # terminal B
eval "$(aiq claude env work)"           eval "$(aiq claude env personal)"
claude                                  claude
```

Or without touching your shell:

```sh
aiq claude run work                     # runs `claude` in that workspace
aiq claude run work -- claude -p "hi"   # or any command
```

PowerShell and fish are supported too:

```powershell
Invoke-Expression (aiq claude env work --powershell)
```

Already have accounts saved as profiles? Convert them without signing in again:

```sh
aiq claude adopt work
```

`login` refuses to sign in over a workspace that already holds an account, so a
new login can never land on top of an existing one.

## Switch a single account

```sh
aiq claude save personal main    # save the signed-in account as a profile
aiq claude use work              # switch
aiq claude active                # who am I right now?
```

Before any switch, `aiq` writes the live token back into its own profile, backs
up what it is about to overwrite, and refuses to run while a CLI session is open
(that session would rewrite the auth file on exit and undo the switch).

For Claude it copies only the *account* keys of `~/.claude.json` — your projects,
MCP servers and history stay exactly where they are.

## Check quota

```sh
aiq quota                        # both providers
aiq claude quota                 # per profile
```

For Claude this calls `GET /api/oauth/usage` — the same endpoint the CLI's
`/usage` screen uses — **for every saved profile**, so you can see which account
still has headroom before you switch to it. It is a read-only call and never
refreshes a token. `AIQ_OFFLINE=1` falls back to the last saved snapshot.

Codex publishes no local usage counters, so it reports plan and subscription
window instead.

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
| `expiring` | Claude: refresh token has under 7 days left · Codex: subscription ends within 3 days |
| `dead` | cannot authenticate any more — sign in again or archive it |

For Claude, `dead` is driven by the **refresh** token (~27 day life), not the
short-lived access token. An expired access token is normal; the CLI mints a new
one on the next run.

## Commands

```
aiq ls | quota | active            both providers
aiq doctor                         environment check
aiq <provider> <action> [args]     provider: claude (cl) · codex (cx)

profiles     ls [--all|--archived] · use · save · active · quota · rm
             archive · restore · prune [--yes] · sync
workspaces   login · envs · env · run · adopt
```

## Where things live

| path | what |
|---|---|
| `~/.claude/profiles/<name>/` | saved Claude profiles |
| `~/.codex/profiles/<name>/` | saved Codex profiles |
| `~/.aiq/envs/<provider>/<name>/` | parallel workspaces |
| `~/.aiq/backups/<provider>/` | rolling backups of every overwrite |

Nothing leaves your machine except the Claude usage request, which goes to
`api.anthropic.com` with your own OAuth token. `aiq` never prints or transmits a
token, and never writes one outside the directories above.

## Environment

| variable | effect |
|---|---|
| `AIQ_OFFLINE=1` | never call the network |
| `AIQ_FORCE=1` | switch even while a CLI is running |
| `AIQ_DIR` | where workspaces and backups live (default `~/.aiq`) |
| `AIQ_KEEP_BACKUPS` | how many backups to keep (default 40) |
| `NO_COLOR=1` | plain output |
| `CLAUDE_CONFIG_DIR`, `CODEX_HOME` | respected, so `aiq` works inside a workspace |

## License

MIT
