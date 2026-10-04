# Windows port notes

There is no Windows build yet. These are the facts a port depends on, checked on Windows 10 with Claude Code 2.1.289 and Swift 6.4 (October 2026). Anything not listed as verified has not been tested.

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

### Orca runs on Windows too

Orca ships a Windows installer and keeps its Claude accounts in `%APPDATA%\orca\claude-accounts\<id>\auth\.credentials.json` (Codex accounts in `%APPDATA%\orca\codex-accounts`). On the test machine Orca was running with three Claude accounts, and the default sign-in had the same refresh token as one of them, so Orca had put it there. The macOS rule from `e5b9adf` (pause switching while Orca manages accounts, never refresh a shared refresh token) applies unchanged; only the Orca directory differs.

### The non-UI code builds with Swift 6.4 for Windows

Every source file except `App.swift` (18 of 19) builds with the swift.org toolchain, with these import changes: Apple-only modules (`AppKit`, `UserNotifications`, `Darwin`, `Security`) behind `#if canImport`, `CryptoKit` replaced by `Crypto` from swift-crypto, `import FoundationNetworking` for `URLSession`, and the SQLite amalgamation built as a C target named `SQLite3`. The toolchain also needs Visual Studio Build Tools with the C++ tools and a Windows SDK.

Run against real data on the test machine:

- `--print` works and reaches the network (it fetched the status page). The Claude line said the token had expired although it was valid for another 7 hours: `defaultAccessToken()` reads the Keychain, gets nothing on Windows, and reports that as expired.
- `--stats` read 2,281 Claude Code log files (89,604 records) in 44 s with a debug build, and wrote the HTML report.
- `--selftest`: 33 lines pass (automatic switching rules, alerts, Gemini, Kimi, Grok, ZCode, OpenCode Go, MiniMax, history), 25 fail: 7 Keychain switching tests, 11 Codex tests and 7 token statistics tests. Every failure maps to an item in the list below.

## Changes the port needs

Found by the trial build and self-test. Each is a small, local change; none touches the usage, switching or alert rules.

| Where | macOS behaviour | Windows change |
|---|---|---|
| `Claude.swift`, `ServiceOpenCodeMiniMax.swift` | Keychain through `/usr/bin/security` and `SecItemCopyMatching` | A credential store interface: Keychain on macOS, the `.credentials.json` files (plus Windows Credential Manager or DPAPI for UsageMaster's own copies and API keys) on Windows |
| `History.swift` line 442 | POSIX `rename()` replaces the target | CRT `rename` fails when the target exists: use `MoveFileExW` with `MOVEFILE_REPLACE_EXISTING` |
| `History.swift` `open()` | Binary by default | Add `_O_BINARY`, or `\n` is written as `\r\n` |
| `TokenStats.swift` | Deduplicates directories and files by `st_dev:st_ino` | `st_ino` is always 0 on Windows, so every file looks the same and only one log file is counted. Use the resolved path or the NTFS file ID |
| `TokenStats.swift` | `st_mtimespec` (nanoseconds) | Not available; take the modification time from `FileManager` attributes, otherwise changes within the same second are missed |
| `TokenStats.swift` worktree lookup | Absolute means "starts with `/`" | `C:\...` is treated as relative and joined onto another path, e.g. a project shown as `C:\src\worktree\C:\src\repo` |
| `TokenStats.swift` | `realpath`, `memmem`, `autoreleasepool` | `GetFinalPathNameByHandleW` (resolves links, keeps the loop guard working), a small `memmem`, no pool needed |
| `ServiceCodex.swift` | Finds `codex` via `:`-separated `PATH` and nvm folders; writes to the app-server through a file descriptor; `kill`, `fcntl(F_SETNOSIGPIPE)` | `;`-separated `PATH` and `codex.cmd`/`.exe`; `FileHandle.write(contentsOf:)`; `TerminateProcess`; no SIGPIPE. The self-test's fake app-server is a `/bin/sh` script and needs a `.cmd` version |
| `ServiceCodex.swift`, `ServiceKimiGrokZCode.swift` | `CFGetTypeID(n) != CFBooleanGetTypeID()` to tell JSON booleans from numbers | No public CoreFoundation; check `objCType`. The same test appears three times and can become one helper |
| `ServiceGemini.swift` | `abbreviatingWithTildeInPath` | Not in Windows Foundation; one small extension |
| `App.swift` | Holds `effective()`, `bindingWindow()` and `usd()`, which other files call | Move them into the core so the core builds without the UI |
| `Alerts.swift` | Rules and macOS delivery (`AlertCenter`) in one file | Split at `// MARK: - 发送`: rules shared, delivery per platform (Windows toast) |
| `Claude.swift` `openLoginTerminal` | `.command` script opened with `NSWorkspace` | A `.cmd` script started with `cmd /c start`, with `BROWSER` as above |
| Data and cache paths | `~/Library/Application Support/UsageMaster`, `~/Library/Application Support/Cursor`, `~/Library/Application Support/orca` | `%APPDATA%` equivalents |

## Not tested yet

- Whether a running session refreshes `oauthAccount` from `~/.claude.json` after a switch. This only affects the name it shows, not which account it uses.
- Toast notifications from an unpackaged app (they usually need an AppUserModelID registered through a Start menu shortcut).
- Codex through `codex app-server` on Windows (the test machine had no `codex` command; the direct web fallback ran).

## Plan

1. Keep one Swift codebase. Put the items above behind small platform files (credential store, paths, notifications, process helpers) and leave everything else shared.
2. First Windows release: the command line (`--print`, `--stats`, `--selftest`) and the Claude Code status line, which shows usage inside the terminal without any tray UI.
3. Then a tray icon drawn on the fly with the tightest percentage (same orange at 75% and red at 90%), the summary line as the tooltip, and a flyout panel with the per-account bars. It can be a thin shell that calls the core for JSON, so the UI stays separate from the logic. Start at login through `HKCU\Software\Microsoft\Windows\CurrentVersion\Run`.
4. Switching last, with the Orca rule above, since Orca already manages accounts on many Windows machines.
