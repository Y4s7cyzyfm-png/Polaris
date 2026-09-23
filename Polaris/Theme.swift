import SwiftUI

// MARK: - 全局主题

enum Theme {
    /// 深空背景色
    static let background = Color(red: 0.040, green: 0.052, blue: 0.084)

    /// 卡片背景色
    static let card = Color.white.opacity(0.055)

    /// 主强调色（星辉蓝）
    static let accent = Color(red: 0.290, green: 0.620, blue: 1.000)

    /// 次强调色（极光紫）
    static let accentAlt = Color(red: 0.640, green: 0.440, blue: 0.980)

    /// 成功状态色
    static let success = Color(red: 0.200, green: 0.830, blue: 0.530)

    /// 全局渐变
    static let gradient = LinearGradient(
        colors: [accent, accentAlt],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    /// 统一圆角半径
    static let cornerRadius: CGFloat = 18
}

// MARK: - 通用卡片容器

struct Card<Content: View>: View {
    let title: String?
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let title = title {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 16)
                    .padding(.top, 14)
                    .padding(.bottom, 6)
            }
            content
                .padding(.vertical, 6)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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

// MARK: - 卡片内部分隔线

struct CardDivider: View {
    var body: some View {
        Rectangle()
            .fill(Color.white.opacity(0.06))
            .frame(height: 0.5)
            .padding(.leading, 16)
    }
}

// MARK: - 行图标

struct RowIcon: View {
    let systemName: String
    var color: Color = Theme.accent

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(color)
            .frame(width: 32, height: 32)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(color.opacity(0.16))
            )
    }
}
