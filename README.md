# AI UsageMaster

English | [简体中文](README.zh-CN.md)

> **Made for heavy AI users who would rather not babysit their quotas.**

**Claude Code usage and rate limits in your macOS menu bar.** Live 5-hour and weekly usage with reset countdowns for several Claude accounts (Pro, Max, Team) and Cursor, plus one-click or automatic switching of the account your `claude` CLI uses.

```
Work 23%·2h16  Personal 7%w  Spare 100%w  │  Cu 61%
```

## Why I built this

I use several Claude accounts and I use them a lot, so one of them is always running out and I keep having to switch. Finding out which account still has room, and when the others reset, meant checking each one in turn. That got tedious fast. So I built a small tool that shows every account's usage in the menu bar, tells me when limits reset, and switches to the right account on its own when one runs out.

## Features

- **Multiple Claude accounts.** For each account: the 5-hour window, the weekly limit (all models) and per-model weekly limits, with progress bars and reset countdowns. Colors follow the warning level the server reports for each limit (orange at 75% and red at 90% when it reports none). The menu bar number is the limit the server marks as the one currently holding you back.
- **More detail per account.** Plan (Max 20x, Max 5x, Team), extra usage spent against its monthly cap, and any usage resets granted to the account (shown only, never redeemed).
- **"Using it fast" warning.** Same rule Claude Code uses: 90% of the 5-hour window gone while 72% or less of the time has passed, or 75%/50% of the week gone with 60%/35% or less of the week passed. Shows when it runs out at the current pace.
- **Switch accounts.** Click an account in the menu and the `claude` CLI uses it from then on. No new login needed. New sessions pick it up right away, and a session that is already open follows on its next request, within about 30 seconds (tested with Claude Code 2.1.288).
- **Two switching modes**
  - Automatic. Leaves an account once its 5-hour window or weekly limit reaches 99%. Among accounts with quota left, it prefers the one whose weekly quota is about to expire, so unused quota is not wasted. If the 5-hour window resets within 5 minutes it waits instead. At least 15 minutes between automatic switches. An account you pick by hand stays until it runs out.
  - Manual. You pick, it never switches on its own.
- **Notifications.** The active account reaching 80% or 95%, using quota fast, the active account running out (in manual mode it names the account to switch to, and clicking the notification switches), every account running out (with the earliest recovery time), a used-up account becoming available again, a weekly quota about to expire with 30% or more unused, an account that needs to sign in again, Cursor reaching 80% or 100%, limits that reset earlier than scheduled, Claude status page posts about usage limits, new quota items in the usage data, and automatic switches. Each kind can be turned off in the menu, and each event is reported once per reset period, even across restarts.
- **Cursor.** Spend against the included amount for the current billing period, the reset date, and team pooled usage.
- **Other AI services (experimental).** Codex, Gemini CLI, Antigravity, Kimi Code, Grok, ZCode, OpenCode Go and MiniMax appear on their own once their tool is signed in on this Mac. MiniMax and OpenCode Go also accept an API key entered in the menu. Each is checked at most every 10 minutes (Codex every 15). These were written from each tool's local sign-in files and usage endpoints and tested against sample responses, not yet against live accounts, so expect rough edges and please report them.
- **Burn-rate forecast.** Readings go into a local history file. Once there are enough recent readings, the menu shows the actual pace over the last 90 minutes and when the window runs out at that pace.
- **Cost and project statistics.** Reads this Mac's Claude Code logs (token counts only, never the conversation text) and prices them at Claude API list prices: today, this month, the last 30 days, the top projects, and an HTML report by project, model and session. Enter what you pay for your subscriptions and it also shows roughly how much they saved you. It is an estimate at API prices, not a bill.
- **Claude Code status line.** Optional. Turn on "Show Usage in Claude Code Status Line" in the menu and Claude Code shows a line like `Opus 5.5 │ $1.23 │ ● Personal 5h 20%↻00:20 wk 12% │ Work 5h 100%↻00:30`. Your existing status line command keeps running, and its output comes first when it answers within 0.3 seconds. The live numbers Claude Code hands to the status line also feed the menu bar, so fewer usage requests are needed. `~/.claude/settings.json` is backed up before every change, and turning it off restores what was there.
- **Follows your system language.** Chinese when macOS's preferred language is Chinese, English otherwise.
- **Command line.** `AIUsageMaster --print` prints the current numbers once. `AIUsageMaster --selftest` runs the self-checks for the switching rules. `AIUsageMaster --stats` prints the cost statistics and writes the HTML report. `--install-statusline` and `--uninstall-statusline` do the same as the menu item.

