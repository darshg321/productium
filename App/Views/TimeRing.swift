import SwiftUI
import Charts
import ProductiumCore

// v1.3 Review: where the time went, drawn like Screen Time: one bar split by category, then the categories as rows
// (colour, symbol and word together, so it reads in grayscale), each with its change against the period before.

struct TimeBreakdown: View {
    let ring: RingModel
    let tree: CategoryTree
    var showSleep = false
    var onSelect: (String) -> Void = { _ in }

    var body: some View {
        let slices = ring.categories.filter { $0.minutes > 0 && $0.id != CategoryTree.untracked
            && (showSleep || !tree.isUnder($0.id, CategoryTree.sleep)) }
        let groups = CategoryGroup.allCases.compactMap { g -> (CategoryGroup, [RingSlice], Int)? in
            let mine = slices.filter { $0.group == g }.sorted { $0.minutes > $1.minutes }
            let total = mine.reduce(0) { $0 + $1.minutes }
            return total > 0 ? (g, mine, total) : nil
        }
        let total = max(1, groups.reduce(0) { $0 + $1.2 })
        VStack(alignment: .leading, spacing: 14) {
            // One bar by group (four colours that are easy to tell apart), then each group with its categories.
            GeometryReader { g in
                HStack(spacing: 2) {
                    ForEach(groups, id: \.0) { grp, _, mins in
                        Rectangle().fill(Theme.color(group: grp))
                            .frame(width: max(3, (g.size.width - CGFloat(groups.count) * 2) * CGFloat(mins) / CGFloat(total)))
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
            }
            .frame(height: 18)
            .accessibilityHidden(true)
            ForEach(groups, id: \.0) { grp, mine, mins in
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .firstTextBaseline) {
                        HStack(spacing: 8) {
                            RoundedRectangle(cornerRadius: 3, style: .continuous).fill(Theme.color(group: grp)).frame(width: 12, height: 12)
                            Text(grp.title).font(.headline)
                        }
                        Spacer()
                        Text(minutesLabel(mins)).font(.headline.monospacedDigit())
                        Text("\(Int((Double(mins) / Double(total) * 100).rounded()))%").font(.subheadline.monospacedDigit())
                            .foregroundStyle(.secondary).frame(width: 40, alignment: .trailing)
                    }
                    ForEach(mine) { s in
                        Button { onSelect(s.id) } label: {
                            HStack(spacing: 10) {
                                Image(systemName: Theme.symbol(category: s.id, tree: tree))
                                    .font(.subheadline).foregroundStyle(Theme.color(category: s.id, tree: tree)).frame(width: 24)
                                Text(s.name).lineLimit(1)
                                Spacer(minLength: 6)
                                Text(minutesLabel(s.minutes)).monospacedDigit().foregroundStyle(.secondary)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("\(s.name), \(minutesLabel(s.minutes))")
                    }
                }
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
