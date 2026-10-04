// 用量历史与统计：把每次抓到的百分比追加进 history.jsonl，据此算消耗速度、预测用完时间、统计"重置时还剩多少没用"、每日消耗。
// 本模块只做本地统计，不涉及任何服务协议，也没有参考 Orca（MIT，Copyright (c) 2026 Lovecast Inc.）的代码。
//
// 文件：<appDataDir>/history.jsonl（macOS ~/Library/Application Support/UsageMaster，Windows %APPDATA%\UsageMaster；权限 600），每行一条：
//   {"a":"账号","k":"weekly","p":42.5,"r":1790000000,"s":"claude","t":1789990000,"w":"weekly_all"}
//   t = 读数时间、r = 该窗口的重置时间（Unix 秒，可缺省）、p = 已用百分比、k = 窗口类别（WindowKind，可缺省）。超过 5MB 时丢掉最旧的一半。
// 文件里存的账号与窗口都是标识，不存随界面语言变化的文字；显示时用 historyWindowName / historyAccountName 换成当前语言。
// "重置周期"的划分（消耗速度、浪费统计、每日消耗共用）：相邻两条读数之间，
//   - 前一条的重置时间已经到了 → 按时重置；
//   - 读数掉了 5 个百分点以上、原定重置时间还没到 → 官方提前重置；
//   - 其余情况（含重置时间几秒到几分钟的抖动、滚动窗口的重置时间缓慢后移）都算同一个周期。

import Foundation

// MARK: - 数据模型

struct HistoryEntry: Equatable {
    var ts: Date               // 读数时间
    var service: String        // 服务 id：claude / cursor / codex …
    var account: String        // 账号的稳定标识（邮箱、账号 id），不要用可改的别名，也不要用随界面语言变化的文字
    var window: String         // 窗口标识（分组、去重都按它，会写进文件）：Claude 用服务端 kind（session / weekly_all / weekly_scoped:范围）；
                               // 其它服务的 ServiceWindow 没有语言无关的标识，暂用显示名。显示时用 historyWindowName
    var percent: Double        // 已用百分比 0–100
    var resetsAt: Date?        // 这个窗口的重置时间
    var kind: WindowKind? = nil // 窗口类别（语言无关）：浪费统计按它挑出每周窗口，不看文字
}

/// 一次"重置时还剩 X% 没用"
struct WasteItem: Equatable {
    var service: String
    var account: String
    var window: String
    var resetAt: Date
    var leftoverPercent: Double
    var lastReadingAt: Date    // 重置前最后一次读数的时间（离重置越近越准）
    var early: Bool = false    // 官方提前重置：resetAt 取的是发现读数突降的那次读数时间（实际重置在它之前）
}

// MARK: - 参数

/// 历史文件位置。测试可改成临时文件；各函数也都接受 file: 参数
var historyFileURL = URL(fileURLWithPath: appDataDir + "/history.jsonl")
/// 文件超过这个大小就丢掉最旧的一半
var historyMaxBytes = 5 * 1024 * 1024
let historyMinInterval: TimeInterval = 60          // 同一窗口两次记录至少隔 60 秒
let historyHeartbeat: TimeInterval = 30 * 60       // 数值没变时，隔 30 分钟仍补记一条，消耗速度才看得出"停用了"
let historySameResetTolerance: TimeInterval = 300  // 去重时重置时间差 5 分钟内视为没变（按"还剩 N 秒"换算的服务会抖）
let historyDropThreshold: Double = 5               // 同一周期内读数降 5 个百分点以上，视为官方提前重置
let historyBurnWindow: TimeInterval = 90 * 60      // 消耗速度只看最近 90 分钟
let historyBurnMinSpan: TimeInterval = 15 * 60     // 且这些点至少跨 15 分钟
let historyWasteMaxGap: TimeInterval = 24 * 3600   // 最后读数离重置超过 24 小时：之后又用了多少不知道，不计入浪费

// MARK: - 对外接口

/// 追加一批读数。同一 (服务, 账号, 窗口) 距上次记录不足 60 秒、或数值与重置时间都没变（且不足 30 分钟）就跳过；
/// 重置时间已过的读数（"已重置、等新数据"时补的 0%）不是真读数，也跳过。返回实际写入的条数。
@discardableResult
func recordSnapshot(entries: [HistoryEntry], file: URL = historyFileURL, maxBytes: Int = historyMaxBytes) -> Int {
    HistoryStore.shared.record(entries, file: file, maxBytes: maxBytes)
}

/// 读出 since 之后的全部读数，按时间升序；坏行跳过
func loadHistory(since: Date, file: URL = historyFileURL) -> [HistoryEntry] {
    HistoryStore.shared.byKey(file).values.flatMap { $0 }.filter { $0.ts >= since }
        .sorted { ($0.ts, $0.service, $0.account, $0.window) < ($1.ts, $1.service, $1.account, $1.window) }
}

/// 消耗速度（%/小时）：当前重置周期内、最近 90 分钟的点做最小二乘直线拟合。
/// 点少于 3 个、跨度不足 15 分钟、周期已过重置点、拟合出负值 → nil
func burnRate(service: String, account: String, window: String, now: Date, file: URL = historyFileURL) -> Double? {
    historyBurnRate(HistoryStore.shared.points(historyKey(service, account, window), file), now: now)
}

/// 按当前速度推到 100% 的时间；重置前用不完（或速度 ≤ 0）→ nil；已经 ≥100% → now
func projectedExhaustion(currentPercent: Double, rate: Double, resetsAt: Date?, now: Date) -> Date? {
    guard currentPercent.isFinite, rate.isFinite else { return nil }
    if let r = resetsAt, r <= now { return nil }
    if currentPercent >= 100 { return now }
    guard rate > 0 else { return nil }
    let t = now.addingTimeInterval((100 - currentPercent) / rate * 3600)
    if let r = resetsAt, t >= r { return nil }
    return t
}

