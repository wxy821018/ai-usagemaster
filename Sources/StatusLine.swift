// Claude Code 状态栏插件：
//   Claude Code 每次刷新状态栏时把一段 JSON 从标准输入交给 statusLine 命令，里面带实时的
//   rate_limits.five_hour / seven_day（used_percentage 0–100，resets_at 为 epoch 秒）、model、cost 等。
//   AIUsageMaster --statusline 做三件事：
//     1) 原样执行用户原来的 statusLine 命令（例如 Orca 的），保证原有功能不受影响；
//     2) 把实时用量连同当前账号身份存一份快照（不含对话内容、路径等其它字段），菜单栏程序优先用它，少调用量接口；
//     3) 输出一行状态：模型、本会话折合费用、当前账号与其它账号的用量。
//   --install-statusline / --uninstall-statusline 负责改写 ~/.claude/settings.json（改前备份，卸载时原样还原）。

import Foundation

let statusLineDir = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Application Support/UsageMaster", isDirectory: true)
let statusLineSnapshotURL = statusLineDir.appendingPathComponent("statusline_latest.json")
let statusLineUpstreamURL = URL(fileURLWithPath: NSHomeDirectory() + "/.config/usagemaster/statusline_upstream.json")
let claudeSettingsURL = URL(fileURLWithPath: NSHomeDirectory() + "/.claude/settings.json")

struct StatusLineSnapshot: Codable {
    var ts: Date
    var email: String
    var orgUuid: String
    var fiveHourPct: Double?
    var fiveHourResetsAt: Date?
    var weeklyPct: Double?
    var weeklyResetsAt: Date?
}

func readStatusLineSnapshot() -> StatusLineSnapshot? {
    guard let d = try? Data(contentsOf: statusLineSnapshotURL) else { return nil }
    let dec = JSONDecoder(); dec.dateDecodingStrategy = .secondsSince1970
    return try? dec.decode(StatusLineSnapshot.self, from: d)
}

/// 快照里的用量还原成窗口（给菜单栏程序用）
func windowsFromStatusLine(_ s: StatusLineSnapshot, now: Date = Date()) -> [UsageWindow] {
    var w: [UsageWindow] = []
    if let p = s.fiveHourPct { w.append(makeWindow(windowLabel(kind: "session"), percent: p, resetsAt: s.fiveHourResetsAt, now: now, kind: "session")) }
    if let p = s.weeklyPct { w.append(makeWindow(windowLabel(kind: "weekly_all"), percent: p, resetsAt: s.weeklyResetsAt, now: now, kind: "weekly_all")) }
    return w
}

/// 状态栏数据属于哪个账号：已开着的 Claude Code 会话可能还在用切换前的账号，不能简单按 ~/.claude.json 归属。
/// 每个账号的每周重置时间各不相同 → 用快照的每周重置时间去匹配各账号缓存里的每周重置时间（误差 2 分钟内）。
func matchStatusLineAccount(_ s: StatusLineSnapshot, accounts: [ManagedAccount]) -> ManagedAccount? {
    guard let r = s.weeklyResetsAt else { return nil }
    let hits = accounts.filter { a in
        guard let e = a.email?.lowercased() else { return false }
        let ws = UsageCache.shared.windows(e + "|" + (a.orgUuid ?? ""))
        return ws.contains { isWeeklyAllWindow($0) && $0.resetsAt.map { abs($0.timeIntervalSince(r)) < 120 } == true }
    }
    return hits.count == 1 ? hits[0] : nil
}

// MARK: - --statusline

private func ansi(_ s: String, _ pct: Double?) -> String {
    guard let p = pct else { return s }
    if p >= 90 { return "\u{1B}[31m\(s)\u{1B}[0m" }        // 红
    if p >= 75 { return "\u{1B}[33m\(s)\u{1B}[0m" }        // 黄
    return s
}

private func hhmm(_ d: Date?) -> String {
    guard let d = d else { return "" }
    let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX")
    f.dateFormat = d.timeIntervalSinceNow < 86400 ? "HH:mm" : "M/d"
    return f.string(from: d)
}

