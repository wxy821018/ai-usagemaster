// 菜单栏界面

import AppKit
import CryptoKit
import Foundation
import SQLite3

// MARK: - 菜单栏

/// 渲染时按"现在"重新判断窗口是否已经过了重置时间（抓取后过了重置点，就按 0% 显示）
func effective(_ w: UsageWindow, _ now: Date) -> (pct: Double, reset: Bool) {
    if w.wasReset { return (0, true) }
    if let r = w.resetsAt, r <= now { return (0, true) }
    return (w.percent, false)
}

func bindingWindow(_ a: ClaudeAccount, _ now: Date) -> UsageWindow? {
    if let w = a.windows.first(where: { $0.isActive && !effective($0, now).reset }) { return w }   // 服务端标出的那一行
    return a.windows.max(by: { effective($0, now).pct < effective($1, now).pct })
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    let menu = NSMenu()
    // 最近一次成功的数据与最近一次错误分开存：一次失败不冲掉已有数字
    var claude: [ClaudeAccount]?
    var claudeOKAt: Date?
    var claudeErr: String?
    var cursor: CursorUsage?
    var cursorOKAt: Date?
    var cursorErr: String?
    var services: [ServiceStatus] = []
    var orcaActive: String?
    var tokenStats: TokenStatsSummary?
    var tokenStatsRunning = false
    var switching = false
    var refreshAgain = false
    var refreshAgainForce = false
    var cursorConfigured = true
    var fetching = false
    var switchNote: String?
    var lastAutoSwitch: Date = .distantPast
    var lastSeen: [String: WindowSeen] = [:]
    var lastExtraKeys: [String: Set<String>] = [:]
    var notices: [OfficialNotice] = []
    var notifiedNoticeIds: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: "notifiedNotices") ?? []) }
        set { UserDefaults.standard.set(Array(newValue.suffix(200)), forKey: "notifiedNotices") }
    }
    /// 切换方式：true = 自动，false = 手动
    var autoSwitch: Bool {
        get { UserDefaults.standard.object(forKey: "autoSwitch") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "autoSwitch") }
    }
    /// 自动模式下手动点选的账号：用完之前不被"先用快重置的"规则换走
    var pinnedDir: String? {
        get { UserDefaults.standard.string(forKey: "pinnedDir") }
        set { UserDefaults.standard.set(newValue, forKey: "pinnedDir") }
    }
    var fetchStartedAt: Date?
    var retryDelay: TimeInterval = 15
    var retryPending = false
    let refreshEvery: TimeInterval = 120   // 拉数据间隔（秒）；倒计时另外每 30 秒本地重算
    let staleAfter: TimeInterval = 15 * 60

    func applicationDidFinishLaunching(_ n: Notification) {
        migrateLegacyAccounts()
        installEditMenu()
        AlertCenter.shared.setup()
        AlertCenter.shared.onSwitch = { [weak self] dir in self?.performSwitch(dir: dir) }
        item.autosaveName = "UsageMaster"
        item.button?.title = L("用量…", "Usage…")
        menu.delegate = self
        menu.autoenablesItems = false
        item.menu = menu
        refresh()
        // 加到 .common 模式：菜单展开时（eventTracking 模式）计时器也照常走
        let t1 = Timer(timeInterval: refreshEvery, repeats: true) { _ in Task { @MainActor in self.refresh() } }
        let t2 = Timer(timeInterval: 30, repeats: true) { _ in Task { @MainActor in self.tick() } }
        let t3 = Timer(timeInterval: 30 * 60, repeats: true) { _ in Task { @MainActor in self.checkNotices() } }
        RunLoop.main.add(t1, forMode: .common)
        RunLoop.main.add(t2, forMode: .common)
        RunLoop.main.add(t3, forMode: .common)
        let t4 = Timer(timeInterval: 10 * 60, repeats: true) { _ in Task { @MainActor in self.refreshTokenStatsInBackground() } }
        RunLoop.main.add(t4, forMode: .common)
        checkNotices()
        refreshTokenStatsInBackground()
        // 刚唤醒时网络往往还没连上：等 8 秒再刷
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 8) { Task { @MainActor in self.refresh() } }
        }
    }

    func refresh(force: Bool = false) {
        // 正在刷新时又来了请求（比如刚切换完账号）：记下来，这一轮结束后马上再刷一次，不能直接丢掉
        // 防卡死：上一轮超过 60 秒还没回来就当它丢了
        if fetching, let s = fetchStartedAt, Date().timeIntervalSince(s) < 60 {
            refreshAgain = true
            refreshAgainForce = refreshAgainForce || force
            return
        }
        fetching = true
        fetchStartedAt = Date()
        Task {
            let s = await fetchAll(force: force)
            switch s.claude {
            case .ok(let a): self.claude = a; self.claudeOKAt = s.at; self.claudeErr = nil
            case .err(let m): self.claudeErr = m
            case .notConfigured: self.claude = nil; self.claudeErr = L("没有登录 Claude Code", "Claude Code is not signed in")
            }
            switch s.cursor {
            case .ok(let u): self.cursor = u; self.cursorOKAt = s.at; self.cursorErr = nil
            case .err(let m): self.cursorErr = m
            case .notConfigured: self.cursor = nil; self.cursorErr = nil; self.cursorConfigured = false
            }
            if case .ok = s.cursor { self.cursorConfigured = true }
            self.services = s.services
            self.orcaActive = s.orcaActive
            self.fetching = false
            recordHistory(s)
            if self.refreshAgain {
                let f = self.refreshAgainForce
                self.refreshAgain = false
                self.refreshAgainForce = false
                self.refresh(force: f)
            }
            self.scheduleRetryIfNeeded()
            self.maybeAutoSwitch()
            if let a = self.claude, self.claudeErr == nil {
                AlertCenter.shared.process(accounts: a, cursor: self.cursorErr == nil ? self.cursor : nil, autoMode: self.autoSwitch)
            }
            self.renderTitle()
        }
    }

    /// 失败时按 15s → 30s → 60s 退避重试，成功后复位
    func scheduleRetryIfNeeded() {
        if claudeErr == nil && cursorErr == nil { retryDelay = 15; return }
        if retryPending { return }
        retryPending = true
        let d = retryDelay
        retryDelay = min(retryDelay * 2, 60)
        DispatchQueue.main.asyncAfter(deadline: .now() + d) {
            Task { @MainActor in self.retryPending = false; self.refresh() }
        }
    }

    /// 每 30 秒：重画标题；当前账号某个窗口刚过重置点、且上次抓取早于重置点 → 主动刷新拿新数字
    func tick() {
        let now = Date()
        if let a = claude?.first(where: { $0.active }), let ok = claudeOKAt,
           a.windows.contains(where: { if let r = $0.resetsAt { return r <= now && ok < r } else { return false } }) {
            refresh()
        }
        renderTitle()
    }

    func color(_ w: UsageWindow) -> NSColor {
        switch severityLevel(w) { case 2: return .systemRed; case 1: return .systemOrange; default: return .labelColor }
    }

    func color(_ pct: Double) -> NSColor {
        pct >= 90 ? .systemRed : (pct >= 75 ? .systemOrange : .labelColor)
    }

    // 菜单栏标题：FF 90%·2h45  个人 7%w  OP 100%w │ Cu 61%
    func renderTitle() {
        let now = Date()
        let title = NSMutableAttributedString()
        let font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        func add(_ s: String, _ c: NSColor = .labelColor) {
            title.append(NSAttributedString(string: s, attributes: [.font: font, .foregroundColor: c]))
        }
        let claudeStale = claudeOKAt.map { now.timeIntervalSince($0) > staleAfter } ?? true
        if let accounts = claude {
            for (i, a) in accounts.enumerated() {
                if i > 0 { add("  ") }
                add("\(a.active && accounts.count > 1 ? "●" : "")\(a.label) ", claudeStale ? .secondaryLabelColor : .labelColor)
                if let w = bindingWindow(a, now) {
                    let (pct, _) = effective(w, now)
                    add("\(Int(pct.rounded()))%", claudeStale ? .secondaryLabelColor : color(w))
                    if isWeeklyWindow(w) && pct > 0 { add("w") }
                    if (a.active || accounts.count == 1 || pct >= 50), !claudeStale {
                        let cd = shortCountdown(w.resetsAt, now: now)
                        if !cd.isEmpty && pct > 0 { add("·\(cd)") }
                    }
                } else { add("—") }
            }
        } else if claudeErr != nil { add("Claude ⚠︎", .systemOrange) } else { add("Claude …") }
        if cursorConfigured {
            add("  │  ")
            let cursorStale = cursorOKAt.map { now.timeIntervalSince($0) > staleAfter } ?? true
            if let u = cursor {
                add("Cu ", cursorStale ? .secondaryLabelColor : .labelColor)
                add("\(Int(u.percent.rounded()))%", cursorStale ? .secondaryLabelColor : color(u.percent))
            } else if cursorErr != nil { add("Cu ⚠︎", .systemOrange) } else { add("Cu …") }
        }
        // 其它已配置的服务：只显示最紧的那个窗口
        for s in services {
            let ws = s.accounts.filter { $0.error == nil }.flatMap { $0.windows }.filter { $0.percent != nil }
            guard let w = ws.max(by: { ($0.percent ?? 0) < ($1.percent ?? 0) }), let pct = w.percent else { continue }
            add("  \(serviceShortName(s.id)) ")
            add("\(Int(pct.rounded()))%", color(pct))
        }
        item.button?.attributedTitle = title
    }

    // 菜单打开前才重建内容（不在菜单展开时替换它）
    func menuNeedsUpdate(_ menu: NSMenu) {
        let now = Date()
        menu.removeAllItems()
        func header(_ s: String) {
            let mi = NSMenuItem(title: s, action: nil, keyEquivalent: "")
            mi.attributedTitle = NSAttributedString(string: s, attributes: [.font: NSFont.boldSystemFont(ofSize: 13)])
            mi.isEnabled = false
            menu.addItem(mi)
        }
        func line(_ s: String, _ c: NSColor = .labelColor, small: Bool = false) {
            let mi = NSMenuItem(title: s, action: nil, keyEquivalent: "")
            mi.attributedTitle = NSAttributedString(string: s, attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: small ? 11 : 12, weight: .regular),
                .foregroundColor: small ? NSColor.secondaryLabelColor : c])
            mi.isEnabled = true
            menu.addItem(mi)
        }

        for n in notices {
            let mi = NSMenuItem(title: "", action: #selector(openNotice(_:)), keyEquivalent: "")
            let when = n.date.map { clockFmt.string(from: $0) } ?? ""
            mi.attributedTitle = NSAttributedString(string: L("📢 官方公告 \(when)：\(n.title)", "📢 Official notice \(when): \(n.title)"), attributes: [
                .font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.systemBlue])
            mi.target = self
            mi.representedObject = n.url
            menu.addItem(mi)
        }
        if !removedDuplicates.isEmpty {
            line(L("  已自动移除重复添加的账号：", "  Removed duplicate accounts: ") + removedDuplicates.joined(separator: listSep), .secondaryLabelColor, small: true)
        }
        if let note = switchNote { line("  \(note)", .secondaryLabelColor, small: true) }
        // Orca 选了账号时，它每次查用量、开会话前都会把那个账号写回 Claude Code 的默认登录：这里切了也会被改回去
        if let o = orcaActive {
            let oLabel = claude?.first(where: { $0.email.lowercased() == o })?.label ?? o
            line(L("  ⓘ Orca 正在管理 Claude 账号（选中 \(oLabel)），它会把这里的切换改回去，所以这里暂停切换：请在 Orca 里切",
                   "  ⓘ Orca is managing Claude accounts (\(oLabel) selected) and would undo a switch made here, so switching is paused here; switch in Orca"),
                 .secondaryLabelColor, small: true)
        }
        if let e = claudeErr {
            header("Claude")
            line(L("  ⚠︎ 最近一次刷新失败：", "  ⚠︎ Last refresh failed: ") + e + (claude == nil ? "" : staleSuffix(claudeOKAt, now)), .systemOrange)
        }
        if let accounts = claude {
            for (i, a) in accounts.enumerated() {
                if i > 0 || claudeErr != nil { menu.addItem(.separator()) }
                let hi = NSMenuItem(title: "", action: a.active ? nil : #selector(switchTo(_:)), keyEquivalent: "")
                let ht = a.active ? "● Claude · \(a.label)  \(a.email)   " + L("使用中", "in use")
                    : "○ Claude · \(a.label)  \(a.email)   " + (a.needsLogin || a.sharedWithOrca ? L("需要重新登录", "needs sign-in")
                        : (orcaActive != nil ? L("在 Orca 里切换", "switch in Orca") : L("点此切换", "click to switch")))
                hi.attributedTitle = NSAttributedString(string: ht, attributes: [.font: NSFont.boldSystemFont(ofSize: 13)])
                hi.target = self
                hi.representedObject = a.configDir
                hi.isEnabled = !a.active && a.configDir != nil && !a.needsLogin && !a.sharedWithOrca && !switching && orcaActive == nil
                menu.addItem(hi)
                if !a.org.isEmpty || a.plan != nil { line("  " + [a.org, a.plan ?? ""].filter { !$0.isEmpty }.joined(separator: " · "), small: true) }
                for n in a.notes { line("  \(n)", small: true) }
                if let e = a.error { line("  ⚠︎ \(e)", .systemOrange) }
                if let w = a.warning, a.error == nil { line("  ⚠︎ \(w)" + staleSuffix(a.updatedAt, now), .secondaryLabelColor, small: true) }
                if a.needsLogin || a.sharedWithOrca, let dir = a.configDir {
                    let mi = NSMenuItem(title: L("  重新登录 \(a.label)…", "  Sign in to \(a.label) again…"), action: #selector(relogin(_:)), keyEquivalent: "")
                    mi.target = self
                    mi.representedObject = dir
                    menu.addItem(mi)
                }
                for w in a.windows {
                    let (pct, reset) = effective(w, now)
                    let when = w.resetsAt.map { clockFmt.string(from: $0) } ?? "—"
                    let tail = w.resetsAt == nil ? L("未开始计时", "not started") : (reset ? L("\(when) 已重置（等新数据）", "reset at \(when) (waiting for new data)") : L("\(when) 重置（还有 \(countdown(w.resetsAt, now: now))）", "resets \(when) (in \(countdown(w.resetsAt, now: now)))"))
                    line("  \(w.label)", .labelColor)
                    line("    \(bar(pct)) \(Int(pct.rounded()))%   \(tail)", reset ? .labelColor : color(w))
                    if let pj = projectionText(a, w, now) { line("    ⏱ \(pj)", .secondaryLabelColor, small: true) }
                    else if let pw = paceWarning(w, now: now) { line("    ⚡ \(pw.text)", .systemOrange, small: true) }
                }
                let src = L("  数据：\(ago(a.updatedAt, now: now))", "  Data: \(ago(a.updatedAt, now: now))")
                line(src, small: true)
            }
        } else if claudeErr == nil {
            header("Claude")
            line(L("  读取中…", "  Loading…"))
        }

        if cursorConfigured {
        menu.addItem(.separator())
        header("Cursor\(cursor?.plan.map { " · \($0)" } ?? "")")
        if let e = cursorErr {
            line(L("  ⚠︎ 最近一次刷新失败：", "  ⚠︎ Last refresh failed: ") + e + (cursor == nil ? "" : staleSuffix(cursorOKAt, now)), .systemOrange)
        }
        if let u = cursor {
            if let used = u.usedCents, let limit = u.limitCents {
                line(L("  本期包含额度：\(dollars(used)) / \(dollars(limit))", "  Included this cycle: \(dollars(used)) / \(dollars(limit))"))
            }
            line("    \(bar(u.percent)) \(Int(u.percent.rounded()))%", color(u.percent))
            let when = u.cycleEnd.map { clockFmt.string(from: $0) } ?? "—"
            line(L("  账单周期 \(when) 重置（还有 \(countdown(u.cycleEnd, now: now))）", "  Billing cycle resets \(when) (in \(countdown(u.cycleEnd, now: now)))"))
            if let pooled = u.pooled { line("  \(pooled)") }
            if u.source != "direct" { line(L("  数据：", "  Data: ") + u.source, small: true) }
        } else if cursorErr == nil {
            line(L("  读取中…", "  Loading…"))
        }
        }

        // 其它 AI 服务
        for s in services {
            menu.addItem(.separator())
            header(s.displayName)
            if s.accounts.isEmpty { line(L("  读取中…", "  Loading…")) }
            for a in s.accounts {
                line("  " + [a.title, a.plan ?? ""].filter { !$0.isEmpty }.joined(separator: " · "), small: true)
                for n in a.notes { line("  \(n)", small: true) }
                if let e = a.error { line("  ⚠︎ \(e)", .systemOrange) }
                for w in a.windows {
                    let tail: String
                    if let r = w.resetsAt {
                        tail = r <= now ? L("\(clockFmt.string(from: r)) 已重置（等新数据）", "reset at \(clockFmt.string(from: r)) (waiting for new data)")
                                        : L("\(clockFmt.string(from: r)) 重置（还有 \(countdown(r, now: now))）", "resets \(clockFmt.string(from: r)) (in \(countdown(r, now: now)))")
                    } else { tail = "" }
                    line("  \(w.label)" + (w.detail.map { "  \($0)" } ?? ""), .labelColor)
                    if let pct = w.percent {
                        line("    \(bar(pct)) \(Int(pct.rounded()))%   \(tail)", color(pct))
                    } else if !tail.isEmpty { line("    \(tail)", small: true) }
                }
                if let u = a.updatedAt { line(L("  数据：", "  Data: ") + ago(u, now: now), small: true) }
            }
            if apiKeyServices.contains(s.id) && hasServiceAPIKey(s.id) {
                let k = NSMenuItem(title: L("  更换 API Key…", "  Replace API Key…"), action: #selector(enterAPIKey(_:)), keyEquivalent: "")
                k.target = self; k.representedObject = s.id
                menu.addItem(k)
                let d = NSMenuItem(title: L("  删除 API Key…", "  Remove API Key…"), action: #selector(removeAPIKey(_:)), keyEquivalent: "")
                d.target = self; d.representedObject = s.id
                menu.addItem(d)
            }
        }
        let unconfigured = registeredServices.filter { !$0.isConfigured() }
        if !unconfigured.isEmpty {
            menu.addItem(.separator())
            let more = NSMenuItem(title: L("其他 AI 服务（未配置）", "Other AI Services (not set up)"), action: nil, keyEquivalent: "")
            let sub = NSMenu()
            for s in unconfigured {
                let si = NSMenuItem(title: s.displayName, action: nil, keyEquivalent: "")
                let hint = NSMenu()
                for l in wrapForMenu(s.setupHint) {
                    let mi = NSMenuItem(title: l, action: nil, keyEquivalent: "")
                    mi.isEnabled = false
                    hint.addItem(mi)
                }
                if apiKeyServices.contains(s.id) {
                    hint.addItem(.separator())
                    let k = NSMenuItem(title: L("填写 API Key…", "Enter API Key…"), action: #selector(enterAPIKey(_:)), keyEquivalent: "")
                    k.target = self
                    k.representedObject = s.id
                    hint.addItem(k)
                }
                si.submenu = hint
                sub.addItem(si)
            }
            more.submenu = sub
            menu.addItem(more)
        }

        // 费用（按 API 价折算）
        menu.addItem(.separator())
        header(L("费用（本机 Claude Code 日志，按 API 价折算）", "Cost (this Mac's Claude Code logs at API prices)"))
        if let s = tokenStats {
            line(L("  今天 \(usd(s.today.costUSD)) · 本月 \(usd(s.thisMonth.costUSD)) · 最近 30 天 \(usd(s.last30Days.costUSD))",
                   "  Today \(usd(s.today.costUSD)) · this month \(usd(s.thisMonth.costUSD)) · last 30 days \(usd(s.last30Days.costUSD))"))
            let sv = tokenSavings(s, subscriptions: loadTokenSubscriptions(), period: .thisMonth)
            if sv.hasSubscriptions {
                line(L("  本月订阅费 \(usd(sv.subscriptionUSD))（按天折算），相当于省下 \(usd(sv.savedUSD))",
                       "  Subscriptions this month \(usd(sv.subscriptionUSD)) (prorated), about \(usd(sv.savedUSD)) saved"))
            }
            let top = s.byProjectThisMonth.prefix(3).map { "\($0.name) \(usd($0.thisMonth.costUSD))" }
            if !top.isEmpty { line(L("  本月最多：", "  Top this month: ") + top.joined(separator: " · "), small: true) }
        } else {
            line(tokenStatsRunning ? L("  统计中…（第一次要扫一遍日志，几秒钟）", "  Counting… (the first scan reads all logs, a few seconds)")
                                   : L("  还没有数据", "  No data yet"), small: true)
        }
        let rep = NSMenuItem(title: L("打开费用与项目报告…", "Open Cost and Project Report…"), action: #selector(openCostReport), keyEquivalent: "")
        rep.target = self
        rep.isEnabled = tokenStats != nil
        menu.addItem(rep)
        let subs = NSMenuItem(title: L("填写订阅月费…（用来算省了多少）", "Set Subscription Prices… (for savings)"), action: #selector(editSubscriptions), keyEquivalent: "")
        subs.target = self
        menu.addItem(subs)

        menu.addItem(.separator())
        let last = [claudeOKAt, cursorOKAt].compactMap { $0 }.max()
        let status = fetching ? L("刷新中…", "Refreshing…") : (last.map { L("更新于 ", "Updated ") + clockFmt.string(from: $0) } ?? L("尚未更新", "Not updated yet"))
        let upd = NSMenuItem(title: status, action: nil, keyEquivalent: "")
        upd.isEnabled = false
        menu.addItem(upd)
        let r = NSMenuItem(title: L("立即刷新", "Refresh Now"), action: #selector(refreshNow), keyEquivalent: "r")
        r.target = self
        r.isEnabled = !fetching
        menu.addItem(r)
        let modeHeader = NSMenuItem(title: L("Claude 账号切换方式", "Claude account switching"), action: nil, keyEquivalent: "")
        modeHeader.isEnabled = false
        menu.addItem(modeHeader)
        let au = NSMenuItem(title: L("  自动：用完就切，先用快重置的", "  Automatic: switch when one runs out, use the soonest-expiring first"), action: #selector(setAutoMode), keyEquivalent: "")
        au.target = self
        au.state = autoSwitch ? .on : .off
        menu.addItem(au)
        let ma = NSMenuItem(title: L("  手动：点哪个账号就用哪个", "  Manual: use whichever account you click"), action: #selector(setManualMode), keyEquivalent: "")
        ma.target = self
        ma.state = autoSwitch ? .off : .on
        menu.addItem(ma)
        menu.addItem(withTitle: L("添加 Claude 账号…", "Add Claude Account…"), action: #selector(addAccount), keyEquivalent: "").target = self
        let sl = NSMenuItem(title: L("在 Claude Code 状态栏显示用量", "Show Usage in Claude Code Status Line"), action: #selector(toggleStatusLine), keyEquivalent: "")
        sl.target = self
        sl.state = statusLineInstalled() ? .on : .off
        menu.addItem(sl)
        let alertsItem = NSMenuItem(title: L("提醒", "Notifications"), action: nil, keyEquivalent: "")
        let sub = NSMenu()
        for type in AlertType.allCases {
            let mi = NSMenuItem(title: type.menuTitle, action: #selector(toggleAlert(_:)), keyEquivalent: "")
            mi.target = self
            mi.representedObject = type.rawValue
            mi.state = type.enabled ? .on : .off
            sub.addItem(mi)
        }
        sub.addItem(.separator())
        sub.addItem(withTitle: L("发一条测试提醒", "Send a Test Notification"), action: #selector(testAlert), keyEquivalent: "").target = self
        alertsItem.submenu = sub
        menu.addItem(alertsItem)
        menu.addItem(withTitle: L("打开 Claude 用量页", "Open Claude Usage Page"), action: #selector(openClaude), keyEquivalent: "").target = self
        if cursorConfigured {
            menu.addItem(withTitle: L("打开 Cursor 用量页", "Open Cursor Usage Page"), action: #selector(openCursor), keyEquivalent: "").target = self
        }
        menu.addItem(.separator())
        menu.addItem(withTitle: L("退出", "Quit"), action: #selector(quit), keyEquivalent: "q").target = self
    }

    /// "（下面是 5 分钟前的数据）"
    func staleSuffix(_ d: Date?, _ now: Date) -> String {
        L("（下面是 \(ago(d, now: now)) 的数据）", " (showing data from \(ago(d, now: now)))")
    }

    /// 本机 Claude Code 日志 → token、折合 API 费用、各项目用量（第一次全量扫描几秒，之后增量）
    func refreshTokenStatsInBackground() {
        guard !tokenStatsRunning else { return }
        tokenStatsRunning = true
        Task {
            let s = await refreshTokenStats(progress: nil)
            self.tokenStats = s
            self.tokenStatsRunning = false
        }
    }

    func applicationWillTerminate(_ n: Notification) { flushTokenStatsCache() }

    /// 菜单栏程序默认没有"编辑"菜单，弹窗里的 ⌘V / ⌘C / ⌘A 就不起作用：补一个不显示的编辑菜单
    func installEditMenu() {
        let main = NSMenu()
        let editItem = NSMenuItem()
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        main.addItem(editItem)
        NSApp.mainMenu = main
    }

    @objc func openCostReport() {
        guard let s = tokenStats else { return }
        let url = writeCostReport(s, subscriptions: loadTokenSubscriptions())
        NSWorkspace.shared.open(url)
    }

    @objc func editSubscriptions() {
        _ = loadTokenSubscriptions()          // 文件不存在时先写一份示例
        NSWorkspace.shared.open(URL(fileURLWithPath: tokenSubscriptionsPath))
    }

    @objc func refreshNow() { refresh(force: true); checkNotices() }
    @objc func openNotice(_ sender: NSMenuItem) {
        if let s = sender.representedObject as? String, let u = URL(string: s) { NSWorkspace.shared.open(u) }
    }

    func checkNotices() {
        Task {
            let found = await fetchOfficialNotices()
            self.notices = found
            var done = self.notifiedNoticeIds
            for n in found where !done.contains(n.id) {
                AlertCenter.shared.post(.resets, L("Claude 官方公告（可能涉及额度重置）", "Claude status notice (may involve a usage reset)"), n.title)
                done.insert(n.id)
            }
            self.notifiedNoticeIds = done
            if !found.isEmpty { self.lastAutoSwitch = .distantPast }   // 有公告：下一轮立即重新判断
        }
    }

    func maybeAutoSwitch() {
        guard let accounts = claude, claudeErr == nil else { return }
        let (events, seen) = detectEarlyResets(previous: lastSeen, accounts: accounts, now: Date())
        lastSeen = seen
        for ev in events { AlertCenter.shared.post(.resets, L("额度提前重置了", "Usage reset early"), ev); switchNote = ev }
        // 用量返回里第一次出现新的额度项（官方活动 / 临时额度 / 重置额度的信号）
        for a in accounts where a.error == nil {
            let now = Set(a.extraKeys)
            if let before = lastExtraKeys[a.ident] {
                let added = now.subtracting(before)
                if !added.isEmpty {
                    let items = added.sorted().joined(separator: listSep)
                    let msg = L("\(a.label) 的用量数据里出现新的额度项：\(items)（可能是官方活动或重置）", "New quota items in \(a.label)'s usage data: \(items) (possibly a promotion or a reset)")
                    AlertCenter.shared.post(.resets, L("Claude 额度有变化", "Claude quota changed"), msg)
                    switchNote = msg
                }
            }
            lastExtraKeys[a.ident] = now
        }
        guard autoSwitch, !events.isEmpty || Date().timeIntervalSince(lastAutoSwitch) > 15 * 60 else { return }
        guard orcaActive == nil else { return }       // Orca 在管账号：自动切换暂停，免得和它来回拉锯
        let d = decideAutoSwitch(accounts, now: Date(), pinnedDir: pinnedDir)
        guard let dir = d.target else { return }
        pinnedDir = nil
        let all = listManagedAccounts()
        guard let x = all.first(where: { $0.dir == dir }) else { return }
        lastAutoSwitch = Date()
        guard !switching else { return }
        switching = true
        Task {
            let err = await switchDefaultSafely(to: x, all: all)
            self.switching = false
            if let err = err {
                self.switchNote = L("自动切换失败：\(err)", "Automatic switch failed: \(err)")
            } else {
                self.markActive(dir: x.dir)
                self.switchNote = L("自动切换：\(d.reason)（\(clockFmt.string(from: Date()))）", "Automatic switch: \(d.reason) (\(clockFmt.string(from: Date())))")
                AlertCenter.shared.post(.switched, L("已自动切换 Claude 账号", "Switched Claude accounts automatically"), d.reason)
                self.refresh()
            }
        }
    }

    @objc func setAutoMode() {
        autoSwitch = true; pinnedDir = nil; lastAutoSwitch = .distantPast
        switchNote = L("切换方式：自动", "Switching: automatic")
        maybeAutoSwitch()
    }
    @objc func setManualMode() { autoSwitch = false; pinnedDir = nil; switchNote = L("切换方式：手动（不会自动换账号）", "Switching: manual (never switches on its own)") }
    @objc func switchTo(_ sender: NSMenuItem) {
        if let dir = sender.representedObject as? String { performSwitch(dir: dir) }
    }

    /// 切换成功后立刻在本地把"使用中"标到新账号上并重画菜单栏，不用等下一轮刷新回来
    func markActive(dir: String) {
        guard var a = claude else { return }
        for i in a.indices { a[i].active = a[i].configDir == dir }
        claude = a
        renderTitle()
    }

    /// 手动切换（菜单里点账号、或点了建议切换的通知）
    func performSwitch(dir: String) {
        let all = listManagedAccounts()
        guard let x = all.first(where: { $0.dir == dir }), !switching else { return }
        if orcaActive != nil {
            switchNote = L("Orca 正在管理 Claude 账号，这里切了会被它改回去：请在 Orca 里切换", "Orca is managing Claude accounts and would undo this; switch in Orca")
            return
        }
        if let a = claude?.first(where: { $0.configDir == dir }), a.sharedWithOrca {
            switchNote = sharedWithOrcaMessage
            return
        }
        if let a = claude?.first(where: { $0.configDir == dir }), a.needsLogin {
            switchNote = L("\(a.label) 需要重新登录，先在菜单里重新登录它再切换", "\(a.label) needs to sign in again; do that from the menu first")
            return
        }
        switching = true
        switchNote = L("切换中…", "Switching…")
        Task {
            let err = await switchDefaultSafely(to: x, all: all)
            self.switching = false
            if let err = err {
                self.switchNote = L("切换失败：\(err)", "Switch failed: \(err)")
            } else {
                self.markActive(dir: x.dir)
                if self.autoSwitch { self.pinnedDir = x.dir }
                let who = x.email ?? ""
                self.switchNote = L("已切换到 \(who)：新开的 claude 会话直接用它，已经开着的会话下一次请求时跟着换（最多约 30 秒）",
                                    "Switched to \(who). New claude sessions use it, and open sessions follow on their next request (within about 30 seconds)")
                    + (self.autoSwitch ? L("。自动模式：它用完前不会被自动换走", ". Automatic mode: it stays until it runs out") : "")
            }
            self.refresh(force: true)
        }
    }
    @objc func toggleAlert(_ sender: NSMenuItem) {
        if let raw = sender.representedObject as? String, let type = AlertType(rawValue: raw) { type.enabled.toggle() }
    }
    @objc func testAlert() { AlertCenter.shared.sendTest() }

    @objc func removeAPIKey(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String,
              let s = registeredServices.first(where: { $0.id == id }) else { return }
        let alert = NSAlert()
        alert.messageText = L("删除 \(s.displayName) 的 API Key？", "Remove the \(s.displayName) API key?")
        alert.informativeText = L("只删 AI UsageMaster 自己存的那份，不影响 \(s.displayName) 本身。", "Only AI UsageMaster's own copy is removed; \(s.displayName) itself is not affected.")
        alert.addButton(withTitle: L("删除", "Remove"))
        alert.addButton(withTitle: L("取消", "Cancel"))
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        deleteServiceAPIKey(service: id)
        switchNote = L("已删除 \(s.displayName) 的 API Key", "Removed the \(s.displayName) API key")
        refresh(force: true)
    }

    /// 用 API Key 查用量的服务：在弹窗里输入（安全输入框），存进钥匙串
    @objc func enterAPIKey(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String,
              let s = registeredServices.first(where: { $0.id == id }) else { return }
        let alert = NSAlert()
        alert.messageText = L("填写 \(s.displayName) 的 API Key", "\(s.displayName) API key")
        alert.informativeText = L("只存进本机钥匙串，只发给 \(s.displayName) 自己的接口。", "Stored only in your Keychain and sent only to \(s.displayName)'s own API.")
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        var regionPopup: NSPopUpButton?
        if id == "minimax" {
            // MiniMax 国际版与国内版是两套账号体系，key 只在自己那边有效
            let box = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 56))
            field.frame.origin.y = 32
            let pop = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 320, height: 26), pullsDown: false)
            pop.addItems(withTitles: [L("国际版（platform.minimax.io）", "International (platform.minimax.io)"),
                                      L("国内版（platform.minimaxi.com）", "China (platform.minimaxi.com)")])
            pop.selectItem(at: storedServiceRegion("minimax") == "cn" ? 1 : 0)
            box.addSubview(field)
            box.addSubview(pop)
            regionPopup = pop
            alert.accessoryView = box
        } else {
            alert.accessoryView = field
        }
        alert.addButton(withTitle: L("保存", "Save"))
        alert.addButton(withTitle: L("取消", "Cancel"))
        NSApp.activate(ignoringOtherApps: true)
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let key = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        let region: String? = regionPopup.map { $0.indexOfSelectedItem == 1 ? "cn" : "global" }
        switchNote = saveServiceAPIKey(service: id, apiKey: key, region: region)
            ? L("已保存 \(s.displayName) 的 API Key", "Saved the \(s.displayName) API key")
            : L("保存 \(s.displayName) 的 API Key 失败", "Could not save the \(s.displayName) API key")
        refresh(force: true)
    }
    @objc func toggleStatusLine() {
        switchNote = statusLineInstalled() ? uninstallStatusLine() : installStatusLine()
    }
    @objc func addAccount() {
        let name = "acct-" + String(Int(Date().timeIntervalSince1970))
        try? FileManager.default.createDirectory(atPath: accountsRoot + "/" + name, withIntermediateDirectories: true)
        openLoginTerminal(configDir: accountsRoot + "/" + name)
    }
    @objc func relogin(_ sender: NSMenuItem) {
        if let dir = sender.representedObject as? String { openLoginTerminal(configDir: dir) }
    }
    @objc func openClaude() { NSWorkspace.shared.open(URL(string: "https://claude.ai/settings/usage")!) }
    @objc func openCursor() { NSWorkspace.shared.open(URL(string: "https://cursor.com/dashboard?tab=usage")!) }
    @objc func quit() { NSApp.terminate(nil) }
}

// 命令行模式：AIUsageMaster --print  拉一次数据，把菜单里的内容打印到终端后退出（不含任何令牌）
// 自检：AIUsageMaster --selftest  用构造数据验证自动切换规则

/// 菜单栏上各服务的简写
func serviceShortName(_ id: String) -> String {
    ["codex": "Cx", "gemini": "Gm", "antigravity": "Ag", "kimi": "Ki", "grok": "Gk", "zcode": "Zc", "opencode-go": "Oc", "minimax": "Mm"][id] ?? String(id.prefix(2)).capitalized
}

/// 需要在菜单里填 API Key 才能用的服务
let apiKeyServices: Set<String> = ["minimax", "opencode-go"]

/// 长说明在菜单里按句子断行（中文按 ；。，英文按 ; . 之后的空格），每行不超过约 width 个字符
func wrapForMenu(_ s: String, width: Int = 56) -> [String] {
    var pieces: [String] = []
    var cur = ""
    for ch in s {
        cur.append(ch)
        if "；。;\n".contains(ch) || (ch == " " && (cur.hasSuffix(". ") || cur.hasSuffix("; "))) {
            pieces.append(cur.trimmingCharacters(in: .whitespacesAndNewlines)); cur = ""
        }
    }
    if !cur.trimmingCharacters(in: .whitespaces).isEmpty { pieces.append(cur.trimmingCharacters(in: .whitespaces)) }
    var lines: [String] = []
    for p in pieces where !p.isEmpty {
        var rest = Substring(p)
        while rest.count > width {
            // 优先在空格或中文逗号处断开
            let head = rest.prefix(width)
            let cut = head.lastIndex(where: { $0 == " " || $0 == "，" || $0 == "," }).map { rest.index(after: $0) } ?? head.endIndex
            lines.append(String(rest[..<cut]).trimmingCharacters(in: .whitespaces))
            rest = rest[cut...]
        }
        if !rest.isEmpty { lines.append(String(rest).trimmingCharacters(in: .whitespaces)) }
    }
    return lines
}

/// 每轮数据写进用量历史（时间用数据本身的时间：没重新查的账号不会被重复记成新读数）
func recordHistory(_ s: Snapshot) {
    var e: [HistoryEntry] = []
    if case .ok(let accts) = s.claude { for a in accts { e += historyEntries(claude: [a], at: a.updatedAt ?? s.at) } }
    if case .ok(let u) = s.cursor { e += historyEntries(cursor: u, at: s.at) }
    for st in s.services { e += historyEntries(service: st, at: st.accounts.compactMap { $0.updatedAt }.max() ?? s.at) }
    guard !e.isEmpty else { return }
    DispatchQueue.global(qos: .utility).async { recordSnapshot(entries: e) }
}

/// 按最近 90 分钟的实际消耗速度推算：在用账号总是显示；其它账号只在重置前会用完时显示
func projectionText(_ a: ClaudeAccount, _ w: UsageWindow, _ now: Date) -> String? {
    let (pct, reset) = effective(w, now)
    guard !reset, pct < 99,
          let rate = burnRate(service: "claude", account: historyClaudeAccountID(a), window: historyWindowID(w), now: now),
          rate >= 0.1 else { return nil }
    let r = String(format: "%.1f", rate)
    if let t = projectedExhaustion(currentPercent: pct, rate: rate, resetsAt: w.resetsAt, now: now) {
        return L("按最近的速度（每小时 +\(r)%），约 \(clockFmt.string(from: t)) 用完（还有 \(countdown(t, now: now))）",
                 "At the recent pace (+\(r)% per hour) it runs out around \(clockFmt.string(from: t)) (in \(countdown(t, now: now)))")
    }
    return a.active ? L("按最近的速度（每小时 +\(r)%），重置前用不完", "At the recent pace (+\(r)% per hour) it lasts until the reset") : nil
}

/// 金额：≥1000 带千位分隔，不带小数；负数写成 -$5.00
func usd(_ v: Double) -> String {
    if v < 0 { return "-" + usd(-v) }
    if abs(v) >= 1000 {
        let f = NumberFormatter(); f.numberStyle = .decimal; f.maximumFractionDigits = 0; f.locale = Locale(identifier: "en_US")
        return "$" + (f.string(from: NSNumber(value: v)) ?? String(format: "%.0f", v))
    }
    return String(format: "$%.2f", v)
}
