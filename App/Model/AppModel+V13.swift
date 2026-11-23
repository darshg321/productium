import Foundation
import UIKit
import ProductiumCore

// v1.3 model actions: the Now Live Activity (B), the rings (D), the activity grid (A).

extension AppModel {
    // MARK: B: the Now activity

    func nowState(now: Date = Date()) -> NowState? {
        NowActivity.make(NowInput(now: now, calendar: cal, entries: state.entries, plan: state.plan, items: state.items,
                                  book: state.dayRules, tree: state.categories, question: state.inference.pending.first,
                                  tiles: startButtons(now: now).top, prompts: state.prefs.prompts, goalLine: goalLine(for: running)))
    }

    /// After every replan, intent and button press (each keeps it alive), and when the app goes to the background (B2).
    func syncNowActivity() {
        let foreground = UIApplication.shared.applicationState != .background
        RunningActivity.sync(nowState(), rings: rings(Date()), foreground: foreground)
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
        default:
            break
        }
        syncNowActivity()
    }

    // MARK: D: the rings

    var ringLimit: Int { DayRings.limit(goals: state.goals, taper: state.taper, tree: state.categories) }

    func rings(_ day: Date) -> DayRings {
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
