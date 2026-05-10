import SwiftUI

enum ClarityColor {
    static let page = Color(red: 0.92, green: 0.92, blue: 0.90)
    static let panel = Color(red: 0.96, green: 0.96, blue: 0.94)
    static let panelElevated = Color(red: 0.89, green: 0.89, blue: 0.87)
    static let stroke = Color.black.opacity(0.08)
    static let primaryText = Color.black.opacity(0.88)
    static let secondaryText = Color.black.opacity(0.56)
    static let mutedText = Color.black.opacity(0.34)
    static let purple = Color.black.opacity(0.88)
    static let purpleLight = Color.black.opacity(0.72)
    static let green = Color(red: 0.05, green: 0.46, blue: 0.25)
    static let red = Color(red: 0.72, green: 0.18, blue: 0.16)
    static let blue = Color.black.opacity(0.68)
}

struct ClarityBackground: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(ClarityColor.page.ignoresSafeArea())
            .preferredColorScheme(.light)
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
