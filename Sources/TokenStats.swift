// Claude Code 本机会话日志 → token 用量与折合 API 费用（按天 / 项目 / 模型 / 会话）
//
// 数据源：Claude Code 每个会话写的 JSONL —— ~/.claude/projects、UsageMaster 自管账号目录 ~/.config/usagemaster/claude/*/projects、
//   Orca 管理的账号 <appSupportRoot>/orca/claude-accounts/*/auth/projects（Windows 为 %APPDATA%\orca；存在才扫，递归找 *.jsonl）。
// 只处理 type=="assistant" 且带 message.usage 的行，只取：timestamp、cwd、sessionId、requestId、message.id、message.model
//   和 usage 里的 token 数。**对话内容一个字节都不解码、不保存**：解析器只认 JSON 的结构边界，message.content 等字段
//   整段跳过；交给 JSONSerialization 的只有 usage 那一小段对象。
// 去重：同一条回复会出现在多个文件里（会话续接 / 分支会把旧消息抄进新文件），在一个文件里也会按内容块拆成多行
//   （流式快照，前几行的 output_tokens 还没长全）。以 message.id + requestId 为键只计一次，各 token 字段取最大值（即最终值）。
// 价格：默认是 Claude Code 2.1.288 内置的模型目录（/cost 用的同一份）；~/.config/usagemaster/pricing.json 可覆盖（同结构）。
// 缓存：<appDataDir>/token_cache.json（权限 600）——每个文件处理到的字节偏移与 (size, mtime)，
//   加上每条回复一行的 token 记录（不存费用：费用在汇总时按当前价格表现算，改了价格立即生效）。
//   文件只追加时从上次的偏移接着读；被截短或 mtime 变小就从头重扫（按最大值合并，重扫不会重复计）。
//   Claude Code 默认会清掉 30 天前的会话日志，缓存里的记录不跟着删，所以历史能一直累积（保留 400 天）。

import Foundation

// MARK: - 价格表

/// 美元 / 百万 token
struct TokenPrice: Equatable {
    var input: Double
    var output: Double
    var cacheWrite5m: Double
    var cacheWrite1h: Double
    var cacheRead: Double

    func cost(input i: Int, output o: Int, cacheRead r: Int, cacheWrite5m w5: Int, cacheWrite1h w1: Int) -> Double {
        (Double(i) * input + Double(o) * output + Double(r) * cacheRead
            + Double(w5) * cacheWrite5m + Double(w1) * cacheWrite1h) / 1_000_000
    }
}

/// Claude Code 2.1.288 内置模型目录：pricing_tiers 原样照抄；models 里每个型号的 id 与各云厂商 id
/// （转小写、去掉 "us.anthropic." / "anthropic." 前缀）都映射到它的价格档位
enum TokenCatalog {
    static let source = L("Claude Code 2.1.288 内置模型目录", "Claude Code 2.1.288 built-in model catalog")
    static let fallbackTier = "tier_5_25"     // 不认识的型号按这一档估
    static let tiers: [String: TokenPrice] = [
        "tier_2_10": TokenPrice(input: 2, output: 10, cacheWrite5m: 2.5, cacheWrite1h: 4, cacheRead: 0.2),
        "tier_3_15": TokenPrice(input: 3, output: 15, cacheWrite5m: 3.75, cacheWrite1h: 6, cacheRead: 0.3),
        "tier_5_25": TokenPrice(input: 5, output: 25, cacheWrite5m: 6.25, cacheWrite1h: 10, cacheRead: 0.5),
        "tier_15_75": TokenPrice(input: 15, output: 75, cacheWrite5m: 18.75, cacheWrite1h: 30, cacheRead: 1.5),
        "tier_10_50": TokenPrice(input: 10, output: 50, cacheWrite5m: 12.5, cacheWrite1h: 20, cacheRead: 1),
        "tier_10_50_cache_read_0_25": TokenPrice(input: 10, output: 50, cacheWrite5m: 12.5, cacheWrite1h: 20, cacheRead: 0.25),
        "tier_4_20_cache_read_0_20": TokenPrice(input: 4, output: 20, cacheWrite5m: 5, cacheWrite1h: 8, cacheRead: 0.2),
        "haiku_35": TokenPrice(input: 0.8, output: 4, cacheWrite5m: 1, cacheWrite1h: 1.6, cacheRead: 0.08),
        "haiku_45": TokenPrice(input: 1, output: 5, cacheWrite5m: 1.25, cacheWrite1h: 2, cacheRead: 0.1),
    ]
    static let models: [String: String] = [
        "claude-3-5-haiku": "haiku_35", "claude-3-5-haiku-20241022": "haiku_35", "claude-3-5-haiku-20241022-v1:0": "haiku_35",
        "claude-3-5-haiku@20241022": "haiku_35", "claude-haiku-4-5": "haiku_45", "claude-haiku-4-5-20251001": "haiku_45",
        "claude-haiku-4-5-20251001-v1:0": "haiku_45", "claude-haiku-4-5@20251001": "haiku_45", "claude-3-5-sonnet": "tier_3_15",
        "claude-3-5-sonnet-20241022": "tier_3_15", "claude-3-5-sonnet-20241022-v2:0": "tier_3_15", "claude-3-5-sonnet-v2@20241022": "tier_3_15",
        "claude-3-7-sonnet": "tier_3_15", "claude-3-7-sonnet-20250219": "tier_3_15", "claude-3-7-sonnet-20250219-v1:0": "tier_3_15",
        "claude-3-7-sonnet@20250219": "tier_3_15", "claude-sonnet-4-0": "tier_3_15", "claude-sonnet-4-20250514": "tier_3_15",
        "claude-sonnet-4-20250514-v1:0": "tier_3_15", "claude-sonnet-4@20250514": "tier_3_15", "claude-sonnet-4": "tier_3_15",
        "claude-sonnet-4-5": "tier_3_15", "claude-sonnet-4-5-20250929": "tier_3_15", "claude-sonnet-4-5-20250929-v1:0": "tier_3_15",
        "claude-sonnet-4-5@20250929": "tier_3_15", "claude-sonnet-4-6": "tier_3_15", "claude-sonnet-5": "tier_2_10",
        "claude-sonnet-5-5": "tier_2_10", "claude-opus-4-0": "tier_15_75", "claude-opus-4-20250514": "tier_15_75",
        "claude-opus-4-20250514-v1:0": "tier_15_75", "claude-opus-4@20250514": "tier_15_75", "claude-opus-4": "tier_15_75",
        "claude-opus-4-1": "tier_15_75", "claude-opus-4-1-20250805": "tier_15_75", "claude-opus-4-1-20250805-v1:0": "tier_15_75",
        "claude-opus-4-1@20250805": "tier_15_75", "claude-opus-4-5": "tier_5_25", "claude-opus-4-5-20251101": "tier_5_25",
        "claude-opus-4-5-20251101-v1:0": "tier_5_25", "claude-opus-4-5@20251101": "tier_5_25", "claude-opus-4-6": "tier_5_25",
        "claude-opus-4-6-v1": "tier_5_25", "claude-opus-4-7": "tier_5_25", "claude-opus-4-8": "tier_5_25",
        "claude-opus-5": "tier_5_25", "claude-opus-5-5": "tier_4_20_cache_read_0_20", "claude-fable-5": "tier_10_50",
        "claude-fable-5-1": "tier_10_50_cache_read_0_25", "claude-mythos-5": "tier_10_50", "claude-mythos-5-1": "tier_10_50_cache_read_0_25",
    ]
}

struct TokenPriceBook {
    var tiers: [String: TokenPrice]
    var models: [String: String]
    var source: String
    var note: String?            // 覆盖文件有问题时的说明

    static let builtIn = TokenPriceBook(tiers: TokenCatalog.tiers, models: TokenCatalog.models, source: TokenCatalog.source, note: nil)

