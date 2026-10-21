import SwiftUI

// 注意：程序入口在 PolarisMain.mm（UIKit main）。
// 那里判断 argv[1] == "-hud" 时进入悬浮窗子进程模式，
// 否则回退到下面的 SwiftUI 主界面。

struct PolarisAppContent: View {
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
        .preferredColorScheme(.dark)
        .tint(Theme.accent)
    }
}

/// SwiftUI 宿主（PolarisMain.mm 以 UIHostingController 方式呈现）
struct PolarisMainHostView: View {
    var body: some View {
        PolarisAppContent()
    }
}
