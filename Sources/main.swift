// AI UsageMaster —— macOS 菜单栏小工具：实时显示多个 Claude 账号的订阅用量（5 小时窗口 / 每周）与 Cursor 本期用量，以及各自多久重置。
//
// Claude 多账号（仿 Orca 的做法，自己管理登录态）：
//   每个账号一个独立的 Claude Code 配置目录 ~/.config/usagemaster/claude/<名字>/，用官方 `claude auth login` 登录一次
//   （菜单「添加 Claude 账号…」会打开终端执行）。Claude Code 把凭据存进钥匙串条目
//   "Claude Code-credentials-<sha256(配置目录) 前 8 位>"。UsageMaster 读它，查 GET https://api.anthropic.com/api/oauth/usage；
//   令牌到期前 5 分钟用 refresh token 向 https://platform.claude.com/v1/oauth/token 换新（与 Claude Code / Orca 同一个公开
//   client_id），再经 `security -i` 从标准输入写回原条目（令牌不进进程参数）。这几份令牌只有 UsageMaster 在用，刷新不会影响
//   Orca 或你平时用的 Claude Code。
//   一个账号都没加时，退回只读显示 Claude Code 默认登录（钥匙串 "Claude Code-credentials"，不刷新）。
// Cursor：POST https://api2.cursor.sh/aiserver.v1.DashboardService/GetCurrentPeriodUsage 与 GetPlanInfo（Cursor 3.21 客户端同源），
//   令牌从 Cursor 本地 state.vscdb 只读读取。
// 令牌只在内存与钥匙串里；网络会话不落盘（ephemeral），不打日志。
//
// 构建：bash build.sh   （产物 ~/Applications/AI UsageMaster.app；加 --login 装开机自启）
// 终端看一次："~/Applications/AI UsageMaster.app/Contents/MacOS/AIUsageMaster" --print


import AppKit
import CryptoKit
import Foundation
import SQLite3

// Claude Code 状态栏：AIUsageMaster --statusline（由 Claude Code 调用，要快）
if CommandLine.arguments.contains("--statusline") { runStatusLine(); exit(0) }
if CommandLine.arguments.contains("--install-statusline") { print(installStatusLine()); exit(0) }
if CommandLine.arguments.contains("--uninstall-statusline") { print(uninstallStatusLine()); exit(0) }