    /// 型号名归一：去空白、转小写、去掉 Bedrock / Mantle 的 "us.anthropic." / "anthropic." 前缀
    static func normalize(_ model: String) -> String {
        var s = model.trimmingCharacters(in: .whitespaces).lowercased()
        if let r = s.range(of: #"^([a-z]+\.)?anthropic\."#, options: .regularExpression) { s.removeSubrange(r) }
        return s
    }

    /// 前缀之后剩下的部分是否只是"同一型号的变体"：日期（-20251001）、上下文档（[1m]）、云厂商版本（@… :… -v1）、-latest。
    /// claude-opus-5-7 不能因为以 claude-opus-5 开头就按它计价
    static func isVariantSuffix(_ rest: Substring) -> Bool {
        guard let c = rest.first else { return true }
        if c == "[" || c == "@" || c == ":" { return true }
        return String(rest).range(of: #"^-(\d{8}|v\d+|latest)\b"#, options: .regularExpression) != nil
    }

    /// 型号名 → (价格, 档位, 是否认识)；不认识按 tier_5_25 估
    func lookup(_ model: String) -> (price: TokenPrice, tier: String, known: Bool) {
        let m = Self.normalize(model)
        var tier = models[m]
        if tier == nil {
            var best = 0
            for (id, t) in models where id.count > best && m.hasPrefix(id) && Self.isVariantSuffix(m.dropFirst(id.count)) {
                best = id.count
                tier = t
            }
        }
        if let t = tier, let p = tiers[t] { return (p, t, true) }
        let fb = TokenCatalog.fallbackTier
        return (tiers[fb] ?? TokenCatalog.tiers[fb]!, fb, false)
    }

    /// 内置价格 + ~/.config/usagemaster/pricing.json（与内置目录同结构，只写要改的部分即可）：
    ///   {"pricing_tiers": {"tier_x": {"input": 3, "output": 15, "cache_write_5m": 3.75, "cache_write_1h": 6, "cache_read": 0.3}},
    ///    "models": [{"id": "claude-xxx", "pricing": "tier_x"}]}
    /// models 也可以写成 {"claude-xxx": "tier_x"}，"pricing_tier" 与 "pricing" 等价。档位只写了部分字段时，缺的沿用同名内置档位；
    /// 新档位缺缓存价时按标准倍率推（5 分钟缓存写 1.25×、1 小时写 2×、缓存读 0.1× 输入价）。
    static func load(overridePath: String) -> TokenPriceBook {
        var book = TokenPriceBook.builtIn
        guard FileManager.default.fileExists(atPath: overridePath) else { return book }
        guard let data = FileManager.default.contents(atPath: overridePath),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            book.note = L("pricing.json 不是合法的 JSON 对象，已忽略，按内置价格计",
                          "pricing.json is not a valid JSON object. It was ignored and built-in prices are used")
            return book
        }
        var notes: [String] = []
        if let tiers = obj["pricing_tiers"] as? [String: Any] {
            for (name, v) in tiers {
                guard let d = v as? [String: Any] else { notes.append(L("档位 \(name) 格式不对", "Tier \(name) has the wrong format")); continue }
                let base = book.tiers[name]
                guard let input = num(d["input"]) ?? base?.input, let output = num(d["output"]) ?? base?.output else {
                    notes.append(L("档位 \(name) 缺 input / output", "Tier \(name) is missing input / output")); continue
                }
                book.tiers[name] = TokenPrice(input: input, output: output,
                                              cacheWrite5m: num(d["cache_write_5m"]) ?? base?.cacheWrite5m ?? input * 1.25,
                                              cacheWrite1h: num(d["cache_write_1h"]) ?? base?.cacheWrite1h ?? input * 2,
                                              cacheRead: num(d["cache_read"]) ?? base?.cacheRead ?? input * 0.1)
            }
        }
        var pairs: [(String, String)] = []
        if let arr = obj["models"] as? [[String: Any]] {
            for m in arr {
                if let id = m["id"] as? String, let t = (m["pricing"] ?? m["pricing_tier"]) as? String { pairs.append((id, t)) }
            }
        } else if let dict = obj["models"] as? [String: Any] {
            for (id, t) in dict { if let t = t as? String { pairs.append((id, t)) } }
        }
        for (id, t) in pairs {
            guard book.tiers[t] != nil else { notes.append(L("型号 \(id) 指向不存在的档位 \(t)", "Model \(id) points to a nonexistent tier \(t)")); continue }
            book.models[normalize(id)] = t
        }
        book.source = TokenCatalog.source + L(" + 自定义 pricing.json", " + custom pricing.json")
        book.note = notes.isEmpty ? nil : notes.joined(separator: L("；", "; "))
        return book
    }
}

// MARK: - 数据模型

/// 一条去重后的回复：只有时间、字符串表下标与 token 数
struct TokenUsageRecord {
    var ts: Int                // Unix 秒
    var model: Int             // 以下三项是字符串表下标
    var cwd: Int
    var session: Int
    var input: Int
    var output: Int
    var cacheRead: Int
    var cacheWrite5m: Int
    var cacheWrite1h: Int
    var flags: Int             // bit0 = fast 模式（特殊计费，未计入）
}

struct TokenTotals {
    var input = 0
    var output = 0
    var cacheRead = 0
    var cacheWrite = 0         // 5 分钟 + 1 小时缓存写入
    var costUSD = 0.0
    var messages = 0           // 回复条数（去重后）
    var tokens: Int { input + output + cacheRead + cacheWrite }

    mutating func add(_ r: TokenUsageRecord, cost: Double) {
        input += r.input
        output += r.output
        cacheRead += r.cacheRead
        cacheWrite += r.cacheWrite5m + r.cacheWrite1h
        costUSD += cost
        messages += 1
    }
}

struct TokenDayStat {
    var day: Date              // 当地时间当天 0 点
    var totals: TokenTotals
}

struct TokenProjectStat {
    var root: String           // git 根目录（找不到就是 cwd）
    var name: String           // 显示名：最后一级目录名，重名时带上父目录
    var thisMonth: TokenTotals
    var last30Days: TokenTotals
    var sessions: Int          // 最近 30 天里的会话数
}

struct TokenModelStat {
    var model: String
    var tier: String
    var price: TokenPrice      // 计价用的单价（美元 / 百万 token）
    var unknown: Bool          // 不在价格表里，按 tier_5_25 估
    var thisMonth: TokenTotals
    var last30Days: TokenTotals
}

struct TokenSessionStat {
    var sessionId: String
    var project: String        // 显示名
    var projectRoot: String
    var mainModel: String      // 这个会话里花钱最多的型号
    var start: Date
    var end: Date
    var totals: TokenTotals
}

struct TokenStatsSummary {
    var today = TokenTotals()
    var last7Days = TokenTotals()       // 含今天的 7 个自然日
    var thisMonth = TokenTotals()
    var last30Days = TokenTotals()      // 含今天的 30 个自然日
    var allTime = TokenTotals()         // 缓存里能追溯到的全部
    var earliest: Date?
    var byDay: [TokenDayStat] = []      // 最近 60 天，升序，没用量的日子补 0
    var byProject: [TokenProjectStat] = []   // 本月或最近 30 天有用量的项目，按最近 30 天费用降序
    var byModel: [TokenModelStat] = []       // 同上，按型号
    var topSessions: [TokenSessionStat] = [] // 最近 30 天费用最高的 10 个会话
    var unknownModels: [String] = []         // 价格表里没有的型号名
    var fastModeMessages = 0                 // 最近 30 天 fast 模式回复数（按标准价算，特殊计费未计入）
    var scannedFiles = 0                     // 本次看到的 JSONL 文件数
    var filesRead = 0                        // 其中有新内容、实际读了的
    var newRecords = 0                       // 本次新增的回复数
    var totalRecords = 0                     // 缓存里的回复总数
    var scanSeconds = 0.0
    var lastScan = Date.distantPast
    var priceSource = TokenCatalog.source
    var priceNote: String?

    /// 按本月费用排序的项目
    var byProjectThisMonth: [TokenProjectStat] {
        byProject.filter { $0.thisMonth.messages > 0 }.sorted { $0.thisMonth.costUSD > $1.thisMonth.costUSD }
    }
}

// MARK: - 对外接口

/// 扫描（第一次全量、之后增量）并汇总。扫描在后台串行队列上做；progress 在后台线程回调（0…1），更新界面要自己切回主线程
func refreshTokenStats(progress: ((Double) -> Void)?) async -> TokenStatsSummary {
    await withCheckedContinuation { (cont: CheckedContinuation<TokenStatsSummary, Never>) in
        tokenStatsQueue.async { cont.resume(returning: tokenStatsShared.refresh(progress: progress)) }
    }
}

/// 最近一次的汇总（不扫描；还没扫过返回 nil），菜单打开时先用它显示
func cachedTokenStats() -> TokenStatsSummary? { tokenStatsShared.lastSummary }

/// 把还没写盘的缓存立即写盘（退出前调用；不调也不会算错，只是下次启动多读几行）
func flushTokenStatsCache() {
    tokenStatsQueue.sync { tokenStatsShared.flush() }
}

fileprivate let tokenStatsQueue = DispatchQueue(label: "io.github.wxy821018.usagemaster.tokenstats", qos: .utility)
fileprivate let tokenStatsShared = TokenStatsEngine(config: .standard)

// MARK: - 订阅对比

struct TokenSubscription {
    var name: String
    var monthlyUSD: Double
    var note: String? = nil
}

let tokenSubscriptionsPath = NSHomeDirectory() + "/.config/usagemaster/subscriptions.json"

/// 读订阅清单 ~/.config/usagemaster/subscriptions.json：[{"name": "...", "monthlyUSD": 200}, ...]（也接受 {"subscriptions": [...]}）。
/// 文件不存在时写一个占位示例：金额一律是 0，等用户自己填实际付的钱——这里不替用户猜任何价格。monthlyUSD 为 0 的条目等于没填。
func loadTokenSubscriptions(path: String = tokenSubscriptionsPath) -> [TokenSubscription] {
    let fm = FileManager.default
    if !fm.fileExists(atPath: path) {
        let example: [[String: Any]] = [[
            "name": L("Claude 订阅（改成你的套餐名，如 Max 20x）", "Claude subscription (change this to your plan name, e.g. Max 20x)"),
            "monthlyUSD": 0,
            "note": L("把 monthlyUSD 改成这个订阅每月实际付的美元金额；有几个订阅写几条，不用的整条删掉。monthlyUSD 为 0 的条目不计入。"
                        + "UsageMaster 拿「本期日志折合的 API 费用 − 本期订阅费（按天数折算）」算省下多少。",
                      "Set monthlyUSD to what you actually pay for this subscription each month, in US dollars. Add one entry per subscription "
                        + "and delete the ones you don't use. Entries with monthlyUSD 0 are not counted. "
                        + "UsageMaster computes savings as (API cost of this period's logs) − (this period's subscription fee, prorated by days)."),
        ]]
        if let data = try? JSONSerialization.data(withJSONObject: example, options: [.prettyPrinted, .sortedKeys]) {
            try? fm.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
        }
    }
    guard let data = fm.contents(atPath: path), let obj = try? JSONSerialization.jsonObject(with: data) else { return [] }
    let arr = (obj as? [[String: Any]]) ?? ((obj as? [String: Any])?["subscriptions"] as? [[String: Any]]) ?? []
    return arr.compactMap { d in
        guard let name = d["name"] as? String else { return nil }
        return TokenSubscription(name: name, monthlyUSD: max(0, num(d["monthlyUSD"]) ?? 0), note: d["note"] as? String)
    }
}

enum TokenSavingsPeriod { case thisMonth, last30Days }

struct TokenSavings {
    var label: String              // "本月 1–3 日（3/31 天）"
    var apiCostUSD: Double         // 本期日志折合的 API 费用
    var subscriptionUSD: Double    // 本期订阅费（按天数折算）
    var hasSubscriptions: Bool     // 有没有填了金额的订阅
    var savedUSD: Double { apiCostUSD - subscriptionUSD }
}

/// 省下的钱 = 本期折合 API 费用 − 本期订阅费。本月：月费 × 已过天数 / 本月天数（今天算一整天）；最近 30 天：月费 × 30 × 12 / 365
func tokenSavings(_ s: TokenStatsSummary, subscriptions: [TokenSubscription], period: TokenSavingsPeriod = .thisMonth) -> TokenSavings {
    let monthly = subscriptions.reduce(0) { $0 + $1.monthlyUSD }
    let cal = Calendar.current
    let now = s.lastScan == .distantPast ? Date() : s.lastScan
    switch period {
    case .thisMonth:
        let day = cal.component(.day, from: now)
        let days = cal.range(of: .day, in: .month, for: now)?.count ?? 30
        return TokenSavings(label: L("本月 1–\(day) 日（\(day)/\(days) 天）", "This month, days 1–\(day) (\(day)/\(days) days)"), apiCostUSD: s.thisMonth.costUSD,
                            subscriptionUSD: monthly * Double(day) / Double(days), hasSubscriptions: monthly > 0)
    case .last30Days:
        return TokenSavings(label: L("最近 30 天", "Last 30 days"), apiCostUSD: s.last30Days.costUSD,
                            subscriptionUSD: monthly * 30 * 12 / 365, hasSubscriptions: monthly > 0)
    }
}

// MARK: - 扫描引擎

struct TokenStatsConfig {
    var roots: () -> [String]      // 每次扫描前重新取（新加的账号目录下次就能扫到）
    var cachePath: String
    var pricingPath: String
    /// 两次写缓存至少隔多久（秒）。正在进行的会话每次刷新都有新行，没必要每次都写 4MB；
    /// 缓存旧一点也不会算错——偏移落后只是多读几行，按最大值合并结果不变
    var minSaveInterval: TimeInterval = 600

