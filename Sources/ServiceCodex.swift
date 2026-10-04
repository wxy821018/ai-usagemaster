// Codex（OpenAI Codex CLI，ChatGPT 登录）：5 小时窗口 / 每周用量 + 官方重置额度。协议参考自 Orca（MIT，Copyright (c) 2026 Lovecast Inc.）
//
// 凭据：<CODEX_HOME>/auth.json（CODEX_HOME 取环境变量，默认 ~/.codex）；另外 ~/.config/usagemaster/codex/<名字>/ 每个子目录
//   各算一个 CODEX_HOME（一个账号），在那个目录里用 `CODEX_HOME=<目录> codex login` 登录。auth.json 只读，绝不写回。
// 主路径：起 `codex -c approval_policy=never -c features.plugins=false -s read-only -a never app-server` 子进程
//   （env 带 CODEX_HOME，cwd 是空的临时目录，避开项目配置与 AGENTS.md），stdin/stdout 逐行 JSON-RPC：
//   initialize → initialized（通知）→ account/rateLimits/read。令牌由 codex 自己按需刷新（与平时用 codex 一样），
//   UsageMaster 不碰 refresh token；同一个目录同一时刻只起一个 app-server，避免两边同时刷新把 refresh token 作废。
// 回退：app-server 用不了（没装 / 出错但不是登录失效 / 会话索引正在重建）时，拿 auth.json 里的 access_token 直接
//   GET https://chatgpt.com/backend-api/wham/usage，不刷新令牌；重置额度信息不全时补查 GET .../wham/rate-limit-reset-credits。
// 不实现"消耗重置额度"（POST .../rate-limit-reset-credits/consume）——那是写操作。
// 令牌只在内存里，不打印、不写日志、不进错误信息；子进程的 stderr 只用来判断错误类型，摘录前先打码。

import Darwin
import Foundation
import SQLite3

struct CodexService: UsageService {
    let id = "codex"
    let displayName = "Codex"
    var setupHint: String {
        L("装 Codex CLI（npm i -g @openai/codex），在终端运行 codex login 用 ChatGPT 账号登录。",
          "Install the Codex CLI (npm i -g @openai/codex), then run codex login in Terminal and sign in with your ChatGPT account. ")
            + L("多账号：mkdir -p ~/.config/usagemaster/codex/<名字>，再运行 CODEX_HOME=~/.config/usagemaster/codex/<名字> codex login",
                "Multiple accounts: mkdir -p ~/.config/usagemaster/codex/<name>, then run CODEX_HOME=~/.config/usagemaster/codex/<name> codex login")
    }

    static let managedRoot = NSHomeDirectory() + "/.config/usagemaster/codex"
    static let appServerArgs = ["-c", "approval_policy=never", "-c", "features.plugins=false", "-s", "read-only", "-a", "never", "app-server"]

    func isConfigured() -> Bool {
        Self.homes().contains { FileManager.default.fileExists(atPath: $0.path + "/auth.json") }
    }

    func fetch() async -> ServiceStatus {
        var st = ServiceStatus(id: id, displayName: displayName, configured: isConfigured(), setupHint: setupHint)
        guard st.configured else { return st }
        let exe = Self.findCodex()
        // 逐个查（与 Orca 一样不并发起多个 app-server）
        for h in Self.homes() { st.accounts.append(await Self.fetchAccount(h, executable: exe)) }
        return st
    }

    // MARK: - 账号目录

    struct Home { let path: String; let name: String; let isDefault: Bool }

    static func defaultHome() -> String {
        if let e = ProcessInfo.processInfo.environment["CODEX_HOME"]?.trimmingCharacters(in: .whitespacesAndNewlines), !e.isEmpty {
            return (e as NSString).expandingTildeInPath
        }
        return NSHomeDirectory() + "/.codex"
    }

    static func resolved(_ p: String) -> String { URL(fileURLWithPath: p).resolvingSymlinksInPath().standardizedFileURL.path }

