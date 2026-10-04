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

struct ManagedAccount {
    let dir: String
    let cred: CredentialRef          // 这个账号自己的那份凭据（UsageMaster 刷新它，不碰默认那份）
    var email: String?
    var org: String?
    var orgUuid: String?
    var oauthAccount: [String: Any]?
}

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
        let oldCred = CredentialRef.claude(configDir: oldDir), newCred = CredentialRef.claude(configDir: newDir)
        #if os(macOS)   // Windows 上凭据就在目录里，随目录一起搬
        if let creds = readCredential(oldCred) {
            guard writeCredential(newCred, creds) else { continue }   // 写不进新条目就先不搬
        }
        #endif
        do { try fm.moveItem(atPath: oldDir, toPath: newDir) } catch { continue }
        #if os(macOS)
        deleteCredential(oldCred)
        #endif
    }
    if (try? fm.contentsOfDirectory(atPath: legacyAccountsRoot))?.isEmpty == true {
        try? fm.removeItem(atPath: legacyAccountsRoot)
        try? fm.removeItem(atPath: (legacyAccountsRoot as NSString).deletingLastPathComponent)
    }
}

/// 删除一个账号目录及其凭据（只用于 UsageMaster 自己建的目录）
func removeManagedAccount(_ a: ManagedAccount) {
    deleteCredential(a.cred)
    try? FileManager.default.removeItem(atPath: a.dir)
}

/// 同一账号的两份凭据里哪份更新：有刷新令牌的优先，其次到期时间更晚的（通常就是刚登录的那份）
private func credentialRank(_ a: ManagedAccount) -> (Int, Double) {
    guard let c = readCredential(a.cred)?["claudeAiOauth"] as? [String: Any] else { return (0, 0) }
    let hasRT = ((c["refreshToken"] as? String)?.isEmpty == false) ? 1 : 0
    return (hasRT, num(c["expiresAt"]) ?? 0)
}

/// 列出已加的账号；同一个账号（邮箱 + 组织）加了多次时只留一份：留凭据更新的那份（不一定是最早的，
/// 重新添加往往正是因为旧的那份失效了），其余自动删除
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
        var a = ManagedAccount(dir: dir, cred: .claude(configDir: dir))
        // 登录后 Claude Code 会在配置目录里写 .claude.json，含 oauthAccount（邮箱、组织，不含令牌）
        if let oa = readJSONFile(dir + "/.claude.json")?["oauthAccount"] as? [String: Any] {
            a.email = oa["emailAddress"] as? String
            a.org = oa["organizationName"] as? String
            a.orgUuid = oa["organizationUuid"] as? String
            a.oauthAccount = oa
        }
        if let key = identityKey(a) {
            if seen.contains(key), let i = out.firstIndex(where: { identityKey($0) == key }) {
                let kept = out[i]
                if credentialRank(a) > credentialRank(kept) {
                    removeManagedAccount(kept)          // 新加的这份凭据更新：留它，删旧的
                    out[i] = a
                } else {
                    removeManagedAccount(a)
                }
                removedDuplicates.append(a.email ?? name)
                continue
            }
            seen.insert(key)
        } else if readCredential(a.cred) == nil,
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

/// 和 Claude Code 写凭据用同一把锁：它用 proper-lockfile 锁 <配置目录>/.storage-write，实际是建目录 .storage-write.lock，
/// 超过 15 秒没更新就算失效。拿不到锁返回 nil
func withClaudeStorageLock<T>(dir: String, _ body: () -> T) -> T? {
    let lock = dir + "/.storage-write.lock"
    let fm = FileManager.default
    try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
    var got = false
    for _ in 0..<25 {
        if (try? fm.createDirectory(atPath: lock, withIntermediateDirectories: false)) != nil { got = true; break }
        if let m = (try? fm.attributesOfItem(atPath: lock))?[.modificationDate] as? Date, Date().timeIntervalSince(m) > 15 {
            try? fm.removeItem(atPath: lock); continue
        }
        Thread.sleep(forTimeInterval: 0.2)
    }
    guard got else { return nil }
    defer { try? fm.removeItem(atPath: lock) }
    return body()
}

