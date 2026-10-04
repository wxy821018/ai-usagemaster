// 提醒：每轮刷新后判断要不要发系统通知。
// - 每种提醒可单独开关（菜单「提醒」）；同一件事在同一个重置周期里只提醒一次，记录存在 UserDefaults，重启也不重复。
// - 用 UNUserNotificationCenter 发（能点：建议切换的那几种，点通知就切过去）；没有通知权限时退回 osascript。
// - evaluateAlerts 是纯函数，--selftest 里有用例。

import AppKit
import Foundation
import UserNotifications

enum AlertType: String, CaseIterable {
    case threshold, pace, exhausted, allExhausted, recovered, expiring, relogin, cursor, resets, switched

    var menuTitle: String {
        switch self {
        case .threshold: return L("在用账号用到 80% / 95%", "Active account reaches 80% / 95%")
        case .pace: return L("用得太快", "Using quota fast")
        case .exhausted: return L("在用账号用完（手动模式下建议切到哪个）", "Active account used up (manual mode suggests a switch)")
        case .allExhausted: return L("所有账号都用完（告诉你最早几点恢复）", "All accounts used up (with the earliest recovery time)")
        case .recovered: return L("用完的账号恢复可用", "A used-up account is available again")
        case .expiring: return L("每周额度快作废、还剩不少", "Weekly quota about to expire unused")
        case .relogin: return L("账号需要重新登录", "An account needs to sign in again")
        case .cursor: return L("Cursor 用到 80% / 100%", "Cursor reaches 80% / 100%")
        case .resets: return L("提前重置、官方公告、新额度项", "Early resets, status notices, new quota items")
        case .switched: return L("自动切换了账号", "Automatic account switch")
        }
    }

    var enabled: Bool {
        get { UserDefaults.standard.object(forKey: "alert." + rawValue) as? Bool ?? true }
        nonmutating set { UserDefaults.standard.set(newValue, forKey: "alert." + rawValue) }
    }
}

struct AlertItem {
    let type: AlertType
    let key: String            // 去重用：同一个 key 只提醒一次
    let title: String
    let body: String
    var switchDir: String? = nil   // 点通知后切到这个账号
}

/// 能不能用：没报错、有数据、5 小时窗口和每周（全部模型）都 < 99%（与自动切换同一口径）
func accountUsable(_ a: ClaudeAccount, _ now: Date) -> Bool {
    guard a.error == nil, !a.windows.isEmpty else { return false }
    let s = sessionWindow(a).map { effective($0, now).pct } ?? 0
    let w = weeklyWindow(a).map { effective($0, now).pct } ?? 0
    return s < 99 && w < 99
}

/// 用完的账号什么时候恢复：卡住它的窗口里最晚的那个重置时间
func recoveryTime(_ a: ClaudeAccount, _ now: Date) -> Date? {
    [sessionWindow(a), weeklyWindow(a)].compactMap { $0 }
        .filter { effective($0, now).pct >= 99 }
        .compactMap { $0.resetsAt }.max()
}

private func minuteKey(_ d: Date?) -> String { d.map { String(Int($0.timeIntervalSince1970 / 60)) } ?? "-" }

private func whenText(_ d: Date?, _ now: Date) -> String {
    guard let d = d else { return L("时间未知", "unknown time") }
    return L("\(clockFmt.string(from: d))（还有 \(countdown(d, now: now))）", "\(clockFmt.string(from: d)) (in \(countdown(d, now: now)))")
}