    static let standard = TokenStatsConfig(roots: tsStandardRoots,
                                           cachePath: appDataDir + "/token_cache.json",
                                           pricingPath: NSHomeDirectory() + "/.config/usagemaster/pricing.json")
}

/// 扫描根目录：存在的才返回
fileprivate func tsStandardRoots() -> [String] {
    let home = NSHomeDirectory()
    let fm = FileManager.default
    func subdirs(_ p: String) -> [String] {
        ((try? fm.contentsOfDirectory(atPath: p)) ?? []).sorted().map { p + "/" + $0 }
    }
    var out = [home + "/.claude/projects"]
    out += subdirs(home + "/.config/usagemaster/claude").map { $0 + "/projects" }
    out += subdirs(orcaClaudeAccountsDir).map { $0 + "/auth/projects" }
    return out.filter { var d: ObjCBool = false; return fm.fileExists(atPath: $0, isDirectory: &d) && d.boolValue }
}

fileprivate struct TSFileState {
    var offset: Int        // 已处理到的字节（最后一个完整行之后）
    var size: Int
    var mtimeMs: Int
}

/// 不是线程安全的：refresh 只在 tokenStatsQueue（或测试的单线程）里调；lastSummary 有锁
final class TokenStatsEngine: @unchecked Sendable {
    static let cacheVersion = 1
    static let keepDays = 400

    let config: TokenStatsConfig
    private var loaded = false
    private var dirty = false
    private var files: [String: TSFileState] = [:]
    private var strings: [String] = []
    private var stringIndex: [String: Int] = [:]
    private var records: [UInt64: TokenUsageRecord] = [:]
    private var roots: [String: String] = [:]        // cwd → 项目根（随缓存保存）
    private var unsureRoots: [String: String] = [:]  // 查找时被系统权限挡住的（如没授权访问"桌面"）：只记在内存，下次启动重查
    private var added = 0
    private var lastSave = Date.distantPast
    private let lock = NSLock()
    private var _last: TokenStatsSummary?

    init(config: TokenStatsConfig) { self.config = config }

    var lastSummary: TokenStatsSummary? {
        lock.lock(); defer { lock.unlock() }
        return _last
    }

    func refresh(now: Date = Date(), progress: ((Double) -> Void)? = nil) -> TokenStatsSummary {
        let t0 = Date()
        loadIfNeeded()
        let prices = TokenPriceBook.load(overridePath: config.pricingPath)
        let (seen, read) = scan(progress: progress)
        var s = summarize(now: now, prices: prices)
        if dirty && Date().timeIntervalSince(lastSave) >= config.minSaveInterval { save(now: now) }
        s.scannedFiles = seen
        s.filesRead = read
        s.newRecords = added
        s.totalRecords = records.count
        s.lastScan = Date()
        s.scanSeconds = s.lastScan.timeIntervalSince(t0)
        s.priceSource = prices.source
        s.priceNote = prices.note
        lock.lock(); _last = s; lock.unlock()
        return s
    }

    func flush() {
        if dirty { save(now: Date()) }
    }

    // MARK: 扫描

    /// 返回 (看到的文件数, 实际读了的文件数)
    private func scan(progress: ((Double) -> Void)?) -> (Int, Int) {
        added = 0
        progress?(0)
        let list = listFiles()
        var todo: [(path: String, size: Int, mtimeMs: Int, start: Int)] = []
        for f in list {
            var start = 0
            if let o = files[f.path] {
                if o.size == f.size && o.mtimeMs == f.mtimeMs { continue }            // 没变
                if f.size >= o.offset && f.mtimeMs >= o.mtimeMs { start = o.offset }   // 只追加了：接着读
                // 否则被截短 / mtime 变小：从头重扫
            }
            todo.append((f.path, f.size, f.mtimeMs, start))
        }
        // 已经不存在的文件只删状态，记录保留（Claude Code 会清旧日志，历史靠缓存留住）
        let present = Set(list.map { $0.path })
        if files.keys.contains(where: { !present.contains($0) }) {
            files = files.filter { present.contains($0.key) }
            dirty = true
        }
        let total = todo.reduce(0) { $0 + max(0, $1.size - $1.start) }
        var done = 0, reported = 0.0
        for f in todo {
            // 每个文件一个 autoreleasepool：后台线程没有 runloop 帮忙清，读 2GB 日志时临时对象会一直堆着
            let end = autoreleasepool {
                readFile(f.path, start: f.start, size: f.size) { n in
                    done += n
                    guard total > 0 else { return }
                    let p = Double(done) / Double(total)
                    if p - reported >= 0.01 { reported = p; progress?(min(p, 1)) }
                }
            }
            if let end = end {
                files[f.path] = TSFileState(offset: end, size: f.size, mtimeMs: f.mtimeMs)
                dirty = true
            }
        }
        progress?(1)
        return (list.count, todo.count)
    }

    /// 递归找 *.jsonl。跟随软链目录（projects 里常有指向别的项目目录的软链），按文件身份去重（macOS 是设备 + inode，
    /// Windows 是卷序列号 + 文件索引；Windows 的 stat 里 inode 恒为 0，不能用），目录环也靠它挡住
    private func listFiles() -> [(path: String, size: Int, mtimeMs: Int)] {
        var out: [(path: String, size: Int, mtimeMs: Int)] = []
        var seenFiles = Set<String>(), seenDirs = Set<String>()
        let fm = FileManager.default
        for root in config.roots() {
            var stack = [root]
            while let dir = stack.popLast() {
                guard case .ok(let di) = fileInfo(dir), di.isDirectory, seenDirs.insert(di.identity).inserted else { continue }
                autoreleasepool {
                    for name in (try? fm.contentsOfDirectory(atPath: dir)) ?? [] {
                        let p = dir + "/" + name
                        guard case .ok(let fi) = fileInfo(p) else { continue }
                        if fi.isDirectory { stack.append(p); continue }
                        guard fi.isRegularFile, name.hasSuffix(".jsonl"), seenFiles.insert(fi.identity).inserted else { continue }
                        out.append((p, fi.size, fi.mtimeMs))
                    }
                }
            }
        }
        return out
    }

