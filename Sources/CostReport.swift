// 费用报告：把 TokenStatsSummary 写成一个自包含的 HTML —— 不引用任何外部 CDN / 字体 / 脚本，图表是内联 SVG，
// 悬停提示是页面里十几行内联脚本。浅色 / 深色跟随系统（prefers-color-scheme）。
// 位置：~/Library/Application Support/UsageMaster/cost_report.html（权限 600）。

import Foundation

let costReportURL = URL(fileURLWithPath: NSHomeDirectory() + "/Library/Application Support/UsageMaster/cost_report.html")

/// 生成并写盘，返回文件位置（菜单里用 NSWorkspace.shared.open 打开即可）
@discardableResult
func writeCostReport(_ s: TokenStatsSummary, subscriptions: [TokenSubscription], to url: URL = costReportURL) -> URL {
    let html = renderCostReportHTML(s, subscriptions: subscriptions)
    try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    if (try? Data(html.utf8).write(to: url, options: .atomic)) != nil {
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
    return url
}

func renderCostReportHTML(_ s: TokenStatsSummary, subscriptions: [TokenSubscription]) -> String {
    let sv = tokenSavings(s, subscriptions: subscriptions, period: .thisMonth)
    let sv30 = tokenSavings(s, subscriptions: subscriptions, period: .last30Days)
    let paid = subscriptions.filter { $0.monthlyUSD > 0 }
    let monthly = paid.reduce(0) { $0 + $1.monthlyUSD }
    var h = ""
    let generated = crEsc(crDateTime.string(from: s.lastScan))
    let earliest = crEsc(s.earliest.map { crDate.string(from: $0) } ?? "—")
    h += """
    <!doctype html>
    <html lang="\(L("zh-CN", "en"))">
    <head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <meta name="color-scheme" content="light dark">
    <title>\(L("Claude Code 费用报告", "Claude Code Cost Report"))</title>
    <style>\(crStyle)</style>
    </head>
    <body>
    <main>
    <header>
    <h1>\(L("Claude Code 用量与折合 API 费用", "Claude Code usage and API-equivalent cost"))</h1>
    <p class="sub">\(L("生成于 \(generated)　·　本机日志可追溯到 \(earliest)　·　按本机时区的自然日统计",
                       "Generated \(generated) · Local logs go back to \(earliest) · Days are calendar days in this Mac's time zone"))</p>
    </header>

    """

    // 顶部卡片
    let savedText: String, savedSub: String, savedClass: String
    if sv.hasSubscriptions {
        savedText = sv.savedUSD >= 0 ? crUSD(sv.savedUSD) : crUSD(-sv.savedUSD)
        savedSub = sv.savedUSD >= 0
            ? L("省下：折合 API 费用 − 订阅费", "Saved: API-equivalent cost − subscription cost")
            : L("多花：订阅费高于折合 API 费用", "Spent more: subscriptions cost more than the API-equivalent cost")
        savedClass = sv.savedUSD >= 0 ? " good" : ""
    } else {
        savedText = "—"
        savedSub = L("先填订阅月费才能算", "Enter your monthly subscription fees to calculate this")
        savedClass = ""
    }
    let subText = sv.hasSubscriptions ? crUSD(sv.subscriptionUSD) : L("未填写", "Not set")
    let subSub = sv.hasSubscriptions
        ? L("月费合计 \(crUSD(monthly))，\(crEsc(sv.label))", "Monthly total \(crUSD(monthly)) · \(crEsc(sv.label))")
        : L("在 subscriptions.json 里填月费（路径见下方说明）", "Set monthly fees in subscriptions.json (path in the notes below)")
    let savedLabel = sv.hasSubscriptions && sv.savedUSD < 0
        ? L("本月多花", "Spent more this month")
        : L("本月省下", "Saved this month")
    let subs30 = sv30.hasSubscriptions
        ? L("；订阅折算 \(crUSD(sv30.subscriptionUSD))", "; subscriptions prorated \(crUSD(sv30.subscriptionUSD))")
        : ""
    let since = crEsc(s.earliest.map { crDateShortY.string(from: $0) } ?? "—")
    h += """
    <section class="cards">
    <div class="card hero"><div class="label">\(L("本月折合 API 费用", "API-equivalent cost this month"))</div><div class="value">\(crUSD(s.thisMonth.costUSD))</div>
    <div class="note">\(crTokens(s.thisMonth.tokens)) tokens · \(L("\(crInt(s.thisMonth.messages)) 次回复", "\(crInt(s.thisMonth.messages)) replies"))</div></div>
    <div class="card"><div class="label">\(L("订阅费用（本月折算）", "Subscriptions (prorated this month)"))</div><div class="value">\(subText)</div><div class="note">\(subSub)</div></div>
    <div class="card"><div class="label">\(savedLabel)</div><div class="value\(savedClass)">\(savedText)</div><div class="note">\(savedSub)</div></div>
    <div class="card"><div class="label">\(L("今天", "Today"))</div><div class="value">\(crUSD(s.today.costUSD))</div><div class="note">\(crTokens(s.today.tokens)) tokens</div></div>
    <div class="card"><div class="label">\(L("最近 7 天", "Last 7 days"))</div><div class="value">\(crUSD(s.last7Days.costUSD))</div><div class="note">\(crTokens(s.last7Days.tokens)) tokens</div></div>
    <div class="card"><div class="label">\(L("最近 30 天", "Last 30 days"))</div><div class="value">\(crUSD(s.last30Days.costUSD))</div>
    <div class="note">\(crTokens(s.last30Days.tokens)) tokens\(subs30)</div></div>
    <div class="card"><div class="label">\(L("累计（可追溯部分）", "All time (available history)"))</div><div class="value">\(crUSD(s.allTime.costUSD))</div>
    <div class="note">\(L("自 \(since) 起，\(crTokens(s.allTime.tokens)) tokens", "Since \(since), \(crTokens(s.allTime.tokens)) tokens"))</div></div>
    </section>

    """

    // 近 30 天每日费用
    // 表头沿用的列名
    let thCost = L("费用", "Cost"), thInput = L("输入", "Input"), thOutput = L("输出", "Output")
    let thCacheRead = L("缓存读", "Cache read"), thCacheWrite = L("缓存写", "Cache write")
    let thShare = L("占比", "Share"), thProject = L("项目", "Project")
    h += "<section class=\"panel\"><h2>\(L("近 30 天每日折合费用", "Daily API-equivalent cost, last 30 days"))</h2>\n" + crDailyChart(Array(s.byDay.suffix(30))) + "\n"
    h += "<details><summary>\(L("每日明细（最近 60 天）", "Daily details (last 60 days)"))</summary><div class=\"scroll\"><table><thead><tr><th>\(L("日期", "Date"))</th><th class=\"n\">\(thCost)</th><th class=\"n\">tokens</th><th class=\"n\">\(thInput)</th><th class=\"n\">\(thOutput)</th><th class=\"n\">\(thCacheRead)</th><th class=\"n\">\(thCacheWrite)</th><th class=\"n\">\(L("回复", "Replies"))</th></tr></thead><tbody>\n"
    for d in s.byDay.reversed() where d.totals.messages > 0 {
        let t = d.totals
        h += "<tr><td>\(crEsc(crDateW.string(from: d.day)))</td><td class=\"n\">\(crUSD(t.costUSD))</td><td class=\"n\">\(crTokens(t.tokens))</td><td class=\"n\">\(crTokens(t.input))</td><td class=\"n\">\(crTokens(t.output))</td><td class=\"n\">\(crTokens(t.cacheRead))</td><td class=\"n\">\(crTokens(t.cacheWrite))</td><td class=\"n\">\(crInt(t.messages))</td></tr>\n"
    }
    h += "</tbody></table></div></details></section>\n"

    // 按项目
    let total30 = s.last30Days.costUSD
    h += "<section class=\"panel\"><h2>\(L("按项目（最近 30 天）", "By project (last 30 days)"))</h2><p class=\"sub\">"
        + L("项目 = 会话所在目录的 git 根目录（git worktree 归到主仓库）；不在 git 里的按目录本身。鼠标停在项目名上看完整路径。",
            "Project = the git root of the session's directory (git worktrees count toward the main repository); directories outside git count as themselves. Hover over a project name to see the full path.")
        + "</p>\n"
    h += "<div class=\"scroll\"><table><thead><tr><th>\(thProject)</th><th class=\"n\">tokens</th><th class=\"n\">\(thCost)</th><th class=\"share\">\(thShare)</th><th class=\"n\">\(L("本月费用", "This month"))</th><th class=\"n\">\(L("会话", "Sessions"))</th></tr></thead><tbody>\n"
    let shownProjects = s.byProject.prefix(30)
    for p in shownProjects {
        h += "<tr><td title=\"\(crEsc(crTilde(p.root)))\">\(crEsc(p.name))</td><td class=\"n\">\(crTokens(p.last30Days.tokens))</td><td class=\"n\">\(crUSD(p.last30Days.costUSD))</td>\(crShareCell(p.last30Days.costUSD, total30))<td class=\"n\">\(crUSD(p.thisMonth.costUSD))</td><td class=\"n\">\(crInt(p.sessions))</td></tr>\n"
    }
    let rest = s.byProject.dropFirst(shownProjects.count)
    if !rest.isEmpty {
        let c30 = rest.reduce(0) { $0 + $1.last30Days.costUSD }, cm = rest.reduce(0) { $0 + $1.thisMonth.costUSD }
        let tk = rest.reduce(0) { $0 + $1.last30Days.tokens }, ss = rest.reduce(0) { $0 + $1.sessions }
        h += "<tr class=\"muted\"><td>\(L("其它 \(rest.count) 个项目", "\(rest.count) other projects"))</td><td class=\"n\">\(crTokens(tk))</td><td class=\"n\">\(crUSD(c30))</td>\(crShareCell(c30, total30))<td class=\"n\">\(crUSD(cm))</td><td class=\"n\">\(crInt(ss))</td></tr>\n"
    }
    if s.byProject.isEmpty { h += "<tr><td colspan=\"6\" class=\"muted\">\(L("最近 30 天没有用量", "No usage in the last 30 days"))</td></tr>\n" }
    h += "</tbody></table></div></section>\n"

    // 按模型
    h += "<section class=\"panel\"><h2>\(L("按模型（最近 30 天）", "By model (last 30 days)"))</h2>\n<div class=\"scroll\"><table><thead><tr><th>\(L("模型", "Model"))</th><th class=\"n\">\(L("单价 输入 / 输出", "Price (input / output)"))</th><th class=\"n\">\(thInput)</th><th class=\"n\">\(thOutput)</th><th class=\"n\">\(thCacheRead)</th><th class=\"n\">\(thCacheWrite)</th><th class=\"n\">\(thCost)</th><th class=\"share\">\(thShare)</th></tr></thead><tbody>\n"
    let unknownTag = L("未知型号，按 $5 / $25 估", "Unknown model, estimated at $5 / $25")
    for m in s.byModel where m.last30Days.messages > 0 {
        let t = m.last30Days
        let flag = m.unknown ? "<span class=\"tag\">\(unknownTag)</span>" : ""
        h += "<tr><td>\(crEsc(m.model))\(flag)</td><td class=\"n\" title=\"\(crEsc(crRateDetail(m.price)))\">\(crRate(m.price.input)) / \(crRate(m.price.output))</td><td class=\"n\">\(crTokens(t.input))</td><td class=\"n\">\(crTokens(t.output))</td><td class=\"n\">\(crTokens(t.cacheRead))</td><td class=\"n\">\(crTokens(t.cacheWrite))</td><td class=\"n\">\(crUSD(t.costUSD))</td>\(crShareCell(t.costUSD, total30))</tr>\n"
    }
    h += "</tbody></table></div><p class=\"sub\">"
        + L("单价是每百万 token 的美元价；缓存读、缓存写（5 分钟 / 1 小时）各有单价，鼠标停在单价上可见。",
            "Prices are USD per million tokens. Cache read and cache write (5 min / 1 hour) each have their own price; hover over a price to see them.")
        + "</p></section>\n"

    // 费用最高的会话
    h += "<section class=\"panel\"><h2>\(L("费用最高的会话（最近 30 天）", "Most expensive sessions (last 30 days)"))</h2>\n<div class=\"scroll\"><table><thead><tr><th>\(L("会话", "Session"))</th><th>\(thProject)</th><th>\(L("主要模型", "Main model"))</th><th>\(L("时间", "Time"))</th><th class=\"n\">tokens</th><th class=\"n\">\(thCost)</th></tr></thead><tbody>\n"
    for x in s.topSessions {
        let span = crDateTime.string(from: x.start) + " – " + (Calendar.current.isDate(x.start, inSameDayAs: x.end) ? crTime.string(from: x.end) : crDateTime.string(from: x.end))
        h += "<tr><td class=\"mono\" title=\"\(crEsc(x.sessionId))\">\(crEsc(String(x.sessionId.prefix(8))))</td><td title=\"\(crEsc(crTilde(x.projectRoot)))\">\(crEsc(x.project))</td><td>\(crEsc(x.mainModel))</td><td>\(crEsc(span))</td><td class=\"n\">\(crTokens(x.totals.tokens))</td><td class=\"n\">\(crUSD(x.totals.costUSD))</td></tr>\n"
    }
    if s.topSessions.isEmpty { h += "<tr><td colspan=\"6\" class=\"muted\">\(L("最近 30 天没有会话", "No sessions in the last 30 days"))</td></tr>\n" }
    h += "</tbody></table></div><p class=\"sub\">"
        + L("会话 = Claude Code 的 sessionId（子代理的用量算在发起它的会话里）。完整 id 停在前 8 位上可见。",
            "Session = the Claude Code sessionId (subagent usage counts toward the session that started it). Hover over the first 8 characters to see the full id.")
        + "</p></section>\n"

    // 说明
    let priceSource = crEsc(s.priceSource)
    let fastNote = s.fastModeMessages > 0
        ? L("，最近 30 天有 \(crInt(s.fastModeMessages)) 次 fast 回复", ", \(crInt(s.fastModeMessages)) fast replies in the last 30 days")
        : ""
    var notes: [String] = [
        L("这里的费用是<strong>「这些请求如果按 API 标价付费要花多少」的估算</strong>，不是账单；订阅用户实际付的是订阅费。",
          "The costs here are <strong>an estimate of what these requests would cost at API list prices</strong>, not a bill. Subscribers actually pay their subscription fee."),
        L("价格来源：\(priceSource)（Claude Code 的 <code>/cost</code> 用的同一份价格表）。可以用 <code>~/.config/usagemaster/pricing.json</code> 覆盖，结构与内置目录相同。",
          "Price source: \(priceSource) (the same price table Claude Code's <code>/cost</code> uses). You can override it with <code>~/.config/usagemaster/pricing.json</code>, which has the same structure as the built-in catalog."),
        L("数据来源：本机 Claude Code 会话日志（<code>~/.claude/projects</code>，以及 UsageMaster / Orca 管理的各账号目录），<strong>只读</strong>。只取时间、模型、目录、会话 id 与 token 数；对话内容不读取、不保存。",
          "Data source: Claude Code session logs on this Mac (<code>~/.claude/projects</code> and the account folders managed by UsageMaster / Orca), <strong>read-only</strong>. Only time, model, directory, session id and token counts are used; conversation content is never read or stored."),
        L("同一条回复会在多个日志文件里重复出现（会话续接 / 分支），在一个文件里也会拆成几行：按「消息 id + 请求 id」只计一次，token 取最终值。",
          "The same reply can appear in several log files (resumed or branched sessions) and be split across several lines in one file. Each reply is counted once by message id + request id, using its final token counts."),
        L("计价：输入、输出、缓存读、缓存写分别按单价计；缓存写区分 5 分钟与 1 小时两档，日志没给拆分时全按 5 分钟算。",
          "Pricing: input, output, cache read and cache write each use their own price. Cache writes have a 5-minute and a 1-hour tier; when the log gives no breakdown, all of it is priced as 5-minute."),
        L("<strong>未计入</strong>：fast 模式等特殊计费（按标准价算\(fastNote)）；网页搜索等按次收费的服务端工具；型号回退时被替换掉的那一次请求（日志顶层只记回退后的用量）。",
          "<strong>Not included</strong>: special pricing such as fast mode (priced at standard rates\(fastNote)); per-use server tools such as web search; the request that was replaced when the model fell back (the top level of the log only records usage after the fallback)."),
        L("只统计这台电脑上的 Claude Code。其它电脑、claude.ai 网页与 App 的用量都不在里面。",
          "Only Claude Code on this computer is counted. Usage on other computers, on the claude.ai website and in the apps is not included."),
        L("Claude Code 默认会删掉 30 天前的会话日志；UsageMaster 把已经统计过的记录留在缓存里（保留 400 天），所以这里的历史可以比日志更长。",
          "By default Claude Code deletes session logs older than 30 days. UsageMaster keeps records it has already counted in its cache (for 400 days), so the history here can go back further than the logs."),
    ]
    if !s.unknownModels.isEmpty {
        let list = s.unknownModels.map { "<code>\(crEsc($0))</code>" }.joined(separator: listSep)
        notes.append(L("价格表里没有的型号按 Opus 档（输入 $5、输出 $25 / 百万）估算：\(list)。",
                       "Models missing from the price table are estimated at the Opus tier ($5 input, $25 output per million): \(list)."))
    }
    if let n = s.priceNote { notes.append(L("pricing.json 的问题：\(crEsc(n))", "Problem with pricing.json: \(crEsc(n))")) }
    if sv.hasSubscriptions {
        let list = paid.map { crEsc($0.name) + " " + crUSD($0.monthlyUSD) + L("/月", "/mo") }.joined(separator: listSep)
        notes.append(L("订阅对比：本月订阅费 = 月费合计 × 本月已过天数 / 本月天数（今天算一整天）；最近 30 天 = 月费 × 30 × 12 / 365。订阅清单：\(list)。",
                       "Subscription comparison: this month's subscription cost = monthly total × days elapsed this month / days in the month (today counts as a full day); last 30 days = monthly fee × 30 × 12 / 365. Subscriptions: \(list)."))
    } else {
        notes.append(L("订阅对比：在 <code>~/.config/usagemaster/subscriptions.json</code> 里把每个订阅的 <code>monthlyUSD</code> 改成你实际付的月费（美元），下次生成报告就会算出省下多少。",
                       "Subscription comparison: in <code>~/.config/usagemaster/subscriptions.json</code>, set each subscription's <code>monthlyUSD</code> to the monthly fee you actually pay (in USD). The next report will show how much you saved."))
    }
    let secs = String(format: "%.1f", s.scanSeconds)
    notes.append(L("本次扫描 \(crInt(s.scannedFiles)) 个日志文件（其中 \(crInt(s.filesRead)) 个有新内容），用时 \(secs) 秒；缓存里共 \(crInt(s.totalRecords)) 次回复。",
                   "Scanned \(crInt(s.scannedFiles)) log files (\(crInt(s.filesRead)) with new content) in \(secs) seconds. The cache holds \(crInt(s.totalRecords)) replies in total."))
    h += "<section class=\"panel notes\"><h2>\(L("说明", "Notes"))</h2><ul>\n" + notes.map { "<li>\($0)</li>" }.joined(separator: "\n") + "\n</ul></section>\n"

    h += "</main>\n<script>\(crScript)</script>\n</body>\n</html>\n"
    return h
}

// MARK: - 柱状图（内联 SVG）

fileprivate func crDailyChart(_ days: [TokenDayStat]) -> String {
    let W = 760.0, H = 260.0, padL = 56.0, padR = 12.0, padT = 22.0, padB = 30.0
    let plotW = W - padL - padR, plotH = H - padT - padB
    let n = max(days.count, 1)
    let band = plotW / Double(n)
    let barW = min(16, band * 0.62)
    let maxV = days.map { $0.totals.costUSD }.max() ?? 0
    // 刻度：1 / 2 / 2.5 / 5 × 10^k，约 4 格
    var step = 1.0
    if maxV > 0 {
        let rough = maxV / 4
        let mag = pow(10, floor(log10(rough)))
        step = [1, 2, 2.5, 5, 10].map { $0 * mag }.first { $0 >= rough } ?? 10 * mag
    }
    let top = maxV > 0 ? ceil(maxV / step) * step : 4
    func y(_ v: Double) -> Double { padT + plotH - v / top * plotH }
    let chartLabel = L("近 30 天每日折合 API 费用柱状图，明细见下方表格", "Bar chart of daily API-equivalent cost over the last 30 days. Details are in the table below.")
    var g = "<div class=\"chart\" id=\"chart\"><svg viewBox=\"0 0 \(Int(W)) \(Int(H))\" role=\"img\" aria-label=\"\(chartLabel)\">\n"
    var v = 0.0
    while v <= top + step / 2 {
        let yy = crF(y(v))
        g += "<line class=\"\(v == 0 ? "axis" : "grid")\" x1=\"\(crF(padL))\" x2=\"\(crF(W - padR))\" y1=\"\(yy)\" y2=\"\(yy)\"/>"
        g += "<text class=\"tick\" x=\"\(crF(padL - 8))\" y=\"\(yy)\" text-anchor=\"end\" dominant-baseline=\"middle\">\(crTickUSD(v, step: step))</text>\n"
        v += step
        if maxV <= 0 { break }
    }
    let maxIndex = days.indices.max { days[$0].totals.costUSD < days[$1].totals.costUSD }
    let ariaSep = L("，", ", "), titleSep = L("　", " · ")
    for (i, d) in days.enumerated() {
        let cx = padL + band * (Double(i) + 0.5)
        let label = crDateW.string(from: d.day)
        let cost = crUSD(d.totals.costUSD), tok = crTokens(d.totals.tokens) + " tokens"
        g += "<g class=\"day\"><rect class=\"hit\" tabindex=\"0\" x=\"\(crF(padL + band * Double(i)))\" y=\"\(crF(padT))\" width=\"\(crF(band))\" height=\"\(crF(plotH))\" data-day=\"\(crEsc(label))\" data-cost=\"\(crEsc(cost))\" data-tok=\"\(crEsc(tok))\" aria-label=\"\(crEsc(label + " " + cost + ariaSep + tok))\"><title>\(crEsc(label + titleSep + cost + titleSep + tok))</title></rect>"
        let hgt = d.totals.costUSD / top * plotH
        if hgt > 0.5 {
            let x0 = cx - barW / 2, x1 = cx + barW / 2, yb = padT + plotH, y0 = yb - hgt
            let r = min(4, barW / 2, hgt)
            g += "<path class=\"bar\" d=\"M\(crF(x0)) \(crF(yb))V\(crF(y0 + r))A\(crF(r)) \(crF(r)) 0 0 1 \(crF(x0 + r)) \(crF(y0))H\(crF(x1 - r))A\(crF(r)) \(crF(r)) 0 0 1 \(crF(x1)) \(crF(y0 + r))V\(crF(yb))Z\"/>"
            if i == maxIndex {
                g += "<text class=\"peak\" x=\"\(crF(cx))\" y=\"\(crF(y0 - 6))\" text-anchor=\"middle\">\(crEsc(cost))</text>"
            }
        }
        g += "</g>\n"
        if (days.count - 1 - i) % 5 == 0 {
            g += "<text class=\"tick\" x=\"\(crF(cx))\" y=\"\(crF(H - 10))\" text-anchor=\"middle\">\(crEsc(crDayShort.string(from: d.day)))</text>\n"
        }
    }
    g += "</svg><div class=\"tip\" id=\"tip\" hidden><div class=\"v\"></div><div class=\"l\"></div></div></div>"
    if maxV <= 0 { g += "<p class=\"sub\">\(L("近 30 天没有用量。", "No usage in the last 30 days."))</p>" }
    return g
}

// MARK: - 格式化

fileprivate func crEsc(_ s: String) -> String {
    var o = ""
    o.reserveCapacity(s.count)
    for c in s {
        switch c {
        case "&": o += "&amp;"
        case "<": o += "&lt;"
        case ">": o += "&gt;"
        case "\"": o += "&quot;"
        case "'": o += "&#39;"
        default: o.append(c)
        }
    }
    return o
}

fileprivate let crGrouping: NumberFormatter = {
    let f = NumberFormatter()
    f.locale = Locale(identifier: "en_US")
    f.numberStyle = .decimal
    f.minimumFractionDigits = 2
    f.maximumFractionDigits = 2
    return f
}()

fileprivate func crUSD(_ v: Double) -> String {
    let s = crGrouping.string(from: NSNumber(value: abs(v))) ?? String(format: "%.2f", abs(v))
    return (v < -0.005 ? "-$" : "$") + s
}

fileprivate func crInt(_ n: Int) -> String {
    let f = NumberFormatter()
    f.locale = Locale(identifier: "en_US")
    f.numberStyle = .decimal
    return f.string(from: NSNumber(value: n)) ?? String(n)
}

/// token 数：一万以下原样，以上中文用 万 / 亿，英文用 K / M / B
fileprivate func crTokens(_ n: Int) -> String {
    let d = Double(n)
    if n < 10_000 { return crInt(n) }
    if isChinese {
        if d < 1e8 { return String(format: d < 1e6 ? "%.1f 万" : "%.0f 万", d / 1e4) }
        return String(format: "%.2f 亿", d / 1e8)
    }
    if d < 1e6 { return String(format: "%.1fK", d / 1e3) }
    if d < 1e9 { return String(format: d < 1e8 ? "%.2fM" : "%.1fM", d / 1e6) }
    return String(format: "%.2fB", d / 1e9)
}

/// 单价（美元 / 百万 token）
fileprivate func crRate(_ v: Double) -> String {
    v == v.rounded() ? String(format: "$%.0f", v) : String(format: "$%g", v)
}

fileprivate func crRateDetail(_ p: TokenPrice) -> String {
    L("每百万 token：输入 \(crRate(p.input))，输出 \(crRate(p.output))，缓存读 \(crRate(p.cacheRead))，缓存写 5 分钟 \(crRate(p.cacheWrite5m)) / 1 小时 \(crRate(p.cacheWrite1h))",
      "Per million tokens: input \(crRate(p.input)), output \(crRate(p.output)), cache read \(crRate(p.cacheRead)), cache write 5 min \(crRate(p.cacheWrite5m)) / 1 hour \(crRate(p.cacheWrite1h))")
}

fileprivate func crTickUSD(_ v: Double, step: Double) -> String {
    if step < 0.1 { return String(format: "$%.2f", v) }
    if step < 1 { return String(format: "$%.1f", v) }
    return "$" + crInt(Int(v.rounded()))
}

fileprivate func crF(_ v: Double) -> String { String(format: "%.1f", v) }

fileprivate func crShareCell(_ part: Double, _ total: Double) -> String {
    let p = total > 0 ? part / total * 100 : 0
    return "<td class=\"share\"><span class=\"meter\"><span style=\"width:\(crF(min(100, max(0, p))))%\"></span></span><span class=\"pct\">\(String(format: p >= 10 ? "%.0f%%" : "%.1f%%", p))</span></td>"
}

fileprivate func crTilde(_ p: String) -> String {
    let home = NSHomeDirectory()
    return p.hasPrefix(home) ? "~" + String(p.dropFirst(home.count)) : p
}

/// 日期格式：中文界面用 zh_CN + 中文格式，英文界面用 en_US + 英文格式
fileprivate func crFormatter(_ zh: String, _ en: String) -> DateFormatter {
    let f = DateFormatter()
    f.locale = Locale(identifier: isChinese ? "zh_CN" : "en_US")
    f.dateFormat = isChinese ? zh : en
    return f
}
fileprivate let crDateTime = crFormatter("M月d日 HH:mm", "MMM d HH:mm")
fileprivate let crTime = crFormatter("HH:mm", "HH:mm")
fileprivate let crDate = crFormatter("yyyy年M月d日", "MMM d, yyyy")
fileprivate let crDateW = crFormatter("M月d日 EEE", "EEE MMM d")
fileprivate let crDayShort = crFormatter("M/d", "M/d")
fileprivate let crDateShortY = crFormatter("yyyy/M/d", "yyyy-MM-dd")

// MARK: - 样式与脚本

fileprivate let crStyle = """
:root {
  color-scheme: light;
  --page: #f9f9f7; --surface: #fcfcfb; --ink: #0b0b0b; --ink2: #52514e; --muted: #898781;
  --grid: #e1e0d9; --axis: #c3c2b7; --ring: rgba(11,11,11,0.10);
  --series: #2a78d6; --series-hover: #5598e7; --track: #e5effb; --good: #006300;
}
@media (prefers-color-scheme: dark) {
  :root {
    color-scheme: dark;
    --page: #0d0d0d; --surface: #1a1a19; --ink: #ffffff; --ink2: #c3c2b7; --muted: #898781;
    --grid: #2c2c2a; --axis: #383835; --ring: rgba(255,255,255,0.10);
    --series: #3987e5; --series-hover: #6da7ec; --track: #1f2c3d; --good: #0ca30c;
  }
}
* { box-sizing: border-box; }
body { margin: 0; background: var(--page); color: var(--ink);
  font: 14px/1.55 system-ui, -apple-system, "PingFang SC", "Hiragino Sans GB", sans-serif; }
main { max-width: 1080px; margin: 0 auto; padding: 24px 16px 48px; }
h1 { font-size: 22px; margin: 0 0 4px; font-weight: 600; }
h2 { font-size: 16px; margin: 0 0 10px; font-weight: 600; }
.sub { color: var(--ink2); margin: 4px 0 10px; font-size: 13px; }
.cards { display: grid; grid-template-columns: minmax(0, 1.6fr) repeat(3, minmax(0, 1fr)); gap: 12px; margin: 18px 0; }
.card, .panel { background: var(--surface); border: 1px solid var(--ring); border-radius: 10px; }
.card { padding: 14px 16px; min-width: 0; }
.panel { min-width: 0; }
.card .label { color: var(--ink2); font-size: 13px; }
.card .value { font-size: 24px; font-weight: 600; margin-top: 2px; }
.card .value.good { color: var(--good); }
.card .note { color: var(--muted); font-size: 12px; margin-top: 2px; overflow-wrap: anywhere; }
.card.hero { grid-row: span 2; display: flex; flex-direction: column; justify-content: center; }
.card.hero .value { font-size: 48px; line-height: 1.15; }
@media (max-width: 760px) {
  .cards { grid-template-columns: repeat(2, minmax(0, 1fr)); }
  .card .value { font-size: 20px; }
  .card.hero { grid-column: span 2; grid-row: auto; }
  .card.hero .value { font-size: 36px; }
}
.panel { padding: 16px; margin: 14px 0; }
.chart { position: relative; }
.chart svg { display: block; width: 100%; height: auto; }
.chart .grid { stroke: var(--grid); stroke-width: 1; }
.chart .axis { stroke: var(--axis); stroke-width: 1; }
.chart .tick { fill: var(--muted); font-size: 11px; font-variant-numeric: tabular-nums; }
.chart .peak { fill: var(--ink2); font-size: 11px; font-weight: 600; }
.chart .bar { fill: var(--series); pointer-events: none; }
.chart .hit { fill: transparent; outline: none; cursor: default; }
.chart .day:hover .bar, .chart .day:focus-within .bar { fill: var(--series-hover); }
.chart .day:focus-within .hit { stroke: var(--axis); stroke-width: 1; }
.tip { position: absolute; top: 4px; transform: translateX(-50%); background: var(--surface); border: 1px solid var(--ring);
  border-radius: 8px; padding: 6px 10px; box-shadow: 0 4px 14px rgba(0,0,0,0.12); pointer-events: none; white-space: nowrap; }
.tip .v { font-weight: 600; font-size: 15px; }
.tip .l { color: var(--ink2); font-size: 12px; }
.scroll { overflow-x: auto; }
table { border-collapse: collapse; width: 100%; font-size: 13px; }
th, td { padding: 7px 8px; border-bottom: 1px solid var(--grid); text-align: left; white-space: nowrap; }
th { color: var(--ink2); font-weight: 500; }
td.n, th.n { text-align: right; font-variant-numeric: tabular-nums; }
td.share { min-width: 150px; }
.meter { display: inline-block; width: 90px; height: 6px; border-radius: 3px; background: var(--track); vertical-align: middle; overflow: hidden; }
.meter > span { display: block; height: 100%; background: var(--series); border-radius: 3px; }
.pct { display: inline-block; min-width: 44px; text-align: right; margin-left: 6px; font-variant-numeric: tabular-nums; color: var(--ink2); }
tr.muted td, td.muted { color: var(--muted); }
.mono { font-family: ui-monospace, SFMono-Regular, Menlo, monospace; }
.tag { margin-left: 8px; font-size: 11px; color: var(--ink2); border: 1px solid var(--ring); border-radius: 4px; padding: 0 5px; }
details { margin-top: 10px; }
summary { cursor: pointer; color: var(--ink2); }
.notes ul { margin: 0; padding-left: 20px; color: var(--ink2); }
.notes li { margin: 4px 0; }
code { font-family: ui-monospace, SFMono-Regular, Menlo, monospace; font-size: 12px; }
"""

/// 悬停 / 键盘聚焦时显示当天的费用；文字一律走 textContent
fileprivate let crScript = """
(function () {
  var wrap = document.getElementById('chart'), tip = document.getElementById('tip');
  if (!wrap || !tip) return;
  function show(e) {
    var t = e.currentTarget, r = wrap.getBoundingClientRect(), b = t.getBoundingClientRect();
    tip.querySelector('.v').textContent = t.getAttribute('data-cost');
    tip.querySelector('.l').textContent = t.getAttribute('data-day') + ' · ' + t.getAttribute('data-tok');
    tip.hidden = false;
    var x = b.left + b.width / 2 - r.left, half = tip.offsetWidth / 2 + 4;
    tip.style.left = Math.min(Math.max(x, half), r.width - half) + 'px';
  }
  function hide() { tip.hidden = true; }
  var hits = wrap.querySelectorAll('.hit');
  for (var i = 0; i < hits.length; i++) {
    hits[i].addEventListener('pointerenter', show);
    hits[i].addEventListener('focus', show);
    hits[i].addEventListener('pointerleave', hide);
    hits[i].addEventListener('blur', hide);
  }
})();
"""
