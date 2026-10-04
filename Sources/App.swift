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
    a.windows.max(by: { effective($0, now).pct < effective($1, now).pct })
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
        item.autosaveName = "UsageMaster"
        item.button?.title = "用量…"
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
        checkNotices()
        // 刚唤醒时网络往往还没连上：等 8 秒再刷
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 8) { Task { @MainActor in self.refresh() } }
        }
    }

    func refresh() {
        // 防卡死：上一轮超过 60 秒还没回来就当它丢了
        if fetching, let s = fetchStartedAt, Date().timeIntervalSince(s) < 60 { return }
        fetching = true
        fetchStartedAt = Date()
        Task {
            let s = await fetchAll()
            switch s.claude {
            case .ok(let a): self.claude = a; self.claudeOKAt = s.at; self.claudeErr = nil
            case .err(let m): self.claudeErr = m
            }
            switch s.cursor {
            case .ok(let u): self.cursor = u; self.cursorOKAt = s.at; self.cursorErr = nil
            case .err(let m): self.cursorErr = m
            }
            self.fetching = false
            self.scheduleRetryIfNeeded()
            self.maybeAutoSwitch()
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
                    add("\(Int(pct.rounded()))%", claudeStale ? .secondaryLabelColor : color(pct))
                    if w.label.hasPrefix("每周") && pct > 0 { add("w") }
                    if (a.active || accounts.count == 1 || pct >= 50), !claudeStale {
                        let cd = shortCountdown(w.resetsAt, now: now)
                        if !cd.isEmpty && pct > 0 { add("·\(cd)") }
                    }
                } else { add("—") }
            }
        } else if claudeErr != nil { add("Claude ⚠︎", .systemOrange) } else { add("Claude …") }
        add("  │  ")
        let cursorStale = cursorOKAt.map { now.timeIntervalSince($0) > staleAfter } ?? true
        if let u = cursor {
            add("Cu ", cursorStale ? .secondaryLabelColor : .labelColor)
            add("\(Int(u.percent.rounded()))%", cursorStale ? .secondaryLabelColor : color(u.percent))
        } else if cursorErr != nil { add("Cu ⚠︎", .systemOrange) } else { add("Cu …") }
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
            mi.attributedTitle = NSAttributedString(string: "📢 官方公告 \(when)：\(n.title)", attributes: [
                .font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.systemBlue])
            mi.target = self
            mi.representedObject = n.url
            menu.addItem(mi)
        }
        if !removedDuplicates.isEmpty {
            line("  已自动移除重复添加的账号：\(removedDuplicates.joined(separator: "、"))", .secondaryLabelColor, small: true)
        }
        if let note = switchNote { line("  \(note)", .secondaryLabelColor, small: true) }
        if let e = claudeErr {
            header("Claude")
            line("  ⚠︎ 最近一次刷新失败：\(e)\(claude == nil ? "" : "（下面是 \(ago(claudeOKAt, now: now)) 的数据）")", .systemOrange)
        }
        if let accounts = claude {
            for (i, a) in accounts.enumerated() {
                if i > 0 || claudeErr != nil { menu.addItem(.separator()) }
                let hi = NSMenuItem(title: "", action: a.active ? nil : #selector(switchTo(_:)), keyEquivalent: "")
                let ht = a.active ? "● Claude · \(a.label)  \(a.email)   使用中" : "○ Claude · \(a.label)  \(a.email)   点此切换"
                hi.attributedTitle = NSAttributedString(string: ht, attributes: [.font: NSFont.boldSystemFont(ofSize: 13)])
                hi.target = self
                hi.representedObject = a.configDir
                hi.isEnabled = !a.active && a.configDir != nil
                menu.addItem(hi)
                if !a.org.isEmpty { line("  \(a.org)", small: true) }
                if let e = a.error { line("  ⚠︎ \(e)", .systemOrange) }
                if a.needsLogin, let dir = a.configDir {
                    let mi = NSMenuItem(title: "  重新登录 \(a.label)…", action: #selector(relogin(_:)), keyEquivalent: "")
                    mi.target = self
                    mi.representedObject = dir
                    menu.addItem(mi)
                }
                for w in a.windows {
                    let (pct, reset) = effective(w, now)
                    let when = w.resetsAt.map { clockFmt.string(from: $0) } ?? "—"
                    let tail = w.resetsAt == nil ? "未开始计时" : (reset ? "\(when) 已重置（等新数据）" : "\(when) 重置（还有 \(countdown(w.resetsAt, now: now))）")
                    line("  \(w.label)", .labelColor)
                    line("    \(bar(pct)) \(Int(pct.rounded()))%   \(tail)", color(pct))
                }
                let src = "  数据：\(ago(a.updatedAt, now: now))"
                line(src, small: true)
            }
        } else if claudeErr == nil {
            header("Claude")
            line("  读取中…")
        }

        menu.addItem(.separator())
        header("Cursor\(cursor?.plan.map { " · \($0)" } ?? "")")
        if let e = cursorErr {
            line("  ⚠︎ 最近一次刷新失败：\(e)\(cursor == nil ? "" : "（下面是 \(ago(cursorOKAt, now: now)) 的数据）")", .systemOrange)
        }
        if let u = cursor {
            if let used = u.usedCents, let limit = u.limitCents {
                line("  本期包含额度：\(dollars(used)) / \(dollars(limit))")
            }
            line("    \(bar(u.percent)) \(Int(u.percent.rounded()))%", color(u.percent))
            let when = u.cycleEnd.map { clockFmt.string(from: $0) } ?? "—"
            line("  账单周期 \(when) 重置（还有 \(countdown(u.cycleEnd, now: now))）")
            if let pooled = u.pooled { line("  \(pooled)") }
            if u.source != "直连" { line("  数据：\(u.source)", small: true) }
        } else if cursorErr == nil {
            line("  读取中…")
        }

        menu.addItem(.separator())
        let last = [claudeOKAt, cursorOKAt].compactMap { $0 }.max()
        let status = fetching ? "刷新中…" : (last.map { "更新于 \(clockFmt.string(from: $0))" } ?? "尚未更新")
        let upd = NSMenuItem(title: status, action: nil, keyEquivalent: "")
        upd.isEnabled = false
        menu.addItem(upd)
        let r = NSMenuItem(title: "立即刷新", action: #selector(refreshNow), keyEquivalent: "r")
        r.target = self
        r.isEnabled = !fetching
        menu.addItem(r)
        let modeHeader = NSMenuItem(title: "Claude 账号切换方式", action: nil, keyEquivalent: "")
        modeHeader.isEnabled = false
        menu.addItem(modeHeader)
        let au = NSMenuItem(title: "  自动：用完就切，先用快重置的", action: #selector(setAutoMode), keyEquivalent: "")
        au.target = self
        au.state = autoSwitch ? .on : .off
        menu.addItem(au)
        let ma = NSMenuItem(title: "  手动：点哪个账号就用哪个", action: #selector(setManualMode), keyEquivalent: "")
        ma.target = self
        ma.state = autoSwitch ? .off : .on
        menu.addItem(ma)
        menu.addItem(withTitle: "添加 Claude 账号…", action: #selector(addAccount), keyEquivalent: "").target = self
        menu.addItem(withTitle: "打开 Claude 用量页", action: #selector(openClaude), keyEquivalent: "").target = self
        menu.addItem(withTitle: "打开 Cursor 用量页", action: #selector(openCursor), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "退出", action: #selector(quit), keyEquivalent: "q").target = self
    }

    @objc func refreshNow() { refresh(); checkNotices() }
    @objc func openNotice(_ sender: NSMenuItem) {
        if let s = sender.representedObject as? String, let u = URL(string: s) { NSWorkspace.shared.open(u) }
    }

    func checkNotices() {
        Task {
            let found = await fetchOfficialNotices()
            self.notices = found
            var done = self.notifiedNoticeIds
            for n in found where !done.contains(n.id) {
                self.notify("Claude 官方公告（可能涉及额度重置）", n.title)
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
        for ev in events { notify("AI UsageMaster：额度提前重置", ev); switchNote = ev }
        // 用量返回里第一次出现新的额度项（官方活动 / 临时额度 / 重置额度的信号）
        for a in accounts where a.error == nil {
            let now = Set(a.extraKeys)
            if let before = lastExtraKeys[a.email] {
                let added = now.subtracting(before)
                if !added.isEmpty {
                    let msg = "\(a.label) 的用量数据里出现新的额度项：\(added.sorted().joined(separator: "、"))（可能是官方活动或重置）"
                    notify("AI UsageMaster：Claude 额度有变化", msg)
                    switchNote = msg
                }
            }
            lastExtraKeys[a.email] = now
        }
        guard autoSwitch, !events.isEmpty || Date().timeIntervalSince(lastAutoSwitch) > 15 * 60 else { return }
        let d = decideAutoSwitch(accounts, now: Date(), pinnedDir: pinnedDir)
        guard let dir = d.target else { return }
        pinnedDir = nil
        let all = listManagedAccounts()
        guard let x = all.first(where: { $0.dir == dir }) else { return }
        lastAutoSwitch = Date()
        if let err = switchDefault(to: x, all: all) {
            switchNote = "自动切换失败：\(err)"
        } else {
            switchNote = "自动切换：\(d.reason)（\(clockFmt.string(from: Date()))）"
            notify("AI UsageMaster 已切换 Claude 账号", d.reason)
            refresh()
        }
    }

    func notify(_ title: String, _ body: String) {
        let esc = { (s: String) in s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") }
        _ = runCommand("/usr/bin/osascript", ["-e", "display notification \"\(esc(body))\" with title \"\(esc(title))\""], timeout: 5)
    }

    @objc func setAutoMode() {
        autoSwitch = true; pinnedDir = nil; lastAutoSwitch = .distantPast
        switchNote = "切换方式：自动"
        maybeAutoSwitch()
    }
    @objc func setManualMode() { autoSwitch = false; pinnedDir = nil; switchNote = "切换方式：手动（不会自动换账号）" }
    @objc func switchTo(_ sender: NSMenuItem) {
        guard let dir = sender.representedObject as? String else { return }
        let all = listManagedAccounts()
        guard let x = all.first(where: { $0.dir == dir }) else { return }
        if let err = switchDefault(to: x, all: all) {
            switchNote = "切换失败：\(err)"
        } else {
            if autoSwitch { pinnedDir = x.dir }
            switchNote = "已切换到 \(x.email ?? "")：新开的 claude 会话直接用它；已经开着的会话在 30 秒内跟着换"
                + (autoSwitch ? "。自动模式：它用完前不会被自动换走" : "")
        }
        refresh()
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
