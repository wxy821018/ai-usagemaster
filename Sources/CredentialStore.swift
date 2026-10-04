// 凭据存储：同一套读写接口，macOS 落在钥匙串，Windows 落在 JSON 文件
//
// 一份凭据用 CredentialRef 表示它在哪。macOS 上是钥匙串条目（service + account），Windows 上是文件路径：
// - Claude Code 在 Windows 上不用钥匙串，登录写在 <配置目录>/.credentials.json（明文，Claude Code 自己要读，原样读写）；
// - Orca 在 Windows 上把各账号放在 %APPDATA%\orca\claude-accounts\<id>\auth\.credentials.json；
// - UsageMaster 自己存的 API key 在 Windows 上用 DPAPI 加密后写文件（只有当前 Windows 用户能解开）。
// 两个平台的写入都要回读一致才算成功。

#if canImport(Security)
import Security
#endif
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import Foundation
#if os(Windows)
import WinSDK
#endif

struct CredentialRef: Equatable {
    var service: String              // macOS：钥匙串条目名
    var account: String? = nil       // macOS：钥匙串 account 字段；nil 用 keychainAccount()（Claude Code 的约定）
    var file: String                 // Windows：凭据文件
    var encrypted = false            // Windows：文件用 DPAPI 加密（只用于 UsageMaster 自己的条目）
}

extension CredentialRef {
    /// 平时直接运行 `claude` 用的那份凭据（没有 CLAUDE_CONFIG_DIR 时）
    static let claudeDefault = CredentialRef(service: "Claude Code-credentials",
                                             file: NSHomeDirectory() + "/.claude/.credentials.json")

    /// 用 CLAUDE_CONFIG_DIR=<dir> 登录的那份（UsageMaster 自管账号）
    static func claude(configDir dir: String) -> CredentialRef {
        CredentialRef(service: keychainService(forConfigDir: dir), file: dir + "/.credentials.json")
    }

    /// Orca 管着的某个 Claude 账号（只读，用来比对刷新令牌）
    static func orca(id: String) -> CredentialRef {
        CredentialRef(service: "Orca Claude Code Managed Credentials", account: id,
                      file: orcaClaudeAccountsDir + "/" + id + "/auth/.credentials.json")
    }

    /// UsageMaster 自己存的东西（API key 等），name 形如 "UsageMaster-minimax"
    static func usageMaster(_ name: String) -> CredentialRef {
        CredentialRef(service: name, file: usageMasterSecretsDir + "/" + name + ".bin", encrypted: true)
    }
}

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

let orcaClaudeAccountsDir = appSupportRoot + "/orca/claude-accounts"
let usageMasterSecretsDir = appDataDir + "/secrets"     // 只有 Windows 用；macOS 上 UsageMaster 自己的条目都在钥匙串

/// 区分"没有这份凭据"和"有，但读不出合法 JSON"：后者绝不能当成空的去覆盖
enum CredentialRead { case missing, unreadable, ok([String: Any]) }

/// 两份 JSON 对象内容是否相同：按排好序的键序列化后逐字节比。
/// 不用 NSDictionary.isEqual：Windows 版 Foundation 把 Swift 的 Int/Double 和 JSON 解出来的 NSNumber 判成不相等
/// （Swift 6.4 实测：["n": 1] 写进去再读回来比对得 false）
func jsonEqual(_ a: [String: Any], _ b: [String: Any]) -> Bool {
    guard let x = try? JSONSerialization.data(withJSONObject: a, options: [.sortedKeys]),
          let y = try? JSONSerialization.data(withJSONObject: b, options: [.sortedKeys]) else { return false }
    return x == y
}

#if os(macOS)

// MARK: - macOS：钥匙串（经 /usr/bin/security，与 Claude Code 写入方式一致）

private func keychainAccountFor(_ r: CredentialRef) -> String { r.account ?? keychainAccount() }

/// 读不到或不是合法 JSON 都返回 nil。走 runCommand，8 秒超时：钥匙串弹授权框时不会一直卡住
func readCredential(_ r: CredentialRef) -> [String: Any]? {
    guard let data = runCommand("/usr/bin/security", ["find-generic-password", "-s", r.service, "-a", keychainAccountFor(r), "-w"], timeout: 8),
          let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
    return obj
}

func readCredentialStrict(_ r: CredentialRef) -> CredentialRead {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/security")
    p.arguments = ["find-generic-password", "-s", r.service, "-a", keychainAccountFor(r), "-w"]
    let out = Pipe()
    p.standardOutput = out
    p.standardError = FileHandle.nullDevice
    do { try p.run() } catch { return .unreadable }
    let data = out.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    if p.terminationStatus == 44 { return .missing }                 // errSecItemNotFound
    guard p.terminationStatus == 0, let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return .unreadable }
    return .ok(obj)
}

