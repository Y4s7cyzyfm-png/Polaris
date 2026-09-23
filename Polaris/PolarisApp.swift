import SwiftUI

@main
struct PolarisApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .preferredColorScheme(.dark)
        }
    }
}

// MARK: - 根视图（双 Tab）

struct ContentView: View {
    var body: some View {
        TabView {
            FunctionView()
                .tabItem {
                    Label("功能", systemImage: "cpu.fill")
                }
            SettingsView()
                .tabItem {
                    Label("设置", systemImage: "gearshape.fill")
                }
        }
        .tint(Theme.accent)
    }
}
