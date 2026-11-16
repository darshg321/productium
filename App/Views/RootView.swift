import SwiftUI
import ProductiumCore

struct RootView: View {
    @Environment(AppModel.self) private var model
    @State private var tab = 0
    @State private var showAdd = false
    @State private var showGap = false

    var body: some View {
        Group {
            if model.state.onboarded {
                TabView(selection: $tab) {
                    TodayView(showAdd: $showAdd, showGap: $showGap)
                        .tabItem { Label("Today", systemImage: "circle.circle") }.tag(0)
                    PlanView(showAdd: $showAdd)
                        .tabItem { Label("Plan", systemImage: "calendar") }.tag(1)
                    InsightsView()
                        .tabItem { Label("Insights", systemImage: "chart.bar") }.tag(2)
                }
                .tint(Theme.accent)
            } else {
                OnboardingView()
            }
        }
        .overlay(alignment: .top) {
            if let t = model.toast {
                Toast(text: t)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .task(id: t) {
                        try? await Task.sleep(nanoseconds: 3_500_000_000)
                        withAnimation { model.toast = nil }
                    }
                    .onTapGesture { withAnimation { model.toast = nil } }
            }
        }
        .animation(.spring(duration: 0.35), value: model.toast)
        .sheet(isPresented: $showAdd) { QuickAddSheet().presentationDetents([.medium, .large]) }
        .sheet(isPresented: $showGap) { GapView() }
        .fullScreenCover(isPresented: Binding(get: { model.state.focus != nil }, set: { _ in })) { FocusView() }
        .onChange(of: model.deepLink) { _, link in
            guard let link else { return }
            switch link {
            case "productium://gap": showGap = true
            case "productium://add": showAdd = true
            case "productium://plan": tab = 1
            case "productium://insights": tab = 2
            default: tab = 0
            }
            model.deepLink = nil
        }
    }
}

/// Floating add button: the one control that's always there.
struct AddButton: View {
    @Binding var show: Bool
    var body: some View {
        Button { show = true } label: {
            Image(systemName: "plus")
                .font(.title2.weight(.semibold))
                .foregroundStyle(.white)
                .frame(width: 56, height: 56)
                .background(Theme.accent, in: Circle())
                .shadow(color: Theme.accent.opacity(0.35), radius: 10, y: 4)
        }
        .padding(20)
        .accessibilityLabel("Add or check in")
    }
}
