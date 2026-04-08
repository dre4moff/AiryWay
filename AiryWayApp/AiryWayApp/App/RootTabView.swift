import SwiftUI

struct RootTabView: View {
    var body: some View {
        TabView {
            ChatScreen()
                .tabItem {
                    Label("Chat", systemImage: "sparkles")
                }

            ModelHubScreen()
                .tabItem {
                    Label("Models", systemImage: "square.and.arrow.down")
                }

            SettingsScreen()
                .tabItem {
                    Label("Settings", systemImage: "slider.horizontal.3")
                }
        }
        .toolbarBackground(.visible, for: .tabBar)
        .toolbarBackground(.ultraThinMaterial, for: .tabBar)
    }
}