/// 切换时用到的位置（自检里换成临时的，不碰真实登录）
struct SwitchTargets {
    var defaultCred = CredentialRef.claudeDefault
    var configPath = NSHomeDirectory() + "/.claude.json"
    var claudeDir = NSHomeDirectory() + "/.claude"
    var orcaAccountsDir = orcaClaudeAccountsDir     // Windows 判断「默认登录是不是 Orca 放的」用
    var nudge = true
}

/// 切换：让平时运行的 `claude` 改用账号 X（与 Orca 的切换同一思路）。
/// 先做完所有只读检查，再在 Claude Code 的写凭据锁里改：
/// 1) 默认凭据里的 claudeAiOauth（可能已被 Claude Code 刷新过）存回当前在用账号自己的条目；
/// 2) 默认凭据只换 claudeAiOauth，mcpOAuth 等其它内容原样保留；3) ~/.claude.json 的 oauthAccount 换成 X 的。
/// 任何一步失败都恢复原样并返回原因。在用账号的令牌由 Claude Code 自己刷新，UsageMaster 不刷新它那份。
func switchDefault(to x: ManagedAccount, all: [ManagedAccount], targets: SwitchTargets = SwitchTargets()) -> String? {
    // 只读检查
    guard case .ok(let xItem) = readCredentialStrict(x.cred), let xc = xItem["claudeAiOauth"] as? [String: Any],
          let rt = xc["refreshToken"] as? String, !rt.isEmpty else {
        return L("这个账号还没登录完成或需要重新登录，没有切换", "This account is not signed in (or needs to sign in again); nothing was switched")
    }
    guard let oa = x.oauthAccount else {
        return L("这个账号的账号信息不全，请重新登录它，没有切换", "This account's profile is incomplete; sign in to it again. Nothing was switched")
    }
    guard readJSONFile(targets.configPath) != nil else {
        return L("读不到 ~/.claude.json，没有切换", "Could not read ~/.claude.json; nothing was switched")
    }
    let result: String?? = withClaudeStorageLock(dir: targets.claudeDir) { () -> String? in
        let d: [String: Any]
        switch readCredentialStrict(targets.defaultCred) {
        case .missing: d = [:]
        case .unreadable: return L("读不出默认凭据，没有切换", "Could not read the default credentials; nothing was switched")
        case .ok(let o): d = o
        }
        // 1) 当前账号：只存回 claudeAiOauth。
        //    例外：默认登录是 Orca 放进去的（它会把同一份写进 <配置目录>/.credentials.json，Claude Code 在 Mac 上不写这个文件）。
        //    那是 Orca 自己的授权，存一份到我们这里会变成两边共用一个刷新令牌，谁先刷新另一边就作废，所以不存，原样留给 Orca。
        var restoreCur: (cred: CredentialRef, item: CredentialRead)?
        let orcaPlaced = defaultPlacedByOrca(d, credentialsFile: targets.claudeDir + "/.credentials.json", orcaAccountsDir: targets.orcaAccountsDir)
        if !orcaPlaced, let oaCur = readJSONFile(targets.configPath)?["oauthAccount"] as? [String: Any],
           let email = (oaCur["emailAddress"] as? String)?.lowercased(),
           let cur = all.first(where: { identityKey($0) == email + "|" + ((oaCur["organizationUuid"] as? String) ?? "") }),
           cur.dir != x.dir, let dc = d["claudeAiOauth"] as? [String: Any] {
            let before = readCredentialStrict(cur.cred)
            if case .unreadable = before { return L("读不出当前账号自己的凭据，没有切换", "Could not read the current account's own credentials; nothing was switched") }
            var m: [String: Any] = [:]
            if case .ok(let o) = before { m = o }
            m["claudeAiOauth"] = dc
            guard writeCredential(cur.cred, m) else {
                if case .ok(let o) = before { _ = writeCredential(cur.cred, o) }
                return L("保存当前账号的凭据失败，没有切换", "Could not save the current account's credentials; nothing was switched")
            }
            restoreCur = (cur.cred, before)
        }
        func undo() {
            if !d.isEmpty { _ = writeCredential(targets.defaultCred, d) }
            if let r = restoreCur, case .ok(let o) = r.item { _ = writeCredential(r.cred, o) }
        }
        // 2) 默认凭据：只换 claudeAiOauth
        var nd = d
        nd["claudeAiOauth"] = xc
        guard writeCredential(targets.defaultCred, nd) else {
            undo()
            return L("写入默认凭据失败，已恢复原样", "Could not write the default credentials; everything was restored")
        }
        // 3) ~/.claude.json：写之前重读一次，尽量不覆盖 Claude Code 刚写的内容
        let failed = L("写 ~/.claude.json 失败，已恢复原来的登录", "Could not write ~/.claude.json; the previous sign-in was restored")
        guard var cfg = readJSONFile(targets.configPath) else { undo(); return failed }
        cfg["oauthAccount"] = oa
        guard let data = try? JSONSerialization.data(withJSONObject: cfg, options: [.prettyPrinted]),
              (try? data.write(to: URL(fileURLWithPath: targets.configPath), options: .atomic)) != nil else { undo(); return failed }
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: targets.configPath)
        return nil
    }
    guard let r = result else {
        return L("Claude Code 正在写登录信息，稍后再试", "Claude Code is writing its sign-in data; try again in a moment")
    }
    if r == nil && targets.nudge { nudgeRunningSessions() }
    return r
}

