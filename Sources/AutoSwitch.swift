// 自动切换规则与提前重置检测

import AppKit
import CryptoKit
import Foundation
import SQLite3

// MARK: - 自动切换规则

struct AutoSwitchDecision { let target: String?; let reason: String }

func sessionWindow(_ a: ClaudeAccount) -> UsageWindow? { a.windows.first { $0.label.hasPrefix("5") } }
func weeklyWindow(_ a: ClaudeAccount) -> UsageWindow? { a.windows.first { $0.label == "每周（全部模型）" } }

/// 规则（三种重置都算）：
/// - 能用：5 小时窗口 < 99% 且 每周（全部模型）< 99%，且没有报错（≥99% 视为用完）
/// - 先用哪个："作废速度" = 每周剩余% ÷ 距每周重置的小时数（越大越该先用，不用就浪费），
///   5 小时窗口快满的账号打折（乘 0.5 + 0.5×5 小时剩余比例）
/// - 当前只是 5 小时窗口满了、每周还有余量、且 5 分钟内就重置：先等，不切
/// - 当前还能用时，只有别人的作废速度 ≥ 当前 1.5 倍、每周重置早 12 小时以上、每周还剩 ≥10%，才主动换（防来回切）
/// - 官方提前重置会直接体现在新的百分比与 resets_at 里，下一次判断自然生效
func decideAutoSwitch(_ accounts: [ClaudeAccount], now: Date, pinnedDir: String? = nil) -> AutoSwitchDecision {
    func sess(_ a: ClaudeAccount) -> Double { sessionWindow(a).map { effective($0, now).pct } ?? 0 }
    func week(_ a: ClaudeAccount) -> Double { weeklyWindow(a).map { effective($0, now).pct } ?? 0 }
    func usable(_ a: ClaudeAccount) -> Bool { a.error == nil && !a.windows.isEmpty && sess(a) < 99 && week(a) < 99 }
    func weeklyReset(_ a: ClaudeAccount) -> Date { weeklyWindow(a)?.resetsAt ?? now.addingTimeInterval(7 * 86400) }
    func hoursLeft(_ d: Date) -> Double { max(d.timeIntervalSince(now) / 3600, 1) }
    func urgency(_ a: ClaudeAccount) -> Double {
        let base = (100 - week(a)) / hoursLeft(weeklyReset(a))
        return base * (0.5 + 0.5 * (100 - sess(a)) / 100)
    }
    func fmtU(_ x: Double) -> String { String(format: "%.1f", x) }

    guard let cur = accounts.first(where: { $0.active }) else { return AutoSwitchDecision(target: nil, reason: "没有在用的托管账号") }
    let candidates = accounts.filter { !$0.active && usable($0) && $0.configDir != nil }
        .sorted { (urgency($0), -sess($0)) > (urgency($1), -sess($1)) }

    if !usable(cur) {
        // 只是 5 小时窗口满了、每周还有、马上重置：等一下
        if cur.error == nil, week(cur) < 99, let sw = sessionWindow(cur), let r = sw.resetsAt,
           r.timeIntervalSince(now) <= 5 * 60, r > now {
            return AutoSwitchDecision(target: nil, reason: "\(cur.label) 的 5 小时窗口 \(max(Int(r.timeIntervalSince(now) / 60), 1)) 分钟后重置，先等")
        }
        guard let best = candidates.first else { return AutoSwitchDecision(target: nil, reason: "\(cur.label) 用完了，但没有其他可用账号") }
        return AutoSwitchDecision(target: best.configDir,
            reason: "\(cur.label) 用完了（5 小时 \(Int(sess(cur)))%，每周 \(Int(week(cur)))%），切到 \(best.label)（每周剩 \(100 - Int(week(best)))%，\(countdown(weeklyReset(best), now: now))后重置）")
    }
    guard let best = candidates.first else { return AutoSwitchDecision(target: nil, reason: "\(cur.label) 还能用；没有其他可用账号") }
    if let pin = pinnedDir, pin == cur.configDir {
        return AutoSwitchDecision(target: nil, reason: "\(cur.label) 是你手动选的，用完前不自动换")
    }
    let gap = weeklyReset(cur).timeIntervalSince(weeklyReset(best))
    if urgency(best) >= 1.5 * urgency(cur) && gap > 12 * 3600 && week(best) <= 90 {
        return AutoSwitchDecision(target: best.configDir,
            reason: "\(best.label) 的每周额度先作废（早 \(Int(gap / 3600)) 小时重置，还剩 \(100 - Int(week(best)))%，作废速度 \(fmtU(urgency(best))) vs \(fmtU(urgency(cur)))），先用它")
    }
    return AutoSwitchDecision(target: nil, reason: "\(cur.label) 还能用，暂不切换")
}

/// 官方提前重置检测：同一账号两次读数之间，用量明显下降、而原定重置时间还没到
struct WindowSeen { let pct: Double; let resetsAt: Date? }
func detectEarlyResets(previous: [String: WindowSeen], accounts: [ClaudeAccount], now: Date) -> (events: [String], seen: [String: WindowSeen]) {
    var seen: [String: WindowSeen] = [:]
    var events: [String] = []
    for a in accounts where a.error == nil {
        for w in a.windows where w.label.hasPrefix("5") || w.label == "每周（全部模型）" {
            let key = a.email + "|" + w.label
            let pct = effective(w, now).pct
            if let old = previous[key], let oldReset = old.resetsAt,
               old.pct - pct >= 15, now < oldReset.addingTimeInterval(-600) {
                events.append("\(a.label) 的\(w.label)提前重置了（\(Int(old.pct))% → \(Int(pct))%，原定 \(clockFmt.string(from: oldReset))）")
            }
            seen[key] = WindowSeen(pct: pct, resetsAt: w.resetsAt)
        }
    }
    return (events, seen)
}
