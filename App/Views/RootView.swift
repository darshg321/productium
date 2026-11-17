import SwiftUI
import ProductiumCore

struct RootView: View {
    @Environment(AppModel.self) private var model
    @State private var tab = 0
    @State private var showGap = false

    var body: some View {
        Group {
            if model.state.onboarded {
                TabView(selection: $tab) {
                    TodayView(showGap: $showGap)
                        .tabItem { Label("Today", systemImage: "sun.max.fill") }.tag(0)
                    ScheduleView()
                        .tabItem { Label("Schedule", systemImage: "calendar.day.timeline.left") }.tag(1)
                    TasksView()
                        .tabItem { Label("Tasks", systemImage: "checklist") }.tag(2)
                    ReviewView()
                        .tabItem { Label("Review", systemImage: "chart.bar.fill") }.tag(3)
                    NavigationStack { SettingsView() }
                        .tabItem { Label("Settings", systemImage: "gearshape.fill") }.tag(4)
                }
            } else {
                OnboardingView()
            }
        }
        .overlay(alignment: .bottom) {
            if let t = model.toast {
                Notice(text: t)
                    .padding(.bottom, 64)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .onTapGesture { model.toast = nil }
                    .task(id: t) {
                        try? await Task.sleep(nanoseconds: 4_000_000_000)
                        withAnimation { model.toast = nil }
                    }
            }
        }
        .animation(.spring(duration: 0.35), value: model.toast)
        .sheet(isPresented: $showGap) { GapView() }
        .fullScreenCover(isPresented: Binding(get: { model.state.focus != nil }, set: { _ in })) { FocusView() }
        .onChange(of: model.deepLink) { _, link in open(link) }
        // A link set before the first frame (an intent that launched the app) doesn't count as a change.
        .onAppear { open(model.deepLink) }
    }

    private func open(_ link: String?) {
        guard let link, model.state.onboarded else { return }
        if link.hasPrefix("productium://gap") { showGap = true }
        else if link.hasPrefix("productium://week") || link.hasPrefix("productium://schedule") { tab = 1 }
        else if link.hasPrefix("productium://tasks") { tab = 2 }
        else if link.hasPrefix("productium://review") { tab = 3 }
        else if link.hasPrefix("productium://settings") { tab = 4 }
        else { tab = 0 }
        model.deepLink = nil
    }
}