    /// 默认目录（有 auth.json 才算）+ ~/.config/usagemaster/codex/ 下每个子目录（没登录的也列出来，好提示去登录）；按真实路径去重
    static func homes() -> [Home] {
        let fm = FileManager.default
        var out: [Home] = []
        var seen = Set<String>()
        let def = defaultHome()
        if fm.fileExists(atPath: def + "/auth.json") {
            out.append(Home(path: def, name: L("默认", "Default"), isDefault: true))
            seen.insert(resolved(def))
        }
        for n in ((try? fm.contentsOfDirectory(atPath: managedRoot)) ?? []).sorted() where !n.hasPrefix(".") {
            let dir = managedRoot + "/" + n
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: dir, isDirectory: &isDir), isDir.boolValue, seen.insert(resolved(dir)).inserted else { continue }
            out.append(Home(path: dir, name: n, isDefault: false))
        }
        return out
    }

    // MARK: - auth.json（只读）

    struct Auth: CustomStringConvertible {
        var accessToken: String?
        var accountId: String?
        var email: String?
        var plan: String?
        var accessExpiry: Date?
        var apiKeyOnly = false
        var description: String { L("Codex 凭据（已隐藏）", "Codex credentials (hidden)") }     // 防止被误打印
    }

    enum AuthRead { case ok(Auth), missing, corrupt }

    static func readAuth(home: String) -> AuthRead {
        let p = home + "/auth.json"
        guard FileManager.default.fileExists(atPath: p) else { return .missing }
        guard let d = try? Data(contentsOf: URL(fileURLWithPath: p)), let a = parseAuth(d) else { return .corrupt }
        return .ok(a)
    }

    static func str(_ d: [String: Any]?, _ k: String) -> String? {
        guard let s = (d?[k] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return nil }
        return s
    }

    /// 解析 auth.json：tokens.access_token / account_id / id_token（JWT，只解 payload 不验签），顶层 OPENAI_API_KEY
    static func parseAuth(_ data: Data) -> Auth? {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        let tokens = root["tokens"] as? [String: Any]
        var a = Auth()
        a.accessToken = str(tokens, "access_token") ?? str(tokens, "accessToken")
        let claims = (str(tokens, "id_token") ?? str(tokens, "idToken")).flatMap(jwtPayload)
        let authNS = claims?["https://api.openai.com/auth"] as? [String: Any]
        let profile = claims?["https://api.openai.com/profile"] as? [String: Any]
        a.email = str(claims, "email") ?? str(profile, "email")
        a.accountId = str(tokens, "account_id") ?? str(tokens, "accountId") ?? str(authNS, "chatgpt_account_id")
        a.plan = planName(str(authNS, "chatgpt_plan_type"))
        a.accessExpiry = a.accessToken.flatMap(jwtPayload).flatMap { finite($0["exp"]) }.map { Date(timeIntervalSince1970: $0) }
        // 只有 API Key、没有 ChatGPT 令牌：没有订阅额度可查（两者都有时按 ChatGPT 登录处理）
        a.apiKeyOnly = a.accessToken == nil && str(root, "OPENAI_API_KEY") != nil
        return a
    }

    /// JWT 第二段 base64url 解码成 JSON；不验签，只用来读邮箱 / 套餐 / 过期时间
    static func jwtPayload(_ token: String) -> [String: Any]? {
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count >= 2 else { return nil }
        var s = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while s.count % 4 != 0 { s += "=" }
        guard let d = Data(base64Encoded: s) else { return nil }
        return (try? JSONSerialization.jsonObject(with: d)) as? [String: Any]
    }

    static func planName(_ raw: String?) -> String? {
        guard let r = raw?.lowercased(), !r.isEmpty else { return nil }
        let map = ["free": "Free", "go": "Go", "plus": "Plus", "pro": "Pro", "team": "Team",
                   "business": "Business", "enterprise": "Enterprise", "edu": "Edu"]
        return map[r] ?? r.capitalized
    }

    // MARK: - 用量数据与解析（纯函数，selfTest 覆盖）

    struct LimitWindow: Equatable { var usedPercent: Double; var windowMins: Double?; var resetsAt: Date? }
    struct ResetCredits: Equatable { var available: Int; var totalEarned: Int?; var nextExpiresAt: Date? }
    struct Usage {
        var session: LimitWindow?
        var weekly: LimitWindow?
        var credits: ResetCredits?
        var plan: String?
        /// 与 Orca 同一判据：可用 0 次，或已知最早过期时间，才算重置额度信息完整
        var creditsComplete: Bool { credits.map { $0.available == 0 || $0.nextExpiresAt != nil } ?? false }
    }

    /// 只认 JSON 数字（排除 true/false 与非有限值）
    static func finite(_ v: Any?) -> Double? {
        guard let n = v as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() else { return nil }
        let d = n.doubleValue
        return d.isFinite ? d : nil
    }

    static func epochSeconds(_ v: Any?) -> Date? {
        guard let s = finite(v), s > 0 else { return nil }
        return Date(timeIntervalSince1970: s)
    }

    /// 宽松时间：数字小于 1e10 当秒、否则当毫秒；字符串先按数字，再按 ISO 8601
    static func flexDate(_ v: Any?) -> Date? {
        var x = finite(v)
        if x == nil, let s = (v as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty {
            if let n = Double(s), n.isFinite { x = n } else { return parseISO(s) }
        }
        guard let n = x else { return nil }
        return Date(timeIntervalSince1970: n < 1e10 ? n : n / 1000)
    }

    static func count(_ d: Double) -> Int { Int(max(0, min(d, 1e6)).rounded(.down)) }

    /// app-server：{usedPercent, windowDurationMins, resetsAt(秒)}
    static func rpcWindow(_ v: Any?) -> LimitWindow? {
        guard let d = v as? [String: Any], let p = finite(d["usedPercent"]) else { return nil }
        return LimitWindow(usedPercent: p, windowMins: finite(d["windowDurationMins"]), resetsAt: epochSeconds(d["resetsAt"]))
    }

    /// 网页接口：{used_percent, limit_window_seconds, reset_at(秒)}
    static func httpWindow(_ v: Any?) -> LimitWindow? {
        guard let d = v as? [String: Any], let p = finite(d["used_percent"]) else { return nil }
        let mins = finite(d["limit_window_seconds"]).flatMap { $0 > 0 ? ($0 / 60).rounded(.up) : nil }
        return LimitWindow(usedPercent: p, windowMins: mins, resetsAt: epochSeconds(d["reset_at"]))
    }

    /// 时长 ≈300 分钟是 5 小时窗口，≈10080 是每周；其它时长不认识
    static func slot(_ w: LimitWindow) -> WindowKind? {
        guard let m = w.windowMins else { return nil }
        if abs(m - 300) <= 1 { return .session }
        if abs(m - 10080) <= 1 { return .weekly }
        return nil
    }

    /// 按时长归类；时长认不出时 primary 当 5 小时窗口、secondary 当每周（与 Orca 一致）
    static func classify(primary: LimitWindow?, secondary: LimitWindow?) -> (session: LimitWindow?, weekly: LimitWindow?) {
        var s: LimitWindow?, w: LimitWindow?
        for x in [primary, secondary].compactMap({ $0 }) {
            switch slot(x) {
            case .session? where s == nil: s = x
            case .weekly? where w == nil: w = x
            default: break
            }
        }
        if s == nil, let p = primary, slot(p) == nil { s = p }
        if w == nil, let q = secondary, slot(q) == nil { w = q }
        return (s, w)
    }

    static func earliestAvailable(_ list: [(status: String, expires: Date?)]?) -> Date? {
        list?.filter { $0.status == "available" }.compactMap { $0.expires }.min()
    }

    /// app-server（驼峰）：{availableCount, totalEarnedCount?, nextExpiresAt?, credits?:[{status, expiresAt, grantedAt}]}
    static func rpcCredits(_ v: Any?) -> ResetCredits? {
        guard let d = v as? [String: Any], let n = finite(d["availableCount"]) else { return nil }
        let list = (d["credits"] as? [[String: Any]])?.map { (status: (($0["status"] as? String) ?? "unknown").lowercased(), expires: flexDate($0["expiresAt"])) }
        return ResetCredits(available: count(n), totalEarned: finite(d["totalEarnedCount"]).map(count),
                            nextExpiresAt: flexDate(d["nextExpiresAt"]) ?? earliestAvailable(list))
    }

    /// 网页接口（下划线）：{available_count?, total_earned_count?, credits?:[{status, expires_at, granted_at}]}；缺 available_count 时数 available 条数
    static func httpCredits(_ v: Any?) -> ResetCredits? {
        guard let d = v as? [String: Any] else { return nil }
        let list = (d["credits"] as? [[String: Any]])?.map { (status: (($0["status"] as? String) ?? "unknown").lowercased(), expires: flexDate($0["expires_at"])) }
        guard let n = finite(d["available_count"]) ?? list.map({ Double($0.filter { $0.status == "available" }.count) }) else { return nil }
        return ResetCredits(available: count(n), totalEarned: finite(d["total_earned_count"]).map(count), nextExpiresAt: earliestAvailable(list))
    }

    /// account/rateLimits/read 的 result
    static func parseRPCResult(_ r: [String: Any]) -> Usage {
        let rl = r["rateLimits"] as? [String: Any]
        let c = classify(primary: rpcWindow(rl?["primary"]), secondary: rpcWindow(rl?["secondary"]))
        return Usage(session: c.session, weekly: c.weekly, credits: rpcCredits(r["rateLimitResetCredits"]))
    }

    /// GET wham/usage 的返回；没有 plan_type（字符串）视为无效
    static func parseHTTPUsage(_ d: [String: Any]) -> Usage? {
        guard let plan = d["plan_type"] as? String else { return nil }
        let rl = d["rate_limit"] as? [String: Any]
        let c = classify(primary: httpWindow(rl?["primary_window"]), secondary: httpWindow(rl?["secondary_window"]))
        return Usage(session: c.session, weekly: c.weekly, credits: httpCredits(d["rate_limit_reset_credits"]), plan: planName(plan))
    }

    static func windowLabel(_ mins: Double?, _ kind: WindowKind) -> String {
        if let m = mins, m > 0 {
            if abs(m - 300) <= 1 { return L("5 小时窗口", "5-hour window") }
            if abs(m - 10080) <= 1 { return L("每周", "Weekly") }
            if m >= 1440, (m / 1440).rounded() == m / 1440 { return L("\(Int(m / 1440)) 天窗口", "\(Int(m / 1440))-day window") }
            if m >= 60, (m / 60).rounded() == m / 60 { return L("\(Int(m / 60)) 小时窗口", "\(Int(m / 60))-hour window") }
            return L("\(Int(m.rounded())) 分钟窗口", "\(Int(m.rounded()))-minute window")
        }
        return kind == .session ? L("5 小时窗口", "5-hour window") : L("每周", "Weekly")
    }

    /// 映射成通用窗口：百分比夹到 0–100，重置时间取整到分钟，重置时间已过视为 0（与 Claude 的 makeWindow 同口径）
    static func serviceWindows(_ u: Usage, now: Date = Date()) -> [ServiceWindow] {
        var out: [ServiceWindow] = []
        for (w, kind) in [(u.session, WindowKind.session), (u.weekly, WindowKind.weekly)] {
            guard let w = w else { continue }
            let reset = roundedMinute(w.resetsAt)
            var pct = min(100, max(0, w.usedPercent))
            var detail: String?
            if let r = reset, r < now { pct = 0; detail = L("已重置", "Already reset") }
            out.append(ServiceWindow(label: windowLabel(w.windowMins, kind), percent: pct, resetsAt: reset, kind: kind, detail: detail))
        }
        return out
    }

    static let dayFmt: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "M/d"
        return f
    }()

    /// 官方给的重置额度；从没拿到过（0 次且累计 0）就不显示
    static func creditsNote(_ c: ResetCredits?) -> String? {
        guard let c = c else { return nil }
        if c.available == 0 {
            guard let t = c.totalEarned, t > 0 else { return nil }
            return L("可用重置额度 0 次（累计获得 \(t) 次）", "Reset credits: 0 available (\(t) earned in total)")
        }
        var s = L("可用重置额度 \(c.available) 次", "Reset credits: \(c.available) available")
        if let d = c.nextExpiresAt { s += L("，最早 \(dayFmt.string(from: d)) 过期", ", earliest expires \(dayFmt.string(from: d))") }
        return s
    }

    // MARK: - 错误文字

    /// 登录失效的特征（codex 的报错原文，与 Orca 同一组）
    static let authPatterns = [
        "access token could not be refreshed", "authentication session could not be refreshed",
        "refresh token (has expired|was already used|was revoked)", "you have since logged out or signed in to another account",
        "please (log out and )?sign in again", "please reauthenticate", "not logged in", "sign in with chatgpt",
        "token data is not available", "auth (is missing|tokens are missing|does not expose)", "chatgpt authentication required",
    ]

    static func isAuthFailure(_ text: String) -> Bool {
        authPatterns.contains { text.range(of: "(?i)" + $0, options: .regularExpression) != nil }
    }

    /// codex 版本太旧、不认 app-server 子命令
    static func isAppServerUnsupported(_ text: String) -> Bool {
        text.split(whereSeparator: \.isNewline).contains {
            $0.contains("app-server") && $0.range(of: "(?i)unrecognized subcommand|unexpected argument|invalid subcommand", options: .regularExpression) != nil
        }
    }

    /// 摘录外部文字前打码：去掉终端颜色码，24 位以上的长串（令牌、JWT）一律换成 …，只留最后一行非空内容的前 100 字
    static func redact(_ text: String) -> String {
        let plain = text.replacingOccurrences(of: "\u{1B}\\[[0-9;]*[a-zA-Z]", with: "", options: .regularExpression)
        let last = plain.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.last { !$0.isEmpty } ?? ""
        let masked = last.replacingOccurrences(of: "[A-Za-z0-9._~+/=-]{24,}", with: "…", options: .regularExpression)
        return masked.count > 100 ? String(masked.prefix(100)) + "…" : masked
    }

    // MARK: - 找 codex 可执行文件

    static func isExecutable(_ p: String) -> Bool {
        var d: ObjCBool = false
        return FileManager.default.fileExists(atPath: p, isDirectory: &d) && !d.boolValue && FileManager.default.isExecutableFile(atPath: p)
    }

    /// 查找顺序：PATH → nvm（默认别名优先）→ volta / asdf / fnm / mise / ~/.local/bin / pnpm / yarn / bun → Homebrew / /usr/local / nix
    static func findCodex(pathEnv: String? = ProcessInfo.processInfo.environment["PATH"], homeDir: String = NSHomeDirectory()) -> String? {
        var dirs = (pathEnv ?? "").split(separator: ":").map(String.init).filter { !$0.isEmpty }
        dirs += nvmBinDirs(homeDir)
        dirs += [".volta/bin", ".asdf/shims", ".fnm/aliases/default/bin", ".local/share/mise/shims", ".local/bin",
                 "Library/pnpm", ".yarn/bin", ".bun/bin"].map { homeDir + "/" + $0 }
        dirs += ["/opt/homebrew/bin", "/usr/local/bin", "/nix/var/nix/profiles/default/bin", homeDir + "/.nix-profile/bin"]
        return dirs.lazy.map { $0 + "/codex" }.first(where: isExecutable)
    }

    static func versionParts(_ v: String) -> [Int] {
        (v.hasPrefix("v") || v.hasPrefix("V") ? String(v.dropFirst()) : v).split(separator: ".").map { Int($0) ?? 0 }
    }

    /// a 的版本号是否高于 b
    static func versionGreater(_ a: String, _ b: String) -> Bool {
        let x = versionParts(a), y = versionParts(b)
        for i in 0..<max(x.count, y.count) {
            let p = i < x.count ? x[i] : 0, q = i < y.count ? y[i] : 0
            if p != q { return p > q }
        }
        return a > b
    }

    /// ~/.nvm/versions/node/*/bin，版本从高到低；~/.nvm/alias/default 指向的版本排最前
    static func nvmBinDirs(_ homeDir: String) -> [String] {
        let root = homeDir + "/.nvm/versions/node"
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: root) else { return [] }
        var versions = names.filter { !$0.hasPrefix(".") }.sorted(by: versionGreater)
        if let def = nvmDefaultVersion(homeDir, installed: versions), let i = versions.firstIndex(of: def) {
            versions.remove(at: i)
            versions.insert(def, at: 0)
        }
        return versions.map { root + "/" + $0 + "/bin" }
    }

    static func nvmDefaultVersion(_ homeDir: String, installed: [String]) -> String? {
        let aliasDir = homeDir + "/.nvm/alias"
        func read(_ name: String) -> String? {
            guard !name.contains("..") else { return nil }
            let v = (try? String(contentsOfFile: aliasDir + "/" + name, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
            return v?.isEmpty == false ? v : nil
        }
        var cur = read("default")
        var seen = Set<String>()
        for _ in 0..<10 {
            guard let c = cur else { break }
            if seen.contains(c) { return nil }        // 别名成环
            seen.insert(c)
            guard let next = read(c) else { break }
            cur = next
        }
        guard let want = cur, !["system", "node", "stable"].contains(want),
              want.range(of: #"^[vV]?(0|[1-9]\d*)(\.(0|[1-9]\d*))*$"#, options: .regularExpression) != nil else { return nil }
        let prefix = versionParts(want)
        return installed.filter { v in
            let p = versionParts(v)
            return p.count >= prefix.count && Array(p.prefix(prefix.count)) == prefix
        }.sorted(by: versionGreater).first
    }

    /// 子进程环境：CODEX_HOME 指向账号目录；npm 装的 codex 是 node 脚本，node 若在同目录就把该目录放到 PATH 最前，
    /// 再补上常见目录（从 Finder / 开机自启运行时 PATH 只有 /usr/bin:/bin 这几个）
    static func childEnvironment(executable: String, home: String) -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["CODEX_HOME"] = home
        let dir = (executable as NSString).deletingLastPathComponent
        var parts: [String] = []
        if isExecutable(dir + "/node") { parts.append(dir) }
        parts += (env["PATH"] ?? "").split(separator: ":").map(String.init)
        parts += ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"]
        var seen = Set<String>()
        env["PATH"] = parts.filter { !$0.isEmpty && seen.insert($0).inserted }.joined(separator: ":")
        return env
    }

    // MARK: - 会话索引回填检测（回填没完成时起 app-server 会触发很长的重建，Orca 遇到就跳过）

    enum Backfill { case complete, incomplete, notTracked, unreadable }

    static func backfillStatus(_ path: String) -> Backfill {
        var db: OpaquePointer?
        let uri = "file:" + (path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path) + "?mode=ro"
        guard sqlite3_open_v2(uri, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK else {
            sqlite3_close(db)
            return .unreadable
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 500)
        func query(_ sql: String) -> (ok: Bool, text: String?) {
            var st: OpaquePointer?
            defer { sqlite3_finalize(st) }
            guard sqlite3_prepare_v2(db, sql, -1, &st, nil) == SQLITE_OK else { return (false, nil) }
            switch sqlite3_step(st) {
            case SQLITE_ROW:
                guard sqlite3_column_type(st, 0) == SQLITE_TEXT, let c = sqlite3_column_text(st, 0) else { return (true, nil) }
                return (true, String(cString: c))
            case SQLITE_DONE: return (true, nil)
            default: return (false, nil)
            }
        }
        let table = query("SELECT name FROM sqlite_master WHERE type = 'table' AND name = 'backfill_state'")
        guard table.ok else { return .unreadable }
        guard table.text != nil else { return .notTracked }
        let row = query("SELECT status FROM backfill_state WHERE id = 1")
        guard row.ok else { return .unreadable }
        guard let status = row.text else { return .notTracked }
        return status == "complete" ? .complete : .incomplete
    }

    static func countSessionFiles(_ dir: String, limit: Int) -> Int {
        guard let e = FileManager.default.enumerator(atPath: dir) else { return 0 }
        var n = 0
        while let rel = e.nextObject() as? String {
            if rel.hasSuffix(".jsonl") || rel.hasSuffix(".jsonl.zst") {
                n += 1
                if n >= limit { break }
            }
        }
        return n
    }

    /// 最新的 state_N.sqlite 里 backfill_state 不是 complete → 正在重建；没有跟踪记录时，sessions 下会话文件 ≥100 个也按正在重建算
    static func sessionIndexBusy(home: String) -> Bool {
        var best: (version: Int, name: String)?
        for n in (try? FileManager.default.contentsOfDirectory(atPath: home)) ?? [] {
            guard n.hasPrefix("state_"), n.hasSuffix(".sqlite") else { continue }
            let digits = n.dropFirst(6).dropLast(7)
            guard !digits.isEmpty, digits.allSatisfy({ $0 >= "0" && $0 <= "9" }), let v = Int(digits) else { continue }
            if best == nil || v > best!.version { best = (v, n) }
        }
        if let b = best {
            switch backfillStatus(home + "/" + b.name) {
            case .complete, .unreadable: return false
            case .incomplete: return true
            case .notTracked: break
            }
        }
        return countSessionFiles(home + "/sessions", limit: 100) >= 100
    }

    // MARK: - app-server 子进程（JSONL JSON-RPC）

    enum RPCOutcome {
        case ok(Usage)
        case authFailed
        case failed(String)       // 简短中文，已打码
    }

    /// 一次 app-server 会话的收发状态；stdout 回调线程与调用线程共用，全部经 lock
    final class RPCSession: @unchecked Sendable {
        private let lock = NSLock()
        private let stdin: FileHandle
        private var stdinOpen = true
        private var buf = Data()
        private var errBuf = Data()
        private let initId = 1, readId = 2
        private var stage = 0          // 0 等 initialize 回应；1 等 rateLimits 回应；2 已有结论
        private var result: [String: Any]?
        private var rpcError: String?
        let initSem = DispatchSemaphore(value: 0)
        let doneSem = DispatchSemaphore(value: 0)
        let errClosed = DispatchSemaphore(value: 0)

        init(stdin: FileHandle) { self.stdin = stdin }

        /// 写一行 JSON 到子进程 stdin（POSIX write + F_SETNOSIGPIPE，对方先退出也不会因 SIGPIPE 把本进程带崩）；调用方须持锁
        private func writeLocked(_ obj: [String: Any]) -> Bool {
            guard stdinOpen, var d = try? JSONSerialization.data(withJSONObject: obj, options: [.withoutEscapingSlashes]) else { return false }
            d.append(0x0A)
            let fd = stdin.fileDescriptor
            return d.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Bool in
                guard let base = raw.baseAddress else { return false }
                var off = 0
                while off < raw.count {
                    let n = Darwin.write(fd, base + off, raw.count - off)
                    if n < 0 {
                        if errno == EINTR { continue }
                        return false
                    }
                    off += n
                }
                return true
            }
        }

        func start() {
            lock.lock(); defer { lock.unlock() }
            _ = writeLocked(["jsonrpc": "2.0", "id": initId, "method": "initialize",
                             "params": ["clientInfo": ["name": "usagemaster", "version": "1.0.0"]]])
        }

        static func intId(_ v: Any?) -> Int? {
            if let n = v as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() { return n.intValue }
            if let s = v as? String { return Int(s) }
            return nil
        }

        static func errorMessage(_ e: Any?) -> String {
            ((e as? [String: Any])?["message"] as? String) ?? L("未知错误", "unknown error")
        }

        func feed(_ d: Data) {
            var wake: [DispatchSemaphore] = []
            lock.lock()
            buf.append(d)
            while let nl = buf.firstIndex(of: 0x0A) {
                let line = buf.subdata(in: buf.startIndex..<nl)
                buf.removeSubrange(buf.startIndex...nl)
                handleLocked(line, &wake)
            }
            if buf.count > 4_000_000 { buf.removeAll() }      // 一行没完没了：丢掉，防内存涨
            lock.unlock()
            wake.forEach { $0.signal() }
        }

        private func handleLocked(_ line: Data, _ wake: inout [DispatchSemaphore]) {
            guard stage < 2, let obj = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else { return }
            // 服务端通知（id 为 null）与服务端发来的请求（带 method）一律忽略，只认回应
            guard obj["method"] == nil, let id = Self.intId(obj["id"]) else { return }
            if stage == 0 && id == initId {
                if obj["error"] != nil && !(obj["error"] is NSNull) {
                    rpcError = Self.errorMessage(obj["error"])
                    stage = 2
                    wake += [initSem, doneSem]
                    return
                }
                stage = 1
                _ = writeLocked(["jsonrpc": "2.0", "method": "initialized", "params": [String: Any]()])
                _ = writeLocked(["jsonrpc": "2.0", "id": readId, "method": "account/rateLimits/read", "params": [String: Any]()])
                wake.append(initSem)
            } else if stage == 1 && id == readId {
                if obj["error"] != nil && !(obj["error"] is NSNull) {
                    rpcError = Self.errorMessage(obj["error"])
                } else {
                    result = (obj["result"] as? [String: Any]) ?? [:]
                }
                stage = 2
                wake.append(doneSem)
            }
        }

        /// stdout 关了（进程退出）：叫醒等待方
        func finishOutput() {
            initSem.signal()
            doneSem.signal()
        }

        func feedStderr(_ d: Data) {
            lock.lock(); defer { lock.unlock() }
            errBuf.append(d)
            if errBuf.count > 100_000 { errBuf = errBuf.suffix(100_000) }     // 只留最后 100KB
        }

        func closeStdin() {
            lock.lock(); defer { lock.unlock() }
            guard stdinOpen else { return }
            stdinOpen = false
            try? stdin.close()
        }

        func snapshot() -> (result: [String: Any]?, rpcError: String?, initDone: Bool, stderr: String) {
            lock.lock(); defer { lock.unlock() }
            return (result, rpcError, stage >= 1 && rpcError == nil || result != nil, String(decoding: errBuf, as: UTF8.self))
        }
    }

    /// 起一次 app-server 查用量。阻塞调用（在后台线程跑），超时：initialize 30 秒、查询 10 秒；
    /// 结束时先关 stdin，再 SIGTERM，宽限 killGrace 秒后 SIGKILL。
    static func runAppServer(executable: String, arguments: [String] = appServerArgs, home: String,
                             initTimeout: TimeInterval = 30, rpcTimeout: TimeInterval = 10, killGrace: TimeInterval = 5) -> RPCOutcome {
        let fm = FileManager.default
        let cwd = NSTemporaryDirectory() + "usagemaster-codex-" + UUID().uuidString
        do {
            try fm.createDirectory(atPath: cwd, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        } catch { return .failed(L("建不了临时目录", "Could not create a temporary folder")) }
        defer { try? fm.removeItem(atPath: cwd) }

        let p = Process()
        p.executableURL = URL(fileURLWithPath: executable)
        p.arguments = arguments
        p.currentDirectoryURL = URL(fileURLWithPath: cwd)
        p.environment = childEnvironment(executable: executable, home: home)
        let inPipe = Pipe(), outPipe = Pipe(), errPipe = Pipe()
        p.standardInput = inPipe
        p.standardOutput = outPipe
        p.standardError = errPipe
        _ = fcntl(inPipe.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        let s = RPCSession(stdin: inPipe.fileHandleForWriting)
        let exited = DispatchSemaphore(value: 0)
        p.terminationHandler = { _ in exited.signal() }
        outPipe.fileHandleForReading.readabilityHandler = { h in
            let d = h.availableData
            if d.isEmpty { h.readabilityHandler = nil; s.finishOutput() } else { s.feed(d) }
        }
        errPipe.fileHandleForReading.readabilityHandler = { h in
            let d = h.availableData
            if d.isEmpty { h.readabilityHandler = nil; s.errClosed.signal() } else { s.feedStderr(d) }
        }
        func closeReaders() {
            outPipe.fileHandleForReading.readabilityHandler = nil
            errPipe.fileHandleForReading.readabilityHandler = nil
            try? outPipe.fileHandleForReading.close()
            try? errPipe.fileHandleForReading.close()
        }
        do { try p.run() } catch {
            s.closeStdin()
            closeReaders()
            return .failed(L("codex 启动失败", "Could not start codex"))
        }

        s.start()
        var timeout: String?
        if s.initSem.wait(timeout: .now() + initTimeout) == .timedOut {
            timeout = L("codex app-server 启动超时（\(Int(initTimeout)) 秒）", "codex app-server startup timed out (\(Int(initTimeout)) s)")
        } else if s.snapshot().initDone, s.doneSem.wait(timeout: .now() + rpcTimeout) == .timedOut {
            timeout = L("查询超时（\(Int(rpcTimeout)) 秒）", "Query timed out (\(Int(rpcTimeout)) s)")
        }

        // 收尾：先关 stdin（app-server 读到 EOF 会自己退出），再 SIGTERM，宽限后 SIGKILL
        s.closeStdin()
        if p.isRunning { p.terminate() }
        if exited.wait(timeout: .now() + killGrace) == .timedOut, p.isRunning {
            kill(p.processIdentifier, SIGKILL)
            _ = exited.wait(timeout: .now() + 2)
        }
        _ = s.errClosed.wait(timeout: .now() + 1)       // 等 stderr 读完，好判断错误类型
        let snap = s.snapshot()
        let status: String = {
            guard !p.isRunning else { return L("未退出", "still running") }
            return p.terminationReason == .uncaughtSignal ? L("信号 \(p.terminationStatus)", "signal \(p.terminationStatus)") : L("退出码 \(p.terminationStatus)", "exit code \(p.terminationStatus)")
        }()
        let exitCode127 = !p.isRunning && p.terminationReason == .exit && p.terminationStatus == 127
        closeReaders()

        if let r = snap.result { return .ok(parseRPCResult(r)) }
        let msg = snap.rpcError ?? ""
        if isAuthFailure(msg) || isAuthFailure(snap.stderr) { return .authFailed }
        if let t = timeout { return .failed(t) }
        if !msg.isEmpty { return .failed(L("codex 返回错误：", "codex returned an error: ") + redact(msg)) }
        if snap.stderr.contains("env: node") || exitCode127 { return .failed(L("找到了 codex 但运行不了（PATH 里没有 node）", "Found codex but could not run it (node is not in PATH)")) }
        if isAppServerUnsupported(snap.stderr) { return .failed(L("codex 版本太旧，不支持 app-server，请升级", "This codex version is too old for app-server, please upgrade")) }
        let tail = redact(snap.stderr)
        return .failed(L("codex app-server 提前退出（\(status)）", "codex app-server exited early (\(status))") + (tail.isEmpty ? "" : L("：", ": ") + tail))
    }

    /// 同一个 CODEX_HOME 同一时刻只起一个 app-server（它可能刷新令牌，并发刷新会让 refresh token 作废）
    final class HomeLocks: @unchecked Sendable {
        static let shared = HomeLocks()
        private let guardLock = NSLock()
        private var locks: [String: NSLock] = [:]
        func lock(for home: String) -> NSLock {
            guardLock.lock(); defer { guardLock.unlock() }
            if let l = locks[home] { return l }
            let l = NSLock()
            locks[home] = l
            return l
        }
    }

    static func appServer(home: String, executable: String) async -> RPCOutcome {
        await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .utility).async {
                let l = HomeLocks.shared.lock(for: resolved(home))
                l.lock()
                let r = runAppServer(executable: executable, home: home)
                l.unlock()
                cont.resume(returning: r)
            }
        }
    }

    // MARK: - 网页接口回退（只读 GET，不刷新令牌）

    enum HTTPResult { case ok(Usage), err(String) }

    static func whamRequest(_ path: String, auth: Auth) -> URLRequest? {
        guard let tok = auth.accessToken, let url = URL(string: "https://chatgpt.com/backend-api/wham/" + path) else { return nil }
        var req = URLRequest(url: url, timeoutInterval: 10)
        req.setValue("Bearer \(tok)", forHTTPHeaderField: "Authorization")
        req.setValue("codex-cli", forHTTPHeaderField: "User-Agent")
        req.setValue("codex-1", forHTTPHeaderField: "OpenAI-Beta")
        req.setValue("Codex Desktop", forHTTPHeaderField: "originator")
        if let a = auth.accountId { req.setValue(a, forHTTPHeaderField: "ChatGPT-Account-Id") }
        return req
    }

    static func httpError(_ code: Int) -> String {
        switch code {
        case 401: return L("令牌失效（401）：用一下 codex 就会刷新", "Token rejected (401): running codex once refreshes it")
        case 403: return L("被拒绝（403）", "Access denied (403)")
        case 429: return L("请求太频繁（429），稍后再试", "Too many requests (429), try again later")
        default: return "HTTP \(code)"
        }
    }

    static func tokenExpired(_ auth: Auth, now: Date = Date()) -> Bool {
        auth.accessExpiry.map { $0 < now } ?? false
    }

    static func httpUsage(_ auth: Auth) async -> HTTPResult {
        if tokenExpired(auth) { return .err(L("登录令牌已过期：用一下 codex 就会自动刷新", "Sign-in token expired: running codex once refreshes it automatically")) }
        guard let req = whamRequest("usage", auth: auth) else { return .err(L("auth.json 里没有 access_token", "No access_token in auth.json")) }
        do {
            let (body, resp) = try await session.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            guard (200..<300).contains(code) else { return .err(httpError(code)) }
            guard let d = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any], let u = parseHTTPUsage(d) else {
                return .err(L("返回格式变了", "The response format has changed"))
            }
            return .ok(u)
        } catch {
            return .err(describe(error))
        }
    }

    static func httpResetCredits(_ auth: Auth) async -> ResetCredits? {
        guard !tokenExpired(auth), let req = whamRequest("rate-limit-reset-credits", auth: auth),
              let (body, resp) = try? await session.data(for: req),
              let code = (resp as? HTTPURLResponse)?.statusCode, (200..<300).contains(code),
              let d = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] else { return nil }
        return httpCredits(d)
    }

    static func shorten(_ s: String, _ n: Int = 60) -> String { s.count > n ? String(s.prefix(n)) + "…" : s }

    // MARK: - 单个账号

    static func fetchAccount(_ home: Home, executable: String?) async -> ServiceAccount {
        var acc = ServiceAccount(id: home.path, title: home.isDefault ? L("默认账号", "Default account") : home.name)
        let auth: Auth
        switch readAuth(home: home.path) {
        case .missing:
            acc.error = L("还没登录：让 CODEX_HOME 指向这个目录后运行 codex login", "Not signed in: point CODEX_HOME at this folder, then run codex login")
            return acc
        case .corrupt:
            acc.error = L("auth.json 读不了或不是有效的 JSON", "auth.json cannot be read or is not valid JSON")
            return acc
        case .ok(let a):
            auth = a
        }
        if let e = auth.email { acc.title = e }
        acc.plan = auth.plan
        if auth.apiKeyOnly {
            acc.error = L("这是 API Key 登录，没有 ChatGPT 订阅用量可查", "Signed in with an API key: there is no ChatGPT subscription usage to check")
            return acc
        }

        var usage: Usage?
        var rpcProblem: String?
        if sessionIndexBusy(home: home.path) {
            rpcProblem = L("codex 会话索引在重建，没起 app-server", "codex session index is rebuilding, app-server not started")
        } else if let exe = executable {
            switch await appServer(home: home.path, executable: exe) {
            case .ok(let u): usage = u
            case .authFailed:
                acc.error = L("ChatGPT 登录已失效：运行 codex login 重新登录", "ChatGPT sign-in expired: run codex login to sign in again")
                return acc
            case .failed(let m): rpcProblem = m
            }
        } else {
            rpcProblem = L("没找到 codex 命令", "codex command not found")
        }

        // app-server 可能刚刷新过令牌：重读一次 auth.json 再走网页接口
        var fresh = auth
        if case .ok(let a) = readAuth(home: home.path) { fresh = a }

        if usage == nil || (usage?.session == nil && usage?.weekly == nil) {
            switch await httpUsage(fresh) {
            case .ok(let h):
                usage = h
                let why = shorten(rpcProblem ?? L("app-server 没给出用量", "app-server returned no usage"))
                acc.notes.append(L("数据来自网页接口（\(why)）", "Data from the web API (\(why))"))
            case .err(let m):
                acc.error = usage == nil ? (rpcProblem.map { shorten($0) + L("；", "; ") } ?? "") + L("网页接口：", "Web API: ") + m
                                         : L("返回里没有用量窗口（格式可能变了）", "No usage windows in the response (the format may have changed)")
                return acc
            }
        } else if var u = usage, u.session == nil, u.weekly != nil, case .ok(let h) = await httpUsage(fresh) {
            // app-server 只给了每周、没给 5 小时窗口：用网页接口补齐
            if h.session != nil {
                u.session = h.session
                u.weekly = h.weekly ?? u.weekly
                u.plan = h.plan ?? u.plan
            }
            if let c = h.credits { u.credits = c }
            usage = u
        }
        guard var u = usage else { return acc }
        if !u.creditsComplete, let c = await httpResetCredits(fresh) { u.credits = c }

        acc.windows = serviceWindows(u)
        if let p = u.plan { acc.plan = p }
        if let n = creditsNote(u.credits) { acc.notes.insert(n, at: 0) }
        acc.updatedAt = Date()
        if acc.windows.isEmpty { acc.error = L("返回里没有用量窗口（格式可能变了）", "No usage windows in the response (the format may have changed)") }
        return acc
    }

    // MARK: - 自检（不发网络请求）

    /// 返回失败描述，空数组 = 全过。解析 / 窗口映射用规格里的样例 JSON；另用假 app-server 脚本测子进程收发与收尾。
    static func selfTest() -> [String] {
        var fails: [String] = []
        func check(_ ok: Bool, _ what: String) { if !ok { fails.append(what) } }
        func json(_ s: String) -> [String: Any] { ((try? JSONSerialization.jsonObject(with: Data(s.utf8))) as? [String: Any]) ?? [:] }
        func near(_ a: Date?, _ b: Date?) -> Bool {
            guard let a = a, let b = b else { return a == nil && b == nil }
            return abs(a.timeIntervalSince(b)) < 1
        }
        let now = Date()
        let t = Int(now.timeIntervalSince1970)

        // 1. app-server 结果：primary=5 小时、secondary=每周；重置额度取 status=available（大小写不敏感）里最早过期的
        do {
            let r = json("""
            {"rateLimits":{"primary":{"usedPercent":42.5,"windowDurationMins":300,"resetsAt":\(t + 3600)},
                           "secondary":{"usedPercent":17,"windowDurationMins":10080,"resetsAt":\(t + 3 * 86400)}},
             "rateLimitResetCredits":{"availableCount":2.7,"totalEarnedCount":3,
               "credits":[{"status":"AVAILABLE","expiresAt":\(t + 9 * 86400)},{"status":"available","expiresAt":\(t + 5 * 86400)},
                          {"status":"used","expiresAt":\(t + 86400)}]}}
            """)
            let u = parseRPCResult(r)
            check(u.session?.usedPercent == 42.5 && u.weekly?.usedPercent == 17, L("RPC：primary/secondary 百分比解析错", "RPC: primary/secondary percent parsed wrong"))
            check(u.credits?.available == 2 && u.credits?.totalEarned == 3, L("RPC：availableCount 应向下取整为 2", "RPC: availableCount should round down to 2"))
            check(near(u.credits?.nextExpiresAt, Date(timeIntervalSince1970: TimeInterval(t + 5 * 86400))), L("RPC：最早过期应取 available 里最早的", "RPC: earliest expiry should be the earliest available credit"))
            check(u.creditsComplete, L("RPC：有最早过期时间应算完整", "RPC: credits with an earliest expiry should count as complete"))
            let w = serviceWindows(u, now: now)
            check(w.count == 2 && w[0].kind == .session && w[0].label == L("5 小时窗口", "5-hour window") && w[0].percent == 42.5, L("映射：5 小时窗口错", "Mapping: 5-hour window wrong"))
            check(w.count == 2 && w[1].kind == .weekly && w[1].label == L("每周", "Weekly") && w[1].percent == 17, L("映射：每周窗口错", "Mapping: weekly window wrong"))
            check(near(w.first?.resetsAt, roundedMinute(Date(timeIntervalSince1970: TimeInterval(t + 3600)))), L("映射：resetsAt 应是秒、取整到分钟", "Mapping: resetsAt should be seconds, rounded to the minute"))
            let note = creditsNote(u.credits) ?? ""
            let day = dayFmt.string(from: Date(timeIntervalSince1970: TimeInterval(t + 5 * 86400)))
            check(note == L("可用重置额度 2 次，最早 \(day) 过期", "Reset credits: 2 available, earliest expires \(day)"), L("重置额度说明文字错：\(note)", "Reset credits note wrong: \(note)"))
        }
        // 2. 顺序颠倒：按时长归类，不按位置
        do {
            let u = parseRPCResult(json("""
            {"rateLimits":{"primary":{"usedPercent":80,"windowDurationMins":10080,"resetsAt":\(t + 7200)},
                           "secondary":{"usedPercent":5,"windowDurationMins":299.5,"resetsAt":\(t + 600)}}}
            """))
            check(u.session?.usedPercent == 5 && u.weekly?.usedPercent == 80, L("归类：应按 windowDurationMins 归类（容差 1 分钟）", "Classify: should go by windowDurationMins (1-minute tolerance)"))
            check(u.credits == nil && !u.creditsComplete, L("没有重置额度字段时应为 nil 且不完整", "Without a reset credits field it should be nil and incomplete"))
        }
        // 3. 时长认不出：primary 当 5 小时窗口、secondary 当每周；标签按真实时长
        do {
            let u = parseRPCResult(json("""
            {"rateLimits":{"primary":{"usedPercent":120,"windowDurationMins":60},"secondary":{"usedPercent":-3,"windowDurationMins":1440}}}
            """))
            let w = serviceWindows(u, now: now)
            check(w.count == 2 && w[0].kind == .session && w[0].label == L("1 小时窗口", "1-hour window") && w[0].percent == 100, L("未知时长：primary 应归 5 小时位、夹到 100", "Unknown length: primary should take the 5-hour slot and clamp to 100"))
            check(w.count == 2 && w[1].kind == .weekly && w[1].label == L("1 天窗口", "1-day window") && w[1].percent == 0, L("未知时长：secondary 应归每周位、夹到 0", "Unknown length: secondary should take the weekly slot and clamp to 0"))
            check(w.allSatisfy { $0.resetsAt == nil }, L("没有 resetsAt 时应为 nil", "Without resetsAt it should be nil"))
        }
        // 4. 缺 usedPercent 的窗口丢弃；布尔值不当数字
        do {
            let u = parseRPCResult(json(#"{"rateLimits":{"primary":{"windowDurationMins":300},"secondary":{"usedPercent":true,"windowDurationMins":10080}}}"#))
            check(u.session == nil && u.weekly == nil && serviceWindows(u).isEmpty, L("缺 usedPercent / 布尔值的窗口应丢弃", "Windows missing usedPercent or with a boolean value should be dropped"))
        }
        // 5. 重置时间已过 → 视为 0
        do {
            let u = Usage(session: LimitWindow(usedPercent: 90, windowMins: 300, resetsAt: now.addingTimeInterval(-600)))
            let w = serviceWindows(u, now: now)
            check(w.first?.percent == 0 && w.first?.detail == L("已重置", "Already reset"), L("重置时间已过应显示 0%", "A past reset time should show 0%"))
        }
        // 6. 网页接口：plan_type 必须有；limit_window_seconds → 分钟（向上取整）；缺 available_count 时数 available 条数
        do {
            let d = json("""
            {"plan_type":"plus","rate_limit":{"primary_window":{"used_percent":12,"limit_window_seconds":18000,"reset_at":\(t + 1800)},
                                              "secondary_window":{"used_percent":55,"limit_window_seconds":604800,"reset_at":\(t + 86400)}},
             "rate_limit_reset_credits":{"total_earned_count":2,"credits":[{"status":"available","expires_at":"2030-10-20T12:00:00Z"},
                                                                          {"status":"redeemed","expires_at":"2030-01-01T00:00:00Z"}]}}
            """)
            let u = parseHTTPUsage(d)
            check(u?.plan == "Plus", L("网页接口：plan_type 映射错", "Web API: plan_type mapped wrong"))
            check(u?.session?.usedPercent == 12 && u?.session?.windowMins == 300, L("网页接口：5 小时窗口错", "Web API: 5-hour window wrong"))
            check(u?.weekly?.usedPercent == 55 && u?.weekly?.windowMins == 10080, L("网页接口：每周窗口错", "Web API: weekly window wrong"))
            check(u?.credits?.available == 1 && u?.credits?.totalEarned == 2, L("网页接口：缺 available_count 时应数 available 条数", "Web API: without available_count it should count the available entries"))
            check(near(u?.credits?.nextExpiresAt, parseISO("2030-10-20T12:00:00Z")), L("网页接口：expires_at ISO 字符串应能解析", "Web API: an ISO expires_at string should parse"))
            check(parseHTTPUsage(json(#"{"rate_limit":{}}"#)) == nil, L("网页接口：没有 plan_type 应视为无效", "Web API: missing plan_type should be invalid"))
            let odd = parseHTTPUsage(json(#"{"plan_type":"enterprise","rate_limit":{"primary_window":{"used_percent":1,"limit_window_seconds":3601}}}"#))
            check(odd?.session?.windowMins == 61 && odd?.plan == "Enterprise", L("网页接口：limit_window_seconds 应向上取整到分钟", "Web API: limit_window_seconds should round up to minutes"))
        }
        // 7. 宽松时间：秒 / 毫秒 / 数字字符串
        do {
            let c = rpcCredits(json(#"{"availableCount":1,"nextExpiresAt":1893456000000}"#))
            check(near(c?.nextExpiresAt, Date(timeIntervalSince1970: 1_893_456_000)), L("nextExpiresAt 毫秒应识别", "nextExpiresAt in milliseconds should be recognized"))
            check(near(flexDate("1893456000"), Date(timeIntervalSince1970: 1_893_456_000)), L("数字字符串（秒）应识别", "A numeric string (seconds) should be recognized"))
            check(rpcCredits(json(#"{"availableCount":"2"}"#)) == nil, L("availableCount 不是数字应视为没有", "A non-numeric availableCount should count as missing"))
            check(creditsNote(ResetCredits(available: 0, totalEarned: nil, nextExpiresAt: nil)) == nil, L("从没有过重置额度不该显示", "Should not show when there have never been reset credits"))
            check(creditsNote(ResetCredits(available: 3, totalEarned: nil, nextExpiresAt: nil)) == L("可用重置额度 3 次", "Reset credits: 3 available"), L("没有过期时间的说明文字错", "Note without an expiry time is wrong"))
        }
        // 8. auth.json：id_token 只解 payload；邮箱可在 profile 命名空间；套餐来自 chatgpt_plan_type
        do {
            func b64url(_ o: [String: Any]) -> String {
                let d = (try? JSONSerialization.data(withJSONObject: o)) ?? Data()
                return d.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
                    .replacingOccurrences(of: "=", with: "")
            }
            let idt = b64url(["alg": "none"]) + "." + b64url(["https://api.openai.com/profile": ["email": "dev@example.com"],
                                                             "https://api.openai.com/auth": ["chatgpt_plan_type": "pro", "chatgpt_account_id": "acct-x"],
                                                             "pad": "??>>"]) + ".sig"
            let at = b64url(["alg": "none"]) + "." + b64url(["exp": t - 60]) + ".sig"
            let raw: [String: Any] = ["OPENAI_API_KEY": NSNull(), "tokens": ["id_token": idt, "access_token": at, "refresh_token": "r"]]
            let a = parseAuth((try? JSONSerialization.data(withJSONObject: raw)) ?? Data())
            check(a?.email == "dev@example.com" && a?.plan == "Pro", L("auth：id_token 邮箱 / 套餐解析错", "auth: email / plan from id_token parsed wrong"))
            check(a?.accountId == "acct-x", L("auth：缺 tokens.account_id 时应取 id_token 里的 chatgpt_account_id", "auth: without tokens.account_id it should use chatgpt_account_id from id_token"))
            check(a.map { tokenExpired($0, now: now) } == true, L("auth：access_token 的 exp 已过应判过期", "auth: an access_token with a past exp should count as expired"))
            check(a?.apiKeyOnly == false, L("auth：有 ChatGPT 令牌不该判成 API Key 登录", "auth: a ChatGPT token should not count as API key sign-in"))
            check(!(a?.description ?? "").contains("ey") && a?.description == L("Codex 凭据（已隐藏）", "Codex credentials (hidden)"), L("auth：description 不能带令牌", "auth: description must not contain the token"))
            let k = parseAuth(Data(#"{"OPENAI_API_KEY":"sk-test"}"#.utf8))
            check(k?.apiKeyOnly == true, L("auth：只有 API Key 应判成 API Key 登录", "auth: API key only should count as API key sign-in"))
            check(parseAuth(Data("{not json".utf8)) == nil, L("auth：坏 JSON 应返回 nil", "auth: bad JSON should return nil"))
            if let req = whamRequest("usage", auth: a ?? Auth()) {
                check(req.value(forHTTPHeaderField: "User-Agent") == "codex-cli" && req.value(forHTTPHeaderField: "OpenAI-Beta") == "codex-1"
                      && req.value(forHTTPHeaderField: "originator") == "Codex Desktop" && req.value(forHTTPHeaderField: "ChatGPT-Account-Id") == "acct-x"
                      && req.url?.absoluteString == "https://chatgpt.com/backend-api/wham/usage" && req.httpMethod == "GET",
                      L("网页接口请求头 / 地址错", "Web API request headers / URL wrong"))
            } else { fails.append(L("网页接口请求没构造出来", "Web API request was not built")) }
            check(whamRequest("usage", auth: Auth()) == nil, L("没有 access_token 不该构造请求", "Should not build a request without access_token"))
        }
        // 9. 错误分类与打码
        do {
            check(isAuthFailure("Error: refresh token was already used. Please sign in again."), L("登录失效识别：refresh token was already used", "Expired sign-in detection: refresh token was already used"))
            check(isAuthFailure("You are NOT LOGGED IN"), L("登录失效识别应不分大小写", "Expired sign-in detection should ignore case"))
            check(!isAuthFailure("connection reset by peer"), L("普通网络错误不该判成登录失效", "A plain network error should not count as expired sign-in"))
            check(isAppServerUnsupported("error: unrecognized subcommand 'app-server'"), L("旧版 codex 识别", "Old codex detection"))
            let red = redact("\u{1B}[31mfirst\u{1B}[0m\nAuthorization: Bearer eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0In0.abcdefghijklmnop failed")
            check(!red.contains("eyJ") && !red.contains("\u{1B}") && red.contains("failed"), L("打码：长令牌 / 颜色码应去掉：\(red)", "Redaction: long tokens / color codes should be removed: \(red)"))
        }

        // 10. 文件系统：找 codex（nvm 默认别名优先）、会话索引回填检测、子进程环境
        let fm = FileManager.default
        let tmp = NSTemporaryDirectory() + "usagemaster-codex-selftest-" + UUID().uuidString
        defer { try? fm.removeItem(atPath: tmp) }
        func mkexe(_ path: String, _ body: String) {
            try? fm.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            try? body.write(toFile: path, atomically: true, encoding: .utf8)
            try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: path)
        }
        do {
            let h = tmp + "/home"
            mkexe(h + "/.nvm/versions/node/v18.20.0/bin/codex", "#!/bin/sh\n")
            mkexe(h + "/.nvm/versions/node/v20.1.0/bin/codex", "#!/bin/sh\n")
            mkexe(h + "/.nvm/versions/node/v20.1.0/bin/node", "#!/bin/sh\n")
            check(findCodex(pathEnv: "", homeDir: h) == h + "/.nvm/versions/node/v20.1.0/bin/codex", L("找 codex：没有默认别名时应取最高版本", "Find codex: without a default alias it should take the highest version"))
            try? fm.createDirectory(atPath: h + "/.nvm/alias/lts", withIntermediateDirectories: true)
            try? "lts/hydrogen\n".write(toFile: h + "/.nvm/alias/default", atomically: true, encoding: .utf8)
            try? "v18.20.0\n".write(toFile: h + "/.nvm/alias/lts/hydrogen", atomically: true, encoding: .utf8)
            check(findCodex(pathEnv: "", homeDir: h) == h + "/.nvm/versions/node/v18.20.0/bin/codex", L("找 codex：nvm 默认别名（含多级别名）应优先", "Find codex: the nvm default alias (including nested aliases) should come first"))
            mkexe(tmp + "/pathbin/codex", "#!/bin/sh\n")
            check(findCodex(pathEnv: tmp + "/pathbin", homeDir: h) == tmp + "/pathbin/codex", L("找 codex：PATH 应最优先", "Find codex: PATH should come first"))
            try? fm.createDirectory(atPath: tmp + "/dirbin/codex", withIntermediateDirectories: true)
            check(findCodex(pathEnv: tmp + "/dirbin", homeDir: tmp + "/nohome") != tmp + "/dirbin/codex", L("找 codex：同名目录不能当可执行文件", "Find codex: a folder with the same name is not an executable"))
            let env = childEnvironment(executable: h + "/.nvm/versions/node/v20.1.0/bin/codex", home: "/x/home")
            check(env["CODEX_HOME"] == "/x/home" && env["PATH"]?.hasPrefix(h + "/.nvm/versions/node/v20.1.0/bin:") == true
                  && env["PATH"]?.contains("/opt/homebrew/bin") == true, L("子进程环境：CODEX_HOME / PATH 错", "Child environment: CODEX_HOME / PATH wrong"))
        }
        do {
            let ch = tmp + "/codexhome"
            try? fm.createDirectory(atPath: ch + "/sessions/2026/10/03", withIntermediateDirectories: true)
            for i in 0..<99 { fm.createFile(atPath: ch + "/sessions/2026/10/03/s\(i).jsonl", contents: Data()) }
            check(!sessionIndexBusy(home: ch), L("回填检测：99 个会话不该判成重建中", "Backfill check: 99 sessions should not count as rebuilding"))
            fm.createFile(atPath: ch + "/sessions/2026/10/03/s99.jsonl.zst", contents: Data())
            check(sessionIndexBusy(home: ch), L("回填检测：没有跟踪记录且 ≥100 个会话应判成重建中", "Backfill check: no tracking record and ≥100 sessions should count as rebuilding"))
            func makeState(_ name: String, _ status: String?) {
                var db: OpaquePointer?
                guard sqlite3_open(ch + "/" + name, &db) == SQLITE_OK else { sqlite3_close(db); return }
                var sql = "CREATE TABLE backfill_state(id INTEGER PRIMARY KEY, status TEXT);"
                if let s = status { sql += "INSERT INTO backfill_state(id, status) VALUES (1, '\(s)');" }
                sqlite3_exec(db, sql, nil, nil, nil)
                sqlite3_close(db)
            }
            makeState("state_3.sqlite", "running")
            makeState("state_12.sqlite", "complete")
            check(!sessionIndexBusy(home: ch), L("回填检测：应取版本号最大的 state_12（complete）", "Backfill check: should use the highest version, state_12 (complete)"))
            makeState("state_20.sqlite", "running")
            check(sessionIndexBusy(home: ch), L("回填检测：backfill_state 不是 complete 应判成重建中", "Backfill check: backfill_state other than complete should count as rebuilding"))
            makeState("state_30.sqlite", nil)
            check(sessionIndexBusy(home: ch), L("回填检测：表里没记录时按会话数（≥100）判", "Backfill check: with no row in the table, decide by session count (≥100)"))
        }

        // 11. 假 app-server：校验收到的 JSON-RPC 顺序、CODEX_HOME、cwd 是空目录，回固定结果
        do {
            let home = tmp + "/fakehome"
            try? fm.createDirectory(atPath: home, withIntermediateDirectories: true)
            let ok = tmp + "/fake-ok.sh"
            mkexe(ok, """
            #!/bin/sh
            trap '' TERM
            [ "$CODEX_HOME" = '\(home)' ] || { echo "bad CODEX_HOME" >&2; exit 9; }
            IFS= read -r a || exit 3
            case "$a" in *'"method":"initialize"'*) ;; *) echo "bad init" >&2; exit 4;; esac
            printf '%s\\n' '{"jsonrpc":"2.0","id":null,"method":"remote/notice","params":{}}'
            printf '%s\\n' '{"jsonrpc":"2.0","id":1,"result":{"userAgent":"fake"}}'
            IFS= read -r b || exit 5
            IFS= read -r c || exit 6
            case "$b" in *'"method":"initialized"'*) ;; *) exit 7;; esac
            case "$c" in *'"method":"account/rateLimits/read"'*) ;; *) exit 8;; esac
            printf '%s\\n' '{"jsonrpc":"2.0","id":2,"method":"server/request","params":{}}'
            n=$(ls -A | wc -l | tr -d ' ')
            printf '{"jsonrpc":"2.0","id":2,"result":{"rateLimits":{"primary":{"usedPercent":%s,"windowDurationMins":300,"resetsAt":\(t + 3600)},"secondary":{"usedPercent":7,"windowDurationMins":10080,"resetsAt":\(t + 86400)}},"rateLimitResetCredits":{"availableCount":1,"nextExpiresAt":\(t + 86400)}}}\\n' "$n"
            cat >/dev/null
            """)
            let t0 = Date()
            switch runAppServer(executable: ok, home: home, initTimeout: 5, rpcTimeout: 5, killGrace: 3) {
            case .ok(let u):
                check(u.session?.usedPercent == 0, L("假 app-server：cwd 应是空目录（得到 \(u.session?.usedPercent ?? -1) 个文件）", "Fake app-server: cwd should be an empty folder (got \(u.session?.usedPercent ?? -1) files)"))
                check(u.weekly?.usedPercent == 7 && u.credits?.available == 1, L("假 app-server：结果解析错", "Fake app-server: result parsed wrong"))
            case .authFailed: fails.append(L("假 app-server：不该判成登录失效", "Fake app-server: should not count as expired sign-in"))
            case .failed(let m): fails.append(L("假 app-server 失败：\(m)", "Fake app-server failed: \(m)"))
            }
            // 假进程忽略 SIGTERM：只有先关 stdin 才能很快结束，否则要等 3 秒宽限后 SIGKILL
            check(Date().timeIntervalSince(t0) < 2, L("假 app-server：关 stdin 后应很快结束", "Fake app-server: should exit quickly after stdin is closed"))

            let authFail = tmp + "/fake-auth.sh"
            mkexe(authFail, "#!/bin/sh\necho 'Error: refresh token was already used' >&2\nexit 1\n")
            if case .authFailed = runAppServer(executable: authFail, home: home, initTimeout: 5, rpcTimeout: 5, killGrace: 1) {} else {
                fails.append(L("假 app-server：stderr 是登录失效应判 authFailed", "Fake app-server: an expired sign-in on stderr should give authFailed"))
            }

            let rpcErr = tmp + "/fake-rpcerr.sh"
            mkexe(rpcErr, """
            #!/bin/sh
            IFS= read -r a; printf '%s\\n' '{"id":1,"result":{}}'
            IFS= read -r b; IFS= read -r c; printf '%s\\n' '{"id":2,"error":{"code":-32603,"message":"boom eyJhbGciOiJIUzI1NiJ9xxxxxxxxxxxxxxxx"}}'
            cat >/dev/null
            """)
            if case .failed(let m) = runAppServer(executable: rpcErr, home: home, initTimeout: 5, rpcTimeout: 5, killGrace: 1) {
                check(m.hasPrefix(L("codex 返回错误：boom", "codex returned an error: boom")) && !m.contains("eyJ"), L("假 app-server：JSON-RPC 错误应原样（打码）带出：\(m)", "Fake app-server: a JSON-RPC error should be passed through (redacted): \(m)"))
            } else { fails.append(L("假 app-server：JSON-RPC 错误应判 failed", "Fake app-server: a JSON-RPC error should give failed")) }

            let rpcAuth = tmp + "/fake-rpcauth.sh"
            mkexe(rpcAuth, """
            #!/bin/sh
            IFS= read -r a; printf '%s\\n' '{"id":1,"result":{}}'
            IFS= read -r b; IFS= read -r c; printf '%s\\n' '{"id":2,"error":{"message":"ChatGPT authentication required"}}'
            cat >/dev/null
            """)
            if case .authFailed = runAppServer(executable: rpcAuth, home: home, initTimeout: 5, rpcTimeout: 5, killGrace: 1) {} else {
                fails.append(L("假 app-server：JSON-RPC 登录类错误应判 authFailed", "Fake app-server: a JSON-RPC sign-in error should give authFailed"))
            }

            // 不回应、还忽略 SIGTERM：应在超时 + 宽限后被 SIGKILL 收掉
            let hang = tmp + "/fake-hang.sh", pidFile = tmp + "/fake-hang.pid"
            mkexe(hang, "#!/bin/sh\necho $$ > '\(pidFile)'\ntrap '' TERM\nwhile :; do sleep 1; done\n")
            let t1 = Date()
            if case .failed(let m) = runAppServer(executable: hang, home: home, initTimeout: 0.5, rpcTimeout: 0.5, killGrace: 0.5) {
                check(m.contains(L("启动超时", "startup timed out")), L("假 app-server：不回应应报启动超时：\(m)", "Fake app-server: no response should report a startup timeout: \(m)"))
            } else { fails.append(L("假 app-server：不回应应判 failed", "Fake app-server: no response should give failed")) }
            check(Date().timeIntervalSince(t1) < 4.5, L("假 app-server：超时后应在宽限期内结束", "Fake app-server: should end within the grace period after a timeout"))
            if let s = try? String(contentsOfFile: pidFile, encoding: .utf8), let pid = Int32(s.trimmingCharacters(in: .whitespacesAndNewlines)) {
                let alive = kill(pid, 0) == 0
                check(!alive, L("假 app-server：忽略 SIGTERM 的进程应被 SIGKILL 收掉", "Fake app-server: a process that ignores SIGTERM should be killed with SIGKILL"))
                if alive { kill(pid, SIGKILL) }
            } else { fails.append(L("假 app-server：没拿到进程号", "Fake app-server: no process ID")) }

            let early = tmp + "/fake-early.sh"
            mkexe(early, "#!/bin/sh\necho 'panic: something broke' >&2\nexit 2\n")
            if case .failed(let m) = runAppServer(executable: early, home: home, initTimeout: 5, rpcTimeout: 5, killGrace: 1) {
                check(m.contains(L("退出码 2", "exit code 2")) && m.contains("panic: something broke"), L("假 app-server：提前退出的说明错：\(m)", "Fake app-server: early exit message wrong: \(m)"))
            } else { fails.append(L("假 app-server：提前退出应判 failed", "Fake app-server: early exit should give failed")) }

            if case .failed = runAppServer(executable: tmp + "/does-not-exist", home: home, initTimeout: 1, rpcTimeout: 1, killGrace: 1) {} else {
                fails.append(L("可执行文件不存在应判 failed", "A missing executable should give failed"))
            }
        }
        return fails
    }
}
