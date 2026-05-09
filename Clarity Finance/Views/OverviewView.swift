import SwiftUI

struct OverviewView: View {
    @Bindable var store: FinanceStore
    var navigate: (AppSection) -> Void

    private let weekdayLabels = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 28) {
                    topBar
                    spendingCard
                    latestSection
                    accountsStrip
                }
                .padding(.horizontal, 24)
                .padding(.top, 18)
                .padding(.bottom, 112)
                .frame(maxWidth: 620, alignment: .leading)
            }

            Button {
                navigate(.accounts)
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 30, weight: .medium))
                    .foregroundStyle(.white)
                    .frame(width: 68, height: 68)
                    .background(Circle().fill(Color.black))
            }
            .buttonStyle(.plain)
            .padding(.trailing, 28)
            .padding(.bottom, 82)
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

            HStack(spacing: 14) {
                Button {
                    navigate(.transactions)
                } label: {
                    Image(systemName: "magnifyingglass")
                }

                Button {
                    navigate(.accounts)
                } label: {
                    Image(systemName: "line.3.horizontal")
                }

                Button {
                    navigate(.settings)
                } label: {
                    Image(systemName: "gearshape")
                }
            }
            .font(.system(size: 19, weight: .semibold))
            .foregroundStyle(ClarityColor.primaryText)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(Capsule().fill(ClarityColor.panelElevated))
            .buttonStyle(.plain)
        }
    }

    private var spendingCard: some View {
        VStack(alignment: .leading, spacing: 22) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Total Spending")
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(ClarityColor.secondaryText)

                Text(MoneyFormat.currency(store.monthlySpend))
                    .font(.system(size: 44, weight: .bold, design: .rounded))
                    .foregroundStyle(ClarityColor.primaryText)
                    .lineLimit(1)
                    .minimumScaleFactor(0.64)
            }

            SimpleBarChart(values: weeklySpendValues, labels: weekdayLabels)
                .frame(height: 210)
        }
        .padding(22)
        .clarityCard(radius: 24)
    }

    private var latestSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Latest")
                .font(.title3.weight(.semibold))
                .foregroundStyle(ClarityColor.secondaryText)
                .padding(.leading, 4)

            VStack(spacing: 0) {
                if store.recentTransactions.isEmpty {
                    EmptyStateView(
                        title: "No transactions yet",
                        message: "Connect an account or import a statement to start tracking spending.",
                        symbolName: "list.bullet.rectangle.portrait"
                    )
                } else {
                    ForEach(Array(store.recentTransactions.prefix(4).enumerated()), id: \.element.id) { index, transaction in
                        TransactionRow(
                            transaction: transaction,
                            account: store.account(for: transaction.accountID)
                        )

                        if index < min(store.recentTransactions.count, 4) - 1 {
                            Divider()
                                .padding(.leading, 52)
                        }
                    }
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 8)
            .clarityCard(radius: 22)
        }
    }

    private var accountsStrip: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Accounts")
                .font(.title3.weight(.semibold))
                .foregroundStyle(ClarityColor.secondaryText)
                .padding(.leading, 4)

            if store.filteredAccounts.isEmpty {
                Button {
                    navigate(.accounts)
                } label: {
                    Text("Connect account")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(PrimaryClarityButtonStyle())
            } else {
                VStack(spacing: 0) {
                    ForEach(store.filteredAccounts.prefix(3)) { account in
                        AccountRow(account: account)
                    }
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 8)
                .clarityCard(radius: 22)
            }
        }
    }

    private var weeklySpendValues: [Double] {
        let calendar = Calendar.current
        let now = Date()
        let startOfWeek = calendar.dateInterval(of: .weekOfYear, for: now)?.start ?? now

        return (0..<7).map { dayOffset in
            guard let day = calendar.date(byAdding: .day, value: dayOffset, to: startOfWeek) else { return 0 }
            return store.filteredTransactions
                .filter { !$0.isIncome && calendar.isDate($0.date, inSameDayAs: day) }
                .reduce(0) { $0 + abs($1.amount) }
        }
    }
}

private struct SimpleBarChart: View {
    var values: [Double]
    var labels: [String]

    var body: some View {
        GeometryReader { geometry in
            let chartHeight = geometry.size.height - 30
            let maxValue = Swift.max(values.max() ?? 0, 1)

            ZStack(alignment: .bottomLeading) {
                VStack(spacing: 0) {
                    ForEach([80, 60, 40, 20, 0], id: \.self) { label in
                        HStack(spacing: 8) {
                            Rectangle()
                                .fill(ClarityColor.stroke)
                                .frame(height: 1)
                            Text("\(label)")
                                .font(.caption2.weight(.medium))
                                .foregroundStyle(ClarityColor.secondaryText)
                                .frame(width: 22, alignment: .trailing)
                        }
                        if label != 0 {
                            Spacer(minLength: 0)
                        }
                    }
                }
                .frame(height: chartHeight)

                HStack(alignment: .bottom, spacing: 0) {
                    ForEach(Array(values.enumerated()), id: \.offset) { index, value in
                        VStack(spacing: 8) {
                            Spacer(minLength: 0)

                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(Color.black)
                                .frame(
                                    width: 34,
                                    height: Swift.max(2, chartHeight * CGFloat(value / maxValue) * 0.86)
                                )
                                .opacity(value == 0 ? 0 : 1)

                            Text(labels.indices.contains(index) ? labels[index] : "")
                                .font(.caption2.weight(.medium))
                                .foregroundStyle(ClarityColor.secondaryText)
                                .frame(height: 18)
                        }
                        .frame(maxWidth: .infinity)
                    }
                }
                .padding(.trailing, 34)
            }
        }
    }
}
