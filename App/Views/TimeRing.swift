import SwiftUI
import Charts
import ProductiumCore

// v1.3 Review: where the time went, drawn like Screen Time: one bar split by category, then the categories as rows
// (colour, symbol and word together, so it reads in grayscale), each with its change against the period before.

struct TimeBreakdown: View {
    let ring: RingModel
    let tree: CategoryTree
    var showSleep = false
    var limit = 7
    var onSelect: (String) -> Void = { _ in }

    private func color(_ s: RingSlice) -> Color {
        s.id == CategoryTree.untracked ? Color(.systemGray4) : Theme.color(category: s.id, tree: tree)
    }

    var body: some View {
        let slices = ring.categories.filter { $0.minutes > 0 && $0.id != CategoryTree.untracked
            && (showSleep || !tree.isUnder($0.id, CategoryTree.sleep)) }
            .sorted { $0.minutes > $1.minutes }
        let total = max(1, slices.reduce(0) { $0 + $1.minutes })
        let most = max(1, slices.first?.minutes ?? 1)
        VStack(alignment: .leading, spacing: 12) {
            GeometryReader { g in
                HStack(spacing: 2) {
                    ForEach(slices) { s in
                        Rectangle().fill(color(s))
                            .frame(width: max(2, (g.size.width - CGFloat(slices.count) * 2) * CGFloat(s.minutes) / CGFloat(total)))
                    }
                }
                .clipShape(Capsule())
            }
            .frame(height: 14)
            .accessibilityHidden(true)
            ForEach(slices.prefix(limit)) { s in
                Button { onSelect(s.id) } label: {
                    HStack(spacing: 12) {
                        IconTile(symbol: s.id == CategoryTree.untracked ? "questionmark" : Theme.symbol(category: s.id, tree: tree),
                                 color: color(s))
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(alignment: .firstTextBaseline) {
                                Text(s.name).lineLimit(1)
                                Spacer(minLength: 6)
                                Text(minutesLabel(s.minutes)).monospacedDigit().foregroundStyle(.secondary)
                            }
                            GeometryReader { g in
                                Capsule().fill(color(s).opacity(0.85))
                                    .frame(width: max(4, g.size.width * CGFloat(s.minutes) / CGFloat(most)), height: 5)
                            }
                            .frame(height: 5)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(s.name), \(durationLabel(s.minutes))")
            }
        }
    }
}

/// Tap a slice: its leaves, then the entries themselves (each opens the entry sheet).
struct DrillSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let id: String
    let range: DateInterval
    let title: String
    @State private var editing: DayEntry?

    var body: some View {
        let tree = model.state.categories
        let slices = TimeLog.past(model.state.entries, in: range, now: Date(), book: model.state.dayRules, calendar: .current)
            .filter { s in
                if let g = CategoryGroup(rawValue: id) { return tree.group(s.category) == g }
                return s.category == id || tree.isUnder(s.category, id)
            }
        let byLeaf = Dictionary(grouping: slices, by: \.category).mapValues { $0.reduce(0) { $0 + $1.minutes } }
        NavigationStack {
            List {
                Section("By category") {
                    ForEach(byLeaf.sorted { $0.value > $1.value }, id: \.key) { k, m in
                        LabeledContent {
                            Text(durationLabel(m)).monospacedDigit()
                        } label: {
                            Label(tree.pathText(k), systemImage: Theme.symbol(category: k, tree: tree))
                        }
                    }
                }
                Section("Entries") {
                    ForEach(Array(slices.enumerated()), id: \.offset) { _, s in
                        Button {
                            editing = s.entry
                        } label: {
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(s.entry?.title ?? "Untracked")
                                    Text("\(s.start.hm)–\(s.end.hm)" + (s.assumed ? " · assumed" : "")).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Text(durationLabel(s.minutes)).font(.caption.monospacedDigit())
                            }
                        }
                        .disabled(s.entry == nil || s.category == CategoryTree.transition)
                    }
                }
            }
            .navigationTitle(id == CategoryTree.untracked ? "Untracked" : (CategoryGroup(rawValue: id)?.title ?? tree.pathText(id)))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .sheet(item: $editing) { EntrySheet(day: $0) }
        }
    }
}
