import SwiftUI
import UIKit

// MARK: - 功能页（Tab 1）

struct FunctionView: View {

    /// 利用流程状态（驱动自 PolarisBridge）
    enum ExploitState {
        case idle
        case running
        case success
        case failed

        var title: String {
            switch self {
            case .idle:    return "未激活"
            case .running: return "利用中"
            case .success: return "已激活"
            case .failed:  return "启动失败"
            }
        }
    }

    // MARK: - 状态（由 Bridge 驱动，定时刷新）

    @State private var state: ExploitState = .idle
    @State private var progress: Double = 0
    @State private var stage: String = "等待开始"
    @State private var lastError: String = ""
    @State private var kernelBase: UInt64 = 0
    @State private var kernelSlide: UInt64 = 0
    @State private var logLines: [String] = []

    // MARK: - 利用选项

    @State private var verboseLog = false

    // MARK: - 功能开关（占位，暂无实际逻辑）

    @State private var filesystemRW = false

    // 0.5s 轮询，与 Bridge 的进度通知双通道刷新
    private let timer = Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()
    private let progressNotification = NSNotification.Name("com.polaris.bridge.progress")

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                header
                StatusCardView(state: state,
                               progress: progress,
                               stage: stage,
                               lastError: lastError,
                               kernelBase: kernelBase,
                               kernelSlide: kernelSlide)
                ActionButtonView(state: state, action: handleActionButton)
                optionsCard
                if verboseLog {
                    LogConsoleCard(lines: logLines, onClear: clearLog)
                }
                featuresCard
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 28)
        }
        .background(Theme.background.ignoresSafeArea())
        .onReceive(timer) { _ in refresh() }
        .onReceive(NotificationCenter.default.publisher(for: progressNotification)) { _ in
            refresh()
        }
        .onAppear { refresh() }
        .animation(.easeInOut(duration: 0.25), value: verboseLog)
    }

    // MARK: - 顶部标题

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Polaris")
                .font(.system(size: 34, weight: .bold, design: .rounded))
                .foregroundStyle(Theme.gradient)
            Text("内核工具箱 · DarkSword")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - 利用选项卡片

    private var optionsCard: some View {
        Card(title: "利用选项") {
            HStack(spacing: 12) {
                RowIcon(systemName: "sparkles")
                Text("利用引擎")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.white)
                Spacer()
                Text("DarkSword")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.accent)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            CardDivider()

            Toggle(isOn: $verboseLog) {
                optionLabel(icon: "doc.text.magnifyingglass", title: "详细日志", subtitle: "实时输出内核利用过程的调试信息")
            }
            .toggleStyle(.switch)
            .tint(Theme.accent)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
    }

    // MARK: - 功能开关卡片（占位）

    private var featuresCard: some View {
        Card(title: "功能开关") {
            FeatureRow(icon: "externaldrive.fill",
                       title: "文件系统读写",
                       subtitle: "以读写权限重新挂载系统分区（即将推出）",
                       isOn: $filesystemRW)
        }
    }

    // MARK: - 交互

    private func handleActionButton() {
        switch state {
        case .idle, .failed:
            startExploit()
        case .running, .success:
            break
        }
    }

    /// 调用 PolarisBridge 启动 DarkSword 内核引导
    private func startExploit() {
        state = .running
        progress = 0.03
        stage = "正在准备启动"
        UINotificationFeedbackGenerator().notificationOccurred(.impactmedium)
        PolarisInitializeDarkSwordKernel()
        refresh()
    }

    /// 从 Bridge 拉取最新状态并刷新 UI
    private func refresh() {
        let ready = PolarisKernelIsReady()
        let running = PolarisKernelIsRunning()
        let error = PolarisBridgeLastError() ?? ""

        stage = PolarisBridgeStage() ?? "等待开始"
        progress = PolarisBridgeProgress()
        lastError = error
        logLines = (PolarisConsoleLogLines() as? [String]) ?? []

        if ready {
            state = .success
            kernelBase = PolarisKernelBase()
            kernelSlide = PolarisKernelSlide()
        } else if running {
            state = .running
        } else if !error.isEmpty {
            state = .failed
        } else {
            state = .idle
        }
    }

    private func clearLog() {
        PolarisClearConsoleLog()
        refresh()
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
    let stage: String
    let lastError: String
    let kernelBase: UInt64
    let kernelSlide: UInt64

    private var statusColor: Color {
        switch state {
        case .idle:    return Color(white: 0.62)
        case .running: return Theme.accent
        case .success: return Theme.success
        case .failed:  return .red
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
                Text("v0.2.0")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(Color.white.opacity(0.07)))
            }

            Text(stage)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)

            if state == .running {
                VStack(alignment: .leading, spacing: 6) {
                    ProgressView(value: min(max(progress, 0.02), 1.0))
                        .tint(Theme.accent)
                    Text("正在利用内核漏洞 · \(Int(progress * 100))%")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                .transition(.opacity)
            }

            if state == .failed && !lastError.isEmpty {
                Text(lastError)
                    .font(.system(size: 12))
                    .foregroundStyle(.red.opacity(0.9))
                    .lineLimit(4)
                    .transition(.opacity)
            }

            if state == .success {
                VStack(alignment: .leading, spacing: 4) {
                    keyValueRow("Kernel Base", String(format: "0x%llx", kernelBase))
                    keyValueRow("Kernel Slide", String(format: "0x%llx", kernelSlide))
                }
                .transition(.opacity)
            }

            CardDivider()

            HStack(spacing: 0) {
                infoColumn(title: "设备", value: DeviceInfo.modelIdentifier)
                infoColumn(title: "系统", value: "iOS \(DeviceInfo.systemVersion)")
                infoColumn(title: "引擎", value: "DarkSword")
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

    private func keyValueRow(_ key: String, _ value: String) -> some View {
        HStack {
            Text(key)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .foregroundStyle(Theme.success)
        }
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
        case .success: return "内核已就绪 · DarkSword"
        case .failed:  return "重试内核利用"
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
                    Image(systemName: icon)
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
                    .fill(backgroundStyle)
            )
            .shadow(
                color: shadowColor.opacity(0.35),
                radius: 14, x: 0, y: 6
            )
        }
        .buttonStyle(.plain)
        .disabled(state == .running || state == .success)
        .animation(.easeInOut(duration: 0.25), value: state)
    }

    private var icon: String {
        switch state {
        case .success: return "checkmark.circle.fill"
        case .failed:  return "arrow.clockwise"
        default:       return "bolt.fill"
        }
    }

    private var backgroundStyle: AnyShapeStyle {
        switch state {
        case .success: return AnyShapeStyle(Theme.success.opacity(0.85))
        case .failed:  return AnyShapeStyle(Color.red.opacity(0.75))
        default:       return AnyShapeStyle(Theme.gradient)
        }
    }

    private var shadowColor: Color {
        switch state {
        case .success: return Theme.success
        case .failed:  return .red
        default:       return Theme.accent
        }
    }
}

// MARK: - 控制台日志卡片

private struct LogConsoleCard: View {
    let lines: [String]
    let onClear: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                RowIcon(systemName: "terminal")
                Text("控制台日志")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                Spacer()
                Text("\(lines.count) 行")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                Button(action: onClear) {
                    Image(systemName: "trash")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 3) {
                        ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                            Text(line)
                                .font(.system(size: 10.5, weight: .regular, design: .monospaced))
                                .foregroundStyle(line.contains("[error]") || line.contains("失败")
                                                 ? Color.red.opacity(0.85)
                                                 : Color.green.opacity(0.75))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .id(index)
                        }
                    }
                    .padding(10)
                }
                .frame(height: 220)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color.black.opacity(0.45))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.06), lineWidth: 1)
                )
                .onChange(of: lines.count) { newCount in
                    if newCount > 0 {
                        proxy.scrollTo(newCount - 1, anchor: .bottom)
                    }
                }
            }

            Text("日志同时写入 Documents/polaris.log（文件 App 可查看）")
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous)
                .fill(Theme.card)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous)
                .strokeBorder(Color.white.opacity(0.07), lineWidth: 1)
        )
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