/// 写钥匙串（-X 十六进制）。一般经 `security -i` 从标准输入写，令牌不出现在进程参数里；
/// 但 `security -i` 一行最多约 4 KB，更长的会被截断、把半截 JSON 写进条目（默认凭据带着很多 MCP 登录时就会这样），
/// 所以超过 4000 字符时和 Claude Code 自己一样改用参数形式（参数只在这一瞬间对本机同一用户可见）。写完回读一致才算成功。
func writeCredential(_ r: CredentialRef, _ obj: [String: Any]) -> Bool {
    guard let data = try? JSONSerialization.data(withJSONObject: obj) else { return false }
    let hex = data.map { String(format: "%02x", $0) }.joined()
    let account = keychainAccountFor(r)
    let cmd = "add-generic-password -U -a \"\(account)\" -s \"\(r.service)\" -X \"\(hex)\"\n"
    if cmd.utf8.count > 4000 {
        guard runCommand("/usr/bin/security", ["add-generic-password", "-U", "-a", account, "-s", r.service, "-X", hex], timeout: 8) != nil,
              let back = readCredential(r) else { return false }
        return NSDictionary(dictionary: back).isEqual(to: obj)
    }
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
    guard p.terminationStatus == 0, let back = readCredential(r) else { return false }
    return NSDictionary(dictionary: back).isEqual(to: obj)          // 回读一致才算成功
}

func deleteCredential(_ r: CredentialRef) {
    _ = runCommand("/usr/bin/security", ["delete-generic-password", "-s", r.service, "-a", keychainAccountFor(r)], timeout: 8)
}

/// 只看在不在：进程内查属性、不取机密（不会弹钥匙串授权框），约 1ms。
/// 不用 security 子进程：实测那条路要 85–105ms，isConfigured 的 100ms 预算不够
func credentialExists(_ r: CredentialRef) -> Bool {
    let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                            kSecAttrService as String: r.service,
                            kSecAttrAccount as String: keychainAccountFor(r),
                            kSecMatchLimit as String: kSecMatchLimitOne,
                            kSecReturnAttributes as String: true]
    var out: CFTypeRef?
    return SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess
}

#elseif os(Windows)

// MARK: - Windows：文件

func readCredential(_ r: CredentialRef) -> [String: Any]? {
    if case .ok(let o) = readCredentialStrict(r) { return o }
    return nil
}

func readCredentialStrict(_ r: CredentialRef) -> CredentialRead {
    guard FileManager.default.fileExists(atPath: r.file) else { return .missing }
    guard var data = try? Data(contentsOf: URL(fileURLWithPath: r.file)) else { return .unreadable }
    if r.encrypted {
        guard let plain = dpapi(data, protect: false) else { return .unreadable }
        data = plain
    }
    guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return .unreadable }
    return .ok(obj)
}

/// 先写同目录的临时文件，再整体替换（replaceFile：MoveFileEx，目标正被打开时重试几次）。
/// Claude Code 在每次请求前看这个文件的修改时间，读到的只会是旧的或新的完整内容，不会是半截。写完回读一致才算成功。
func writeCredential(_ r: CredentialRef, _ obj: [String: Any]) -> Bool {
    guard var data = try? JSONSerialization.data(withJSONObject: obj) else { return false }
    if r.encrypted {
        guard let sealed = dpapi(data, protect: true) else { return false }
        data = sealed
    }
    let dir = (r.file as NSString).deletingLastPathComponent
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    let tmp = r.file + ".tmp-" + UUID().uuidString.prefix(8)
    guard (try? data.write(to: URL(fileURLWithPath: tmp))) != nil else { return false }
    guard replaceFile(tmp, r.file) else { try? FileManager.default.removeItem(atPath: tmp); return false }
    guard let back = readCredential(r) else { return false }
    return jsonEqual(back, obj)
}

func deleteCredential(_ r: CredentialRef) {
    try? FileManager.default.removeItem(atPath: r.file)
}

func credentialExists(_ r: CredentialRef) -> Bool {
    FileManager.default.fileExists(atPath: r.file)
}

/// DPAPI：用当前 Windows 用户的密钥加密/解密，不弹任何界面
private func dpapi(_ input: Data, protect: Bool) -> Data? {
    var inBytes = [UInt8](input)
    return inBytes.withUnsafeMutableBufferPointer { buf -> Data? in
        var inBlob = DATA_BLOB(cbData: DWORD(buf.count), pbData: buf.baseAddress)
        var outBlob = DATA_BLOB()
        let ok = protect
            ? CryptProtectData(&inBlob, nil, nil, nil, nil, DWORD(CRYPTPROTECT_UI_FORBIDDEN), &outBlob)
            : CryptUnprotectData(&inBlob, nil, nil, nil, nil, DWORD(CRYPTPROTECT_UI_FORBIDDEN), &outBlob)
        guard ok, let p = outBlob.pbData else { return nil }
        defer { LocalFree(p) }
        return Data(bytes: p, count: Int(outBlob.cbData))
    }
}

#endif
