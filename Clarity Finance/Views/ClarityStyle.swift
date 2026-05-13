import SwiftUI
#if os(iOS)
import UIKit
private typealias PlatformColor = UIColor
#elseif os(macOS)
import AppKit
private typealias PlatformColor = NSColor
#endif

enum ClarityAppearance: String, CaseIterable, Identifiable {
    case light
    case dark

    var id: String { rawValue }

    var title: String {
        switch self {
        case .light: "Light"
        case .dark: "Dark"
        }
    }

    var colorScheme: ColorScheme {
        switch self {
        case .light: .light
        case .dark: .dark
        }
    }
}

enum ClarityColor {
    static let page = Color.clarityAdaptive(light: platformColor(0.92, 0.92, 0.90), dark: platformColor(0.04, 0.04, 0.04))
    static let panel = Color.clarityAdaptive(light: platformColor(0.96, 0.96, 0.94), dark: platformColor(0.08, 0.08, 0.08))
    static let panelElevated = Color.clarityAdaptive(light: platformColor(0.89, 0.89, 0.87), dark: platformColor(0.15, 0.15, 0.14))
    static let stroke = Color.clarityAdaptive(light: platformColor(0.00, 0.00, 0.00, 0.08), dark: platformColor(1.00, 1.00, 1.00, 0.10))
    static let primaryText = Color.clarityAdaptive(light: platformColor(0.00, 0.00, 0.00, 0.88), dark: platformColor(1.00, 1.00, 1.00, 0.92))
    static let secondaryText = Color.clarityAdaptive(light: platformColor(0.00, 0.00, 0.00, 0.56), dark: platformColor(1.00, 1.00, 1.00, 0.62))
    static let mutedText = Color.clarityAdaptive(light: platformColor(0.00, 0.00, 0.00, 0.34), dark: platformColor(1.00, 1.00, 1.00, 0.38))
    static let purple = primaryText
    static let purpleLight = secondaryText
    static let green = Color.clarityAdaptive(light: platformColor(0.05, 0.46, 0.25), dark: platformColor(0.23, 0.82, 0.48))
    static let red = Color.clarityAdaptive(light: platformColor(0.72, 0.18, 0.16), dark: platformColor(1.00, 0.36, 0.32))
    static let orange = Color.clarityAdaptive(light: platformColor(0.72, 0.38, 0.08), dark: platformColor(1.00, 0.65, 0.24))
    static let blue = Color.clarityAdaptive(light: platformColor(0.00, 0.00, 0.00, 0.68), dark: platformColor(0.72, 0.78, 0.86))
    static let primaryButtonBackground = primaryText
    static let primaryButtonText = page
}

struct ClarityBackground: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(ClarityColor.page.ignoresSafeArea())
    }
}

struct ClarityCard: ViewModifier {
    var radius: CGFloat = 18

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(ClarityColor.panel)
            )
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .stroke(ClarityColor.stroke, lineWidth: 1)
            )
    }
}

private func platformColor(_ red: Double, _ green: Double, _ blue: Double, _ alpha: Double = 1) -> PlatformColor {
    PlatformColor(red: CGFloat(red), green: CGFloat(green), blue: CGFloat(blue), alpha: CGFloat(alpha))
}

private extension Color {
    static func clarityAdaptive(light: PlatformColor, dark: PlatformColor) -> Color {
        #if os(iOS)
        Color(UIColor { traitCollection in
            traitCollection.userInterfaceStyle == .dark ? dark : light
        })
        #elseif os(macOS)
        Color(NSColor(name: nil) { appearance in
            let match = appearance.bestMatch(from: [.darkAqua, .aqua])
            return match == .darkAqua ? dark : light
        })
        #endif
    }
}

extension View {
    func clarityBackground() -> some View {
        modifier(ClarityBackground())
    }

    func clarityCard(radius: CGFloat = 18) -> some View {
        modifier(ClarityCard(radius: radius))
    }

    func clarityTabContentPadding() -> some View {
        safeAreaPadding(.bottom, 96)
    }
}

struct IconBadge: View {
    var symbolName: String
    var tint: Color = ClarityColor.purple

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(ClarityColor.panelElevated)
                .frame(width: 40, height: 40)

            Image(systemName: symbolName)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(ClarityColor.primaryText)
        }
    }
}

struct SectionHeader: View {
    var title: String
    var systemImage: String?

    var body: some View {
        HStack {
            Text(title)
                .font(.title3.weight(.semibold))
                .foregroundStyle(ClarityColor.primaryText)

            Spacer()

            if let systemImage {
                Image(systemName: systemImage)
                    .foregroundStyle(ClarityColor.secondaryText)
            }
        }
    }
}
