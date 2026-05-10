import SwiftUI

struct CoachView: View {
    @Bindable var store: FinanceStore

    @State private var purchasePrice = ""
    @State private var purchaseCategory: TransactionCategory = .shopping
    @State private var purchaseIsMonthly = false
    @State private var decision: AffordabilityDecision?
    @State private var shareShowsAmounts = true
    @State private var shareShowsMerchants = true
    @State private var shareCardURL: URL?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                ScreenTitle(title: "Coach", subtitle: "What you did, what it means, and what to change next.")

                if !store.data.accounts.isEmpty {
                    AccountFilterBar(accounts: store.data.accounts, selectedAccountIDs: $store.selectedAccountIDs)
                }

                PersonalityCard(personality: store.spendingPersonality)

                insightsSection
                wrappedSection
                affordabilitySection
                subscriptionCoachSection
            }
            .padding(24)
            .frame(maxWidth: 940, alignment: .leading)
        }
        .clarityTabContentPadding()
    }

    private var insightsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "Do this next", systemImage: "sparkles")

            ForEach(store.moneyInsights) { insight in
                InsightCard(insight: insight)
            }
        }
    }

    private var wrappedSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionHeader(title: "Money Wrapped", systemImage: "square.and.arrow.up")

            MoneyWrappedCard(wrapped: store.moneyWrapped)

            VStack(alignment: .leading, spacing: 12) {
                Toggle("Show amounts", isOn: $shareShowsAmounts)
                Toggle("Show merchant names", isOn: $shareShowsMerchants)

                HStack(spacing: 12) {
                    Button {
                        createShareCard()
                    } label: {
                        Label("Create Share Card", systemImage: "photo")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(PrimaryClarityButtonStyle())

                    if let shareCardURL {
                        ShareLink(item: shareCardURL) {
                            Label("Share", systemImage: "square.and.arrow.up")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(SecondaryClarityButtonStyle())
                    }
                }
            }
            .padding(18)
            .clarityCard(radius: 20)
        }
    }

    private var affordabilitySection: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionHeader(title: "Can I afford this?", systemImage: "questionmark.circle")

            VStack(alignment: .leading, spacing: 14) {
                TextField("Price", text: $purchasePrice)
#if os(iOS)
                    .keyboardType(.decimalPad)
#endif
                    .textFieldStyle(.plain)
                    .padding(14)
                    .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(ClarityColor.panelElevated))

                Picker("Category", selection: $purchaseCategory) {
                    ForEach(TransactionCategory.allCases.filter { $0 != .income && $0 != .transfer }) { category in
                        Label(category.title, systemImage: category.symbolName)
                            .tag(category)
                    }
                }
                .pickerStyle(.menu)

                Toggle("This is monthly", isOn: $purchaseIsMonthly)

                Button {
                    runAffordabilityCheck()
                } label: {
                    Label("Ask Clarity", systemImage: "sparkles")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(PrimaryClarityButtonStyle())

                if let decision {
                    AffordabilityResultCard(decision: decision)
                }
            }
            .padding(18)
            .clarityCard(radius: 20)
        }
    }

    private var subscriptionCoachSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "Subscription review", systemImage: "calendar.badge.clock")

            if store.subscriptionIntelligence.isEmpty {
                EmptyStateView(title: "No recurring charges yet", message: "Sync more history to find subscriptions and money leaks.", symbolName: "calendar")
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(store.subscriptionIntelligence.prefix(5).enumerated()), id: \.element.id) { index, item in
                        SubscriptionIntelligenceRow(item: item) {
                            store.setRecurringCharge(item.subscription, correction: item.isIgnored ? nil : .ignored)
                        }

                        if index < min(store.subscriptionIntelligence.count, 5) - 1 {
                            Divider().padding(.leading, 52)
                        }
                    }
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 8)
                .clarityCard(radius: 20)
            }
        }
    }

    private func runAffordabilityCheck() {
        let cleaned = purchasePrice
            .replacingOccurrences(of: "$", with: "")
            .replacingOccurrences(of: ",", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let price = Double(cleaned), price > 0 else {
            store.lastErrorMessage = "Enter a price first."
            return
        }

        decision = FinanceCoachEngine.affordabilityDecision(
            price: price,
            category: purchaseCategory,
            isMonthly: purchaseIsMonthly,
            transactions: store.filteredTransactions,
            accounts: store.filteredAccounts,
            anchor: store.reportingMonthAnchor
        )
    }

    private func createShareCard() {
        do {
            shareCardURL = try ShareCardExporter.exportWrappedCard(
                wrapped: store.moneyWrapped,
                showAmounts: shareShowsAmounts,
                showMerchants: shareShowsMerchants
            )
            store.statusMessage = "Share card created."
        } catch {
            store.lastErrorMessage = error.localizedDescription
        }
    }
}

private struct PersonalityCard: View {
    var personality: SpendingPersonality