    /// 从 start 读到 size，逐个完整行处理；返回新的偏移（最后一个完整行之后）。打不开返回 nil
    private func readFile(_ path: String, start: Int, size: Int, onBytes: (Int) -> Void) -> Int? {
        guard let fh = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? fh.close() }
        var start = start
        if start > 0 {
            // 接着读之前确认上次停在行尾；不是（文件被整个改写过）就从头来
            try? fh.seek(toOffset: UInt64(start - 1))
            let prev = (try? fh.read(upToCount: 1)) ?? Data()
            if prev.first != 0x0A { start = 0 }
        }
        guard (try? fh.seek(toOffset: UInt64(start))) != nil else { return nil }
        var pos = start
        var remaining = size - start
        var carry = Data()
        let chunkSize = 4 << 20
        while remaining > 0 {
            guard let chunk = try? fh.read(upToCount: min(chunkSize, remaining)), !chunk.isEmpty else { break }
            remaining -= chunk.count
            let buf: Data
            if carry.isEmpty { buf = chunk } else { carry.append(chunk); buf = carry }
            let consumed = autoreleasepool { buf.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Int in
                guard let base = raw.baseAddress else { return 0 }
                let p = base.assumingMemoryBound(to: UInt8.self)
                var lineStart = 0
                while lineStart < raw.count {
                    guard let nl = memchr(base + lineStart, 0x0A, raw.count - lineStart) else { break }
                    let e = base.distance(to: UnsafeRawPointer(nl))
                    if let x = tsParseLine(p + lineStart, e - lineStart) { ingest(x) }
                    lineStart = e + 1
                }
                return lineStart
            } }
            pos += consumed
            carry = consumed < buf.count ? buf.subdata(in: consumed..<buf.count) : Data()
            onBytes(chunk.count)
        }
        return pos
    }

    private func intern(_ s: String) -> Int {
        if let i = stringIndex[s] { return i }
        strings.append(s)
        stringIndex[s] = strings.count - 1
        return strings.count - 1
    }

    private func ingest(_ x: TSParsedLine) {
        let rec = TokenUsageRecord(ts: x.ts, model: intern(x.model), cwd: intern(x.cwd), session: intern(x.session),
                                   input: x.input, output: x.output, cacheRead: x.cacheRead,
                                   cacheWrite5m: x.cacheWrite5m, cacheWrite1h: x.cacheWrite1h, flags: x.fast ? 1 : 0)
        guard var old = records[x.key] else {
            records[x.key] = rec
            added += 1
            dirty = true
            return
        }
        // 同一条回复再次出现：各字段取最大值（流式快照里 output 逐行变大；跨文件的副本完全相同）。
        // 会话续接（--resume / --continue）会把旧回复连同时间戳抄进新会话的文件，同一条回复就挂在两个会话下：
        // 归属取（时间、会话 id、目录）最小的那一份，与读文件的先后无关，全量重扫和增量扫描结果一致
        let takeNew = rec.session != old.session || rec.cwd != old.cwd
            ? (rec.ts, strings[rec.session], strings[rec.cwd]) < (old.ts, strings[old.session], strings[old.cwd])
            : false
        let merged = TokenUsageRecord(ts: min(old.ts, rec.ts), model: old.model,
                                      cwd: takeNew ? rec.cwd : old.cwd, session: takeNew ? rec.session : old.session,
                                      input: max(old.input, rec.input), output: max(old.output, rec.output),
                                      cacheRead: max(old.cacheRead, rec.cacheRead),
                                      cacheWrite5m: max(old.cacheWrite5m, rec.cacheWrite5m),
                                      cacheWrite1h: max(old.cacheWrite1h, rec.cacheWrite1h), flags: old.flags | rec.flags)
        if merged.ts != old.ts || merged.session != old.session || merged.cwd != old.cwd || merged.input != old.input || merged.output != old.output || merged.cacheRead != old.cacheRead
            || merged.cacheWrite5m != old.cacheWrite5m || merged.cacheWrite1h != old.cacheWrite1h || merged.flags != old.flags {
            old = merged
            records[x.key] = old
            dirty = true
        }
    }

    // MARK: 项目归属

    /// cwd → git 根目录（向上找 .git；git worktree 归到主仓库）；找不到就用 cwd 本身。结果缓存并随 token_cache.json 保存
    private func projectRoot(_ cwd: String) -> String {
        if let r = roots[cwd] ?? unsureRoots[cwd] { return r }
        let (r, sure) = tsResolveGitRoot(cwd)
        if sure {
            roots[cwd] = r
            dirty = true
        } else {
            unsureRoots[cwd] = r
        }
        return r
    }

    // MARK: 汇总

    private func summarize(now: Date, prices: TokenPriceBook) -> TokenStatsSummary {
        let cal = Calendar.current
        let todayStart = cal.startOfDay(for: now)
        var dayStarts: [Int] = []       // 60 个当地 0 点，升序；dayStarts[59] = 今天
        for i in stride(from: 59, through: 0, by: -1) {
            dayStarts.append(Int((cal.date(byAdding: .day, value: -i, to: todayStart) ?? todayStart).timeIntervalSince1970))
        }
        let monthStart = Int((cal.date(from: cal.dateComponents([.year, .month], from: now)) ?? todayStart).timeIntervalSince1970)
        let cutoff = Int(now.timeIntervalSince1970) - Self.keepDays * 86400

        // 累加器一律按字符串表下标开数组：项目路径多是中文，拿 String 当字典键每次都要做 Unicode 归一化哈希，5 万条就要几百毫秒
        let ns = strings.count
        var s = TokenStatsSummary()
        var days = Array(repeating: TokenTotals(), count: 60)
        var priceOf = [(price: TokenPrice, tier: String, known: Bool)?](repeating: nil, count: ns)
        var rootOfCwd = [Int](repeating: -1, count: ns)          // cwd 下标 → 项目编号
        var rootPaths: [String] = [], rootIds: [String: Int] = [:]
        var projMonth: [TokenTotals] = [], proj30: [TokenTotals] = [], projSessions: [Set<Int>] = []
        var modelMonth = [TokenTotals](repeating: TokenTotals(), count: ns), model30 = modelMonth
        var sessTotals = [TokenTotals](repeating: TokenTotals(), count: ns)
        var sessStart = [Int](repeating: Int.max, count: ns), sessEnd = [Int](repeating: 0, count: ns), sessCwd = [Int](repeating: 0, count: ns)
        var sessModelCost: [Int: Double] = [:]                   // 会话下标 × ns + 型号下标 → 费用
        var unknown = [Int](repeating: 0, count: ns)
        var earliest = Int.max
        var expired: [UInt64] = []

        for (key, r) in records {
            if r.ts < cutoff { expired.append(key); continue }
            let pr: (price: TokenPrice, tier: String, known: Bool)
            if let p = priceOf[r.model] { pr = p } else { pr = prices.lookup(strings[r.model]); priceOf[r.model] = pr }
            let cost = pr.price.cost(input: r.input, output: r.output, cacheRead: r.cacheRead,
                                     cacheWrite5m: r.cacheWrite5m, cacheWrite1h: r.cacheWrite1h)
            s.allTime.add(r, cost: cost)
            earliest = min(earliest, r.ts)
            if !pr.known { unknown[r.model] += r.input + r.output + r.cacheRead + r.cacheWrite5m + r.cacheWrite1h }
            // 落在最近 60 天的哪一天（二分找最后一个 ≤ ts 的 0 点；晚于今天的时间戳算今天）
            var k = -1
            if r.ts >= dayStarts[0] {
                var lo = 0, hi = 59
                while lo < hi { let mid = (lo + hi + 1) / 2; if dayStarts[mid] <= r.ts { lo = mid } else { hi = mid - 1 } }
                k = lo
                days[k].add(r, cost: cost)
            }
            let in30 = k >= 30, inMonth = r.ts >= monthStart
            if k == 59 { s.today.add(r, cost: cost) }
            if k >= 53 { s.last7Days.add(r, cost: cost) }
            if inMonth { s.thisMonth.add(r, cost: cost) }
            guard in30 || inMonth else { continue }
            var pid = rootOfCwd[r.cwd]
            if pid < 0 {
                let root = projectRoot(strings[r.cwd])
                if let x = rootIds[root] { pid = x } else {
                    pid = rootPaths.count
                    rootIds[root] = pid
                    rootPaths.append(root)
                    projMonth.append(TokenTotals()); proj30.append(TokenTotals()); projSessions.append([])
                }
                rootOfCwd[r.cwd] = pid
            }
            if inMonth { projMonth[pid].add(r, cost: cost); modelMonth[r.model].add(r, cost: cost) }
            guard in30 else { continue }
            s.last30Days.add(r, cost: cost)
            proj30[pid].add(r, cost: cost)
            projSessions[pid].insert(r.session)
            model30[r.model].add(r, cost: cost)
            if r.flags & 1 != 0 { s.fastModeMessages += 1 }
            sessTotals[r.session].add(r, cost: cost)
            if r.ts < sessStart[r.session] { sessStart[r.session] = r.ts; sessCwd[r.session] = r.cwd }   // 会话按第一条回复的目录归项目
            sessEnd[r.session] = max(sessEnd[r.session], r.ts)
            sessModelCost[r.session * ns + r.model, default: 0] += cost
        }
        if !expired.isEmpty {
            for key in expired { records[key] = nil }
            dirty = true
        }

        s.earliest = earliest == Int.max ? nil : Date(timeIntervalSince1970: TimeInterval(earliest))
        s.byDay = (0..<60).map { TokenDayStat(day: Date(timeIntervalSince1970: TimeInterval(dayStarts[$0])), totals: days[$0]) }
        let names = tsDisplayNames(rootPaths)
        s.byProject = rootPaths.indices.map {
            TokenProjectStat(root: rootPaths[$0], name: names[rootPaths[$0]] ?? rootPaths[$0], thisMonth: projMonth[$0],
                             last30Days: proj30[$0], sessions: projSessions[$0].count)
        }.sorted { ($0.last30Days.costUSD, $0.thisMonth.costUSD) > ($1.last30Days.costUSD, $1.thisMonth.costUSD) }
        s.byModel = (0..<ns).filter { modelMonth[$0].messages > 0 || model30[$0].messages > 0 }.map { m -> TokenModelStat in
            let pr = priceOf[m] ?? prices.lookup(strings[m])
            return TokenModelStat(model: strings[m], tier: pr.tier, price: pr.price, unknown: !pr.known,
                                  thisMonth: modelMonth[m], last30Days: model30[m])
        }.sorted { ($0.last30Days.costUSD, $0.thisMonth.costUSD) > ($1.last30Days.costUSD, $1.thisMonth.costUSD) }
        var mainModel: [Int: (model: Int, cost: Double)] = [:]
        for (k, c) in sessModelCost where c > (mainModel[k / ns]?.cost ?? -1) { mainModel[k / ns] = (k % ns, c) }
        s.topSessions = (0..<ns).filter { sessTotals[$0].messages > 0 }
            .sorted { sessTotals[$0].costUSD > sessTotals[$1].costUSD }.prefix(10).map { i in
                let root = rootOfCwd[sessCwd[i]] >= 0 ? rootPaths[rootOfCwd[sessCwd[i]]] : projectRoot(strings[sessCwd[i]])
                return TokenSessionStat(sessionId: strings[i], project: names[root] ?? root, projectRoot: root,
                                        mainModel: mainModel[i].map { strings[$0.model] } ?? "",
                                        start: Date(timeIntervalSince1970: TimeInterval(sessStart[i])),
                                        end: Date(timeIntervalSince1970: TimeInterval(sessEnd[i])), totals: sessTotals[i])
            }
        s.unknownModels = (0..<ns).filter { unknown[$0] > 0 || (priceOf[$0].map { !$0.known } ?? false) }
            .sorted { unknown[$0] > unknown[$1] }.map { strings[$0] }
        return s
    }

    // MARK: 缓存读写

    private func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        guard let data = FileManager.default.contents(atPath: config.cachePath),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              (obj["version"] as? Int) == Self.cacheVersion,
              let strs = obj["strings"] as? [String],
              let fs = obj["files"] as? [String: [Int]],
              let rs = obj["records"] as? [[Any]] else { return }
        var recs: [UInt64: TokenUsageRecord] = [:]
        recs.reserveCapacity(rs.count)
        for a in rs {
            // ["键(16 进制)", ts, model, cwd, session, input, output, cacheRead, cacheWrite5m, cacheWrite1h, flags]
            guard a.count >= 11, let ks = a[0] as? String, let k = UInt64(ks, radix: 16) else { return }
            var v: [Int] = []
            for x in a[1...] { guard let n = x as? NSNumber else { return }; v.append(n.intValue) }
            guard v[1] >= 0, v[1] < strs.count, v[2] >= 0, v[2] < strs.count, v[3] >= 0, v[3] < strs.count else { return }   // 坏缓存：整个不用，全量重扫
            recs[k] = TokenUsageRecord(ts: v[0], model: v[1], cwd: v[2], session: v[3], input: v[4], output: v[5],
                                       cacheRead: v[6], cacheWrite5m: v[7], cacheWrite1h: v[8], flags: v[9])
        }
        var st: [String: TSFileState] = [:]
        for (p, v) in fs where v.count >= 3 { st[p] = TSFileState(offset: v[0], size: v[1], mtimeMs: v[2]) }
        strings = strs
        stringIndex = [:]
        for (i, x) in strs.enumerated() where stringIndex[x] == nil { stringIndex[x] = i }
        records = recs
        files = st
        roots = obj["roots"] as? [String: String] ?? [:]
        lastSave = Date()       // 盘上的缓存此刻与内存一致
    }

    private func save(now: Date) {
        var recs: [[Any]] = []
        recs.reserveCapacity(records.count)
        for (k, r) in records {
            recs.append([String(k, radix: 16), r.ts, r.model, r.cwd, r.session, r.input, r.output,
                         r.cacheRead, r.cacheWrite5m, r.cacheWrite1h, r.flags])
        }
        var fs: [String: [Int]] = [:]
        for (p, v) in files { fs[p] = [v.offset, v.size, v.mtimeMs] }
        let obj: [String: Any] = ["version": Self.cacheVersion, "savedAt": Int(now.timeIntervalSince1970),
                                  "note": L("UsageMaster token 统计缓存：只有 token 数与元数据（时间、模型、目录、会话 id），不含对话内容。删掉会在下次全量重扫。",
                                            "UsageMaster token stats cache: only token counts and metadata (time, model, directory, session id), no conversation content. Deleting it triggers a full rescan next time."),
                                  "strings": strings, "files": fs, "roots": roots, "records": recs]
        guard let data = try? JSONSerialization.data(withJSONObject: obj) else { return }
        let url = URL(fileURLWithPath: config.cachePath)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if (try? data.write(to: url, options: .atomic)) != nil {
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            dirty = false
            lastSave = Date()
        }
    }
}