/// 最近 days 天里，每个每周窗口（kind == .weekly）每次重置时还剩多少没用。按重置时间倒序（最新在前）
func wasteReport(days: Int, now: Date, file: URL = historyFileURL) -> [WasteItem] {
    guard days > 0 else { return [] }
    let from = now.addingTimeInterval(-Double(days) * 86400)
    var out: [WasteItem] = []
    for (_, pts) in HistoryStore.shared.byKey(file) {
        guard pts.first?.kind == .weekly else { continue }
        out += historyWaste(pts.filter { $0.ts <= now }, now: now).filter { $0.resetAt > from }
    }
    return out.sorted { ($0.resetAt, $0.service, $0.account) > ($1.resetAt, $1.service, $1.account) }
}

/// 按自然日（calendar 的时区）累加百分点消耗，含今天共 days 天、旧在前。
/// 同一周期内只累加上涨（小幅回落记 0）；按时重置后的第一条记它本身的值（从 0 涨上来的）；
/// 读数突降（官方提前重置或滚动窗口回落）那一条记 0，避免把回落当成消耗
func dailyUsage(service: String, account: String, window: String, days: Int, now: Date,
                calendar: Calendar = .current, file: URL = historyFileURL) -> [(day: Date, consumed: Double)] {
    historyDaily(HistoryStore.shared.points(historyKey(service, account, window), file), days: days, now: now, calendar: calendar)
}

// MARK: - 抓取结果 → 历史记录（集成时用）

/// Claude：跳过报错的账号、已过重置点的窗口。账号标识用 邮箱（+ 组织名，同一邮箱可在多个组织）
func historyEntries(claude accounts: [ClaudeAccount], at now: Date) -> [HistoryEntry] {
    var out: [HistoryEntry] = []
    for a in accounts where a.error == nil {
        let acct = historyClaudeAccountID(a)
        for w in a.windows where !w.wasReset {
            out.append(HistoryEntry(ts: now, service: "claude", account: acct, window: historyWindowID(w), percent: w.percent,
                                    resetsAt: w.resetsAt, kind: isSessionWindow(w) ? .session : .weekly))
        }
    }
    return out
}

/// Claude 账号的标识（写入与查询共用同一个口径）：邮箱，有组织名时加上组织名
func historyClaudeAccountID(_ a: ClaudeAccount) -> String {
    a.org.isEmpty ? a.email : "\(a.email) · \(a.org)"
}

/// Claude 窗口的标识：按服务端 kind，不用跟随界面语言的标签；旧缓存没有 kind 时用 Core 里按旧标签的判断
func historyWindowID(_ w: UsageWindow) -> String {
    if let k = w.kind {
        if k == "weekly_scoped" { return w.scope.map { "weekly_scoped:" + $0 } ?? k }
        return k
    }
    if isSessionWindow(w) { return "session" }
    if isWeeklyAllWindow(w) { return "weekly_all" }
    return w.label
}

/// 其它服务：跳过未配置、报错的账号与百分比未知的窗口
func historyEntries(service s: ServiceStatus, at now: Date) -> [HistoryEntry] {
    guard s.configured else { return [] }
    var out: [HistoryEntry] = []
    for a in s.accounts where a.error == nil {
        for w in a.windows {
            guard let p = w.percent else { continue }
            out.append(HistoryEntry(ts: now, service: s.id, account: a.id, window: w.label, percent: p, resetsAt: w.resetsAt, kind: w.kind))
        }
    }
    return out
}

func historyEntries(cursor u: CursorUsage, at now: Date) -> [HistoryEntry] {
    [HistoryEntry(ts: now, service: "cursor", account: historyCursorAccount, window: historyCursorWindow, percent: u.percent,
                  resetsAt: u.cycleEnd, kind: .monthly)]
}

// MARK: - 显示名（文件里存的是标识，显示时才换成当前界面语言）

let historyCursorAccount = "default"     // Cursor 只有一个账号
let historyCursorWindow = "included"     // Cursor 的本期包含额度

/// 窗口标识 → 显示名
func historyWindowName(service: String, window: String) -> String {
    if service == "cursor" && window == historyCursorWindow { return L("本期包含额度", "Included this cycle") }
    guard service == "claude" else { return window }
    let scoped = "weekly_scoped:"
    if window.hasPrefix(scoped) { return windowLabel(kind: "weekly_scoped", scope: String(window.dropFirst(scoped.count))) }
    return windowLabel(kind: window)     // session / weekly_all / weekly_scoped；不认识的（旧标签）原样返回
}

/// 账号标识 → 显示名
func historyAccountName(service: String, account: String) -> String {
    service == "cursor" && account == historyCursorAccount ? L("默认账号", "Default account") : account
}

// MARK: - 统计（纯函数，输入是同一窗口按时间升序的读数）

private enum CycleEnd { case open, scheduled, early }

private struct Cycle {
    var points: [HistoryEntry]
    var end: CycleEnd = .open
    var nextStart: Date? = nil     // 下一个周期第一条读数的时间
}

private func cycleBreak(_ prev: HistoryEntry, _ cur: HistoryEntry) -> CycleEnd {
    if let r = prev.resetsAt, r <= cur.ts { return .scheduled }
    if cur.percent < prev.percent - historyDropThreshold { return .early }
    return .open
}