    var body: some View {
        HStack(spacing: 14) {
            IconBadge(symbolName: personality.symbolName)

            VStack(alignment: .leading, spacing: 4) {
                Text(personality.title)
                    .font(.title3.weight(.bold))
                    .foregroundStyle(ClarityColor.primaryText)

                Text(personality.subtitle)
                    .font(.subheadline)
                    .foregroundStyle(ClarityColor.secondaryText)
            }

            Spacer()
        }
        .padding(18)
        .clarityCard(radius: 22)
    }
}

private struct InsightCard: View {
    var insight: MoneyInsight

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                IconBadge(symbolName: insight.symbolName, tint: toneColor)

                VStack(alignment: .leading, spacing: 5) {
                    Text(insight.title)
                        .font(.headline.weight(.bold))
                        .foregroundStyle(ClarityColor.primaryText)

                    Text(insight.message)
                        .font(.subheadline)
                        .foregroundStyle(ClarityColor.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer()
            }

            Text(insight.action)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(ClarityColor.primaryText)
                .padding(.leading, 52)

            ShareLink(item: insight.shareLine) {
                Label("Share insight", systemImage: "square.and.arrow.up")
                    .font(.caption.weight(.bold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(ClarityColor.secondaryText)
            .padding(.leading, 52)
        }
        .padding(18)
        .clarityCard(radius: 20)
    }

    private var toneColor: Color {
        switch insight.tone {
        case .good: ClarityColor.green
        case .warning: ClarityColor.purple
        case .urgent: ClarityColor.red
        case .neutral: ClarityColor.blue
        }
    }
}

private struct MoneyWrappedCard: View {
    var wrapped: MoneyWrapped

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(wrapped.monthTitle)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(ClarityColor.secondaryText)

                    Text("Your month, translated")
                        .font(.title2.weight(.bold))
                        .foregroundStyle(ClarityColor.primaryText)
                }

                Spacer()

                IconBadge(symbolName: "sparkles")
            }

            VStack(spacing: 0) {
                DetailStatRow(title: "Total spent", value: MoneyFormat.currency(wrapped.totalSpent))
                Divider().overlay(ClarityColor.stroke)
                DetailStatRow(title: "Top category", value: wrapped.topCategory?.title ?? "Still learning")
                Divider().overlay(ClarityColor.stroke)
                DetailStatRow(title: "Top merchant", value: wrapped.topMerchant ?? "Still learning")
                Divider().overlay(ClarityColor.stroke)
                DetailStatRow(title: "Subscriptions", value: "\(MoneyFormat.currency(wrapped.subscriptionsTotal))/mo")
                Divider().overlay(ClarityColor.stroke)
                DetailStatRow(title: "Expensive day", value: wrapped.expensiveDay)
            }
        }
        .padding(18)
        .clarityCard(radius: 22)
    }
}

private struct AffordabilityResultCard: View {
    var decision: AffordabilityDecision

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                IconBadge(symbolName: decision.verdict.symbolName)

                VStack(alignment: .leading, spacing: 4) {
                    Text(decision.verdict.title)
                        .font(.headline.weight(.bold))
                        .foregroundStyle(ClarityColor.primaryText)

                    Text(decision.message)
                        .font(.subheadline)
                        .foregroundStyle(ClarityColor.secondaryText)
                }
            }

            Text(decision.impact)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(ClarityColor.primaryText)

            Text(decision.suggestion)
                .font(.subheadline)
                .foregroundStyle(ClarityColor.secondaryText)
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(ClarityColor.panelElevated))
    }
}

private struct SubscriptionIntelligenceRow: View {
    var item: SubscriptionIntelligence
    var toggleCorrection: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            IconBadge(symbolName: item.subscription.recurringKind.symbolName)

            VStack(alignment: .leading, spacing: 4) {
                Text(item.subscription.displayName)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(ClarityColor.primaryText)
                    .strikethrough(item.isIgnored)

                Text("\(item.statusLine) • \(MoneyFormat.currency(item.totalPaidThisYear)) this year")
                    .font(.caption)
                    .foregroundStyle(ClarityColor.secondaryText)
                    .lineLimit(1)
            }

            Spacer()

            Button(item.isIgnored ? "Restore" : "Hide") {
                toggleCorrection()
            }
            .font(.caption.weight(.bold))
            .buttonStyle(.plain)
            .foregroundStyle(ClarityColor.primaryText)
        }
        .padding(.vertical, 10)
    }
}

private struct DetailStatRow: View {
    var title: String
    var value: String

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(.subheadline)
                .foregroundStyle(ClarityColor.secondaryText)

            Spacer()

            Text(value)
                .font(.subheadline.weight(.bold))
                .foregroundStyle(ClarityColor.primaryText)
                .multilineTextAlignment(.trailing)
        }
        .padding(.vertical, 10)
    }
}
