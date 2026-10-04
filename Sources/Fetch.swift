// 汇总抓取

import AppKit
import CryptoKit
import Foundation
import SQLite3

// MARK: - 汇总抓取

struct Snapshot {
    var claude: Fetch<[ClaudeAccount]>
    var cursor: Fetch<CursorUsage>
    var at: Date
}

func fetchAll() async -> Snapshot {
    let managed = listManagedAccounts()
    var claude: Fetch<[ClaudeAccount]>
    if managed.isEmpty {
        switch await fetchClaudeDirect() {
        case .ok(let a): claude = .ok([a])
        case .err(let m): claude = .err(m)
        }
    } else {
        // 各账号并行查
        let results = await withTaskGroup(of: (Int, ClaudeAccount).self) { g in
            let cur = currentDefaultIdentity().map { $0.email + "|" + $0.orgUuid }
            for (i, a) in managed.enumerated() {
                let isDef = cur != nil && identityKey(a) == cur
                g.addTask { (i, await fetchManaged(a, isDefault: isDef)) }
            }
            var out: [(Int, ClaudeAccount)] = []
            for await r in g { out.append(r) }
            return out.sorted { $0.0 < $1.0 }.map { $0.1 }
        }
        claude = .ok(results)
    }
    let cursor = await fetchCursorDirect()
    return Snapshot(claude: claude, cursor: cursor, at: Date())
}
