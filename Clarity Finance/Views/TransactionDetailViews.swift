import SwiftUI

struct TransactionDetailView: View {
    @Environment(\.dismiss) private var dismiss

    var transaction: FinanceTransaction
    var account: FinancialAccount?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    DetailHeader(
                        symbolName: transaction.category.symbolName,
                        title: transaction.merchantName,
                        subtitle: transaction.category.title,
                        amount: MoneyFormat.currency(transaction.signedDisplayAmount, showsSign: true),
                        amountColor: transaction.isIncome ? ClarityColor.green : ClarityColor.primaryText
                    )

                    VStack(spacing: 0) {
                        DetailRow(title: "Date", value: transaction.date.formatted(.dateTime.month(.wide).day().year()))
                        DetailDivider()
                        DetailRow(title: "Account", value: account?.displayName ?? "Unknown account")
                        DetailDivider()
                        DetailRow(title: "Institution", value: account?.institutionName ?? "Unknown")
                        DetailDivider()
                        DetailRow(title: "Category", value: transaction.category.title)
                        DetailDivider()
                        DetailRow(title: "Status", value: transaction.pending ? "Pending" : "Posted")
                        DetailDivider()
                        DetailRow(title: "Source", value: transaction.source)
                    }
                    .padding(18)
                    .clarityCard(radius: 20)

                    if transaction.originalName != transaction.merchantName {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Original name")
                                .font(.caption.weight(.bold))
                                .foregroundStyle(ClarityColor.secondaryText)

                            Text(transaction.originalName)
                                .font(.subheadline)
                                .foregroundStyle(ClarityColor.primaryText)
                                .textSelection(.enabled)
                        }
                        .padding(18)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .clarityCard(radius: 20)
                    }
                }
                .padding(24)
                .frame(maxWidth: 560, alignment: .leading)
            }
            .background(ClarityColor.page)
            .navigationTitle("Transaction")
#if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
#endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
    }
}

struct SubscriptionDetailView: View {
    @Environment(\.dismiss) private var dismiss

    var subscription: SubscriptionItem
    var account: FinancialAccount?
    var recentTransactions: [FinanceTransaction]
    var intelligence: SubscriptionIntelligence?
    var setCorrection: ((RecurringChargeCorrection?) -> Void)?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    DetailHeader(
                        symbolName: subscription.category.symbolName,
                        title: subscription.displayName,
                        subtitle: subscription.category.title,
                        amount: MoneyFormat.currency(subscription.monthlyAmount),
                        amountColor: ClarityColor.primaryText
                    )

                    VStack(spacing: 0) {
                        DetailRow(title: "Monthly amount", value: MoneyFormat.currency(subscription.monthlyAmount))
                        DetailDivider()
                        DetailRow(title: "Next expected", value: subscription.nextExpectedDate.formatted(.dateTime.month(.wide).day().year()))
                        DetailDivider()
                        DetailRow(title: "Account", value: account?.displayName ?? "Unknown account")
                        DetailDivider()
                        DetailRow(title: "Institution", value: account?.institutionName ?? "Unknown")
                        DetailDivider()
                        DetailRow(title: "Category", value: subscription.category.title)
                        DetailDivider()
                        DetailRow(title: "Plaid type", value: subscription.recurringKind.title)
                        DetailDivider()
                        DetailRow(title: "Frequency", value: subscription.frequency.isEmpty ? "Plaid recurring" : subscription.frequency.replacingOccurrences(of: "_", with: " ").capitalized)
                        DetailDivider()
                        DetailRow(title: "Plaid status", value: subscription.status.isEmpty ? "Active" : subscription.status.capitalized)
                        if subscription.lastAmount > 0 {
                            DetailDivider()
                            DetailRow(title: "Last amount", value: MoneyFormat.currency(subscription.lastAmount))
                        }
                        if let lastDate = subscription.lastDate {
                            DetailDivider()
                            DetailRow(title: "Last charged", value: lastDate.formatted(.dateTime.month(.wide).day().year()))
                        }
                        if let intelligence {
                            DetailDivider()
                            DetailRow(title: "Confidence", value: intelligence.confidenceLabel)
                            DetailDivider()
                            DetailRow(title: "Paid this year", value: MoneyFormat.currency(intelligence.totalPaidThisYear))
                            DetailDivider()
                            DetailRow(title: "Charges found", value: "\(intelligence.chargeCount)")
                        }
                    }
                    .padding(18)
                    .clarityCard(radius: 20)

