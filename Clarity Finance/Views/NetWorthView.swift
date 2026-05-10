import SwiftUI

struct NetWorthView: View {
    @Bindable var store: FinanceStore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                ScreenTitle(title: "Net Worth", subtitle: "Assets minus credit cards, loans, and other liabilities.")

                if !store.data.accounts.isEmpty {
                    AccountFilterBar(accounts: store.data.accounts, selectedAccountIDs: $store.selectedAccountIDs)
                }

                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                    MetricCard(title: store.isAccountFilterActive ? "Balance" : "Net worth", value: MoneyFormat.currency(store.totalBalance), caption: store.isAccountFilterActive ? store.accountFilterCaption : "Assets minus debt", symbolName: "chart.line.uptrend.xyaxis", tint: ClarityColor.purpleLight)
                    MetricCard(title: "Debt", value: MoneyFormat.currency(store.liabilitiesTotal), caption: "Credit balances", symbolName: "creditcard.trianglebadge.exclamationmark", tint: ClarityColor.red)
                }

                VStack(alignment: .leading, spacing: 16) {
                    SectionHeader(title: "Trend")

                    if store.isAccountFilterActive {
                        EmptyStateView(
                            title: "Account filter active",
                            message: "The balance sheet below is filtered. Net worth history is tracked across all accounts.",
                            symbolName: "line.3.horizontal.decrease.circle"
                        )
                    } else if store.data.netWorthSnapshots.isEmpty {
                        EmptyStateView(
                            title: "No net worth history yet",
                            message: "Connect accounts to start tracking assets minus debt.",
                            symbolName: "chart.line.uptrend.xyaxis"
                        )
                    } else {
                        MiniLineChart(values: store.data.netWorthSnapshots.map(\.netWorth), lineColor: ClarityColor.green)
                            .frame(height: 180)
                    }

                    HStack {
                        Text(store.data.netWorthSnapshots.first?.date.formatted(.dateTime.month(.abbreviated).year()) ?? "Start")
                        Spacer()
                        Text(store.data.netWorthSnapshots.last?.date.formatted(.dateTime.month(.abbreviated).year()) ?? "Now")
                    }
                    .font(.caption.weight(.medium))
                    .foregroundStyle(ClarityColor.secondaryText)
                }
                .padding(18)
                .clarityCard(radius: 20)

                VStack(alignment: .leading, spacing: 10) {
                    SectionHeader(title: "Balance sheet")

                    if store.filteredAccounts.isEmpty {
                        EmptyStateView(
                            title: "No accounts yet",
                            message: "Your assets and liabilities will appear here after Plaid syncs.",
                            symbolName: "wallet.pass"
                        )
                    } else {
                        ForEach(store.filteredAccounts.sorted { $0.kind.isLiability.description < $1.kind.isLiability.description }) { account in
                            AccountRow(account: account)
                        }
                    }
                }
                .padding(18)
                .clarityCard(radius: 20)
            }
            .padding(24)
            .frame(maxWidth: 900, alignment: .leading)
        }
        .clarityTabContentPadding()
    }
}
