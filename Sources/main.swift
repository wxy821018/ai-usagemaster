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

if CommandLine.arguments.contains("--selftest") {
    let now = Date()
    func acc(_ label: String, active: Bool, s: Double, w: Double, wResetH: Double, err: String? = nil) -> ClaudeAccount {
        var a = ClaudeAccount(label: label, email: label + "@x", org: "", active: active, source: "test", configDir: "/tmp/" + label)
        a.windows = [UsageWindow(label: "5 小时窗口", percent: s, resetsAt: now.addingTimeInterval(3600), wasReset: false),
                     UsageWindow(label: "每周（全部模型）", percent: w, resetsAt: now.addingTimeInterval(wResetH * 3600), wasReset: false)]
        a.error = err
        return a
    }
    func accS(_ label: String, active: Bool, s: Double, sResetMin: Double, w: Double, wResetH: Double) -> ClaudeAccount {
        var a = acc(label, active: active, s: s, w: w, wResetH: wResetH)
        a.windows[0] = UsageWindow(label: "5 小时窗口", percent: s, resetsAt: now.addingTimeInterval(sResetMin * 60), wasReset: false)
        return a
    }
    let cases: [(String, [ClaudeAccount], String?)] = [
        ("当前 5 小时用完 → 切到最该先用的", [acc("A", active: true, s: 99.5, w: 40, wResetH: 100), acc("B", active: false, s: 10, w: 20, wResetH: 48), acc("C", active: false, s: 0, w: 0, wResetH: 120)], "/tmp/B"),
        ("当前 5 小时 98%、每周 98% → 还不算用完，且没有更该先用的 → 不切", [acc("A", active: true, s: 98, w: 98, wResetH: 20), acc("B", active: false, s: 0, w: 10, wResetH: 140)], nil),
        ("当前账号数据取不到（被限流）→ 不切", [acc("A", active: true, s: 0, w: 0, wResetH: 100, err: "被限流（429）"), acc("B", active: false, s: 0, w: 10, wResetH: 24)], nil),
        ("当前每周用完 → 切", [acc("A", active: true, s: 10, w: 99, wResetH: 100), acc("B", active: false, s: 0, w: 50, wResetH: 140)], "/tmp/B"),
        ("当前能用，B 早 5 天重置且有余量 → 先用 B", [acc("A", active: true, s: 10, w: 50, wResetH: 144), acc("B", active: false, s: 0, w: 30, wResetH: 24)], "/tmp/B"),
        ("当前能用，B 只早 6 小时 → 不切", [acc("A", active: true, s: 10, w: 50, wResetH: 30), acc("B", active: false, s: 0, w: 30, wResetH: 24)], nil),
        ("当前能用，B 早但只剩 5% → 不切", [acc("A", active: true, s: 10, w: 50, wResetH: 144), acc("B", active: false, s: 0, w: 95, wResetH: 24)], nil),
        ("当前用完，其他也都用完 → 不切", [acc("A", active: true, s: 100, w: 50, wResetH: 144), acc("B", active: false, s: 100, w: 10, wResetH: 24), acc("C", active: false, s: 0, w: 100, wResetH: 24)], nil),
        ("候选有报错 → 不选它", [acc("A", active: true, s: 100, w: 50, wResetH: 144), acc("B", active: false, s: 0, w: 10, wResetH: 24, err: "需要重新登录")], nil),
        ("当前 5 小时满但 3 分钟后重置 → 先等", [accS("A", active: true, s: 100, sResetMin: 3, w: 50, wResetH: 144), acc("B", active: false, s: 0, w: 10, wResetH: 24)], nil),
        ("当前 5 小时满、40 分钟后才重置 → 切", [accS("A", active: true, s: 100, sResetMin: 40, w: 50, wResetH: 144), acc("B", active: false, s: 0, w: 10, wResetH: 24)], "/tmp/B"),
        ("两个候选：B 剩 60% 两天后重置，C 剩 90% 六天后 → 选 B（作废更快）", [acc("A", active: true, s: 99, w: 50, wResetH: 100), acc("B", active: false, s: 0, w: 40, wResetH: 48), acc("C", active: false, s: 0, w: 10, wResetH: 144)], "/tmp/B"),
        ("当前是手动选的、还能用，B 更该先用 → 不切", [acc("A", active: true, s: 10, w: 50, wResetH: 144), acc("B", active: false, s: 0, w: 30, wResetH: 24)], nil),
        ("候选 5 小时快满会打折：B 5h 90%，C 5h 0% 且作废速度接近 → 选 C", [acc("A", active: true, s: 99, w: 50, wResetH: 100), acc("B", active: false, s: 90, w: 40, wResetH: 48), acc("C", active: false, s: 0, w: 40, wResetH: 60)], "/tmp/C"),
    ]
    // 提前重置检测
    do {
        let before = [acc("A", active: true, s: 80, w: 70, wResetH: 72)]
        let after = [acc("A", active: true, s: 5, w: 0, wResetH: 168)]
        let (_, seen) = detectEarlyResets(previous: [:], accounts: before, now: now)
        let (ev, _) = detectEarlyResets(previous: seen, accounts: after, now: now)
        print(ev.count == 2 ? "✓ 提前重置检测：\(ev.joined(separator: "；"))" : "✗ 提前重置检测：得到 \(ev.count) 个事件")
        if ev.count != 2 { exit(1) }
    }
    var fail = 0
    for (name, accs, want) in cases {
        let d = decideAutoSwitch(accs, now: now, pinnedDir: name.hasPrefix("当前是手动选的") ? "/tmp/A" : nil)
        let ok = d.target == want
        if !ok { fail += 1 }
        print("\(ok ? "✓" : "✗") \(name)：\(d.reason)")
    }
    print(fail == 0 ? "全部通过" : "\(fail) 个失败")
    exit(fail == 0 ? 0 : 1)
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
                print("Claude · \(a.label)  \(a.email)  [\(ago(a.updatedAt, now: now))]")
                if let e = a.error { print("  ⚠︎ \(e)") }
                for w in a.windows {
                    let when = w.resetsAt.map { clockFmt.string(from: $0) } ?? "—"
                    let tail = w.resetsAt == nil ? "未开始计时" : (w.wasReset ? "\(when) 已重置（等新数据）" : "\(when) 重置（还有 \(countdown(w.resetsAt, now: now))）")
                    print("  \(w.label)  \(bar(w.percent)) \(Int(w.percent.rounded()))%  \(tail)")
                }
            }
        case .err(let m): print("Claude ⚠︎ \(m)")
        }
        if case .ok(let accounts) = s.claude {
            for a in accounts where !a.extraKeys.isEmpty { print("  \(a.label) 额外额度项：\(a.extraKeys.joined(separator: "、"))") }
            print("自动切换判断（只看不切）：\(decideAutoSwitch(accounts, now: now).reason)")
        }
        let ns = await fetchOfficialNotices()
        print(ns.isEmpty ? "官方状态页：最近 7 天没有涉及额度/重置的公告" : ns.map { "官方公告：\($0.title)  \($0.url)" }.joined(separator: "\n"))
        switch s.cursor {
        case .ok(let u):
            let when = u.cycleEnd.map { clockFmt.string(from: $0) } ?? "—"
            let money = (u.usedCents != nil && u.limitCents != nil) ? "\(dollars(u.usedCents!)) / \(dollars(u.limitCents!))  " : ""
            print("Cursor  \(u.plan ?? "")  [\(u.source)]")
            print("  本期包含额度 \(money)\(bar(u.percent)) \(Int(u.percent.rounded()))%  \(when) 重置（还有 \(countdown(u.cycleEnd, now: now))）")
            if let p = u.pooled { print("  \(p)") }
        case .err(let m): print("Cursor ⚠︎ \(m)")
        }
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
