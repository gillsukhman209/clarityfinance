import SwiftUI

struct TransactionsView: View {
    @Bindable var store: FinanceStore
    @State private var searchText = ""
    @State private var selectedCategory: TransactionCategory?
    @State private var selectedTransaction: FinanceTransaction?

    var filteredTransactions: [FinanceTransaction] {
        store.recentTransactions.filter { transaction in
            let matchesSearch = searchText.isEmpty ||
            transaction.merchantName.localizedCaseInsensitiveContains(searchText) ||
            transaction.originalName.localizedCaseInsensitiveContains(searchText)

            let matchesCategory = selectedCategory == nil || transaction.category == selectedCategory
            return matchesSearch && matchesCategory
        }
    }

    var body: some View {
        let visibleTransactions = filteredTransactions

        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                ScreenTitle(title: "Transactions", subtitle: "A single feed across every bank, card, and statement.")

                if !store.data.accounts.isEmpty {
                    AccountFilterBar(accounts: store.data.accounts, selectedAccountIDs: $store.selectedAccountIDs)
                }

                TextField("Search merchants", text: $searchText)
                    .textFieldStyle(.plain)
                    .padding(14)
                    .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(ClarityColor.panel))
                    .foregroundStyle(ClarityColor.primaryText)

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        CategoryChip(title: "All", isSelected: selectedCategory == nil) {
                            selectedCategory = nil
                        }

                        ForEach(TransactionCategory.allCases) { category in
                            CategoryChip(title: category.title, isSelected: selectedCategory == category) {
                                selectedCategory = category
                            }
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 8) {
                    SectionHeader(title: "\(visibleTransactions.count) transactions")

                    if visibleTransactions.isEmpty {
                        EmptyStateView(
                            title: store.data.transactions.isEmpty ? "No transactions yet" : "No matches",
                            message: store.data.transactions.isEmpty ? "Connect Plaid Sandbox or import an Apple Card PDF to build your transaction feed." : "Try another merchant or category.",
                            symbolName: store.data.transactions.isEmpty ? "list.bullet.rectangle.portrait" : "magnifyingglass"
                        )
                    } else {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(visibleTransactions) { transaction in
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
                            }
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
        .sheet(item: $selectedTransaction) { transaction in
            TransactionDetailView(
                transaction: transaction,
                account: store.account(for: transaction.accountID)
            )
        }
    }
}

struct CategoryChip: View {
    var title: String
    var isSelected: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.caption.weight(.bold))
                .foregroundStyle(isSelected ? .white : ClarityColor.secondaryText)
                .padding(.horizontal, 13)
                .padding(.vertical, 9)
                .background(
                    Capsule()
                        .fill(isSelected ? Color.black : ClarityColor.panelElevated)
                )
        }
        .buttonStyle(.plain)
    }
}
