import SwiftUI
import UIKit

// MARK: - 功能页（Tab 1）

struct FunctionView: View {

    /// 利用流程状态（仅 UI 演示）
    enum ExploitState {
        case idle
        case running
        case success

        var title: String {
            switch self {
            case .idle:    return "未激活"
            case .running: return "利用中"
            case .success: return "已激活"
            }
        }
    }

    // MARK: - 状态

    @State private var state: ExploitState = .idle
    @State private var progress: Double = 0

    // MARK: - 利用选项（仅 UI 演示）

    @State private var exploitMode = "自动选择"
    @State private var autoRepair = true
    @State private var verboseLog = false
    private let exploitModes = ["自动选择", "经典模式", "实验模式"]

    // MARK: - 功能开关（仅 UI 演示）

    @State private var tweakInjection = true
    @State private var filesystemRW = false
    @State private var daemonPatch = false
    @State private var autoRespring = true

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                header
                StatusCardView(state: state, progress: progress)
                ActionButtonView(state: state, action: handleActionButton)
                optionsCard
                featuresCard
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 28)
        }
        .background(Theme.background.ignoresSafeArea())
    }

    // MARK: - 顶部标题

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Polaris")
                .font(.system(size: 34, weight: .bold, design: .rounded))
                .foregroundStyle(Theme.gradient)
            Text("内核工具箱 · UI 预览版")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - 利用选项卡片

    private var optionsCard: some View {
        Card(title: "利用选项") {
            Menu {
                Picker("利用模式", selection: $exploitMode) {
                    ForEach(exploitModes, id: \.self) { mode in
                        Text(mode).tag(mode)
                    }
                }
            } label: {
                HStack(spacing: 12) {
                    RowIcon(systemName: "sparkles")
                    Text("利用模式")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(.white)
                    Spacer()
                    Text(exploitMode)
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .menuIndicator(.hidden)

            CardDivider()

            Toggle(isOn: $autoRepair) {
                optionLabel(icon: "wand.and.stars", title: "自动修复环境", subtitle: "利用完成后自动修复依赖项")
            }
            .toggleStyle(.switch)
            .tint(Theme.accent)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            CardDivider()

            Toggle(isOn: $verboseLog) {
                optionLabel(icon: "doc.text.magnifyingglass", title: "详细日志", subtitle: "输出内核利用过程的调试信息")
            }
            .toggleStyle(.switch)
            .tint(Theme.accent)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
    }

    // MARK: - 功能开关卡片

    private var featuresCard: some View {
        Card(title: "功能开关") {
            FeatureRow(icon: "syringe.fill",
                       title: "Tweak 注入",
                       subtitle: "为应用进程注入动态库插件",
                       isOn: $tweakInjection)
            CardDivider()
            FeatureRow(icon: "externaldrive.fill",
                       title: "文件系统读写",
                       subtitle: "以读写权限重新挂载系统分区",
                       isOn: $filesystemRW)
            CardDivider()
            FeatureRow(icon: "wrench.and.screwdriver.fill",
                       title: "守护进程补丁",
                       subtitle: "修补系统服务以加载第三方插件",
                       isOn: $daemonPatch)
            CardDivider()
            FeatureRow(icon: "arrow.triangle.2.circlepath",
                       title: "自动注销",
                       subtitle: "利用完成后自动重启 SpringBoard",
                       isOn: $autoRespring)
        }
    }

    // MARK: - 交互

    private func handleActionButton() {
        switch state {
        case .idle:
            startExploit()
        case .running:
            break
        case .success:
            state = .idle
            progress = 0
        }
    }

    /// 模拟利用流程（纯 UI 演示，无真实逻辑）
    private func startExploit() {
        state = .running
        progress = 0
        Task { @MainActor in
            while progress < 1 {
                try? await Task.sleep(nanoseconds: 50_000_000)
                progress = min(progress + Double.random(in: 0.015...0.05), 1)
            }
            try? await Task.sleep(nanoseconds: 350_000_000)
            state = .success
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        }
    }

    // MARK: - 子视图辅助

    private func optionLabel(icon: String, title: String, subtitle: String) -> some View {
        HStack(spacing: 12) {
            RowIcon(systemName: icon)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.white)
                Text(subtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - 状态卡片

private struct StatusCardView: View {
    let state: FunctionView.ExploitState
    let progress: Double

    private var statusColor: Color {
        switch state {
        case .idle:    return Color(white: 0.62)
        case .running: return Theme.accent
        case .success: return Theme.success
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 9, height: 9)
                    .shadow(color: statusColor.opacity(0.9), radius: state == .idle ? 0 : 5)
                Text(state.title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(statusColor)
                Spacer()
                Text("v0.1.0")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(Color.white.opacity(0.07)))
            }

            if state == .running {
                VStack(alignment: .leading, spacing: 6) {
                    ProgressView(value: progress)
                        .tint(Theme.accent)
                    Text("正在利用内核漏洞 · \(Int(progress * 100))%")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                .transition(.opacity)
            }

            CardDivider()

            HStack(spacing: 0) {
                infoColumn(title: "设备", value: DeviceInfo.modelIdentifier)
                infoColumn(title: "系统", value: "iOS \(DeviceInfo.systemVersion)")
                infoColumn(title: "引擎", value: "Polaris")
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous)
                .fill(Theme.card)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous)
                .strokeBorder(
                    state == .success
                        ? AnyShapeStyle(Theme.success.opacity(0.45))
                        : AnyShapeStyle(Color.white.opacity(0.07)),
                    lineWidth: 1
                )
        )
        .animation(.easeInOut(duration: 0.25), value: state)
    }

    private func infoColumn(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - 主操作按钮

private struct ActionButtonView: View {
    let state: FunctionView.ExploitState
    let action: () -> Void

    private var title: String {
        switch state {
        case .idle:    return "启动内核利用"
        case .running: return "正在利用…"
        case .success: return "已完成 · 点击重置"
        }
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                if state == .running {
                    ProgressView()
                        .tint(.white)
                        .scaleEffect(0.9)
                } else {
                    Image(systemName: state == .success ? "checkmark.circle.fill" : "bolt.fill")
                        .font(.system(size: 16, weight: .semibold))
                }
                Text(title)
                    .font(.system(size: 16, weight: .semibold))
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 15)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(
                        state == .success
                            ? AnyShapeStyle(Theme.success.opacity(0.85))
                            : AnyShapeStyle(Theme.gradient)
                    )
            )
            .shadow(
                color: (state == .success ? Theme.success : Theme.accent).opacity(0.35),
                radius: 14, x: 0, y: 6
            )
        }
        .buttonStyle(.plain)
        .disabled(state == .running)
        .animation(.easeInOut(duration: 0.25), value: state)
    }
}

// MARK: - 功能开关行

private struct FeatureRow: View {
    let icon: String
    let title: String
    let subtitle: String
    @Binding var isOn: Bool

    var body: some View {
        Toggle(isOn: $isOn) {
            HStack(spacing: 12) {
                RowIcon(systemName: icon)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(.white)
                    Text(subtitle)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .toggleStyle(.switch)
        .tint(Theme.accent)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
}