/// 执行原来的 statusLine 命令：把同一份输入交给它，最多等 0.3 秒拿它的输出；没输出完也不阻塞我们
private func runUpstream(_ input: Data) -> String {
    guard let d = try? Data(contentsOf: statusLineUpstreamURL),
          let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
          let cmd = o["command"] as? String, !cmd.isEmpty else { return "" }
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/sh")
    p.arguments = ["-c", cmd]
    let inPipe = Pipe(), outPipe = Pipe()
    p.standardInput = inPipe
    p.standardOutput = outPipe
    p.standardError = FileHandle.nullDevice
    do { try p.run() } catch { return "" }
    inPipe.fileHandleForWriting.write(input)
    try? inPipe.fileHandleForWriting.close()
    let done = DispatchSemaphore(value: 0)
    var out = Data()
    DispatchQueue.global().async { out = outPipe.fileHandleForReading.readDataToEndOfFile(); done.signal() }
    if done.wait(timeout: .now() + 0.3) == .timedOut { return "" }    // 它自己会跑完（例如把数据转发给 Orca）
    return String(data: out, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
}

func runStatusLine() {
    let input = FileHandle.standardInput.readDataToEndOfFile()
    let upstream = runUpstream(input)
    let j = (try? JSONSerialization.jsonObject(with: input) as? [String: Any]) ?? [:]
    let now = Date()

    // 当前账号身份（~/.claude.json 的 oauthAccount，不含令牌）
    let ident = currentDefaultIdentity()
    let rl = j["rate_limits"] as? [String: Any]
    let fh = rl?["five_hour"] as? [String: Any]
    let wk = rl?["seven_day"] as? [String: Any]
    func secs(_ v: Any?) -> Date? { num(v).map { Date(timeIntervalSince1970: $0 > 1e11 ? $0 / 1000 : $0) } }
    var snap: StatusLineSnapshot?
    if let id = ident, rl != nil {
        snap = StatusLineSnapshot(ts: now, email: id.email, orgUuid: id.orgUuid,
                                  fiveHourPct: num(fh?["used_percentage"]), fiveHourResetsAt: secs(fh?["resets_at"]),
                                  weeklyPct: num(wk?["used_percentage"]), weeklyResetsAt: secs(wk?["resets_at"]))
        try? FileManager.default.createDirectory(at: statusLineDir, withIntermediateDirectories: true)
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .secondsSince1970
        if let d = try? enc.encode(snap) {
            try? d.write(to: statusLineSnapshotURL, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: statusLineSnapshotURL.path)
        }
    }

    var parts: [String] = []
    if let m = (j["model"] as? [String: Any])?["display_name"] as? String { parts.append(m) }
    if let c = num((j["cost"] as? [String: Any])?["total_cost_usd"]), c > 0 { parts.append(String(format: "$%.2f", c)) }

    // 当前账号：实时数字
    let managed = listManagedAccountsReadOnly()
    let matched = snap.flatMap { matchStatusLineAccount($0, accounts: managed) }
    if let s = snap {
        var seg = "● " + (matched.map { accountLabel(dir: $0.dir, email: $0.email ?? "") } ?? L("本会话", "this session"))
        if let p = s.fiveHourPct { seg += " " + ansi("5h \(Int(p.rounded()))%", p) + (s.fiveHourResetsAt.map { "↻" + hhmm($0) } ?? "") }
        if let p = s.weeklyPct { seg += " " + ansi(L("周", "wk") + " \(Int(p.rounded()))%", p) }
        parts.append(seg)
    }
    // 其它账号：菜单栏程序缓存里的数字
    for a in managed {
        guard let email = a.email?.lowercased(), a.dir != matched?.dir else { continue }
        let ws = UsageCache.shared.windows(email + "|" + (a.orgUuid ?? ""), now: now)
        guard let worst = ws.max(by: { $0.percent < $1.percent }) else { continue }
        let tag = isWeeklyWindow(worst) ? L("周", "wk") : "5h"
        let reset = worst.percent >= 99 ? "↻" + hhmm(worst.resetsAt) : ""
        parts.append(accountLabel(dir: a.dir, email: email) + " " + ansi("\(tag) \(Int(worst.percent.rounded()))%", worst.percent) + reset)
    }
    let ours = parts.joined(separator: " │ ")
    print(upstream.isEmpty ? ours : upstream + " │ " + ours)
}

/// 只读列出账号（状态栏模式不能顺手删重复目录或迁移，避免和菜单栏程序同时动文件）
func listManagedAccountsReadOnly() -> [ManagedAccount] {
    guard let names = try? FileManager.default.contentsOfDirectory(atPath: accountsRoot) else { return [] }
    return names.sorted().compactMap { name in
        guard !name.hasPrefix(".") else { return nil }
        let dir = accountsRoot + "/" + name
        var a = ManagedAccount(dir: dir, service: keychainService(forConfigDir: dir))
        if let oa = readJSONFile(dir + "/.claude.json")?["oauthAccount"] as? [String: Any] {
            a.email = oa["emailAddress"] as? String
            a.org = oa["organizationName"] as? String
            a.orgUuid = oa["organizationUuid"] as? String
            a.oauthAccount = oa
        }
        return a.email == nil ? nil : a
    }
}

// MARK: - 安装 / 卸载

func ourStatusLineCommand() -> String {
    let bin = Bundle.main.executablePath ?? (NSHomeDirectory() + "/Applications/AI UsageMaster.app/Contents/MacOS/AIUsageMaster")
    return "\"\(bin)\" --statusline"
}

func statusLineInstalled() -> Bool {
    guard let s = readJSONFile(claudeSettingsURL.path)?["statusLine"] as? [String: Any],
          let c = s["command"] as? String else { return false }
    return c.contains("--statusline") && c.contains("AIUsageMaster")
}

private func writeSettings(_ obj: [String: Any]) -> Bool {
    guard let d = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .withoutEscapingSlashes]) else { return false }
    let stamp = Int(Date().timeIntervalSince1970)
    let backup = claudeSettingsURL.path + ".bak-aium-\(stamp)"
    try? FileManager.default.copyItem(atPath: claudeSettingsURL.path, toPath: backup)
    do { try d.write(to: claudeSettingsURL, options: .atomic); return true } catch { return false }
}

