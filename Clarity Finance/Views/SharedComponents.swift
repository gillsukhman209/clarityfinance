import SwiftUI

struct MetricCard: View {
    var title: String
    var value: String
    var caption: String
    var symbolName: String
    var tint: Color = ClarityColor.purple

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(ClarityColor.secondaryText)
                Text(value)
                    .font(.title3.weight(.bold))
                    .foregroundStyle(ClarityColor.primaryText)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                Text(caption)
                    .font(.caption)
                    .foregroundStyle(ClarityColor.mutedText)
                    .lineLimit(1)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .clarityCard(radius: 18)
    }
}

struct ActionTile: View {
    var section: AppSection
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: section.symbolName)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(ClarityColor.primaryText)
                    .frame(width: 28, height: 28)
                Text(section.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(ClarityColor.primaryText)
                    .lineLimit(1)

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(Capsule().fill(ClarityColor.panelElevated))
        }
        .buttonStyle(.plain)
    }
}

struct AccountFilterBar: View {
    var accounts: [FinancialAccount]
    @Binding var selectedAccountIDs: Set<String>

    private var title: String {
        if selectedAccountIDs.isEmpty {
            return "All accounts"
        }

        if selectedAccountIDs.count == 1,
           let selectedID = selectedAccountIDs.first,
           let account = accounts.first(where: { $0.id == selectedID }) {
            return account.displayName
        }

        return "\(selectedAccountIDs.count) accounts selected"
    }

    var body: some View {
        HStack(spacing: 10) {
            Menu {
                Button("All accounts") {
                    selectedAccountIDs = []
                }

                Divider()

                ForEach(accounts) { account in
                    Button {
                        if selectedAccountIDs.contains(account.id) {
                            selectedAccountIDs.remove(account.id)
                        } else {
                            selectedAccountIDs.insert(account.id)
                        }
                    } label: {
                        Label(
                            account.displayName,
                            systemImage: selectedAccountIDs.contains(account.id) ? "checkmark.circle.fill" : "circle"
                        )
                    }
                }
            } label: {
                HStack(spacing: 8) {
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(ClarityColor.primaryText)
                        .lineLimit(1)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(ClarityColor.secondaryText)
                }
            }
            .buttonStyle(.plain)

            if !selectedAccountIDs.isEmpty {
                Button {
                    selectedAccountIDs = []
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(ClarityColor.secondaryText)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Capsule().fill(ClarityColor.panelElevated))
    }
}

struct MiniLineChart: View {
    var values: [Double]
    var lineColor: Color = ClarityColor.purpleLight

    var body: some View {
        GeometryReader { geometry in
            let normalized = normalizedPoints(in: geometry.size)

            ZStack {
                ChartGrid()

                if normalized.count > 1 {
                    Path { path in
                        path.move(to: normalized[0])
                        for point in normalized.dropFirst() {
                            path.addLine(to: point)
                        }
                    }
                    .trim(from: 0, to: 1)
                    .stroke(
                        lineColor,
                        style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round)
                    )

                    ForEach(Array(normalized.enumerated()), id: \.offset) { _, point in
                        Circle()
                            .fill(lineColor)
                            .frame(width: 4, height: 4)
                            .position(point)
                    }
                }
            }
        }
    }

    private func normalizedPoints(in size: CGSize) -> [CGPoint] {
        guard let minValue = values.min(), let maxValue = values.max(), maxValue != minValue else {
            return values.enumerated().map { index, _ in
                CGPoint(
                    x: CGFloat(index) / CGFloat(Swift.max(values.count - 1, 1)) * size.width,
                    y: size.height * 0.55
                )
            }
        }

        return values.enumerated().map { index, value in
            let x = CGFloat(index) / CGFloat(Swift.max(values.count - 1, 1)) * size.width
            let progress = (value - minValue) / (maxValue - minValue)
            let y = size.height - CGFloat(progress) * (size.height * 0.74) - size.height * 0.13
            return CGPoint(x: x, y: y)
        }
    }
}

private struct ChartGrid: View {
    var body: some View {
        VStack {
            Spacer()
            Divider().overlay(ClarityColor.stroke)
            Spacer()
            Divider().overlay(ClarityColor.stroke)
            Spacer()
        }
    }
}

struct TransactionRow: View {
    var transaction: FinanceTransaction
    var account: FinancialAccount?

    var body: some View {
        HStack(spacing: 12) {
            IconBadge(symbolName: transaction.category.symbolName, tint: tint)

            VStack(alignment: .leading, spacing: 3) {
                Text(transaction.merchantName)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(ClarityColor.primaryText)
                    .lineLimit(1)

                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(ClarityColor.secondaryText)
                    .lineLimit(1)
            }

            Spacer()

            Text(MoneyFormat.currency(transaction.signedDisplayAmount, showsSign: true))
                .font(.subheadline.weight(.bold))
                .foregroundStyle(ClarityColor.primaryText)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .padding(.vertical, 12)
    }

    private var tint: Color {
        transaction.isIncome ? ClarityColor.green : ClarityColor.purple
    }

    private var subtitle: String {
        let date = transaction.date.formatted(.dateTime.month(.abbreviated).day())
        if let account {
            return "\(date) • \(account.name)"
        }
        return date
    }
}

struct AccountRow: View {
    var account: FinancialAccount

    var body: some View {
        HStack(spacing: 12) {
            IconBadge(symbolName: account.kind.symbolName, tint: account.kind.isLiability ? ClarityColor.red : ClarityColor.blue)

            VStack(alignment: .leading, spacing: 3) {
                Text(account.displayName)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(ClarityColor.primaryText)
                    .lineLimit(1)

                Text("\(account.institutionName) • \(account.kind.title)")
                    .font(.caption)
                    .foregroundStyle(ClarityColor.secondaryText)
                    .lineLimit(1)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 3) {
                Text(MoneyFormat.currency(account.currentBalance))
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(ClarityColor.primaryText)
                    .lineLimit(1)

                Text(account.isManual ? "PDF" : "Plaid")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(ClarityColor.mutedText)
            }
        }
        .padding(.vertical, 12)
    }
}

struct EmptyStateView: View {
    var title: String
    var message: String
    var symbolName: String

    var body: some View {
        VStack(spacing: 12) {
            Text(title)
                .font(.headline)
                .foregroundStyle(ClarityColor.primaryText)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(ClarityColor.secondaryText)
                .multilineTextAlignment(.center)
        }
        .padding(24)
        .frame(maxWidth: .infinity)
        .clarityCard(radius: 18)
    }
}
