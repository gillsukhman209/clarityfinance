import SwiftUI

struct MoneyWrappedShareCard: View {
    var wrapped: MoneyWrapped
    var showAmounts: Bool
    var showMerchants: Bool

    var body: some View {
        ZStack {
            Color(red: 0.92, green: 0.92, blue: 0.90)

            VStack(alignment: .leading, spacing: 54) {
                VStack(alignment: .leading, spacing: 18) {
                    Text("Clarity")
                        .font(.system(size: 42, weight: .bold, design: .rounded))
                        .foregroundStyle(.black.opacity(0.56))

                    Text("\(wrapped.monthTitle)\nMoney Wrapped")
                        .font(.system(size: 92, weight: .black, design: .rounded))
                        .foregroundStyle(.black.opacity(0.9))
                        .lineSpacing(4)
                }

                VStack(alignment: .leading, spacing: 28) {
                    ShareMetricLine(title: "Total spent", value: showAmounts ? MoneyFormat.currency(wrapped.totalSpent) : "Hidden")
                    ShareMetricLine(title: "Top category", value: wrapped.topCategory?.title ?? "Still learning")
                    ShareMetricLine(title: "Top merchant", value: showMerchants ? (wrapped.topMerchant ?? "Still learning") : "Hidden")
                    ShareMetricLine(title: "Subscriptions", value: showAmounts ? "\(MoneyFormat.currency(wrapped.subscriptionsTotal))/mo" : "Hidden")
                    ShareMetricLine(title: "Expensive day", value: wrapped.expensiveDay)
                }
                .padding(42)
                .background(
                    RoundedRectangle(cornerRadius: 48, style: .continuous)
                        .fill(Color.white.opacity(0.5))
                )

                VStack(alignment: .leading, spacing: 16) {
                    Text("Spending personality")
                        .font(.system(size: 34, weight: .semibold, design: .rounded))
                        .foregroundStyle(.black.opacity(0.54))

                    HStack(spacing: 24) {
                        Image(systemName: wrapped.personality.symbolName)
                            .font(.system(size: 58, weight: .bold))
                            .foregroundStyle(.black.opacity(0.86))
                            .frame(width: 96, height: 96)
                            .background(
                                RoundedRectangle(cornerRadius: 28, style: .continuous)
                                    .fill(Color.black.opacity(0.08))
                            )

                        VStack(alignment: .leading, spacing: 10) {
                            Text(wrapped.personality.title)
                                .font(.system(size: 54, weight: .black, design: .rounded))
                                .foregroundStyle(.black.opacity(0.9))

                            Text(wrapped.personality.subtitle)
                                .font(.system(size: 30, weight: .medium, design: .rounded))
                                .foregroundStyle(.black.opacity(0.58))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }

                Spacer()

                Text("Your spending, translated.")
                    .font(.system(size: 36, weight: .bold, design: .rounded))
                    .foregroundStyle(.black.opacity(0.74))
            }
            .padding(78)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        }
    }
}

private struct ShareMetricLine: View {
    var title: String
    var value: String

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(.system(size: 34, weight: .semibold, design: .rounded))
                .foregroundStyle(.black.opacity(0.52))

            Spacer(minLength: 32)

            Text(value)
                .font(.system(size: 42, weight: .black, design: .rounded))
                .foregroundStyle(.black.opacity(0.9))
                .multilineTextAlignment(.trailing)
        }
    }
}
