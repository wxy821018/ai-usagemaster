// Kimi Code、Grok（xAI grok CLI）、ZCode（Z.ai / 智谱 GLM Coding Plan）三家的用量。协议参考自 Orca 1.4.219 的 out/main/index.js（MIT 许可，Copyright (c) 2026 Lovecast Inc.）。
//
// 三家都只读对方 CLI 留在本机的凭据文件：不写回、不刷新。令牌过期时提示去运行一次对应的 CLI，由它自己刷新并改写文件。
// 令牌只在内存里，不打印、不写日志、不进错误信息；请求都走 Core.swift 里不落盘的 session（不跟随重定向）。
//
// Kimi Code：读 <KIMI_CODE_HOME 或 ~/.kimi-code>/credentials/kimi-code.json 的 access_token / expires_at（Unix 秒），
//   GET {KIMI_CODE_BASE_URL 或 https://api.kimi.com/coding/v1}/usages，Bearer。返回里 usage = 周窗口，
//   limits[] 里窗口分钟数最接近 300 的那项 = 5 小时窗口。
// Grok：读 <GROK_HOME（须是绝对路径）或 ~/.grok>/auth.json（按 issuer 分条的 map），优先取 https://auth.x.ai 系里令牌还新鲜的那条，
//   GET https://cli-chat-proxy.grok.com/v1/billing?format=credits，没有百分比时再 GET /billing。
// ZCode：读 ~/.zcode/cli/config.json，model 指向的 provider 的 options.apiKey 与 baseURL（只认 https 的 api.z.ai / open.bigmodel.cn / dev.bigmodel.cn），
//   GET <origin>/api/monitor/usage/quota/limit，Authorization 直接是 key（不加 Bearer）。

import Foundation

// MARK: - 三家共用的小工具

enum KimiGrokZCode {
    /// JSON 数字。排除 true/false：JSONSerialization 把布尔也解成 NSNumber，而 Orca 用 typeof === 'number' 判断
    static func number(_ v: Any?) -> Double? {
        guard let n = v as? NSNumber, CFGetTypeID(n as CFTypeRef) != CFBooleanGetTypeID() else { return nil }
        let d = n.doubleValue
        return d.isFinite ? d : nil
    }

    /// 严格的 JSON true（数字 1 不算）
    static func isJSONTrue(_ v: Any?) -> Bool {
        guard let n = v as? NSNumber, CFGetTypeID(n as CFTypeRef) == CFBooleanGetTypeID() else { return false }
        return n.boolValue
    }

    /// 数字，或者能整串转成数字的字符串（Kimi 的 limit / used / remaining 两种写法都可能出现）
    static func numberOrString(_ v: Any?) -> Double? {
        if let d = number(v) { return d }
        guard let s = v as? String, let d = Double(s.trimmingCharacters(in: .whitespacesAndNewlines)), d.isFinite else { return nil }
        return d
    }

    /// 像 JS 的 parseFloat：取开头那段数字，"12.5abc" → 12.5（Grok 的 {val:"12.5"}）
    static func parseFloatPrefix(_ s: String) -> Double? {
        guard let d = Scanner(string: s).scanDouble(), d.isFinite else { return nil }
        return d
    }

    /// Unix 时间戳：大于 1e12 视为毫秒，否则视为秒（Orca 处理 Cursor 时间戳时用的同一个阈值）
    static func epoch(_ n: Double) -> Date? {
        guard n > 0 else { return nil }
        return Date(timeIntervalSince1970: n > 1e12 ? n / 1000 : n)
    }

    /// 时间字段：ISO 字符串（可带 6 位小数秒），或 Unix 时间戳（数字或纯数字字符串）
    static func date(_ v: Any?) -> Date? {
        if let n = number(v) { return epoch(n) }
        guard let raw = v as? String else { return nil }
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.isEmpty { return nil }
        if s.allSatisfy({ $0.isASCII && $0.isNumber }), let n = Double(s) { return epoch(n) }
        if let d = parseISO(s) { return d }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current                       // 不带时区的 ISO：JS 的 Date.parse 按本地时间解释
        for fmt in ["yyyy-MM-dd'T'HH:mm:ss.SSS", "yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd HH:mm:ss"] {
            f.dateFormat = fmt
            if let d = f.date(from: s) { return d }
        }
        f.timeZone = TimeZone(identifier: "UTC")    // 只有日期：JS 按 UTC 解释
        f.dateFormat = "yyyy-MM-dd"
        return f.date(from: s)
    }

    static func clampPercent(_ v: Double) -> Double { min(100, max(0, v)) }

    // 窗口显示名跟随界面语言。代码里判断窗口类型一律看 kind / 分钟数，不比对这些文字；自测也拿这几个常量比
    static var labelSession: String { L("5 小时窗口", "5-hour window") }
    static var labelDaily: String { L("每天", "Daily") }
    static var labelWeekly: String { L("每周", "Weekly") }
    static var labelMonthly: String { L("本月", "This month") }

    /// 按窗口长度（分钟）给显示名
    static func windowLabel(minutes m: Double) -> String {
        switch m {
        case 300: return labelSession
        case 1440: return labelDaily
        case 10080: return labelWeekly
        case 43200: return labelMonthly
        default:
            if m >= 60, m.truncatingRemainder(dividingBy: 60) == 0 { return L("\(Int(m / 60)) 小时窗口", "\(Int(m / 60))-hour window") }
            return L("\(Int(m.rounded())) 分钟窗口", "\(Int(m.rounded()))-minute window")
        }
    }

    /// 窗口附加说明："已用 X / Y"
    static func usedDetail(_ used: Double, _ limit: Double) -> String {
        L("已用 \(amount(used)) / \(amount(limit))", "\(amount(used)) / \(amount(limit)) used")
    }

    /// 用量数字的简短写法：1500 → "1500"，12345 → "12.3K"，40000000 → "40M"（不带单位，因为各家单位没核实）
    static func amount(_ v: Double) -> String {
        func strip(_ s: String) -> String {
            guard s.contains(".") else { return s }
            var t = s
            while t.hasSuffix("0") { t.removeLast() }
            if t.hasSuffix(".") { t.removeLast() }
            return t
        }
        let a = abs(v)
        if a >= 1e9 { return strip(String(format: "%.1f", v / 1e9)) + "B" }
        if a >= 1e6 { return strip(String(format: "%.1f", v / 1e6)) + "M" }
        if a >= 1e4 { return strip(String(format: "%.1f", v / 1e3)) + "K" }
        if v == v.rounded() { return String(Int(v)) }
        return strip(String(format: "%.2f", v))
    }

    enum FileJSON {
        case missing                // 文件不存在 → 视为没配置
        case unreadable             // 存在但读不了（权限、是个目录……）
        case invalid                // 不是合法 JSON
        case ok(Data, Any)
    }

