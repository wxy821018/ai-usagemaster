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

End to end through `--add-account`, see "Adding an account" below.

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
| ~~`Claude.swift`, `ServiceOpenCodeMiniMax.swift`~~ | ~~Keychain through `/usr/bin/security` and `SecItemCopyMatching`~~ | **Done**, see "Credential store" below |
| ~~`History.swift` line 442~~ | ~~POSIX `rename()` replaces the target~~ | **Done**, see "Paths and file handling" below |
| ~~`History.swift` `open()`~~ | ~~Binary by default~~ | **Done**, see "Paths and file handling" below |
| ~~`TokenStats.swift`~~ | ~~Deduplicates directories and files by `st_dev:st_ino`~~ | **Done**, see "Paths and file handling" below |
| ~~`TokenStats.swift`~~ | ~~`st_mtimespec` (nanoseconds)~~ | **Done**, see "Paths and file handling" below |
| ~~`TokenStats.swift` worktree lookup~~ | ~~Absolute means "starts with `/`"~~ | **Done**, see "Paths and file handling" below |
| ~~`TokenStats.swift`~~ | ~~`realpath`, `memmem`, `autoreleasepool`~~ | **Done**, see "Paths and file handling" below |
| `ServiceCodex.swift` | Finds `codex` via `:`-separated `PATH` and nvm folders; writes to the app-server through a file descriptor; `kill`, `fcntl(F_SETNOSIGPIPE)` | `;`-separated `PATH` and `codex.cmd`/`.exe`; `FileHandle.write(contentsOf:)`; `TerminateProcess`; no SIGPIPE. The self-test's fake app-server is a `/bin/sh` script and needs a `.cmd` version |
| `ServiceCodex.swift`, `ServiceKimiGrokZCode.swift` | `CFGetTypeID(n) != CFBooleanGetTypeID()` to tell JSON booleans from numbers | No public CoreFoundation; check `objCType`. The same test appears three times and can become one helper |
| `ServiceGemini.swift` | `abbreviatingWithTildeInPath` | Not in Windows Foundation; one small extension |
| `App.swift` | Holds `effective()`, `bindingWindow()` and `usd()`, which other files call | Move them into the core so the core builds without the UI |
| `Alerts.swift` | Rules and macOS delivery (`AlertCenter`) in one file | Split at `// MARK: - 发送`: rules shared, delivery per platform (Windows toast) |
| ~~`Claude.swift` `openLoginTerminal`~~ | ~~`.command` script opened with `NSWorkspace`~~ | **Done**, see "Adding an account" below |
| ~~Data and cache paths~~ | ~~`~/Library/Application Support/UsageMaster`, `~/Library/Application Support/Cursor`, `~/Library/Application Support/orca`~~ | **Done**, see "Paths and file handling" below |

## Credential store (done)

All credential access goes through `Sources/CredentialStore.swift`. A `CredentialRef` says where one credential lives: a Keychain item (service and account) on macOS, a JSON file on Windows. Five functions cover every use: `readCredential`, `readCredentialStrict` (tells "missing" from "unreadable"), `writeCredential`, `deleteCredential` and `credentialExists`.

| Credential | macOS | Windows |
|---|---|---|
| Default Claude Code sign-in | Keychain `Claude Code-credentials` | `%USERPROFILE%\.claude\.credentials.json` |
| Account added through AI UsageMaster | Keychain `Claude Code-credentials-<hash of config dir>` | `<config dir>\.credentials.json` |
| Orca account (read only) | Keychain `Orca Claude Code Managed Credentials`, account = Orca id | `%APPDATA%\orca\claude-accounts\<id>\auth\.credentials.json` |
| API keys entered in AI UsageMaster | Keychain `UsageMaster-<service>` | `%APPDATA%\UsageMaster\secrets\UsageMaster-<service>.bin`, DPAPI-encrypted |

The macOS side keeps the existing item names and accounts, so nothing stored before the change has to be migrated. On Windows a write goes to a temporary file in the same folder and then replaces the target with `MoveFileExW` (retried briefly if another process has the file open); both systems read the result back before reporting success.

Two Windows-specific findings came out of this step:

- **Orca detection.** On macOS the default sign-in counts as placed by Orca when `~/.claude/.credentials.json` holds the same refresh token as the Keychain. On Windows that file *is* the default sign-in, so the same check would always be true and a switch would never save the current account's refreshed token. On Windows the default sign-in is compared with each account under `%APPDATA%\orca\claude-accounts` instead. The Orca CLI ships as `%LOCALAPPDATA%\Programs\orca\resources\bin\orca.exe` and prints the same `account list --json` structure as on macOS.
- **Comparing JSON.** Windows Foundation (Swift 6.4) reports `NSDictionary(["n": 1]).isEqual(to:)` as false against the same dictionary read back from JSON, because a Swift `Int` or `Double` does not compare equal to the `NSNumber` it becomes. Read-back checks therefore compare the two objects serialized with sorted keys (`jsonEqual`).

