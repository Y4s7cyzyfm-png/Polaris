import SwiftUI

// MARK: - 设置页（Tab 2）

struct SettingsView: View {

    /// TODO: 替换为你的官方 Telegram 频道链接
    private let telegramURL = URL(string: "https://t.me/xiaoniannya520")!

    @Environment(\.openURL) private var openURL

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                header
                telegramCard
                aboutCard
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
            Text("设置")
                .font(.system(size: 34, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
            Text("偏好与社区")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Telegram 频道

    private var telegramCard: some View {
        Card(title: "社区") {
            Button {
                openURL(telegramURL)
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "paperplane.fill")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 34, height: 34)
                        .background(Circle().fill(Theme.gradient))
                    VStack(alignment: .leading, spacing: 2) {
                        Text("加入官方 Telegram 频道")
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(.white)
                        Text("获取最新版本、使用教程与支持")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - 关于

    private var aboutCard: some View {
        Card(title: "关于") {
            aboutRow(title: "版本", value: "0.4.5")
            CardDivider()
            aboutRow(title: "项目代号", value: "Polaris · 北极星")
            CardDivider()
            aboutRow(title: "构建环境", value: "Xcode 16+ / Swift 5")
        }
    }

    private func aboutRow(title: String, value: String) -> some View {
        HStack {
            Text(title)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.white)
            Spacer()
            Text(value)
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
    }
}