if CommandLine.arguments.contains("--selftest") {
    let now = Date()
    let pinnedCase = L("当前是手动选的", "Current was picked by hand")
    func acc(_ label: String, active: Bool, s: Double, w: Double, wResetH: Double, err: String? = nil) -> ClaudeAccount {
        var a = ClaudeAccount(label: label, email: label + "@x", org: "", active: active, source: "test", configDir: "/tmp/" + label)
        a.windows = [UsageWindow(label: windowLabel(kind: "session"), percent: s, resetsAt: now.addingTimeInterval(3600), wasReset: false, kind: "session"),
                     UsageWindow(label: windowLabel(kind: "weekly_all"), percent: w, resetsAt: now.addingTimeInterval(wResetH * 3600), wasReset: false, kind: "weekly_all")]
        a.error = err
        return a
    }
    func accS(_ label: String, active: Bool, s: Double, sResetMin: Double, w: Double, wResetH: Double) -> ClaudeAccount {
        var a = acc(label, active: active, s: s, w: w, wResetH: wResetH)
        a.windows[0] = UsageWindow(label: windowLabel(kind: "session"), percent: s, resetsAt: now.addingTimeInterval(sResetMin * 60), wasReset: false, kind: "session")
        return a
    }
    let cases: [(String, [ClaudeAccount], String?)] = [
        (L("当前 5 小时用完 → 切到最该先用的", "5-hour window used up → switch to the account to use first"), [acc("A", active: true, s: 99.5, w: 40, wResetH: 100), acc("B", active: false, s: 10, w: 20, wResetH: 48), acc("C", active: false, s: 0, w: 0, wResetH: 120)], "/tmp/B"),
        (L("当前 5 小时 98%、每周 98% → 还不算用完，且没有更该先用的 → 不切", "5-hour 98%, weekly 98% → not used up and nothing better → stay"), [acc("A", active: true, s: 98, w: 98, wResetH: 20), acc("B", active: false, s: 0, w: 10, wResetH: 140)], nil),
        (L("当前账号数据取不到（被限流）→ 不切", "No data for the current account (rate limited) → stay"), [acc("A", active: true, s: 0, w: 0, wResetH: 100, err: L("被限流（429）", "rate limited (429)")), acc("B", active: false, s: 0, w: 10, wResetH: 24)], nil),
        (L("当前每周用完 → 切", "Weekly used up → switch"), [acc("A", active: true, s: 10, w: 99, wResetH: 100), acc("B", active: false, s: 0, w: 50, wResetH: 140)], "/tmp/B"),
        (L("当前能用，B 早 5 天重置且有余量 → 先用 B", "Current usable, B resets 5 days earlier with room → use B first"), [acc("A", active: true, s: 10, w: 50, wResetH: 144), acc("B", active: false, s: 0, w: 30, wResetH: 24)], "/tmp/B"),
        (L("当前能用，B 只早 6 小时 → 不切", "Current usable, B only 6 h earlier → stay"), [acc("A", active: true, s: 10, w: 50, wResetH: 30), acc("B", active: false, s: 0, w: 30, wResetH: 24)], nil),
        (L("当前能用，B 早但只剩 5% → 不切", "Current usable, B earlier but only 5% left → stay"), [acc("A", active: true, s: 10, w: 50, wResetH: 144), acc("B", active: false, s: 0, w: 95, wResetH: 24)], nil),
        (L("当前用完，其他也都用完 → 不切", "Current used up, all others too → stay"), [acc("A", active: true, s: 100, w: 50, wResetH: 144), acc("B", active: false, s: 100, w: 10, wResetH: 24), acc("C", active: false, s: 0, w: 100, wResetH: 24)], nil),
        (L("候选有报错 → 不选它", "Candidate has an error → skip it"), [acc("A", active: true, s: 100, w: 50, wResetH: 144), acc("B", active: false, s: 0, w: 10, wResetH: 24, err: L("需要重新登录", "sign in again"))], nil),
        (L("当前 5 小时满但 3 分钟后重置 → 先等", "5-hour full but resets in 3 min → wait"), [accS("A", active: true, s: 100, sResetMin: 3, w: 50, wResetH: 144), acc("B", active: false, s: 0, w: 10, wResetH: 24)], nil),
        (L("当前 5 小时满、40 分钟后才重置 → 切", "5-hour full, resets in 40 min → switch"), [accS("A", active: true, s: 100, sResetMin: 40, w: 50, wResetH: 144), acc("B", active: false, s: 0, w: 10, wResetH: 24)], "/tmp/B"),
        (L("两个候选：B 剩 60% 两天后重置，C 剩 90% 六天后 → 选 B（作废更快）", "Two candidates: B 60% left resets in 2 days, C 90% left in 6 days → B (expires sooner)"), [acc("A", active: true, s: 99, w: 50, wResetH: 100), acc("B", active: false, s: 0, w: 40, wResetH: 48), acc("C", active: false, s: 0, w: 10, wResetH: 144)], "/tmp/B"),
        (L("当前是手动选的、还能用，B 更该先用 → 不切", "Current was picked by hand and usable, B would be better → stay"), [acc("A", active: true, s: 10, w: 50, wResetH: 144), acc("B", active: false, s: 0, w: 30, wResetH: 24)], nil),
        (L("候选 5 小时快满会打折：B 5h 90%，C 5h 0% 且作废速度接近 → 选 C", "Candidates near a full 5-hour window are discounted: B 5h 90%, C 5h 0% → C"), [acc("A", active: true, s: 99, w: 50, wResetH: 100), acc("B", active: false, s: 90, w: 40, wResetH: 48), acc("C", active: false, s: 0, w: 40, wResetH: 60)], "/tmp/C"),
    ]
    // 提前重置检测
    do {
        let before = [acc("A", active: true, s: 80, w: 70, wResetH: 72)]
        let after = [acc("A", active: true, s: 5, w: 0, wResetH: 168)]
        let (_, seen) = detectEarlyResets(previous: [:], accounts: before, now: now)
        let (ev, _) = detectEarlyResets(previous: seen, accounts: after, now: now)
        print(ev.count == 2 ? L("✓ 提前重置检测：", "✓ Early reset detection: ") + ev.joined(separator: L("；", "; ")) : L("✗ 提前重置检测：得到 \(ev.count) 个事件", "✗ Early reset detection: got \(ev.count) events"))
        if ev.count != 2 { exit(1) }
    }
    var fail = 0
    for (name, accs, want) in cases {
        let d = decideAutoSwitch(accs, now: now, pinnedDir: name.hasPrefix(pinnedCase) ? "/tmp/A" : nil)
        let ok = d.target == want
        if !ok { fail += 1 }
        print("\(ok ? "✓" : "✗") \(name)\(L("：", ": "))\(d.reason)")
    }
    // 提醒规则
    func types(_ r: (alerts: [AlertItem], usable: [String: Bool])) -> [AlertType] { r.alerts.map { $0.type } }
    let alertCases: [(String, () -> Bool)] = [
        (L("在用账号 5 小时 85% → 80% 提醒", "Active 5-hour at 85% → 80% alert"), {
            let r = evaluateAlerts(accounts: [acc("A", active: true, s: 85, w: 10, wResetH: 100)], cursor: nil, autoMode: true, previousUsable: [:], now: now)
            return r.alerts.contains { $0.type == .threshold && $0.key.hasPrefix("th80|") } }),
        (L("手动模式、在用账号用完、B 可用 → 建议切到 B", "Manual mode, active used up, B usable → suggest B"), {
            let r = evaluateAlerts(accounts: [acc("A", active: true, s: 100, w: 50, wResetH: 100), acc("B", active: false, s: 0, w: 10, wResetH: 24)], cursor: nil, autoMode: false, previousUsable: [:], now: now)
            return r.alerts.contains { $0.type == .exhausted && $0.switchDir == "/tmp/B" } }),
        (L("自动模式下用完不发「建议切换」（交给自动切换）", "Automatic mode: no switch suggestion (auto-switch handles it)"), {
            let r = evaluateAlerts(accounts: [acc("A", active: true, s: 100, w: 50, wResetH: 100), acc("B", active: false, s: 0, w: 10, wResetH: 24)], cursor: nil, autoMode: true, previousUsable: [:], now: now)
            return !types(r).contains(.exhausted) }),
        (L("全部用完 → 告诉最早恢复的账号", "All used up → earliest recovery"), {
            let r = evaluateAlerts(accounts: [acc("A", active: true, s: 100, w: 50, wResetH: 100), acc("B", active: false, s: 10, w: 100, wResetH: 24)], cursor: nil, autoMode: true, previousUsable: [:], now: now)
            return r.alerts.contains { $0.type == .allExhausted && $0.body.contains("A") } }),
        (L("上一轮用完、这一轮能用 → 恢复提醒", "Used up last round, usable now → recovered"), {
            let r = evaluateAlerts(accounts: [acc("A", active: true, s: 10, w: 10, wResetH: 100), acc("B", active: false, s: 0, w: 10, wResetH: 100)], cursor: nil, autoMode: false, previousUsable: ["B@x": false], now: now)
            return r.alerts.contains { $0.type == .recovered && $0.switchDir == "/tmp/B" } }),
        (L("B 每周 10 小时后重置还剩 50% → 快作废提醒", "B resets in 10 h with 50% left → expiring"), {
            let r = evaluateAlerts(accounts: [acc("A", active: true, s: 10, w: 10, wResetH: 100), acc("B", active: false, s: 0, w: 50, wResetH: 10)], cursor: nil, autoMode: true, previousUsable: [:], now: now)
            return types(r).contains(.expiring) }),
        (L("在用账号一点数据都没有 → 不切（不当成用完）", "Active account has no data at all → stay (not treated as used up)"), {
            var a = acc("A", active: true, s: 0, w: 0, wResetH: 100); a.windows = []
            return decideAutoSwitch([a, acc("B", active: false, s: 0, w: 10, wResetH: 24)], now: now).target == nil }),
        (L("候选的每周重置时间已过、数据还没刷新 → 不因此主动切", "Candidate's weekly reset already passed, data not refreshed → no proactive switch"), {
            decideAutoSwitch([acc("A", active: true, s: 10, w: 50, wResetH: 144), acc("B", active: false, s: 0, w: 30, wResetH: -2)], now: now).target == nil }),
        (L("需要重新登录的账号不当切换目标", "An account that needs to sign in is never a switch target"), {
            var b = acc("B", active: false, s: 0, w: 10, wResetH: 24); b.needsLogin = true; b.error = "sign in again"
            return decideAutoSwitch([acc("A", active: true, s: 100, w: 50, wResetH: 100), b], now: now).target == nil }),
        (L("同样的数据算两次，去重 key 一样", "Same data twice → same dedupe keys"), {
            let a = [acc("A", active: true, s: 96, w: 80, wResetH: 10)]
            let k1 = evaluateAlerts(accounts: a, cursor: nil, autoMode: true, previousUsable: [:], now: now).alerts.map { $0.key }
            let k2 = evaluateAlerts(accounts: a, cursor: nil, autoMode: true, previousUsable: [:], now: now.addingTimeInterval(120)).alerts.map { $0.key }
            return !k1.isEmpty && k1 == k2 }),
    ]
    for (name, check) in alertCases {
        let ok = check()
        if !ok { fail += 1 }
        print("\(ok ? "✓" : "✗") \(name)")
    }
    // 切换：全部用临时钥匙串条目和临时文件，不碰真实登录
    do {
        let tag = "aium-selftest-" + UUID().uuidString.prefix(8)
        let tmp = NSTemporaryDirectory() + tag
        let fm = FileManager.default
        try? fm.createDirectory(atPath: tmp + "/claude", withIntermediateDirectories: true)
        let svc = { (n: String) in "\(tag)-\(n)" }
        let created = ["default", "A", "B", "C", "D", "big"].map(svc)
        defer {
            for s in created { _ = runCommand("/usr/bin/security", ["delete-generic-password", "-s", s, "-a", keychainAccount()], timeout: 8) }
            try? fm.removeItem(atPath: tmp)
        }
        func oa(_ e: String) -> [String: Any] { ["emailAddress": e, "organizationUuid": "org1", "organizationName": "Test"] }
        func creds(_ tok: String, rt: String? = "rt-\(UUID().uuidString)") -> [String: Any] {
            var c: [String: Any] = ["accessToken": tok, "expiresAt": 9_999_999_999_000.0, "scopes": ["user:inference"]]
            if let rt = rt { c["refreshToken"] = rt }
            return ["claudeAiOauth": c]
        }
        var mcp: [String: Any] = [:]
        for i in 0..<30 { mcp["server\(i)"] = ["accessToken": String(repeating: "x", count: 300), "serverName": "fake\(i)"] }
        var dflt = creds("tok-A-rotated"); dflt["mcpOAuth"] = mcp
        let A = ManagedAccount(dir: tmp + "/A", service: svc("A"), email: "a@x", org: "Test", orgUuid: "org1", oauthAccount: oa("a@x"))
        let B = ManagedAccount(dir: tmp + "/B", service: svc("B"), email: "b@x", org: "Test", orgUuid: "org1", oauthAccount: oa("b@x"))
        let C = ManagedAccount(dir: tmp + "/C", service: svc("C"), email: "c@x", org: "Test", orgUuid: "org1", oauthAccount: nil)
        let D = ManagedAccount(dir: tmp + "/D", service: svc("D"), email: "d@x", org: "Test", orgUuid: "org1", oauthAccount: oa("d@x"))
        let targets = SwitchTargets(defaultService: svc("default"), configPath: tmp + "/claude.json", claudeDir: tmp + "/claude", nudge: false)
        func setup() -> Bool {
            let cfg: [String: Any] = ["oauthAccount": oa("a@x"), "other": "keep"]
            try? JSONSerialization.data(withJSONObject: cfg).write(to: URL(fileURLWithPath: targets.configPath))
            return writeKeychainJSON(service: svc("default"), dflt) && writeKeychainJSON(service: svc("A"), creds("tok-A-old"))
                && writeKeychainJSON(service: svc("B"), creds("tok-B")) && writeKeychainJSON(service: svc("C"), creds("tok-C"))
                && writeKeychainJSON(service: svc("D"), creds("tok-D", rt: nil))
        }
        func tok(_ s: String) -> String? { (readKeychainJSON(service: s)?["claudeAiOauth"] as? [String: Any])?["accessToken"] as? String }
        func email() -> String? { (readJSONFile(targets.configPath)?["oauthAccount"] as? [String: Any])?["emailAddress"] as? String }
        var big: [String: Any] = ["blob": String(repeating: "y", count: 9000)]
        big["n"] = 1
        let cases: [(String, () -> Bool)] = [
            (L("超过 4 KB 的条目能完整写入并回读", "Items over 4 KB are written and read back intact"), {
                writeKeychainJSON(service: svc("big"), big) && NSDictionary(dictionary: readKeychainJSON(service: svc("big")) ?? [:]).isEqual(to: big) }),
            (L("切换：默认凭据只换 claudeAiOauth，8 KB 的 MCP 登录原样保留", "Switch: only claudeAiOauth is swapped, 8 KB of MCP sign-ins kept"), {
                guard setup(), switchDefault(to: B, all: [A, B, C, D], targets: targets) == nil else { return false }
                let d = readKeychainJSON(service: svc("default")) ?? [:]
                return tok(svc("default")) == "tok-B" && NSDictionary(dictionary: d["mcpOAuth"] as? [String: Any] ?? [:]).isEqual(to: mcp) }),
            (L("切换：当前账号只存回 claudeAiOauth（Claude Code 刷新过的那份），不带 MCP", "Switch: current account gets back only its refreshed claudeAiOauth, no MCP"), {
                guard setup(), switchDefault(to: B, all: [A, B, C, D], targets: targets) == nil else { return false }
                let a = readKeychainJSON(service: svc("A")) ?? [:]
                return tok(svc("A")) == "tok-A-rotated" && a["mcpOAuth"] == nil && email() == "b@x"
                    && readJSONFile(targets.configPath)?["other"] as? String == "keep" }),
            (L("目标账号缺账号信息 → 拒绝，什么都不改", "Target without profile → refused, nothing changed"), {
                guard setup(), switchDefault(to: C, all: [A, B, C, D], targets: targets) != nil else { return false }
                return tok(svc("default")) == "tok-A-rotated" && tok(svc("A")) == "tok-A-old" && email() == "a@x" }),
            (L("目标账号没有刷新令牌 → 拒绝，什么都不改", "Target without refresh token → refused, nothing changed"), {
                guard setup(), switchDefault(to: D, all: [A, B, C, D], targets: targets) != nil else { return false }
                return tok(svc("default")) == "tok-A-rotated" && tok(svc("A")) == "tok-A-old" && email() == "a@x" }),
        ]
        for (name, check) in cases {
            let ok = check()
            if !ok { fail += 1 }
            print("\(ok ? "✓" : "✗") \(name)")
        }
    }
    // 各模块自带的自检：多数返回失败清单；TokenStats 返回全部结果（以 ✓ / ✗ 开头）
    let modules: [(String, () -> [String])] = [
        ("Codex", CodexService.selfTest), ("Gemini", GeminiService.selfTest), ("Kimi/Grok/ZCode", KimiGrokZCode.selfTest),
        ("Kimi", KimiService.selfTest), ("Grok", GrokService.selfTest), ("ZCode", ZCodeService.selfTest),
        ("OpenCode Go", OpenCodeGoService.selfTest), ("MiniMax", MiniMaxService.selfTest), ("History", History.selfTest),
        ("TokenStats", TokenStats.selfTest),
    ]
    for (name, run) in modules {
        let r = run()
        let fails = name == "TokenStats" ? r.filter { $0.hasPrefix("✗") } : r
        if fails.isEmpty { print("✓ \(name)") } else { fail += fails.count; for f in fails { print("✗ \(name): \(f)") } }
    }
    print(fail == 0 ? L("全部通过", "All passed") : L("\(fail) 个失败", "\(fail) failed"))
    exit(fail == 0 ? 0 : 1)
}

