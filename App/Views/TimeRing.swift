import SwiftUI
import Charts
import ProductiumCore

// v1.2 G2: the ring. Inner ring = groups, outer ring = their level-2 categories; actual time solid, the forecast (or
// the plan) faint and outlined. Tap a slice to drill into its leaves and entries. Every colour also has a symbol and a
// word in the legend, so it reads in grayscale (v1.1 J).

struct TimeRing: View {
    let ring: RingModel
    let tree: CategoryTree
    var goals: [Goal] = []
    @Binding var selection: String?
    var centre: String
    var centreCaption: String
    @State private var angle: Int?

    struct Piece: Identifiable {
        let id: String
        let slice: String
        let minutes: Int
        let forecast: Bool
        let color: Color
    }

    private func pieces(_ slices: [RingSlice], group: Bool) -> [Piece] {
        slices.flatMap { s -> [Piece] in
            let c = group ? Theme.color(group: s.group) : Theme.color(category: s.id, tree: tree)
            let solid = s.id == CategoryTree.untracked && group ? Color(.systemGray4) : c
            return [Piece(id: s.id + "|a", slice: s.id, minutes: s.minutes, forecast: false, color: solid),
                    Piece(id: s.id + "|f", slice: s.id, minutes: s.forecast, forecast: true, color: solid)].filter { $0.minutes > 0 }
        }
    }

    var body: some View {
        let inner = pieces(ring.groups, group: true)
        let outer = pieces(ring.categories, group: false)
        ZStack {
            chart(outer, inner: 0.72, outerR: 1.0)
                .chartAngleSelection(value: $angle)
            chart(inner, inner: 0.5, outerR: 0.68)
                .allowsHitTesting(false)
            VStack(spacing: 2) {
                if let sel = selectedSlice(outer) {
                    Text(durationLabel(sel.minutes + sel.forecast)).font(.title3.weight(.semibold)).monospacedDigit()
                    Text(sel.name).font(.caption).foregroundStyle(.secondary)
                } else {
                    Text(centre).font(.title3.weight(.semibold)).monospacedDigit()
                    Text(centreCaption).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .onChange(of: angle) { _, a in
            guard a != nil, let s = selectedSlice(outer) else { return }
            selection = s.id
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(ring.categories.filter { $0.minutes > 0 }.prefix(6).map { "\($0.name) \(durationLabel($0.minutes))" }.joined(separator: ", "))
    }

    private func selectedSlice(_ pieces: [Piece]) -> RingSlice? {
        guard let a = angle else { return nil }
        var acc = 0
        for p in pieces {
            acc += p.minutes
            if a < acc { return ring.categories.first { $0.id == p.slice } }
        }
        return nil
    }

    private func chart(_ pieces: [Piece], inner: CGFloat, outerR: CGFloat) -> some View {
        Chart(pieces) { p in
            SectorMark(angle: .value("Minutes", p.minutes), innerRadius: .ratio(inner), outerRadius: .ratio(outerR), angularInset: 0.8)
                .foregroundStyle(p.forecast ? p.color.opacity(0.28) : p.color)
                .opacity(selection == nil || selection == p.slice || !pieces.contains { $0.slice == selection } ? 1 : 0.45)
        }
        .chartLegend(.hidden)
    }
}

struct RingLegend: View {
    let ring: RingModel
    let tree: CategoryTree

    var body: some View {
        let shown = ring.categories.filter { $0.minutes + $0.forecast >= 10 }.prefix(8)
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), alignment: .leading)], alignment: .leading, spacing: 6) {
            ForEach(Array(shown), id: \.id) { s in
                HStack(spacing: 6) {
                    Image(systemName: Theme.symbol(category: s.id, tree: tree))
                        .foregroundStyle(Theme.color(category: s.id, tree: tree)).frame(width: 18)
                    Text(s.name).font(.caption).lineLimit(1)
                    Spacer(minLength: 2)
                    Text(durationLabel(s.minutes)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    if let d = s.delta, d != 0 {
                        Text("\(d > 0 ? "▲" : "▼") \(durationLabel(abs(d)))").font(.caption2).foregroundStyle(.secondary)
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
                        .disabled(s.entry == nil)
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