## Install

Requires macOS 13 or later, the Xcode command line tools (`xcode-select --install`), and the [Claude Code](https://docs.claude.com/en/docs/claude-code) CLI.

```bash
git clone https://github.com/wxy821018/ai-usagemaster.git
cd ai-usagemaster
bash build.sh            # builds and installs ~/Applications/AI UsageMaster.app
bash build.sh --login    # optional: start at login
open "$HOME/Applications/AI UsageMaster.app"
```

To stop starting at login: `launchctl bootout gui/$(id -u)/io.github.wxy821018.usagemaster && rm ~/Library/LaunchAgents/io.github.wxy821018.usagemaster.plist`

## Adding accounts

Choose **Add Claude Account…** in the menu. A Terminal window runs the official `claude auth login` against a dedicated config directory, `~/.config/usagemaster/claude/<name>/`. The sign-in page opens in a Chrome incognito window, so an account that is already signed in to your browser does not get in the way of adding a different one.

- Adding the same account twice keeps the first copy and removes the duplicate.
- To change the name shown in the menu, put a `label` file in the account directory, for example `echo Work > ~/.config/usagemaster/claude/acct-xxx/label`.
- With no accounts added, the app shows the account `claude` is currently signed in to, read-only.

## Where the data comes from

| What | Source |
|---|---|
| Claude usage | `GET https://api.anthropic.com/api/oauth/usage`, the same endpoint Claude Code's `/usage` uses |
| Claude tokens | One Keychain item per account, `Claude Code-credentials-<first 8 hex of SHA-256 of the config dir path>`, written by Claude Code at sign-in |
| Token refresh | Five minutes before expiry, via `https://platform.claude.com/v1/oauth/token` with Claude Code's public OAuth client id |
| Live usage while you work | The `rate_limits` field Claude Code passes to its status line command (only when the status line is turned on) |
| Codex | The Codex CLI's own `codex app-server` with `~/.codex/auth.json`; falls back to `https://chatgpt.com/backend-api/wham/usage` |
| Gemini CLI, Antigravity | `~/.gemini/oauth_creds.json` (or OpenCode's `auth.json`), then `https://cloudcode-pa.googleapis.com/v1internal:retrieveUserQuota` |
| Kimi Code | `~/.kimi-code/credentials/kimi-code.json`, then `https://api.kimi.com/coding/v1/usages` |
| Grok | `~/.grok/auth.json`, then `https://cli-chat-proxy.grok.com/v1/billing` |
| ZCode | `~/.zcode/cli/config.json` (a Z.ai or BigModel API key), then `/api/monitor/usage/quota/limit` on that host |
| OpenCode Go | An API key from the menu, OpenCode's `auth.json` or `OPENCODE_API_KEY`, then `https://opencode.ai/zen/go/v1/usage` |
| MiniMax | An API key from the menu, then `/v1/api/openplatform/coding_plan/remains` on `platform.minimax.io` or `www.minimaxi.com` |
| Cost statistics | Claude Code's local logs under `~/.claude/projects/`, token counts only |
| Status notices | `https://status.claude.com/api/v2/incidents.json` (public, no sign-in) |
| Cursor usage | `GetCurrentPeriodUsage` and `GetPlanInfo` on `https://api2.cursor.sh/aiserver.v1.DashboardService`, with the token read (read-only) from Cursor's local `state.vscdb` |

## Security and privacy

- Tokens live only in the macOS Keychain and are only sent to the matching vendor over HTTPS. Network sessions keep no disk cache, do not follow redirects, and nothing is logged.
- Keychain writes go through the standard input of `security -i`, so tokens do not appear in process arguments. The one exception is an item larger than about 4 KB (Claude Code's own credentials once many MCP servers are signed in): `security -i` cuts long lines, so, like Claude Code itself, that single call passes the value as an argument.
- Windows (port in progress) has no Keychain. There, Claude Code's and Orca's sign-ins are the plain JSON files those tools write and read themselves, and AI UsageMaster reads and writes them in place; API keys entered in AI UsageMaster are encrypted with DPAPI for the current Windows user. All credential access goes through one file, `Sources/CredentialStore.swift`.
- Other tools' sign-in files are only read, never written. API keys entered in the menu go into the Keychain. Gemini access tokens refreshed by AI UsageMaster stay in memory.
- **Refreshing only touches AI UsageMaster's own copies of the credentials**, so the sign-in of the Claude Code you use day to day is not affected.
- Switching accounts changes two things: the Claude sign-in (`claudeAiOauth`) inside the default Keychain item `Claude Code-credentials`, and the `oauthAccount` entry in `~/.claude.json`. Everything else in that item, such as MCP server sign-ins, stays as it is. Before switching, the current account's sign-in (which Claude Code may have refreshed) is saved back to that account's own Keychain item. All checks run before anything is written, the change is made while holding the same lock Claude Code uses for its own credential writes, and any failure restores the previous state. An account that needs to sign in again cannot be switched to.
- Claude Code sometimes leaves a backup copy of its credentials in `~/.claude/.credentials.json`. While that file exists, running sessions only notice a change when the file's modification time changes, so after a switch AI UsageMaster updates that timestamp. It never changes the file's contents and never creates it.
- **Using Orca as well.** Orca writes its selected Claude account back into Claude Code's default sign-in every time it fetches usage or opens a Claude session, so a switch made here is undone within minutes while Orca has an account selected. AI UsageMaster detects this (through `orca account list`) and pauses its own manual and automatic switching, with a note in the menu to switch in Orca instead; it keeps showing usage and sending notifications. If an account here ends up with the same refresh token as Orca's copy, a refresh on either side would sign the other out, so AI UsageMaster never refreshes such a copy and asks you to sign in to that account again here, which gives each app its own sign-in. AI UsageMaster never copies a sign-in that Orca placed in the default slot.

## Known limitations

- A personal project, not affiliated with Anthropic or Cursor. The endpoints it uses are not publicly documented and may change at any time.
- macOS only for now. On Windows, Claude Code keeps credentials in `%USERPROFILE%\.claude\.credentials.json` (or in the `CLAUDE_CONFIG_DIR` directory when that is set), and Cursor keeps its database at `%APPDATA%\Cursor\User\globalStorage\state.vscdb`. A port is under way: the non-UI code already builds with Swift 6.4 for Windows and runs `--print` and `--stats` there, and credential storage and account switching pass the self-test on both systems; [docs/WINDOWS.md](docs/WINDOWS.md) lists what has been verified and the changes still needed.
- Automatic switching only covers accounts added through AI UsageMaster.

## Roadmap

- Several accounts per service for the other AI services, the way Claude works now
- Verify the other services against live accounts
- Usage per Claude account in the cost statistics
- Windows version: command line and status line first, then a tray icon, account switching last (see [docs/WINDOWS.md](docs/WINDOWS.md))

## Acknowledgements

The approach to multi-account management and usage queries draws on [Orca](https://github.com/stablyai/orca) (MIT License, Copyright (c) 2026 Lovecast Inc.).

## License

MIT
