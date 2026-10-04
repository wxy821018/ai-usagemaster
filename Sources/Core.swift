// 数据模型与通用工具：网络会话（不落盘）、钥匙串读写、时间格式化、子进程

import AppKit
import CryptoKit
import Foundation
import SQLite3

// MARK: - 界面语言

/// 界面语言跟随系统：系统首选语言是中文就显示中文，否则显示英文。
/// 环境变量 AIUM_LANG=zh / en 可临时指定（自检、截图用）。
let isChinese: Bool = {
    if let o = ProcessInfo.processInfo.environment["AIUM_LANG"], !o.isEmpty { return o.lowercased().hasPrefix("zh") }
    return (Locale.preferredLanguages.first ?? "en").lowercased().hasPrefix("zh")
}()

/// 双语文案：L("中文", "English")
func L(_ zh: String, _ en: String) -> String { isChinese ? zh : en }

/// 中文用顿号，英文用逗号
var listSep: String { L("、", ", ") }

// MARK: - 数据模型

struct UsageWindow {
    let label: String
    let percent: Double        // 0–100（已按"重置时间已过 → 视为 0"修正）
    let resetsAt: Date?
    let wasReset: Bool         // 数据里的重置时间已经过了
    var kind: String? = nil    // 服务端 limits[].kind：session / weekly_all / weekly_scoped（按它分类，不看标签文字）
    var severity: String? = nil // 服务端判定的严重程度：normal / warning / critical（颜色直接用它）
    var isActive: Bool = false // 服务端标出的"当前卡住你的那一行"
    var scope: String? = nil   // weekly_scoped 的范围名（模型名，如 Fable）
}

struct ClaudeAccount {
    var label: String          // 菜单栏短名：FF / OP / 个人 …
    var email: String
    var org: String
    var active: Bool
    var windows: [UsageWindow] = []
    var updatedAt: Date?
    var source: String         // "direct" / "statusline"
    var error: String?
    var configDir: String? = nil
    var needsLogin = false
    var extraKeys: [String] = []     // 用量返回里非空的额外额度项（官方活动/临时额度的信号）
    var warning: String? = nil       // 暂时性问题（被限流、网络断）：数字来自上次成功的缓存，仍可用
    var notes: [String] = []         // 额外信息：超额用量、可用重置次数等（只读展示）
    var plan: String? = nil          // 套餐：Max 20x / Max 5x / Team / Pro
    var key: String = ""             // 身份：邮箱|组织 uuid（同一邮箱可在多个组织）
    var sharedWithOrca = false       // 我们这份刷新令牌和 Orca 的是同一个（不能在这里刷新，要重新登录）
    /// 按账号存的状态、去重 key 一律用它，不要只用邮箱
    var ident: String { key.isEmpty ? email : key }

    /// 最紧的那个窗口（用来在菜单栏上显示）
    var binding: UsageWindow? { windows.max(by: { $0.percent < $1.percent }) }
}

struct CursorUsage {
    var plan: String?
    var usedCents: Int?
    var limitCents: Int?
    var percent: Double = 0
    var cycleEnd: Date?
    var pooled: String?
    var source: String = "direct"
}

enum Fetch<T> {
    case ok(T)
    case err(String)
    case notConfigured          // 本机没装 / 没登录：不显示、不算错误、不重试
}

/// 不落盘的网络会话：URLSession.shared 默认会把请求（含 Authorization 头）写进 ~/Library/Caches 的 Cache.db，绝不能用
let session: URLSession = {
    let c = URLSessionConfiguration.ephemeral
    c.urlCache = nil
    c.httpCookieStorage = nil
    c.urlCredentialStorage = nil
    c.requestCachePolicy = .reloadIgnoringLocalCacheData
    c.timeoutIntervalForRequest = 10
    c.timeoutIntervalForResource = 20
    return URLSession(configuration: c, delegate: NoRedirect.shared, delegateQueue: nil)
}()

/// 把常见网络错误翻成简短的说明
func describe(_ error: Error) -> String {
    let ns = error as NSError
    if ns.domain == NSURLErrorDomain {
        switch ns.code {
        case NSURLErrorNotConnectedToInternet: return L("没联网", "No internet connection")
        case NSURLErrorTimedOut: return L("请求超时", "Request timed out")
        case NSURLErrorNetworkConnectionLost: return L("网络连接中断", "Network connection lost")
        case NSURLErrorCannotFindHost, NSURLErrorDNSLookupFailed: return L("域名解析失败", "DNS lookup failed")
        default: return L("网络错误（\(ns.code)）", "Network error (\(ns.code))")
        }
    }
    return ns.localizedDescription
}

