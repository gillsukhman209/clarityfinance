import SwiftUI

struct OverviewView: View {
    @Bindable var store: FinanceStore
    var navigate: (AppSection) -> Void
    @State private var selectedTransaction: FinanceTransaction?

    private var activeSubscriptions: [SubscriptionItem] {
        store.filteredSubscriptions.filter(\.isActive)
    }

    private var activeRecurringTotal: Double {
        activeSubscriptions.reduce(0) { $0 + $1.monthlyAmount }
    }

    private var mainInsight: MoneyInsight? {
        store.moneyInsights.first
    }

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 18) {
                topBar
                todayBrief
                closeKnowingCard
                nextActionCard
                latestActivity
            }
            .padding(.horizontal, 24)
            .padding(.top, 18)
            .padding(.bottom, 104)
            .frame(maxWidth: 680, alignment: .leading)
        }
        .sheet(item: $selectedTransaction) { transaction in
            TransactionDetailView(
                transaction: transaction,
                account: store.account(for: transaction.accountID)
            )
        }
    }

    private var topBar: some View {
        HStack(spacing: 12) {
            if !store.data.accounts.isEmpty {
                AccountFilterBar(accounts: store.data.accounts, selectedAccountIDs: $store.selectedAccountIDs)
            } else {
                Text("Personal")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(ClarityColor.primaryText)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(Capsule().fill(ClarityColor.panelElevated))
            }

            Spacer()

            Button {
                Task { await store.syncAllConnections() }
            } label: {
                Image(systemName: store.isSyncing ? "clock.arrow.circlepath" : "arrow.triangle.2.circlepath")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(ClarityColor.primaryText)
                    .frame(width: 42, height: 42)
                    .background(Circle().fill(ClarityColor.panelElevated))
            }
            .buttonStyle(.plain)
            .disabled(store.isSyncing)
        }
    }

    private var todayBrief: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Today")
                    .font(.title.weight(.bold))
                    .foregroundStyle(ClarityColor.primaryText)

                Text(primarySentence)
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(ClarityColor.primaryText)
                    .fixedSize(horizontal: false, vertical: true)

                Text(store.reportingMonthTitle)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(ClarityColor.secondaryText)
            }

            HStack(spacing: 10) {
                BriefMetric(title: "Spent", value: MoneyFormat.currency(store.monthlySpend))
                BriefMetric(title: "Income", value: MoneyFormat.currency(store.incomeThisMonth))
                BriefMetric(title: "Net worth", value: MoneyFormat.currency(store.totalBalance))
            }
        }
        .padding(22)
        .clarityCard(radius: 24)
    }

    private var closeKnowingCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionHeader(title: "What changed", systemImage: nil)

            VStack(spacing: 0) {
                LearningRow(
                    symbolName: "chart.bar.fill",
                    title: "This month",
                    value: MoneyFormat.currency(store.monthlySpend),
                    caption: monthCaption
                )
                BriefDivider()
                LearningRow(
                    symbolName: "calendar.badge.clock",
                    title: "Recurring",
                    value: MoneyFormat.currency(activeRecurringTotal),
                    caption: "\(activeSubscriptions.count) active subscription\(activeSubscriptions.count == 1 ? "" : "s")"
                )
                BriefDivider()
                LearningRow(
                    symbolName: "building.columns.fill",
                    title: "Accounts",
                    value: "\(store.filteredAccounts.count)",
                    caption: store.accountFilterCaption
                )
            }
        }
        .padding(18)
        .clarityCard(radius: 22)
    }

    private var nextActionCard: some View {
        Button {
            navigate(mainInsight == nil && !store.hasFinancialData ? .settings : .coach)
        } label: {
            HStack(spacing: 14) {
                IconBadge(symbolName: mainInsight?.symbolName ?? "sparkles")

                VStack(alignment: .leading, spacing: 5) {
                    Text(nextActionTitle)
                        .font(.headline.weight(.bold))
                        .foregroundStyle(ClarityColor.primaryText)
                        .lineLimit(2)

                    Text(nextActionCaption)
                        .font(.subheadline)
                        .foregroundStyle(ClarityColor.secondaryText)
                        .lineLimit(3)
                }

                Spacer(minLength: 8)

                Image(systemName: "chevron.right")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(ClarityColor.secondaryText)
            }
            .padding(18)
            .clarityCard(radius: 22)
        }
        .buttonStyle(.plain)
    }

    private var latestActivity: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "Latest activity", systemImage: nil)

            VStack(spacing: 0) {
                if store.recentTransactions.isEmpty {
                    EmptyStateView(
                        title: "No activity yet",
                        message: "Connect an account or import a statement to see your money in one place.",
                        symbolName: "list.bullet.rectangle.portrait"
                    )
                } else {
                    ForEach(Array(store.recentTransactions.prefix(3).enumerated()), id: \.element.id) { index, transaction in
                        Button {
                            selectedTransaction = transaction
                        } label: {
                            TransactionRow(
                                transaction: transaction,
                                account: store.account(for: transaction.accountID)
                            )
                        }
                        .buttonStyle(.plain)
                        .contentShape(Rectangle())

                        if index < min(store.recentTransactions.count, 3) - 1 {
                            BriefDivider()
                        }
                    }
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 8)
            .clarityCard(radius: 22)
        }
    }

    private var primarySentence: String {
        if !store.hasFinancialData {
            return "Connect your accounts first."
        }

        if let mainInsight {
            return mainInsight.title
        }

        return "You spent \(MoneyFormat.currency(store.monthlySpend)) this month."
    }

    private var monthCaption: String {
        if store.incomeThisMonth > 0 {
            let remaining = store.incomeThisMonth - store.monthlySpend
            if remaining >= 0 {
                return "\(MoneyFormat.currency(remaining)) left against income"
            }
            return "\(MoneyFormat.currency(abs(remaining))) over income"
        }

        return store.reportingMonthTitle
    }

    private var nextActionTitle: String {
        if !store.hasFinancialData {
            return "Connect your first account"
        }

        return mainInsight?.action ?? "Review your spending"
    }

    private var nextActionCaption: String {
        if !store.hasFinancialData {
            return "Start with Plaid or import an Apple Card statement."
        }

        return mainInsight?.message ?? "Open Advice for the plain-English explanation."
    }
}

private struct BriefMetric: View {
    var title: String
    var value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(ClarityColor.secondaryText)
                .lineLimit(1)

            Text(value)
                .font(.subheadline.weight(.bold))
                .foregroundStyle(ClarityColor.primaryText)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(ClarityColor.panelElevated)
        )
    }
}

private struct BriefDivider: View {
    var body: some View {
        Divider()
            .overlay(ClarityColor.stroke)
    }
}

private struct LearningRow: View {
    var symbolName: String
    var title: String
    var value: String
    var caption: String

    var body: some View {
        HStack(spacing: 12) {
            IconBadge(symbolName: symbolName)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(ClarityColor.primaryText)

                Text(caption)
                    .font(.caption)
                    .foregroundStyle(ClarityColor.secondaryText)
                    .lineLimit(1)
            }

            Spacer()

            Text(value)
                .font(.headline.weight(.bold))
                .foregroundStyle(ClarityColor.primaryText)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .padding(.vertical, 12)
    }
}
