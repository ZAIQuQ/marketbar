import AppKit
import SwiftUI

enum MarketTheme {
    static let accent = adaptive(light: (0.05, 0.43, 0.40), dark: (0.32, 0.76, 0.69))
    static let positive = adaptive(light: (0.05, 0.47, 0.35), dark: (0.31, 0.77, 0.57))
    static let negative = adaptive(light: (0.77, 0.22, 0.28), dark: (0.98, 0.43, 0.46))
    static let surface = Color(nsColor: .windowBackgroundColor)
    static let subtleSurface = Color.primary.opacity(0.035)
    static let separator = Color.primary.opacity(0.075)

    static func changeColor(_ value: Double) -> Color {
        if abs(value) < 0.005 { return .secondary }
        return value > 0 ? positive : negative
    }

    private static func adaptive(light: (Double, Double, Double), dark: (Double, Double, Double)) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let rgb = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: rgb.0, green: rgb.1, blue: rgb.2, alpha: 1)
        })
    }
}

struct MarketIconButtonStyle: ButtonStyle {
    var selected = false

    func makeBody(configuration: Configuration) -> some View {
        IconBody(configuration: configuration, selected: selected)
    }

    private struct IconBody: View {
        let configuration: ButtonStyle.Configuration
        let selected: Bool
        @State private var hovering = false

        var body: some View {
            configuration.label
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(selected ? MarketTheme.accent : Color.secondary)
                .frame(width: 30, height: 30)
                .background(selected ? MarketTheme.accent.opacity(0.10)
                            : Color.primary.opacity(configuration.isPressed ? 0.09 : hovering ? 0.055 : 0),
                            in: RoundedRectangle(cornerRadius: 8))
                .contentShape(RoundedRectangle(cornerRadius: 8))
                .onHover { hovering = $0 }
                .animation(.easeOut(duration: 0.12), value: hovering)
        }
    }
}

struct MarketBrandMark: View {
    var body: some View {
        HStack(alignment: .bottom, spacing: 3) {
            RoundedRectangle(cornerRadius: 1.5).frame(width: 4, height: 9)
            RoundedRectangle(cornerRadius: 1.5).frame(width: 4, height: 16)
            RoundedRectangle(cornerRadius: 1.5).frame(width: 4, height: 12)
        }
        .foregroundStyle(MarketTheme.accent)
        .frame(width: 34, height: 34)
        .background(MarketTheme.accent.opacity(0.09), in: RoundedRectangle(cornerRadius: 10))
        .accessibilityHidden(true)
    }
}
