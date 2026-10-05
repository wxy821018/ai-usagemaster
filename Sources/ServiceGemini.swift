// Gemini CLI / Antigravity：Google Code Assist 配额（loadCodeAssist 取项目 → retrieveUserQuota 取各模型余量）
// 协议参考自 Orca 1.4.219（MIT，Copyright (c) 2026 Lovecast Inc.）；字段含义另对照 Gemini CLI 开源代码（Apache-2.0）
//
// 凭据只读不写：
// - Gemini CLI：~/.gemini/oauth_creds.json（Windows 为 %USERPROFILE%\.gemini\oauth_creds.json），账号邮箱读同目录 google_accounts.json
// - OpenCode：auth.json 里 type=oauth 的 google 条目（refresh 字段是 "refreshToken|projectId|managedProjectId"）
// access_token 过期时用 Google OAuth 刷新换新 access token，只放内存，不写回任何文件（Google 刷新一般不轮换 refresh token；本机无凭据，未实测）。
// 刷新所需的 OAuth client 不内置：与 Orca 相同，运行时从本机 Gemini CLI 安装包的 oauth2.js 里读出
// （来源 Gemini CLI 开源代码 packages/core/src/code_assist/oauth2.ts，注释写明这是 installed app 的公开 client；
//  不写进本仓库，是为了不让 GOCSPX- 开头的字面量触发 GitHub 的密钥扫描）。

#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking   // Windows / Linux 上 URLSession 在这个模块里
#endif

// MARK: - 凭据

enum GeminiCredSource { case geminiCLI, openCode }

struct GeminiCredential {
    var source: GeminiCredSource
    var path: String
    var accessToken: String?
    var refreshToken: String
    var expiresAt: Date?
    var fallbackProjects: [String] = []      // OpenCode refresh 串里带的项目 ID，loadCodeAssist 取不到时兜底
    var email: String? = nil