// MARK: - 工具函数

func parseISO(_ v: Any?) -> Date? {
    guard let s = v as? String else { return nil }
    // resets_at 可能带 6 位小数秒（微秒），ISO8601DateFormatter 只认 3 位，先把小数部分截到 3 位
    let trimmed = s.replacingOccurrences(of: #"(\.\d{3})\d+"#, with: "$1", options: .regularExpression)
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let d = f.date(from: trimmed) { return d }
    f.formatOptions = [.withInternetDateTime]
    return f.date(from: trimmed)
}

func msDate(_ v: Any?) -> Date? {
    if let n = v as? NSNumber { return Date(timeIntervalSince1970: n.doubleValue / 1000) }
    if let s = v as? String, let ms = Double(s) { return Date(timeIntervalSince1970: ms / 1000) }
    return nil
}

/// 数字字段：proto3 JSON 里 int64 会以字符串返回，0 值会被省略
func num(_ v: Any?) -> Double? {
    if let n = v as? NSNumber { return n.doubleValue }
    if let s = v as? String { return Double(s) }
    return nil
}

/// 重置时间显示前取整到分钟（服务端给的是 03:59:58.87 这种，不取整会显示成 20:59）
func roundedMinute(_ d: Date?) -> Date? {
    guard let d = d else { return nil }
    return Date(timeIntervalSince1970: (d.timeIntervalSince1970 / 60).rounded() * 60)
}

func countdown(_ d: Date?, now: Date = Date()) -> String {
    guard let d = d else { return "—" }
    let s = Int(d.timeIntervalSince(now))
    if s <= 0 { return L("已到", "now") }
    let days = s / 86400, h = (s % 86400) / 3600, m = (s % 3600) / 60
    if days > 0 { return L("\(days)天\(h)小时", "\(days)d \(h)h") }
    if h > 0 { return L("\(h)小时\(m)分", "\(h)h \(m)m") }
    return L("\(max(m, 1))分", "\(max(m, 1))m")
}

func shortCountdown(_ d: Date?, now: Date = Date()) -> String {
    guard let d = d else { return "" }
    let s = Int(d.timeIntervalSince(now))
    if s <= 0 { return "" }
    let days = s / 86400, h = (s % 86400) / 3600, m = (s % 3600) / 60
    if days > 0 { return "\(days)d\(h)h" }
    if h > 0 { return "\(h)h\(String(format: "%02d", m))" }
    return "\(m)m"
}

func ago(_ d: Date?, now: Date = Date()) -> String {
    guard let d = d else { return L("时间未知", "unknown time") }
    let s = Int(now.timeIntervalSince(d))
    if s < 90 { return L("刚刚", "just now") }
    if s < 3600 { return L("\(s / 60) 分钟前", "\(s / 60) min ago") }
    if s < 86400 { return L("\(s / 3600) 小时前", "\(s / 3600) h ago") }
    return L("\(s / 86400) 天前", "\(s / 86400) days ago")
}

let clockFmt: DateFormatter = {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.dateFormat = "M/d HH:mm"
    return f
}()

func bar(_ pct: Double, width: Int = 10) -> String {
    let filled = max(0, min(width, Int((pct / 100 * Double(width)).rounded())))
    return String(repeating: "▓", count: filled) + String(repeating: "░", count: width - filled)
}

func dollars(_ cents: Int) -> String { String(format: "$%.2f", Double(cents) / 100) }

func shortLabel(email: String) -> String {
    let local = email.split(separator: "@").first.map(String.init) ?? email
    return String(local.prefix(8))
}

/// 账号显示名：账号目录里的 label 文件（自定义别名）优先，否则取邮箱前缀
func accountLabel(dir: String?, email: String) -> String {
    if let d = dir, let s = try? String(contentsOfFile: d + "/label", encoding: .utf8) {
        let v = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if !v.isEmpty { return v }
    }
    return shortLabel(email: email)
}

func makeWindow(_ label: String, percent: Double, resetsAt: Date?, now: Date = Date(),
                kind: String? = nil, severity: String? = nil, isActive: Bool = false, scope: String? = nil) -> UsageWindow {
    let r = roundedMinute(resetsAt)
    if let r = r, r < now { return UsageWindow(label: label, percent: 0, resetsAt: r, wasReset: true, kind: kind, scope: scope) }
    return UsageWindow(label: label, percent: percent, resetsAt: r, wasReset: false, kind: kind, severity: severity, isActive: isActive, scope: scope)
}

/// 窗口显示名：按服务端的 kind 生成，跟随界面语言
func windowLabel(kind: String?, scope: String? = nil, fallback: String = "") -> String {
    switch kind {
    case "session": return L("5 小时窗口", "5-hour window")
    case "weekly_all": return L("每周（全部模型）", "Weekly (all models)")
    case "weekly_scoped": return L("每周（\(scope ?? "指定范围")）", "Weekly (\(scope ?? "scoped"))")
    default: return fallback.isEmpty ? (kind ?? "") : fallback
    }
}

/// 判断窗口类型一律看 kind；旧缓存里没有 kind 时才按旧的中文标签判断
func isSessionWindow(_ w: UsageWindow) -> Bool { w.kind == "session" || (w.kind == nil && w.label.hasPrefix("5")) }
func isWeeklyAllWindow(_ w: UsageWindow) -> Bool { w.kind == "weekly_all" || (w.kind == nil && w.label == "每周（全部模型）") }
func isWeeklyWindow(_ w: UsageWindow) -> Bool { !isSessionWindow(w) }

/// 窗口总长度（算"已过去多少时间"用）
func windowLength(_ w: UsageWindow) -> TimeInterval { isSessionWindow(w) ? 5 * 3600 : 7 * 86400 }

/// "用得太快"：照 Claude Code 的规则——5 小时窗口用了 ≥90% 而时间才过去 ≤72%；
/// 每周窗口 (≥75%, ≤60%) 或 (≥50%, ≤35%)。返回提示文字与按当前速度用完的时间
func paceWarning(_ w: UsageWindow, now: Date = Date()) -> (text: String, exhaustAt: Date?)? {
    guard !w.wasReset, let r = w.resetsAt, r > now, w.percent > 0, w.percent < 99 else { return nil }
    let len = windowLength(w)
    let elapsed = max(0.0, min(1.0, 1 - r.timeIntervalSince(now) / len))
    guard elapsed > 0.01 else { return nil }
    let fast: Bool
    if len < 86400 { fast = w.percent >= 90 && elapsed <= 0.72 }
    else { fast = (w.percent >= 75 && elapsed <= 0.60) || (w.percent >= 50 && elapsed <= 0.35) }
    guard fast else { return nil }
    let ratePerSec = w.percent / (elapsed * len)                      // 平均速度
    let exhaust = now.addingTimeInterval((100 - w.percent) / ratePerSec)
    let at = exhaust < r ? exhaust : nil
    let text = L("用得太快：已用 \(Int(w.percent))%，时间才过去 \(Int(elapsed * 100))%", "Using it fast: \(Int(w.percent))% used with \(Int(elapsed * 100))% of the time gone")
        + (at.map { L("，按这个速度约 \(countdown($0, now: now))后用完", ", runs out in about \(countdown($0, now: now)) at this pace") } ?? "")
    return (text, at)
}

/// 颜色：优先用服务端判定的 severity，没有时退回 75% / 90% 阈值
func severityLevel(_ w: UsageWindow) -> Int {
    if !w.wasReset, let s = w.severity {
        switch s { case "critical": return 2; case "warning": return 1; default: return 0 }
    }
    return w.percent >= 90 ? 2 : (w.percent >= 75 ? 1 : 0)
}

/// 跑一个命令，带超时；返回 stdout。不经过 shell，不把参数暴露给日志。
func runCommand(_ path: String, _ args: [String], timeout: TimeInterval) -> Data? {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: path)
    p.arguments = args
    var env = ProcessInfo.processInfo.environment
    env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
    p.environment = env
    let out = Pipe()
    p.standardOutput = out
    p.standardError = FileHandle.nullDevice
    do { try p.run() } catch { return nil }
    let deadline = DispatchTime.now() + timeout
    let done = DispatchSemaphore(value: 0)
    var data = Data()
    DispatchQueue.global().async {
        data = out.fileHandleForReading.readDataToEndOfFile()
        done.signal()
    }
    if done.wait(timeout: deadline) == .timedOut {
        p.terminate()
        return nil
    }
    p.waitUntilExit()
    return p.terminationStatus == 0 ? data : nil
}

/// 不跟随重定向：防止 Authorization 头被带到别的域名
final class NoRedirect: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    static let shared = NoRedirect()
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