private func splitCycles(_ pts: [HistoryEntry]) -> [Cycle] {
    var cycles: [Cycle] = []
    for p in pts {
        if let prev = cycles.last?.points.last {
            let b = cycleBreak(prev, p)
            if b == .open { cycles[cycles.count - 1].points.append(p); continue }
            cycles[cycles.count - 1].end = b
            cycles[cycles.count - 1].nextStart = p.ts
        }
        cycles.append(Cycle(points: [p]))
    }
    return cycles
}

private func historyBurnRate(_ all: [HistoryEntry], now: Date) -> Double? {
    guard let cur = splitCycles(all.filter { $0.ts <= now }).last, let last = cur.points.last else { return nil }
    if let r = last.resetsAt, r <= now { return nil }                 // 这个周期已经过了重置点
    let pts = cur.points.filter { $0.ts >= now.addingTimeInterval(-historyBurnWindow) }
    guard pts.count >= 3, let first = pts.first, let end = pts.last,
          end.ts.timeIntervalSince(first.ts) >= historyBurnMinSpan else { return nil }
    let n = Double(pts.count)
    var sx = 0.0, sy = 0.0, sxx = 0.0, sxy = 0.0
    for p in pts {
        let x = p.ts.timeIntervalSince(first.ts)
        sx += x; sy += p.percent; sxx += x * x; sxy += x * p.percent
    }
    let den = n * sxx - sx * sx
    guard den > 0 else { return nil }
    let rate = (n * sxy - sx * sy) / den * 3600
    guard rate.isFinite else { return nil }
    if abs(rate) < 1e-6 { return 0 }                                 // 一直没动：浮点误差别算成负值
    return rate < 0 ? nil : rate
}

private func historyWaste(_ pts: [HistoryEntry], now: Date) -> [WasteItem] {
    let cycles = splitCycles(pts)
    var out: [WasteItem] = []
    for c in cycles {
        guard let last = c.points.last else { continue }
        var resetAt: Date
        var early = false
        switch c.end {
        case .scheduled:
            guard let r = last.resetsAt else { continue }
            resetAt = r
        case .early:
            guard let n = c.nextStart else { continue }
            resetAt = n
            early = true
        case .open:
            guard let r = last.resetsAt, r <= now else { continue }   // 还没到重置点：不算
            resetAt = r
        }
        guard resetAt <= now, resetAt.timeIntervalSince(last.ts) <= historyWasteMaxGap else { continue }
        out.append(WasteItem(service: last.service, account: last.account, window: last.window, resetAt: resetAt,
                             leftoverPercent: max(0, 100 - last.percent), lastReadingAt: last.ts, early: early))
    }
    return out
}

private func historyDaily(_ all: [HistoryEntry], days: Int, now: Date, calendar cal: Calendar) -> [(day: Date, consumed: Double)] {
    guard days > 0 else { return [] }
    let today = cal.startOfDay(for: now)
    guard let start = cal.date(byAdding: .day, value: -(days - 1), to: today) else { return [] }
    let dayStarts = (0..<days).compactMap { cal.date(byAdding: .day, value: $0, to: start) }
    var sums = [Double](repeating: 0, count: dayStarts.count)
    let pts = all.filter { $0.ts <= now }
    if pts.count >= 2 {
        for i in 1..<pts.count {
            let prev = pts[i - 1], cur = pts[i]
            guard cur.ts >= start else { continue }
            let inc: Double
            switch cycleBreak(prev, cur) {
            case .open: inc = max(0, cur.percent - prev.percent)
            case .scheduled: inc = max(0, cur.percent)
            case .early: inc = 0
            }
            guard let idx = cal.dateComponents([.day], from: start, to: cal.startOfDay(for: cur.ts)).day,
                  idx >= 0, idx < sums.count else { continue }
            sums[idx] += inc
        }
    }
    return zip(dayStarts, sums).map { (day: $0.0, consumed: $0.1) }
}

// MARK: - 文件读写（带内存缓存；文件大小或修改时间变了就重读）

private func historyKey(_ service: String, _ account: String, _ window: String) -> String {
    service + "\u{1F}" + account + "\u{1F}" + window
}
private func historyKey(_ e: HistoryEntry) -> String { historyKey(e.service, e.account, e.window) }

private func roundedSecond(_ d: Date) -> Date { Date(timeIntervalSince1970: d.timeIntervalSince1970.rounded()) }

private func encodeHistoryLine(_ e: HistoryEntry) -> Data? {
    var d: [String: Any] = ["t": Int64(e.ts.timeIntervalSince1970.rounded()), "s": e.service, "a": e.account,
                            "w": e.window, "p": e.percent]
    if let r = e.resetsAt { d["r"] = Int64(r.timeIntervalSince1970.rounded()) }
    if let k = e.kind { d["k"] = k.rawValue }
    return try? JSONSerialization.data(withJSONObject: d, options: [.sortedKeys])
}

/// 文件里一行的格式（JSONDecoder 比 JSONSerialization + 桥接成 [String: Any] 快一倍多）
private struct HistoryLine: Decodable {
    let t: Double, s: String, a: String, w: String, p: Double, r: Double?, k: String?
    var entry: HistoryEntry {
        HistoryEntry(ts: Date(timeIntervalSince1970: t), service: s, account: a, window: w, percent: p,
                     resetsAt: r.map { Date(timeIntervalSince1970: $0) }, kind: k.flatMap(WindowKind.init(rawValue:)))
    }
}

/// 字段缺失/类型不对的行解成 nil，不让整个数组失败
private struct LossyHistoryLine: Decodable {
    let line: HistoryLine?
    init(from decoder: Decoder) throws { line = try? HistoryLine(from: decoder) }
}

