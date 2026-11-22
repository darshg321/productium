import SwiftUI
import UIKit
import ProductiumCore

/// Dev builds only: a test runner (Claude Code, the CI simulator, `scripts/test/device.sh`) drives the app through a
/// file. It writes `Documents/test/commands.txt`; the app picks it up within a second, runs it line by line, and writes
/// `Documents/test/results.txt` (ending in `DONE`), screenshots to `shots/` and state dumps to `dumps/`.
/// Commands (one per line, `#` comments):
///   scenario <fresh|today|history|evening|alerts|leaderboard>   reset   tab <today|schedule|tasks|review|settings>
///   open <productium://…>   say <text>   start <title>   start-next   stop   mood <1-5>   confirm-today   approve   decline
///   answer <yes|no|skipped|sick|no-school>   dismiss   scroll <card>   review [recap]   now <action>   backup
///   refresh   replan   learn   leaderboard   server [url]   wait <seconds>   shot <name>   dump <name>
@MainActor
final class TestHooks {
    static let shared = TestHooks()
    private var started = false
    private var running = false

    static var dir: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("test", isDirectory: true)
    }
    private var inbox: URL { Self.dir.appendingPathComponent("commands.txt") }
    private var results: URL { Self.dir.appendingPathComponent("results.txt") }

    func start(_ model: AppModel) {
        guard AppInfo.isDev, !started else { return }
        started = true
        for sub in ["shots", "dumps"] {
            try? FileManager.default.createDirectory(at: Self.dir.appendingPathComponent(sub), withIntermediateDirectories: true)
        }
        Task { @MainActor in
            while true {
                if !running, FileManager.default.fileExists(atPath: inbox.path) { await runInbox(model) }
                try? await Task.sleep(nanoseconds: 800_000_000)
            }
        }
    }

    private func runInbox(_ model: AppModel) async {
        running = true
        defer { running = false }
        guard let text = try? String(contentsOf: inbox, encoding: .utf8) else { return }
        try? FileManager.default.removeItem(at: inbox)
        var out: [String] = []
        var errors = 0
        let lines = text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty && !$0.hasPrefix("#") }
        model.log(.lifecycle, "test_run", ["commands": "\(lines.count)"])
        for line in lines {
            let r = await run(line, model)
            if r.hasPrefix("error") { errors += 1 }
            out.append("\(r.hasPrefix("error") ? "ERR" : "ok ") \(line)\(r == "ok" ? "" : " → " + r)")
            try? (out.joined(separator: "\n") + "\n").write(to: results, atomically: true, encoding: .utf8)
        }
        out.append("DONE \(lines.count - errors) ok, \(errors) errors")
        try? (out.joined(separator: "\n") + "\n").write(to: results, atomically: true, encoding: .utf8)
    }

    private func run(_ line: String, _ m: AppModel) async -> String {
        let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
        let cmd = parts[0].lowercased(), arg = parts.count > 1 ? parts[1] : ""
        switch cmd {
        case "scenario":
            guard let s = Scenario(rawValue: arg) else { return "error: scenarios are " + Scenario.allCases.map(\.rawValue).joined(separator: ", ") }
            dismissSheets()
            m.loadScenario(Scenarios.make(s, now: Date(), calendar: m.cal))
            await settle(1.2)
            return "ok"
        case "reset":
            dismissSheets()
            m.loadScenario(AppState())
            await settle(1)
            return "ok"
        case "tab":
            let tabs = ["today", "schedule", "tasks", "review", "settings"]
            guard tabs.contains(arg) else { return "error: tabs are " + tabs.joined(separator: ", ") }
            dismissSheets()
            m.deepLink = "productium://\(arg)"
            await settle(0.8)
            return "ok"
        case "open":
            guard let url = URL(string: arg) else { return "error: not a URL" }
            m.deepLink = AppInfo.normalised(url)
            await settle(1.2)
            return "ok"
        case "say":
            guard !arg.isEmpty else { return "error: say what?" }
            let ok = await m.submit(arg, source: .app)
            await settle(0.8)
            return ok ? "ok: " + (m.state.conversation.turns.last?.reply ?? "") : "error: not sent (queued in the outbox)"
        case "start":
            m.start(title: arg, source: "test")
            await settle(0.8)
            return m.running.map { "ok: running \($0.title)" } ?? "error: nothing running"
        case "start-next":
            m.startNowOrNext()
            await settle(0.8)
            return m.running.map { "ok: running \($0.title)" } ?? "error: nothing started"
        case "stop":
            m.stopRunning(source: "test")
            await settle(0.8)
            return "ok"
        case "mood":
            guard let n = Int(arg), (1...5).contains(n) else { return "error: mood 1-5" }
            m.logMood(n, energy: nil, note: nil)
            return "ok"
        case "confirm-today":
            let today = Days.dayInterval(Date(), m.cal)
            m.confirmAll(in: DateInterval(start: today.start, end: Date()))
            await settle(0.8)
            return "ok: " + (m.toast ?? "")
        case "approve", "decline":
            guard let a = m.approvals.first else { return "error: nothing waiting" }
            if cmd == "approve" { m.approve(a.id) } else { m.decline(a.id) }
            await settle(0.8)
            return "ok"
        case "answer":
            guard let q = m.state.inference.pending.first else { return "error: no question" }
            let map = ["yes": "q.yes", "no": "q.no", "skipped": "q.skipped", "sick": "q.sick", "no-school": "q.noSchool"]
            m.answerQuestion(action: map[arg] ?? "q.yes", id: q.id, text: "")
            await settle(0.8)
            return "ok"
        case "dismiss":
            dismissSheets()
            await settle(0.6)
            return "ok"
        case "scroll":
            m.scrollTarget = arg
            await settle(0.9)
            m.scrollTarget = nil
            return "ok"
        case "review":
            dismissSheets()
            m.deepLink = "productium://review"
            await settle(0.8)
            if arg == "recap" {
                m.showRecap = true
                await settle(1.0)
            }
            return "ok"
        case "now":
            // A Now Live Activity button, as the Lock Screen would press it (stop, start:<title>, yes:<ref>, …).
            m.nowAction(arg)
            await settle(0.8)
            return "ok: " + (m.nowState().map { "\($0.card.kind.rawValue) \($0.card.title)" } ?? "nothing")
        case "backup":
            await m.backupIfDue(force: true)
            return m.state.backup.failing ? "error: \(m.state.backup.lastError ?? "")" : "ok: \(m.state.backup.lastFile ?? "no folder")"
        case "refresh":
            await m.refresh(full: false)
            return "ok"
        case "replan":
            m.replan()
            return "ok"
        case "learn":
            m.learnAdherence()
            return "ok: adherence \(Int(m.state.learned.adherence * 100))%, good hours \(m.state.learned.goodHours())"
        case "leaderboard":
            await m.refreshLeaderboards(force: true)
            return "ok"
        case "server":
            // The key arrives as Documents/test/server-key.txt (scripts/test/connect-server.sh) and goes straight to the
            // Keychain; it's never echoed. `server <url>` also sets the address (default: the Pi over Tailscale).
            let file = Self.dir.appendingPathComponent("server-key.txt")
            if let key = (try? String(contentsOf: file, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty {
                ClaudeClient.shared.apiKey = key
            }
            try? FileManager.default.removeItem(at: file)
            if let url = URL(string: arg), arg.hasPrefix("https://") { ClaudeClient.shared.baseURL = url }
            guard ClaudeClient.shared.isConfigured else { return "error: no key (push server-key.txt first)" }
            let check = await ClaudeClient.shared.verify()
            m.serverOnline = check == .ok
            return check == .ok ? "ok: connected to \(ClaudeClient.shared.baseURL?.host ?? "")" : "error: \(check) (Tailscale on?)"
        case "wait":
            await settle(Double(arg) ?? 1)
            return "ok"
        case "shot":
            await settle(0.4)
            return screenshot(arg.isEmpty ? "shot" : arg) ? "ok" : "error: no window"
        case "dump":
            dump(arg.isEmpty ? "dump" : arg, m)
            return "ok"
        default:
            return "error: unknown command"
        }
    }

    private func settle(_ seconds: Double) async {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    private var window: UIWindow? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let scene = scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
        return scene?.windows.first { $0.isKeyWindow } ?? scene?.windows.first
    }

    private func dismissSheets() {
        window?.rootViewController?.dismiss(animated: false)
    }

    /// What's on screen, sheets included, as the app draws it (works on the simulator and on a phone).
    private func screenshot(_ name: String) -> Bool {
        guard let w = window else { return false }
        let img = UIGraphicsImageRenderer(bounds: w.bounds).image { _ in w.drawHierarchy(in: w.bounds, afterScreenUpdates: true) }
        guard let png = img.pngData() else { return false }
        return (try? png.write(to: Self.dir.appendingPathComponent("shots/\(name).png"))) != nil
    }

    /// The state as text a reader can check without the screen, plus the raw state.json.
    private func dump(_ name: String, _ m: AppModel) {
        let now = Date(), cal = m.cal
        let s = m.state
        var l: [String] = ["# \(name) at \(now.formatted(date: .abbreviated, time: .standard)) (\(TimeZone.current.identifier))",
                           "build: \(AppInfo.name) \(UpdateChecker.installed) (\(UpdateChecker.build)), onboarded: \(s.onboarded)",
                           "toast: \(m.toast ?? "none")"]
        if let r = m.running { l.append("running: \(r.title) since \(r.start.hm) [\(s.categories.pathText(r.category))]") }
        l.append("\n## Today")
        for d in m.dayEntries(now) {
            let kind = d.entry.isRunning ? "running" : d.isPlannedSession ? "planned" : d.assumed ? "assumed" : d.end <= now ? "done" : "later"
            l.append("\(d.start.hm)–\(d.end.hm) \(kind.padding(toLength: 8, withPad: " ", startingAt: 0)) \(d.title) [\(s.categories.pathText(d.category))]")
        }
        if let n = m.nowState(now: now) {
            l.append("now activity: \(n.card.kind.rawValue) “\(n.card.title)” " + n.card.buttons.map(\.label).joined(separator: " | ")
                     + (n.then.map { " → then \($0.kind.rawValue) at \(n.until?.hm ?? "?")" } ?? ""))
        }
        let r = m.rings(now)
        l.append("rings: work \(r.workLabel), tracked \(r.trackedLabel) (\(r.trackedSubtitle)), limit \(r.limitLabel)")
        l.append("grid: " + m.startButtons(now: now).row.map { $0.isPinned ? "\($0.title)📌" : $0.title }.joined(separator: ", "))
        let score = m.dayScore(now)
        l.append("score \(score.score): tracked \(Int(score.tracked)) work \(Int(score.work)) deadlines \(Int(score.deadlines)) scrolling \(Int(score.scrolling)); untracked \(score.untrackedMinutes)m, work \(score.workMinutes)/\(score.askedMinutes)m")
        l.append("\n## Plan (next 7 days)")
        for b in s.plan.blocks where b.isStudy && b.start < now.addingTimeInterval(7 * 86400) {
            l.append("\(b.start.formatted(.dateTime.weekday(.abbreviated))) \(b.start.hm)–\(b.end.hm) \(b.title)")
        }
        for w in s.plan.warnings { l.append("warning (\(w.level)): \(w.message)") }
        l.append("\n## Tasks")
        for t in s.items where t.isOpen {
            l.append("\(t.title) — due \(t.due.formatted(date: .abbreviated, time: .shortened)), \(t.completedMinutes)/\(t.estimateMinutes)m"
                     + (s.taskHistory.warning(for: t).map { " ⚠︎ \($0)" } ?? ""))
        }
        l.append("\n## Learned")
        l.append("adherence \(Int(s.learned.adherence * 100))% over \(s.learned.adherenceSamples) sessions, good hours \(s.learned.goodHours()), focus \(Int(s.learned.focusMinutes))m, through \(s.learned.learnedThrough ?? "-")")
        if !m.approvals.isEmpty { l.append("\n## Waiting for approval"); l += m.approvals.map { "- \($0.why)" } }
        if let q = s.inference.pending.first { l.append("\n## Question\n\(q.question ?? q.kind.rawValue) answers: \(q.answers)") }
        for g in s.leaderboard.groups {
            l.append("\n## Leaderboard \(g.name)")
            if let b = s.leaderboard.boards[g.id] {
                for r in Leaderboard.rows(b, metric: .score, you: g.memberId, today: now, calendar: cal) {
                    l.append("\(r.rank) \(r.name)\(r.isYou ? " (you)" : "") \(r.label)")
                }
            }
        }
        if let t = s.conversation.turns.last { l.append("\n## Last box turn\n> \(t.text)\n< \(t.reply)") }
        l.append("\n## Telemetry (last 20)")
        l += s.telemetry.events.suffix(20).map { "\($0.at.hm) \($0.area.rawValue) \($0.name) \($0.detail.map { "\($0.key)=\($0.value)" }.sorted().joined(separator: " "))" }
        let dumps = Self.dir.appendingPathComponent("dumps")
        try? l.joined(separator: "\n").write(to: dumps.appendingPathComponent("\(name).txt"), atomically: true, encoding: .utf8)
        try? FileManager.default.removeItem(at: dumps.appendingPathComponent("\(name).state.json"))
        try? FileManager.default.copyItem(at: Persistence.url, to: dumps.appendingPathComponent("\(name).state.json"))
    }
}

extension AppModel {
    /// Dev builds: replace everything with a seeded state (the `scenario` and `reset` test commands).
    func loadScenario(_ s: AppState) {
        guard AppInfo.isDev else { return }
        state = s
        toast = nil
        pendingInvite = nil
        learnAdherence()
        replan()
        save()
        deepLink = "productium://today"
    }
}