// MARK: - 项目根与显示名

/// 向上找 .git；.git 是文件且指向 <主仓库>/.git/worktrees/<名字> 时归到主仓库。结果去掉软链。
/// 返回 (项目根, 是否确定)：途中被系统权限挡住（EPERM / EACCES，常见于没授权的"桌面""文稿"或外接卷）就不算确定
fileprivate func tsResolveGitRoot(_ cwd: String) -> (String, Bool) {
    var dir = cwd
    var sure = true
    while !dir.isEmpty {
        let git = (dir == "/" ? "" : dir) + "/.git"
        let gi = fileInfo(git)
        if case .ok(let info) = gi {
            if info.isRegularFile, let s = try? String(contentsOfFile: git, encoding: .utf8),
               let line = s.split(separator: "\n").first, line.hasPrefix("gitdir:") {
                var gd = line.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespaces)
                if !isAbsolutePath(gd) { gd = dir + "/" + gd }       // Windows 上 git 写的是 C:/repo/.git/worktrees/x
                if let r = gd.range(of: "/.git/worktrees/") { return (tsRealPath(String(gd[..<r.lowerBound])), true) }
            }
            return (tsRealPath(dir), true)
        }
        if case .denied = gi { sure = false }
        if dir == "/" { break }
        dir = (dir as NSString).deletingLastPathComponent
    }
    return (cwd, sure)
}

fileprivate func tsRealPath(_ p: String) -> String { realPath(p) }

/// 项目显示名：最后一级目录名（主目录显示 ~）；重名时带上父目录，再重名用完整路径
fileprivate func tsDisplayNames(_ roots: [String]) -> [String: String] {
    let home = NSHomeDirectory()
    func last(_ p: String) -> String {
        if p.isEmpty { return L("（未知目录）", "(unknown directory)") }
        if p == home { return "~" }
        let l = (p as NSString).lastPathComponent
        return l.isEmpty ? p : l
    }
    func withParent(_ p: String) -> String {
        let parent = ((p as NSString).deletingLastPathComponent as NSString).lastPathComponent
        return parent.isEmpty || parent == "/" || p == home ? last(p) : parent + "/" + last(p)
    }
    func abbreviated(_ p: String) -> String { p.hasPrefix(home + "/") ? "~" + String(p.dropFirst(home.count)) : p }
    var out: [String: String] = [:]
    for (name, rs) in Dictionary(grouping: roots, by: last) {
        if rs.count == 1 { out[rs[0]] = name; continue }
        for (n2, rs2) in Dictionary(grouping: rs, by: withParent) {
            for r in rs2 { out[r] = rs2.count == 1 ? n2 : abbreviated(r) }
        }
    }
    return out
}

// MARK: - 行解析（只认 JSON 结构边界，字符串内容不解码）

fileprivate struct TSParsedLine {
    var key: UInt64
    var ts: Int
    var model: String
    var cwd: String
    var session: String
    var input: Int
    var output: Int
    var cacheRead: Int
    var cacheWrite5m: Int
    var cacheWrite1h: Int
    var fast: Bool
}

fileprivate let tsNeedleUsage: StaticString = "\"usage\""
fileprivate let tsNeedleAssistant: StaticString = "\"assistant\""