/// 用 open(2) 带 0600 创建/写入：新建的文件一开始就是 600，没有先 644 再改的空档
private func writePrivateFile(_ path: String, _ data: Data, append: Bool) -> Bool {
    let fd = open(path, O_WRONLY | O_CREAT | openBinaryFlag | (append ? O_APPEND : O_TRUNC), 0o600)
    guard fd >= 0 else { return false }
    defer { close(fd) }
    return data.withUnsafeBytes { (buf: UnsafeRawBufferPointer) -> Bool in
        guard let base = buf.baseAddress else { return true }
        var off = 0
        while off < buf.count {
            let n = writeFD(fd, base + off, buf.count - off)
            if n <= 0 { return false }
            off += n
        }
        return true
    }
}

private final class HistoryStore: @unchecked Sendable {
    static let shared = HistoryStore()
    private let lock = NSLock()
    private var path: String?
    private var size: UInt64 = 0
    private var mtime: Date?
    private var endsWithNewline = true
    private var data: [String: [HistoryEntry]] = [:]     // 每个窗口一组，组内按时间升序

    func byKey(_ url: URL) -> [String: [HistoryEntry]] {
        lock.lock(); defer { lock.unlock() }
        ensureLoaded(url)
        return data
    }

    func points(_ key: String, _ url: URL) -> [HistoryEntry] {
        lock.lock(); defer { lock.unlock() }
        ensureLoaded(url)
        return data[key] ?? []
    }

    private func stat(_ p: String) -> (UInt64, Date?, Int?)? {
        guard let a = try? FileManager.default.attributesOfItem(atPath: p) else { return nil }
        return ((a[.size] as? NSNumber)?.uint64Value ?? 0, a[.modificationDate] as? Date, (a[.posixPermissions] as? NSNumber)?.intValue)
    }

    private func ensureLoaded(_ url: URL) {
        let p = url.path
        let st = stat(p)
        if path == p, (st?.0 ?? 0) == size, st?.1 == mtime { return }
        path = p; size = st?.0 ?? 0; mtime = st?.1; data = [:]; endsWithNewline = true
        guard let st = st, let raw = try? Data(contentsOf: url) else { return }
        if let perm = st.2, perm & 0o777 != 0o600 { chmod(p, 0o600) }
        endsWithNewline = raw.isEmpty || raw.last == 0x0A
        // 快路径：整份拼成一个 JSON 数组一次解析（5MB 约 0.25 秒，-O 实测）；有写了一半的坏行（不是合法 JSON）时退回逐行解析、跳过坏行
        let lines = raw.split(separator: 0x0A)
        var joined = Data(capacity: raw.count + 2)
        joined.append(0x5B)
        for (i, l) in lines.enumerated() {
            if i > 0 { joined.append(0x2C) }
            joined.append(contentsOf: l)
        }
        joined.append(0x5D)
        let dec = JSONDecoder()
        let parsed: [HistoryLine?]
        if let arr = try? dec.decode([LossyHistoryLine].self, from: joined), arr.count == lines.count {
            parsed = arr.map { $0.line }
        } else {
            parsed = lines.map { try? dec.decode(HistoryLine.self, from: Data($0)) }
        }
        for case let l? in parsed where l.t.isFinite && l.p.isFinite {
            let e = l.entry
            data[historyKey(e), default: []].append(e)
        }
        data = data.mapValues { $0.sorted { $0.ts < $1.ts } }
    }

    private func refreshStat(_ p: String) {
        let st = stat(p)
        size = st?.0 ?? 0; mtime = st?.1
    }

    func record(_ input: [HistoryEntry], file url: URL, maxBytes: Int) -> Int {
        lock.lock(); defer { lock.unlock() }
        ensureLoaded(url)
        var pending: [String: HistoryEntry] = [:]
        var accepted: [HistoryEntry] = []
        var out = Data()
        for raw in input {
            var e = raw
            e.ts = roundedSecond(e.ts)
            e.resetsAt = e.resetsAt.map(roundedSecond)
            e.percent = (e.percent * 100).rounded() / 100
            guard e.percent.isFinite else { continue }
            if let r = e.resetsAt, r <= e.ts { continue }
            let k = historyKey(e)
            if let last = pending[k] ?? data[k]?.last {
                let dt = e.ts.timeIntervalSince(last.ts)
                if dt < historyMinInterval { continue }
                let sameReset: Bool
                switch (last.resetsAt, e.resetsAt) {
                case (nil, nil): sameReset = true
                case let (a?, b?): sameReset = abs(a.timeIntervalSince(b)) <= historySameResetTolerance
                default: sameReset = false
                }
                if abs(e.percent - last.percent) < 0.005 && sameReset && dt < historyHeartbeat { continue }
            }
            guard let line = encodeHistoryLine(e) else { continue }
            out.append(line)
            out.append(0x0A)
            pending[k] = e
            accepted.append(e)
        }
        guard !accepted.isEmpty else { return 0 }
        if !endsWithNewline { out.insert(0x0A, at: 0) }        // 上次写到一半（崩溃）留下的半行：先换行，别粘在一起
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
        } catch { return 0 }
        guard writePrivateFile(url.path, out, append: true) else {
            path = nil                                        // 可能写了一半：下次整份重读
            return 0
        }
        for e in accepted { data[historyKey(e), default: []].append(e) }
        endsWithNewline = true
        refreshStat(url.path)
        if size > UInt64(max(maxBytes, 0)) { compact(url) }
        return accepted.count
    }

    /// 丢掉最旧的一半，重写文件（先写临时文件再改名，中途失败不会丢原文件）
    private func compact(_ url: URL) {
        let all = data.values.flatMap { $0 }.sorted { $0.ts < $1.ts }
        let keep = Array(all[(all.count / 2)...])
        var out = Data()
        for e in keep {
            if let line = encodeHistoryLine(e) { out.append(line); out.append(0x0A) }
        }
        let tmp = url.deletingLastPathComponent().appendingPathComponent(".history-\(UUID().uuidString).tmp").path
        guard writePrivateFile(tmp, out, append: false), replaceFile(tmp, url.path) else {
            try? FileManager.default.removeItem(atPath: tmp)
            return
        }
        data = [:]
        for e in keep { data[historyKey(e), default: []].append(e) }
        endsWithNewline = true
        refreshStat(url.path)
    }
}

