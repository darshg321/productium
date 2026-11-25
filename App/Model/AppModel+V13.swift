import Foundation
import UIKit
import ProductiumCore

// v1.3 model actions: the Now Live Activity (B), the rings (D), the activity grid (A).

extension AppModel {
    // MARK: B: the Now activity

    func nowState(now: Date = Date()) -> NowState? {
        NowActivity.make(NowInput(now: now, calendar: cal, entries: state.entries, plan: state.plan, items: state.items,
                                  book: state.dayRules, tree: state.categories, question: state.inference.pending.first,
                                  tiles: startButtons(now: now).top, prompts: state.prefs.prompts, goalLine: goalLine(for: running),
                                  paused: state.paused, resumedEnds: resumedEnds))
    }

    /// After every replan, intent and button press (each keeps it alive), and when the app goes to the background (B2).
    func syncNowActivity() {
        let foreground = UIApplication.shared.applicationState != .background
        RunningActivity.sync(nowState(), rings: rings(Date()), busy: aiWorking, foreground: foreground)
        checkRings()
    }

    /// A Now activity button (`NowActionIntent`), run in the app's process.
    func nowAction(_ action: String) {
        log(.intent, "now_action", ["action": String(action.prefix(60))])
        let parts = action.split(separator: ":", maxSplits: 1).map(String.init)
        let arg = parts.count > 1 ? parts[1] : ""
        switch parts.first ?? "" {
        case "stop":
            stopRunning(source: "live activity")
        case "pause":
            pauseRunning(source: "live activity")
        case "resume":
            resumePaused(source: "live activity")
        case "start":
            start(title: arg, source: "live activity")
        case "answer":
            let bits = arg.split(separator: ":", maxSplits: 1).map(String.init)
            if bits.count == 2, let q = state.inference.pending.first(where: { $0.id == bits[0] }) {
                resolveQuestion(q, bits[1])
                replan()
            }
        case "yes", "no":
            if let d = dayEntries(Date()).first(where: { $0.ref == arg }) {
                if parts[0] == "yes" { confirm(d) } else { reject(d) }
            }
        case "task":
            if let id = UUID(uuidString: arg), let item = state.items.first(where: { $0.id == id && $0.isOpen }) { startTask(item) }
        case "done":
            if let id = UUID(uuidString: arg) { complete(id) }
        case "extend":
            let bits = arg.split(separator: ":").map(String.init)
            if let id = bits.first.flatMap(UUID.init(uuidString:)) { extend(id, minutes: bits.count > 1 ? Int(bits[1]) ?? 15 : 15) }
        default:
            break
        }
        syncNowActivity()
    }

    // MARK: v1.5: how focused a session was

    /// 1 unfocused, 2 focused; 0 = you skipped the question.
    func rateFocus(_ id: UUID, _ focus: Int) {
        guard let i = state.entries.firstIndex(where: { $0.id == id }) else { return }
        state.entries[i].focus = focus
        log(.log, "focus_rated", ["title": state.entries[i].title, "focus": "\(focus)"])
        NotificationService.clearDelivered(prefixes: ["rate.\(id)"])
        Haptics.tap()
        save()
    }

    /// Work that just stopped while the app isn't in front asks its focus by notification instead of on Today.
    func askFocusIfAway() {
        let now = Date()
        guard UIApplication.shared.applicationState != .active,
              let e = TimeLog.unratedWork(state.entries, tree: state.categories, now: now),
              now.timeIntervalSince(e.end ?? e.start) < 120 else { return }
        NotificationService.askFocus(e.title, entryId: e.id)
    }

    // MARK: D: the rings

    var ringLimit: Int { DayRings.limit(goals: state.goals, taper: state.taper, tree: state.categories) }

    func rings(_ day: Date) -> DayRings {
        memo("rings-" + DayKeys.key(day, cal), now: Date()) { ringsNow(day) }
    }

    /// F1: the days the rings page through (oldest first, up to 30, from when you started).
    var ringDays: [Date] {
        let today = cal.startOfDay(for: Date())
        let first = max(trackingStart, cal.date(byAdding: .day, value: -29, to: today) ?? today)
        let n = max(0, cal.dateComponents([.day], from: first, to: today).day ?? 0)
        return (0...n).compactMap { cal.date(byAdding: .day, value: $0 - n, to: today) }
    }

    /// Today's resolved log (Today's cards share one computation per minute).
    func todaySlices(_ now: Date) -> [LogSlice] {
        memo("todaySlices", now: now) {
            TimeLog.past(state.entries, in: Days.dayInterval(now, cal), now: now, book: state.dayRules, calendar: cal)
        }
    }

    private func ringsNow(_ day: Date) -> DayRings {
        DayRings.make(day, asked: state.dayPlans[DayKeys.key(day, cal)] ?? [:], entries: state.entries, items: state.items,
                      tree: state.categories, limit: ringLimit, now: Date(), book: state.dayRules, calendar: cal)
    }

    /// The Work ring closing gets the goal celebration (once a day; the Tracked ring has the tracked-day one at bedtime).
    func checkRings() {
        if rings(Date()).workClosed { celebrate(.goalClosed(title: "Work", weekly: false, daysThisMonth: nil)) }
    }

    // MARK: A: the activity grid

    /// Onboarding: the templates, minus the ones you unticked.
    func seedGrid(skipping: Set<String>) {
        state.quickStarts.seedTemplates(at: Date(), skip: skipping)
        save()
    }

    func pinTile(_ b: QuickStart, at slot: Int?) {
        state.quickStarts.pin(b.id, at: slot)
        save()
    }

    func hideTile(_ b: QuickStart) {
        state.quickStarts.remove(b.id)
        log(.log, "tile_hidden", ["title": b.title])
        save()
    }
}
