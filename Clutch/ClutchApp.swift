import SwiftUI

@main
struct ClutchApp: App {
    // Deliberately NOT @AppStorage: the engine picker greets the user on
    // every launch so they always consciously pick Cloud vs. Local.
    @State private var isOnboardingPresented = !UserDefaults.standard.bool(forKey: "ClutchSkipOnboarding")

    var body: some Scene {
        WindowGroup {
            ContentView()
                .sheet(isPresented: $isOnboardingPresented) {
                    OnboardingView()
                }
                .task { await BackendController.shared.startAndKeepAlive() }
        }
        .defaultSize(width: 1320, height: 840)
        .windowToolbarStyle(.unified)
    }
}