// 费用统计：AIUsageMaster --stats  扫描本机 Claude Code 日志，打印折合 API 费用并生成 HTML 报告
if CommandLine.arguments.contains("--stats") {
    let sem = DispatchSemaphore(value: 0)
    Task.detached {
        let s = await refreshTokenStats(progress: nil)
        flushTokenStatsCache()
        let subs = loadTokenSubscriptions()
        print(L("折合 API 费用（本机 Claude Code 日志）", "API-equivalent cost (this Mac's Claude Code logs)"))
        print(L("  今天 \(usd(s.today.costUSD))，最近 7 天 \(usd(s.last7Days.costUSD))，本月 \(usd(s.thisMonth.costUSD))，最近 30 天 \(usd(s.last30Days.costUSD))",
                "  Today \(usd(s.today.costUSD)), last 7 days \(usd(s.last7Days.costUSD)), this month \(usd(s.thisMonth.costUSD)), last 30 days \(usd(s.last30Days.costUSD))"))
        let sv = tokenSavings(s, subscriptions: subs, period: .thisMonth)
        print(sv.hasSubscriptions
              ? L("  \(sv.label)：订阅费 \(usd(sv.subscriptionUSD))，相当于省下 \(usd(sv.savedUSD))", "  \(sv.label): subscriptions \(usd(sv.subscriptionUSD)), about \(usd(sv.savedUSD)) saved")
              : L("  订阅月费还没填：\(tokenSubscriptionsPath)", "  Subscription prices not set yet: \(tokenSubscriptionsPath)"))
        print(L("最近 30 天的项目：", "Projects, last 30 days:"))
        for p in s.byProject.prefix(10) { print("  \(usd(p.last30Days.costUSD).padding(toLength: 11, withPad: " ", startingAt: 0)) \(p.name)") }
        print(L("报告：", "Report: ") + writeCostReport(s, subscriptions: subs).path)
        print(L("（扫描 \(s.scannedFiles) 个文件，新增 \(s.newRecords) 条，用时 \(String(format: "%.2f", s.scanSeconds)) 秒）",
                "(\(s.scannedFiles) files scanned, \(s.newRecords) new records, \(String(format: "%.2f", s.scanSeconds)) s)"))
        sem.signal()
    }
    sem.wait()
    exit(0)
}

