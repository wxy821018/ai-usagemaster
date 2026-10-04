// 汇总抓取

import AppKit
import CryptoKit
import Foundation
import SQLite3

// MARK: - 汇总抓取

struct Snapshot {
    var claude: Fetch<[ClaudeAccount]>
    var cursor: Fetch<CursorUsage>
    var services: [ServiceStatus] = []
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
        }
    } else {
        // 各账号并行查
        let results = await withTaskGroup(of: (Int, ClaudeAccount).self) { g in
            let cur = currentDefaultIdentity().map { $0.email + "|" + $0.orgUuid }
            for (i, a) in managed.enumerated() {
                let isDef = cur != nil && identityKey(a) == cur
                g.addTask { (i, await fetchManaged(a, isDefault: isDef, force: force)) }
            }
            var out: [(Int, ClaudeAccount)] = []
            for await r in g { out.append(r) }
            return out.sorted { $0.0 < $1.0 }.map { $0.1 }
        }
        claude = .ok(results)
    }
    async let cursorTask = fetchCursorDirect()
    async let servicesTask = fetchServices(force: force)
    let (cursor, services) = await (cursorTask, servicesTask)
    return Snapshot(claude: claude, cursor: cursor, services: services, at: Date())
}
