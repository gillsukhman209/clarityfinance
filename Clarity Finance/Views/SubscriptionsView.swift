import SwiftUI

struct SubscriptionsView: View {
    @Bindable var store: FinanceStore

    var totalMonthly: Double {
        store.filteredSubscriptions.reduce(0) { $0 + $1.monthlyAmount }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                ScreenTitle(title: "Subscriptions", subtitle: "Recurring charges detected from synced transactions.")

                if !store.data.accounts.isEmpty {
                    AccountFilterBar(accounts: store.data.accounts, selectedAccountIDs: $store.selectedAccountIDs)
                }

                MetricCard(
                    title: "Monthly recurring",
                    value: MoneyFormat.currency(totalMonthly),
                    caption: "\(store.filteredSubscriptions.count) active streams",
                    symbolName: "calendar.badge.clock"
                )

                VStack(alignment: .leading, spacing: 10) {
                    SectionHeader(title: "Detected subscriptions")

                    if store.filteredSubscriptions.isEmpty {
                        EmptyStateView(title: "No recurring charges yet", message: "Sync more transaction history to detect subscriptions.", symbolName: "calendar")
                    } else {
                        ForEach(store.filteredSubscriptions) { subscription in
                            SubscriptionRow(
                                subscription: subscription,
                                account: subscription.accountID.flatMap { store.account(for: $0) }
                            )
                        }
                    }
                }
                .padding(18)
                .clarityCard(radius: 20)
            }
            .padding(24)
            .frame(maxWidth: 820, alignment: .leading)
        }
    }
}

struct SubscriptionRow: View {
    var subscription: SubscriptionItem
    var account: FinancialAccount?

    var body: some View {
        HStack(spacing: 12) {
            IconBadge(symbolName: subscription.category.symbolName)

            VStack(alignment: .leading, spacing: 3) {
                Text(subscription.merchantName)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(ClarityColor.primaryText)

                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(ClarityColor.secondaryText)
            }

            Spacer()

            Text(MoneyFormat.currency(subscription.monthlyAmount))
                .font(.subheadline.weight(.bold))
                .foregroundStyle(ClarityColor.primaryText)
        }
        .padding(.vertical, 8)
    }

    private var subtitle: String {
        let date = subscription.nextExpectedDate.formatted(.dateTime.month(.abbreviated).day())
        if let account {
            return "Next expected \(date) • \(account.name)"
        }
        return "Next expected \(date)"
    }
}