/// 默认登录是不是 Orca 放进去的。
/// macOS：明文副本 ~/.claude/.credentials.json 里的刷新令牌和默认钥匙串里的一样（Claude Code 在 Mac 上不写这个文件，Orca 写）。
/// Windows：那个文件本身就是默认登录，拿它和自己比永远相同，所以改为和 Orca 每个账号目录里的那份比。
func defaultPlacedByOrca(_ d: [String: Any], credentialsFile: String, orcaAccountsDir: String = orcaClaudeAccountsDir) -> Bool {
    guard let rt = (d["claudeAiOauth"] as? [String: Any])?["refreshToken"] as? String, !rt.isEmpty else { return false }
    #if os(Windows)
    let ids = (try? FileManager.default.contentsOfDirectory(atPath: orcaAccountsDir)) ?? []
    return ids.contains { id in
        (readJSONFile(orcaAccountsDir + "/" + id + "/auth/.credentials.json")?["claudeAiOauth"] as? [String: Any])?["refreshToken"] as? String == rt
    }
    #else
    guard let f = (readJSONFile(credentialsFile)?["claudeAiOauth"] as? [String: Any])?["refreshToken"] as? String else { return false }
    return f == rt
    #endif
}

/// Orca 管着的 Claude 账号：选中的是谁、每个邮箱对应的 Orca 账号 id。没装 Orca 或它没在运行时返回 nil。只读，不含令牌。
/// Orca 每次查用量、每次开 Claude 会话前都会把选中的账号重新写进 Claude Code 的默认登录（源码 prepareForRateLimitFetch /
/// prepareForClaudeLaunch → doSyncForCurrentSelection），所以它选了账号时，这里切过去也会被它改回去
struct OrcaClaudeState { var active: String?; var ids: [String: String] }
func orcaClaudeState() -> OrcaClaudeState? {
    #if os(Windows)
    let candidates = [(ProcessInfo.processInfo.environment["LOCALAPPDATA"] ?? "") + "/Programs/orca/resources/bin/orca.exe"]
    #else
    let candidates = ["/opt/homebrew/bin/orca", "/usr/local/bin/orca", "/Applications/Orca.app/Contents/Resources/bin/orca"]
    #endif
    let bin = candidates
        .first { FileManager.default.isExecutableFile(atPath: $0) }
    guard let b = bin, let data = runCommand(b, ["account", "list", "--json"], timeout: 5),
          let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
    let r = (j["result"] as? [String: Any]) ?? j
    guard let c = r["claude"] as? [String: Any], let accts = c["accounts"] as? [[String: Any]] else { return nil }
    var ids: [String: String] = [:]
    for a in accts { if let e = (a["email"] as? String)?.lowercased(), let id = a["id"] as? String { ids[e] = id } }
    let act = c["activeAccountId"] as? String
    return OrcaClaudeState(active: (accts.first { $0["id"] as? String == act }?["email"] as? String)?.lowercased(), ids: ids)
}
func orcaActiveClaudeEmail() -> String? { orcaClaudeState()?.active }