Self-test: on Windows every credential and switching test passes (43 lines pass; the 18 failures left are the Codex and token statistics items in the table above). On macOS 15.6 with Swift 6.2.4 all 45 lines pass, the 42 from before plus 3 new ones (delete then read as missing, encrypted item round trip, Orca present but not the source of the default sign-in). Temporary Keychain items and files are removed afterwards. `runCommand` no longer replaces `PATH` on Windows, so the Orca CLI can find the system folders.

## Paths and file handling (done)

`Sources/Platform.swift` holds the remaining platform differences outside the credential store:

| What | macOS | Windows |
|---|---|---|
| `appSupportRoot` (Cursor, Orca, OpenCode data) | `~/Library/Application Support` | `%APPDATA%` |
| `appDataDir` (cache, history, cost report, status line snapshot) | `~/Library/Application Support/UsageMaster` | `%APPDATA%\UsageMaster` |
| `isAbsolutePath` | starts with `/` | also `C:\`, `C:/`, `\\server\share` and `\` |
| `fileInfo` (type, size, modification time, identity) | `stat`; identity = device + inode | `GetFileInformationByHandle`; identity = volume serial + file index, modification time in milliseconds |
| `realPath` | `realpath` | `GetFinalPathNameByHandleW`, so `C:/a/b` from git and `C:\a\b` from the logs become the same path |
| `replaceFile` | `rename` | `MoveFileExW` with replace, retried while another process has the file open |
| `openBinaryFlag`, `writeFD` | `0`, `write` | `_O_BINARY`, `_write` |

The macOS side is the code that was there before, moved into one place. Dotfile locations in the home folder (`~/.claude`, `~/.config/usagemaster`, `~/.codex` and so on) are the same on both systems and were left alone. The same "absolute means starts with `/`" bug was also fixed for `GROK_HOME` and `OPENCODE_DB` / `XDG_DATA_HOME`.

Checked on the test machine with real Claude Code logs (2,281 files): worktree costs now land on the main repository (for example 3.06 + 1.03 = 4.09 USD for one repository whose worktree was listed separately before), the file count is unchanged, and a second run reads only what changed (2 s instead of 35 s). Self-test: Windows passes everything except the 11 Codex items; macOS 15.6 passes all 45.

## Adding an account (done)

`AIUsageMaster --add-account` (and the menu item on macOS) calls `addClaudeAccount()`: it creates `~/.config/usagemaster/claude/acct-<timestamp>` and opens the sign-in window. On Windows that is a command prompt started with `cmd /c start`, running a generated `.cmd` that:

- switches the console to UTF-8 (`chcp 65001`) before printing anything, because the default code page of a Chinese Windows install is 936 and the instructions would otherwise be garbled;
- sets `CLAUDE_CONFIG_DIR` to the new folder and `BROWSER` to a second `.cmd` that passes the URL on untouched to Chrome `--incognito`, or Edge `--inprivate`, or the default browser;
- runs `claude auth login --claudeai`, then `claude auth status --text`, and waits for a key.

Characters that mean something to `echo` in cmd (`^ & | < > ( )`, `%`) are escaped. Checked on the test machine: the sign-in completed, `.credentials.json` (with a refresh token) and `.claude.json` (with the account profile) appeared in the new folder, and `--print` then listed the account with its 5-hour and weekly usage. The macOS script is unchanged.

## Not tested yet

- Whether a running session refreshes `oauthAccount` from `~/.claude.json` after a switch. This only affects the name it shows, not which account it uses.
- Toast notifications from an unpackaged app (they usually need an AppUserModelID registered through a Start menu shortcut).
- Codex through `codex app-server` on Windows (the test machine had no `codex` command; the direct web fallback ran).

## Plan

1. Keep one Swift codebase. Put the items above behind small platform files (credential store, paths and the login terminal: done; Codex process handling and notifications: next) and leave everything else shared.
2. First Windows release: the command line (`--print`, `--stats`, `--selftest`) and the Claude Code status line, which shows usage inside the terminal without any tray UI.
3. Then a tray icon drawn on the fly with the tightest percentage (same orange at 75% and red at 90%), the summary line as the tooltip, and a flyout panel with the per-account bars. It can be a thin shell that calls the core for JSON, so the UI stays separate from the logic. Start at login through `HKCU\Software\Microsoft\Windows\CurrentVersion\Run`.
4. Switching last, with the Orca rule above, since Orca already manages accounts on many Windows machines.