/// 一行 JSON 的结构扫描器：只认字符串 / 对象 / 数组的边界；对话正文所在的字符串整段用 memchr 跳过，不解码
fileprivate struct TSScanner {
    let b: UnsafePointer<UInt8>
    let n: Int

    @inline(__always) func skipWS(_ i: Int) -> Int {
        var j = i
        while j < n {
            let c = b[j]
            if c != 0x20 && c != 0x0A && c != 0x0D && c != 0x09 { break }
            j += 1
        }
        return j
    }

    /// i 指向开引号，返回闭引号之后的位置
    func stringEnd(_ i: Int) -> Int? {
        let base = UnsafeRawPointer(b)
        var j = i + 1
        while j < n {
            guard let q = memchr(base + j, 0x22, n - j) else { return nil }
            let k = base.distance(to: UnsafeRawPointer(q))
            var t = k - 1, slashes = 0
            while t > i && b[t] == 0x5C { slashes += 1; t -= 1 }
            if slashes % 2 == 0 { return k + 1 }
            j = k + 1
        }
        return nil
    }

    func containerEnd(_ i: Int) -> Int? {
        var depth = 0, j = i
        while j < n {
            let c = b[j]
            if c == 0x22 {
                guard let e = stringEnd(j) else { return nil }
                j = e
                continue
            }
            if c == 0x7B || c == 0x5B {
                depth += 1
            } else if c == 0x7D || c == 0x5D {
                depth -= 1
                if depth == 0 { return j + 1 }
            }
            j += 1
        }
        return nil
    }

    func valueEnd(_ i: Int) -> Int? {
        guard i < n else { return nil }
        let c = b[i]
        if c == 0x22 { return stringEnd(i) }
        if c == 0x7B || c == 0x5B { return containerEnd(i) }
        var j = i
        while j < n {
            let d = b[j]
            if d == 0x2C || d == 0x7D || d == 0x5D || d == 0x20 || d == 0x0A || d == 0x0D || d == 0x09 { break }
            j += 1
        }
        return j > i ? j : nil
    }

    /// i 指向 '{'：依次把每个成员交给 body(键起, 键止, 值起)；body 自己处理了值就返回值的结束位置，否则返回 nil 由这里跳过。
    /// 返回对象结束之后的位置；结构坏了返回 nil
    func members(_ i: Int, _ body: (Int, Int, Int) -> Int?) -> Int? {
        guard i < n, b[i] == 0x7B else { return nil }
        var j = skipWS(i + 1)
        if j < n && b[j] == 0x7D { return j + 1 }
        while j < n {
            guard b[j] == 0x22, let ke = stringEnd(j) else { return nil }
            var v = skipWS(ke)
            guard v < n, b[v] == 0x3A else { return nil }
            v = skipWS(v + 1)
            guard let ve = body(j + 1, ke - 1, v) ?? valueEnd(v) else { return nil }
            j = skipWS(ve)
            guard j < n else { return nil }
            if b[j] == 0x2C { j = skipWS(j + 1); continue }
            if b[j] == 0x7D { return j + 1 }
            return nil
        }
        return nil
    }

    func keyIs(_ ks: Int, _ ke: Int, _ k: StaticString) -> Bool {
        ke - ks == k.utf8CodeUnitCount && memcmp(b + ks, k.utf8Start, ke - ks) == 0
    }

    /// 值区间 [vs, ve) 是 JSON 字符串时取出它（只用于时间、目录、id、型号这些短字段）
    func string(_ vs: Int, _ ve: Int) -> String? {
        guard ve - vs >= 2, b[vs] == 0x22 else { return nil }
        let s = vs + 1, len = ve - 1 - s
        if len == 0 || memchr(b + s, 0x5C, len) == nil {
            return String(decoding: UnsafeBufferPointer(start: b + s, count: len), as: UTF8.self)
        }
        return (try? JSONSerialization.jsonObject(with: Data(bytes: b + vs, count: ve - vs), options: .fragmentsAllowed)) as? String
    }
}

/// 解析一行；不是带 usage 的 assistant 行、或是 <synthetic>（本地生成的报错消息，token 全 0）返回 nil
fileprivate func tsParseLine(_ b: UnsafePointer<UInt8>, _ n: Int) -> TSParsedLine? {
    guard n > 2,
          memmem(b, n, tsNeedleUsage.utf8Start, tsNeedleUsage.utf8CodeUnitCount) != nil,
          memmem(b, n, tsNeedleAssistant.utf8Start, tsNeedleAssistant.utf8CodeUnitCount) != nil else { return nil }
    let sc = TSScanner(b: b, n: n)
    var isAssistant = false
    var tsV: (Int, Int)?, cwdV: (Int, Int)?, sessV: (Int, Int)?, sess2V: (Int, Int)?, reqV: (Int, Int)?
    var idV: (Int, Int)?, modelV: (Int, Int)?, usageV: (Int, Int)?
    let ok = sc.members(sc.skipWS(0)) { ks, ke, vs in
        if sc.keyIs(ks, ke, "type") {
            guard let e = sc.valueEnd(vs) else { return nil }
            isAssistant = e - vs == 11 && memcmp(b + vs, tsNeedleAssistant.utf8Start, 11) == 0
            return e
        }
        if sc.keyIs(ks, ke, "message") {
            guard vs < n, b[vs] == 0x7B else { return nil }
            return sc.members(vs) { mks, mke, mvs in
                if sc.keyIs(mks, mke, "id") { let e = sc.valueEnd(mvs); if let e = e { idV = (mvs, e) }; return e }
                if sc.keyIs(mks, mke, "model") { let e = sc.valueEnd(mvs); if let e = e { modelV = (mvs, e) }; return e }
                if sc.keyIs(mks, mke, "usage") { let e = sc.valueEnd(mvs); if let e = e { usageV = (mvs, e) }; return e }
                return nil     // content 等其它字段：由 members 按结构跳过
            }
        }
        if sc.keyIs(ks, ke, "timestamp") { let e = sc.valueEnd(vs); if let e = e { tsV = (vs, e) }; return e }
        if sc.keyIs(ks, ke, "cwd") { let e = sc.valueEnd(vs); if let e = e { cwdV = (vs, e) }; return e }
        if sc.keyIs(ks, ke, "sessionId") { let e = sc.valueEnd(vs); if let e = e { sessV = (vs, e) }; return e }
        if sc.keyIs(ks, ke, "session_id") { let e = sc.valueEnd(vs); if let e = e { sess2V = (vs, e) }; return e }
        if sc.keyIs(ks, ke, "requestId") { let e = sc.valueEnd(vs); if let e = e { reqV = (vs, e) }; return e }
        return nil
    }
    guard ok != nil, isAssistant, let u = usageV, let id = idV, b[u.0] == 0x7B else { return nil }
    let model = modelV.flatMap { sc.string($0.0, $0.1) } ?? ""
    if model == "<synthetic>" { return nil }
    guard let usage = (try? JSONSerialization.jsonObject(with: Data(bytes: b + u.0, count: u.1 - u.0))) as? [String: Any] else { return nil }
    func count(_ v: Any?) -> Int {
        guard let d = num(v), d.isFinite, d > 0, d < 1e15 else { return 0 }
        return Int(d)
    }
    let ccTotal = count(usage["cache_creation_input_tokens"])
    var w5 = ccTotal, w1 = 0
    if let cc = usage["cache_creation"] as? [String: Any] {
        w5 = count(cc["ephemeral_5m_input_tokens"])
        w1 = count(cc["ephemeral_1h_input_tokens"])
        if w5 + w1 < ccTotal { w5 += ccTotal - w5 - w1 }    // 拆分不全：差额按 5 分钟算
    }
    guard let t = tsV, t.1 - t.0 >= 2 else { return nil }    // 没时间的行无法归到哪天
    let ts = tsParseTimestamp(b, t.0 + 1, t.1 - 1)
        ?? parseISO(sc.string(t.0, t.1)).map { Int($0.timeIntervalSince1970) }
    guard let ts = ts else { return nil }
    var h = tsFNV(b, id.0, id.1, 0xcbf2_9ce4_8422_2325)
    h = (h ^ 0xFF) &* 0x0000_0100_0000_01B3
    if let r = reqV { h = tsFNV(b, r.0, r.1, h) }
    return TSParsedLine(key: h, ts: ts, model: model,
                        cwd: cwdV.flatMap { sc.string($0.0, $0.1) } ?? "",
                        session: (sessV ?? sess2V).flatMap { sc.string($0.0, $0.1) } ?? "",
                        input: count(usage["input_tokens"]), output: count(usage["output_tokens"]),
                        cacheRead: count(usage["cache_read_input_tokens"]), cacheWrite5m: w5, cacheWrite1h: w1,
                        fast: (usage["speed"] as? String) == "fast")
}

/// FNV-1a 64 位，键只用来去重（消息 id + 请求 id 的原始字节）
fileprivate func tsFNV(_ b: UnsafePointer<UInt8>, _ s: Int, _ e: Int, _ seed: UInt64) -> UInt64 {
    var h = seed
    var i = s
    while i < e { h = (h ^ UInt64(b[i])) &* 0x0000_0100_0000_01B3; i += 1 }
    return h
}

/// "2026-08-24T05:30:39.211Z" 这种 UTC 时间的快速解析（日志里全是这个格式，比 ISO8601DateFormatter 快两个数量级）。
/// [s, e) 是引号里的内容；别的格式返回 nil，由调用方退回 parseISO
fileprivate func tsParseTimestamp(_ b: UnsafePointer<UInt8>, _ s: Int, _ e: Int) -> Int? {
    let n = e - s
    guard n >= 20, b[e - 1] == 0x5A, b[s + 4] == 0x2D, b[s + 7] == 0x2D, b[s + 10] == 0x54,
          b[s + 13] == 0x3A, b[s + 16] == 0x3A else { return nil }
    func digits(_ i: Int, _ len: Int) -> Int? {
        var x = 0
        for k in (s + i)..<(s + i + len) {
            let c = b[k]
            guard c >= 0x30 && c <= 0x39 else { return nil }
            x = x * 10 + Int(c - 0x30)
        }
        return x
    }
    guard let y = digits(0, 4), let mo = digits(5, 2), let d = digits(8, 2), let h = digits(11, 2),
          let mi = digits(14, 2), let se = digits(17, 2),
          (1...12).contains(mo), (1...31).contains(d), h < 24, mi < 60, se < 61 else { return nil }
    if n > 20 {
        guard b[s + 19] == 0x2E, n > 21, digits(20, n - 21) != nil else { return nil }
    }
    // 公历日期 → 1970-01-01 起的天数（Howard Hinnant 的 days_from_civil）
    let yy = mo <= 2 ? y - 1 : y
    let era = (yy >= 0 ? yy : yy - 399) / 400
    let yoe = yy - era * 400
    let doy = (153 * (mo > 2 ? mo - 3 : mo + 9) + 2) / 5 + d - 1
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
    let days = era * 146097 + doe - 719468
    return days * 86400 + h * 3600 + mi * 60 + se
}

// MARK: - 自测