/// 这个账号我们手里的刷新令牌和 Orca 那份是不是同一个。同一个就绝不能在这里刷新：刷新会让 Orca 那份作废、把它挤下线。
/// 只在内存里比较，不保存、不输出 Orca 的任何内容
func sharesRefreshTokenWithOrca(email: String?, refreshToken: String, state: OrcaClaudeState?,
                                orcaCred: (String) -> CredentialRef = CredentialRef.orca(id:)) -> Bool {
    guard let e = email?.lowercased(), let id = state?.ids[e],
          let theirs = (readCredential(orcaCred(id))?["claudeAiOauth"] as? [String: Any])?["refreshToken"] as? String else { return false }
    return theirs == refreshToken
}

let sharedWithOrcaMessage = L("这个账号和 Orca 用的是同一份登录：在这里刷新会把 Orca 那边挤下线，所以这里不刷新。请在菜单里点「重新登录」，两边各用各的",
                              "This account shares its sign-in with Orca; refreshing it here would sign Orca out, so it is not refreshed here. Choose Sign In Again in the menu to give each app its own sign-in")

/// 异步版：先让目标账号的令牌可用（快到期就刷新），再在刷新锁里切换，不和本程序自己的令牌刷新交叠
func switchDefaultSafely(to x: ManagedAccount, all: [ManagedAccount]) async -> String? {
    if case .needLogin(let m) = await accessToken(for: x) { return m }
    return await RefreshGate.run {
        await Task.detached { switchDefault(to: x, all: all) }.value
    }
}

/// 让已经开着的 Claude Code 会话尽快换到新账号。
/// Claude Code（2.1.288 实测）每次请求前检查凭据有没有变：~/.claude/.credentials.json 存在时只看它的修改时间，
/// 不存在时才重读钥匙串（钥匙串读取缓存 30 秒）。这个文件是钥匙串写入失败时留下的备用副本，
/// 它在的话只改钥匙串，开着的会话察觉不到。所以文件存在时更新一下修改时间（不改内容，也不新建）。
/// Windows 上这个文件就是默认凭据本身，切换时已经整份替换过，这里再更新一次修改时间也无妨。
func nudgeRunningSessions() {
    let path = NSHomeDirectory() + "/.claude/.credentials.json"      // 切换改的是默认那份凭据，对应默认配置目录
    guard FileManager.default.fileExists(atPath: path) else { return }
    try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: path)
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