/// 根据这一轮的数据算出应该发哪些提醒（不去重、不发送）。previousUsable：上一轮各账号能不能用，用来判断"恢复可用"
func evaluateAlerts(accounts: [ClaudeAccount], cursor: CursorUsage?, autoMode: Bool,
                    previousUsable: [String: Bool], now: Date) -> (alerts: [AlertItem], usable: [String: Bool]) {
    var out: [AlertItem] = []
    var usable: [String: Bool] = [:]
    let withData = accounts.filter { $0.error == nil && !$0.windows.isEmpty }
    for a in withData { usable[a.email] = accountUsable(a, now) }

    func pcts(_ a: ClaudeAccount) -> String {
        let s = Int(sessionWindow(a).map { effective($0, now).pct } ?? 0)
        let w = Int(weeklyWindow(a).map { effective($0, now).pct } ?? 0)
        return L("5 小时 \(s)%，每周 \(w)%", "5-hour \(s)%, weekly \(w)%")
    }

    // 在用账号：用量阈值、用得太快、用完
    if let cur = accounts.first(where: { $0.active }), cur.error == nil, !cur.windows.isEmpty {
        for w in [sessionWindow(cur), weeklyWindow(cur)].compactMap({ $0 }) {
            let (pct, reset) = effective(w, now)
            if reset { continue }
            let kind = isSessionWindow(w) ? "session" : "weekly_all"
            let level = pct >= 95 ? 95 : (pct >= 80 ? 80 : 0)
            if level > 0 && pct < 99 {
                out.append(AlertItem(type: .threshold, key: "th\(level)|\(cur.email)|\(kind)|\(minuteKey(w.resetsAt))",
                    title: L("\(cur.label) 的\(w.label)已用 \(Int(pct))%", "\(cur.label): \(w.label) at \(Int(pct))%"),
                    body: L("\(whenText(w.resetsAt, now)) 重置", "Resets \(whenText(w.resetsAt, now))")))
            }
            if let pw = paceWarning(w, now: now) {
                out.append(AlertItem(type: .pace, key: "pace|\(cur.email)|\(kind)|\(minuteKey(w.resetsAt))",
                    title: L("\(cur.label) 的\(w.label)用得太快", "\(cur.label): \(w.label) is going fast"), body: pw.text))
            }
        }
        if usable[cur.email] == false && !autoMode {
            let d = decideAutoSwitch(accounts, now: now, pinnedDir: nil)
            let rec = recoveryTime(cur, now)
            if let dir = d.target, let best = accounts.first(where: { $0.configDir == dir }) {
                out.append(AlertItem(type: .exhausted, key: "exh|\(cur.email)|\(minuteKey(rec))",
                    title: L("\(cur.label) 用完了", "\(cur.label) is used up"),
                    body: L("\(whenText(rec, now)) 恢复。点这条通知切到 \(best.label)（\(pcts(best))）",
                            "Back \(whenText(rec, now)). Click to switch to \(best.label) (\(pcts(best)))"),
                    switchDir: dir))
            }
        }
    }

    // 所有账号都用完
    if !withData.isEmpty && withData.allSatisfy({ usable[$0.email] == false }) {
        let earliest = withData.compactMap { a in recoveryTime(a, now).map { (a, $0) } }.min { $0.1 < $1.1 }
        out.append(AlertItem(type: .allExhausted, key: "all|\(minuteKey(earliest?.1))",
            title: L("所有 Claude 账号都用完了", "Every Claude account is used up"),
            body: earliest.map { L("最早恢复的是 \($0.0.label)：\(whenText($0.1, now))", "First back: \($0.0.label), \(whenText($0.1, now))") }
                ?? L("恢复时间未知", "Recovery time unknown")))
    }

    for a in withData {
        // 恢复可用
        if usable[a.email] == true && previousUsable[a.email] == false {
            let canSwitch = !a.active && !autoMode && a.configDir != nil
            out.append(AlertItem(type: .recovered, key: "rec|\(a.email)|\(Int(now.timeIntervalSince1970 / 3600))",
                title: L("\(a.label) 可以用了", "\(a.label) is available again"),
                body: pcts(a) + (canSwitch ? L("。点这条通知切换过去", ". Click to switch to it") : ""),
                switchDir: canSwitch ? a.configDir : nil))
        }
        // 每周额度快作废、还剩不少（24 小时内重置、还剩 ≥30%）
        if let w = weeklyWindow(a), let r = w.resetsAt, r > now, r.timeIntervalSince(now) <= 24 * 3600 {
            let left = 100 - Int(effective(w, now).pct)
            if left >= 30 {
                let canSwitch = !a.active && !autoMode && a.configDir != nil && usable[a.email] == true
                out.append(AlertItem(type: .expiring, key: "exp|\(a.email)|\(minuteKey(r))",
                    title: L("\(a.label) 的每周额度还剩 \(left)%，快作废了", "\(a.label) still has \(left)% of its week left"),
                    body: L("\(whenText(r, now)) 重置，没用完的就没了", "It resets \(whenText(r, now)) and unused quota is lost")
                        + (canSwitch ? L("。点这条通知切过去先用它", ". Click to switch and use it first") : ""),
                    switchDir: canSwitch ? a.configDir : nil))
            }
        }
    }

    // 需要重新登录
    for a in accounts where a.needsLogin {
        out.append(AlertItem(type: .relogin, key: "relogin|\(a.email)",
            title: L("\(a.label) 需要重新登录", "\(a.label) needs to sign in again"),
            body: a.error ?? L("在菜单里点「重新登录」", "Choose Sign In Again in the menu")))
    }

    // Cursor
    if let u = cursor {
        let level = u.percent >= 100 ? 100 : (u.percent >= 80 ? 80 : 0)
        if level > 0 {
            out.append(AlertItem(type: .cursor, key: "cursor\(level)|\(minuteKey(u.cycleEnd))",
                title: L("Cursor 本期额度已用 \(Int(u.percent))%", "Cursor: \(Int(u.percent))% of this cycle's included usage"),
                body: L("账单周期 \(whenText(u.cycleEnd, now)) 重置", "Billing cycle resets \(whenText(u.cycleEnd, now))")))
        }
    }
    return (out, usable)
}

