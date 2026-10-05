// 汇总抓取

#if canImport(AppKit)
import AppKit
#endif
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking   // Windows / Linux 上 URLSession 在这个模块里
#endif
import SQLite3

// MARK: - 汇总抓取

struct Snapshot {
    var claude: Fetch<[ClaudeAccount]>
    var cursor: Fetch<CursorUsage>
    var services: [ServiceStatus] = []
    var orcaActive: String? = nil       // Orca 里选中的 Claude 账号（邮箱）
    var at: Date
}

/// 其它 AI 服务的查询节奏：只查本机已配置的；Codex 至少隔 15 分钟、其它 10 分钟，手动刷新至少隔 2 分钟；
/// 一次全部失败时保留上次成功的数字并注明原因（和 Claude 账号同一个思路，避免被限流、避免数字闪没）
actor ServicePacer {
    static let shared = ServicePacer()
    private var last: [String: ServiceStatus] = [:]
    private var lastOK: [String: (status: ServiceStatus, at: Date)] = [:]
    private var attempted: [String: Date] = [:]

    private func interval(_ id: String) -> TimeInterval { id == "codex" ? 900 : 600 }

    func get(_ s: UsageService, force: Bool) async -> ServiceStatus {
        let now = Date()
        if let a = attempted[s.id], now.timeIntervalSince(a) < (force ? 120 : interval(s.id)) {
            return last[s.id] ?? ServiceStatus(id: s.id, displayName: s.displayName, configured: true, setupHint: s.setupHint)
        }
        attempted[s.id] = now
        let st = await s.fetch()
        let ok = st.accounts.contains { $0.error == nil }
        if ok || st.accounts.isEmpty && !st.configured {
            if ok { lastOK[s.id] = (st, Date()) }
            last[s.id] = st
            return st
        }
        // 这次全失败：有上次成功的数据就接着显示它
        if let prev = lastOK[s.id] {
            var keep = prev.status
            let why = st.accounts.compactMap { $0.error }.first ?? L("未知错误", "unknown error")
            for i in keep.accounts.indices {
                keep.accounts[i].notes.insert(L("⚠︎ 刷新失败：\(why)（下面是 \(ago(prev.at)) 的数据）",
                                                "⚠︎ Refresh failed: \(why) (showing data from \(ago(prev.at)))"), at: 0)
            }
            last[s.id] = keep
            return keep
        }
        last[s.id] = st
        return st
    }
}

func fetchServices(force: Bool) async -> [ServiceStatus] {
    let configured = registeredServices.filter { $0.isConfigured() }
    return await withTaskGroup(of: (Int, ServiceStatus).self) { g in
        for (i, s) in configured.enumerated() { g.addTask { (i, await ServicePacer.shared.get(s, force: force)) } }
        var out: [(Int, ServiceStatus)] = []
        for await r in g { out.append(r) }
        return out.sorted { $0.0 < $1.0 }.map { $0.1 }
    }
}

func fetchAll(force: Bool = false) async -> Snapshot {
    let managed = listManagedAccounts()
    var claude: Fetch<[ClaudeAccount]>
    if managed.isEmpty {
        switch await fetchClaudeDirect(force: force) {
        case .ok(let a): claude = .ok([a])
        case .err(let m): claude = .err(m)
        case .notConfigured: claude = .notConfigured
        }
    } else {
        // 各账号并行查
        // 状态栏快照：用完整账号列表匹配一次，匹配唯一才用（每个账号的每周重置时间不同，靠它认账号）
        let snap = readStatusLineSnapshot().flatMap { Date().timeIntervalSince($0.ts) < 600 ? $0 : nil }
        let liveDir = snap.flatMap { matchStatusLineAccount($0, accounts: managed) }?.dir
        let results = await withTaskGroup(of: (Int, ClaudeAccount).self) { g in
            let cur = currentDefaultIdentity().map { $0.email + "|" + $0.orgUuid }
            for (i, a) in managed.enumerated() {
                let isDef = cur != nil && identityKey(a) == cur
                let live = a.dir == liveDir ? snap : nil
                g.addTask { (i, await fetchManaged(a, isDefault: isDef, force: force, liveSnapshot: live)) }
            }
            var out: [(Int, ClaudeAccount)] = []
            for await r in g { out.append(r) }
            return out.sorted { $0.0 < $1.0 }.map { $0.1 }
        }
        claude = .ok(results)
    }
    async let cursorTask = fetchCursorDirect()
    async let servicesTask = fetchServices(force: force)
    async let orcaTask = Task.detached { orcaClaudeState() }.value
    let (cursor, services, orca) = await (cursorTask, servicesTask, orcaTask)
    // 和 Orca 共用同一个刷新令牌的账号：标出来（菜单提示重新登录、不能被切过去）
    if let st = orca, case .ok(var accts) = claude, !managed.isEmpty {
        for i in accts.indices {
            guard let m = managed.first(where: { $0.dir == accts[i].configDir }),
                  let rt = (readCredential(m.cred)?["claudeAiOauth"] as? [String: Any])?["refreshToken"] as? String else { continue }
            if sharesRefreshTokenWithOrca(email: m.email, refreshToken: rt, state: st) {
                accts[i].sharedWithOrca = true
                accts[i].notes.insert(L("⚠︎ 和 Orca 共用同一份登录（任一边刷新都会把另一边挤下线），请点「重新登录」", "⚠︎ Shares its sign-in with Orca (a refresh on either side signs the other out); choose Sign In Again"), at: 0)
            }
        }
        claude = .ok(accts)
    }
    return Snapshot(claude: claude, cursor: cursor, services: services, orcaActive: orca?.active, at: Date())
}
