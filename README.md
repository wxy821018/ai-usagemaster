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

- **Multiple Claude accounts.** For each account: the 5-hour window, the weekly limit (all models) and per-model weekly limits, with progress bars and reset countdowns. Turns orange at 75% and red at 90%.
- **Switch accounts.** Click an account in the menu and the `claude` CLI uses it from then on. No new login needed. Sessions that are already open follow within about 30 seconds.
- **Two switching modes**
  - Automatic. Leaves an account once its 5-hour window or weekly limit reaches 99%. Among accounts with quota left, it prefers the one whose weekly quota is about to expire, so unused quota is not wasted. If the 5-hour window resets within 5 minutes it waits instead. At least 15 minutes between automatic switches. An account you pick by hand stays until it runs out.
  - Manual. You pick, it never switches on its own.
- **Reset alerts.** A system notification when a limit resets earlier than scheduled, when the Claude status page posts something about usage limits, or when a new quota item shows up in the usage data.
- **Cursor.** Spend against the included amount for the current billing period, the reset date, and team pooled usage.
- **Command line.** `AIUsageMaster --print` prints the current numbers once. `AIUsageMaster --selftest` runs the self-checks for the switching rules.

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

Choose **Add Claude account…** in the menu (the menu text is currently in Chinese: 「添加 Claude 账号…」). A Terminal window runs the official `claude auth login` against a dedicated config directory, `~/.config/usagemaster/claude/<name>/`. The sign-in page opens in a Chrome incognito window, so an account that is already signed in to your browser does not get in the way of adding a different one.

- Adding the same account twice keeps the first copy and removes the duplicate.
- To change the name shown in the menu, put a `label` file in the account directory, for example `echo Work > ~/.config/usagemaster/claude/acct-xxx/label`.
- With no accounts added, the app shows the account `claude` is currently signed in to, read-only.

## Where the data comes from

| What | Source |
|---|---|
| Claude usage | `GET https://api.anthropic.com/api/oauth/usage`, the same endpoint Claude Code's `/usage` uses |
| Claude tokens | One Keychain item per account, `Claude Code-credentials-<first 8 hex of SHA-256 of the config dir path>`, written by Claude Code at sign-in |
| Token refresh | Five minutes before expiry, via `https://platform.claude.com/v1/oauth/token` with Claude Code's public OAuth client id |
| Status notices | `https://status.claude.com/api/v2/incidents.json` (public, no sign-in) |
| Cursor usage | `GetCurrentPeriodUsage` and `GetPlanInfo` on `https://api2.cursor.sh/aiserver.v1.DashboardService`, with the token read (read-only) from Cursor's local `state.vscdb` |

## Security and privacy

- Tokens live only in the macOS Keychain and are only sent to the matching vendor over HTTPS. Network sessions keep no disk cache, do not follow redirects, and nothing is logged.
- Keychain writes go through the standard input of `security -i`, so tokens never appear in process arguments.
- **Refreshing only touches AI UsageMaster's own copies of the credentials**, so the sign-in of the Claude Code you use day to day is not affected.
- Switching accounts changes two things: the default Keychain item `Claude Code-credentials` and the `oauthAccount` entry in `~/.claude.json`. Before switching, the current credentials (which Claude Code may have refreshed) are saved back to that account's own directory.
- If you also use another account switcher (Orca, for example), switch with only one of them. Two tools taking turns on the same default sign-in will invalidate one side's credentials and force a new login.

## Known limitations

- A personal project, not affiliated with Anthropic or Cursor. The endpoints it uses are not publicly documented and may change at any time.
- macOS only for now. On Windows, Claude Code keeps credentials in `%USERPROFILE%\.claude\.credentials.json` (or in the `CLAUDE_CONFIG_DIR` directory when that is set), and Cursor keeps its database at `%APPDATA%\Cursor\User\globalStorage\state.vscdb`. Ports are welcome; see [docs/WINDOWS.md](docs/WINDOWS.md) for what has been verified so far.
- Automatic switching only covers accounts added through AI UsageMaster.
- The menu is in Chinese for now; an English UI is planned.

## Roadmap

- Add accounts for other AI services the same way as Claude: Codex, Gemini, Kimi, Grok, ZCode, OpenCode Go, MiniMax (in progress)
- Usage history and burn-rate forecasts ("at this pace the 5-hour window runs out in about 1 h 40 min")
- Token, API-equivalent cost and per-project statistics from local Claude Code logs, compared against what the subscriptions cost
- A Claude Code status line plugin and a command line interface
- Windows version

## Acknowledgements

The approach to multi-account management and usage queries draws on [Orca](https://github.com/stablyai/orca) (MIT License, Copyright (c) 2026 Lovecast Inc.).

## License

MIT
