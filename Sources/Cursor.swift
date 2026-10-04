// Cursor：本期用量

import AppKit
import CryptoKit
import Foundation
import SQLite3

// MARK: - Cursor

func readCursorToken() -> String? {
    let path = appSupportRoot + "/Cursor/User/globalStorage/state.vscdb"     // Windows：%APPDATA%\Cursor\User\globalStorage
    var db: OpaquePointer?
    let uri = "file:" + (path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path) + "?mode=ro"
    guard sqlite3_open_v2(uri, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK else {
        sqlite3_close(db)
        return nil
    }
    defer { sqlite3_close(db) }
    sqlite3_busy_timeout(db, 1000)
    var stmt: OpaquePointer?
    defer { sqlite3_finalize(stmt) }
    guard sqlite3_prepare_v2(db, "select value from ItemTable where key='cursorAuth/accessToken'", -1, &stmt, nil) == SQLITE_OK,
          sqlite3_step(stmt) == SQLITE_ROW,
          let c = sqlite3_column_text(stmt, 0) else { return nil }
    return String(cString: c)
}

func cursorRPC(_ method: String, token: String) async throws -> [String: Any] {
    var req = URLRequest(url: URL(string: "https://api2.cursor.sh/aiserver.v1.DashboardService/\(method)")!, timeoutInterval: 10)
    req.httpMethod = "POST"
    req.httpBody = Data("{}".utf8)
    req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
    req.setValue("1", forHTTPHeaderField: "Connect-Protocol-Version")
    let (data, resp) = try await session.data(for: req)
    let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
    guard code == 200 else {
        throw NSError(domain: "cursor", code: code, userInfo: [NSLocalizedDescriptionKey:
            code == 401 ? L("令牌失效（401）：打开一下 Cursor 就会刷新", "Token rejected (401): opening Cursor once refreshes it") : "HTTP \(code)"])
    }
    return (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
}

func fetchCursorDirect() async -> Fetch<CursorUsage> {
    guard let token = readCursorToken() else { return .notConfigured }
    do {
        let d = try await cursorRPC("GetCurrentPeriodUsage", token: token)
        var u = CursorUsage()
        u.cycleEnd = msDate(d["billingCycleEnd"])
        guard let p = d["planUsage"] as? [String: Any] else { return .err(L("返回里没有 planUsage，格式可能变了", "No planUsage in the response; the format may have changed")) }
        // 与 Cursor 3.21 客户端同一公式：limit>0 时 min(included/limit,100%)，否则用 totalPercentUsed。
        // proto3 JSON 省略 0 值，所以 includedSpend 缺失按 0。
        let used = Int(num(p["includedSpend"]) ?? 0)
        let limit = Int(num(p["limit"]) ?? 0)
        if limit > 0 {
            u.usedCents = used
            u.limitCents = limit
            u.percent = min(Double(used) / Double(limit) * 100, 100)
        } else if let t = num(p["totalPercentUsed"]) {
            u.percent = t
        } else {
            return .err(L("返回里既没有包含额度上限也没有百分比", "The response has neither an included-usage limit nor a percentage"))
        }
        if let s = d["spendLimitUsage"] as? [String: Any], let lim = num(s["pooledLimit"]), lim > 0 {
            let pooledUsed = num(s["pooledUsed"]) ?? 0
            u.pooled = L("团队共享额度：\(dollars(Int(pooledUsed))) / \(dollars(Int(lim)))", "Team pooled usage: \(dollars(Int(pooledUsed))) / \(dollars(Int(lim)))")
        }
        if let info = try? await cursorRPC("GetPlanInfo", token: token), let pi = info["planInfo"] as? [String: Any] {
            let name = pi["planName"] as? String ?? ""
            let price = pi["price"] as? String ?? ""
            u.plan = price.isEmpty ? name : "\(name) \(price)"
            if u.cycleEnd == nil { u.cycleEnd = msDate(pi["billingCycleEnd"]) }
        }
        return .ok(u)
    } catch {
        return .err(describe(error))
    }
}