    var accountId: String { source == .geminiCLI ? "gemini-cli" : "opencode-google:" + path }
    var title: String { email ?? (source == .geminiCLI ? L("Gemini CLI 登录", "Gemini CLI sign-in") : L("OpenCode 的 Google 登录", "OpenCode Google sign-in")) }
    var sourceNote: String {
        source == .geminiCLI ? L("凭据：Gemini CLI（~/.gemini/oauth_creds.json，只读）", "Credentials: Gemini CLI (~/.gemini/oauth_creds.json, read-only)")
                             : L("凭据：OpenCode 的 Google 登录（\(abbreviatedPath(path))，只读）",
                                 "Credentials: OpenCode Google sign-in (\(abbreviatedPath(path)), read-only)")
    }
    /// 内存令牌缓存的键：refresh token 的哈希，不拿令牌本身当键
    var cacheKey: String {
        SHA256.hash(data: Data(refreshToken.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - Code Assist 协议与解析

enum GeminiCodeAssist {
    static let loadURL = URL(string: "https://cloudcode-pa.googleapis.com/v1internal:loadCodeAssist")!
    static let quotaURL = URL(string: "https://cloudcode-pa.googleapis.com/v1internal:retrieveUserQuota")!
    static let tokenURL = URL(string: "https://oauth2.googleapis.com/token")!

    static var home: String { NSHomeDirectory() }
    static var geminiCredsPath: String { home + "/.gemini/oauth_creds.json" }
    static var geminiAccountsPath: String { home + "/.gemini/google_accounts.json" }

    /// OpenCode auth.json 的候选位置（顺序同 Orca）：Windows %APPDATA% → $XDG_DATA_HOME → ~/.local/share → macOS Application Support
    static var openCodeAuthPaths: [String] {
        let env = ProcessInfo.processInfo.environment
        var out: [String] = []
        if let a = env["APPDATA"], !a.isEmpty { out.append(a + "/opencode/auth.json") }
        if let x = env["XDG_DATA_HOME"], !x.isEmpty { out.append(x + "/opencode/auth.json") }
        out.append(home + "/.local/share/opencode/auth.json")
        out.append(home + "/Library/Application Support/opencode/auth.json")
        return out
    }

    static func readJSON(_ path: String) -> [String: Any]? {
        guard let d = FileManager.default.contents(atPath: path) else { return nil }
        return (try? JSONSerialization.jsonObject(with: d)) as? [String: Any]
    }

    /// Gemini CLI 的 oauth_creds.json：access_token、refresh_token 必须是字符串；expiry_date 是毫秒时间戳
    static func parseGeminiCreds(_ o: [String: Any], path: String) -> GeminiCredential? {
        guard let at = o["access_token"] as? String, let rt = o["refresh_token"] as? String, !rt.isEmpty else { return nil }
        return GeminiCredential(source: .geminiCLI, path: path, accessToken: at.isEmpty ? nil : at,
                                refreshToken: rt, expiresAt: msDate(o["expiry_date"]))
    }

    /// OpenCode auth.json：只认 google.type == "oauth"；refresh 是 "refreshToken|projectId|managedProjectId"，expires 是毫秒
    static func parseOpenCodeAuth(_ o: [String: Any], path: String) -> GeminiCredential? {
        guard let g = o["google"] as? [String: Any], g["type"] as? String == "oauth",
              let refresh = g["refresh"] as? String else { return nil }
        let parts = refresh.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        guard let rt = parts.first, !rt.isEmpty else { return nil }
        let access = g["access"] as? String
        return GeminiCredential(source: .openCode, path: path, accessToken: (access?.isEmpty ?? true) ? nil : access,
                                refreshToken: rt, expiresAt: msDate(g["expires"]),
                                fallbackProjects: parts.dropFirst().filter { !$0.isEmpty })
    }

    /// 本机所有可用凭据：OpenCode 在前（Orca 优先用它），Gemini CLI 在后。
    /// 与 Orca 的差别：Orca 只取第一份能读到的 auth.json、且两种来源二选一；这里各候选都看，两种来源都列出（同一项目的会在取数后合并）
    static func localCredentials() -> [GeminiCredential] {
        var out: [GeminiCredential] = []
        var seenPaths = Set<String>()
        for p in openCodeAuthPaths where !seenPaths.contains(p) {
            seenPaths.insert(p)
            if let o = readJSON(p), let c = parseOpenCodeAuth(o, path: p) { out.append(c); break }
        }
        if let o = readJSON(geminiCredsPath), var c = parseGeminiCreds(o, path: geminiCredsPath) {
            if let email = readJSON(geminiAccountsPath)?["active"] as? String, !email.isEmpty { c.email = email }
            out.append(c)
        }
        return out
    }

    static func hasCredentials() -> Bool { !localCredentials().isEmpty }

    // MARK: 请求

    /// loadCodeAssist 的请求体（与 Orca / Gemini CLI 相同）
    static func loadCodeAssistBody() -> [String: Any] {
        ["metadata": ["ideType": "GEMINI_CLI", "pluginType": "GEMINI"]]
    }

    static func quotaBody(project: String) -> [String: Any] { ["project": project] }

    static func makeRequest(_ url: URL, token: String, body: [String: Any]) -> URLRequest {
        var req = URLRequest(url: url, timeoutInterval: 10)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("UsageMaster/1.0", forHTTPHeaderField: "User-Agent")
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        return req
    }

    /// 发请求（必须用不落盘的 session），返回状态码与解析后的 JSON
    static func post(_ req: URLRequest) async throws -> (Int, Any?) {
        let (data, resp) = try await session.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        return (code, try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]))
    }

    /// loadCodeAssist 响应：cloudaicompanionProject（项目 ID）+ currentTier（套餐）
    static func parseLoadCodeAssist(_ j: Any?) -> (project: String?, plan: String?) {
        guard let d = j as? [String: Any] else { return (nil, nil) }
        let project = (d["cloudaicompanionProject"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        var plan: String?
        if let tier = d["currentTier"] as? [String: Any] {
            if let n = tier["name"] as? String, !n.isEmpty { plan = n }
            else if let id = tier["id"] as? String {
                plan = ["free-tier": L("免费版", "Free"), "standard-tier": "Standard", "legacy-tier": "Legacy"][id] ?? id
            }
        }
        return (project, plan)
    }

    static func formEncode(_ items: [(String, String)]) -> Data {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        let s = items.map { "\($0.0)=\($0.1.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")" }.joined(separator: "&")
        return Data(s.utf8)
    }

    // MARK: 刷新所需的 OAuth client（运行时从本机 Gemini CLI 读）

    /// 与 Orca 同一正则：OAUTH_CLIENT_ID = '...' / OAUTH_CLIENT_SECRET = '...'（\s 能跨行，源码里 ID 的值在下一行）
    static func parseOAuthClient(_ text: String) -> (id: String, secret: String)? {
        func grab(_ name: String) -> String? {
            guard let re = try? NSRegularExpression(pattern: name + #"\s*=\s*['"]([^'"]+)['"]"#),
                  let m = re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
                  let r = Range(m.range(at: 1), in: text) else { return nil }
            return String(text[r])
        }
        guard let id = grab("OAUTH_CLIENT_ID"), let secret = grab("OAUTH_CLIENT_SECRET") else { return nil }
        return (id, secret)
    }

    static func clientFromFile(_ path: String) -> (id: String, secret: String)? {
        let fm = FileManager.default
        guard fm.fileExists(atPath: path),
              let size = (try? fm.attributesOfItem(atPath: path))?[.size] as? NSNumber, size.intValue < 64 << 20,
              let text = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
        return parseOAuthClient(text)
    }

    /// 找 gemini 可执行文件：先看 PATH，再看常见安装位置（菜单栏应用的 PATH 很短，所以固定位置要补上）
    static func geminiExecutable() -> String? {
        let fm = FileManager.default
        var dirs = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
        dirs += ["/usr/local/bin", "/opt/homebrew/bin", home + "/.local/bin", home + "/bin", home + "/.npm-global/bin"]
        if let vs = try? fm.contentsOfDirectory(atPath: home + "/.nvm/versions/node") {
            dirs += vs.sorted().reversed().map { home + "/.nvm/versions/node/\($0)/bin" }
        }
        for d in dirs where !d.isEmpty {
            let p = d + "/gemini"
            if fm.isExecutableFile(atPath: p) { return p }
        }
        return nil
    }

    /// 与 Orca 相同的查找顺序：Homebrew / npm 全局的固定相对位置 → 向上找 @google/gemini-cli 的 package.json → 扫 bundle/*.js
    static func findOAuthClient() -> (id: String, secret: String)? {
        guard let bin = geminiExecutable() else { return nil }
        let fm = FileManager.default
        let real = URL(fileURLWithPath: bin).resolvingSymlinksInPath().path
        let rel = "dist/src/code_assist/oauth2.js"
        let t = (real as NSString).deletingLastPathComponent
        let n = (t as NSString).deletingLastPathComponent
        let fixed = [
            n + "/libexec/lib/node_modules/@google/gemini-cli/node_modules/@google/gemini-cli-core/" + rel,
            n + "/lib/node_modules/@google/gemini-cli/node_modules/@google/gemini-cli-core/" + rel,
            n + "/share/gemini-cli/node_modules/@google/gemini-cli-core/" + rel,
            n + "/../gemini-cli-core/" + rel,
            n + "/node_modules/@google/gemini-cli-core/" + rel,
        ]
        for p in fixed { if let c = clientFromFile((p as NSString).standardizingPath) { return c } }

        // 向上最多 8 层找 @google/gemini-cli 包根目录
        var pkg: String?
        var dir = t
        for _ in 0...8 {
            if let o = readJSON(dir + "/package.json"), o["name"] as? String == "@google/gemini-cli" { pkg = dir; break }
            let a = dir + "/lib/node_modules/@google/gemini-cli", b = dir + "/node_modules/@google/gemini-cli"
            if fm.fileExists(atPath: a + "/package.json") { pkg = a; break }
            if fm.fileExists(atPath: b + "/package.json") { pkg = b; break }
            let up = (dir as NSString).deletingLastPathComponent
            if up == dir { break }
            dir = up
        }
        guard let root = pkg else { return nil }
        if let c = clientFromFile(root + "/node_modules/@google/gemini-cli-core/" + rel) ?? clientFromFile(root + "/" + rel) { return c }
        if let files = try? fm.contentsOfDirectory(atPath: root + "/bundle") {
            for f in files.sorted() where f.hasSuffix(".js") {
                if let c = clientFromFile(root + "/bundle/" + f) { return c }
            }
        }
        return nil
    }

    // MARK: 配额解析与窗口映射

    struct Bucket {
        var modelId: String
        var remainingFraction: Double?     // 0..1；proto3 JSON 会省略 0 值，缺失时不当成 0，标为未知
        var remainingAmount: Double?       // 剩余次数（int64 以字符串返回）
        var resetsAt: Date?
        var tokenType: String?             // Gemini CLI 测试样例里是 "REQUESTS"
    }

    /// 响应可以是数组，也可以是 {buckets:[...]}（同 Orca）。必须有 modelId；
    /// Orca 还要求 remainingFraction 与 resetTime 都在，这里放宽：缺了也保留，显示为未知，免得用完的那项被悄悄丢掉
    static func parseBuckets(_ j: Any?) -> [Bucket] {
        let items: [[String: Any]] = (j as? [[String: Any]]) ?? ((j as? [String: Any])?["buckets"] as? [[String: Any]]) ?? []
        return items.compactMap { b in
            guard let id = b["modelId"] as? String, !id.isEmpty else { return nil }
            var rf: Double?
            if let n = b["remainingFraction"] as? NSNumber, n.doubleValue.isFinite { rf = n.doubleValue }
            return Bucket(modelId: id, remainingFraction: rf, remainingAmount: num(b["remainingAmount"]),
                          resetsAt: parseISO(b["resetTime"]), tokenType: b["tokenType"] as? String)
        }
    }

    /// 模型显示名表（照抄 Orca）；表里没有的去掉 gemini- 前缀、按 - 拆开首字母大写
    static let modelNames: [String: String] = [
        "gemini-3.1-pro": "3.1 Pro", "gemini-3.1-flash": "3.1 Flash", "gemini-3.1-flash-lite": "3.1 Flash Lite",
        "gemini-3.0-pro": "3.0 Pro", "gemini-3.0-flash": "3.0 Flash",
        "gemini-2.5-pro": "Pro", "gemini-2.5-flash": "Flash", "gemini-2.5-flash-lite": "Flash Lite",
        "gemini-2.0-pro": "2.0 Pro", "gemini-2.0-flash": "2.0 Flash", "gemini-2.0-flash-lite": "2.0 Flash Lite",
        "gemini-1.5-pro": "1.5 Pro", "gemini-1.5-flash": "1.5 Flash",
        "gemini-exp": "Exp", "gemini-experimental": "Exp",
    ]

    static func displayName(_ modelId: String) -> String {
        if let n = modelNames[modelId] { return n }
        let stripped = modelId.replacingOccurrences(of: "^gemini-", with: "", options: [.regularExpression, .caseInsensitive])
        return stripped.split(separator: "-", omittingEmptySubsequences: false)
            .map { $0.isEmpty ? "" : $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
    }

    /// 窗口周期按重置时间推断（Orca 写死 60 分钟，不照抄）。
    /// Gemini CLI 官方文档：Google 账号登录的配额是"每人每天最多 N 次请求"，所以一天内重置的按每日算；
    /// 每分钟限流文档说存在，但没见它出现在这个接口里，不按"每分钟"标。
    static func period(resetsAt: Date?, now: Date) -> WindowKind {
        guard let r = resetsAt else { return .other }
        let dt = r.timeIntervalSince(now)
        if dt <= 26 * 3600 { return .daily }
        if dt <= 8 * 86400 { return .weekly }
        if dt <= 32 * 86400 { return .monthly }
        return .other
    }

    /// 窗口标签的后半段（周期 + 请求/配额）：按 kind 生成，只在显示时跟随界面语言
    static func quotaLabel(_ kind: WindowKind, requests: Bool) -> String {
        switch kind {
        case .daily: return requests ? L("每日请求", "Daily requests") : L("每日配额", "Daily quota")
        case .weekly: return requests ? L("每周请求", "Weekly requests") : L("每周配额", "Weekly quota")
        case .monthly: return requests ? L("每月请求", "Monthly requests") : L("每月配额", "Monthly quota")
        default: return requests ? L("请求配额", "Request quota") : L("配额", "Quota")
        }
    }

    static func usedPercent(_ rf: Double) -> Double { min(100, max(0, ((1 - rf) * 100).rounded())) }

    /// 每个 bucket 一个窗口；已用百分比与重置时间都相同的合成一个（Orca 的去重规则：优先已知模型名，其次名字更短），
    /// 被合并掉的模型名写进 detail，不悄悄丢
    static func windows(from buckets: [Bucket], now: Date) -> [ServiceWindow] {
        struct Group { var main: Bucket; var names: [String] }
        var groups: [Group] = []
        var index: [String: Int] = [:]
        for b in buckets {
            let pct = b.remainingFraction.map(usedPercent)
            let reset = roundedMinute(b.resetsAt)
            let key = "\(pct.map { String($0) } ?? "?")|\(reset?.timeIntervalSince1970 ?? -1)|\(b.tokenType ?? "")"
            guard pct != nil, let i = index[key] else {
                if pct != nil { index[key] = groups.count }
                groups.append(Group(main: b, names: [displayName(b.modelId)]))
                continue
            }
            let cur = groups[i].main
            let newKnown = modelNames[b.modelId] != nil, curKnown = modelNames[cur.modelId] != nil
            if (newKnown && !curKnown) || (newKnown == curKnown && displayName(b.modelId).count < displayName(cur.modelId).count) {
                groups[i].main = b
            }
            groups[i].names.append(displayName(b.modelId))
        }

        var out: [ServiceWindow] = []
        for g in groups {
            let b = g.main
            let name = displayName(b.modelId)
            let reset = roundedMinute(b.resetsAt)
            let kind = period(resetsAt: reset, now: now)
            let isRequests = (b.tokenType ?? "").uppercased() == "REQUESTS"
            let label = "\(name) · " + quotaLabel(kind, requests: isRequests)
            var pct = b.remainingFraction.map(usedPercent)
            var details: [String] = []
            if let r = reset, r < now {
                pct = 0
                details.append(L("已到重置时间，等下次刷新", "Reset time has passed, waiting for the next refresh"))
            } else if let amt = b.remainingAmount {
                let unit = isRequests ? L(" 次", " requests") : ""
                if let rf = b.remainingFraction, rf > 0 {
                    let total = Int((amt / rf).rounded())
                    details.append(L("剩余 \(Int(amt))\(unit) / 共约 \(total)\(unit)", "\(Int(amt))\(unit) left / about \(total)\(unit) total"))
                } else {
                    details.append(L("剩余 \(Int(amt))\(unit)", "\(Int(amt))\(unit) left"))
                }
            }
            if b.remainingFraction == nil {
                details.append(L("返回里缺剩余比例（proto3 会省略 0 值，可能已用完）",
                                 "Response has no remaining fraction (proto3 omits zero values, so it may be used up)"))
            }
            var others: [String] = []
            for n in g.names where n != name && !others.contains(n) { others.append(n) }
            if !others.isEmpty { details.append(L("同一额度：", "Shared with: ") + others.joined(separator: listSep)) }
            out.append(ServiceWindow(label: label, percent: pct, resetsAt: reset, kind: kind,
                                     detail: details.isEmpty ? nil : details.joined(separator: L("；", "; "))))
        }
        // 最紧的排前面；未知的排最后
        return out.enumerated().sorted { a, b in
            let pa = a.element.percent ?? -1, pb = b.element.percent ?? -1
            return pa != pb ? pa > pb : a.offset < b.offset
        }.map { $0.element }
    }

    // MARK: 取数

    enum TokenOutcome { case ok(String, refreshed: Bool), fail(String) }

    /// 用 refresh token 换新的 access token（只放内存缓存，不写回凭据文件）
    static func refresh(_ c: GeminiCredential) async -> TokenOutcome {
        guard let client = await GeminiTokenCache.shared.oauthClient() else {
            return .fail(c.source == .geminiCLI
                ? L("令牌已过期，本机找不到 Gemini CLI 安装包来刷新：运行一次 gemini 即可",
                    "Token expired and no local Gemini CLI install was found to refresh it: just run gemini once")
                : L("令牌已过期：打开一次 OpenCode 让它刷新（本机没有 Gemini CLI 可借用刷新）",
                    "Token expired: open OpenCode once so it refreshes it (no local Gemini CLI to refresh with)"))
        }
        var req = URLRequest(url: tokenURL, timeoutInterval: 10)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = formEncode([("client_id", client.id), ("client_secret", client.secret),
                                   ("refresh_token", c.refreshToken), ("grant_type", "refresh_token")])
        do {
            let (code, j) = try await post(req)
            if code == 400 || code == 401 {
                return .fail(c.source == .geminiCLI
                    ? L("登录已失效（刷新被拒 \(code)）：运行 gemini 重新登录",
                        "Sign-in expired (refresh rejected, \(code)): run gemini to sign in again")
                    : L("OpenCode 的 Google 登录已失效（刷新被拒 \(code)）：在 OpenCode 里重新登录",
                        "OpenCode Google sign-in expired (refresh rejected, \(code)): sign in again in OpenCode"))
            }
            guard code == 200, let d = j as? [String: Any], let at = d["access_token"] as? String, !at.isEmpty else {
                return .fail(L("刷新令牌失败：HTTP \(code)", "Token refresh failed: HTTP \(code)"))
            }
            // 响应里若带新的 refresh_token 也不用、不写回：凭据归 Gemini CLI / OpenCode 自己管
            let exp = Date().addingTimeInterval(num(d["expires_in"]) ?? 3000)
            await GeminiTokenCache.shared.save(c.cacheKey, token: at, expiresAt: exp)
            return .ok(at, refreshed: true)
        } catch {
            return .fail(L("刷新令牌失败：\(describe(error))", "Token refresh failed: \(describe(error))"))
        }
    }

    /// 文件里的令牌没过期就直接用；过期了先看内存里有没有刷新过的，再不行就刷新（提前 60 秒）
    static func usableToken(_ c: GeminiCredential, force: Bool) async -> TokenOutcome {
        let now = Date()
        if !force {
            if let t = c.accessToken, (c.expiresAt ?? .distantFuture) > now.addingTimeInterval(60) { return .ok(t, refreshed: false) }
            if let t = await GeminiTokenCache.shared.token(c.cacheKey, now: now) { return .ok(t, refreshed: true) }
        } else {
            await GeminiTokenCache.shared.drop(c.cacheKey)
        }
        return await refresh(c)
    }

    /// 一份凭据 → 一个账号；第二个返回值是项目 ID（用于合并同一账号的两份凭据）
    static func fetchAccount(_ c: GeminiCredential) async -> (ServiceAccount, String?) {
        var acc = ServiceAccount(id: c.accountId, title: c.title)
        acc.notes = [c.sourceNote]
        var project: String?
        var refreshedAny = false
        for attempt in 0..<2 {
            let token: String
            switch await usableToken(c, force: attempt == 1) {
            case .fail(let m): acc.error = m; return (acc, project)
            case .ok(let t, let r): token = t; refreshedAny = refreshedAny || r
            }
            do {
                // 1) 取项目 ID
                let (lc, lj) = try await post(makeRequest(loadURL, token: token, body: loadCodeAssistBody()))
                if lc == 401 && attempt == 0 { continue }
                let parsed: (project: String?, plan: String?) = lc == 200 ? parseLoadCodeAssist(lj) : (nil, nil)
                if let p = parsed.plan { acc.plan = p }
                project = parsed.project ?? c.fallbackProjects.first
                guard let proj = project else {
                    switch lc {
                    case 200: acc.error = L("取不到项目 ID：先运行一次 gemini 完成初始化", "No project ID: run gemini once to finish setup")
                    case 401: acc.error = L("令牌无效（401）：运行 gemini 重新登录", "Token rejected (401): run gemini to sign in again")
                    case 403: acc.error = L("无权使用 Code Assist（403）", "Not allowed to use Code Assist (403)")
                    default: acc.error = L("取项目 ID 失败：HTTP \(lc)", "Project ID request failed: HTTP \(lc)")
                    }
                    return (acc, nil)
                }
                // 2) 取配额
                let (qc, qj) = try await post(makeRequest(quotaURL, token: token, body: quotaBody(project: proj)))
                if qc == 401 && attempt == 0 { continue }
                guard qc == 200 else {
                    acc.error = qc == 401 ? L("令牌无效（401）：运行 gemini 重新登录", "Token rejected (401): run gemini to sign in again")
                        : qc == 429 ? L("查询太频繁（429），稍后再试", "Too many requests (429), try again later")
                        : L("查询配额失败：HTTP \(qc)", "Quota request failed: HTTP \(qc)")
                    return (acc, proj)
                }
                acc.windows = windows(from: parseBuckets(qj), now: Date())
                acc.updatedAt = Date()
                if acc.windows.isEmpty { acc.error = L("返回里没有配额数据（格式可能变了）", "No quota data in the response (the format may have changed)") }
                if refreshedAny {
                    acc.notes.append(L("令牌已过期，已在内存里临时刷新（没有写回凭据文件）",
                                       "Token had expired, refreshed in memory for now (not written back to the credentials file)"))
                }
                return (acc, proj)
            } catch {
                acc.error = describe(error)
                return (acc, project)
            }
        }
        acc.error = L("令牌无效（401）：运行 gemini 重新登录", "Token rejected (401): run gemini to sign in again")
        return (acc, project)
    }

    /// 两种来源若查到同一个项目，就是同一个账号：只留一份（优先没报错的、其次 Gemini CLI 那份，它有邮箱）
    static func mergeSameProject(_ items: [(ServiceAccount, String?, GeminiCredSource)]) -> [ServiceAccount] {
        var out: [(ServiceAccount, String?, GeminiCredSource)] = []
        for it in items {
            if let p = it.1, let i = out.firstIndex(where: { $0.1 == p }) {
                let keepNew = (out[i].0.error != nil && it.0.error == nil)
                    || ((out[i].0.error == nil) == (it.0.error == nil) && it.2 == .geminiCLI)
                var kept = keepNew ? it : out[i]
                kept.0.notes.append(L("Gemini CLI 与 OpenCode 登录的是同一个账号，已合并显示",
                                      "Gemini CLI and OpenCode are signed in to the same account, shown as one"))
                out[i] = kept
            } else {
                out.append(it)
            }
        }
        return out.map { $0.0 }
    }

    static func fetchAllAccounts() async -> [ServiceAccount] {
        var items: [(ServiceAccount, String?, GeminiCredSource)] = []
        for c in localCredentials() {
            let (a, p) = await fetchAccount(c)
            items.append((a, p, c.source))
        }
        return mergeSameProject(items)
    }
}

/// 内存里的令牌缓存与 OAuth client 缓存；不落盘、不打日志
actor GeminiTokenCache {
    static let shared = GeminiTokenCache()
    private var tokens: [String: (token: String, expiresAt: Date)] = [:]
    private var client: (id: String, secret: String)?

    func token(_ key: String, now: Date) -> String? {
        guard let e = tokens[key], e.expiresAt > now.addingTimeInterval(60) else { return nil }
        return e.token
    }
    func save(_ key: String, token: String, expiresAt: Date) { tokens[key] = (token, expiresAt) }
    func drop(_ key: String) { tokens[key] = nil }

    /// 找到一次就记住；找不到下次再找（用户可能刚装上 Gemini CLI）
    func oauthClient() -> (id: String, secret: String)? {
        if let c = client { return c }
        client = GeminiCodeAssist.findOAuthClient()
        return client
    }
}

/// Gemini 与 Antigravity 共用一次取数：30 秒内的结果直接复用，正在取的就等它，不重复发请求
actor GeminiQuotaHub {
    static let shared = GeminiQuotaHub()
    private var inflight: Task<[ServiceAccount], Never>?
    private var last: (at: Date, accounts: [ServiceAccount])?

    func accounts() async -> [ServiceAccount] {
        if let l = last, Date().timeIntervalSince(l.at) < 30 { return l.accounts }
        if let t = inflight { return await t.value }
        let t = Task { await GeminiCodeAssist.fetchAllAccounts() }
        inflight = t
        let v = await t.value
        inflight = nil
        last = (Date(), v)
        return v
    }
}

// MARK: - Gemini CLI

struct GeminiService: UsageService {
    let id = "gemini"
    let displayName = "Gemini CLI"
    let setupHint = L("安装 Gemini CLI（npm i -g @google/gemini-cli），运行 gemini 选「Login with Google」登录；或在 OpenCode 里用 Google OAuth 登录",
                      "Install Gemini CLI (npm i -g @google/gemini-cli), run gemini and choose \"Login with Google\", or sign in with Google OAuth in OpenCode")

    func isConfigured() -> Bool { GeminiCodeAssist.hasCredentials() }

    func fetch() async -> ServiceStatus {
        var st = ServiceStatus(id: id, displayName: displayName, configured: isConfigured(), setupHint: setupHint)
        guard st.configured else { return st }
        st.accounts = await GeminiQuotaHub.shared.accounts()
        return st
    }
}

// MARK: - Antigravity

/// Antigravity 没有独立的用量接口：与 Orca 一样，显示 Gemini 那份 Google Code Assist 配额（同一组数字）
struct AntigravityService: UsageService {
    let id = "antigravity"
    let displayName = "Antigravity"
    let setupHint = L("安装 Antigravity，并用 Gemini CLI 登录 Google（运行 gemini 选「Login with Google」）；这里显示的是两者共用的 Code Assist 配额",
                      "Install Antigravity and sign in to Google with Gemini CLI (run gemini and choose \"Login with Google\"). The quota shown here is the Code Assist quota they share")

    static var appInstalled: Bool {
        let fm = FileManager.default
        return fm.fileExists(atPath: "/Applications/Antigravity.app")
            || fm.fileExists(atPath: NSHomeDirectory() + "/Applications/Antigravity.app")
    }

    func isConfigured() -> Bool { Self.appInstalled && GeminiCodeAssist.hasCredentials() }

    /// 把 Gemini 的账号换成 Antigravity 的：数字原样，加一行说明；出错时改写成"读不到共享配额"
    static func mapFromGemini(_ accounts: [ServiceAccount]) -> [ServiceAccount] {
        accounts.map { g in
            var a = g
            a.id = "antigravity:" + g.id
            a.notes = [L("与 Gemini CLI 共用 Google Code Assist 配额，分不出 Antigravity 自己用了多少",
                         "Shares the Google Code Assist quota with Gemini CLI, so Antigravity's own usage can't be told apart")] + g.notes
            if let e = g.error { a.error = L("读不到共享的 Code Assist 配额：", "Could not read the shared Code Assist quota: ") + e }
            return a
        }
    }

    func fetch() async -> ServiceStatus {
        var st = ServiceStatus(id: id, displayName: displayName, configured: isConfigured(), setupHint: setupHint)
        guard st.configured else { return st }
        st.accounts = Self.mapFromGemini(await GeminiQuotaHub.shared.accounts())
        return st
    }
}

// MARK: - 自测（不发网络请求）

extension GeminiService {
    /// 用规格与 Gemini CLI 源码里的样例 JSON 测解析与窗口映射；返回失败描述，空数组 = 全过
    static func selfTest() -> [String] {
        var fails: [String] = []
        func check(_ ok: Bool, _ msg: String) { if !ok { fails.append(msg) } }
        func json(_ s: String) -> Any? { try? JSONSerialization.jsonObject(with: Data(s.utf8), options: [.fragmentsAllowed]) }
        let now = parseISO("2025-10-22T00:00:00Z")!
        // 期望的窗口标签跟随界面语言（标签由 quotaLabel 按 kind 生成）
        let proDailyReq = L("Pro · 每日请求", "Pro · Daily requests")

        // 1) Gemini CLI server.test.ts 里的 retrieveUserQuota 样例（对象形态）
        let sample = json(#"{"buckets":[{"modelId":"gemini-2.5-pro","tokenType":"REQUESTS","remainingFraction":0.75,"resetTime":"2025-10-22T16:01:15Z"}]}"#)
        let b1 = GeminiCodeAssist.parseBuckets(sample)
        check(b1.count == 1, L("对象形态应解析出 1 个 bucket，实际 \(b1.count)", "Object form should parse 1 bucket, got \(b1.count)"))
        let w1 = GeminiCodeAssist.windows(from: b1, now: now)
        check(w1.count == 1, L("应映射出 1 个窗口", "Should map to 1 window"))
        if let w = w1.first {
            check(w.label == proDailyReq, L("窗口标签错：\(w.label)", "Wrong window label: \(w.label)"))
            check(w.percent == 25, L("已用百分比应为 25，实际 \(String(describing: w.percent))", "Used percent should be 25, got \(String(describing: w.percent))"))
            check(w.kind == .daily, L("一天内重置应为每日窗口", "A reset within a day should be a daily window"))
            check(w.resetsAt == parseISO("2025-10-22T16:01:00Z"), L("重置时间应取整到分钟", "Reset time should be rounded to the minute"))
        }

        // 2) 数组形态 + 无效项丢弃（缺 modelId）+ 越界钳制
        let arr = json(#"[{"modelId":"gemini-2.5-flash","remainingFraction":1.2,"resetTime":"2025-10-22T10:00:00Z"},{"remainingFraction":0.5,"resetTime":"2025-10-22T10:00:00Z"},{"modelId":"gemini-3.1-pro","remainingFraction":-0.1,"resetTime":"2025-10-22T11:00:00Z"}]"#)
        let b2 = GeminiCodeAssist.parseBuckets(arr)
        check(b2.count == 2, L("数组形态应丢掉缺 modelId 的项，剩 2 个，实际 \(b2.count)", "Array form should drop items without modelId and keep 2, got \(b2.count)"))
        let w2 = GeminiCodeAssist.windows(from: b2, now: now)
        check(w2.first?.label == L("3.1 Pro · 每日配额", "3.1 Pro · Daily quota") && w2.first?.percent == 100,
              L("remainingFraction<0 应钳到 100% 且排最前：\(w2.map { $0.label })", "remainingFraction<0 should clamp to 100% and sort first: \(w2.map { $0.label })"))
        check(w2.last?.label == L("Flash · 每日配额", "Flash · Daily quota") && w2.last?.percent == 0,
              L("remainingFraction>1 应钳到 0%", "remainingFraction>1 should clamp to 0%"))

        // 3) 模型显示名
        check(GeminiCodeAssist.displayName("gemini-2.5-flash") == "Flash", L("gemini-2.5-flash 应显示 Flash", "gemini-2.5-flash should show as Flash"))
        check(GeminiCodeAssist.displayName("gemini-3.1-pro") == "3.1 Pro", L("gemini-3.1-pro 应显示 3.1 Pro", "gemini-3.1-pro should show as 3.1 Pro"))
        check(GeminiCodeAssist.displayName("gemini-2.5-pro-preview-06-05") == "2.5 Pro Preview 06 05",
              L("未知模型名转换错：\(GeminiCodeAssist.displayName("gemini-2.5-pro-preview-06-05"))",
                "Wrong name for an unknown model: \(GeminiCodeAssist.displayName("gemini-2.5-pro-preview-06-05"))"))
        check(GeminiCodeAssist.displayName("Gemini-exp-1206") == "Exp 1206", L("前缀应不区分大小写去掉", "Prefix should be removed case-insensitively"))

        // 4) 去重：同百分比同重置时间合成一个，优先已知名，其余名字写进 detail
        let dup = json(#"{"buckets":[{"modelId":"gemini-2.5-pro-preview-06-05","remainingFraction":0.4,"resetTime":"2025-10-22T16:00:00Z","tokenType":"REQUESTS"},{"modelId":"gemini-2.5-pro","remainingFraction":0.4,"resetTime":"2025-10-22T16:00:00Z","tokenType":"REQUESTS"},{"modelId":"gemini-2.5-flash","remainingFraction":0.9,"resetTime":"2025-10-22T16:00:00Z","tokenType":"REQUESTS"}]}"#)
        let w4 = GeminiCodeAssist.windows(from: GeminiCodeAssist.parseBuckets(dup), now: now)
        check(w4.count == 2, L("去重后应剩 2 个窗口，实际 \(w4.count)", "Should have 2 windows after dedup, got \(w4.count)"))
        check(w4.first?.label == proDailyReq && w4.first?.percent == 60,
              L("合并后应保留已知名 Pro、60%：\(w4.map { $0.label })", "Merged window should keep the known name Pro at 60%: \(w4.map { $0.label })"))
        check(w4.first?.detail?.contains(L("同一额度：2.5 Pro Preview 06 05", "Shared with: 2.5 Pro Preview 06 05")) == true,
              L("被合并的模型名应写进 detail：\(w4.first?.detail ?? "nil")", "Merged model names should go into detail: \(w4.first?.detail ?? "nil")"))

        // 5) 剩余次数、缺剩余比例、已过重置时间、周期推断
        let misc = json(#"{"buckets":[{"modelId":"gemini-2.5-pro","remainingFraction":0.75,"remainingAmount":"750","resetTime":"2025-10-22T16:00:00Z","tokenType":"REQUESTS"},{"modelId":"gemini-2.5-flash","resetTime":"2025-10-22T16:00:00Z","tokenType":"REQUESTS"},{"modelId":"gemini-2.0-flash","remainingFraction":0.2,"resetTime":"2025-10-21T23:00:00Z"},{"modelId":"gemini-1.5-pro","remainingFraction":0.5,"resetTime":"2025-10-25T00:00:00Z"}]}"#)
        let w5 = GeminiCodeAssist.windows(from: GeminiCodeAssist.parseBuckets(misc), now: now)
        let byName = Dictionary(w5.map { ($0.label, $0) }, uniquingKeysWith: { a, _ in a })
        check(byName[proDailyReq]?.detail == L("剩余 750 次 / 共约 1000 次", "750 requests left / about 1000 requests total"),
              L("剩余次数说明错：\(byName[proDailyReq]?.detail ?? "nil")", "Wrong remaining count text: \(byName[proDailyReq]?.detail ?? "nil")"))
        check(byName[L("Flash · 每日请求", "Flash · Daily requests")].map { $0.percent == nil && ($0.detail ?? "").contains(L("缺剩余比例", "no remaining fraction")) } == true,
              L("缺 remainingFraction 应显示为未知", "Missing remainingFraction should show as unknown"))
        check(byName[L("2.0 Flash · 每日配额", "2.0 Flash · Daily quota")].map { $0.percent == 0 && ($0.detail ?? "").contains(L("已到重置时间", "Reset time has passed")) } == true,
              L("已过重置时间应视为 0%", "A passed reset time should count as 0%"))
        check(byName[L("1.5 Pro · 每周配额", "1.5 Pro · Weekly quota")]?.kind == .weekly,
              L("三天后重置应推断为每周：\(w5.map { $0.label })", "A reset in three days should be weekly: \(w5.map { $0.label })"))
        check(w5.last?.percent == nil, L("未知百分比应排最后", "Unknown percent should sort last"))

        // 6) 凭据解析（假值）
        let gc = GeminiCodeAssist.parseGeminiCreds(json(#"{"access_token":"a","refresh_token":"r","expiry_date":1761091200000,"token_type":"Bearer"}"#) as! [String: Any], path: "/x")
        check(gc?.refreshToken == "r" && gc?.expiresAt == parseISO("2025-10-22T00:00:00Z"),
              L("oauth_creds.json 解析错（expiry_date 是毫秒）", "Wrong oauth_creds.json parse (expiry_date is in milliseconds)"))
        check(GeminiCodeAssist.parseGeminiCreds(json(#"{"access_token":"a"}"#) as! [String: Any], path: "/x") == nil,
              L("缺 refresh_token 应视为没有凭据", "Missing refresh_token should mean no credentials"))
        let oc = GeminiCodeAssist.parseOpenCodeAuth(json(#"{"google":{"type":"oauth","access":"a","refresh":"rt|proj1|proj2","expires":1761091200000}}"#) as! [String: Any], path: "/y")
        check(oc?.refreshToken == "rt" && oc?.fallbackProjects == ["proj1", "proj2"], L("OpenCode refresh 串拆分错", "Wrong split of the OpenCode refresh string"))
        let oc2 = GeminiCodeAssist.parseOpenCodeAuth(json(#"{"google":{"type":"oauth","access":"a","refresh":"rt||proj2"}}"#) as! [String: Any], path: "/y")
        check(oc2?.fallbackProjects == ["proj2"], L("projectId 为空时应退到 managedProjectId", "An empty projectId should fall back to managedProjectId"))
        check(GeminiCodeAssist.parseOpenCodeAuth(json(#"{"google":{"type":"api","key":"k"}}"#) as! [String: Any], path: "/y") == nil,
              L("google.type 不是 oauth 时不该用", "A google entry whose type is not oauth should be ignored"))

        // 7) 从 oauth2.js 读 OAuth client（假值；tsc 产物里 ID 的值在下一行，bundle 里是双引号）
        let tsc = "const OAUTH_CLIENT_ID =\n  'fake-id.apps.googleusercontent.com';\n// 注释\nconst OAUTH_CLIENT_SECRET = 'fake-secret';\n"
        let c1 = GeminiCodeAssist.parseOAuthClient(tsc)
        check(c1?.id == "fake-id.apps.googleusercontent.com" && c1?.secret == "fake-secret",
              L("跨行的 OAUTH_CLIENT_ID 应能读出", "OAUTH_CLIENT_ID split across lines should be read"))
        let c2 = GeminiCodeAssist.parseOAuthClient(#"var OAUTH_CLIENT_ID = "i2", OAUTH_CLIENT_SECRET = "s2";"#)
        check(c2?.id == "i2" && c2?.secret == "s2", L("bundle 形态应能读出", "Bundle form should be read"))
        check(GeminiCodeAssist.parseOAuthClient("const OAUTH_CLIENT_ID = 'x';") == nil, L("缺 secret 时应返回 nil", "Missing secret should return nil"))

        // 8) 请求构造
        let req = GeminiCodeAssist.makeRequest(GeminiCodeAssist.quotaURL, token: "T", body: GeminiCodeAssist.quotaBody(project: "p1"))
        check(req.httpMethod == "POST" && req.value(forHTTPHeaderField: "Authorization") == "Bearer T"
              && req.value(forHTTPHeaderField: "Content-Type") == "application/json", L("请求方法或请求头错", "Wrong request method or headers"))
        check((req.httpBody.flatMap { json(String(decoding: $0, as: UTF8.self)) } as? [String: String]) == ["project": "p1"],
              L("retrieveUserQuota 请求体应为 {project}", "retrieveUserQuota body should be {project}"))
        let lb = GeminiCodeAssist.loadCodeAssistBody()["metadata"] as? [String: String]
        check(lb == ["ideType": "GEMINI_CLI", "pluginType": "GEMINI"], L("loadCodeAssist 请求体错", "Wrong loadCodeAssist body"))
        let form = String(decoding: GeminiCodeAssist.formEncode([("refresh_token", "1//a+b/c"), ("grant_type", "refresh_token")]), as: UTF8.self)
        check(form == "refresh_token=1%2F%2Fa%2Bb%2Fc&grant_type=refresh_token", L("表单编码错：\(form)", "Wrong form encoding: \(form)"))

        // 9) loadCodeAssist 响应
        let lr = GeminiCodeAssist.parseLoadCodeAssist(json(#"{"cloudaicompanionProject":"proj-x","currentTier":{"id":"free-tier","name":"Gemini Code Assist for individuals"}}"#))
        check(lr.project == "proj-x" && lr.plan == "Gemini Code Assist for individuals", L("loadCodeAssist 解析错", "Wrong loadCodeAssist parse"))
        let lr2 = GeminiCodeAssist.parseLoadCodeAssist(json(#"{"cloudaicompanionProject":"","currentTier":{"id":"standard-tier"}}"#))
        check(lr2.project == nil && lr2.plan == "Standard",
              L("空项目 ID 应视为没有；只有 tier id 时用映射名", "An empty project ID should count as none; a bare tier id should use the mapped name"))

        // 10) 同一项目合并 + Antigravity 映射
        var g1 = ServiceAccount(id: "opencode-google:/y", title: L("OpenCode 的 Google 登录", "OpenCode Google sign-in")); g1.windows = w1
        var g2 = ServiceAccount(id: "gemini-cli", title: "me@example.com"); g2.windows = w1
        let merged = GeminiCodeAssist.mergeSameProject([(g1, "p", .openCode), (g2, "p", .geminiCLI)])
        check(merged.count == 1 && merged.first?.title == "me@example.com",
              L("同一项目应合并且保留 Gemini CLI 那份", "The same project should merge and keep the Gemini CLI entry"))
        var bad = ServiceAccount(id: "gemini-cli", title: "x"); bad.error = L("查询配额失败：HTTP 500", "Quota request failed: HTTP 500")
        let ag = AntigravityService.mapFromGemini([g2, bad])
        check(ag.count == 2 && ag[0].id == "antigravity:gemini-cli" && ag[0].windows.count == 1,
              L("Antigravity 应原样复用 Gemini 的窗口", "Antigravity should reuse Gemini's windows as is"))
        check(ag[1].error == L("读不到共享的 Code Assist 配额：查询配额失败：HTTP 500", "Could not read the shared Code Assist quota: Quota request failed: HTTP 500"),
              L("Antigravity 出错文案错：\(ag[1].error ?? "nil")", "Wrong Antigravity error text: \(ag[1].error ?? "nil")"))

        return fails
    }
}