nonisolated(unsafe) var exitCode: Int32 = 0
if CommandLine.arguments.contains("--print") {
    let sem = DispatchSemaphore(value: 0)
    Task.detached {
        migrateLegacyAccounts()
        let s = await fetchAll()
        let now = Date()
        switch s.claude {
        case .ok(let accounts):
            for a in accounts {
                print("Claude · \(a.label)  \(a.email)  [\(ago(a.updatedAt, now: now))]" + (a.plan.map { "  \($0)" } ?? ""))
                if let e = a.error { print("  ⚠︎ \(e)") }
                if let w = a.warning, a.error == nil { print("  ⚠︎ \(w)") }
                for n in a.notes { print("  \(n)") }
                for w in a.windows {
                    let when = w.resetsAt.map { clockFmt.string(from: $0) } ?? "—"
                    let tail = w.resetsAt == nil ? L("未开始计时", "not started") : (w.wasReset ? L("\(when) 已重置（等新数据）", "reset at \(when) (waiting for new data)") : L("\(when) 重置（还有 \(countdown(w.resetsAt, now: now))）", "resets \(when) (in \(countdown(w.resetsAt, now: now)))"))
                    print("  \(w.label)  \(bar(w.percent)) \(Int(w.percent.rounded()))%  \(tail)" + (w.isActive ? L("  ← 当前卡住你的", "  ← binding") : ""))
                    if let pw = paceWarning(w, now: now) { print("    ⚡ \(pw.text)") }
                }
            }
        case .err(let m): print("Claude ⚠︎ \(m)")
        case .notConfigured: print(L("Claude：没有登录", "Claude: not signed in"))
        }
        if case .ok(let accounts) = s.claude {
            for a in accounts where !a.extraKeys.isEmpty { print(L("  \(a.label) 额外额度项：", "  \(a.label) extra quota items: ") + a.extraKeys.joined(separator: listSep)) }
            print(L("自动切换判断（只看不切）：\(decideAutoSwitch(accounts, now: now).reason)", "Automatic switching (dry run): \(decideAutoSwitch(accounts, now: now).reason)"))
        }
        let ns = await fetchOfficialNotices()
        print(ns.isEmpty ? L("官方状态页：最近 7 天没有涉及额度/重置的公告", "Status page: no notices about limits or resets in the last 7 days")
                         : ns.map { L("官方公告：", "Official notice: ") + "\($0.title)  \($0.url)" }.joined(separator: "\n"))
        switch s.cursor {
        case .ok(let u):
            let when = u.cycleEnd.map { clockFmt.string(from: $0) } ?? "—"
            let money = (u.usedCents != nil && u.limitCents != nil) ? "\(dollars(u.usedCents!)) / \(dollars(u.limitCents!))  " : ""
            print("Cursor  \(u.plan ?? "")" + (u.source == "direct" ? "" : "  [\(u.source)]"))
            print(L("  本期包含额度 \(money)\(bar(u.percent)) \(Int(u.percent.rounded()))%  \(when) 重置（还有 \(countdown(u.cycleEnd, now: now))）", "  Included this cycle \(money)\(bar(u.percent)) \(Int(u.percent.rounded()))%  resets \(when) (in \(countdown(u.cycleEnd, now: now)))"))
            if let p = u.pooled { print("  \(p)") }
        case .err(let m): print("Cursor ⚠︎ \(m)")
        case .notConfigured: break
        }
        for st in s.services {
            for a in st.accounts {
                print("\(st.displayName)  \(a.title)" + (a.plan.map { "  \($0)" } ?? "") + "  [\(ago(a.updatedAt, now: now))]")
                for n in a.notes { print("  \(n)") }
                if let e = a.error { print("  ⚠︎ \(e)") }
                for w in a.windows {
                    let pct = w.percent.map { "\(bar($0)) \(Int($0.rounded()))%" } ?? "—"
                    let when = w.resetsAt.map { L("\(clockFmt.string(from: $0)) 重置（还有 \(countdown($0, now: now))）", "resets \(clockFmt.string(from: $0)) (in \(countdown($0, now: now)))") } ?? ""
                    print("  \(w.label)  \(pct)  \(when)" + (w.detail.map { "  \($0)" } ?? ""))
                }
            }
        }
        let notSet = registeredServices.filter { !$0.isConfigured() }.map { $0.displayName }
        if !notSet.isEmpty { print(L("未配置：", "Not set up: ") + notSet.joined(separator: listSep)) }
        var bad: Int32 = 0
        if case .err = s.claude { bad = 1 }
        if case .err = s.cursor { bad = 1 }
        exitCode = bad
        sem.signal()
    }
    sem.wait()
    exit(exitCode)
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)   // 只在菜单栏，不占 Dock
    let delegate = AppDelegate()
    app.delegate = delegate          // NSApplication.delegate 是弱引用，下面显式保活
    withExtendedLifetime(delegate) { app.run() }
}
