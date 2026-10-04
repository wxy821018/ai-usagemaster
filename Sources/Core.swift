// 数据模型与通用工具：网络会话（不落盘）、钥匙串读写、时间格式化、子进程

import AppKit
import CryptoKit
import Foundation
import SQLite3

// MARK: - 数据模型

struct UsageWindow {
    let label: String
    let percent: Double        // 0–100（已按"重置时间已过 → 视为 0"修正）
    let resetsAt: Date?
    let wasReset: Bool         // 数据里的重置时间已经过了
}

struct ClaudeAccount {
    var label: String          // 菜单栏短名：FF / OP / 个人 …
    var email: String
    var org: String
    var active: Bool
    var windows: [UsageWindow] = []
    var updatedAt: Date?
    var source: String         // "直连"
    var error: String?
    var configDir: String? = nil
    var needsLogin = false
    var extraKeys: [String] = []     // 用量返回里非空的额外额度项（官方活动/临时额度的信号）
    var warning: String? = nil       // 暂时性问题（被限流、网络断）：数字来自上次成功的缓存，仍可用

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
    var source: String = "直连"
}

enum Fetch<T> {
    case ok(T)
    case err(String)
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

/// 把常见网络错误翻成简短中文
func describe(_ error: Error) -> String {
    let ns = error as NSError
    if ns.domain == NSURLErrorDomain {
        switch ns.code {
        case NSURLErrorNotConnectedToInternet: return "没联网"
        case NSURLErrorTimedOut: return "请求超时"
        case NSURLErrorNetworkConnectionLost: return "网络连接中断"
        case NSURLErrorCannotFindHost, NSURLErrorDNSLookupFailed: return "域名解析失败"
        default: return "网络错误（\(ns.code)）"
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
    if s <= 0 { return "已到" }
    let days = s / 86400, h = (s % 86400) / 3600, m = (s % 3600) / 60
    if days > 0 { return "\(days)天\(h)小时" }
    if h > 0 { return "\(h)小时\(m)分" }
    return "\(max(m, 1))分"
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
    guard let d = d else { return "时间未知" }
    let s = Int(now.timeIntervalSince(d))
    if s < 90 { return "刚刚" }
    if s < 3600 { return "\(s / 60) 分钟前" }
    if s < 86400 { return "\(s / 3600) 小时前" }
    return "\(s / 86400) 天前"
}

let clockFmt: DateFormatter = {
    let f = DateFormatter()
    f.locale = Locale(identifier: "zh_CN")
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

func makeWindow(_ label: String, percent: Double, resetsAt: Date?, now: Date = Date()) -> UsageWindow {
    let r = roundedMinute(resetsAt)
    if let r = r, r < now { return UsageWindow(label: label, percent: 0, resetsAt: r, wasReset: true) }
    return UsageWindow(label: label, percent: percent, resetsAt: r, wasReset: false)
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
