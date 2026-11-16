import Foundation
#if canImport(ActivityKit)
import ActivityKit

/// Live Activity for the block that's happening now (lock screen + Dynamic Island).
struct BlockActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var title: String
        var start: Date
        var end: Date
        var kind: String
        var nextTitle: String?
    }
    var startedFromApp: Bool
}
#endif