    /// 只读一个 JSON 文件；区分"不存在"和"坏了"，前者算没配置，后者要报错
    static func readJSON(path: String) -> FileJSON {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir) else { return .missing }
        guard !isDir.boolValue, let d = FileManager.default.contents(atPath: path) else { return .unreadable }
        guard let o = try? JSONSerialization.jsonObject(with: d, options: [.fragmentsAllowed]) else { return .invalid }
        return .ok(d, o)
    }

    /// 按文件里的出现顺序列出 JSON 顶层对象的键。JSONSerialization 解出来的字典不保序，
    /// 而 Orca（JS 的 Object.entries）按文件顺序挑"第一个" Grok 登录，这里要还原那个顺序。
    static func topLevelKeys(_ data: Data) -> [String] {
        let b = [UInt8](data)
        var keys: [String] = []
        var depth = 0, keyStart = -1
        var inString = false, escaped = false, expectKey = false
        for i in b.indices {
            let c = b[i]
            if inString {
                if escaped { escaped = false }
                else if c == 0x5C { escaped = true }                      // 反斜杠
                else if c == 0x22 {                                        // 字符串结束
                    inString = false
                    if keyStart >= 0 {
                        if let k = try? JSONSerialization.jsonObject(with: Data(b[keyStart...i]), options: [.fragmentsAllowed]) as? String,
                           !keys.contains(k) { keys.append(k) }
                        keyStart = -1
                    }
                }
                continue
            }
            switch c {
            case 0x22:                                                     // 字符串开始；顶层对象里 { 或 , 之后的第一个字符串是键
                inString = true
                if depth == 1 && expectKey { keyStart = i; expectKey = false }
            case 0x7B: depth += 1; if depth == 1 { expectKey = true }      // {
            case 0x5B: depth += 1                                          // [
            case 0x7D, 0x5D: depth -= 1                                    // } ]
            case 0x2C: if depth == 1 { expectKey = true }                  // ,
            default: break
            }
        }
        return keys
    }

    /// 基址：环境变量（去空白、去末尾 /）优先，空则用默认。只接受 https，免得令牌被发到明文地址
    static func httpsBase(_ raw: String?, fallback: String) -> String? {
        var s = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if s.isEmpty { s = fallback }
        if s.hasSuffix("/") { s.removeLast() }
        guard let u = URL(string: s), u.scheme?.lowercased() == "https", let h = u.host, !h.isEmpty else { return nil }
        return s
    }

    struct JSONReply {
        var code: Int
        var json: Any?          // 解析不了时为 nil
        var error: String?      // 网络层错误（已是中文短句，不含令牌）
    }

    /// GET 一个 JSON 端点。必须用 Core 里不落盘的 session，不能用 URLSession.shared
    static func getJSON(url: URL, headers: [String: String], timeout: TimeInterval) async -> JSONReply {
        var req = URLRequest(url: url, timeoutInterval: timeout)
        req.httpMethod = "GET"
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        do {
            let (data, resp) = try await session.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            return JSONReply(code: code, json: try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]), error: nil)
        } catch {
            return JSONReply(code: 0, json: nil, error: describe(error))
        }
    }

    /// 三家一起自测（解析与窗口映射，不发网络请求）。返回失败描述，空数组 = 全过
    static func selfTest() -> [String] {
        var fails: [String] = []
        func check(_ ok: Bool, _ what: String) { if !ok { fails.append(L("工具：", "Helpers: ") + what) } }
        check(topLevelKeys(Data(#"{"a\"b":1,"x":{"y":{"z":[1,{"q":2}]}},"c":"},{\"k\":"}"#.utf8)) == ["a\"b", "x", "c"], L("topLevelKeys 顺序/转义", "topLevelKeys order/escapes"))
        check(parseFloatPrefix("12.5abc") == 12.5 && parseFloatPrefix("abc") == nil && parseFloatPrefix(" 7") == 7, "parseFloatPrefix")
        check(date("2026-10-03T20:00:00.123456Z") == parseISO("2026-10-03T20:00:00.123Z"), L("date 6 位小数秒", "date with 6-digit fractional seconds"))
        check(date(1_790_000_000)?.timeIntervalSince1970 == 1_790_000_000, L("date 秒", "date in seconds"))
        check(date(1_790_000_000_000.0)?.timeIntervalSince1970 == 1_790_000_000, L("date 毫秒", "date in milliseconds"))
        check(date("1790000000")?.timeIntervalSince1970 == 1_790_000_000, L("date 数字字符串", "date as a numeric string"))
        check(date("") == nil && date(NSNull()) == nil && date("不是时间") == nil, L("date 空值", "date with empty values"))
        check(windowLabel(minutes: 300) == labelSession && windowLabel(minutes: 240) == L("4 小时窗口", "4-hour window")
              && windowLabel(minutes: 90) == L("90 分钟窗口", "90-minute window") && windowLabel(minutes: 10080) == labelWeekly, "windowLabel")
        check(amount(1500) == "1500" && amount(12.5) == "12.5" && amount(12345) == "12.3K" && amount(40_000_000) == "40M", "amount")
        check(httpsBase(nil, fallback: "https://a.example/v1") == "https://a.example/v1", L("httpsBase 默认", "httpsBase default"))
        check(httpsBase("  https://b.example/v1/ ", fallback: "https://a.example/v1") == "https://b.example/v1", L("httpsBase 去空白与末尾 /", "httpsBase trims whitespace and the trailing /"))
        check(httpsBase("http://b.example/v1", fallback: "https://a.example/v1") == nil, L("httpsBase 拒绝 http", "httpsBase rejects http"))
        check(number(true as NSNumber) == nil && number(3 as NSNumber) == 3, L("number 排除布尔", "number excludes booleans"))
        return fails + KimiService.selfTest() + GrokService.selfTest() + ZCodeService.selfTest()
    }

    /// 自测用：把 JSON 文本解成对象（与真实返回走同一条 JSONSerialization 路径，数字是 NSNumber、布尔是 CFBoolean）
    static func json(_ s: String) -> Any? {
        try? JSONSerialization.jsonObject(with: Data(s.utf8), options: [.fragmentsAllowed])
    }

    static func near(_ a: Double?, _ b: Double) -> Bool {
        guard let a = a else { return false }
        return abs(a - b) < 1e-9
    }
}

// MARK: - Kimi Code

struct KimiService: UsageService {
    let id = "kimi"
    let displayName = "Kimi Code"
    var setupHint: String {
        L("安装 Kimi Code CLI 后在终端运行 kimi 登录一次。UsageMaster 只读 ~/.kimi-code/credentials/kimi-code.json"
            + "（设了 KIMI_CODE_HOME 则读那里），令牌过期时再运行一次 kimi 就会刷新。",
          "Install the Kimi Code CLI and run kimi in a terminal once to sign in. UsageMaster only reads ~/.kimi-code/credentials/kimi-code.json"
            + " (or the one under KIMI_CODE_HOME if set). When the token expires, run kimi again and it will refresh.")
    }

    static let defaultBaseURL = "https://api.kimi.com/coding/v1"
    static let sessionMinutes = 300.0       // 选"最接近 5 小时"的那个窗口
    static let weeklyMinutes = 10080.0

    static func home(env: [String: String] = ProcessInfo.processInfo.environment) -> String {
        if let h = env["KIMI_CODE_HOME"]?.trimmingCharacters(in: .whitespacesAndNewlines), !h.isEmpty { return h }
        return NSHomeDirectory() + "/.kimi-code"
    }

    static func credentialsPath(env: [String: String] = ProcessInfo.processInfo.environment) -> String {
        home(env: env) + "/credentials/kimi-code.json"
    }

    func isConfigured() -> Bool { FileManager.default.fileExists(atPath: Self.credentialsPath()) }

    /// 令牌还能用：expires_at（Unix 秒，必须是数字）比现在晚 5 秒以上；缺 expires_at 也算过期（与 Orca 一致，过期就不发请求）
    static func isFresh(_ cred: [String: Any], now: Date) -> Bool {
        guard let exp = KimiGrokZCode.number(cred["expires_at"]) else { return false }
        return exp - floor(now.timeIntervalSince1970) > 5
    }

    struct Window {
        var minutes: Double
        var percent: Double
        var used: Double
        var limit: Double
        var resetsAt: Date?
    }

    /// 一个额度对象 {limit, used | remaining, resetTime | resetAt}：limit 必须 > 0；没有 used 时用 limit - remaining
    static func window(_ v: Any?, minutes: Double) -> Window? {
        guard let d = v as? [String: Any], let limit = KimiGrokZCode.numberOrString(d["limit"]), limit > 0 else { return nil }
        var used = KimiGrokZCode.numberOrString(d["used"])
        if used == nil, let rem = KimiGrokZCode.numberOrString(d["remaining"]) { used = limit - rem }
        guard let u = used else { return nil }
        let rt = d["resetTime"]
        let raw = (rt == nil || rt is NSNull) ? d["resetAt"] : rt
        return Window(minutes: minutes, percent: KimiGrokZCode.clampPercent(u / limit * 100), used: u, limit: limit,
                      resetsAt: KimiGrokZCode.date(raw))
    }

    /// {duration, timeUnit} → 分钟。timeUnit 大写后含 MINUTE / HOUR / DAY / SECOND 依次判断，都不含就按原值；没有 duration 返回 nil
    static func minutes(_ w: Any?) -> Double? {
        let d = w as? [String: Any]
        guard let n = KimiGrokZCode.numberOrString(d?["duration"]) else { return nil }
        let unit = (d?["timeUnit"] as? String ?? "").uppercased()
        if unit.contains("MINUTE") { return n }
        if unit.contains("HOUR") { return n * 60 }
        if unit.contains("DAY") { return n * 1440 }
        if unit.contains("SECOND") { return (n / 60).rounded() }
        return n
    }

    /// 解析 /usages：顶层 usage = 周窗口（长度固定按 7 天）；limits[] 里分钟数最接近 300 的那项 = 会话窗口（并列取先出现的）
    static func parse(_ d: [String: Any]) -> (session: Window?, weekly: Window?) {
        let weekly = window(d["usage"], minutes: weeklyMinutes)
        var session: Window?
        for item in d["limits"] as? [Any] ?? [] {
            let e = item as? [String: Any]
            let m = minutes(e?["window"]) ?? sessionMinutes
            guard let w = window(e?["detail"], minutes: m) else { continue }
            if session == nil || abs(m - sessionMinutes) < abs(session!.minutes - sessionMinutes) { session = w }
        }
        return (session, weekly)
    }

    static func windows(_ d: [String: Any]) -> [ServiceWindow] {
        let p = parse(d)
        var out: [ServiceWindow] = []
        if let s = p.session {
            let kind: WindowKind = s.minutes < 1440 ? .session : (s.minutes == 1440 ? .daily : .other)
            out.append(ServiceWindow(label: KimiGrokZCode.windowLabel(minutes: s.minutes), percent: s.percent, resetsAt: s.resetsAt,
                                     kind: kind, detail: KimiGrokZCode.usedDetail(s.used, s.limit)))
        }
        if let w = p.weekly {
            out.append(ServiceWindow(label: KimiGrokZCode.labelWeekly, percent: w.percent, resetsAt: w.resetsAt, kind: .weekly,
                                     detail: KimiGrokZCode.usedDetail(w.used, w.limit)))
        }
        return out
    }

    private func status(_ accounts: [ServiceAccount], configured: Bool = true) -> ServiceStatus {
        ServiceStatus(id: id, displayName: displayName, configured: configured, setupHint: setupHint, accounts: accounts)
    }

    func fetch() async -> ServiceStatus {
        let env = ProcessInfo.processInfo.environment
        var acc = ServiceAccount(id: Self.home(env: env), title: L("默认账号", "Default account"))
        let cred: [String: Any]
        switch KimiGrokZCode.readJSON(path: Self.credentialsPath(env: env)) {
        case .missing: return status([], configured: false)
        case .unreadable: acc.error = L("读不到 Kimi 凭据文件", "Could not read the Kimi credentials file"); return status([acc])
        case .invalid: acc.error = L("Kimi 凭据文件格式不对", "The Kimi credentials file is malformed"); return status([acc])
        case .ok(_, let obj):
            guard let o = obj as? [String: Any] else { acc.error = L("Kimi 凭据文件格式不对", "The Kimi credentials file is malformed"); return status([acc]) }
            cred = o
        }
        guard let token = cred["access_token"] as? String, !token.isEmpty else {
            acc.error = L("Kimi 凭据里没有 access token", "No access token in the Kimi credentials"); return status([acc])
        }
        guard Self.isFresh(cred, now: Date()) else {
            acc.error = L("Kimi 登录已过期：在终端运行一次 kimi，等它启动后再刷新", "Kimi sign-in has expired: run kimi in a terminal once, wait for it to start, then refresh"); return status([acc])
        }
        guard let base = KimiGrokZCode.httpsBase(env["KIMI_CODE_BASE_URL"], fallback: Self.defaultBaseURL),
              let url = URL(string: base + "/usages") else {
            acc.error = L("KIMI_CODE_BASE_URL 不是 https 地址，没有发请求", "KIMI_CODE_BASE_URL is not an https address, so no request was sent"); return status([acc])
        }
        let r = await KimiGrokZCode.getJSON(url: url, headers: ["Authorization": "Bearer " + token, "Accept": "application/json"],
                                            timeout: 10)
        if let e = r.error { acc.error = e; return status([acc]) }
        if r.code == 401 || r.code == 403 {
            acc.error = L("Kimi 拒绝了令牌（HTTP \(r.code)）：在终端运行一次 kimi 重新登录", "Kimi rejected the token (HTTP \(r.code)): run kimi in a terminal once to sign in again"); return status([acc])
        }
        guard (200..<300).contains(r.code) else { acc.error = L("查询 Kimi 用量失败：HTTP \(r.code)", "Kimi usage request failed: HTTP \(r.code)"); return status([acc]) }
        guard let json = r.json else { acc.error = L("Kimi 返回的不是 JSON", "Kimi did not return JSON"); return status([acc]) }
        acc.windows = Self.windows(json as? [String: Any] ?? [:])
        if acc.windows.isEmpty { acc.error = L("Kimi 返回里没有额度窗口，格式可能变了", "No quota windows in the Kimi response; the format may have changed") } else { acc.updatedAt = Date() }
        return status([acc])
    }

    static func selfTest() -> [String] {
        var fails: [String] = []
        func check(_ ok: Bool, _ what: String) { if !ok { fails.append(L("Kimi：", "Kimi: ") + what) } }
        func ws(_ s: String) -> [ServiceWindow] { windows(KimiGrokZCode.json(s) as? [String: Any] ?? [:]) }
        let near = KimiGrokZCode.near

        // 1) 典型返回：数字字符串、remaining 推 used、6 位小数秒
        let a = ws(#"""
        {"usage":{"limit":"100","used":"25","remaining":"75","resetTime":"2026-10-10T00:00:00Z"},
         "limits":[{"window":{"duration":5,"timeUnit":"TIME_UNIT_HOUR"},"detail":{"limit":50,"remaining":40,"resetTime":"2026-10-03T20:00:00.123456Z"}},
                   {"window":{"duration":1,"timeUnit":"TIME_UNIT_DAY"},"detail":{"limit":10,"used":9}}]}
        """#)
        check(a.count == 2, L("典型返回应有 2 个窗口，实际 \(a.count)", "Typical response should have 2 windows, got \(a.count)"))
        if a.count == 2 {
            check(a[0].label == KimiGrokZCode.labelSession && a[0].kind == .session && near(a[0].percent, 20),
                  L("会话窗口 20%：\(a[0].label) \(a[0].percent ?? -1)", "Session window 20%: \(a[0].label) \(a[0].percent ?? -1)"))
            check(a[0].resetsAt == parseISO("2026-10-03T20:00:00.123Z"), L("会话窗口重置时间", "Session window reset time"))
            check(a[0].detail == L("已用 10 / 50", "10 / 50 used"), L("会话窗口 detail：\(a[0].detail ?? "nil")", "Session window detail: \(a[0].detail ?? "nil")"))
            check(a[1].label == KimiGrokZCode.labelWeekly && a[1].kind == .weekly && near(a[1].percent, 25), L("周窗口 25%", "Weekly window 25%"))
            check(a[1].resetsAt == parseISO("2026-10-10T00:00:00Z"), L("周窗口重置时间", "Weekly window reset time"))
        }
        // 2) 最接近 300：240 与 360 距离相同，取先出现的 240
        let b = parse(KimiGrokZCode.json(#"""
        {"limits":[{"window":{"duration":1440,"timeUnit":"MINUTE"},"detail":{"limit":10,"used":1}},
                   {"window":{"duration":4,"timeUnit":"HOUR"},"detail":{"limit":10,"used":5}},
                   {"window":{"duration":6,"timeUnit":"HOUR"},"detail":{"limit":10,"used":7}}]}
        """#) as? [String: Any] ?? [:])
        check(b.session?.minutes == 240 && near(b.session?.percent, 50) && b.weekly == nil, L("并列时取先出现的 240 分钟窗口", "On a tie, take the 240-minute window that comes first"))
        check(windows(KimiGrokZCode.json(#"{"limits":[{"window":{"duration":4,"timeUnit":"HOUR"},"detail":{"limit":10,"used":5}}]}"#)
                      as? [String: Any] ?? [:]).first?.label == L("4 小时窗口", "4-hour window"), L("非 5 小时窗口的显示名", "Display name of a window that isn't 5 hours"))
        // 3) 没有 window → 按 300；SECOND 单位与字符串 duration
        check(parse(KimiGrokZCode.json(#"{"limits":[{"detail":{"limit":4,"used":1}}]}"#) as? [String: Any] ?? [:]).session?.minutes == 300,
              L("缺 window 时按 300 分钟", "Missing window counts as 300 minutes"))
        check(minutes(KimiGrokZCode.json(#"{"duration":"18000","timeUnit":"TIME_UNIT_SECOND"}"#)) == 300, L("SECOND 单位换算", "SECOND unit conversion"))
        check(minutes(KimiGrokZCode.json(#"{"duration":2,"timeUnit":"TIME_UNIT_DAY"}"#)) == 2880, L("DAY 单位换算", "DAY unit conversion"))
        check(minutes(KimiGrokZCode.json(#"{"timeUnit":"HOUR"}"#)) == nil, L("缺 duration 返回 nil", "Missing duration returns nil"))
        // 4) 没有窗口 / limit=0 / 夹到 0–100 / resetAt 备用字段 / 时间戳形式
        check(ws("{}").isEmpty && ws(#"{"usage":{"limit":0,"used":0}}"#).isEmpty && ws(#"{"usage":{"limit":10}}"#).isEmpty, L("没有可用窗口", "No usable windows"))
        check(near(window(KimiGrokZCode.json(#"{"limit":10,"used":15}"#), minutes: 300)?.percent, 100), L("超额夹到 100", "Over the limit clamps to 100"))
        check(near(window(KimiGrokZCode.json(#"{"limit":10,"remaining":12}"#), minutes: 300)?.percent, 0), L("负数夹到 0", "Negative clamps to 0"))
        check(window(KimiGrokZCode.json(#"{"limit":10,"used":1,"resetAt":"2026-10-04T00:00:00Z"}"#), minutes: 300)?.resetsAt
              == parseISO("2026-10-04T00:00:00Z"), L("resetAt 备用字段", "resetAt fallback field"))
        check(window(KimiGrokZCode.json(#"{"limit":10,"used":1,"resetTime":"","resetAt":"2026-10-04T00:00:00Z"}"#), minutes: 300)?.resetsAt == nil,
              L("resetTime 为空串时不回退 resetAt（与 Orca 的 ?? 一致）", "An empty resetTime does not fall back to resetAt (same as Orca's ??)"))
        check(window(KimiGrokZCode.json(#"{"limit":10,"used":1,"resetTime":1790000000000}"#), minutes: 300)?.resetsAt?.timeIntervalSince1970
              == 1_790_000_000, L("毫秒时间戳", "Millisecond timestamp"))
        // 5) 过期判断：expires_at 必须是数字、且比现在晚 5 秒以上
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        check(!isFresh(["access_token": "x", "expires_at": NSNumber(value: 1_790_000_003)], now: now), L("剩 3 秒算过期", "3 seconds left counts as expired"))
        check(isFresh(["access_token": "x", "expires_at": NSNumber(value: 1_790_000_100)], now: now), L("剩 100 秒算新鲜", "100 seconds left counts as fresh"))
        check(!isFresh(["access_token": "x"], now: now), L("缺 expires_at 算过期", "Missing expires_at counts as expired"))
        check(!isFresh(["access_token": "x", "expires_at": "9999999999"], now: now), L("字符串 expires_at 不认", "A string expires_at is not accepted"))
        // 6) home 目录
        check(home(env: ["KIMI_CODE_HOME": "  /tmp/kh  "]) == "/tmp/kh", L("KIMI_CODE_HOME 去空白", "KIMI_CODE_HOME trims whitespace"))
        check(home(env: ["KIMI_CODE_HOME": "  "]) == NSHomeDirectory() + "/.kimi-code", L("KIMI_CODE_HOME 为空时用默认", "An empty KIMI_CODE_HOME uses the default"))
        check(credentialsPath(env: [:]) == NSHomeDirectory() + "/.kimi-code/credentials/kimi-code.json", L("默认凭据路径", "Default credentials path"))
        return fails
    }
}

// MARK: - Grok

struct GrokService: UsageService {
    let id = "grok"
    let displayName = "Grok"
    var setupHint: String {
        L("安装 grok CLI 后在终端运行 grok login。UsageMaster 只读 ~/.grok/auth.json（设了绝对路径的 GROK_HOME 则读那里），"
            + "登录过期时运行一次 grok 就会刷新，不用发消息。",
          "Install the grok CLI and run grok login in a terminal. UsageMaster only reads ~/.grok/auth.json (or the one under GROK_HOME if it is set to an absolute path)."
            + " When the sign-in expires, run grok once and it will refresh; you don't need to send a message.")
    }

    static let defaultBaseURL = "https://cli-chat-proxy.grok.com/v1"
    static let xaiIssuer = "https://auth.x.ai"
    /// 判断"顶层就是 config"用的字段
    static let configKeys = ["creditUsagePercent", "currentPeriod", "billingPeriodStart", "billingPeriodEnd", "subscriptionTier",
                             "monthlyLimit", "used", "onDemandCap", "onDemandUsed", "prepaidBalance"]
    /// 额度类字段（值都在 .val 下，可能是字符串）
    static let amountKeys = ["onDemandCap", "onDemandUsed", "prepaidBalance", "monthlyLimit", "used"]

    // 会被自测按值比对的报错定义成常量，比对时两边取同一个值，不依赖界面语言
    static var msgBadAuthFile: String { L("Grok 登录文件格式不对", "The Grok sign-in file is malformed") }
    static var msgNoPercent: String { L("Grok 没有给出这个账号的用量百分比", "Grok did not report a usage percentage for this account") }
    static var msgNoUsage: String { L("Grok 账单返回里没有额度用量", "No quota usage in the Grok billing response") }

    /// GROK_HOME 只在是绝对路径时才用
    static func home(env: [String: String] = ProcessInfo.processInfo.environment) -> String {
        let h = env["GROK_HOME"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return isAbsolutePath(h) ? h : NSHomeDirectory() + "/.grok"
    }

    static func authPath(env: [String: String] = ProcessInfo.processInfo.environment) -> String { home(env: env) + "/auth.json" }

    func isConfigured() -> Bool { FileManager.default.fileExists(atPath: Self.authPath()) }

    struct Session {
        var issuer: String
        var key: String
        var userId: String?
        var email: String?
        var expiresAt: Date?
    }

    enum AuthPick {
        case missing
        case error(String)
        case ok(Session, total: Int)        // total = 文件里有效登录的条数
    }

    /// 没有 expires_at 算新鲜；有则要比现在晚 5 分钟以上
    static func isFresh(_ s: Session, now: Date) -> Bool {
        guard let e = s.expiresAt else { return true }
        return e.timeIntervalSince(now) > 300
    }

    /// 从 auth.json（issuer → {key, user_id, email, expires_at, …}）里挑一条：
    /// x.ai 系（https://auth.x.ai 或 https://auth.x.ai::xxx）里第一条新鲜的 > 第一条 x.ai（哪怕过期）> 只有在完全没有 x.ai 键时才用别的 issuer
    static func pickSession(data: Data, now: Date) -> AuthPick {
        guard let obj = try? JSONSerialization.jsonObject(with: data), let map = obj as? [String: Any] else {
            return .error(msgBadAuthFile)
        }
        var order = KimiGrokZCode.topLevelKeys(data).filter { map[$0] != nil }
        for k in map.keys.sorted() where !order.contains(k) { order.append(k) }
        var anyXai = false, total = 0
        var freshXai: Session?, firstXai: Session?, firstOther: Session?
        for k in order {
            let isXai = k == xaiIssuer || k.hasPrefix(xaiIssuer + "::")
            anyXai = anyXai || isXai                         // 条目无效也算"有 x.ai 键"（与 Orca 一致）
            guard let v = map[k] as? [String: Any], let key = v["key"] as? String, !key.isEmpty else { continue }
            total += 1
            let s = Session(issuer: k, key: key, userId: v["user_id"] as? String, email: v["email"] as? String,
                            expiresAt: KimiGrokZCode.date(v["expires_at"]))
            if isXai {
                if freshXai == nil && isFresh(s, now: now) { freshXai = s }
                if firstXai == nil { firstXai = s }
            } else if firstOther == nil {
                firstOther = s
            }
        }
        guard let s = freshXai ?? firstXai ?? (anyXai ? nil : firstOther) else { return .missing }
        return .ok(s, total: total)
    }

    /// Grok 的数值都在 {val: …} 里，val 可能是字符串（按 parseFloat 取开头数字）
    static func val(_ x: Any?) -> Double? {
        let v = (x as? [String: Any])?["val"]
        if let s = v as? String { return KimiGrokZCode.parseFloatPrefix(s) }
        return KimiGrokZCode.number(v)
    }

    /// JS 真值（判断 config 字段"有没有"时用）
    static func truthy(_ v: Any?) -> Bool {
        guard let v = v, !(v is NSNull) else { return false }
        if let n = v as? NSNumber { return KimiGrokZCode.isJSONTrue(n) || (KimiGrokZCode.number(n).map { $0 != 0 } ?? false) }
        if let s = v as? String { return !s.isEmpty }
        return true
    }

    /// 返回体里的 config：有 config 用 config；否则顶层带任一账单字段时，顶层本身就是 config
    static func billingConfig(_ d: [String: Any]) -> [String: Any]? {
        if let c = d["config"] as? [String: Any] { return c }
        if truthy(d["config"]) { return [:] }           // 非对象但为真：Orca 也当成 config，只是什么都读不出
        return configKeys.contains { d[$0] != nil } ? d : nil
    }

    /// 账单周期结束时间：currentPeriod.end，没有再用 billingPeriodEnd
    static func periodEnd(_ c: [String: Any]) -> Date? {
        let cpEnd = (c["currentPeriod"] as? [String: Any])?["end"]
        return KimiGrokZCode.date((cpEnd == nil || cpEnd is NSNull) ? c["billingPeriodEnd"] : cpEnd)
    }

    /// 有额度字段读出 0 → 不能把"缺百分比"当成 0%。onDemandCap 为 0 时只看 onDemandUsed / used 是否 > 0
    static func zeroBlocksDefault(_ c: [String: Any]) -> Bool {
        let capVal = (c["onDemandCap"] as? [String: Any])?["val"]
        let capStrictZero: Bool = {
            if let d = KimiGrokZCode.number(capVal) { return d == 0 }
            if let s = capVal as? String { return Double(s.trimmingCharacters(in: .whitespacesAndNewlines)) == 0 }
            return false
        }()
        if val(c["onDemandCap"]) == 0 && capStrictZero {
            return [c["onDemandUsed"], c["used"]].contains { (val($0) ?? 0) > 0 }
        }
        return amountKeys.contains { val(c[$0]) == 0 }
    }

    /// 当前周期是周、且与账单周期首尾完全一致
    static func isWeeklyBillingPeriod(_ c: [String: Any]) -> Bool {
        guard let cp = c["currentPeriod"] as? [String: Any], cp["type"] as? String == "USAGE_PERIOD_TYPE_WEEKLY" else { return false }
        func same(_ a: Any?, _ b: Any?) -> Bool {
            guard let x = KimiGrokZCode.date(a), let y = KimiGrokZCode.date(b) else { return false }
            return x == y
        }
        return same(cp["start"], c["billingPeriodStart"]) && same(cp["end"], c["billingPeriodEnd"])
    }

    /// creditUsagePercent；缺失时只有在"没有任何额度字段读出 0、也算不出月度"且当前周期就是周账单期时，才按 0%
    static func creditPercent(_ c: [String: Any]) -> Double? {
        if let t = KimiGrokZCode.number(c["creditUsagePercent"]) { return t }
        if c["creditUsagePercent"] != nil || zeroBlocksDefault(c) || monthlyWindow(c) != nil { return nil }
        return isWeeklyBillingPeriod(c) ? 0 : nil
    }

    /// 额度百分比窗口。Orca 一律当成"每周"；这里只在 currentPeriod.type 明确写着 MONTH 时改标"本月"
    static func creditWindow(_ c: [String: Any]) -> ServiceWindow? {
        guard let p = creditPercent(c) else { return nil }
        let type = ((c["currentPeriod"] as? [String: Any])?["type"] as? String ?? "").uppercased()
        let monthly = type.contains("MONTH")
        return ServiceWindow(label: monthly ? KimiGrokZCode.labelMonthly : KimiGrokZCode.labelWeekly, percent: KimiGrokZCode.clampPercent(p), resetsAt: periodEnd(c),
                             kind: monthly ? .monthly : .weekly)
    }

    /// 月度：used.val / monthlyLimit.val
    static func monthlyWindow(_ c: [String: Any]) -> ServiceWindow? {
        guard let limit = val(c["monthlyLimit"]), let used = val(c["used"]), limit > 0 else { return nil }
        return ServiceWindow(label: KimiGrokZCode.labelMonthly, percent: KimiGrokZCode.clampPercent(used / limit * 100), resetsAt: periodEnd(c), kind: .monthly)
    }

    static func hasNumbers(_ c: [String: Any]) -> Bool { amountKeys.contains { val(c[$0]) != nil } }

    enum Outcome {
        case windows([ServiceWindow], plan: String?)
        case needPlain                      // credits 接口没给出百分比，要再查一次不带参数的 /billing
        case failure(String)
    }

    /// 把 /billing?format=credits（以及需要时的 /billing）的返回映射成窗口
    static func interpret(credits: [String: Any], plain: [String: Any]?) -> Outcome {
        guard let cfg = billingConfig(credits) else { return .failure(L("Grok 账单返回里没有 config，格式可能变了", "No config in the Grok billing response; the format may have changed")) }
        let tier = (cfg["subscriptionTier"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let plan = (tier?.isEmpty ?? true) ? nil : tier
        if let w = creditWindow(cfg) { return .windows([w], plan: plan) }
        if let w = monthlyWindow(cfg) { return .windows([w], plan: plan) }
        guard let plain = plain else { return .needPlain }
        let pc = plain["config"]
        let cfg2: [String: Any] = (pc == nil || pc is NSNull) ? plain : (pc as? [String: Any] ?? [:])
        if let w = monthlyWindow(cfg2) { return .windows([w], plan: plan) }
        return .failure(hasNumbers(cfg) || hasNumbers(cfg2) ? msgNoPercent : msgNoUsage)
    }

    private func status(_ accounts: [ServiceAccount], configured: Bool = true) -> ServiceStatus {
        ServiceStatus(id: id, displayName: displayName, configured: configured, setupHint: setupHint, accounts: accounts)
    }

    /// 发一次账单请求；成功返回字典，失败返回中文错误
    private static func billing(_ url: URL, headers: [String: String]) async -> (body: [String: Any]?, error: String?) {
        let r = await KimiGrokZCode.getJSON(url: url, headers: headers, timeout: 10)
        if let e = r.error { return (nil, e) }
        if r.code == 401 || r.code == 403 { return (nil, L("Grok 拒绝了令牌（HTTP \(r.code)）：在终端运行一次 grok 重新登录", "Grok rejected the token (HTTP \(r.code)): run grok in a terminal once to sign in again")) }
        guard (200..<300).contains(r.code) else { return (nil, L("查询 Grok 用量失败：HTTP \(r.code)", "Grok usage request failed: HTTP \(r.code)")) }
        guard let json = r.json else { return (nil, L("Grok 返回的不是 JSON", "Grok did not return JSON")) }
        return (json as? [String: Any] ?? [:], nil)
    }

    func fetch() async -> ServiceStatus {
        let env = ProcessInfo.processInfo.environment
        var acc = ServiceAccount(id: "grok", title: L("Grok 账号", "Grok account"))
        let s: Session
        switch KimiGrokZCode.readJSON(path: Self.authPath(env: env)) {
        case .missing: return status([], configured: false)
        case .unreadable: acc.error = L("读不到 Grok 登录文件", "Could not read the Grok sign-in file"); return status([acc])
        case .invalid: acc.error = Self.msgBadAuthFile; return status([acc])
        case .ok(let data, _):
            switch Self.pickSession(data: data, now: Date()) {
            case .missing: return status([], configured: false)
            case .error(let m): acc.error = m; return status([acc])
            case .ok(let picked, let total):
                s = picked
                if total > 1 { acc.notes.append(L("auth.json 里有 \(total) 个登录，只显示其中一个", "auth.json has \(total) sign-ins; showing only one")) }
            }
        }
        let email = s.email?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let uid = s.userId ?? ""
        acc.id = !uid.isEmpty ? uid : (!email.isEmpty ? email : s.issuer)
        acc.title = !email.isEmpty ? email : (!uid.isEmpty ? uid : L("Grok 账号", "Grok account"))
        guard Self.isFresh(s, now: Date()) else {
            acc.error = L("Grok 登录已过期：在终端运行一次 grok（需要时重新登录），不用发消息",
                          "Grok sign-in has expired: run grok in a terminal once (sign in again if needed); you don't need to send a message"); return status([acc])
        }
        guard let base = KimiGrokZCode.httpsBase(env["GROK_CLI_CHAT_PROXY_BASE_URL"], fallback: Self.defaultBaseURL),
              let creditsURL = URL(string: base + "/billing?format=credits"), let plainURL = URL(string: base + "/billing") else {
            acc.error = L("GROK_CLI_CHAT_PROXY_BASE_URL 不是 https 地址，没有发请求", "GROK_CLI_CHAT_PROXY_BASE_URL is not an https address, so no request was sent"); return status([acc])
        }
        var headers = ["Authorization": "Bearer " + s.key, "X-XAI-Token-Auth": "xai-grok-cli", "Accept": "application/json"]
        if !uid.isEmpty { headers["x-userid"] = uid }

        let first = await Self.billing(creditsURL, headers: headers)
        guard let credits = first.body else { acc.error = first.error; return status([acc]) }
        var outcome = Self.interpret(credits: credits, plain: nil)
        if case .needPlain = outcome {
            let second = await Self.billing(plainURL, headers: headers)
            guard let plain = second.body else { acc.error = second.error; return status([acc]) }
            outcome = Self.interpret(credits: credits, plain: plain)
        }
        switch outcome {
        case .windows(let w, let plan): acc.windows = w; acc.plan = plan; acc.updatedAt = Date()
        case .failure(let m): acc.error = m
        case .needPlain: acc.error = Self.msgNoUsage
        }
        return status([acc])
    }

    static func selfTest() -> [String] {
        var fails: [String] = []
        func check(_ ok: Bool, _ what: String) { if !ok { fails.append(L("Grok：", "Grok: ") + what) } }
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        let iso = ISO8601DateFormatter()
        func pick(_ s: String) -> AuthPick { pickSession(data: Data(s.utf8), now: now) }
        func picked(_ p: AuthPick) -> Session? { if case .ok(let s, _) = p { return s }; return nil }
        func isMissing(_ p: AuthPick) -> Bool { if case .missing = p { return true }; return false }
        func isError(_ p: AuthPick) -> Bool { if case .error = p { return true }; return false }
        func cfg(_ s: String) -> [String: Any] { KimiGrokZCode.json(s) as? [String: Any] ?? [:] }
        let near = KimiGrokZCode.near

        // 1) 挑登录：新鲜的 x.ai 优先、文件顺序、非 x.ai 只在没有 x.ai 键时用
        let p1 = pick(#"{"https://auth.x.ai::a":{"key":"k1","expires_at":"2020-01-01T00:00:00Z"},"https://auth.x.ai":{"key":"k2","expires_at":null,"email":"a@b.c","user_id":"u2"}}"#)
        check(picked(p1)?.issuer == "https://auth.x.ai" && picked(p1)?.userId == "u2", L("优先取新鲜的 x.ai 登录", "Prefers a fresh x.ai sign-in"))
        if case .ok(_, let total) = p1 { check(total == 2, L("有效登录条数", "Number of valid sign-ins")) }
        check(picked(pick(#"{"https://auth.x.ai::b":{"key":"kb","expires_at":"2020-01-01T00:00:00Z"},"https://auth.x.ai::a":{"key":"ka","expires_at":"2020-01-01T00:00:00Z"}}"#))?.issuer
              == "https://auth.x.ai::b", L("都过期时按文件顺序取第一条（不是按字母序）", "When all are expired, take the first in file order (not alphabetical)"))
        check(picked(pick(#"{"https://other.example":{"key":"ko"},"https://auth.x.ai":{"key":"kx","expires_at":"2020-01-01T00:00:00Z"}}"#))?.issuer
              == "https://auth.x.ai", L("有 x.ai 时即使过期也不用别的 issuer", "With an x.ai entry, don't use another issuer even if it has expired"))
        check(picked(pick(#"{"https://other.example":{"key":"ko"}}"#))?.issuer == "https://other.example", L("完全没有 x.ai 时用别的 issuer", "With no x.ai entry at all, use another issuer"))
        check(isMissing(pick(#"{"https://auth.x.ai":{"key":""},"https://other.example":{"key":"ko"}}"#)), L("有 x.ai 键但无效 → 视为未登录", "x.ai key present but invalid → treated as not signed in"))
        check(isMissing(pick("{}")) && isError(pick("[1]")) && isError(pick("not json")), L("空 / 非对象 / 坏 JSON", "Empty / non-object / bad JSON"))
        let soon = iso.string(from: now.addingTimeInterval(200)), later = iso.string(from: now.addingTimeInterval(400))
        check(!isFresh(Session(issuer: "x", key: "k", expiresAt: iso.date(from: soon)), now: now), L("剩 200 秒算过期", "200 seconds left counts as expired"))
        check(isFresh(Session(issuer: "x", key: "k", expiresAt: iso.date(from: later)), now: now), L("剩 400 秒算新鲜", "400 seconds left counts as fresh"))
        check(home(env: ["GROK_HOME": "relative/dir"]) == NSHomeDirectory() + "/.grok" && home(env: ["GROK_HOME": " /tmp/g "]) == "/tmp/g",
              L("GROK_HOME 只认绝对路径", "GROK_HOME only accepts absolute paths"))

        // 2) credits 返回 → 每周百分比
        let weekly = #"{"type":"USAGE_PERIOD_TYPE_WEEKLY","start":"2026-09-28T00:00:00Z","end":"2026-10-05T00:00:00Z"}"#
        if case .windows(let w, let plan) = interpret(credits: cfg(#"{"config":{"creditUsagePercent":42.5,"currentPeriod":\#(weekly),"subscriptionTier":" SuperGrok "}}"#), plain: nil) {
            check(w.count == 1 && w[0].label == KimiGrokZCode.labelWeekly && w[0].kind == .weekly && near(w[0].percent, 42.5),
                  L("creditUsagePercent → 每周 42.5%", "creditUsagePercent → weekly 42.5%"))
            check(w.first?.resetsAt == parseISO("2026-10-05T00:00:00Z"), L("每周重置时间取 currentPeriod.end", "Weekly reset time comes from currentPeriod.end"))
            check(plan == "SuperGrok", L("套餐名去空白", "Plan name trims whitespace"))
        } else { check(false, L("creditUsagePercent 应给出窗口", "creditUsagePercent should produce a window")) }
        // 顶层就是 config、超 100 夹住、重置时间回退 billingPeriodEnd
        let top = creditWindow(billingConfig(cfg(#"{"creditUsagePercent":150,"billingPeriodEnd":"2026-10-31T00:00:00Z"}"#)) ?? [:])
        check(near(top?.percent, 100) && top?.resetsAt == parseISO("2026-10-31T00:00:00Z"), L("顶层 config / 夹到 100 / billingPeriodEnd", "Top-level config / clamp to 100 / billingPeriodEnd"))
        // 周账单期且没有百分比 → 0%
        let zeroBase = #""currentPeriod":\#(weekly),"billingPeriodStart":"2026-09-28T00:00:00.000Z","billingPeriodEnd":"2026-10-05T00:00:00Z""#
        check(near(creditWindow(cfg("{\(zeroBase)}"))?.percent, 0), L("周账单期缺百分比 → 0%", "Weekly billing period without a percentage → 0%"))
        check(creditWindow(cfg(#"{\#(zeroBase),"onDemandCap":{"val":"5"},"used":{"val":0}}"#)) == nil, L("有额度字段读出 0 → 不按 0%", "A quota field reads 0 → don't assume 0%"))
        check(near(creditWindow(cfg(#"{\#(zeroBase),"onDemandCap":{"val":0}}"#))?.percent, 0), L("onDemandCap 为 0 且无用量 → 仍按 0%", "onDemandCap is 0 with no usage → still 0%"))
        check(creditWindow(cfg(#"{\#(zeroBase),"onDemandCap":{"val":0},"onDemandUsed":{"val":"3"}}"#)) == nil, L("onDemandCap 为 0 但有按需用量 → 不按 0%", "onDemandCap is 0 but there is on-demand usage → don't assume 0%"))
        check(creditWindow(cfg(#"{"creditUsagePercent":"42"}"#)) == nil, L("字符串百分比不认", "A string percentage is not accepted"))
        let m = creditWindow(cfg(#"{"creditUsagePercent":10,"currentPeriod":{"type":"USAGE_PERIOD_TYPE_MONTHLY"}}"#))
        check(m?.label == KimiGrokZCode.labelMonthly && m?.kind == .monthly, L("currentPeriod 是月度时标本月", "A monthly currentPeriod gets the monthly label"))

        // 3) 月度：used / monthlyLimit（val 可为字符串）
        if case .windows(let w, _) = interpret(credits: cfg(#"{"config":{"used":{"val":"12.5"},"monthlyLimit":{"val":50},"billingPeriodEnd":"2026-10-31T00:00:00Z"}}"#), plain: nil) {
            check(w.first?.label == KimiGrokZCode.labelMonthly && w.first?.kind == .monthly && near(w.first?.percent, 25), L("月度 25%", "Monthly 25%"))
        } else { check(false, L("月度应给出窗口", "Monthly should produce a window")) }
        // 4) credits 没结果 → 要查 /billing；/billing 给出月度；都没有时的两种报错
        let bare = cfg(#"{"config":{"subscriptionTier":"Basic"}}"#)
        if case .needPlain = interpret(credits: bare, plain: nil) {} else { check(false, L("没有百分比时应要求再查 /billing", "Without a percentage it should ask for /billing too")) }
        if case .windows(let w, let plan) = interpret(credits: bare, plain: cfg(#"{"config":{"used":{"val":1},"monthlyLimit":{"val":4}}}"#)) {
            check(near(w.first?.percent, 25) && plan == "Basic", L("/billing 回退给出月度，套餐名取 credits 那份", "/billing fallback gives monthly; the plan name comes from the credits response"))
        } else { check(false, L("/billing 回退应给出窗口", "/billing fallback should produce a window")) }
        if case .failure(let e) = interpret(credits: bare, plain: cfg(#"{"used":{"val":3}}"#)) {
            check(e == msgNoPercent, L("有数字没百分比的报错：\(e)", "Error for numbers without a percentage: \(e)"))
        } else { check(false, L("有数字没百分比应报错", "Numbers without a percentage should be an error")) }
        if case .failure(let e) = interpret(credits: bare, plain: cfg("{}")) {
            check(e == msgNoUsage, L("什么都没有的报错：\(e)", "Error when there is nothing: \(e)"))
        } else { check(false, L("什么都没有应报错", "Nothing at all should be an error")) }
        if case .failure = interpret(credits: cfg(#"{"foo":1}"#), plain: nil) {} else { check(false, L("没有 config 应报错", "Missing config should be an error")) }
        check(billingConfig(cfg(#"{"config":null,"used":{"val":1}}"#)) != nil, L("config 为 null 时看顶层字段", "With config null, look at top-level fields"))
        check(val(cfg(#"{"v":{"val":"7.5x"}}"#)["v"]) == 7.5 && val(cfg(#"{"v":5}"#)["v"]) == nil, L("val 取值规则", "val parsing rules"))
        return fails
    }
}

// MARK: - ZCode

struct ZCodeService: UsageService {
    let id = "zcode"
    let displayName = "ZCode"
    var setupHint: String {
        L("在 ~/.zcode/cli/config.json 里配置 Z.ai / 智谱的 API key：model 写成 \"<provider>/<模型>\"，"
            + "provider.<provider>.options 里填 apiKey 和 baseURL（https，域名须是 api.z.ai、open.bigmodel.cn 或 dev.bigmodel.cn）。",
          "Set up a Z.ai / Zhipu API key in ~/.zcode/cli/config.json: set model to \"<provider>/<model>\", "
            + "and put apiKey and baseURL under provider.<provider>.options (https, and the host must be api.z.ai, open.bigmodel.cn or dev.bigmodel.cn).")
    }

    static let allowedHosts: Set<String> = ["api.z.ai", "open.bigmodel.cn", "dev.bigmodel.cn"]

    // 显示名与会被自测按值比对的报错定义成常量，比对时两边取同一个值，不依赖界面语言
    static var labelMCP: String { L("MCP 额度", "MCP quota") }
    static var msgBadFormat: String { L("ZCode 返回格式不对", "Unexpected ZCode response format") }
    static var msgNoItems: String { L("ZCode 返回里没有可用的额度项", "No usable quota items in the ZCode response") }
    static func msgServer(_ m: String) -> String { L("ZCode：\(m)", "ZCode: \(m)") }

    static func configPath() -> String { NSHomeDirectory() + "/.zcode/cli/config.json" }

    struct Creds {
        var provider: String
        var apiKey: String
        var origin: String      // https://<host>
        var host: String
    }

    /// model："<provider>/<模型>" 或 {main: "<provider>/<模型>"}；取第一个 / 之前的部分（/ 不能在首尾）
    static func providerName(_ model: Any?) -> String? {
        guard let s = (model as? String) ?? ((model as? [String: Any])?["main"] as? String) else { return nil }
        let u = Array(s.utf16)
        guard let i = u.firstIndex(of: 0x2F), i > 0, i < u.count - 1 else { return nil }
        return String(decoding: u[..<i], as: UTF16.self)
    }

    /// 从 config.json 解出 key 与 origin；任何一步不满足都算"没配置"
    static func resolve(_ obj: Any?) -> Creds? {
        guard let root = obj as? [String: Any], let name = providerName(root["model"]),
              let opts = ((root["provider"] as? [String: Any])?[name] as? [String: Any])?["options"] as? [String: Any],
              let rawKey = opts["apiKey"] as? String, let base = opts["baseURL"] as? String else { return nil }
        let key = rawKey.trimmingCharacters(in: .whitespacesAndNewlines)
        // 按 Unicode 标量查换行："\r\n" 在 Swift 里是一个字符，String.contains("\n") 查不到它
        guard !key.isEmpty, !rawKey.unicodeScalars.contains(where: { $0 == "\r" || $0 == "\n" }) else { return nil }
        guard let comps = URLComponents(string: base.trimmingCharacters(in: .whitespacesAndNewlines)),
              comps.scheme?.lowercased() == "https",
              let host = comps.host?.lowercased(), allowedHosts.contains(host),
              comps.port == nil || comps.port == 443 else { return nil }
        return Creds(provider: name, apiKey: key, origin: "https://" + host, host: host)
    }

    static func loadCreds() -> Creds? {
        guard case .ok(_, let obj) = KimiGrokZCode.readJSON(path: configPath()) else { return nil }
        return resolve(obj)
    }

    /// config.json 可能存在却指向别家 provider，所以这里要解析一下才知道是不是配了 Z.ai（本地小文件，很快）
    func isConfigured() -> Bool { Self.loadCreds() != nil }

    struct Slot {
        var minutes: Double
        var percent: Double
        var resetsAt: Date?
        var detail: String?
    }

    /// 窗口分钟数：unit 1=天 3=小时 5=分钟 6=周，乘以 number（须为正整数）。
    /// 特例照搬 Orca：TIME_LIMIT 且 unit=5、number=1 记作一个月（暗示 unit 5 其实是"月"，没核实）
    static func minutes(_ e: [String: Any]) -> Double? {
        let unit = KimiGrokZCode.number(e["unit"]), n = KimiGrokZCode.number(e["number"])
        if e["type"] as? String == "TIME_LIMIT", unit == 5, n == 1 { return 43200 }
        let table: [Double: Double] = [1: 1440, 3: 60, 5: 1, 6: 10080]
        guard let u = unit, let n = n, n == n.rounded(), n > 0, let per = table[u] else { return nil }
        return n * per
    }

    /// 已用百分比：usage > 0 且有 currentValue 或 remaining 时自己算，否则用 percentage；都夹到 0–100
    static func percent(_ e: [String: Any]) -> (Double, String?)? {
        if let total = KimiGrokZCode.number(e["usage"]), total > 0 {
            let cur = KimiGrokZCode.number(e["currentValue"]), rem = KimiGrokZCode.number(e["remaining"])
            if cur != nil || rem != nil {
                let used = cur ?? total - (rem ?? 0)
                return (KimiGrokZCode.clampPercent(used / total * 100), KimiGrokZCode.usedDetail(used, total))
            }
        }
        guard let p = KimiGrokZCode.number(e["percentage"]) else { return nil }
        return (KimiGrokZCode.clampPercent(p), nil)
    }

    static func slot(_ e: [String: Any], now: Date) -> Slot? {
        guard let (p, detail) = percent(e), let m = minutes(e) else { return nil }
        var reset: Date? = nil
        if let r = KimiGrokZCode.number(e["nextResetTime"]), r > 0 { reset = KimiGrokZCode.epoch(r) }
        // 5 小时窗口的重置时间如果在 301 分钟以后，说明不可信，丢掉
        if m == 300, let r = reset, r > now.addingTimeInterval(301 * 60) { reset = nil }
        return Slot(minutes: m, percent: p, resetsAt: reset, detail: detail)
    }

    enum Parsed {
        case ok(plan: String?, windows: [ServiceWindow])
        case failure(String)
    }

    /// 解析 quota/limit：{success:true, code:缺省|0|200, msg, data:{level, limits:[…]}}。
    /// TOKENS_LIMIT / CREDIT_LIMIT 里 300 分钟那项 = 5 小时窗口、10080 分钟那项 = 每周；第一个 TIME_LIMIT = MCP 额度（Orca 界面也标 MCP）
    static func parse(_ json: Any?, now: Date) -> Parsed {
        let root = json as? [String: Any]
        let data = root?["data"] as? [String: Any]
        let codeOK: Bool = {
            guard let c = root?["code"] else { return true }
            guard let n = KimiGrokZCode.number(c) else { return false }
            return n == 0 || n == 200
        }()
        guard KimiGrokZCode.isJSONTrue(root?["success"]), codeOK, let limits = data?["limits"] as? [Any] else {
            if let m = (root?["msg"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !m.isEmpty {
                return .failure(msgServer(String(m.prefix(80))))
            }
            return .failure(msgBadFormat)
        }
        let items = limits.compactMap { $0 as? [String: Any] }
        let quota = items.filter { ["TOKENS_LIMIT", "CREDIT_LIMIT"].contains($0["type"] as? String ?? "") }.compactMap { slot($0, now: now) }
        let session = quota.first { $0.minutes == 300 }
        let weekly = quota.first { $0.minutes == 10080 }
        let mcp = items.first { $0["type"] as? String == "TIME_LIMIT" }.flatMap { slot($0, now: now) }
        var out: [ServiceWindow] = []
        if let s = session { out.append(ServiceWindow(label: KimiGrokZCode.labelSession, percent: s.percent, resetsAt: s.resetsAt, kind: .session, detail: s.detail)) }
        if let w = weekly { out.append(ServiceWindow(label: KimiGrokZCode.labelWeekly, percent: w.percent, resetsAt: w.resetsAt, kind: .weekly, detail: w.detail)) }
        if let t = mcp { out.append(ServiceWindow(label: labelMCP, percent: t.percent, resetsAt: t.resetsAt, kind: .monthly, detail: t.detail)) }
        if out.isEmpty { return .failure(msgNoItems) }
        return .ok(plan: data?["level"] as? String, windows: out)
    }

    private func status(_ accounts: [ServiceAccount], configured: Bool = true) -> ServiceStatus {
        ServiceStatus(id: id, displayName: displayName, configured: configured, setupHint: setupHint, accounts: accounts)
    }

    func fetch() async -> ServiceStatus {
        guard let c = Self.loadCreds() else { return status([], configured: false) }
        var acc = ServiceAccount(id: c.provider + "@" + c.host, title: L("\(c.host)（\(c.provider)）", "\(c.host) (\(c.provider))"))
        guard let url = URL(string: c.origin + "/api/monitor/usage/quota/limit") else {
            acc.error = L("ZCode 地址不对", "Invalid ZCode address"); return status([acc])
        }
        let r = await KimiGrokZCode.getJSON(url: url, headers: ["Authorization": c.apiKey, "Accept-Language": "en-US,en",
                                                                "Content-Type": "application/json"], timeout: 15)
        if let e = r.error { acc.error = e; return status([acc]) }
        if r.code == 401 || r.code == 403 {
            acc.error = L("ZCode 拒绝了 API key（HTTP \(r.code)）：检查 ~/.zcode/cli/config.json", "ZCode rejected the API key (HTTP \(r.code)): check ~/.zcode/cli/config.json"); return status([acc])
        }
        guard (200..<300).contains(r.code) else { acc.error = L("查询 ZCode 额度失败：HTTP \(r.code)", "ZCode quota request failed: HTTP \(r.code)"); return status([acc]) }
        guard let json = r.json else { acc.error = L("ZCode 返回解析不了", "Could not parse the ZCode response"); return status([acc]) }
        switch Self.parse(json, now: Date()) {
        case .ok(let plan, let windows): acc.plan = plan; acc.windows = windows; acc.updatedAt = Date()
        case .failure(let m): acc.error = m
        }
        return status([acc])
    }

    static func selfTest() -> [String] {
        var fails: [String] = []
        func check(_ ok: Bool, _ what: String) { if !ok { fails.append(L("ZCode：", "ZCode: ") + what) } }
        func res(_ s: String) -> Creds? { resolve(KimiGrokZCode.json(s)) }
        let near = KimiGrokZCode.near

        // 1) 解析配置
        let c1 = res(#"{"model":"zai/glm-4.6","provider":{"zai":{"options":{"apiKey":"  test-key  ","baseURL":"https://api.z.ai/api/coding/paas/v4"}}}}"#)
        check(c1?.provider == "zai" && c1?.apiKey == "test-key" && c1?.origin == "https://api.z.ai", L("字符串 model + key 去空白 + origin", "String model + trimmed key + origin"))
        let c2 = res(#"{"model":{"main":"bigmodel/glm-4.5"},"provider":{"bigmodel":{"options":{"apiKey":"k","baseURL":"https://OPEN.BIGMODEL.CN:443/api/paas/v4"}}}}"#)
        check(c2?.origin == "https://open.bigmodel.cn", L("对象 model + 大写域名 + 显式 443 端口", "Object model + uppercase host + explicit port 443"))
        func cfg(model: String = "\"zai/glm\"", key: String = "\"k\"", base: String = "\"https://api.z.ai/x\"") -> String {
            #"{"model":\#(model),"provider":{"zai":{"options":{"apiKey":\#(key),"baseURL":\#(base)}}}}"#
        }
        check(res(cfg()) != nil, L("基准配置可用", "Baseline config works"))
        check(res(cfg(base: "\"http://api.z.ai/x\"")) == nil, L("拒绝 http", "Rejects http"))
        check(res(cfg(base: "\"https://evil.example/x\"")) == nil, L("拒绝白名单外域名", "Rejects hosts outside the allowlist"))
        check(res(cfg(base: "\"https://api.z.ai:8443/x\"")) == nil, L("拒绝非 443 端口", "Rejects ports other than 443"))
        check(res(cfg(key: #""a\r\nb""#)) == nil, L("key 含 CRLF 拒绝", "Rejects a key containing CRLF"))
        check(res(cfg(key: #""abc\n""#)) == nil, L("key 末尾换行也拒绝（与 Orca 一致，查原始值）", "Also rejects a key with a trailing newline (same as Orca, checks the raw value)"))
        check(res(cfg(key: "\"   \"")) == nil, L("key 全空白拒绝", "Rejects an all-whitespace key"))
        check(res(cfg(model: "\"zai\"")) == nil && res(cfg(model: "\"/x\"")) == nil && res(cfg(model: "\"zai/\"")) == nil, L("model 格式不对", "Bad model format"))
        check(res(cfg(model: "\"other/x\"")) == nil, L("model 指向不存在的 provider", "model points to a provider that doesn't exist"))
        check(res(#"{"model":"zai/x","provider":{"zai":{"options":{"apiKey":"k"}}}}"#) == nil && res("[1]") == nil, L("缺 baseURL / 根不是对象", "Missing baseURL / root is not an object"))

        // 2) 解析额度
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        let ms = { (sec: Double) in String(Int64((now.timeIntervalSince1970 + sec) * 1000)) }
        let sample = #"""
        {"success":true,"code":200,"msg":"ok","data":{"level":"pro","limits":[
          {"type":"TOKENS_LIMIT","unit":3,"number":5,"usage":1000,"currentValue":250,"remaining":750,"percentage":25,"nextResetTime":\#(ms(7200))},
          {"type":"TOKENS_LIMIT","unit":6,"number":1,"percentage":60,"nextResetTime":\#(ms(259200))},
          {"type":"TIME_LIMIT","unit":5,"number":1,"usage":100,"currentValue":10,"remaining":90,"nextResetTime":\#(ms(1728000))}]}}
        """#
        if case .ok(let plan, let w) = parse(KimiGrokZCode.json(sample), now: now) {
            check(plan == "pro" && w.count == 3, L("套餐与窗口数：\(plan ?? "nil") \(w.count)", "Plan and window count: \(plan ?? "nil") \(w.count)"))
            if w.count == 3 {
                check(w[0].label == KimiGrokZCode.labelSession && w[0].kind == .session && near(w[0].percent, 25)
                      && w[0].detail == L("已用 250 / 1000", "250 / 1000 used"), L("5 小时窗口 25%", "5-hour window 25%"))
                check(w[0].resetsAt == now.addingTimeInterval(7200), L("5 小时窗口重置时间（毫秒）", "5-hour window reset time (milliseconds)"))
                check(w[1].label == KimiGrokZCode.labelWeekly && w[1].kind == .weekly && near(w[1].percent, 60) && w[1].detail == nil,
                      L("每周 60%（只有 percentage）", "Weekly 60% (percentage only)"))
                check(w[2].label == labelMCP && w[2].kind == .monthly && near(w[2].percent, 10), L("MCP 额度 10%", "MCP quota 10%"))
            }
        } else { check(false, L("典型返回应解析成功", "Typical response should parse")) }
        func one(_ item: String) -> [ServiceWindow]? {
            if case .ok(_, let w) = parse(KimiGrokZCode.json(#"{"success":true,"data":{"limits":[\#(item)]}}"#), now: now) { return w }
            return nil
        }
        check(one(#"{"type":"TOKENS_LIMIT","unit":3,"number":5,"percentage":10,"nextResetTime":\#(ms(400 * 60))}"#)?.first?.resetsAt == nil,
              L("5 小时窗口重置在 301 分钟以后 → 丢掉", "5-hour window reset more than 301 minutes away → dropped"))
        check(near(one(#"{"type":"TOKENS_LIMIT","unit":3,"number":5,"usage":100,"remaining":30}"#)?.first?.percent, 70), L("只有 remaining → 70%", "Only remaining → 70%"))
        check(near(one(#"{"type":"CREDIT_LIMIT","unit":3,"number":5,"percentage":130}"#)?.first?.percent, 100), L("CREDIT_LIMIT + 超额夹到 100", "CREDIT_LIMIT + over the limit clamps to 100"))
        check(one(#"{"type":"CREDIT_LIMIT","unit":6,"number":1,"percentage":5}"#)?.first?.kind == .weekly, L("CREDIT_LIMIT 周窗口", "CREDIT_LIMIT weekly window"))
        check(one(#"{"type":"TOKENS_LIMIT","unit":2,"number":5,"percentage":10}"#) == nil, L("未知 unit → 无可用项", "Unknown unit → no usable items"))
        check(one(#"{"type":"TOKENS_LIMIT","unit":3,"number":2.5,"percentage":10}"#) == nil, L("number 非整数 → 无可用项", "Non-integer number → no usable items"))
        check(one(#"{"type":"TOKENS_LIMIT","unit":1,"number":1,"percentage":10}"#) == nil, L("1 天窗口不进任何槽位（与 Orca 一致）", "A 1-day window goes into no slot (same as Orca)"))
        check(one(#"{"type":"TIME_LIMIT","unit":6,"number":1,"percentage":3}"#)?.first?.label == labelMCP, L("TIME_LIMIT 不论长度都进 MCP 槽位", "TIME_LIMIT goes into the MCP slot whatever its length"))
        check(one(#"{"type":"TIME_LIMIT","unit":2,"number":1,"percentage":3},{"type":"TIME_LIMIT","unit":6,"number":1,"percentage":3}"#) == nil,
              L("只看第一个 TIME_LIMIT（与 Orca 一致）", "Only the first TIME_LIMIT counts (same as Orca)"))
        check(minutes(KimiGrokZCode.json(#"{"type":"TIME_LIMIT","unit":5,"number":1}"#) as? [String: Any] ?? [:]) == 43200, L("TIME_LIMIT 特例 = 一个月", "TIME_LIMIT special case = one month"))
        check(minutes(KimiGrokZCode.json(#"{"type":"TOKENS_LIMIT","unit":5,"number":1}"#) as? [String: Any] ?? [:]) == 1, L("unit 5 普通情况 = 分钟", "unit 5 normally = minutes"))
        func failure(_ s: String) -> String? { if case .failure(let m) = parse(KimiGrokZCode.json(s), now: now) { return m }; return nil }
        check(failure(#"{"success":false,"msg":"token expired"}"#) == msgServer("token expired"), L("success=false 时带上服务端 msg", "success=false includes the server msg"))
        check(failure(#"{"success":true,"code":500,"data":{"limits":[]}}"#) == msgBadFormat, "code=500")
        check(failure(#"{"success":true,"code":"200","data":{"limits":[]}}"#) != nil, L("字符串 code 不认", "A string code is not accepted"))
        check(failure(#"{"success":true,"code":null,"data":{"limits":[]}}"#) != nil, L("code 为 null 不认", "A null code is not accepted"))
        check(failure(#"{"success":1,"data":{"limits":[]}}"#) != nil, L("success 为数字 1 不认", "success as the number 1 is not accepted"))
        check(failure(#"{"success":true,"data":{}}"#) != nil && failure("[]") != nil && failure("\"x\"") != nil, L("缺 limits / 根不是对象", "Missing limits / root is not an object"))
        check(failure(#"{"success":true,"code":0,"data":{"limits":[]}}"#) == msgNoItems, L("limits 为空", "Empty limits"))
        return fails
    }
}