enum TokenStats {
    /// 在临时目录里构造 JSONL（重复消息、跨文件重复、未知型号、5m/1h 缓存、内容里藏着诱饵字段）验证解析、去重、计价、增量扫描。
    /// 返回每项结果，"✓" 开头为通过、"✗" 开头为失败
    static func selfTest() -> [String] {
        var out: [String] = []
        func check(_ ok: Bool, _ name: String) { out.append((ok ? "✓ " : "✗ ") + name) }
        func near(_ a: Double, _ b: Double) -> Bool { abs(a - b) < 1e-9 }

        // 计价与型号匹配
        let book = TokenPriceBook.builtIn
        check(book.lookup("claude-opus-5-5[1m]").tier == "tier_4_20_cache_read_0_20", L("型号带 [1m] 前缀匹配", "Model with [1m] matches by prefix"))
        check(book.lookup("claude-haiku-4-5-20251001").tier == "haiku_45", L("型号带日期后缀", "Model with a date suffix"))
        check(book.lookup("us.anthropic.claude-opus-4-1-20250805-v1:0").tier == "tier_15_75", L("Bedrock 型号名", "Bedrock model name"))
        check(book.lookup("claude-sonnet-4-6-20260101").tier == "tier_3_15", L("未收录的日期后缀落到同型号", "Unlisted date suffix maps to the same model"))
        check(!book.lookup("claude-opus-5-7").known && book.lookup("claude-opus-5-7").tier == "tier_5_25", L("新型号不误落到 claude-opus-5，按 tier_5_25 估", "New model is not mistaken for claude-opus-5, estimated at tier_5_25"))
        check(book.lookup("claude-opus-4-20250514").tier == "tier_15_75", L("老 Opus 4 的 first-party id", "Old Opus 4 first-party id"))

        // 时间解析与 parseISO 一致
        for t in ["2026-08-24T05:30:39.211Z", "2024-02-29T23:59:59Z", "1999-12-31T00:00:00.5Z", "2026-03-01T00:00:00.123456Z"] {
            let bytes = Array(t.utf8)
            let fast = bytes.withUnsafeBufferPointer { tsParseTimestamp($0.baseAddress!, 0, $0.count) }
            let slow = parseISO(t).map { Int($0.timeIntervalSince1970) }
            check(fast != nil && fast == slow, L("时间解析 \(t)", "Timestamp parsing \(t)"))
        }

        // 构造测试目录
        let fm = FileManager.default
        let tmp = tsRealPath(NSTemporaryDirectory()) + "/usagemaster-tokentest-" + UUID().uuidString
        defer { try? fm.removeItem(atPath: tmp) }
        let repo = tmp + "/proj/repo", sub = repo + "/sub", wt = tmp + "/proj/wt", plain = tmp + "/proj/plain"
        let root1 = tmp + "/logs1", root2 = tmp + "/logs2"
        for d in [repo + "/.git/worktrees/wt", sub, wt, plain, root1 + "/p", root2 + "/p"] {
            try? fm.createDirectory(atPath: d, withIntermediateDirectories: true)
        }
        try? "gitdir: \(repo)/.git/worktrees/wt\n".write(toFile: wt + "/.git", atomically: true, encoding: .utf8)
        // 软链：一个指向另一个根里已有的目录（不能重复计），一个指回自己（目录环，不能死循环）
        try? fm.createSymbolicLink(atPath: root1 + "/dup", withDestinationPath: root2 + "/p")
        try? fm.createSymbolicLink(atPath: root1 + "/p/loop", withDestinationPath: root1)
        let secret = "TOPSECRET-CONTENT-7f3a"
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let now = Date()
        let cal = Calendar.current
        let todayStart = cal.startOfDay(for: now)
        let tToday = todayStart.addingTimeInterval(floor(now.timeIntervalSince(todayStart) / 2))
        let tOld = (cal.date(byAdding: .day, value: -40, to: todayStart) ?? todayStart).addingTimeInterval(12 * 3600)
        func line(_ id: String, _ req: String?, model: String, at: Date, cwd: String, session: String,
                  input: Int, output: Int, cacheRead: Int = 0, cc: Int = 0, cc5: Int? = nil, cc1: Int? = nil) -> String {
            var usage: [String: Any] = ["input_tokens": input, "output_tokens": output, "cache_read_input_tokens": cacheRead,
                                        "cache_creation_input_tokens": cc, "service_tier": "standard"]
            if let a = cc5, let b = cc1 { usage["cache_creation"] = ["ephemeral_5m_input_tokens": a, "ephemeral_1h_input_tokens": b] }
            // 内容里放诱饵：同名的 model / usage 键、转义引号、结尾反斜杠、秘密字串——都不应被读出来
            let content: [Any] = [["type": "text", "text": "\(secret) \"usage\":{\"input_tokens\":999999} C:\\path\\"],
                                  ["type": "tool_use", "name": "Agent", "input": ["model": "claude-fake-1", "usage": ["output_tokens": 777777]]]]
            var msg: [String: Any] = ["id": id, "type": "message", "role": "assistant", "model": model, "content": content, "usage": usage]
            msg["stop_reason"] = NSNull()
            var obj: [String: Any] = ["type": "assistant", "timestamp": iso.string(from: at), "cwd": cwd, "sessionId": session,
                                      "uuid": UUID().uuidString, "message": msg]
            if let r = req { obj["requestId"] = r }
            let data = (try? JSONSerialization.data(withJSONObject: obj)) ?? Data()
            return String(decoding: data, as: UTF8.self) + "\n"
        }
        let userLine = String(decoding: (try? JSONSerialization.data(withJSONObject: [
            "type": "user", "timestamp": iso.string(from: tToday), "cwd": sub, "sessionId": "s1",
            "message": ["role": "user", "content": "\(secret) {\"type\":\"assistant\",\"usage\":{\"input_tokens\":5}}"],
        ])) ?? Data(), as: UTF8.self) + "\n"
        let synthetic = line("msg_syn", "req_syn", model: "<synthetic>", at: tToday, cwd: sub, session: "s1", input: 0, output: 0)
        let a1 = line("msg_A", "req_A", model: "claude-opus-5-5", at: tToday, cwd: sub, session: "s1",
                      input: 10, output: 3, cacheRead: 1000, cc: 500, cc5: 200, cc1: 300)
        let a2 = line("msg_A", "req_A", model: "claude-opus-5-5", at: tToday.addingTimeInterval(1), cwd: sub, session: "s1",
                      input: 10, output: 200, cacheRead: 1000, cc: 500, cc5: 200, cc1: 300)
        let bLine = line("msg_B", "req_B", model: "claude-haiku-4-5-20251001", at: tToday, cwd: sub, session: "s1", input: 100, output: 50, cc: 40)
        let cLine = line("msg_C", "req_C", model: "claude-zeta-9", at: tToday, cwd: wt, session: "s1", input: 1000, output: 1000)
        let dLine = line("msg_D", "req_D", model: "claude-sonnet-5[1m]", at: tOld, cwd: sub, session: "s0", input: 1000, output: 100)
        let eLine = line("msg_E", nil, model: "claude-opus-4-8", at: tToday, cwd: plain, session: "s2", input: 0, output: 0, cacheRead: 1_000_000)
        let f1 = root1 + "/p/s1.jsonl", f2 = root2 + "/p/s1-copy.jsonl"
        try? (userLine + a1 + a2 + bLine + synthetic + "{\"type\":\"assistant\",\"usage\":{broken\n" + cLine).write(toFile: f1, atomically: true, encoding: .utf8)
        try? (a2 + bLine + dLine + eLine).write(toFile: f2, atomically: true, encoding: .utf8)
        func append(_ path: String, _ s: String) {
            if let h = FileHandle(forWritingAtPath: path) { h.seekToEndOfFile(); h.write(Data(s.utf8)); h.closeFile() }
        }

        let cachePath = tmp + "/cache/token_cache.json", pricing = tmp + "/pricing.json"
        let cfg = TokenStatsConfig(roots: { [root1, root2, tmp + "/missing"] }, cachePath: cachePath, pricingPath: pricing, minSaveInterval: 0)
        var prog: [Double] = []
        let eng = TokenStatsEngine(config: cfg)
        var s = eng.refresh(now: now) { prog.append($0) }
        // A = 10×4 + 200×20 + 1000×0.2 + 200×5 + 300×8 = 7640；B = 100×1 + 50×5 + 40×1.25 = 400；C = 1000×5 + 1000×25 = 30000；
        // E = 1,000,000×0.5 = 500000；D（40 天前）= 1000×2 + 100×10 = 3000（单位：美元 / 百万）
        let costA = 7640e-6, costB = 400e-6, costC = 30000e-6, costD = 3000e-6, costE = 500000e-6
        check(s.totalRecords == 5, L("去重：5 条回复（同文件流式重复 + 跨文件重复各只算一次），实际 \(s.totalRecords)", "Dedup: 5 replies (streaming repeats in one file and copies across files each count once), got \(s.totalRecords)"))
        check(s.scannedFiles == 2 && s.filesRead == 2, L("扫描 2 个文件（软链目录去重、目录环不卡死、不存在的根目录跳过），实际 \(s.scannedFiles)", "Scans 2 files (symlinked dirs deduped, no hang on directory loops, missing roots skipped), got \(s.scannedFiles)"))
        check(near(s.today.costUSD, costA + costB + costC + costE), L("今天费用 \(s.today.costUSD)", "Today's cost \(s.today.costUSD)"))
        check(s.today.output == 200 + 50 + 1000, L("流式重复取最终 output_tokens，诱饵字段不计入", "Streaming repeats use the final output_tokens, decoy fields not counted"))
        check(s.today.cacheWrite == 540, L("缓存写入：5m/1h 拆分 + 无拆分全按 5m", "Cache writes: 5m/1h split, and all 5m when there is no split"))
        check(near(s.allTime.costUSD, costA + costB + costC + costD + costE), L("累计费用含 40 天前的记录", "All-time cost includes the record from 40 days ago"))
        check(near(s.last30Days.costUSD, s.today.costUSD) && near(s.last7Days.costUSD, s.today.costUSD), L("7 天 / 30 天不含 40 天前", "7-day / 30-day totals exclude 40 days ago"))
        check(s.byDay.count == 60 && s.byDay[19].totals.messages == 1 && s.byDay[59].totals.messages == 4, L("按天：60 天，40 天前那天 1 条、今天 4 条", "By day: 60 days, 1 reply 40 days ago, 4 today"))
        check(s.unknownModels == ["claude-zeta-9"], L("未知型号：\(s.unknownModels)", "Unknown models: \(s.unknownModels)"))
        check(s.byModel.first(where: { $0.model == "claude-zeta-9" })?.unknown == true, L("按型号标出未知", "By-model list flags unknown models"))
        let names = s.byProject.map { $0.name }
        check(names == ["plain", "repo"], L("项目归属：git 根 + worktree 归主仓库 + 无 git 用 cwd，按费用排序 \(names)", "Project mapping: git root, worktree goes to the main repo, cwd when there is no git, sorted by cost \(names)"))
        check(near(s.byProject.first(where: { $0.name == "repo" })?.last30Days.costUSD ?? 0, costA + costB + costC), L("项目费用", "Project cost"))
        check(s.topSessions.map { $0.sessionId } == ["s2", "s1"], L("费用最高的会话（30 天外的不算）", "Top sessions by cost (older than 30 days not counted)"))
        check(prog.last == 1 && zip(prog, prog.dropFirst()).allSatisfy { $0.0 <= $0.1 }, L("进度回调单调到 1", "Progress callback rises monotonically to 1"))
        let cacheData = fm.contents(atPath: cachePath) ?? Data()
        check(!cacheData.isEmpty && cacheData.range(of: Data(secret.utf8)) == nil && cacheData.range(of: Data("claude-fake-1".utf8)) == nil,
              L("缓存不含任何对话内容", "Cache has no conversation content"))
        let attrs = (try? fm.attributesOfItem(atPath: cachePath)) ?? [:]
        let perm = (attrs[.posixPermissions] as? NSNumber)?.intValue ?? 0
        check(perm == 0o600, L("缓存文件权限 600", "Cache file permissions 600"))

        // 增量
        s = eng.refresh(now: now)
        check(s.filesRead == 0 && s.newRecords == 0 && s.totalRecords == 5, L("没变化时不读文件", "No files read when nothing changed"))
        let fLine = line("msg_F", "req_F", model: "claude-opus-5", at: tToday, cwd: sub, session: "s1", input: 1, output: 1)
        append(f1, a2 + fLine + "{\"type\":\"assistant\",\"partial")     // 最后一行还没写完
        s = eng.refresh(now: now)
        check(s.filesRead == 1 && s.newRecords == 1 && s.totalRecords == 6, L("追加：只读改了的文件、只多 1 条，半行不处理", "Append: reads only the changed file, adds just 1 reply, skips the partial line"))
        check(near(s.today.costUSD, costA + costB + costC + costE + 30e-6), L("追加后费用", "Cost after append"))
        append(f1, "\":1}\n")      // 补完那半行（一条坏行）
        s = eng.refresh(now: now)
        check(s.filesRead == 1 && s.totalRecords == 6, L("补完的半行从行首重新解析", "Completed partial line is parsed again from its start"))
        try? a2.write(toFile: f1, atomically: true, encoding: .utf8)     // 截短
        s = eng.refresh(now: now)
        check(s.filesRead == 1 && s.newRecords == 0 && s.totalRecords == 6 && near(s.today.costUSD, costA + costB + costC + costE + 30e-6),
              L("截短后重扫不重复计、已删的记录保留", "Rescan after truncation does not double count, removed records are kept"))

        // 换一个引擎实例（模拟重启）：从缓存接着来
        let eng2 = TokenStatsEngine(config: cfg)
        s = eng2.refresh(now: now)
        check(s.filesRead == 0 && s.totalRecords == 6 && near(s.allTime.costUSD, costA + costB + costC + costD + costE + 30e-6), L("重启后读缓存、不重扫", "After restart, reads the cache without rescanning"))

        // 写盘节流：间隔内只改内存，flush 才落盘；落盘前重启也不会算错（偏移落后只是多读几行）
        var cfgSlow = cfg
        cfgSlow.minSaveInterval = 3600
        let slow = TokenStatsEngine(config: cfgSlow)
        _ = slow.refresh(now: now)
        let before = fm.contents(atPath: cachePath)
        append(f2, line("msg_G", "req_G", model: "claude-opus-5", at: tToday, cwd: plain, session: "s2", input: 2, output: 0))
        s = slow.refresh(now: now)
        let unchanged = fm.contents(atPath: cachePath) == before
        let stale = TokenStatsEngine(config: cfgSlow).refresh(now: now)
        slow.flush()
        let flushed = TokenStatsEngine(config: cfg).refresh(now: now)
        check(s.newRecords == 1 && unchanged && stale.totalRecords == 7 && stale.filesRead == 1 && flushed.filesRead == 0 && flushed.totalRecords == 7,
              L("写盘节流：间隔内不写，未落盘时重启照样补读、不重复；flush 后不再重读", "Save throttling: no write within the interval, a restart before saving still catches up without double counting, no reread after flush"))
        let costG = 2 * 5e-6

        // 价格覆盖
        try? #"{"pricing_tiers": {"tier_4_20_cache_read_0_20": {"output": 40}}, "models": [{"id": "claude-zeta-9", "pricing": "tier_2_10"}]}"#
            .write(toFile: pricing, atomically: true, encoding: .utf8)
        s = TokenStatsEngine(config: cfg).refresh(now: now)
        let costA2 = costA + 200 * 20e-6, costC2 = 1000 * 2e-6 + 1000 * 10e-6
        check(near(s.today.costUSD, costA2 + costB + costC2 + costE + 30e-6 + costG) && s.unknownModels.isEmpty, L("pricing.json 覆盖档位与型号", "pricing.json overrides tiers and models"))
        try? "not json".write(toFile: pricing, atomically: true, encoding: .utf8)
        s = TokenStatsEngine(config: cfg).refresh(now: now)
        check(s.priceNote != nil && near(s.today.costUSD, costA + costB + costC + costE + 30e-6 + costG), L("坏的 pricing.json 被忽略并给出说明", "Bad pricing.json is ignored with a note"))

        // 订阅与省下的钱
        let subsPath = tmp + "/subscriptions.json"
        let example = loadTokenSubscriptions(path: subsPath)
        check(fm.fileExists(atPath: subsPath) && example.count == 1 && example[0].monthlyUSD == 0, L("没有订阅文件时生成金额为 0 的示例", "Creates an example with amount 0 when there is no subscriptions file"))
        try? #"[{"name": "测试订阅", "monthlyUSD": 31}]"#.write(toFile: subsPath, atomically: true, encoding: .utf8)
        let subs = loadTokenSubscriptions(path: subsPath)
        let sv = tokenSavings(s, subscriptions: subs)
        let day = Double(cal.component(.day, from: s.lastScan)), dim = Double(cal.range(of: .day, in: .month, for: s.lastScan)?.count ?? 30)
        check(sv.hasSubscriptions && near(sv.subscriptionUSD, 31 * day / dim) && near(sv.savedUSD, s.thisMonth.costUSD - 31 * day / dim), L("订阅按天折算", "Subscription prorated by day"))

        // 报告
        let html = renderCostReportHTML(s, subscriptions: subs)
        check(html.contains("<svg") && html.contains("repo") && html.contains("plain"), L("报告含图表与项目", "Report has the chart and projects"))
        check(!html.contains("http://") && !html.contains("https://") && !html.contains("<link") && !html.contains(" src="), L("报告不引用任何外部资源", "Report references no external resources"))
        check(!html.contains(secret), L("报告不含对话内容", "Report has no conversation content"))
        let url = writeCostReport(s, subscriptions: subs, to: URL(fileURLWithPath: tmp + "/report/cost_report.html"))
        check(fm.contents(atPath: url.path).map { $0.count > 1000 } ?? false, L("报告写盘", "Report written to disk"))

        // 会话续接：同一条回复（同一时间戳）被抄进新会话的文件，归属与读文件的先后无关
        let rx = tmp + "/resume/x", ry = tmp + "/resume/y"
        for d in [rx, ry] { try? fm.createDirectory(atPath: d, withIntermediateDirectories: true) }
        let h = line("msg_H", "req_H", model: "claude-opus-5", at: tToday, cwd: plain, session: "bb-old", input: 1, output: 1)
        try? h.write(toFile: rx + "/old.jsonl", atomically: true, encoding: .utf8)
        try? h.replacingOccurrences(of: "bb-old", with: "zz-new").write(toFile: ry + "/new.jsonl", atomically: true, encoding: .utf8)
        let order1 = TokenStatsEngine(config: TokenStatsConfig(roots: { [rx, ry] }, cachePath: tmp + "/resume/c1.json", pricingPath: pricing))
            .refresh(now: now).topSessions.map { $0.sessionId }
        let order2 = TokenStatsEngine(config: TokenStatsConfig(roots: { [ry, rx] }, cachePath: tmp + "/resume/c2.json", pricingPath: pricing))
            .refresh(now: now).topSessions.map { $0.sessionId }
        check(order1 == ["bb-old"] && order2 == ["bb-old"], L("续接会话里的重复回复只算一次，归属与读文件顺序无关 \(order1) \(order2)", "Repeated reply in a resumed session counts once, attribution does not depend on file read order \(order1) \(order2)"))
        return out
    }
}
