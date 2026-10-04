// Claude：自管多账号、令牌刷新、切换

import AppKit
import CryptoKit
import Foundation
import SQLite3

// MARK: - Claude：自管多账号（仿 Orca）

let accountsRoot = NSHomeDirectory() + "/.config/usagemaster/claude"
let legacyAccountsRoot = NSHomeDirectory() + "/.config/usagebar/claude"   // 旧名 UsageBar 时期的目录，启动时自动迁移
let oauthClientId = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"   // Claude Code 的公开 OAuth client（Orca 刷新也用它）
let tokenURL = URL(string: "https://platform.claude.com/v1/oauth/token")!

/// 与 Claude Code 2.1.x 相同的命名：Claude Code-credentials-<sha256(配置目录, NFC) 前 8 位>
func keychainService(forConfigDir dir: String) -> String {
    let nfc = dir.precomposedStringWithCanonicalMapping
    let hex = SHA256.hash(data: Data(nfc.utf8)).map { String(format: "%02x", $0) }.joined()
    return "Claude Code-credentials-" + hex.prefix(8)
}

/// Claude Code 用 $USER 当钥匙串 account 字段
func keychainAccount() -> String {
    let u = ProcessInfo.processInfo.environment["USER"] ?? NSUserName()
    return u.range(of: #"^[a-zA-Z0-9._-]+$"#, options: .regularExpression) != nil ? u : "claude-code-user"
}

func readKeychainJSON(service: String) -> [String: Any]? {
    guard let data = runCommand("/usr/bin/security", ["find-generic-password", "-s", service, "-a", keychainAccount(), "-w"], timeout: 8),
          let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
    return obj
}

/// 经 `security -i` 从标准输入写回（-X 十六进制），令牌不出现在进程参数里——与 Claude Code 自己写钥匙串的方式一致
func writeKeychainJSON(service: String, _ obj: [String: Any]) -> Bool {
    guard let data = try? JSONSerialization.data(withJSONObject: obj) else { return false }
    let hex = data.map { String(format: "%02x", $0) }.joined()
    let cmd = "add-generic-password -U -a \"\(keychainAccount())\" -s \"\(service)\" -X \"\(hex)\"\n"
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/security")
    p.arguments = ["-i"]
    let input = Pipe()
    p.standardInput = input
    p.standardOutput = FileHandle.nullDevice
    p.standardError = FileHandle.nullDevice
    do { try p.run() } catch { return false }
    input.fileHandleForWriting.write(Data(cmd.utf8))
    try? input.fileHandleForWriting.close()      // 关闭标准输入即结束交互模式（security -i 没有 quit 命令，写了会让退出码变 1）
    let done = DispatchSemaphore(value: 0)
    DispatchQueue.global().async { p.waitUntilExit(); done.signal() }
    if done.wait(timeout: .now() + 8) == .timedOut { p.terminate(); return false }
    guard p.terminationStatus == 0, let back = readKeychainJSON(service: service) else { return false }
    return NSDictionary(dictionary: back).isEqual(to: obj)          // 回读一致才算成功
}

struct ManagedAccount {
    let dir: String
    let service: String
    var email: String?
    var org: String?
    var orgUuid: String?
    var oauthAccount: [String: Any]?
}

let defaultService = "Claude Code-credentials"          // 平时直接运行 `claude` 用的那份凭据
let defaultConfigPath = NSHomeDirectory() + "/.claude.json"

func readJSONFile(_ path: String) -> [String: Any]? {
    guard let d = try? Data(contentsOf: URL(fileURLWithPath: path)) else { return nil }
    return try? JSONSerialization.jsonObject(with: d) as? [String: Any]
}

/// 平时 `claude` 当前登录的是哪个账号（读 ~/.claude.json 的 oauthAccount，不含令牌）
func currentDefaultIdentity() -> (email: String, orgUuid: String)? {
    guard let oa = readJSONFile(defaultConfigPath)?["oauthAccount"] as? [String: Any],
          let email = oa["emailAddress"] as? String else { return nil }
    return (email.lowercased(), (oa["organizationUuid"] as? String) ?? "")
}

func identityKey(_ a: ManagedAccount) -> String? {
    guard let e = a.email else { return nil }
    return e.lowercased() + "|" + (a.orgUuid ?? "")
}

/// 从旧名 UsageBar 的目录迁移：凭据从旧钥匙串条目复制到新条目（条目名由目录路径哈希决定），再搬目录、删旧条目
func migrateLegacyAccounts() {
    let fm = FileManager.default
    guard let names = try? fm.contentsOfDirectory(atPath: legacyAccountsRoot) else { return }
    try? fm.createDirectory(atPath: accountsRoot, withIntermediateDirectories: true)
    for name in names where !name.hasPrefix(".") {
        let oldDir = legacyAccountsRoot + "/" + name, newDir = accountsRoot + "/" + name
        guard !fm.fileExists(atPath: newDir) else { continue }
        let oldSvc = keychainService(forConfigDir: oldDir), newSvc = keychainService(forConfigDir: newDir)
        if let creds = readKeychainJSON(service: oldSvc) {
            guard writeKeychainJSON(service: newSvc, creds) else { continue }   // 写不进新条目就先不搬
        }
        do { try fm.moveItem(atPath: oldDir, toPath: newDir) } catch { continue }
        _ = runCommand("/usr/bin/security", ["delete-generic-password", "-s", oldSvc, "-a", keychainAccount()], timeout: 8)
    }
    if (try? fm.contentsOfDirectory(atPath: legacyAccountsRoot))?.isEmpty == true {
        try? fm.removeItem(atPath: legacyAccountsRoot)
        try? fm.removeItem(atPath: (legacyAccountsRoot as NSString).deletingLastPathComponent)
    }
}

/// 删除一个账号目录及其钥匙串凭据（只用于 UsageMaster 自己建的目录）
func removeManagedAccount(_ a: ManagedAccount) {
    _ = runCommand("/usr/bin/security", ["delete-generic-password", "-s", a.service, "-a", keychainAccount()], timeout: 8)
    try? FileManager.default.removeItem(atPath: a.dir)
}

/// 列出已加的账号；同一个账号（邮箱 + 组织）加了多次时，只保留最早那份，其余自动删除
var removedDuplicates: [String] = []
func listManagedAccounts() -> [ManagedAccount] {
    let fm = FileManager.default
    guard let names = try? fm.contentsOfDirectory(atPath: accountsRoot) else { return [] }
    var seen = Set<String>()
    var out: [ManagedAccount] = []
    for name in names.sorted() {
        let dir = accountsRoot + "/" + name
        var isDir: ObjCBool = false
        guard !name.hasPrefix("."), fm.fileExists(atPath: dir, isDirectory: &isDir), isDir.boolValue else { continue }
        var a = ManagedAccount(dir: dir, service: keychainService(forConfigDir: dir))
        // 登录后 Claude Code 会在配置目录里写 .claude.json，含 oauthAccount（邮箱、组织，不含令牌）
        if let oa = readJSONFile(dir + "/.claude.json")?["oauthAccount"] as? [String: Any] {
            a.email = oa["emailAddress"] as? String
            a.org = oa["organizationName"] as? String
            a.orgUuid = oa["organizationUuid"] as? String
            a.oauthAccount = oa
        }
        if let key = identityKey(a) {
            if seen.contains(key) {
                removeManagedAccount(a)
                removedDuplicates.append(a.email ?? name)
                continue
            }
            seen.insert(key)
        } else if readKeychainJSON(service: a.service) == nil,
                  let attrs = try? fm.attributesOfItem(atPath: dir), let created = attrs[.creationDate] as? Date,
                  Date().timeIntervalSince(created) > 1800 {
            // 半小时还没登录成功的空目录：清掉
            try? fm.removeItem(atPath: dir)
            continue
        }
        out.append(a)
    }
    return out
}

/// 切换：让平时运行的 `claude` 改用账号 X（与 Orca 的切换同一思路）
/// 1) 先把默认凭据（可能已被 Claude Code 刷新过）存回当前在用账号的目录，避免轮换后的令牌丢失；
/// 2) 把 X 的凭据写进默认钥匙串条目；3) 把 ~/.claude.json 的 oauthAccount 换成 X 的。
/// 在用的那个账号由 Claude Code 自己刷新令牌，UsageMaster 不再去刷新它那份。
func switchDefault(to x: ManagedAccount, all: [ManagedAccount]) -> String? {
    if let cur = currentDefaultIdentity(),
       let curAcc = all.first(where: { identityKey($0) == cur.email + "|" + cur.orgUuid }),
       let curCreds = readKeychainJSON(service: defaultService) {
        _ = writeKeychainJSON(service: curAcc.service, curCreds)
    }
    guard let creds = readKeychainJSON(service: x.service) else { return "这个账号还没登录完成" }
    guard writeKeychainJSON(service: defaultService, creds) else { return "写入默认凭据失败" }
    guard var cfg = readJSONFile(defaultConfigPath), let oa = x.oauthAccount else { return "读不到 ~/.claude.json" }
    cfg["oauthAccount"] = oa
    guard let data = try? JSONSerialization.data(withJSONObject: cfg, options: [.prettyPrinted]) else { return "写 ~/.claude.json 失败" }
    do {
        try data.write(to: URL(fileURLWithPath: defaultConfigPath), options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: defaultConfigPath)
    } catch { return "写 ~/.claude.json 失败" }
    return nil
}

/// 同一账号的刷新串行进行，避免两次刷新互相把对方的 refresh token 作废
/// 真正的异步互斥锁：actor 方法在 await 处可被重入，单纯 `await body()` 串不住，所以用排队的 continuation
actor AsyncLock {
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func lock() async {
        if !busy { busy = true; return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func unlock() {
        if waiters.isEmpty { busy = false } else { waiters.removeFirst().resume() }
    }
}

enum RefreshGate {
    static let lock = AsyncLock()
    static func run<T>(_ body: () async -> T) async -> T {
        await lock.lock()
        let r = await body()
        await lock.unlock()
        return r
    }
}

enum TokenResult { case ok(String), needLogin(String), err(String) }

/// 取可用的 accessToken；距到期不足 5 分钟（或 force）时先刷新并写回钥匙串
func accessToken(for a: ManagedAccount, force: Bool = false) async -> TokenResult {
    await RefreshGate.run {
        guard var root = readKeychainJSON(service: a.service), var oauth = root["claudeAiOauth"] as? [String: Any] else {
            return .needLogin("还没登录：菜单里点「重新登录」")
        }
        let exp = num(oauth["expiresAt"]) ?? 0
        let fresh = exp / 1000 > Date().timeIntervalSince1970 + 300
        if fresh && !force, let tok = oauth["accessToken"] as? String { return .ok(tok) }
        guard let rt = oauth["refreshToken"] as? String, !rt.isEmpty else { return .needLogin("没有 refresh token：需要重新登录") }
        var req = URLRequest(url: tokenURL, timeoutInterval: 10)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var comps = URLComponents()
        comps.queryItems = [URLQueryItem(name: "grant_type", value: "refresh_token"),
                            URLQueryItem(name: "refresh_token", value: rt),
                            URLQueryItem(name: "client_id", value: oauthClientId)]
        req.httpBody = Data((comps.percentEncodedQuery ?? "").utf8)
        do {
            let (body, resp) = try await session.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            if code == 400 || code == 401 { return .needLogin("登录已失效（刷新被拒 \(code)）：需要重新登录") }
            guard code == 200, let j = try JSONSerialization.jsonObject(with: body) as? [String: Any],
                  let at = j["access_token"] as? String, !at.isEmpty else { return .err("刷新令牌失败：HTTP \(code)") }
            oauth["accessToken"] = at
            if let rt2 = j["refresh_token"] as? String, !rt2.isEmpty { oauth["refreshToken"] = rt2 }
            if let ei = num(j["expires_in"]) { oauth["expiresAt"] = (Date().timeIntervalSince1970 + ei) * 1000 }
            if let sc = j["scope"] as? String, !sc.isEmpty { oauth["scopes"] = sc.split(separator: " ").map(String.init) }
            root["claudeAiOauth"] = oauth
            // 写回失败也先用新令牌（下次会因旧 refresh token 失效而提示重新登录）
            if !writeKeychainJSON(service: a.service, root) { return .ok(at) }
            return .ok(at)
        } catch {
            return .err("刷新令牌失败：\(describe(error))")
        }
    }
}

func usageRequest(token: String) -> URLRequest {
    var req = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!, timeoutInterval: 10)
    req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
    req.setValue("AIUsageMaster/1.0", forHTTPHeaderField: "User-Agent")
    return req
}

/// 用量返回里的常规字段；其余字段一旦非空，视为"官方新给的额度项"（活动、临时额度、重置额度等）
let regularUsageKeys: Set<String> = ["five_hour", "seven_day", "seven_day_oauth_apps", "seven_day_opus", "seven_day_sonnet",
    "seven_day_cowork", "extra_usage", "limits", "spend", "member_dashboard_available", "seven_day_breakdown"]
func extraUsageKeys(_ d: [String: Any]) -> [String] {
    d.filter { !regularUsageKeys.contains($0.key) && !($0.value is NSNull) }.map { $0.key }.sorted()
}

/// 解析 /api/oauth/usage：优先 limits[]（与 /usage 同口径），否则旧字段 five_hour / seven_day
func parseUsage(_ d: [String: Any], now: Date) -> [UsageWindow] {
    var out: [UsageWindow] = []
    if let limits = d["limits"] as? [[String: Any]] {
        for l in limits {
            guard let pct = num(l["percent"]) else { continue }
            let kind = l["kind"] as? String ?? ""
            var label: String
            switch kind {
            case "session": label = "5 小时窗口"
            case "weekly_all": label = "每周（全部模型）"
            case "weekly_scoped":
                let scope = l["scope"] as? [String: Any]
                let name = ((scope?["model"] as? [String: Any])?["display_name"] as? String)
                    ?? ((scope?["surface"] as? [String: Any])?["display_name"] as? String)
                label = "每周（\(name ?? "指定范围")）"
            default: label = kind
            }
            out.append(makeWindow(label, percent: pct, resetsAt: parseISO(l["resets_at"]), now: now))
        }
        return out
    }
    for (key, label) in [("five_hour", "5 小时窗口"), ("seven_day", "每周（全部模型）")] {
        if let w = d[key] as? [String: Any], let pct = num(w["utilization"]) {
            out.append(makeWindow(label, percent: pct, resetsAt: parseISO(w["resets_at"]), now: now))
        }
    }
    return out
}

func cacheKey(_ a: ManagedAccount) -> String { identityKey(a) ?? a.dir }

/// 默认凭据（平时 `claude` 用的那份）的 accessToken；不刷新，过期就返回 nil
func defaultAccessToken() -> String? {
    guard let obj = readKeychainJSON(service: "Claude Code-credentials"),
          let oauth = obj["claudeAiOauth"] as? [String: Any],
          let token = oauth["accessToken"] as? String else { return nil }
    if let exp = num(oauth["expiresAt"]), exp / 1000 < Date().timeIntervalSince1970 + 30 { return nil }
    return token
}

/// 查一个托管账号：先看缓存节奏与限流退避，必要时才发请求；失败时保留上次的数字并标注原因
func fetchManaged(_ a: ManagedAccount, isDefault: Bool, force: Bool = false) async -> ClaudeAccount {
    let email = a.email ?? (a.dir as NSString).lastPathComponent
    var acc = ClaudeAccount(label: accountLabel(dir: a.dir, email: email), email: email, org: a.org ?? "", active: isDefault,
                            source: "直连", configDir: a.dir)
    let key = cacheKey(a)
    let cache = UsageCache.shared
    func fromCache(_ note: String?) {
        acc.windows = cache.windows(key)
        acc.extraKeys = cache.get(key)?.extraKeys ?? []
        acc.updatedAt = cache.get(key)?.fetchedAt
        acc.warning = note
        if acc.windows.isEmpty, let n = note { acc.error = n }        // 一点旧数据都没有时才算错误
    }
    if !cache.shouldFetch(key, active: isDefault, force: force) {
        let c = cache.get(key)
        fromCache(c?.retryAfter.flatMap { $0 > Date() ? "被限流，\(clockFmt.string(from: $0)) 后再查" : nil })
        return acc
    }
    cache.markAttempt(key)
    for attempt in 0..<2 {
        let token: String
        if isDefault {
            // 在用账号：令牌归 Claude Code 管，只读默认凭据，不刷新
            guard let t = defaultAccessToken() else { fromCache("在用账号的令牌已过期，等 Claude Code 自己刷新"); return acc }
            token = t
        } else {
            switch await accessToken(for: a, force: attempt == 1) {
            case .needLogin(let m): acc.error = m; acc.needsLogin = true; return acc
            case .err(let m): fromCache(m); return acc
            case .ok(let t): token = t
            }
        }
        switch await requestUsage(token: token) {
        case .ok(let d):
            let w = parseUsage(d, now: Date())
            if w.isEmpty { fromCache("返回格式变了，解析不出用量"); return acc }
            cache.storeSuccess(key, windows: w, extraKeys: extraUsageKeys(d))
            acc.windows = w
            acc.extraKeys = extraUsageKeys(d)
            acc.updatedAt = Date()
            return acc
        case .rateLimited(let ra):
            let until = cache.storeRateLimited(key, retryAfterHeader: ra)
            fromCache("被限流（429），\(clockFmt.string(from: until)) 后再查")
            return acc
        case .unauthorized:
            if !isDefault && attempt == 0 { continue }             // 令牌被提前作废：强制刷新再试一次
            if isDefault { fromCache("在用账号的令牌失效（401），等 Claude Code 自己刷新"); return acc }
            acc.error = "令牌无效（401）：需要重新登录"; acc.needsLogin = true
            return acc
        case .http(let code):
            fromCache("查询用量失败：HTTP \(code)")
            return acc
        case .failure(let m):
            fromCache(m)
            return acc
        }
    }
    return acc
}

/// 一个账号都没加时的兜底：只读 Claude Code 默认登录，不刷新（它的令牌归你平时用的 Claude Code 管）
func fetchClaudeDirect(force: Bool = false) async -> Fetch<ClaudeAccount> {
    let fake = ManagedAccount(dir: "default", service: "Claude Code-credentials")
    var acc = await fetchManaged(fake, isDefault: true, force: force)
    acc.label = "C"
    acc.email = "Claude Code 默认登录（只读）"
    acc.configDir = nil
    if let e = acc.error { return .err(e) }
    return .ok(acc)
}

/// 打开终端，用官方 `claude auth login` 登录到指定配置目录。
/// 授权页用 Chrome 无痕窗口打开（BROWSER 变量），这样浏览器里已登录的 claude.ai 账号不会挡住你登录别的账号。
func openLoginTerminal(configDir: String) {
    let claudeBin = [NSHomeDirectory() + "/.local/bin/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude"]
        .first { FileManager.default.isExecutableFile(atPath: $0) } ?? "claude"
    let tmp = NSTemporaryDirectory()
    let tag = String(UUID().uuidString.prefix(8))
    let browserPath = tmp + "usagemaster-incognito-\(tag).sh"
    let hasChrome = FileManager.default.fileExists(atPath: "/Applications/Google Chrome.app")
    let browser = hasChrome
        ? "#!/bin/bash\nopen -na 'Google Chrome' --args --incognito \"$1\"\n"
        : "#!/bin/bash\nopen -a Safari \"$1\"\n"
    let script = """
    #!/bin/bash
    export CLAUDE_CONFIG_DIR='\(configDir)'
    export BROWSER='\(browserPath)'
    mkdir -p "$CLAUDE_CONFIG_DIR"
    echo "AI UsageMaster：给菜单栏添加一个 Claude 账号"
    echo "授权页会在 \(hasChrome ? "Chrome 无痕窗口" : "Safari") 里打开：在那里用你要添加的账号（邮箱）登录，然后点授权。"
    echo "如果打开的是普通窗口、里面已经是别的账号：复制下面打印的链接，按 ⌘⇧N 开无痕窗口粘贴打开。"
    echo
    '\(claudeBin)' auth login --claudeai
    echo
    '\(claudeBin)' auth status --text
    echo
    echo "完成。菜单栏 1 分钟内会显示这个账号（或在菜单里点「立即刷新」）。可以关闭此窗口。"
    """
    let path = tmp + "usagemaster-login-\(tag).command"
    do {
        try browser.write(toFile: browserPath, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: browserPath)
        try script.write(toFile: path, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: path)
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    } catch {}
}

