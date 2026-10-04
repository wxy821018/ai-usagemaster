// 每个账号的"上次成功数据 + 查询节奏 + 限流退避"，存盘（只有数字和时间，不含令牌）
// 用量接口有频率限制（Claude Code 自己的 /usage 也缓存 5 分钟），查太勤会被 429：
//   在用账号至少隔 5 分钟查一次，其他账号 15 分钟，手动刷新至少隔 60 秒；
//   被 429 时按 Retry-After 退避（至少 5 分钟，连续被限流时翻倍，最多 30 分钟），期间显示上次的数据。

import Foundation

struct CachedWindow: Codable {
    var label: String
    var percent: Double
    var resetsAt: Date?
    var kind: String?
    var severity: String?
    var isActive: Bool?
    var scope: String?
}

struct CachedAccount: Codable {
    var windows: [CachedWindow] = []
    var extraKeys: [String] = []
    var notes: [String]? = nil
    var failure: String? = nil       // 上次请求的"硬"失败（需要重新登录等）；成功时清掉。限流轮次不发请求时靠它还原状态
    var needsLogin: Bool? = nil
    var fetchedAt: Date?             // 上次成功拿到数据的时间
    var attemptedAt: Date?           // 上次发出请求的时间（成功失败都算）
    var retryAfter: Date?            // 被限流时，这个时间之前不再请求
    var backoff: TimeInterval = 0    // 当前退避时长
}

final class UsageCache: @unchecked Sendable {
    static let shared = UsageCache()
    private let lock = NSLock()
    private var map: [String: CachedAccount] = [:]
    private let url: URL = {
        let dir = URL(fileURLWithPath: appDataDir, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("claude_usage_cache.json")
    }()

    private init() {
        if let d = try? Data(contentsOf: url),
           let m = try? JSONDecoder().decode([String: CachedAccount].self, from: d) { map = m }
    }

    private func save() {
        guard let d = try? JSONEncoder().encode(map) else { return }
        try? d.write(to: url, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    func get(_ key: String) -> CachedAccount? { lock.lock(); defer { lock.unlock() }; return map[key] }

    /// 这次要不要真的发请求
    func shouldFetch(_ key: String, active: Bool, force: Bool, now: Date = Date()) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard let c = map[key] else { return true }
        if let r = c.retryAfter, now < r { return false }                 // 限流退避中，手动刷新也不破例
        let since = c.attemptedAt.map { now.timeIntervalSince($0) } ?? .infinity
        if force { return since >= 60 }
        return since >= (active ? 300 : 900)
    }

    func markAttempt(_ key: String, now: Date = Date()) {
        lock.lock(); defer { lock.unlock() }
        var c = map[key] ?? CachedAccount()
        c.attemptedAt = now
        map[key] = c
        save()
    }

    func storeSuccess(_ key: String, windows: [UsageWindow], extraKeys: [String], notes: [String]? = nil, now: Date = Date()) {
        lock.lock(); defer { lock.unlock() }
        var c = map[key] ?? CachedAccount()
        c.windows = windows.map { CachedWindow(label: $0.label, percent: $0.percent, resetsAt: $0.resetsAt,
                                               kind: $0.kind, severity: $0.severity, isActive: $0.isActive, scope: $0.scope) }
        c.extraKeys = extraKeys
        if let n = notes { c.notes = n }
        c.failure = nil
        c.needsLogin = nil
        c.fetchedAt = now
        c.attemptedAt = now
        c.retryAfter = nil
        c.backoff = 0
        map[key] = c
        save()
    }

    /// 记下硬失败（需要重新登录、令牌无效）
    func storeFailure(_ key: String, _ message: String, needsLogin: Bool) {
        lock.lock(); defer { lock.unlock() }
        var c = map[key] ?? CachedAccount()
        c.failure = message
        c.needsLogin = needsLogin
        map[key] = c
        save()
    }

    /// 被限流：返回下次可以请求的时间
    func storeRateLimited(_ key: String, retryAfterHeader: TimeInterval?, now: Date = Date()) -> Date {
        lock.lock(); defer { lock.unlock() }
        var c = map[key] ?? CachedAccount()
        let next = c.backoff > 0 ? min(c.backoff * 2, 1800) : 300
        c.backoff = max(next, min(retryAfterHeader ?? 0, 1800))
        let until = now.addingTimeInterval(c.backoff)
        c.retryAfter = until
        c.attemptedAt = now
        map[key] = c
        save()
        return until
    }

    /// 用缓存的数字还原窗口（重置时间已过的按 0 处理）
    func windows(_ key: String, now: Date = Date()) -> [UsageWindow] {
        (get(key)?.windows ?? []).map { c in
            let (kind, scope) = c.kind != nil ? (c.kind, c.scope) : legacyKind(c.label)
            return makeWindow(windowLabel(kind: kind, scope: scope, fallback: c.label),
                              percent: c.percent, resetsAt: c.resetsAt, now: now,
                              kind: kind, severity: c.severity, isActive: c.isActive ?? false, scope: scope)
        }
    }

    /// 早期版本的缓存只存了中文标签，没有 kind：按标签推断
    private func legacyKind(_ label: String) -> (String?, String?) {
        if label.hasPrefix("5") { return ("session", nil) }
        if label == "每周（全部模型）" { return ("weekly_all", nil) }
        if label.hasPrefix("每周（"), label.hasSuffix("）") {
            return ("weekly_scoped", String(label.dropFirst(3).dropLast()))
        }
        return (nil, nil)
    }
}

/// 解析 Retry-After：秒数或 HTTP 日期
func retryAfterSeconds(_ resp: URLResponse?) -> TimeInterval? {
    guard let h = (resp as? HTTPURLResponse)?.value(forHTTPHeaderField: "Retry-After") else { return nil }
    if let s = Double(h.trimmingCharacters(in: .whitespaces)) { return s }
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
    return f.date(from: h).map { max($0.timeIntervalSinceNow, 0) }
}

enum UsageFetchResult {
    case ok([String: Any])
    case rateLimited(TimeInterval?)
    case unauthorized
    case http(Int)
    case failure(String)
}

/// 发一次用量请求（带上统一的错误分类）
func requestUsage(token: String) async -> UsageFetchResult {
    do {
        let (body, resp) = try await session.data(for: usageRequest(token: token))
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        switch code {
        case 200:
            guard let d = try JSONSerialization.jsonObject(with: body) as? [String: Any] else { return .failure(L("返回格式变了，解析不出用量", "Unexpected response format, could not read usage")) }
            return .ok(d)
        case 429: return .rateLimited(retryAfterSeconds(resp))
        case 401: return .unauthorized
        default: return .http(code)
        }
    } catch {
        return .failure(describe(error))
    }
}
