// 官方公告（状态页）

import AppKit
import CryptoKit
import Foundation
import SQLite3

// MARK: - 官方公告（状态页）

struct OfficialNotice { let id: String; let title: String; let date: Date?; let url: String; let body: String }

/// 读 Claude 官方状态页（Statuspage 公开接口，无需登录），挑出提到重置 / 用量限制的公告
func fetchOfficialNotices() async -> [OfficialNotice] {
    guard let url = URL(string: "https://status.claude.com/api/v2/incidents.json"),
          let (data, resp) = try? await session.data(from: url),
          (resp as? HTTPURLResponse)?.statusCode == 200,
          let d = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let incidents = d["incidents"] as? [[String: Any]] else { return [] }
    let pattern = #"(?i)\b(reset|resets|usage limits?|rate limits?|weekly limits?|session limits?|limits? (have been|were) (reset|restored|raised))\b|额度|重置"#
    var out: [OfficialNotice] = []
    for inc in incidents {
        let title = inc["name"] as? String ?? ""
        let updates = inc["incident_updates"] as? [[String: Any]] ?? []
        let body = updates.compactMap { $0["body"] as? String }.joined(separator: " ")
        guard (title + " " + body).range(of: pattern, options: .regularExpression) != nil else { continue }
        let date = parseISO(inc["created_at"])
        if let dt = date, Date().timeIntervalSince(dt) > 7 * 86400 { continue }   // 只看最近 7 天
        out.append(OfficialNotice(id: inc["id"] as? String ?? title, title: title, date: date,
                                  url: inc["shortlink"] as? String ?? "https://status.claude.com",
                                  body: String(body.prefix(200))))
    }
    return out
}
