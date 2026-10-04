# Windows port notes

There is no Windows build yet. These are the facts a port depends on, checked on Windows 10 with Claude Code 2.1.289 (October 2026). Anything not listed under "Verified" has not been tested.

## Verified

### Credentials are a plain JSON file

There is no keychain. Claude Code keeps its login in `%USERPROFILE%\.claude\.credentials.json`, or in `<CLAUDE_CONFIG_DIR>\.credentials.json` when that variable is set.

The file has two top-level keys: `claudeAiOauth` (`accessToken`, `refreshToken`, `expiresAt`, `refreshTokenExpiresAt`, `scopes`, `subscriptionType`, `rateLimitTier`) and `mcpOAuth`. When switching accounts, replace only `claudeAiOauth`. Overwriting the whole file signs MCP servers out.

Cursor's database is at `%APPDATA%\Cursor\User\globalStorage\state.vscdb`, the same SQLite layout as on macOS.

### `claude auth login` honours `BROWSER`

With `BROWSER` pointing at a `.cmd` file, `claude auth login --claudeai` calls it with the authorize URL as one argument, wrapped in double quotes. The URL contains `&`, so pass the argument through untouched, for example:

```bat
@start "" "%ProgramFiles%\Google\Chrome\Application\chrome.exe" --incognito %1
```

The terminal also prints a fallback URL with a different redirect (paste-the-code flow), which can be shown if the browser never opens.

Not yet tested: that the line above really opens an incognito window and completes the sign-in. The test stopped before authorising.

### Running sessions pick up a switched account within seconds

A long-running `claude` session compares the modification time of `.credentials.json` with the last one it saw and reloads the file when it changes. Test: one session, two messages, the file edited between them.

| Between message 1 and 2 | Message 2 |
|---|---|
| access token replaced with an invalid one, 40 s wait | auth error, so the new file was read |
| same content, only the modification time updated, 40 s wait (control) | normal reply |
| access token replaced with an invalid one, 3 s wait | auth error |

So a Windows port does not need to tell people to restart their sessions after a switch.

## What this means for the port

- Before switching, copy the current default `claudeAiOauth` back to the account it belongs to. A running session may have refreshed it, and the refreshed token is the only valid one.
- Write the default file atomically (write a temp file, then rename over it). Sessions read it at any moment, so a half-written file shows up as a failed request.
- The macOS security notes in the README do not carry over: on Windows the tokens sit in plain files. Restrict the per-account directories to the current user, or keep UsageMaster's copies encrypted with DPAPI.

## Not tested yet

- Whether a running session refreshes `oauthAccount` from `~/.claude.json` after a switch. This only affects the name it shows, not which account it uses.
- Toast notifications from an unpackaged app (they usually need an AppUserModelID registered through a Start menu shortcut).

## Suggested shape

The menu bar line does not translate: tray icons are 16 px and cannot show text. The plan is a tray icon drawn on the fly with the tightest percentage (same orange at 75% and red at 90%), the current summary line as the tooltip, a flyout panel on left click with the per-account bars and switch buttons, and a short menu on right click. Start at login through `HKCU\Software\Microsoft\Windows\CurrentVersion\Run`. Keep `--print` and `--selftest`.