// MARK: - 自检

enum History {
    /// 用构造数据测记录/去重/坏行/截断、消耗速度、预测、浪费统计、每日消耗。只写临时文件，不碰真实 history.jsonl。
    /// 返回失败描述，空数组 = 全过
    static func selfTest() -> [String] {
        var fails: [String] = []
        func check(_ ok: Bool, _ msg: @autoclosure () -> String) { if !ok { fails.append(msg()) } }
        func near(_ a: Double?, _ b: Double, _ tol: Double = 0.01) -> Bool { a.map { abs($0 - b) <= tol } ?? false }

        var temps: [URL] = []
        func tmp(_ name: String) -> URL {
            let u = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("usagemaster-history-selftest-\(name)-\(UUID().uuidString).jsonl")
            temps.append(u)
            return u
        }
        defer { for u in temps { try? FileManager.default.removeItem(at: u) } }

        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        let now = cal.date(from: DateComponents(year: 2026, month: 9, day: 21, hour: 15))!
        let H: TimeInterval = 3600, M: TimeInterval = 60, D: TimeInterval = 86400
        func E(_ dt: TimeInterval, _ p: Double, _ r: Date?, s: String = "claude", a: String = "x@y",
               w: String = "session", k: WindowKind? = .session) -> HistoryEntry {
            HistoryEntry(ts: now.addingTimeInterval(dt), service: s, account: a, window: w, percent: p, resetsAt: r, kind: k)
        }
        func lines(_ u: URL) -> [String] {
            ((try? String(contentsOf: u, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
        }
        func perm(_ u: URL) -> Int {
            ((try? FileManager.default.attributesOfItem(atPath: u.path))?[.posixPermissions] as? NSNumber)?.intValue ?? -1
        }

        // 1) 记录与去重
        do {
            let f = tmp("rec")
            let r0 = now.addingTimeInterval(3 * H), r1 = now.addingTimeInterval(5 * D)
            check(recordSnapshot(entries: [E(-3600, 10, r0)], file: f) == 1,
                  L("记录：第一条应写入", "Record: the first reading should be written"))
            check(recordSnapshot(entries: [E(-3570, 12, r0)], file: f) == 0,
                  L("记录：30 秒内的第二条应跳过", "Record: a second reading within 30 seconds should be skipped"))
            check(recordSnapshot(entries: [E(-3480, 10, r0)], file: f) == 0,
                  L("记录：数值没变应跳过", "Record: an unchanged value should be skipped"))
            check(recordSnapshot(entries: [E(-3420, 15, r0)], file: f) == 1,
                  L("记录：数值变了应写入", "Record: a changed value should be written"))
            check(recordSnapshot(entries: [E(-3420 + 31 * M, 15, r0.addingTimeInterval(20))], file: f) == 1,
                  L("记录：没变但隔了 31 分钟应补记一条（重置时间抖 20 秒算没变）",
                    "Record: an unchanged value 31 minutes later should still be written (a 20-second jitter in the reset time counts as unchanged)"))
            check(recordSnapshot(entries: [E(-1200, 15, now.addingTimeInterval(-1300))], file: f) == 0,
                  L("记录：重置时间已过的读数应跳过", "Record: a reading whose reset time has passed should be skipped"))
            check(recordSnapshot(entries: [E(-1100, .nan, r0)], file: f) == 0, L("记录：NaN 应跳过", "Record: NaN should be skipped"))
            check(recordSnapshot(entries: [E(-1000, 20, r0), E(-1000, 50, r1, w: "weekly_all", k: .weekly), E(-990, 21, r0)], file: f) == 2,
                  L("记录：同一批里两个窗口各写一条、同窗口 10 秒后那条跳过",
                    "Record: in one batch, each of the two windows should get one line and the same window 10 seconds later should be skipped"))
            check(lines(f).count == 5, L("记录：文件应有 5 行，实际 \(lines(f).count)", "Record: the file should have 5 lines, got \(lines(f).count)"))
            check(perm(f) & 0o777 == 0o600, L("记录：文件权限应为 600，实际 \(String(perm(f), radix: 8))",
                                              "Record: file permissions should be 600, got \(String(perm(f), radix: 8))"))
            let all = loadHistory(since: .distantPast, file: f)
            check(all.map { $0.percent } == [10, 15, 15, 20, 50],
                  L("读取：顺序/内容不对：", "Load: wrong order or content: ") + "\(all.map { $0.percent })")
            check(all.first?.resetsAt == r0, L("读取：重置时间没存对", "Load: the reset time was not stored correctly"))
            check(all.first?.kind == .session && all.last?.kind == .weekly,
                  L("读取：窗口类别没存对", "Load: the window kind was not stored correctly"))
            check(loadHistory(since: now.addingTimeInterval(-1050), file: f).count == 2,
                  L("读取：since 过滤不对", "Load: the since filter is wrong"))

            // 坏行（外部写入，最后一行还是写了一半没换行的）：读取跳过，下一条记录不能粘在半行上
            let junk = "{oops\nnot json\n{\"t\":\"x\"}\n[1,2]\n{\"t\":1,\"s\":\"claude\""
            check(writePrivateFile(f.path, Data(("\n" + junk).utf8), append: true),
                  L("坏行：写不进测试数据", "Bad lines: could not write the test data"))
            check(loadHistory(since: .distantPast, file: f).count == 5,
                  L("坏行：应跳过坏行，仍读到 5 条", "Bad lines: bad lines should be skipped and 5 readings still loaded"))
            check(recordSnapshot(entries: [E(-500, 25, r0)], file: f) == 1,
                  L("坏行：之后的记录应写入", "Bad lines: a later reading should be written"))
            check(recordSnapshot(entries: [E(-470, 26, r0)], file: f) == 0,
                  L("坏行：重读文件后去重状态应还在（30 秒内跳过）", "Bad lines: dedup state should survive the reload (skip within 30 seconds)"))
            let after = loadHistory(since: .distantPast, file: f)
            check(after.count == 6 && after.last?.percent == 25,
                  L("坏行：应读到 6 条且最后一条 25%，实际 ", "Bad lines: should load 6 readings with the last at 25%, got ") + "\(after.map { $0.percent })")
        }

        // 2) 超过上限丢最旧的一半
        do {
            let f = tmp("cap")
            for i in 0..<200 {
                recordSnapshot(entries: [E(Double(i) * 120 - 100_000, Double(i % 97), nil, w: "test")], file: f, maxBytes: 4000)
            }
            let size = ((try? FileManager.default.attributesOfItem(atPath: f.path))?[.size] as? NSNumber)?.intValue ?? -1
            let all = loadHistory(since: .distantPast, file: f)
            check(size > 0 && size <= 4000, L("截断：文件应 ≤ 4000 字节，实际 \(size)", "Trim: the file should be at most 4000 bytes, got \(size)"))
            check(all.last?.percent == Double(199 % 97) && all.last?.ts == now.addingTimeInterval(199 * 120 - 100_000),
                  L("截断：最新一条应保留", "Trim: the newest reading should be kept"))
            check((all.first?.ts ?? .distantPast) > now.addingTimeInterval(-100_000),
                  L("截断：最旧的应已丢掉", "Trim: the oldest readings should be dropped"))
            check(all.count >= 10 && all.count == lines(f).count,
                  L("截断：条数异常 \(all.count) / \(lines(f).count) 行", "Trim: unexpected count \(all.count) / \(lines(f).count) lines"))
            check(perm(f) & 0o777 == 0o600, L("截断：重写后权限应仍为 600", "Trim: permissions should still be 600 after the rewrite"))
        }

        // 3) 消耗速度
        do {
            let f = tmp("burn")
            func rec(_ a: String, _ pts: [(TimeInterval, Double, Date?)]) {
                for (dt, p, r) in pts { recordSnapshot(entries: [E(dt, p, r, a: a)], file: f) }
            }
            func rate(_ a: String) -> Double? { burnRate(service: "claude", account: a, window: "session", now: now, file: f) }
            func got(_ a: String) -> String { String(describing: rate(a)) }
            let rNew = now.addingTimeInterval(3 * H)
            // 上一周期 85 分钟前重置，88 分钟前那条 95% 落在 90 分钟内，但不属于当前周期
            var bPts: [(TimeInterval, Double, Date?)] = [(-88 * M, 95, now.addingTimeInterval(-85 * M))]
            for m in stride(from: 80.0, through: 0, by: -10) {
                let pct: Double = 20 + 0.1 * (80 - m)
                bPts.append((-m * M, pct, rNew))
            }
            rec("b", bPts)
            check(near(rate("b"), 6), L("速度：匀速 6%/小时，实际 \(got("b"))", "Burn rate: steady 6%/hour, got \(got("b"))"))
            rec("c", [(-30 * M, 10, rNew), (-10 * M, 20, rNew)])
            check(rate("c") == nil, L("速度：只有 2 个点应为 nil", "Burn rate: only 2 points should give nil"))
            rec("d", [(-10 * M, 10, rNew), (-7 * M, 12, rNew), (-4 * M, 14, rNew), (-1 * M, 16, rNew)])
            check(rate("d") == nil, L("速度：跨度不足 15 分钟应为 nil", "Burn rate: a span under 15 minutes should give nil"))
            rec("e", [(-30 * M, 30, rNew), (-20 * M, 29, rNew), (-10 * M, 28, rNew), (0, 27, rNew)])
            check(rate("e") == nil, L("速度：负值应为 nil，实际 \(got("e"))", "Burn rate: a negative rate should give nil, got \(got("e"))"))
            rec("f", [(-60 * M, 40, rNew), (-30 * M, 40, rNew), (0, 40, rNew)])
            check(rate("f") == 0, L("速度：一直没动应为 0，实际 \(got("f"))", "Burn rate: no change should give 0, got \(got("f"))"))
            let rOld = now.addingTimeInterval(-25 * M)
            rec("g", [(-60 * M, 80, rOld), (-45 * M, 85, rOld), (-30 * M, 90, rOld),
                      (-20 * M, 2, rNew), (-10 * M, 4, rNew), (0, 6, rNew)])
            check(near(rate("g"), 12), L("速度：只用重置后的点，应为 12%/小时，实际 \(got("g"))",
                                         "Burn rate: only points after the reset should count (12%/hour), got \(got("g"))"))
            rec("h", [(-80 * M, 60, now.addingTimeInterval(2 * D)), (-60 * M, 70, now.addingTimeInterval(2 * D)),
                      (-40 * M, 80, now.addingTimeInterval(2 * D)),
                      (-30 * M, 3, now.addingTimeInterval(7 * D)), (-15 * M, 5, now.addingTimeInterval(7 * D)),
                      (0, 7, now.addingTimeInterval(7 * D))])
            check(near(rate("h"), 8), L("速度：官方提前重置后应只用之后的点（8%/小时），实际 \(got("h"))",
                                        "Burn rate: after an early official reset only later points should count (8%/hour), got \(got("h"))"))
            let rPast = now.addingTimeInterval(-5 * M)
            rec("i", [(-60 * M, 10, rPast), (-40 * M, 20, rPast), (-20 * M, 30, rPast)])
            check(rate("i") == nil, L("速度：周期已过重置点应为 nil", "Burn rate: a cycle past its reset time should give nil"))
        }

        // 4) 预测用完时间
        do {
            check(projectedExhaustion(currentPercent: 40, rate: 10, resetsAt: now.addingTimeInterval(10 * H), now: now)
                  == now.addingTimeInterval(6 * H), L("预测：40% + 10%/小时 应 6 小时后用完", "Projection: 40% at 10%/hour should run out in 6 hours"))
            check(projectedExhaustion(currentPercent: 40, rate: 10, resetsAt: now.addingTimeInterval(5 * H), now: now) == nil,
                  L("预测：重置前用不完应为 nil", "Projection: should be nil when it won't run out before the reset"))
            check(projectedExhaustion(currentPercent: 40, rate: 0, resetsAt: nil, now: now) == nil,
                  L("预测：速度 0 应为 nil", "Projection: a rate of 0 should give nil"))
            check(projectedExhaustion(currentPercent: 40, rate: -3, resetsAt: nil, now: now) == nil,
                  L("预测：负速度应为 nil", "Projection: a negative rate should give nil"))
            check(projectedExhaustion(currentPercent: 90, rate: 5, resetsAt: nil, now: now) == now.addingTimeInterval(2 * H),
                  L("预测：不知道重置时间时照算", "Projection: should still compute when the reset time is unknown"))
            check(projectedExhaustion(currentPercent: 100, rate: 0, resetsAt: now.addingTimeInterval(H), now: now) == now,
                  L("预测：已经用完应返回 now", "Projection: should return now when already used up"))
        }

        // 5) 浪费统计（按 kind 挑每周窗口，窗口文字是哪种语言都不影响）
        do {
            let f = tmp("waste")
            let wk = "weekly_all"
            let r1 = now.addingTimeInterval(-3 * D), r2 = now.addingTimeInterval(4 * D), r3 = now.addingTimeInterval(6 * D)
            let w1: [HistoryEntry] = [
                HistoryEntry(ts: r1.addingTimeInterval(-2 * D), service: "claude", account: "a@y", window: wk, percent: 50, resetsAt: r1, kind: .weekly),
                HistoryEntry(ts: r1.addingTimeInterval(-H), service: "claude", account: "a@y", window: wk, percent: 70, resetsAt: r1, kind: .weekly),
                HistoryEntry(ts: r1.addingTimeInterval(H), service: "claude", account: "a@y", window: wk, percent: 5, resetsAt: r2, kind: .weekly),
                E(-D - H, 40, r2, a: "a@y", w: wk, k: .weekly),
                E(-D, 2, r3, a: "a@y", w: wk, k: .weekly),          // 原定 4 天后重置，突然掉到 2%：官方提前重置
                E(-H, 10, r3, a: "a@y", w: wk, k: .weekly),
            ]
            for e in w1 { recordSnapshot(entries: [e], file: f) }
            recordSnapshot(entries: [E(-2 * D - 2 * H, 30, now.addingTimeInterval(-2 * D), s: "codex", a: "b", w: "Weekly", k: .weekly)], file: f)
            recordSnapshot(entries: [E(-5 * D, 10, now.addingTimeInterval(-3 * D), s: "gemini", a: "c", w: "weekly", k: .weekly)], file: f)
            recordSnapshot(entries: [E(-6 * H, 10, now.addingTimeInterval(-3 * H), a: "a@y")], file: f)   // 5 小时窗口：不统计
            let rep = wasteReport(days: 7, now: now, file: f)
            let want: [WasteItem] = [
                WasteItem(service: "claude", account: "a@y", window: wk, resetAt: now.addingTimeInterval(-D), leftoverPercent: 60,
                          lastReadingAt: now.addingTimeInterval(-D - H), early: true),
                WasteItem(service: "codex", account: "b", window: "Weekly", resetAt: now.addingTimeInterval(-2 * D), leftoverPercent: 70,
                          lastReadingAt: now.addingTimeInterval(-2 * D - 2 * H)),
                WasteItem(service: "claude", account: "a@y", window: wk, resetAt: r1, leftoverPercent: 30,
                          lastReadingAt: r1.addingTimeInterval(-H)),
            ]
            check(rep == want, L("浪费：结果不对：", "Waste: wrong result: ")
                  + "\(rep.map { "\($0.service) \(Int($0.leftoverPercent))% early=\($0.early)" })")
            let rep2 = wasteReport(days: 2, now: now, file: f)
            check(rep2.count == 1 && rep2.first?.early == true,
                  L("浪费：最近 2 天应只剩那次提前重置，实际 \(rep2.count) 条", "Waste: the last 2 days should hold only the early reset, got \(rep2.count) items"))
            check(wasteReport(days: 0, now: now, file: f).isEmpty, L("浪费：days=0 应为空", "Waste: days=0 should be empty"))
        }

        // 6) 每日消耗
        do {
            let f = tmp("daily")
            let wk = "weekly_all"
            let today = cal.startOfDay(for: now)
            let d1 = cal.date(byAdding: .day, value: -1, to: today)!, d0 = cal.date(byAdding: .day, value: -2, to: today)!
            let dPrev = cal.date(byAdding: .day, value: -3, to: today)!
            let r1 = d1.addingTimeInterval(9.5 * H), r2 = now.addingTimeInterval(5 * D)
            func P(_ day: Date, _ h: Double, _ p: Double, _ r: Date) -> HistoryEntry {
                HistoryEntry(ts: day.addingTimeInterval(h * H), service: "claude", account: "a@y", window: wk, percent: p, resetsAt: r, kind: .weekly)
            }
            let pts = [P(dPrev, 23, 5, r1),                                       // 范围之前的基准点
                       P(d0, 8, 10, r1), P(d0, 12, 30, r1),                       // 第 1 天：+5 +20 = 25
                       P(d1, 9, 50, r1), P(d1, 10, 5, r2), P(d1, 20, 15, r2),     // 第 2 天：+20，按时重置后 +5，+10
                       P(d1, 21, 12, r2), P(d1, 22, 14, r2),                      // 小幅回落记 0，再 +2 → 37
                       P(today, 1, 20, r2), P(today, 2, 3, r2), P(today, 3, 8, r2)] // 今天：+6，突降记 0，+5 → 11
            for e in pts { recordSnapshot(entries: [e], file: f) }
            let got = dailyUsage(service: "claude", account: "a@y", window: wk, days: 3, now: now, calendar: cal, file: f)
            check(got.map { $0.day } == [d0, d1, today], L("每日：日期不对：", "Daily: wrong dates: ") + "\(got.map { $0.day })")
            check(zip(got.map { $0.consumed }, [25.0, 37, 11]).allSatisfy { abs($0 - $1) < 1e-9 } && got.count == 3,
                  L("每日：消耗不对：\(got.map { $0.consumed })，应为 [25, 37, 11]", "Daily: wrong usage: \(got.map { $0.consumed }), expected [25, 37, 11]"))
            let one = dailyUsage(service: "claude", account: "a@y", window: wk, days: 1, now: now, calendar: cal, file: f)
            check(one.count == 1 && one.first?.consumed == 11, L("每日：days=1 应只有今天 11", "Daily: days=1 should hold only today at 11"))
            check(dailyUsage(service: "claude", account: "a@y", window: wk, days: 0, now: now, calendar: cal, file: f).isEmpty,
                  L("每日：days=0 应为空", "Daily: days=0 should be empty"))
        }

        // 7) 抓取结果 → 历史记录（窗口标识用 kind，不随界面语言变）
        do {
            var ok = ClaudeAccount(label: "FF", email: "a@y", org: "FF", active: true, source: "test")
            ok.windows = [UsageWindow(label: windowLabel(kind: "session"), percent: 30, resetsAt: now.addingTimeInterval(H), wasReset: false, kind: "session"),
                          UsageWindow(label: windowLabel(kind: "weekly_all"), percent: 0, resetsAt: now.addingTimeInterval(-H), wasReset: true, kind: "weekly_all"),
                          UsageWindow(label: windowLabel(kind: "weekly_scoped", scope: "Fable"), percent: 10, resetsAt: now.addingTimeInterval(D),
                                      wasReset: false, kind: "weekly_scoped", scope: "Fable")]
            var bad = ClaudeAccount(label: "OP", email: "b@y", org: "", active: false, source: "test")
            bad.windows = ok.windows
            bad.error = L("需要重新登录", "Sign in again")
            let ce = historyEntries(claude: [ok, bad], at: now)
            check(ce.map { $0.account } == ["a@y · FF", "a@y · FF"] && ce.map { $0.window } == ["session", "weekly_scoped:Fable"]
                  && ce.map { $0.kind } == [.session, .weekly],
                  L("转换：Claude 应剩 2 条（跳过已重置窗口与报错账号），窗口标识用 kind：",
                    "Convert: Claude should give 2 entries (skipping the reset window and the account with an error), with kind as the window ID: ")
                  + "\(ce.map { $0.window })")
            var old = ClaudeAccount(label: "OLD", email: "c@y", org: "", active: false, source: "test")
            old.windows = [UsageWindow(label: windowLabel(kind: "session"), percent: 5, resetsAt: now.addingTimeInterval(H), wasReset: false)]
            check(historyEntries(claude: [old], at: now).map { $0.window } == ["session"],
                  L("转换：旧缓存没有 kind 时也应得到 session", "Convert: an old cache entry without kind should still map to session"))
            let st = ServiceStatus(id: "codex", displayName: "Codex", configured: true, setupHint: "", accounts: [
                ServiceAccount(id: "u1", title: "u1", windows: [
                    ServiceWindow(label: L("每周", "Weekly"), percent: 40, resetsAt: nil, kind: .weekly),
                    ServiceWindow(label: L("本月", "This month"), percent: nil, resetsAt: nil, kind: .monthly)])])
            let se = historyEntries(service: st, at: now)
            check(se.map { $0.window } == [L("每周", "Weekly")] && se.first?.kind == .weekly,
                  L("转换：百分比未知的窗口应跳过", "Convert: windows with an unknown percentage should be skipped"))
            let cu = historyEntries(cursor: CursorUsage(percent: 12, cycleEnd: now.addingTimeInterval(D)), at: now)
            check(cu.first?.account == historyCursorAccount && cu.first?.window == historyCursorWindow && cu.first?.kind == .monthly,
                  L("转换：Cursor 应存账号与窗口的标识", "Convert: Cursor should store account and window IDs"))
            check(historyWindowName(service: "claude", window: "session") == windowLabel(kind: "session")
                  && historyWindowName(service: "claude", window: "weekly_scoped:Fable") == windowLabel(kind: "weekly_scoped", scope: "Fable")
                  && historyWindowName(service: "claude", window: "weekly_scoped") == windowLabel(kind: "weekly_scoped")
                  && historyWindowName(service: "codex", window: "Weekly") == "Weekly"
                  && historyAccountName(service: "codex", account: "u1") == "u1",
                  L("显示名：标识换回显示名不对", "Display: mapping IDs back to display names is wrong"))
        }
        return fails
    }
}
