import SwiftUI
import AudioToolbox
import ProductiumCore

struct RootView: View {
    @Environment(AppModel.self) private var model
    @State private var tab = 0
    @State private var showGap = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

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
        .overlay(alignment: .top) {
            if let m = model.rewardMoment, m.intensity >= .medium {
                RewardBanner(moment: m)
                    .overlay(alignment: .top) {
                        if m.intensity == .big && !reduceMotion { ConfettiView().frame(height: 420).offset(y: -40) }
                    }
                    .padding(.top, 8)
                    .transition(reduceMotion ? .opacity : .move(edge: .top).combined(with: .opacity))
                    .onTapGesture { model.rewardMoment = nil }
                    .task(id: m.at) {
                        try? await Task.sleep(nanoseconds: (m.intensity == .big ? 5 : 3) * 1_000_000_000)
                        withAnimation { model.rewardMoment = nil }
                    }
            }
        }
        .sensoryFeedback(.success, trigger: model.rewardMoment) { _, new in new != nil && new!.intensity >= .small }
        .onChange(of: model.rewardMoment) { _, new in
            if new != nil, model.state.rewardSettings.sound { AudioServicesPlaySystemSound(1057) }
        }
        .animation(.spring(duration: 0.35), value: model.toast)
        .animation(.spring(duration: 0.35), value: model.rewardMoment)
        .sheet(isPresented: $showGap) { GapView() }
        .fullScreenCover(isPresented: Binding(get: { model.focus != nil }, set: { _ in })) { FocusView() }
        .onChange(of: model.deepLink) { _, link in open(link) }
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
