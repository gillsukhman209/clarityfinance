import SwiftUI

struct SubscriptionsView: View {
    @Bindable var store: FinanceStore
    @State private var selectedSubscription: SubscriptionIntelligence?

    var body: some View {
        let model = SubscriptionScreenModel(items: store.subscriptionIntelligence)

        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                ScreenTitle(title: "Subscriptions", subtitle: "Detected recurring charges, split into subscriptions and bills.")

                if !store.data.accounts.isEmpty {
                    AccountFilterBar(accounts: store.data.accounts, selectedAccountIDs: $store.selectedAccountIDs)
                }

                MetricCard(
                    title: "Recurring",
                    value: MoneyFormat.currency(model.totalMonthlyRecurring),
                    caption: "\(model.visibleItems.count) charge(s), \(model.activeItems.count) active",
                    symbolName: "calendar.badge.clock"
                )

                Text(store.data.transactions.isEmpty ? "Connect a bank in Settings." : "Pull down to refresh recurring charges.")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(ClarityColor.secondaryText)

                if model.allItems.isEmpty {
                    EmptyStateView(
                        title: "No recurring charges yet",
                        message: "Run the spending scan in Settings after syncing transactions.",
                        symbolName: "calendar"
                    )
                    .padding(18)
                    .clarityCard(radius: 20)
                } else {
                    recurringSection(
                        title: "Subscriptions",
                        total: model.subscriptionsTotal,
                        items: model.subscriptionItems,
                        emptyMessage: "No subscriptions found yet."
                    )

                    recurringSection(
                        title: "Recurring bills",
                        total: model.billsTotal,
                        items: model.billItems,
                        emptyMessage: "No recurring bills found yet."
                    )

                    if !model.inactiveItems.isEmpty {
                        recurringSection(
                            title: "Inactive",
                            total: model.inactiveTotal,
                            items: model.inactiveItems,
                            emptyMessage: ""
                        )
                    }

                    if !model.ignoredItems.isEmpty {
                        recurringSection(
                            title: "Hidden",
                            total: model.ignoredTotal,
                            items: model.ignoredItems,
                            emptyMessage: ""
                        )
                    }
                }

                if !store.recurringDiagnostics.isEmpty {
                    RecurringDiagnosticsCard(lines: store.recurringDiagnostics)
                }
            }
            .padding(24)
            .frame(maxWidth: 820, alignment: .leading)
        }
        .clarityTabContentPadding()
        .sheet(item: $selectedSubscription) { item in
            SubscriptionDetailView(
                subscription: item.subscription,
                account: item.account,
                recentTransactions: FinanceCoachEngine.relatedTransactions(for: item.subscription, in: store.filteredTransactions),
                intelligence: item
            ) { correction in
                store.setRecurringCharge(item.subscription, correction: correction)
            }
        }
        .refreshable {
            guard !store.data.transactions.isEmpty else { return }
            await store.refreshRecurringCharges()
        }
    }

    private func recurringSection(
        title: String,
        total: Double,
        items: [SubscriptionIntelligence],
        emptyMessage: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "\(title) • \(MoneyFormat.currency(total))")

            if items.isEmpty {
                Text(emptyMessage)
                    .font(.subheadline)
                    .foregroundStyle(ClarityColor.secondaryText)
                    .padding(.vertical, 8)
            } else {
                ForEach(items) { item in
                    Button {
                        selectedSubscription = item
                    } label: {
                        SubscriptionRow(
                            subscription: item.subscription,
                            account: item.account,
                            statusLine: "\(item.statusLine) • \(MoneyFormat.currency(item.totalPaidThisYear)) this year",
                            isIgnored: item.isIgnored
                        ) {
                            correctionMenu(for: item)
                        }
                    }
                    .buttonStyle(.plain)
                    .contentShape(Rectangle())
                }
            }
        }
        .padding(18)
        .clarityCard(radius: 20)
    }

    @ViewBuilder
    private func correctionMenu(for item: SubscriptionIntelligence) -> some View {
        Menu {
            Button("Mark as subscription") {
                store.setRecurringCharge(item.subscription, correction: .subscription)
            }

            Button("Mark as bill") {
                store.setRecurringCharge(item.subscription, correction: .bill)
            }

            Button(item.isIgnored ? "Restore recurring charge" : "Hide recurring charge") {
                store.setRecurringCharge(item.subscription, correction: item.isIgnored ? nil : .ignored)
            }

            if item.correction != nil {
                Button("Reset") {
                    store.setRecurringCharge(item.subscription, correction: nil)
                }
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(ClarityColor.secondaryText)
                .frame(width: 34, height: 34)
                .background(Circle().fill(ClarityColor.panelElevated))
        }
        .buttonStyle(.plain)
    }
}

