import SwiftUI

struct BudgetView: View {
    @Bindable var store: FinanceStore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                ScreenTitle(title: "Budget", subtitle: "Simple monthly limits that stay tied to real spending.")

                if !store.data.accounts.isEmpty {
                    AccountFilterBar(accounts: store.data.accounts, selectedAccountIDs: $store.selectedAccountIDs)
                }

                MetricCard(
                    title: "Spent this month",
                    value: MoneyFormat.currency(store.monthlySpend),
                    caption: "Across \(store.filteredBudgets.count) tracked categories",
                    symbolName: "chart.pie.fill"
                )

                VStack(alignment: .leading, spacing: 16) {
                    SectionHeader(title: "Categories")

                    if store.filteredBudgets.isEmpty {
                        EmptyStateView(
                            title: "No budget data yet",
                            message: "Budgets are calculated after real transactions are synced or imported.",
                            symbolName: "chart.pie"
                        )
                    } else {
                        ForEach(store.filteredBudgets) { budget in
                            BudgetProgressRow(budget: budget)
                        }
                    }
                }
                .padding(18)
                .clarityCard(radius: 20)
            }
            .padding(24)
            .frame(maxWidth: 820, alignment: .leading)
        }
        .clarityTabContentPadding()
    }
}

struct BudgetProgressRow: View {
    var budget: BudgetCategory

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(budget.category.title, systemImage: budget.category.symbolName)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(ClarityColor.primaryText)

                Spacer()

                Text("\(MoneyFormat.currency(budget.spent)) / \(MoneyFormat.currency(budget.limit))")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(ClarityColor.secondaryText)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }

            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(ClarityColor.panelElevated)

                    Capsule()
                        .fill(budget.progress > 0.9 ? ClarityColor.red : ClarityColor.primaryText)
                        .frame(width: geometry.size.width * budget.progress)
                }
            }
            .frame(height: 8)
        }
    }
}
