// OpenCode Go 与 MiniMax（Coding Plan）：订阅用量。协议参考自 Orca 1.4.219（MIT 许可，Copyright (c) 2026 Lovecast Inc.）
//
// 两家都只做 API key 路径。网页 cookie 路径不做：OpenCode Go 那条依赖 opencode.ai 构建期写死的 server-function 哈希，
// 对方一重新部署就失效；MiniMax 那条前面有 Akamai，要整串粘贴 cookie 还得伪装浏览器 UA，都太脆。
//
// OpenCode Go：GET https://opencode.ai/zen/go/v1/usage（Authorization: Bearer <API key>）
//   key 依次取（第一个命中的生效）：UsageMaster 钥匙串 "UsageMaster-opencode-go" → OpenCode CLI 的 auth.json 里
//   "opencode-go" 条目 → OpenCode 的 SQLite credential 表 → 环境变量 OPENCODE_API_KEY。OpenCode 的文件只读，绝不写回。
// MiniMax：GET <区域主机>/v1/api/openplatform/coding_plan/remains（Authorization: Bearer <API key>）
//   key 只存在 UsageMaster 钥匙串 "UsageMaster-minimax"：{"apiKey": "...", "region": "overseas"|"cn"}。
// 两家的 API key 都是长期静态的，没有刷新流程。key 只在内存与钥匙串里，不打印、不进错误信息。

import Foundation
import Security
import SQLite3

// MARK: - UsageMaster 自己存的 API key（钥匙串条目 "UsageMaster-<服务>"）

/// 条目名。服务名只许字母数字和 ._-：它会被拼进 `security -i` 的命令行（writeKeychainJSON 里用双引号包着，引号本身不能出现）
private func apiKeyKeychainName(_ service: String) -> String? {
    guard service.range(of: #"^[A-Za-z0-9._-]{1,64}$"#, options: .regularExpression) != nil else { return nil }
    return "UsageMaster-" + service
}

/// 粘贴来的 key：去首尾空白、去掉误带的 "Bearer " 前缀；中间有空白或控制字符的一律不收（会破坏请求头）
private func cleanAPIKey(_ raw: String) -> String? {
    var k = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    if k.lowercased().hasPrefix("bearer ") { k = String(k.dropFirst(7)).trimmingCharacters(in: .whitespacesAndNewlines) }
    guard !k.isEmpty, k.count <= 4096,
          k.unicodeScalars.allSatisfy({ !CharacterSet.whitespacesAndNewlines.contains($0) && !CharacterSet.controlCharacters.contains($0) })
    else { return nil }
    return k
}

/// 只看条目在不在：进程内查属性、不取机密（不会弹钥匙串授权框），约 1ms。
/// 不用 runCommand 起 security 子进程：实测那条路要 85–105ms，isConfigured 的 100ms 预算不够
private func apiKeyItemExists(_ service: String) -> Bool {
    guard let name = apiKeyKeychainName(service) else { return false }
    let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                            kSecAttrService as String: name,
                            kSecAttrAccount as String: keychainAccount(),
                            kSecMatchLimit as String: kSecMatchLimitOne,
                            kSecReturnAttributes as String: true]
    var out: CFTypeRef?
    return SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess
}

/// 读出条目里的 key 与整份 JSON（region 等非机密设置也在里面）
private func readAPIKeyItem(_ service: String) -> (apiKey: String, item: [String: Any])? {
    guard let name = apiKeyKeychainName(service), let obj = readKeychainJSON(service: name),
          let raw = obj["apiKey"] as? String, let key = cleanAPIKey(raw) else { return nil }
    return (key, obj)
}