private struct SubscriptionScreenModel {
    var allItems: [SubscriptionIntelligence]
    var visibleItems: [SubscriptionIntelligence]
    var activeItems: [SubscriptionIntelligence]
    var inactiveItems: [SubscriptionIntelligence]
    var subscriptionItems: [SubscriptionIntelligence]
    var billItems: [SubscriptionIntelligence]
    var ignoredItems: [SubscriptionIntelligence]
    var subscriptionsTotal: Double
    var billsTotal: Double
    var inactiveTotal: Double
    var ignoredTotal: Double
    var totalMonthlyRecurring: Double

    init(items: [SubscriptionIntelligence]) {
        allItems = items
        visibleItems = items.filter { !$0.isIgnored }
        activeItems = visibleItems.filter { $0.subscription.isActive }
        inactiveItems = visibleItems.filter { !$0.subscription.isActive }
        subscriptionItems = activeItems.filter { $0.subscription.recurringKind == .subscription }
        billItems = activeItems.filter { $0.subscription.recurringKind == .bill }
        ignoredItems = items.filter(\.isIgnored)
        subscriptionsTotal = subscriptionItems.reduce(0) { $0 + $1.subscription.monthlyAmount }
        billsTotal = billItems.reduce(0) { $0 + $1.subscription.monthlyAmount }
        inactiveTotal = inactiveItems.reduce(0) { $0 + $1.subscription.monthlyAmount }
        ignoredTotal = ignoredItems.reduce(0) { $0 + $1.subscription.monthlyAmount }
        totalMonthlyRecurring = activeItems.reduce(0) { $0 + $1.subscription.monthlyAmount }
    }
}

private struct RecurringDiagnosticsCard: View {
    var lines: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "Recurring diagnostics", systemImage: "stethoscope")

            Text(lines.joined(separator: "\n"))
                .font(.caption.monospaced())
                .foregroundStyle(ClarityColor.secondaryText)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(18)
        .clarityCard(radius: 20)
    }
}

struct SubscriptionRow: View {
    var subscription: SubscriptionItem
    var account: FinancialAccount?
    var statusLine: String?
    var isIgnored = false
    var accessory: AnyView?

    init(
        subscription: SubscriptionItem,
        account: FinancialAccount?,
        statusLine: String? = nil,
        isIgnored: Bool = false,
        @ViewBuilder accessory: () -> some View = { EmptyView() }
    ) {
        self.subscription = subscription
        self.account = account
        self.statusLine = statusLine
        self.isIgnored = isIgnored
        self.accessory = AnyView(accessory())
    }

    var body: some View {
        HStack(spacing: 12) {
            IconBadge(symbolName: subscription.recurringKind.symbolName)

            VStack(alignment: .leading, spacing: 3) {
                Text(subscription.displayName)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(ClarityColor.primaryText)
                    .strikethrough(isIgnored)

                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(ClarityColor.secondaryText)
                    .lineLimit(1)
            }

            Spacer()

            Text(MoneyFormat.currency(subscription.monthlyAmount))
                .font(.subheadline.weight(.bold))
                .foregroundStyle(ClarityColor.primaryText)

            accessory
        }
        .padding(.vertical, 8)
    }

    private var subtitle: String {
        if let statusLine {
            return statusLine
        }

        let date = subscription.nextExpectedDate.formatted(.dateTime.month(.abbreviated).day())
        if let account {
            return "Next expected \(date) • \(account.name)"
        }
        return "Next expected \(date)"
    }
}
