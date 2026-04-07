import SwiftUI

@main
struct AiryWayApp: App {
    @StateObject private var chatViewModel = ChatViewModel()
    @StateObject private var settingsStore = SettingsStore()

    var body: some Scene {
        WindowGroup {
            RootTabView()
                .environmentObject(chatViewModel)
                .environmentObject(settingsStore)
                .preferredColorScheme(settingsStore.appAppearance.colorScheme)
                .task {
                    chatViewModel.bootstrap(settingsStore: settingsStore)
                    await settingsStore.bootstrap()
                }
        }
    }
}