/// 菜单「粘贴 API key」调用：写进 UsageMaster 自己的钥匙串条目 "UsageMaster-<service>"，
/// 经 `security -i` 从标准输入写入（key 不进进程参数），回读一致才返回 true。region 为空则不写（读时按默认处理）。
func saveServiceAPIKey(service: String, apiKey: String, region: String?) -> Bool {
    guard let name = apiKeyKeychainName(service), let key = cleanAPIKey(apiKey) else { return false }
    var obj: [String: Any] = ["apiKey": key]
    if let r = region?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !r.isEmpty {
        guard r.range(of: #"^[a-z0-9_-]{1,32}$"#, options: .regularExpression) != nil else { return false }
        obj["region"] = r
    }
    return writeKeychainJSON(service: name, obj)
}

/// 菜单用：UsageMaster 自己的条目里有没有存 key（只查属性，不取机密）
func hasServiceAPIKey(_ service: String) -> Bool { apiKeyItemExists(service) }

/// 菜单用：已存的区域（MiniMax 弹窗预选），没有返回 nil
func storedServiceRegion(_ service: String) -> String? { readAPIKeyItem(service)?.item["region"] as? String }

/// 菜单「删除 API key」调用：只删 UsageMaster 自己的条目，不碰 OpenCode 等别家软件的凭据
func deleteServiceAPIKey(service: String) {
    guard let name = apiKeyKeychainName(service) else { return }
    _ = runCommand("/usr/bin/security", ["delete-generic-password", "-s", name, "-a", keychainAccount()], timeout: 8)
}

// MARK: - 小工具

private func clampPercent(_ p: Double) -> Double { max(0, min(100, p)) }

/// Unix 时间戳：大于 1e11 视为毫秒，否则视为秒（Orca 把 MiniMax 的 end_time 当毫秒，秒值在这里也能兜住）
private func epochDate(_ n: Double) -> Date? {
    guard n.isFinite, n > 0 else { return nil }
    return Date(timeIntervalSince1970: n > 1e11 ? n / 1000 : n)
}

/// 时间字段：ISO 字符串，或数字时间戳
private func flexibleDate(_ v: Any?) -> Date? {
    if let s = v as? String, let d = parseISO(s) { return d }
    return num(v).flatMap(epochDate)
}

/// 服务端回的错误文案：抹掉回显的 key 与长串令牌样的字符、去换行、截短
private func redactServerText(_ s: String, secret: String?) -> String {
    var t = s.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\r", with: " ")
    if let k = secret, !k.isEmpty { t = t.replacingOccurrences(of: k, with: "***") }
    t = t.replacingOccurrences(of: #"[A-Za-z0-9._~+/=-]{24,}"#, with: "***", options: .regularExpression)
    if t.count > 120 { t = String(t.prefix(120)) + "…" }
    return t
}

// MARK: - OpenCode Go

struct OpenCodeGoService: UsageService {
    let id = "opencode-go"
    let displayName = "OpenCode Go"
    var setupHint: String {
        L("装 OpenCode 后运行 opencode，输入 /connect 选 OpenCode Go 填 API key；或在菜单里直接粘贴 OpenCode Go 的 API key（opencode.ai 控制台获取）",
          "Install OpenCode, run opencode, type /connect, pick OpenCode Go and enter the API key. Or paste your OpenCode Go API key in the menu (get it from the opencode.ai console).")
    }

    static let usageURL = URL(string: "https://opencode.ai/zen/go/v1/usage")!
    static let integrationID = "opencode-go"

    /// rawValue 是与语言无关的标识；显示用 label（跟随界面语言）
    enum KeySource: String {
        case usageMaster, authFile, database, environment

        var label: String {
            switch self {
            case .usageMaster: return L("UsageMaster 钥匙串", "UsageMaster Keychain")
            case .authFile: return L("OpenCode 的 auth.json", "OpenCode auth.json")
            case .database: return L("OpenCode 的本地数据库", "OpenCode local database")
            case .environment: return L("环境变量 OPENCODE_API_KEY", "environment variable OPENCODE_API_KEY")
            }
        }
    }

    /// OpenCode 数据目录：$XDG_DATA_HOME/opencode，否则 ~/.local/share/opencode（Windows 上同样是 %USERPROFILE%\.local\share\opencode）
    static func dataDir(env: [String: String], home: String = NSHomeDirectory()) -> String {
        if let x = env["XDG_DATA_HOME"]?.trimmingCharacters(in: .whitespacesAndNewlines), x.hasPrefix("/") {
            return (x as NSString).appendingPathComponent("opencode")
        }
        return home + "/.local/share/opencode"
    }

    /// auth.json：{"opencode-go": {"type": "api", "key": "..."}}；其它类型（如 oauth）不算
    static func keyFromAuthFile(_ data: Data) -> String? {
        guard data.count <= 1_000_000,
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let e = root[integrationID] as? [String: Any], e["type"] as? String == "api",
              let k = e["key"] as? String else { return nil }
        return cleanAPIKey(k)
    }

    static func authFileKey(dataDir: String) -> String? {
        let p = dataDir + "/auth.json"
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: p),
              let size = attrs[.size] as? NSNumber, size.intValue <= 1_000_000,
              let d = FileManager.default.contents(atPath: p) else { return nil }
        return keyFromAuthFile(d)
    }

    /// credential 表 value 列：{"type": "key", "key": "..."}
    static func keyFromCredentialValue(_ s: String) -> String? {
        guard let d = s.data(using: .utf8), let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any],
              o["type"] as? String == "key", let k = o["key"] as? String else { return nil }
        return cleanAPIKey(k)
    }

    /// 候选数据库：设了 OPENCODE_DB 就只用它（绝对路径，或相对数据目录；":memory:" 表示没有）；
    /// 否则数据目录里名字形如 opencode.db / opencode-<名>.db 的文件，opencode.db 排最前，其余按路径排序
    static func databasePaths(dataDir: String, env: [String: String]) -> [String] {
        let fm = FileManager.default
        func isFile(_ p: String) -> Bool {
            var d: ObjCBool = false
            return fm.fileExists(atPath: p, isDirectory: &d) && !d.boolValue
        }
        if let o = env["OPENCODE_DB"]?.trimmingCharacters(in: .whitespacesAndNewlines), !o.isEmpty {
            if o == ":memory:" { return [] }
            let p = o.hasPrefix("/") ? o : (dataDir as NSString).appendingPathComponent(o)
            return isFile(p) ? [p] : []
        }
        guard let names = try? fm.contentsOfDirectory(atPath: dataDir) else { return [] }
        let paths = names
            .filter { $0.range(of: #"^opencode(-[A-Za-z0-9_.-]+)?\.db$"#, options: .regularExpression) != nil }
            .map { dataDir + "/" + $0 }
            .filter(isFile)
        func rank(_ p: String) -> Int { (p as NSString).lastPathComponent.lowercased() == "opencode.db" ? 0 : 1 }
        return paths.sorted { rank($0) != rank($1) ? rank($0) < rank($1) : $0 < $1 }
    }

    /// 只读打开 OpenCode 的数据库取 key：没有 credential 表就 prepare 失败、直接返回 nil
    static func keyFromDatabase(_ path: String) -> String? {
        var db: OpaquePointer?
        let uri = "file:" + (path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path) + "?mode=ro"
        guard sqlite3_open_v2(uri, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK else {
            sqlite3_close(db)
            return nil
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 50)          // OpenCode 正在写库时最多等 50ms，isConfigured 要快
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        let sql = "SELECT value FROM credential WHERE integration_id = 'opencode-go' ORDER BY active DESC, time_created DESC LIMIT 8"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let c = sqlite3_column_text(stmt, 0) else { continue }
            if let k = keyFromCredentialValue(String(cString: c)) { return k }
        }
        return nil
    }

    /// 按优先级找 key：UsageMaster 钥匙串 → auth.json → 数据库 → 环境变量
    static func resolveKey(env: [String: String] = ProcessInfo.processInfo.environment) -> (key: String, source: KeySource)? {
        if let k = readAPIKeyItem(integrationID)?.apiKey { return (k, .usageMaster) }
        let dir = dataDir(env: env)
        if let k = authFileKey(dataDir: dir) { return (k, .authFile) }
        for p in databasePaths(dataDir: dir, env: env) {
            if let k = keyFromDatabase(p) { return (k, .database) }
        }
        if let v = env["OPENCODE_API_KEY"], let k = cleanAPIKey(v) { return (k, .environment) }
        return nil
    }

    /// 便宜的检查放前面：读小文件 → 环境变量 → 数据库 → 钥匙串（只查条目在不在）
    func isConfigured() -> Bool {
        let env = ProcessInfo.processInfo.environment
        let dir = Self.dataDir(env: env)
        if Self.authFileKey(dataDir: dir) != nil { return true }
        if let v = env["OPENCODE_API_KEY"], cleanAPIKey(v) != nil { return true }
        if Self.databasePaths(dataDir: dir, env: env).contains(where: { Self.keyFromDatabase($0) != nil }) { return true }
        return apiKeyItemExists(Self.integrationID)
    }

    /// 解析 {usage: {rolling, weekly, monthly?}}，每项 {percent: 0–100, resetsAt: ISO}。rolling 与 weekly 缺一个就算解析失败
    static func parseUsage(_ data: Data) -> [ServiceWindow]? {
        guard data.count <= 1_000_000,
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let usage = root["usage"] as? [String: Any] else { return nil }
        func window(_ key: String, _ label: String, _ kind: WindowKind) -> ServiceWindow? {
            guard let w = usage[key] as? [String: Any], let p = num(w["percent"]), p.isFinite else { return nil }
            return ServiceWindow(label: label, percent: clampPercent(p), resetsAt: roundedMinute(flexibleDate(w["resetsAt"])), kind: kind)
        }
        guard let s = window("rolling", L("5 小时窗口", "5-hour window"), .session),
              let w = window("weekly", L("每周", "Weekly"), .weekly) else { return nil }
        var out = [s, w]
        if let m = window("monthly", L("本月", "This month"), .monthly) { out.append(m) }
        return out
    }

    /// 非 2xx：先看 error.type（EntitlementError / AuthError），再看状态码
    static func httpError(code: Int, body: Data) -> String {
        var type: String?
        if body.count <= 4000, let j = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any],
           let e = j["error"] as? [String: Any] {
            type = e["type"] as? String
        }
        if type == "EntitlementError" || code == 403 {
            return L("这个 OpenCode 账号没有订阅 OpenCode Go", "This OpenCode account has no OpenCode Go subscription")
        }
        if type == "AuthError" || code == 401 {
            return L("API key 被拒（HTTP \(code)）：在 OpenCode 里重新 /connect，或在菜单里换一个 key",
                     "API key rejected (HTTP \(code)): run /connect again in OpenCode, or paste a different key in the menu")
        }
        return L("查询用量失败：HTTP \(code)", "Usage request failed: HTTP \(code)")
    }

    func fetch() async -> ServiceStatus {
        var st = ServiceStatus(id: id, displayName: displayName, configured: false, setupHint: setupHint)
        guard let found = Self.resolveKey() else {
            if apiKeyItemExists(Self.integrationID) {
                st.configured = true
                st.accounts = [ServiceAccount(id: id, title: L("默认账号", "Default account"),
                                              error: L("钥匙串里的 API key 读不出来：在菜单里重新粘贴", "Could not read the API key from the Keychain: paste it again in the menu"))]
            }
            return st
        }
        st.configured = true
        var acc = ServiceAccount(id: id, title: L("默认账号", "Default account"),
                                 notes: [L("API key 来源：\(found.source.label)", "API key source: \(found.source.label)")])
        var req = URLRequest(url: Self.usageURL, timeoutInterval: 15)
        req.setValue("Bearer \(found.key)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        do {
            let (body, resp) = try await session.data(for: req)
            let http = resp as? HTTPURLResponse
            let code = http?.statusCode ?? 0
            if !(200..<300).contains(code) {
                acc.error = Self.httpError(code: code, body: body)
            } else if let ws = Self.parseUsage(body) {
                acc.windows = ws
                acc.updatedAt = Date()
            } else if (http?.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased().contains("text/html") {
                // 被拒时 opencode.ai 有可能回一个 200 的网页（登录页），按 key 失效处理
                acc.error = L("API key 被拒（返回了网页）：在 OpenCode 里重新 /connect，或在菜单里换一个 key",
                              "API key rejected (got a web page back): run /connect again in OpenCode, or paste a different key in the menu")
            } else {
                acc.error = L("返回格式变了，解析不出用量", "Unexpected response format, could not read usage")
            }
        } catch {
            acc.error = describe(error)
        }
        st.accounts = [acc]
        return st
    }

    /// 离线自检：用样例 JSON 测解析、窗口映射、凭据读取（建临时文件/数据库，跑完删掉；不发网络、不碰钥匙串）。空数组 = 全过
    static func selfTest() -> [String] {
        var fails: [String] = []
        func check(_ ok: Bool, _ what: String) { if !ok { fails.append(L("OpenCode Go：", "OpenCode Go: ") + what) } }
        let iso = ISO8601DateFormatter()

        // 1. 用量解析：三个窗口、百分比夹到 0–100、ISO 时间（带/不带毫秒）
        let full = #"{"usage":{"rolling":{"percent":42.5,"resetsAt":"2026-10-03T15:00:00.000Z"},"weekly":{"percent":10,"resetsAt":"2026-10-08T00:00:00Z"},"monthly":{"percent":120,"resetsAt":"2026-11-01T00:00:00Z"}}}"#
        if let ws = parseUsage(Data(full.utf8)) {
            check(ws.count == 3, L("完整样例应有 3 个窗口，得到 \(ws.count)", "Full sample should have 3 windows, got \(ws.count)"))
            check(ws.map(\.kind) == [.session, .weekly, .monthly], L("窗口类型映射不对：\(ws.map(\.kind))", "Wrong window kind mapping: \(ws.map(\.kind))"))
            check(ws.first?.percent == 42.5, L("5 小时窗口百分比不对", "Wrong 5-hour window percent"))
            check(ws.first?.resetsAt == iso.date(from: "2026-10-03T15:00:00Z"),
                  L("5 小时窗口重置时间（带毫秒的 ISO）解析不对", "Wrong 5-hour window reset time (ISO with milliseconds)"))
            check(ws.count > 1 && ws[1].resetsAt == iso.date(from: "2026-10-08T00:00:00Z"), L("每周重置时间解析不对", "Wrong weekly reset time"))
            check(ws.count > 2 && ws[2].percent == 100, L("超过 100 的百分比应夹到 100", "Percent over 100 should clamp to 100"))
        } else {
            check(false, L("完整样例解析失败", "Full sample failed to parse"))
        }
        let noMonthly = #"{"usage":{"rolling":{"percent":-3,"resetsAt":"2026-10-03T15:00:00Z"},"weekly":{"percent":"55","resetsAt":null}}}"#
        if let ws = parseUsage(Data(noMonthly.utf8)) {
            check(ws.count == 2, L("没有 monthly 时应只有 2 个窗口", "Without monthly there should be only 2 windows"))
            check(ws.first?.percent == 0, L("负百分比应夹到 0", "Negative percent should clamp to 0"))
            check(ws.count > 1 && ws[1].percent == 55 && ws[1].resetsAt == nil,
                  L("字符串百分比 / 空重置时间处理不对", "Wrong handling of string percent / null reset time"))
        } else {
            check(false, L("没有 monthly 的样例解析失败", "Sample without monthly failed to parse"))
        }
        check(parseUsage(Data(#"{"usage":{"rolling":{"percent":1,"resetsAt":"2026-10-03T15:00:00Z"}}}"#.utf8)) == nil,
              L("缺 weekly 应判解析失败", "Missing weekly should fail to parse"))
        check(parseUsage(Data(#"{"usage":{"rolling":{"resetsAt":"x"},"weekly":{"percent":1}}}"#.utf8)) == nil,
              L("rolling 缺 percent 应判解析失败", "Missing percent in rolling should fail to parse"))
        check(parseUsage(Data("<html>login</html>".utf8)) == nil, L("网页内容应判解析失败", "Web page content should fail to parse"))

        // 2. 错误映射（期望文案随界面语言取，两种语言下都能测）
        let noSub = L("没有订阅", "no OpenCode Go subscription")
        let rejected = L("被拒", "rejected")
        check(httpError(code: 403, body: Data()).contains(noSub), L("403 应提示没有订阅", "403 should say there is no subscription"))
        check(httpError(code: 400, body: Data(#"{"error":{"type":"EntitlementError"}}"#.utf8)).contains(noSub),
              L("EntitlementError 应提示没有订阅", "EntitlementError should say there is no subscription"))
        check(httpError(code: 401, body: Data()).contains(rejected), L("401 应提示 key 被拒", "401 should say the key was rejected"))
        check(httpError(code: 400, body: Data(#"{"error":{"type":"AuthError"}}"#.utf8)).contains(rejected),
              L("AuthError 应提示 key 被拒", "AuthError should say the key was rejected"))
        check(httpError(code: 500, body: Data()) == L("查询用量失败：HTTP 500", "Usage request failed: HTTP 500"),
              L("其它状态码文案不对", "Wrong message for other status codes"))

        // 3. key 清洗与钥匙串条目名
        check(cleanAPIKey("  sk-abc \n") == "sk-abc", L("key 首尾空白没去掉", "Leading/trailing whitespace not stripped from key"))
        check(cleanAPIKey("Bearer sk-abc") == "sk-abc", L("误带的 Bearer 前缀没去掉", "Stray Bearer prefix not stripped"))
        check(cleanAPIKey("sk a") == nil && cleanAPIKey("") == nil && cleanAPIKey("sk\u{7}x") == nil,
              L("带空白/控制字符/空的 key 应拒收", "Keys with whitespace or control characters, and empty keys, should be rejected"))
        check(apiKeyKeychainName("opencode-go") == "UsageMaster-opencode-go", L("钥匙串条目名不对", "Wrong keychain item name"))
        check(apiKeyKeychainName("a\"b") == nil && apiKeyKeychainName("") == nil && apiKeyKeychainName("a b") == nil,
              L("非法服务名应拒收", "Invalid service names should be rejected"))
        check(!saveServiceAPIKey(service: "a\"b", apiKey: "k", region: nil), L("非法服务名保存应失败", "Saving with an invalid service name should fail"))
        check(!saveServiceAPIKey(service: "opencode-go", apiKey: "   ", region: nil), L("空 key 保存应失败", "Saving an empty key should fail"))
        check(!saveServiceAPIKey(service: "minimax", apiKey: "k", region: "c n"), L("非法区域保存应失败", "Saving an invalid region should fail"))

        // 4. auth.json 与 credential value
        check(keyFromAuthFile(Data(#"{"opencode-go":{"type":"api","key":" sk-go "},"anthropic":{"type":"oauth"}}"#.utf8)) == "sk-go",
              L("auth.json 读 key 不对", "Wrong key read from auth.json"))
        check(keyFromAuthFile(Data(#"{"opencode-go":{"type":"oauth","key":"x"}}"#.utf8)) == nil,
              L("auth.json 里非 api 类型应忽略", "Non-api entries in auth.json should be ignored"))
        check(keyFromAuthFile(Data(#"{"opencode":{"type":"api","key":"x"}}"#.utf8)) == nil,
              L("auth.json 里别的条目不该被当成 opencode-go", "Other entries in auth.json should not be taken as opencode-go"))
        check(keyFromCredentialValue(#"{"type":"key","key":"sk-db"}"#) == "sk-db", L("credential value 读 key 不对", "Wrong key read from credential value"))
        check(keyFromCredentialValue(#"{"type":"api","key":"x"}"#) == nil,
              L("credential value 非 key 类型应忽略", "Credential values not of type key should be ignored"))
        check(dataDir(env: [:], home: "/h") == "/h/.local/share/opencode", L("默认数据目录不对", "Wrong default data directory"))
        check(dataDir(env: ["XDG_DATA_HOME": "/x"], home: "/h") == "/x/opencode", L("XDG_DATA_HOME 没生效", "XDG_DATA_HOME not applied"))

        // 5. 真文件：数据库发现顺序、OPENCODE_DB、SQLite credential 表排序、auth.json 读取
        let fm = FileManager.default
        let tmp = NSTemporaryDirectory() + "usagemaster-opencode-selftest-" + UUID().uuidString
        defer { try? fm.removeItem(atPath: tmp) }
        do {
            try fm.createDirectory(atPath: tmp, withIntermediateDirectories: true)
            for n in ["opencode-dev.db", "opencode.db", "other.db", "opencode.db-wal", "opencode-x.sqlite", "opencode-a b.db"] {
                fm.createFile(atPath: tmp + "/" + n, contents: Data())
            }
            try fm.createDirectory(atPath: tmp + "/opencode-dir.db", withIntermediateDirectories: true)
            let names = databasePaths(dataDir: tmp, env: [:]).map { ($0 as NSString).lastPathComponent }
            check(names == ["opencode.db", "opencode-dev.db"], L("数据库发现顺序不对：\(names)", "Wrong database discovery order: \(names)"))
            check(databasePaths(dataDir: tmp, env: ["OPENCODE_DB": ":memory:"]).isEmpty,
                  L("OPENCODE_DB=:memory: 应视为没有数据库", "OPENCODE_DB=:memory: should mean no database"))
            check(databasePaths(dataDir: tmp, env: ["OPENCODE_DB": "opencode-dev.db"]) == [tmp + "/opencode-dev.db"],
                  L("相对路径的 OPENCODE_DB 没按数据目录解析", "Relative OPENCODE_DB not resolved against the data directory"))
            check(databasePaths(dataDir: tmp, env: ["OPENCODE_DB": "missing.db"]).isEmpty,
                  L("OPENCODE_DB 指向不存在的文件应返回空", "OPENCODE_DB pointing to a missing file should return nothing"))

            let dbPath = tmp + "/opencode.db"
            try fm.removeItem(atPath: dbPath)
            var db: OpaquePointer?
            guard sqlite3_open_v2(dbPath, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK else {
                sqlite3_close(db)
                check(false, L("建临时数据库失败", "Failed to create the temporary database"))
                return fails
            }
            let setup = """
            CREATE TABLE credential(id INTEGER PRIMARY KEY, integration_id TEXT, value TEXT, active INTEGER, time_created INTEGER);
            INSERT INTO credential(integration_id, value, active, time_created) VALUES
              ('opencode-go', '{"type":"key","key":"inactive-newest"}', 0, 900),
              ('opencode-go', '{"type":"key","key":"active-old"}', 1, 100),
              ('opencode-go', '{"type":"key","key":"active-new"}', 1, 200),
              ('opencode-go', '{"type":"oauth","key":"wrong-type"}', 1, 999),
              ('opencode-go', 'not json', 1, 998),
              ('other', '{"type":"key","key":"other-integration"}', 1, 9999);
            """
            let rc = sqlite3_exec(db, setup, nil, nil, nil)
            sqlite3_close(db)
            check(rc == SQLITE_OK, L("临时数据库建表失败", "Failed to create the table in the temporary database"))
            let fromDB = keyFromDatabase(dbPath)
            check(fromDB == "active-new", L("数据库应取 active 最新且类型为 key 的那条，得到 \(fromDB ?? "nil")",
                                            "Database should return the newest active entry of type key, got \(fromDB ?? "nil")"))

            let noTable = tmp + "/opencode-dev.db"      // 空文件 = 空库，没有 credential 表
            check(keyFromDatabase(noTable) == nil, L("没有 credential 表应返回 nil", "No credential table should return nil"))

            try Data(#"{"opencode-go":{"type":"api","key":"sk-file"}}"#.utf8).write(to: URL(fileURLWithPath: tmp + "/auth.json"))
            check(authFileKey(dataDir: tmp) == "sk-file", L("从 auth.json 文件读 key 不对", "Wrong key read from the auth.json file"))
            check(authFileKey(dataDir: tmp + "/nope") == nil, L("auth.json 不存在应返回 nil", "Missing auth.json should return nil"))
        } catch {
            check(false, L("临时文件操作失败：\(error.localizedDescription)", "Temporary file operation failed: \(error.localizedDescription)"))
        }
        return fails
    }
}

// MARK: - MiniMax（Coding Plan）

struct MiniMaxService: UsageService {
    let id = "minimax"
    let displayName = "MiniMax"
    var setupHint: String {
        L("在 MiniMax 开放平台的 API Keys 页创建 key（国际版 platform.minimax.io，国内版 platform.minimaxi.com），然后在菜单里粘贴并选对区域",
          "Create a key on the API Keys page of the MiniMax platform (international: platform.minimax.io, China: platform.minimaxi.com), then paste it in the menu and pick the matching region")
    }

    static let remainsPath = "/v1/api/openplatform/coding_plan/remains"

    /// 国际版主机 platform.minimax.io；国内版 API 主机是 www.minimaxi.com（控制台才是 platform.minimaxi.com）
    static func endpoint(cn: Bool) -> URL {
        URL(string: (cn ? "https://www.minimaxi.com" : "https://platform.minimax.io") + remainsPath)!
    }

    /// 要看哪个额度项：钥匙串 JSON 里可选的 "models"（逗号分隔字符串或数组），默认 general（与 Orca 默认一致）
    static func models(from item: [String: Any]) -> [String] {
        var list: [String] = []
        if let s = item["models"] as? String { list = s.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) } }
        else if let a = item["models"] as? [String] { list = a.map { $0.trimmingCharacters(in: .whitespaces) } }
        list = list.filter { !$0.isEmpty }
        return list.isEmpty ? ["general"] : list
    }

    func isConfigured() -> Bool { apiKeyItemExists(id) }

    /// 解析 coding_plan/remains：
    /// - base_resp.status_code 缺省或 0 为正常；1004 = key 过期；其它非 0 用 status_msg（由调用方再脱敏）
    /// - model_remains[] 每项要有 model_name、current_interval_remaining_percent、start_time、end_time，缺一个就丢弃
    /// - 5 小时窗口：已用 = round(100 − 剩余%)，重置 = end_time；周窗口（有 current_weekly_remaining_percent 才有）：
    ///   已用 = round(100 − 周剩余%)，重置 = 现在 + weekly_remains_time（毫秒，是相对时长）
    /// - 选项：按 models 依序找 model_name 完全相等的第一项；都找不到但只有一项时用那一项
    static func parseRemains(_ data: Data, models: [String], now: Date) -> Fetch<(model: String, windows: [ServiceWindow])> {
        guard data.count <= 1_000_000, let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return .err(L("返回格式不对，解析不出用量", "Unexpected response format, could not read usage"))
        }
        if let br = root["base_resp"] as? [String: Any], let code = num(br["status_code"]), code != 0 {
            if code == 1004 { return .err(L("API key 已过期（1004）：在菜单里换一个", "API key expired (1004): paste a new one in the menu")) }
            if let m = br["status_msg"] as? String, !m.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return .err(L("MiniMax 报错（\(Int(code))）：\(m)", "MiniMax error (\(Int(code))): \(m)"))
            }
            return .err(L("MiniMax 返回错误（代码 \(Int(code))）", "MiniMax returned an error (code \(Int(code)))"))
        }
        var entries: [(name: String, windows: [ServiceWindow])] = []
        for case let e as [String: Any] in (root["model_remains"] as? [Any] ?? []) {
            guard let name = e["model_name"] as? String,
                  let remain = num(e["current_interval_remaining_percent"]), remain.isFinite,
                  num(e["start_time"]) != nil, let end = num(e["end_time"]) else { continue }
            var ws = [ServiceWindow(label: L("5 小时窗口", "5-hour window"), percent: clampPercent((100 - remain).rounded()),
                                    resetsAt: roundedMinute(epochDate(end)), kind: .session)]
            if let wr = num(e["current_weekly_remaining_percent"]), wr.isFinite {
                let reset = num(e["weekly_remains_time"]).flatMap { $0.isFinite ? now.addingTimeInterval($0 / 1000) : nil }
                ws.append(ServiceWindow(label: L("每周", "Weekly"), percent: clampPercent((100 - wr).rounded()),
                                        resetsAt: roundedMinute(reset), kind: .weekly))
            }
            entries.append((name, ws))
        }
        for m in models {
            if let hit = entries.first(where: { $0.name == m }) { return .ok((hit.name, hit.windows)) }
        }
        if entries.count == 1 { return .ok((entries[0].name, entries[0].windows)) }
        if entries.isEmpty { return .err(L("返回里没有用量数据", "No usage data in the response")) }
        let have = entries.prefix(5).map(\.name).joined(separator: listSep)
        return .err(L("返回里没有 \(models.joined(separator: "/")) 这一项额度（有：\(have)）",
                      "No \(models.joined(separator: "/")) quota in the response (found: \(have))"))
    }

    func fetch() async -> ServiceStatus {
        var st = ServiceStatus(id: id, displayName: displayName, configured: false, setupHint: setupHint)
        guard let found = readAPIKeyItem(id) else {
            if apiKeyItemExists(id) {
                st.configured = true
                st.accounts = [ServiceAccount(id: id, title: L("默认账号", "Default account"),
                                              error: L("钥匙串里的 API key 读不出来：在菜单里重新粘贴", "Could not read the API key from the Keychain: paste it again in the menu"))]
            }
            return st
        }
        st.configured = true
        let cn = (found.item["region"] as? String)?.lowercased() == "cn"
        var acc = ServiceAccount(id: id, title: cn ? L("默认账号（国内版）", "Default account (China)")
                                                   : L("默认账号（国际版）", "Default account (international)"))
        var req = URLRequest(url: Self.endpoint(cn: cn), timeoutInterval: 10)
        req.setValue("Bearer \(found.apiKey)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        do {
            let (body, resp) = try await session.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            if code == 401 || code == 403 {
                acc.error = L("API key 无效或已过期（HTTP \(code)）：在菜单里换一个，并确认区域（国际版/国内版）选对了",
                              "API key invalid or expired (HTTP \(code)): paste a new one in the menu and check that the region (international/China) is right")
            } else if !(200..<300).contains(code) {
                acc.error = L("查询用量失败：HTTP \(code)", "Usage request failed: HTTP \(code)")
            } else {
                switch Self.parseRemains(body, models: Self.models(from: found.item), now: Date()) {
                case .ok(let r):
                    acc.windows = r.windows
                    acc.updatedAt = Date()
                    if r.model != "general" { acc.notes.append(L("额度项：\(r.model)", "Quota item: \(r.model)")) }
                case .err(let m):
                    acc.error = redactServerText(m, secret: found.apiKey)
                case .notConfigured:
                    break
                }
            }
        } catch {
            acc.error = describe(error)
        }
        st.accounts = [acc]
        return st
    }

    /// 离线自检：用样例 JSON 测解析与窗口映射（不发网络、不碰钥匙串）。空数组 = 全过
    static func selfTest() -> [String] {
        var fails: [String] = []
        func check(_ ok: Bool, _ what: String) { if !ok { fails.append(L("MiniMax：", "MiniMax: ") + what) } }
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        func ok(_ json: String, models: [String] = ["general"]) -> (model: String, windows: [ServiceWindow])? {
            if case .ok(let r) = parseRemains(Data(json.utf8), models: models, now: now) { return r }
            return nil
        }
        func err(_ json: String, models: [String] = ["general"]) -> String? {
            if case .err(let m) = parseRemains(Data(json.utf8), models: models, now: now) { return m }
            return nil
        }

        // 1. 典型返回：选中 general，5 小时窗口 + 周窗口
        let sample = #"{"base_resp":{"status_code":0,"status_msg":"success"},"model_remains":[{"model_name":"video","current_interval_remaining_percent":100,"start_time":1,"end_time":2},{"model_name":"general","current_interval_remaining_percent":74.6,"start_time":1789985600000,"end_time":1790003600000,"current_weekly_remaining_percent":"90","weekly_remains_time":172800000}]}"#
        if let r = ok(sample) {
            check(r.model == "general", L("应选中 general，得到 \(r.model)", "Should pick general, got \(r.model)"))
            check(r.windows.count == 2, L("应有 5 小时 + 周两个窗口，得到 \(r.windows.count)", "Should have two windows (5-hour + weekly), got \(r.windows.count)"))
            check(r.windows.first?.kind == .session && r.windows.first?.percent == 25,
                  L("5 小时已用应为 round(100−74.6)=25，得到 \(r.windows.first?.percent ?? -1)",
                    "5-hour used should be round(100−74.6)=25, got \(r.windows.first?.percent ?? -1)"))
            check(r.windows.first?.resetsAt == roundedMinute(Date(timeIntervalSince1970: 1_790_003_600)),
                  L("5 小时重置时间（end_time 毫秒）不对", "Wrong 5-hour reset time (end_time in milliseconds)"))
            check(r.windows.count > 1 && r.windows[1].kind == .weekly && r.windows[1].percent == 10,
                  L("周已用应为 100−90=10（字符串数字）", "Weekly used should be 100−90=10 (number given as a string)"))
            check(r.windows.count > 1 && r.windows[1].resetsAt == roundedMinute(now.addingTimeInterval(172_800)),
                  L("周重置应为 现在 + weekly_remains_time 毫秒", "Weekly reset should be now + weekly_remains_time milliseconds"))
        } else {
            check(false, L("典型样例解析失败：\(err(sample) ?? "")", "Typical sample failed to parse: \(err(sample) ?? "")"))
        }

        // 2. end_time 是秒、没有周字段、没有 base_resp
        if let r = ok(#"{"model_remains":[{"model_name":"general","current_interval_remaining_percent":"0","start_time":"1789985600","end_time":"1790003600"}]}"#) {
            check(r.windows.count == 1 && r.windows[0].percent == 100,
                  L("剩余 0% 应为已用 100%，且没有周窗口", "0% remaining should be 100% used, with no weekly window"))
            check(r.windows.first?.resetsAt == roundedMinute(Date(timeIntervalSince1970: 1_790_003_600)),
                  L("秒级 end_time 应按秒解析", "An end_time in seconds should be read as seconds"))
        } else {
            check(false, L("秒级时间戳样例解析失败", "Sample with second timestamps failed to parse"))
        }

        // 3. base_resp 错误码（只看错误码与 status_msg 原文，两种语言下都成立）
        check(err(#"{"base_resp":{"status_code":1004,"status_msg":"cookie is missing"}}"#)?.contains("1004") == true,
              L("1004 应提示过期", "1004 should say the key expired"))
        check(err(#"{"base_resp":{"status_code":2013,"status_msg":"invalid params"}}"#)?.contains("invalid params") == true,
              L("其它错误码应带 status_msg", "Other error codes should include status_msg"))
        check(err(#"{"base_resp":{"status_code":1000}}"#)?.contains("1000") == true,
              L("没有 status_msg 时应带错误码", "Without status_msg the error code should be shown"))

        // 4. 选项规则
        check(ok(sample, models: ["video", "general"])?.model == "video", L("按 models 顺序选第一个命中的", "Should pick the first match in models order"))
        check(ok(#"{"model_remains":[{"model_name":"MiniMax-M2","current_interval_remaining_percent":50,"start_time":1,"end_time":1790003600000}]}"#)?.model == "MiniMax-M2",
              L("只有一项时即使名字不匹配也用它", "With only one entry, it should be used even if the name does not match"))
        check(err(sample, models: ["speech"])?.contains("speech") == true,
              L("多项都不匹配应报找不到", "With several entries and no match, it should report not found"))
        check(err(#"{"model_remains":[{"model_name":"general","current_interval_remaining_percent":50,"start_time":1}]}"#) != nil,
              L("缺 end_time 的项应丢弃，丢完报错", "Entries missing end_time should be dropped, with an error when none are left"))
        check(err("not json") != nil, L("非 JSON 应报错", "Non-JSON should report an error"))
        check(models(from: ["models": " a, b,,"]) == ["a", "b"] && models(from: [:]) == ["general"] && models(from: ["models": ["x"]]) == ["x"],
              L("models 设置解析不对", "Wrong parsing of the models setting"))

        // 5. 区域端点与脱敏
        check(endpoint(cn: false).absoluteString == "https://platform.minimax.io/v1/api/openplatform/coding_plan/remains",
              L("国际版端点不对", "Wrong international endpoint"))
        check(endpoint(cn: true).absoluteString == "https://www.minimaxi.com/v1/api/openplatform/coding_plan/remains",
              L("国内版端点不对", "Wrong China endpoint"))
        let secret = "sk-cp-abcdefghijklmnopqrstuvwxyz0123456789"
        let red = redactServerText("bad key \(secret)\nBearer eyJhbGciOiJIUzI1NiJ9.payloadpayloadpayload", secret: secret)
        check(!red.contains(secret) && !red.contains("eyJhbGciOiJIUzI1NiJ9") && !red.contains("\n"),
              L("错误文案没有脱敏：\(red)", "Error text not redacted: \(red)"))
        check(redactServerText(String(repeating: "错", count: 300), secret: nil).count <= 121, L("错误文案没有截短", "Error text not truncated"))
        return fails
    }
}