/// 取可用的 accessToken；距到期不足 5 分钟（或 force）时先刷新并写回这个账号自己的凭据
func accessToken(for a: ManagedAccount, force: Bool = false) async -> TokenResult {
    await RefreshGate.run {
        guard var root = readCredential(a.cred), var oauth = root["claudeAiOauth"] as? [String: Any] else {
            return .needLogin(L("还没登录：菜单里点「重新登录」", "Not signed in: choose Sign In Again in the menu"))
        }
        let exp = num(oauth["expiresAt"]) ?? 0
        let fresh = exp / 1000 > Date().timeIntervalSince1970 + 300
        if fresh && !force, let tok = oauth["accessToken"] as? String { return .ok(tok) }
        guard let rt = oauth["refreshToken"] as? String, !rt.isEmpty else { return .needLogin(L("没有 refresh token：需要重新登录", "No refresh token: sign in again")) }
        if sharesRefreshTokenWithOrca(email: a.email, refreshToken: rt, state: orcaClaudeState()) { return .needLogin(sharedWithOrcaMessage) }
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
            if code == 400 || code == 401 { return .needLogin(L("登录已失效（刷新被拒 \(code)）：需要重新登录", "Sign-in expired (refresh rejected, \(code)): sign in again")) }
            guard code == 200, let j = try JSONSerialization.jsonObject(with: body) as? [String: Any],
                  let at = j["access_token"] as? String, !at.isEmpty else { return .err(L("刷新令牌失败：HTTP \(code)", "Token refresh failed: HTTP \(code)")) }
            oauth["accessToken"] = at
            if let rt2 = j["refresh_token"] as? String, !rt2.isEmpty { oauth["refreshToken"] = rt2 }
            if let ei = num(j["expires_in"]) { oauth["expiresAt"] = (Date().timeIntervalSince1970 + ei) * 1000 }
            if let sc = j["scope"] as? String, !sc.isEmpty { oauth["scopes"] = sc.split(separator: " ").map(String.init) }
            root["claudeAiOauth"] = oauth
            // 写回失败也先用新令牌（下次会因旧 refresh token 失效而提示重新登录）
            if !writeCredential(a.cred, root) { return .ok(at) }
            return .ok(at)
        } catch {
            return .err(L("刷新令牌失败：\(describe(error))", "Token refresh failed: \(describe(error))"))
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
    "seven_day_cowork", "extra_usage", "limits", "spend", "member_dashboard_available", "seven_day_breakdown",
    "seven_day_omelette", "cinder_cove", "cedar_ember", "juniper_tide"]
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
            let scope = l["scope"] as? [String: Any]
            let name = ((scope?["model"] as? [String: Any])?["display_name"] as? String)
                ?? ((scope?["surface"] as? [String: Any])?["display_name"] as? String)
            out.append(makeWindow(windowLabel(kind: kind, scope: name), percent: pct, resetsAt: parseISO(l["resets_at"]), now: now,
                                  kind: kind, severity: l["severity"] as? String, isActive: (l["is_active"] as? Bool) ?? false, scope: name))
        }
        return out
    }
    for (key, kind) in [("five_hour", "session"), ("seven_day", "weekly_all")] {
        if let w = d[key] as? [String: Any], let pct = num(w["utilization"]) {
            out.append(makeWindow(windowLabel(kind: kind), percent: pct, resetsAt: parseISO(w["resets_at"]), now: now, kind: kind))
        }
    }
    return out
}

/// 额外信息（只读展示）：超额用量 / usage credits、官方给的可用重置次数
func usageNotes(_ d: [String: Any]) -> [String] {
    var out: [String] = []
    if let e = d["extra_usage"] as? [String: Any] {
        let cur = ((e["currency"] as? String) ?? "USD").uppercased()
        let exp = Double((e["decimal_places"] as? Int) ?? (["JPY", "KRW", "VND"].contains(cur) ? 0 : 2))
        func money(_ v: Any?) -> String? {
            guard let x = num(v) else { return nil }
            let amt = x / pow(10, exp)
            return cur == "USD" ? String(format: "$%.2f", amt) : String(format: "%.2f %@", amt, cur)
        }
        if (e["is_enabled"] as? Bool) == false {
            let reasons = ["org_level_disabled": L("组织没开", "turned off for the organization"),
                           "user_disabled": L("你自己关了", "turned off by you"),
                           "spend_limit_reached": L("已到花费上限", "spend limit reached")]
            let r = (e["disabled_reason"] as? String).map { reasons[$0] ?? $0 }
            out.append(L("超额用量：未开启", "Extra usage: off") + (r.map { L("（\($0)）", " (\($0))") } ?? ""))
        } else if e["is_enabled"] as? Bool == true {
            let used = money(e["used_credits"]) ?? "$0.00"
            if let lim = num(e["monthly_limit"]), lim > 0, let ls = money(lim) { out.append(L("超额用量：已用 \(used) / 上限 \(ls)（每月 1 号重置）", "Extra usage: \(used) of \(ls) used (resets on the 1st)")) }
            else if e["monthly_limit"] is NSNull || e["monthly_limit"] == nil { out.append(L("超额用量：已开启，无上限，本月已用 \(used)", "Extra usage: on, no limit, \(used) used this month")) }
        }
    }
    for key in ["cedar_ember", "juniper_tide"] {
        guard let c = d[key] as? [String: Any] else { continue }
        let grants = c["grants"] as? [[String: Any]] ?? []
        let left = grants.compactMap { num($0["resets_left"]) }.reduce(0, +)
        if left > 0 { out.append(L("官方给的可用重置次数：\(Int(left))（只显示，不会自动领取）", "Usage resets granted: \(Int(left)) (shown only, never redeemed automatically)")) }
    }
    return out
}