                    if !subscription.streamDescription.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                       subscription.streamDescription != subscription.displayName {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Plaid raw name")
                                .font(.caption.weight(.bold))
                                .foregroundStyle(ClarityColor.secondaryText)

                            Text(subscription.streamDescription)
                                .font(.subheadline)
                                .foregroundStyle(ClarityColor.primaryText)
                                .textSelection(.enabled)
                        }
                        .padding(18)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .clarityCard(radius: 20)
                    }

                    if let intelligence, let setCorrection {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Correction")
                                .font(.headline.weight(.semibold))
                                .foregroundStyle(ClarityColor.primaryText)

                            HStack(spacing: 10) {
                                Button("Subscription") {
                                    setCorrection(.subscription)
                                    dismiss()
                                }
                                .buttonStyle(SecondaryClarityButtonStyle())

                                Button("Bill") {
                                    setCorrection(.bill)
                                    dismiss()
                                }
                                .buttonStyle(SecondaryClarityButtonStyle())
                            }

                            HStack(spacing: 10) {
                                Button(intelligence.isIgnored ? "Restore Plaid" : "Hide") {
                                    setCorrection(intelligence.isIgnored ? nil : .ignored)
                                    dismiss()
                                }
                                .buttonStyle(SecondaryClarityButtonStyle())

                                Button("Reset to Plaid") {
                                    setCorrection(nil)
                                    dismiss()
                                }
                                .buttonStyle(SecondaryClarityButtonStyle())
                            }
                        }
                        .padding(18)
                        .clarityCard(radius: 20)
                    }

                    if !recentTransactions.isEmpty {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Recent charges")
                                .font(.headline.weight(.semibold))
                                .foregroundStyle(ClarityColor.primaryText)

                            VStack(spacing: 0) {
                                ForEach(Array(recentTransactions.enumerated()), id: \.element.id) { index, transaction in
                                    MiniTransactionRow(transaction: transaction)

                                    if index < recentTransactions.count - 1 {
                                        DetailDivider()
                                    }
                                }
                            }
                        }
                        .padding(18)
                        .clarityCard(radius: 20)
                    }
                }
                .padding(24)
                .frame(maxWidth: 560, alignment: .leading)
            }
            .background(ClarityColor.page)
            .navigationTitle("Subscription")
#if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
#endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
    }
}

private struct DetailHeader: View {
    var symbolName: String
    var title: String
    var subtitle: String
    var amount: String
    var amountColor: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            IconBadge(symbolName: symbolName)

            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(.title2.weight(.bold))
                    .foregroundStyle(ClarityColor.primaryText)
                    .fixedSize(horizontal: false, vertical: true)

                Text(subtitle)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(ClarityColor.secondaryText)
            }

            Text(amount)
                .font(.system(size: 38, weight: .bold, design: .rounded))
                .foregroundStyle(amountColor)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .padding(22)
        .frame(maxWidth: .infinity, alignment: .leading)
        .clarityCard(radius: 24)
    }
}

private struct DetailRow: View {
    var title: String
    var value: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 16) {
            Text(title)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(ClarityColor.secondaryText)

            Spacer(minLength: 16)

            Text(value)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(ClarityColor.primaryText)
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
        }
        .padding(.vertical, 10)
    }
}

private struct DetailDivider: View {
    var body: some View {
        Divider()
            .overlay(ClarityColor.stroke)
    }
}

private struct MiniTransactionRow: View {
    var transaction: FinanceTransaction

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(transaction.date.formatted(.dateTime.month(.abbreviated).day().year()))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(ClarityColor.primaryText)

                Text(transaction.pending ? "Pending" : "Posted")
                    .font(.caption)
                    .foregroundStyle(ClarityColor.secondaryText)
            }

            Spacer()

            Text(MoneyFormat.currency(transaction.signedDisplayAmount, showsSign: true))
                .font(.subheadline.weight(.bold))
                .foregroundStyle(ClarityColor.primaryText)
        }
        .padding(.vertical, 10)
    }
}