/// 装上：原来的 statusLine 存进 ~/.config/usagemaster/statusline_upstream.json，再换成我们的命令
func installStatusLine() -> String {
    guard var settings = readJSONFile(claudeSettingsURL.path) else { return L("读不到 ~/.claude/settings.json", "Could not read ~/.claude/settings.json") }
    if statusLineInstalled() { return L("已经装好了", "Already installed") }
    let old = settings["statusLine"] as? [String: Any] ?? [:]
    try? FileManager.default.createDirectory(at: statusLineUpstreamURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    if let d = try? JSONSerialization.data(withJSONObject: old, options: [.prettyPrinted]) { try? d.write(to: statusLineUpstreamURL, options: .atomic) }
    var mine: [String: Any] = ["type": "command", "command": ourStatusLineCommand()]
    if let pad = old["padding"] { mine["padding"] = pad }
    settings["statusLine"] = mine
    return writeSettings(settings) ? L("已安装（原来的状态栏命令会照常执行；设置已备份）", "Installed (your previous status line command still runs; settings were backed up)") : L("写 settings.json 失败", "Could not write settings.json")
}

/// 卸载：把原来的 statusLine 原样放回
func uninstallStatusLine() -> String {
    guard var settings = readJSONFile(claudeSettingsURL.path) else { return L("读不到 ~/.claude/settings.json", "Could not read ~/.claude/settings.json") }
    guard statusLineInstalled() else { return L("当前不是 AI UsageMaster 的状态栏，没动", "The current status line is not AI UsageMaster's; left unchanged") }
    if let d = try? Data(contentsOf: statusLineUpstreamURL), let old = try? JSONSerialization.jsonObject(with: d) as? [String: Any], !old.isEmpty {
        settings["statusLine"] = old
    } else {
        settings.removeValue(forKey: "statusLine")
    }
    return writeSettings(settings) ? L("已卸载，原来的状态栏已还原", "Removed; your previous status line is restored") : L("写 settings.json 失败", "Could not write settings.json")
}