/// 套餐名：从账号信息（不含令牌）推断
func planName(_ oa: [String: Any]?) -> String? {
    guard let oa = oa else { return nil }
    let tier = ((oa["userRateLimitTier"] as? String) ?? (oa["organizationRateLimitTier"] as? String) ?? "").lowercased()
    let org = ((oa["organizationType"] as? String) ?? "").lowercased()
    if tier.contains("max_20x") { return org.contains("team") ? L("Team（Max 20x 档）", "Team (Max 20x tier)") : "Max 20x" }
    if tier.contains("max_5x") { return org.contains("team") ? L("Team（Max 5x 档）", "Team (Max 5x tier)") : "Max 5x" }
    if org.contains("team") { return "Team" }
    if org.contains("enterprise") { return "Enterprise" }
    if org.contains("pro") { return "Pro" }
    return nil
}

func cacheKey(_ a: ManagedAccount) -> String { identityKey(a) ?? a.dir }

/// 默认凭据（平时 `claude` 用的那份）的 accessToken；不刷新，过期就返回 nil
func defaultAccessToken() -> String? {
    guard let obj = readCredential(.claudeDefault),
          let oauth = obj["claudeAiOauth"] as? [String: Any],
          let token = oauth["accessToken"] as? String else { return nil }
    if let exp = num(oauth["expiresAt"]), exp / 1000 < Date().timeIntervalSince1970 + 30 { return nil }
    return token
}

/// 查一个托管账号，再叠上 Claude Code 状态栏刚给的实时数字（只有 5 小时与每周两项，且必须比查到的数据新）。
/// liveSnapshot 由 fetchAll 用完整账号列表匹配后传进来，只有匹配唯一的那个账号会拿到
func fetchManaged(_ a: ManagedAccount, isDefault: Bool, force: Bool = false, liveSnapshot: StatusLineSnapshot? = nil) async -> ClaudeAccount {
    var acc = await fetchManagedCore(a, isDefault: isDefault, force: force)
    if let s = liveSnapshot, !acc.needsLogin, s.ts > (acc.updatedAt ?? .distantPast) {
        let live = windowsFromStatusLine(s)
        if !live.isEmpty {
            acc.windows = live + acc.windows.filter { !isSessionWindow($0) && !isWeeklyAllWindow($0) }
            acc.updatedAt = s.ts
            acc.source = "statusline"
            acc.warning = nil
            acc.error = nil
        }
    }
    return acc
}

