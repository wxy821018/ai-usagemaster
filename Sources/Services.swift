// 通用"服务"接口：Claude、Cursor 之外的各家 AI 服务（Codex、Gemini、Kimi、Grok……）都实现 UsageService，
// 菜单按服务分组显示。没配置的服务不显示数字，只给出配置方法。

import Foundation

enum WindowKind: String { case session, weekly, monthly, daily, other }

struct ServiceWindow {
    var label: String            // 显示名，如 "5 小时窗口"、"每周"、"本月"
    var percent: Double?         // 已用百分比 0–100；未知为 nil
    var resetsAt: Date?          // 重置时间
    var kind: WindowKind
    var detail: String? = nil    // 附加说明，如 "$3.20 / $20.00"
}

struct ServiceAccount {
    var id: String               // 稳定标识（账号 id / 邮箱 / 配置目录）
    var title: String            // 显示名（邮箱、用户名或 "默认账号"）
    var plan: String? = nil      // 套餐名
    var windows: [ServiceWindow] = []
    var notes: [String] = []     // 其它信息行，如 "剩余重置额度 2 次"
    var updatedAt: Date? = nil
    var error: String? = nil
}

struct ServiceStatus {
    var id: String
    var displayName: String
    var configured: Bool          // 本机有可用凭据/登录
    var setupHint: String         // 没配置时告诉用户怎么配
    var accounts: [ServiceAccount] = []
}

protocol UsageService {
    var id: String { get }
    var displayName: String { get }
    /// 只检查本机有没有凭据/登录痕迹，不发网络请求，要快
    func isConfigured() -> Bool
    var setupHint: String { get }
    /// 取用量。未配置时返回 configured=false；出错写进 account.error，不要抛出
    func fetch() async -> ServiceStatus
}

/// 已接入的服务（各家实现放在 Service<Name>.swift，在这里登记）
var registeredServices: [UsageService] = [
    CodexService(), GeminiService(), AntigravityService(), KimiService(), GrokService(),
    ZCodeService(), OpenCodeGoService(), MiniMaxService(),
]
