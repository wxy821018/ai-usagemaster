# AI UsageMaster

[English](README.md) | 简体中文

> **AI 重度用户的懒人福音**

**AI 订阅额度助手**：Claude、Cursor 等 AI 编程工具的用量、重置倒计时、多账号自动切换，都在 macOS 菜单栏上。

同时显示多个 Claude 账号和 Cursor 的用量、离重置还有多久，点一下就能切换 `claude` 命令行用哪个账号，也可以让它按用量自动切换。

```
工作 23%·2h16  个人 7%w  备用 100%w  │  Cu 61%
```

## 缘起

我手上有好几个 Claude 账号，用量也大，经常是一个用完了就得换另一个。可每次都要挨个去查：哪个还有余量，别的什么时候重置。查起来太麻烦。所以做了这个小工具：所有账号的用量都摆在菜单栏上，额度重置会提醒，一个用完了就自动切到合适的账号。

## 功能

- **多个 Claude 账号**：每个账号显示 5 小时窗口、每周（全部模型）和按模型的每周额度，带进度条和重置倒计时。颜色按服务端给每个额度标的警示级别来（服务端没给时，75% 变橙、90% 变红）。菜单栏上显示的数字，是服务端标出的"当前卡住你的那一项"。
- **账号的更多信息**：套餐（Max 20x、Max 5x、Team）、超额用量花了多少和每月上限、官方给这个账号的可用重置次数（只显示，不会自动领取）。
- **"用得太快"提醒**：和 Claude Code 同一套规则：5 小时窗口用了 90% 而时间才过去 72% 以内，或者每周额度用了 75%/50% 而一周才过去 60%/35% 以内。同时显示按现在的速度什么时候用完。
- **切换账号**：在菜单里点哪个账号，平时运行的 `claude` 就用哪个，不用重新登录。新开的会话马上就用新账号，已经开着的会话在下一次请求时跟着换，最多约 30 秒（Claude Code 2.1.288 实测）。
- **两种切换方式**
  - 自动：用完就切（5 小时窗口或每周额度 ≥99%）；有余量的账号里，优先用每周额度最快作废的那个；5 小时窗口 5 分钟内就重置时先等一下；两次自动切换至少隔 15 分钟。自动模式下手动点选的账号，在它用完之前不会被换走。
  - 手动：点哪个用哪个，不会自动换。
- **提醒**：在用账号用到 80% 或 95%、用得太快、在用账号用完（手动模式下会告诉你该切到哪个，点通知就切过去）、所有账号都用完（告诉你最早几点恢复）、用完的账号恢复可用、每周额度快作废但还剩 30% 以上、账号需要重新登录、Cursor 用到 80% 或 100%、额度被提前重置、官方状态页出现和用量限制有关的公告、用量数据里出现新的额度项、自动切换了账号。每种都能在菜单里单独关掉；同一件事在同一个重置周期里只提醒一次，重启也不会重复。
- **Cursor**：本期包含额度的花费、账单周期重置时间、团队共享额度。
- **其他 AI 服务（实验性）**：Codex、Gemini CLI、Antigravity、Kimi Code、Grok、ZCode、OpenCode Go、MiniMax，本机对应的工具登录好之后会自动出现；MiniMax 和 OpenCode Go 也可以在菜单里直接填 API Key。每个服务最多 10 分钟查一次（Codex 15 分钟）。这几家是照各自工具的本地登录文件和用量接口写的，用样例数据测过，还没用真实账号验证，可能有不完善的地方，欢迎反馈。
- **按实际速度预测**：每次读数都存进本地历史文件。最近的读数够多时，菜单里会显示最近 90 分钟的实际消耗速度，以及按这个速度几点用完。
- **费用和项目统计**：读本机 Claude Code 的日志（只读 token 数，不读对话内容），按 Claude API 标价折算：今天、本月、最近 30 天、最花钱的几个项目，还能生成按项目、模型、会话细分的 HTML 报告。填上你每月实际付的订阅费，还会算出订阅大概帮你省了多少。这是按 API 价的估算，不是账单。
- **Claude Code 状态栏**（可选）：在菜单里勾上「在 Claude Code 状态栏显示用量」，Claude Code 底部会显示一行，比如 `Opus 5.5 │ $1.23 │ ● 个人 5h 20%↻00:20 周 12% │ 工作 5h 100%↻00:30`。你原来的状态栏命令照常执行，它在 0.3 秒内给出的输出排在前面。Claude Code 交给状态栏的实时用量也会被菜单栏直接用上，少查几次用量接口。每次改 `~/.claude/settings.json` 之前都会备份，关掉时原样还原。
- **语言跟随系统**：macOS 首选语言是中文就显示中文，否则显示英文。
- **命令行**：`AIUsageMaster --print` 打印一次当前数据；`AIUsageMaster --selftest` 跑自动切换规则的自检；`AIUsageMaster --stats` 打印费用统计并生成 HTML 报告；`--install-statusline` / `--uninstall-statusline` 和菜单里那一项作用相同。