/// 查一个托管账号：先看缓存节奏与限流退避，必要时才发请求；失败时保留上次的数字并标注原因
func fetchManagedCore(_ a: ManagedAccount, isDefault: Bool, force: Bool = false) async -> ClaudeAccount {
    let email = a.email ?? (a.dir as NSString).lastPathComponent
    var acc = ClaudeAccount(label: accountLabel(dir: a.dir, email: email), email: email, org: a.org ?? "", active: isDefault,
                            source: "direct", configDir: a.dir)
    acc.plan = planName(a.oauthAccount)
    acc.key = cacheKey(a)
    let key = cacheKey(a)
    let cache = UsageCache.shared
    func fromCache(_ note: String?) {
        acc.windows = cache.windows(key)
        acc.extraKeys = cache.get(key)?.extraKeys ?? []
        acc.notes = cache.get(key)?.notes ?? []
        acc.updatedAt = cache.get(key)?.fetchedAt
        acc.warning = note
        if acc.windows.isEmpty, let n = note { acc.error = n }        // 一点旧数据都没有时才算错误
    }
    if !cache.shouldFetch(key, active: isDefault, force: force) {
        let c = cache.get(key)
        if let f = c?.failure {                                     // 上次是硬失败：照样报出来，别拿旧数字当能用
            fromCache(nil)
            acc.error = f
            acc.needsLogin = c?.needsLogin ?? false
            return acc
        }
        fromCache(c?.retryAfter.flatMap { $0 > Date() ? L("被限流，\(clockFmt.string(from: $0)) 后再查", "Rate limited, next check after \(clockFmt.string(from: $0))") : nil })
        return acc
    }
    cache.markAttempt(key)
    for attempt in 0..<2 {
        let token: String
        if isDefault {
            // 在用账号：令牌归 Claude Code 管，只读默认凭据，不刷新
            guard let t = defaultAccessToken() else { fromCache(L("在用账号的令牌已过期，等 Claude Code 自己刷新", "The active account's token has expired; waiting for Claude Code to refresh it")); return acc }
            token = t
        } else {
            switch await accessToken(for: a, force: attempt == 1) {
            case .needLogin(let m): acc.error = m; acc.needsLogin = true; cache.storeFailure(key, m, needsLogin: true); return acc
            case .err(let m): fromCache(m); return acc
            case .ok(let t): token = t
            }
        }
        switch await requestUsage(token: token) {
        case .ok(let d):
            let w = parseUsage(d, now: Date())
            if w.isEmpty { fromCache(L("返回格式变了，解析不出用量", "Unexpected response format, could not read usage")); return acc }
            cache.storeSuccess(key, windows: w, extraKeys: extraUsageKeys(d), notes: usageNotes(d))
            acc.windows = w
            acc.extraKeys = extraUsageKeys(d)
            acc.notes = usageNotes(d)
            acc.updatedAt = Date()
            return acc
        case .rateLimited(let ra):
            let until = cache.storeRateLimited(key, retryAfterHeader: ra)
            fromCache(L("被限流（429），\(clockFmt.string(from: until)) 后再查", "Rate limited (429), next check after \(clockFmt.string(from: until))"))
            return acc
        case .unauthorized:
            if !isDefault && attempt == 0 { continue }             // 令牌被提前作废：强制刷新再试一次
            if isDefault { fromCache(L("在用账号的令牌失效（401），等 Claude Code 自己刷新", "The active account's token was rejected (401); waiting for Claude Code to refresh it")); return acc }
            acc.error = L("令牌无效（401）：需要重新登录", "Token rejected (401): sign in again"); acc.needsLogin = true
            cache.storeFailure(key, acc.error ?? "", needsLogin: true)
            return acc
        case .http(let code):
            fromCache(L("查询用量失败：HTTP \(code)", "Usage request failed: HTTP \(code)"))
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
    let fake = ManagedAccount(dir: "default", cred: .claudeDefault)
    var acc = await fetchManaged(fake, isDefault: true, force: force)
    acc.label = "C"
    acc.email = L("Claude Code 默认登录（只读）", "Claude Code default sign-in (read-only)")
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
    echo "\(L("AI UsageMaster：给菜单栏添加一个 Claude 账号", "AI UsageMaster: add a Claude account to the menu bar"))"
    echo "\(L("授权页会在 \(hasChrome ? "Chrome 无痕窗口" : "Safari") 里打开：在那里用你要添加的账号（邮箱）登录，然后点授权。", "The authorization page opens in \(hasChrome ? "a Chrome incognito window" : "Safari"). Sign in there with the account you want to add, then approve."))"
    echo "\(L("如果打开的是普通窗口、里面已经是别的账号：复制下面打印的链接，按 ⌘⇧N 开无痕窗口粘贴打开。", "If it opened in a normal window that is already signed in to another account, copy the link printed below into a private window (⌘⇧N)."))"
    echo
    '\(claudeBin)' auth login --claudeai
    echo
    '\(claudeBin)' auth status --text
    echo
    echo "\(L("完成。菜单栏 1 分钟内会显示这个账号（或在菜单里点「立即刷新」）。可以关闭此窗口。", "Done. The account shows up in the menu bar within a minute (or choose Refresh Now in the menu). You can close this window."))"
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

