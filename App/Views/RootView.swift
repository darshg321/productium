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
                    WeekView()
                        .tabItem { Label("Week", systemImage: "calendar") }.tag(1)
                    ReviewView()
                        .tabItem { Label("Review", systemImage: "chart.bar.fill") }.tag(2)
                    NavigationStack { SettingsView() }
                        .tabItem { Label("Settings", systemImage: "gearshape.fill") }.tag(3)
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
        .onChange(of: model.deepLink) { _, link in
            guard let link else { return }
            if link.hasPrefix("productium://gap") { showGap = true }
            else if link.hasPrefix("productium://week") { tab = 1 }
            else if link.hasPrefix("productium://review") { tab = 2 }
            else if link.hasPrefix("productium://settings") { tab = 3 }
            else { tab = 0 }
            model.deepLink = nil
        }
    }
}
