import Foundation
import ActivityKit
import AppIntents

/// v1.3 B: the one "Now" activity, always there: running, a question, untracked time, assumed time, or up next.
/// A mirror of ProductiumCore's `NowCard` (the extension doesn't link the core).
struct NowAttributes: ActivityAttributes {
    struct Button: Codable, Hashable {
        /// Run by `NowActionIntent` in the app: stop, start:<title>, answer:<id>:<answer>, yes:<ref>, no:<ref>, task:<id>,
        /// done:<task id>, extend:<task id>:<minutes>.
        var action: String
        var label: String
        var symbol: String?
    }

    struct Card: Codable, Hashable {
        /// running, question, untracked, assumed, upNext
        var kind: String
        var title: String
        var subtitle: String?
        var since: Date?
        var buttons: [Button]
        var other: Bool
        /// A task session's planned end: the timer counts down to it.
        var ends: Date?
        /// v1.6 C2: a task's first step and due day, under the subtitle.
        var detail: String?
    }

    /// D2: today's three rings, small, in the expanded view.
    struct Rings: Codable, Hashable {
        var work: Double
        var tracked: Double
        var limit: Double
        var workLabel: String
        var trackedLabel: String
        var limitLabel: String
    }

    struct ContentState: Codable, Hashable {
        var card: Card
        /// Shown once the content is stale (`ActivityContent.staleDate` = when `card` stops being true).
        var then: Card?
        var rings: Rings?
        /// "Sorting categories": Claude is working in the background.
        var busy: String?
    }
}

/// A button on the Now activity. Runs in the app's process, so it logs, replans and updates the activity in place.
struct NowActionIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "Now Activity Button"
    static var isDiscoverable = false

    @Parameter(title: "Action") var action: String

    init() {}
    init(action: String) { self.action = action }

    @MainActor
    func perform() async throws -> some IntentResult {
        #if !WIDGET_EXTENSION
        AppModel.shared.nowAction(action)
        #endif
        return .result()
    }
}

// The intents below run in the app's process (LiveActivityIntent), so the extension's copies never do any work.

struct StopActivityIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "Stop Activity"
    static var description = IntentDescription("Stops whatever is being tracked. Use it from Back Tap, a sticker, or a Focus turning off.")

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        #if WIDGET_EXTENSION
        return .result(dialog: "Stopped.")
        #else
        AppModel.shared.log(.intent, "StopActivityIntent")
        let title = AppModel.shared.running?.title
        AppModel.shared.stopRunning(source: "intent")
        return .result(dialog: title.map { "Stopped \($0)." } ?? "Nothing was running.")
        #endif
    }
}

struct StartFocusIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "Start focus"
    static var description = IntentDescription("Start the block that's on now, or the next one. Try it from an NFC tag on your desk, or when a Focus turns on.")
    static var openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        #if !WIDGET_EXTENSION
        AppModel.shared.log(.intent, "StartFocusIntent")
        AppModel.shared.startNowOrNext()
        #endif
        return .result()
    }
}