// MARK: - 发送

@MainActor
final class AlertCenter: NSObject, UNUserNotificationCenterDelegate {
    static let shared = AlertCenter()
    var onSwitch: ((String) -> Void)?
    private var previousUsable: [String: Bool] = [:]
    private var authorized: Bool?

    /// 已经提醒过的 key → 时间（10 天后清掉）
    private var fired: [String: Double] {
        get { UserDefaults.standard.dictionary(forKey: "alertFired") as? [String: Double] ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: "alertFired") }
    }

    func setup() {
        let c = UNUserNotificationCenter.current()
        c.delegate = self
        let action = UNNotificationAction(identifier: "SWITCH", title: L("切换", "Switch"), options: [])
        c.setNotificationCategories([UNNotificationCategory(identifier: "SWITCH", actions: [action], intentIdentifiers: [], options: [])])
        c.requestAuthorization(options: [.alert, .sound]) { ok, _ in
            Task { @MainActor in self.authorized = ok }
        }
    }

    /// 每轮刷新后调用
    func process(accounts: [ClaudeAccount], cursor: CursorUsage?, autoMode: Bool) {
        let now = Date()
        let (alerts, usable) = evaluateAlerts(accounts: accounts, cursor: cursor, autoMode: autoMode,
                                              previousUsable: previousUsable, now: now)
        previousUsable.merge(usable) { $1 }
        var f = fired.filter { now.timeIntervalSince1970 - $0.value < 10 * 86400 }
        for a in accounts where !a.needsLogin { f.removeValue(forKey: "relogin|\(a.email)") }   // 登录好了，下次失效还会再提醒
        for a in alerts where f[a.key] == nil {
            f[a.key] = now.timeIntervalSince1970          // 关掉的类型也记一笔：之后再打开不会补发一堆旧提醒
            if a.type.enabled { deliver(a) }
        }
        fired = f
    }

    /// 事件型提醒（提前重置、官方公告、自动切换）：调用方已经去过重
    func post(_ type: AlertType, _ title: String, _ body: String) {
        guard type.enabled else { return }
        deliver(AlertItem(type: type, key: "\(type.rawValue)|\(UUID().uuidString)", title: title, body: body))
    }

    func sendTest() {
        deliver(AlertItem(type: .resets, key: "test|\(UUID().uuidString)", title: "AI UsageMaster",
                          body: L("这是一条测试提醒。能看到它，提醒就能正常送达。", "This is a test notification. If you can see it, notifications work.")))
    }

    private func deliver(_ a: AlertItem) {
        if authorized == false { fallback(a); return }
        let content = UNMutableNotificationContent()
        content.title = a.title
        content.body = a.body
        content.sound = .default
        if let d = a.switchDir {
            content.categoryIdentifier = "SWITCH"
            content.userInfo = ["dir": d]
        }
        let req = UNNotificationRequest(identifier: a.key, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(req) { err in
            if err != nil { Task { @MainActor in self.fallback(a) } }
        }
    }

    private func fallback(_ a: AlertItem) {
        let esc = { (s: String) in s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") }
        _ = runCommand("/usr/bin/osascript", ["-e", "display notification \"\(esc(a.body))\" with title \"\(esc(a.title))\""], timeout: 5)
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        let dir = response.notification.request.content.userInfo["dir"] as? String
        let id = response.actionIdentifier
        if let d = dir, id == "SWITCH" || id == UNNotificationDefaultActionIdentifier {
            Task { @MainActor in self.onSwitch?(d) }
        }
        completionHandler()
    }
}
