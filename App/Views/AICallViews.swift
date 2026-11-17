import SwiftUI
import ProductiumCore

// MARK: - Subscription

/// How much of the Claude subscription behind the server is used: one bar per limit (the
/// 5-hour session and the weekly ones), with when each resets.
struct SubscriptionSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Section {
            if let s = model.subscription {
                if s.limits.isEmpty {
                    if let e = s.last_event {
                        LabeledContent("Status", value: (e.status ?? "unknown").replacingOccurrences(of: "_", with: " ").capitalized)
                        if let u = e.utilization { meter(label: e.type.map(windowName) ?? "Current limit", percent: u * 100, resets: e.resets_at.map { Date(timeIntervalSince1970: $0) }) }
                        else if let r = e.resets_at { LabeledContent("Resets", value: Date(timeIntervalSince1970: r).formatted(date: .abbreviated, time: .shortened)) }
                    }
                    Text(s.legacy == true
                         ? "This server is older and only knows the last limit status. Update claude-server for real percentages."
                         : s.error.map { "Couldn't read the percentages: \($0)." } ?? "No limits reported.")
                        .font(.footnote).foregroundStyle(.secondary)
                } else {
                    ForEach(s.limits) { l in meter(label: l.label, percent: l.percent, resets: l.resetsAt) }
                }
            } else {
                Text(ClaudeClient.shared.isConfigured ? "Loading…" : "Connect Claude to see the subscription.")
                    .foregroundStyle(.secondary)
            }
        } header: {
            HStack {
                Text("Subscription")
                Spacer()
                if let p = model.subscription?.plan { Text(p.capitalized) }
            }
        } footer: {
            if let at = model.subscription?.fetchedAt {
                Text("From Anthropic via your server, \(at.formatted(.relative(presentation: .named))). Shared by everything that uses the subscription, not just this app.")
            }
        }
    }

    private func windowName(_ t: String) -> String {
        switch t {
        case "five_hour": return "Current session (5 h)"
        case "seven_day": return "This week"
        default: return t.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }

    private func meter(label: String, percent: Double, resets: Date?) -> some View {
        let f = percent / 100
        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(label).font(.subheadline)
                Spacer()
                Text("\(Int(percent.rounded()))% used").font(.subheadline.monospacedDigit().weight(.semibold))
                    .foregroundStyle(Theme.meter(f))
            }
            ProgressView(value: min(1, max(0, f))).tint(Theme.meter(f))
            if let r = resets {
                Text("\(Int(max(0, 100 - percent).rounded()))% left · resets \(r.formatted(.relative(presentation: .named)))")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Calls

struct AICallRow: View {
    let call: AICall

    var body: some View {
        HStack(spacing: 12) {
            IconTile(symbol: call.ok ? Theme.symbol(for: call.feature) : "exclamationmark.triangle.fill",
                     color: call.ok ? Theme.color(for: call.feature) : Theme.alert, size: 24)
            VStack(alignment: .leading, spacing: 1) {
                Text(call.feature.title + (call.attempt > 1 ? " (retry)" : "")).font(.subheadline)
                Text(preview).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                Text("\(call.at.relativeDay.capitalized), \(call.at.hm) · \(call.model ?? call.requestedModel) · \(seconds)")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 1) {
                if let t = call.tokens {
                    Text(tokensLabel(t.counted)).font(.subheadline.monospacedDigit())
                    Text("out").font(.caption2).foregroundStyle(.secondary)
                } else {
                    Text(call.status.map { "HTTP \($0)" } ?? "Failed").font(.caption).foregroundStyle(Theme.alert)
                }
            }
        }
    }

    private var seconds: String { String(format: "%.1f s", Double(call.durationMs) / 1000) }

    /// What the student typed (after the context), or the first line of the request.
    private var preview: String {
        let last = call.messages.last?.content ?? ""
        if let r = last.range(of: "\nStudent:\n") { return String(last[r.upperBound...]).replacingOccurrences(of: "\n", with: " ") }
        return last.replacingOccurrences(of: "\n", with: " ")
    }
}

/// Every call this phone made, newest first.
struct AICallListView: View {
    @Environment(AppModel.self) private var model
    @State private var feature: AIFeature?
    @State private var confirmClear = false

    var body: some View {
        let calls = model.callLog.calls.reversed().filter { feature == nil || $0.feature == feature }
        List {
            Section {
                Picker("Show", selection: $feature) {
                    Text("All").tag(AIFeature?.none)
                    ForEach(AIFeature.allCases, id: \.self) { Text($0.title).tag(AIFeature?.some($0)) }
                }
            }
            Section {
                if calls.isEmpty { Text("No requests yet.").foregroundStyle(.secondary) }
                ForEach(calls) { c in
                    NavigationLink { AICallDetailView(call: c) } label: { AICallRow(call: c) }
                }
            } footer: {
                Text("The last \(AICallLog.maxCalls) requests from the past two weeks, kept only on this phone.")
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Requests")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Clear", role: .destructive) { confirmClear = true }.disabled(model.callLog.calls.isEmpty)
            }
        }
        .confirmationDialog("Delete the saved prompts and replies?", isPresented: $confirmClear, titleVisibility: .visible) {
            Button("Delete All", role: .destructive) { model.clearCallLog() }
        }
    }
}

/// One request in full: what was sent (system prompt, each message, the schema) and the raw reply.
struct AICallDetailView: View {
    let call: AICall
    @State private var prettyReply = true

    var body: some View {
        List {
            Section {
                LabeledContent("Feature", value: call.feature.title + (call.attempt > 1 ? " (second try)" : ""))
                LabeledContent("When", value: call.at.formatted(date: .abbreviated, time: .standard))
                LabeledContent("Model", value: call.model ?? call.requestedModel)
                LabeledContent("Status", value: call.status.map { "HTTP \($0)" } ?? "No response")
                LabeledContent("Took", value: String(format: "%.1f s", Double(call.durationMs) / 1000))
                if let t = call.tokens {
                    LabeledContent("Output tokens", value: "\(t.output)")
                    LabeledContent("Input tokens", value: "\(t.input) + \(t.cacheRead) cached, \(t.cacheWrite) cache write")
                }
                LabeledContent("max_tokens", value: "\(call.maxTokens)")
                if let ttl = call.cacheTTL { LabeledContent("Reply cache", value: "\(ttl) s") }
                if let e = call.error {
                    Text(e).font(.footnote).foregroundStyle(Theme.alert).textSelection(.enabled)
                }
            }
            block("System prompt", call.system)
            ForEach(Array(call.messages.enumerated()), id: \.offset) { i, m in
                block("\(m.role.capitalized) message \(i + 1)" + (m.images > 0 ? " · \(m.images) image\(m.images == 1 ? "" : "s")" : ""), m.content)
            }
            if let s = call.schema { block("Schema", s, collapsed: true) }
            Section {
                Toggle("Pretty-print", isOn: $prettyReply)
                CodeText(text: prettyReply ? call.prettyResponse : call.response)
            } header: {
                HStack { Text("Response"); Spacer(); copy(call.response) }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(call.feature.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                ShareLink(item: call.transcript, preview: SharePreview("\(call.feature.title) request")) {
                    Image(systemName: "square.and.arrow.up")
                }
            }
        }
    }

    @ViewBuilder private func block(_ title: String, _ text: String, collapsed: Bool = false) -> some View {
        Section {
            if collapsed {
                DisclosureGroup("\(text.count) characters") { CodeText(text: text) }
            } else {
                CodeText(text: text)
            }
        } header: {
            HStack { Text(title); Spacer(); copy(text) }
        }
    }

    private func copy(_ text: String) -> some View {
        Button { UIPasteboard.general.string = text } label: { Image(systemName: "doc.on.doc") }
            .buttonStyle(.borderless)
            .accessibilityLabel("Copy")
    }
}

/// Long monospaced text that can be selected. Very long text is shown in pieces so the list stays fast.
struct CodeText: View {
    let text: String

    var body: some View {
        let chunks = text.isEmpty ? ["(empty)"] : stride(from: 0, to: text.count, by: 4000).map { i -> String in
            let s = text.index(text.startIndex, offsetBy: i)
            let e = text.index(s, offsetBy: 4000, limitedBy: text.endIndex) ?? text.endIndex
            return String(text[s..<e])
        }
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(chunks.enumerated()), id: \.offset) { _, c in
                Text(c).font(.caption.monospaced()).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}
