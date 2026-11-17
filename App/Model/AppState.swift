import Foundation
import ProductiumCore

struct SavedPlace: Codable, Hashable, Identifiable {
    var id: String          // "home", "school", or a custom id
    var name: String
    var latitude: Double
    var longitude: Double
    var radius: Double = 120
}

struct Integrations: Codable, Hashable {
    var health = false
    var calendarImport = false
    var calendarExport = false
    var screenTime = false
    var location = false
    var alarms = false
    var liveActivities = true
    var notifications = false
}

struct FocusSession: Codable, Hashable {
    var blockId: UUID
    var itemId: UUID?
    var title: String
    var startedAt: Date
    var plannedEnd: Date
}

/// Everything the app persists. Every field decodes with a default, so app updates
/// that add fields never wipe a student's data.
struct AppState: Codable {
    var onboarded = false
    var prefs = Preferences()
    var items: [WorkItem] = []
    var commitments: [Commitment] = []
    var routines: [Routine] = Routine.defaults
    var markers: [TimelineEvent] = []
    var outcomes: [BlockOutcome] = []
    var moods: [MoodEntry] = []
    var health: [HealthDay] = []
    var screen: [ScreenDay] = []
    var events: [FixedEvent] = []          // calendar cache
    var oneOffs: [FixedEvent] = []         // one-off busy time from the brain dump
    var exceptions: [DayException] = []    // one-day changes ("no school today")
    var learned = LearnedModel()
    var taper = ScreenTaper()
    var flashcards: [Flashcard] = []
    var reads: [ReadPiece] = []
    var plan: Plan = .empty
    var places: [SavedPlace] = []
    var integrations = Integrations()
    var review: WeeklyReview?
    var reviewAt: Date?
    /// The Inbox box: one ongoing AI session until it's cleared.
    var conversation = Conversation(startedAt: Date())
    /// Cleared conversations ("Past prompts").
    var archive = ConversationArchive()
    var focus: FocusSession?
    var learnedDays: Set<String> = []
    var dismissed: Set<String> = []
    var usage = UsageLedger()              // AI token meter
    var snoozed: [UUID: Date] = [:]        // block → when its snooze reminder fires

    var dumpState: DumpState {
        get {
            DumpState(items: items, commitments: commitments, exceptions: exceptions, oneOffs: oneOffs, markers: markers,
                      routines: routines, moods: moods, screen: screen, prefs: prefs)
        }
        set {
            items = newValue.items
            commitments = newValue.commitments
            exceptions = newValue.exceptions
            oneOffs = newValue.oneOffs
            markers = newValue.markers
            routines = newValue.routines
            moods = newValue.moods
            screen = newValue.screen
            prefs = newValue.prefs
        }
    }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AppState()
        func v<T: Decodable>(_ k: CodingKeys, _ def: T) -> T { (try? c.decodeIfPresent(T.self, forKey: k)) ?? def }
        onboarded = v(.onboarded, d.onboarded)
        prefs = v(.prefs, d.prefs)
        items = v(.items, d.items)
        commitments = v(.commitments, d.commitments)
        routines = v(.routines, d.routines)
        markers = v(.markers, d.markers)
        outcomes = v(.outcomes, d.outcomes)
        moods = v(.moods, d.moods)
        health = v(.health, d.health)
        screen = v(.screen, d.screen)
        events = v(.events, d.events)
        oneOffs = v(.oneOffs, d.oneOffs)
        exceptions = v(.exceptions, d.exceptions)
        learned = v(.learned, d.learned)
        taper = v(.taper, d.taper)
        flashcards = v(.flashcards, d.flashcards)
        reads = v(.reads, d.reads)
        plan = v(.plan, d.plan)
        places = v(.places, d.places)
        integrations = v(.integrations, d.integrations)
        review = v(.review, d.review)
        reviewAt = v(.reviewAt, d.reviewAt)
        conversation = v(.conversation, d.conversation)
        archive = v(.archive, d.archive)
        focus = v(.focus, d.focus)
        learnedDays = v(.learnedDays, d.learnedDays)
        dismissed = v(.dismissed, d.dismissed)
        usage = v(.usage, d.usage)
        snoozed = v(.snoozed, d.snoozed)
    }

    var backup: Backup {
        Backup(exportedAt: Date(), preferences: prefs, items: items, commitments: commitments, routines: routines,
               markers: markers, outcomes: outcomes, moods: moods, health: health, screen: screen,
               learned: learned, taper: taper, flashcards: flashcards)
    }

    mutating func restore(_ b: Backup) {
        prefs = b.preferences
        items = b.items
        commitments = b.commitments
        routines = b.routines
        markers = b.markers
        outcomes = b.outcomes
        moods = b.moods
        health = b.health
        screen = b.screen
        learned = b.learned
        taper = b.taper
        flashcards = b.flashcards
        onboarded = true
    }

    /// Keep the file small: old fine-grained data is pruned (aggregates live in learned/taper).
    mutating func prune(now: Date) {
        let cutoff = now.addingTimeInterval(-180 * 86400)
        markers.removeAll { $0.at < cutoff }
        outcomes.removeAll { $0.plannedStart < cutoff }
        health.removeAll { $0.day < cutoff }
        screen.removeAll { $0.day < cutoff }
        items.removeAll { $0.isDone && ($0.doneAt ?? $0.due) < cutoff }
        reads.removeAll { ($0.readAt ?? $0.createdAt) < now.addingTimeInterval(-30 * 86400) }
        exceptions.removeAll { $0.day < now.addingTimeInterval(-60 * 86400) }
        oneOffs.removeAll { $0.end < cutoff }
        usage.prune(now: now)
        snoozed = snoozed.filter { $0.value > now.addingTimeInterval(-3600) }
    }

    /// Restore from a full backup. Permissions (integrations) belong to this phone, not the
    /// backup, so they're kept, and a focus session from another time is dropped.
    mutating func restore(full s: AppState) {
        let device = integrations
        self = s
        integrations = device
        focus = nil
        onboarded = true
    }
}

/// The whole app in one file: every piece of state plus the few settings kept outside it.
/// Written by Settings → Backup, read back by Restore (on this phone or another).
struct FullBackup: Codable {
    static let formatID = "productium-backup"
    var format = FullBackup.formatID
    var version = 2
    var exportedAt: Date
    var appVersion: String?
    var serverURL: String?
    var nudgeOnShield: Bool?
    var state: AppState

    static func encoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }

    static func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }
}

/// What a backup file holds, shown before it replaces anything.
struct RestorePreview: Identifiable {
    let id = UUID()
    var exportedAt: Date?
    var summary: String
    var full: FullBackup?
    var legacy: Backup?
}

enum Persistence {
    static var url: URL { SharedConfig.containerURL.appendingPathComponent("state.json") }

    static func load() -> AppState {
        guard let data = try? Data(contentsOf: url) else { return AppState() }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return (try? dec.decode(AppState.self, from: data)) ?? AppState()
    }

    static func save(_ s: AppState) {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        guard let data = try? enc.encode(s) else { return }
        try? data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
}

/// The full AI call log (prompts and replies) lives in its own file: it's for reading when
/// something looks off, and keeping it out of state.json keeps every save small.
enum CallLogStore {
    static var url: URL { SharedConfig.containerURL.appendingPathComponent("ai-calls.json") }

    static func load() -> AICallLog {
        guard let data = try? Data(contentsOf: url) else { return AICallLog() }
        return (try? FullBackup.decoder().decode(AICallLog.self, from: data)) ?? AICallLog()
    }

    static func save(_ log: AICallLog) {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        guard let data = try? enc.encode(log) else { return }
        try? data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
}