## 安装

需要 macOS 13 以上、Xcode 命令行工具（`xcode-select --install`），以及已经装好的 [Claude Code](https://docs.claude.com/en/docs/claude-code) 命令行。

```bash
git clone https://github.com/wxy821018/ai-usagemaster.git
cd ai-usagemaster
bash build.sh            # 编译并安装到 ~/Applications/AI UsageMaster.app
bash build.sh --login    # 另外设为开机自启
open "$HOME/Applications/AI UsageMaster.app"
```

取消开机自启：`launchctl bootout gui/$(id -u)/io.github.wxy821018.usagemaster && rm ~/Library/LaunchAgents/io.github.wxy821018.usagemaster.plist`

## 添加账号

菜单里点「添加 Claude 账号…」。它会打开终端，用官方的 `claude auth login` 登录到一个专用的配置目录（`~/.config/usagemaster/claude/<名字>/`）。授权页会在 Chrome 无痕窗口里打开，这样浏览器里已经登录的账号不会挡住你登录另一个账号。

- 同一个账号重复添加时，只保留最早那份，多出来的会自动删掉。
- 想改菜单上的显示名，在账号目录里放一个 `label` 文件，内容写你想要的名字，比如 `echo 工作 > ~/.config/usagemaster/claude/acct-xxx/label`。
- 一个账号都没加时，只读显示 `claude` 当前登录的那个账号。

## 数据从哪里来

| 内容 | 来源 |
|---|---|
| Claude 用量 | `GET https://api.anthropic.com/api/oauth/usage`，和 Claude Code 里 `/usage` 用的是同一个接口 |
| Claude 令牌 | 每个账号的钥匙串条目 `Claude Code-credentials-<配置目录路径的 SHA-256 前 8 位>`，由 Claude Code 登录时写入 |
| 令牌刷新 | 到期前 5 分钟向 `https://platform.claude.com/v1/oauth/token` 换新，用的是 Claude Code 的公开 OAuth client id |
| 使用中的实时用量 | Claude Code 交给状态栏命令的 `rate_limits` 字段（只在开了状态栏时） |
| Codex | Codex 命令行自带的 `codex app-server`，用 `~/.codex/auth.json`；不行时退回 `https://chatgpt.com/backend-api/wham/usage` |
| Gemini CLI、Antigravity | `~/.gemini/oauth_creds.json`（或 OpenCode 的 `auth.json`），然后查 `https://cloudcode-pa.googleapis.com/v1internal:retrieveUserQuota` |
| Kimi Code | `~/.kimi-code/credentials/kimi-code.json`，然后查 `https://api.kimi.com/coding/v1/usages` |
| Grok | `~/.grok/auth.json`，然后查 `https://cli-chat-proxy.grok.com/v1/billing` |
| ZCode | `~/.zcode/cli/config.json`（Z.ai 或智谱 BigModel 的 API Key），然后查该域名下的 `/api/monitor/usage/quota/limit` |
| OpenCode Go | 菜单里填的 API Key、OpenCode 的 `auth.json` 或环境变量 `OPENCODE_API_KEY`，然后查 `https://opencode.ai/zen/go/v1/usage` |
| MiniMax | 菜单里填的 API Key，然后查 `platform.minimax.io` 或 `www.minimaxi.com` 下的 `/v1/api/openplatform/coding_plan/remains` |
| 费用统计 | Claude Code 在 `~/.claude/projects/` 下的本地日志，只读 token 数 |
| 官方公告 | `https://status.claude.com/api/v2/incidents.json`（公开接口，不需要登录） |
| Cursor 用量 | `https://api2.cursor.sh/aiserver.v1.DashboardService/GetCurrentPeriodUsage` 与 `GetPlanInfo`，令牌从 Cursor 本地的 `state.vscdb` 只读读取 |

## 安全和隐私

- 令牌只放在 macOS 钥匙串里，只发给对应厂商的 HTTPS 接口。网络会话不写磁盘缓存，不跟随重定向，也不打日志。
- 写钥匙串时通过 `security -i` 的标准输入传入，令牌不会出现在进程参数里。唯一的例外是超过约 4 KB 的条目（MCP 服务器登录多了以后的 Claude Code 自身凭据）：`security -i` 会截断长行，所以和 Claude Code 自己的做法一样，这一次调用改用参数传值。
- 其他工具的登录文件只读不写。菜单里填的 API Key 存进钥匙串。AI UsageMaster 为 Gemini 刷新的访问令牌只放在内存里。
- **刷新只针对 UsageMaster 自己的那几份凭据**，所以不会影响你平时用的 Claude Code 的登录状态。
- 切换账号会改两处：默认钥匙串条目 `Claude Code-credentials` 里的 Claude 登录（`claudeAiOauth`），以及 `~/.claude.json` 里的 `oauthAccount`。条目里的其它内容（比如 MCP 服务器的登录）原样保留。切换前，当前账号的登录（可能已被 Claude Code 刷新过）会先存回它自己的钥匙串条目。所有检查都在写入之前做完，写入时持有 Claude Code 自己写凭据用的同一把锁，任何一步失败都会恢复原样。需要重新登录的账号不能被切过去。
- Claude Code 有时会在 `~/.claude/.credentials.json` 留一份凭据备份。这个文件在的时候，开着的会话只看它的修改时间来判断凭据变没变，所以切换后 AI UsageMaster 会更新一下它的修改时间。不改文件内容，文件不存在时也不会新建。
- 如果你还在用别的账号切换工具（比如 Orca），请只用其中一个来切换。两个工具交替改同一份默认登录，会让其中一方的凭据失效，需要重新登录。

## 已知限制

- 这是一个个人项目，和 Anthropic、Cursor 没有任何关系。用到的接口不是公开文档里的接口，厂商随时可能调整。
- 目前只支持 macOS。Windows 上 Claude Code 的凭据在 `%USERPROFILE%\.claude\.credentials.json`（带 `CLAUDE_CONFIG_DIR` 时在该目录下），Cursor 的在 `%APPDATA%\Cursor\User\globalStorage\state.vscdb`，欢迎移植，已实测的移植要点见 [docs/WINDOWS.md](docs/WINDOWS.md)。
- 自动切换只对通过 UsageMaster 添加的账号生效。

## 路线图

- 其他 AI 服务也支持像 Claude 一样添加多个账号
- 用真实账号验证其他服务
- 费用统计按 Claude 账号分开
- Windows 版（见 [docs/WINDOWS.md](docs/WINDOWS.md)）

## 致谢

多账号管理和用量查询的思路参考了 [Orca](https://github.com/stablyai/orca)（MIT License，Copyright (c) 2026 Lovecast Inc.）。
