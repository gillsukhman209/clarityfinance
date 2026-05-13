import AuthenticationServices
import SwiftUI
import UniformTypeIdentifiers
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

struct ContentView: View {
    @Environment(\.scenePhase) private var scenePhase

    @Bindable var store: FinanceStore
    @AppStorage("clarityAppearance") private var appearanceRawValue = ClarityAppearance.light.rawValue
    @State private var selectedTab: ClarityTab = .today
    @State private var plaidWebSession: PlaidWebSession?
    @State private var isImportingStatement = false
    @State private var showsDiagnostics = false

    private var selectedAppearance: ClarityAppearance {
        ClarityAppearance(rawValue: appearanceRawValue) ?? .light
    }

    var body: some View {
        TabView(selection: $selectedTab) {
            TodayTab(store: store)
                .tabItem { Label("Today", systemImage: "house.fill") }
                .tag(ClarityTab.today)

            ActivityTab(store: store)
                .tabItem { Label("Activity", systemImage: "list.bullet.rectangle.portrait.fill") }
                .tag(ClarityTab.activity)

            SubscriptionsView(store: store)
                .tabItem { Label("Subs", systemImage: "calendar.badge.clock") }
                .tag(ClarityTab.subscriptions)

            CreditCardsTab(store: store)
                .tabItem { Label("Cards", systemImage: "creditcard.fill") }
                .tag(ClarityTab.creditCards)

            CoachView(store: store)
                .tabItem { Label("Coach", systemImage: "sparkles") }
                .tag(ClarityTab.coach)

            SettingsTab(
                store: store,
                plaidWebSession: $plaidWebSession,
                isImportingStatement: $isImportingStatement,
                showsDiagnostics: $showsDiagnostics,
                appearanceRawValue: $appearanceRawValue
            )
            .tabItem { Label("Settings", systemImage: "gearshape.fill") }
            .tag(ClarityTab.settings)
        }
        .clarityBackground()
        .preferredColorScheme(selectedAppearance.colorScheme)
        .sheet(item: $plaidWebSession) { session in
            PlaidLinkSheet(store: store, session: session)
        }
        .fileImporter(
            isPresented: $isImportingStatement,
            allowedContentTypes: [.pdf],
            allowsMultipleSelection: true
        ) { result in
            switch result {
            case .success(let urls):
                store.importAppleCardStatements(from: urls)
            case .failure(let error):
                store.lastErrorMessage = error.localizedDescription
            }
        }
        .onChange(of: scenePhase) { _, newPhase in
            guard newPhase == .active else { return }
            Task { await store.importCompletedHostedLinkWhenAppReturns() }
        }
    }
}

private enum ClarityTab {
    case today
    case activity
    case subscriptions
    case creditCards
    case coach
    case settings
}

private struct TodayTab: View {
    @Environment(\.colorScheme) private var colorScheme

    @Bindable var store: FinanceStore
    @State private var selectedTransaction: FinanceTransaction?

    var body: some View {
        ScreenScroll {
            todayBalanceView
            latestPreviewCard
        }
        .sheet(item: $selectedTransaction) { transaction in
            TransactionDetailView(
                transaction: transaction,
                account: store.account(for: transaction.accountID),
                classification: store.classification(for: transaction),
                merchantHistory: store.merchantHistory(for: transaction)
            )
        }
        .refreshable {
            guard !store.data.connections.isEmpty else { return }
            await store.syncAllConnections()
        }
    }

    private var todayBalanceView: some View {
        VStack(alignment: .leading, spacing: 28) {
            HStack(alignment: .center) {
                Circle()
                    .fill(ClarityColor.primaryText)
                    .frame(width: 12, height: 12)

                Spacer()

                if !store.data.accounts.isEmpty {
                    AccountFilterBar(accounts: store.data.accounts, selectedAccountIDs: $store.selectedAccountIDs)
                        .fixedSize()
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Balance")
                    .font(.caption.weight(.bold))
                    .textCase(.uppercase)
                    .foregroundStyle(ClarityColor.secondaryText)

                Text(MoneyFormat.currency(currentBalance))
                    .font(.system(size: 62, weight: .regular))
                    .foregroundStyle(ClarityColor.primaryText)
                    .lineLimit(1)
                    .minimumScaleFactor(0.48)
            }

            VStack(spacing: 16) {
                Image(colorScheme == .dark ? "hourglass_dark" : "hourglass")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 232, height: 258)
                    .accessibilityHidden(true)
                    .shadow(color: Color.black.opacity(0.08), radius: 24, x: 0, y: 18)
                    .frame(maxWidth: .infinity)

                Text(balanceLine)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(ClarityColor.primaryText)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)

                HStack(spacing: 5) {
                    Capsule()
                        .fill(ClarityColor.primaryText)
                        .frame(width: 18, height: 4)
                    Circle()
                        .fill(ClarityColor.primaryText.opacity(0.28))
                        .frame(width: 4, height: 4)
                    Capsule()
                        .fill(ClarityColor.primaryText.opacity(0.16))
                        .frame(width: 18, height: 3)
                }
            }

            VStack(spacing: 0) {
                TodayBalanceMetricRow(title: "Income", amount: store.incomeThisMonth, tone: .positive)
                Divider().overlay(ClarityColor.stroke)
                TodayBalanceMetricRow(title: "Expenses", amount: store.monthlySpend, tone: .negative)
                Divider().overlay(ClarityColor.stroke)
                TodayBalanceMetricRow(title: "Saved", amount: savedThisMonth, tone: .neutral)
            }
        }
        .padding(.top, 6)
    }

    private var currentBalance: Double {
        store.assetsTotal - store.liabilitiesTotal
    }

    private var savedThisMonth: Double {
        max(0, store.incomeThisMonth - store.monthlySpend)
    }

    private var balanceLine: String {
        if store.data.accounts.isEmpty && store.data.transactions.isEmpty {
            return "Connect your accounts to see the full picture."
        }

        if savedThisMonth > 0 {
            return "You kept \(MoneyFormat.currency(savedThisMonth)) this month."
        }

        if store.monthlySpend > 0 {
            return "You spent \(MoneyFormat.currency(store.monthlySpend)) this month."
        }

        return "Your money is quiet right now."
    }

    private var latestPreviewCard: some View {
        let recentTransactions = Array(store.recentTransactions.prefix(5))

        return VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "Latest", systemImage: "clock.fill")

            if recentTransactions.isEmpty {
                EmptyStateView(
                    title: "No transactions",
                    message: "Connect a bank in Settings, then refresh.",
                    symbolName: "receipt"
                )
            } else {
                ForEach(recentTransactions) { transaction in
                    Button {
                        selectedTransaction = transaction
                    } label: {
                        SimpleTransactionRow(
                            transaction: transaction,
                            classification: store.classification(for: transaction),
                            account: store.account(for: transaction.accountID)
                        )
                    }
                    .buttonStyle(.plain)

                    if transaction.id != recentTransactions.last?.id {
                        Divider()
                    }
                }
            }
        }
        .padding(18)
        .clarityCard(radius: 20)
    }
}

private struct TodayBalanceMetricRow: View {
    enum Tone {
        case positive
        case negative
        case neutral
    }

    var title: String
    var amount: Double
    var tone: Tone

    var body: some View {
        HStack(spacing: 18) {
            Text(title)
                .font(.headline.weight(.semibold))
                .foregroundStyle(ClarityColor.primaryText)

            Spacer()

            MiniPulseLine(tone: tone)
                .frame(width: 44, height: 18)

            Text(MoneyFormat.currency(amount))
                .font(.headline.weight(.bold))
                .foregroundStyle(ClarityColor.primaryText)
                .lineLimit(1)
                .minimumScaleFactor(0.76)
                .frame(minWidth: 92, alignment: .trailing)
        }
        .padding(.vertical, 17)
    }
}

private struct MiniPulseLine: View {
    var tone: TodayBalanceMetricRow.Tone

    var body: some View {
        GeometryReader { geometry in
            Path { path in
                let width = geometry.size.width
                let height = geometry.size.height
                path.move(to: CGPoint(x: 0, y: height * 0.60))
                path.addLine(to: CGPoint(x: width * 0.25, y: tone == .negative ? height * 0.42 : height * 0.68))
                path.addLine(to: CGPoint(x: width * 0.48, y: tone == .negative ? height * 0.68 : height * 0.46))
                path.addLine(to: CGPoint(x: width * 0.72, y: tone == .negative ? height * 0.56 : height * 0.36))
                path.addLine(to: CGPoint(x: width, y: tone == .negative ? height * 0.76 : height * 0.22))
            }
            .stroke(color, style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
        }
    }

    private var color: Color {
        switch tone {
        case .positive:
            return ClarityColor.green
        case .negative:
            return ClarityColor.red
        case .neutral:
            return ClarityColor.primaryText.opacity(0.62)
        }
    }
}

private struct ActivityTab: View {
    @Bindable var store: FinanceStore
    @State private var selectedTransaction: FinanceTransaction?

    var body: some View {
        let recentTransactions = Array(store.recentTransactions.prefix(60))

        ScreenScroll {
            HeaderView(title: "Activity", subtitle: store.accountFilterCaption) {
                if !store.data.accounts.isEmpty {
                    AccountFilterBar(accounts: store.data.accounts, selectedAccountIDs: $store.selectedAccountIDs)
                }
            }

            VStack(alignment: .leading, spacing: 12) {
                SectionHeader(title: "Transactions", systemImage: "list.bullet.rectangle.portrait.fill")

                if recentTransactions.isEmpty {
                    EmptyStateView(
                        title: "No transactions",
                        message: "Connect a bank in Settings, then refresh.",
                        symbolName: "receipt"
                    )
                } else {
                    ForEach(recentTransactions) { transaction in
                        Button {
                            selectedTransaction = transaction
                        } label: {
                            SimpleTransactionRow(
                                transaction: transaction,
                                classification: store.classification(for: transaction),
                                account: store.account(for: transaction.accountID)
                            )
                        }
                        .buttonStyle(.plain)

                        if transaction.id != recentTransactions.last?.id {
                            Divider()
                        }
                    }
                }
            }
            .padding(18)
            .clarityCard(radius: 20)
        }
        .sheet(item: $selectedTransaction) { transaction in
            TransactionDetailView(
                transaction: transaction,
                account: store.account(for: transaction.accountID),
                classification: store.classification(for: transaction),
                merchantHistory: store.merchantHistory(for: transaction)
            )
        }
        .refreshable {
            guard !store.data.connections.isEmpty else { return }
            await store.syncAllConnections()
        }
    }
}

private struct AccountsTab: View {
    @Bindable var store: FinanceStore
    @State private var accountPendingRemoval: FinancialAccount?

    var body: some View {
        let filteredAccounts = store.filteredAccounts

        ScreenScroll {
            HeaderView(title: "Accounts", subtitle: store.accountFilterCaption) {
                if !store.data.accounts.isEmpty {
                    AccountFilterBar(accounts: store.data.accounts, selectedAccountIDs: $store.selectedAccountIDs)
                }
            }

            VStack(alignment: .leading, spacing: 12) {
                SectionHeader(title: "Balances", systemImage: "wallet.pass.fill")

                if store.data.accounts.isEmpty {
                    EmptyStateView(
                        title: "No accounts",
                        message: "Go to Settings to connect a bank or import Apple Card.",
                        symbolName: "wallet.pass"
                    )
                } else {
                    ForEach(filteredAccounts) { account in
                        AccountRow(account: account) {
                            accountPendingRemoval = account
                        }

                        if account.id != filteredAccounts.last?.id {
                            Divider()
                        }
                    }
                }
            }
            .padding(18)
            .clarityCard(radius: 20)
        }
        .alert(item: $accountPendingRemoval) { account in
            Alert(
                title: Text("Remove \(account.displayName)?"),
                message: Text("This removes the account and every transaction, subscription, bill, budget number, and total linked to it from Clarity."),
                primaryButton: .destructive(Text("Remove")) {
                    store.removeAccount(account)
                },
                secondaryButton: .cancel()
            )
        }
    }
}

private struct CreditCardsTab: View {
    @Bindable var store: FinanceStore
    @State private var selectedCard: FinancialAccount?

    private var creditAccounts: [FinancialAccount] {
        deduplicatedCreditAccounts(from: store.filteredAccounts.filter { $0.kind == .creditCard })
    }

    private var totalDebt: Double {
        creditAccounts.reduce(0) { $0 + $1.currentBalance }
    }

    private var minimumPaymentTotal: Double {
        creditAccounts.reduce(0) { total, account in
            total + (store.creditCardLiability(for: account.id)?.minimumPaymentAmount ?? 0)
        }
    }

    private var cardsWithLiabilityDetails: Int {
        creditAccounts.filter { store.creditCardLiability(for: $0.id) != nil }.count
    }

    private var cardsWithMinimumPayment: Int {
        creditAccounts.filter { store.creditCardLiability(for: $0.id)?.minimumPaymentAmount != nil }.count
    }

    private var nextDueDate: Date? {
        creditAccounts
            .compactMap { store.creditCardLiability(for: $0.id)?.nextPaymentDueDate }
            .min()
    }

    var body: some View {
        ScreenScroll {
            HeaderView(title: "Cards", subtitle: "Credit card debt and due dates.") {
                if !store.data.accounts.isEmpty {
                    AccountFilterBar(accounts: store.data.accounts, selectedAccountIDs: $store.selectedAccountIDs)
                }
            }

            if let message = store.creditCardLiabilityStatusMessage {
                StatusBanner(message: message, isError: false)
            }

            if let message = store.creditCardLiabilityErrorMessage {
                StatusBanner(message: message, isError: true)
            }

            VStack(alignment: .leading, spacing: 14) {
                SectionHeader(title: "Credit snapshot", systemImage: "creditcard.fill")

                HStack(spacing: 12) {
                    MetricCard(
                        title: "Total balance",
                        value: MoneyFormat.currency(totalDebt),
                        caption: "\(creditAccounts.count) card\(creditAccounts.count == 1 ? "" : "s")",
                        symbolName: "creditcard.fill",
                        tint: ClarityColor.red
                    )
                    MetricCard(
                        title: "Minimum due",
                        value: MoneyFormat.currency(minimumPaymentTotal),
                        caption: minimumDueCaption,
                        symbolName: "calendar.badge.exclamationmark",
                        tint: ClarityColor.purple
                    )
                }

                if !creditAccounts.isEmpty && cardsWithMinimumPayment < creditAccounts.count {
                    Text("Plaid returned minimum payment details for \(cardsWithMinimumPayment) of \(creditAccounts.count) card\(creditAccounts.count == 1 ? "" : "s"). Cards can still show balances even when the bank does not return minimum due/date through Liabilities.")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(ClarityColor.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Button {
                    Task { await store.syncAllConnections() }
                } label: {
                    Label("Refresh card details", systemImage: "arrow.clockwise")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(SecondaryClarityButtonStyle())
                .disabled(store.isSyncing || store.data.connections.isEmpty)
            }
            .padding(18)
            .clarityCard(radius: 20)

            VStack(alignment: .leading, spacing: 12) {
                SectionHeader(title: "Payment details", systemImage: "calendar")

                if creditAccounts.isEmpty {
                    EmptyStateView(
                        title: "No credit cards",
                        message: "Connect a credit card account with Plaid Liabilities enabled.",
                        symbolName: "creditcard"
                    )
                } else {
                    ForEach(creditAccounts) { account in
                        Button {
                            selectedCard = account
                        } label: {
                            CreditCardLiabilityRow(
                                account: account,
                                liability: store.creditCardLiability(for: account.id)
                            )
                        }
                        .buttonStyle(.plain)

                        if account.id != creditAccounts.last?.id {
                            Divider()
                        }
                    }
                }
            }
            .padding(18)
            .clarityCard(radius: 20)
        }
        .refreshable {
            guard !store.data.connections.isEmpty else { return }
            await store.syncAllConnections()
        }
        .sheet(item: $selectedCard) { account in
            CreditCardDetailView(
                account: account,
                liability: store.creditCardLiability(for: account.id)
            )
        }
    }

    private var minimumDueCaption: String {
        if let nextDueDate {
            return "Next due \(nextDueDate.formatted(.dateTime.month(.abbreviated).day()))"
        }

        if creditAccounts.isEmpty {
            return "No cards"
        }

        if cardsWithLiabilityDetails == 0 {
            return "Waiting for Plaid"
        }

        return "\(cardsWithMinimumPayment)/\(creditAccounts.count) minimums returned"
    }

    private func deduplicatedCreditAccounts(from accounts: [FinancialAccount]) -> [FinancialAccount] {
        let grouped = Dictionary(grouping: accounts, by: creditCardDuplicateKey)

        return grouped.values
            .compactMap { group in
                group.max { lhs, rhs in
                    creditCardDisplayScore(lhs) < creditCardDisplayScore(rhs)
                }
            }
            .sorted { lhs, rhs in
                if lhs.institutionName != rhs.institutionName {
                    return lhs.institutionName < rhs.institutionName
                }

                if lhs.name != rhs.name {
                    return lhs.name < rhs.name
                }

                return (lhs.mask ?? "") < (rhs.mask ?? "")
            }
    }

    private func creditCardDisplayScore(_ account: FinancialAccount) -> Int {
        var score = 0
        let liability = store.creditCardLiability(for: account.id)

        if liability != nil { score += 100 }
        if liability?.minimumPaymentAmount != nil { score += 40 }
        if liability?.nextPaymentDueDate != nil { score += 30 }
        if account.creditLimit != nil { score += 10 }
        if account.availableBalance != nil { score += 5 }

        return score
    }

    private func creditCardDuplicateKey(_ account: FinancialAccount) -> String {
        let institution = normalizedCardKey(account.institutionName)
        if let mask = account.mask, !mask.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "\(institution)|\(normalizedCardKey(mask))"
        }

        return "\(institution)|\(normalizedCardKey(account.name))"
    }

    private func normalizedCardKey(_ value: String) -> String {
        value
            .lowercased()
            .filter { $0.isLetter || $0.isNumber }
    }
}

private struct CreditCardLiabilityRow: View {
    var account: FinancialAccount
    var liability: CreditCardLiability?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                IconBadge(symbolName: "creditcard.fill", tint: overdueColor)

                VStack(alignment: .leading, spacing: 3) {
                    Text(account.name)
                        .font(.headline.weight(.bold))
                        .foregroundStyle(ClarityColor.primaryText)
                        .lineLimit(1)

                    Text(rowSubtitle)
                        .font(.caption)
                        .foregroundStyle(ClarityColor.secondaryText)
                        .lineLimit(2)
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 3) {
                    Text(MoneyFormat.currency(account.currentBalance))
                        .font(.headline.weight(.bold))
                        .foregroundStyle(ClarityColor.primaryText)
                    Text("balance")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(ClarityColor.mutedText)
                }
            }

            if let liability {
                VStack(spacing: 10) {
                    CreditDetailLine(title: "Minimum payment", value: amountText(liability.minimumPaymentAmount))
                    CreditDetailLine(title: "Due date", value: dateText(liability.nextPaymentDueDate))
                    CreditDetailLine(title: "Last payment", value: amountText(liability.lastPaymentAmount))
                    CreditDetailLine(title: "Last statement", value: amountText(liability.lastStatementBalance))
                    CreditDetailLine(title: "APR", value: percentText(liability.aprPercentage))
                    CreditDetailLine(title: "Status", value: liability.isOverdue == true ? "Overdue" : "Current")
                }
            } else {
                Text("Balance is available, but Plaid did not return minimum payment or due date for this card.")
                    .font(.subheadline)
                    .foregroundStyle(ClarityColor.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 12)
    }

    private var overdueColor: Color {
        liability?.isOverdue == true ? ClarityColor.red : ClarityColor.blue
    }

    private var rowSubtitle: String {
        var parts = [account.institutionName, cardIdentifier]
        if let minimumPaymentAmount = liability?.minimumPaymentAmount {
            parts.append("Min \(MoneyFormat.currency(minimumPaymentAmount))")
        } else {
            parts.append("Min not returned")
        }
        return parts.joined(separator: " • ")
    }

    private var cardIdentifier: String {
        guard let mask = account.mask?.trimmingCharacters(in: .whitespacesAndNewlines), !mask.isEmpty else {
            return "Last 4 not returned"
        }
        return "•••• \(mask)"
    }

    private func amountText(_ amount: Double?) -> String {
        guard let amount else { return "Not returned" }
        return MoneyFormat.currency(amount)
    }

    private func dateText(_ date: Date?) -> String {
        guard let date else { return "Not returned" }
        return date.formatted(.dateTime.month(.abbreviated).day().year())
    }

    private func percentText(_ percent: Double?) -> String {
        guard let percent else { return "Not returned" }
        return "\(percent.formatted(.number.precision(.fractionLength(2))))%"
    }
}

private struct CreditCardDetailView: View {
    @Environment(\.dismiss) private var dismiss

    var account: FinancialAccount
    var liability: CreditCardLiability?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    VStack(alignment: .leading, spacing: 10) {
                        IconBadge(symbolName: "creditcard.fill", tint: liability?.isOverdue == true ? ClarityColor.red : ClarityColor.blue)

                        VStack(alignment: .leading, spacing: 3) {
                            Text(account.name)
                                .font(.title2.weight(.bold))
                                .foregroundStyle(ClarityColor.primaryText)
                                .lineLimit(2)

                            Text("\(account.institutionName) • \(cardIdentifier)")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(ClarityColor.secondaryText)
                        }

                        Text(MoneyFormat.currency(account.currentBalance))
                            .font(.system(size: 44, weight: .bold))
                            .foregroundStyle(ClarityColor.primaryText)
                            .lineLimit(1)
                            .minimumScaleFactor(0.65)
                    }
                    .padding(18)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .clarityCard(radius: 20)

                    VStack(spacing: 0) {
                        CreditDetailLine(title: "Institution", value: account.institutionName)
                        CreditRowDivider()
                        CreditDetailLine(title: "Card name", value: account.name)
                        CreditRowDivider()
                        CreditDetailLine(title: "Last 4", value: account.mask?.isEmpty == false ? account.mask! : "Not returned by Plaid")
                        CreditRowDivider()
                        CreditDetailLine(title: "Balance", value: MoneyFormat.currency(account.currentBalance))
                        CreditRowDivider()
                        CreditDetailLine(title: "Available credit", value: amountText(account.availableBalance))
                        CreditRowDivider()
                        CreditDetailLine(title: "Credit limit", value: amountText(account.creditLimit))
                        CreditRowDivider()
                        CreditDetailLine(title: "Utilization", value: utilizationText)
                        CreditRowDivider()
                        CreditDetailLine(title: "Source", value: account.isManual ? "PDF import" : "Plaid")
                    }
                    .padding(18)
                    .clarityCard(radius: 20)

                    if let liability {
                        VStack(spacing: 0) {
                            CreditDetailLine(title: "Minimum payment", value: amountText(liability.minimumPaymentAmount))
                            CreditRowDivider()
                            CreditDetailLine(title: "Due date", value: dateText(liability.nextPaymentDueDate))
                            CreditRowDivider()
                            CreditDetailLine(title: "Last payment", value: amountText(liability.lastPaymentAmount))
                            CreditRowDivider()
                            CreditDetailLine(title: "Last paid", value: dateText(liability.lastPaymentDate))
                            CreditRowDivider()
                            CreditDetailLine(title: "Last statement", value: amountText(liability.lastStatementBalance))
                            CreditRowDivider()
                            CreditDetailLine(title: "Statement date", value: dateText(liability.lastStatementIssueDate))
                            CreditRowDivider()
                            CreditDetailLine(title: "APR", value: percentText(liability.aprPercentage))
                            CreditRowDivider()
                            CreditDetailLine(title: "Status", value: liability.isOverdue == true ? "Overdue" : "Current")
                            CreditRowDivider()
                            CreditDetailLine(title: "Updated", value: dateTimeText(liability.updatedAt))
                        }
                        .padding(18)
                        .clarityCard(radius: 20)
                    } else {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Payment details unavailable")
                                .font(.headline.weight(.bold))
                                .foregroundStyle(ClarityColor.primaryText)

                            Text("Plaid returned this card balance, but not a Liabilities row for minimum payment, due date, APR, or statement data. That usually means this specific card or bank connection does not expose those details yet. Try Refresh card details, or reconnect the bank and make sure credit card permissions are selected.")
                                .font(.subheadline)
                                .foregroundStyle(ClarityColor.secondaryText)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(18)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .clarityCard(radius: 20)
                    }
                }
                .padding(18)
            }
            .clarityBackground()
            .navigationTitle("Card details")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private var cardIdentifier: String {
        guard let mask = account.mask?.trimmingCharacters(in: .whitespacesAndNewlines), !mask.isEmpty else {
            return "Last 4 not returned"
        }
        return "•••• \(mask)"
    }

    private var utilizationText: String {
        guard let limit = account.creditLimit, limit > 0 else { return "Not returned" }
        let utilization = max(0, account.currentBalance) / limit
        return utilization.formatted(.percent.precision(.fractionLength(1)))
    }

    private func amountText(_ amount: Double?) -> String {
        guard let amount else { return "Not returned" }
        return MoneyFormat.currency(amount)
    }

    private func dateText(_ date: Date?) -> String {
        guard let date else { return "Not returned" }
        return date.formatted(.dateTime.month(.abbreviated).day().year())
    }

    private func dateTimeText(_ date: Date?) -> String {
        guard let date else { return "Not returned" }
        return date.formatted(.dateTime.month(.abbreviated).day().year().hour().minute())
    }

    private func percentText(_ percent: Double?) -> String {
        guard let percent else { return "Not returned" }
        return "\(percent.formatted(.number.precision(.fractionLength(2))))%"
    }
}

private struct CreditRowDivider: View {
    var body: some View {
        Divider()
            .overlay(ClarityColor.stroke)
            .padding(.vertical, 10)
    }
}

private struct CreditDetailLine: View {
    var title: String
    var value: String

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(ClarityColor.secondaryText)

            Spacer(minLength: 16)

            Text(value)
                .font(.subheadline.weight(.bold))
                .foregroundStyle(ClarityColor.primaryText)
                .multilineTextAlignment(.trailing)
        }
    }
}

private struct TrendsTab: View {
    @Bindable var store: FinanceStore

    var body: some View {
        let trends = SpendingTrends(transactions: store.filteredTransactions)

        ScreenScroll {
            HeaderView(title: "Trends", subtitle: store.accountFilterCaption) {
                if !store.data.accounts.isEmpty {
                    AccountFilterBar(accounts: store.data.accounts, selectedAccountIDs: $store.selectedAccountIDs)
                }
            }

            if trends.hasSpending {
                monthTrendCard(trends)
                sevenDayCard(trends)
                trendNotesCard(trends)
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    SectionHeader(title: "No trends yet", systemImage: "chart.line.uptrend.xyaxis")
                    EmptyStateView(
                        title: "No spending to compare",
                        message: "Connect a bank or import Apple Card PDFs from Settings.",
                        symbolName: "chart.line.uptrend.xyaxis"
                    )
                }
                .padding(18)
                .clarityCard(radius: 20)
            }
        }
        .refreshable {
            guard !store.data.connections.isEmpty else { return }
            await store.syncAllConnections()
        }
    }

    private func monthTrendCard(_ trends: SpendingTrends) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Month trend")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(ClarityColor.secondaryText)

                Text(MoneyFormat.currency(trends.thisMonthTotal))
                    .font(.system(size: 42, weight: .bold))
                    .foregroundStyle(ClarityColor.primaryText)
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)

                Text("This month so far")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(ClarityColor.mutedText)
            }

            TrendBadge(
                title: trends.monthToDateComparison.title,
                caption: trends.monthToDateComparison.caption,
                isIncrease: trends.monthToDateComparison.isIncrease
            )

            HStack(spacing: 10) {
                SpendingStatCard(title: "Last month", amount: trends.lastMonthTotal)
                SpendingStatCard(title: "Same point", amount: trends.samePointLastMonthTotal)
                SpendingStatCard(title: "Change", amount: abs(trends.monthToDateComparison.delta))
            }
        }
        .padding(18)
        .clarityCard(radius: 20)
    }

    private func sevenDayCard(_ trends: SpendingTrends) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            SectionHeader(title: "Last 7 days", systemImage: "calendar")

            HStack(spacing: 10) {
                SpendingStatCard(title: "7 days", amount: trends.lastSevenDaysTotal)
                SpendingStatCard(title: "Previous", amount: trends.previousSevenDaysTotal)
                SpendingStatCard(title: "Change", amount: abs(trends.sevenDayComparison.delta))
            }

            VStack(alignment: .leading, spacing: 10) {
                MiniLineChart(values: trends.lastSevenDailyTotals)
                    .frame(height: 96)

                HStack {
                    ForEach(trends.lastSevenLabels, id: \.self) { label in
                        Text(label)
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(ClarityColor.mutedText)
                            .frame(maxWidth: .infinity)
                    }
                }
            }

            TrendBadge(
                title: trends.sevenDayComparison.title,
                caption: trends.sevenDayComparison.caption,
                isIncrease: trends.sevenDayComparison.isIncrease
            )
        }
        .padding(18)
        .clarityCard(radius: 20)
    }

    private func trendNotesCard(_ trends: SpendingTrends) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionHeader(title: "What changed", systemImage: "sparkles")

            TrendInsightRow(
                symbolName: trends.monthToDateComparison.isIncrease ? "arrow.up.right" : "arrow.down.right",
                title: "This month",
                value: trends.monthToDateComparison.summary
            )

            TrendInsightRow(
                symbolName: trends.sevenDayComparison.isIncrease ? "flame.fill" : "checkmark.circle.fill",
                title: "7-day pace",
                value: trends.sevenDayComparison.summary
            )

            if let riser = trends.topRisingMerchant {
                TrendInsightRow(
                    symbolName: "bag.fill",
                    title: "Top riser",
                    value: "\(riser.name) is up \(MoneyFormat.currency(riser.delta)) vs last month."
                )
            }

            if let expensiveDay = trends.mostExpensiveRecentDay {
                TrendInsightRow(
                    symbolName: "bolt.fill",
                    title: "Biggest day",
                    value: "\(expensiveDay.label) was your biggest recent day at \(MoneyFormat.currency(expensiveDay.total))."
                )
            }
        }
        .padding(18)
        .clarityCard(radius: 20)
    }
}

private struct SettingsTab: View {
    @Bindable var store: FinanceStore
    @Binding var plaidWebSession: PlaidWebSession?
    @Binding var isImportingStatement: Bool
    @Binding var showsDiagnostics: Bool
    @Binding var appearanceRawValue: String
    @State private var accountPendingRemoval: FinancialAccount?
    @State private var appleSignInNonce: String?

    private var selectedAppearance: ClarityAppearance {
        get {
            ClarityAppearance(rawValue: appearanceRawValue) ?? .light
        }
        nonmutating set {
            appearanceRawValue = newValue.rawValue
        }
    }

    var body: some View {
        ScreenScroll {
            HeaderView(title: "Settings", subtitle: "Connect, import, refresh.")

            appearanceCard
            authCard
            addAccountCard
            notificationsCard
            connectedAccountsCard
            toolsCard
            statusArea
        }
        .alert(item: $accountPendingRemoval) { account in
            Alert(
                title: Text("Remove \(account.displayName)?"),
                message: Text("This removes the account and every transaction, subscription, bill, budget number, and total linked to it from Clarity."),
                primaryButton: .destructive(Text("Remove")) {
                    store.removeAccount(account)
                },
                secondaryButton: .cancel()
            )
        }
    }

    private var appearanceCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionHeader(title: "Appearance", systemImage: "circle.lefthalf.filled")

            Picker("Theme", selection: Binding(
                get: { selectedAppearance },
                set: { selectedAppearance = $0 }
            )) {
                ForEach(ClarityAppearance.allCases) { appearance in
                    Text(appearance.title).tag(appearance)
                }
            }
            .pickerStyle(.segmented)

            Text("Dark mode changes the whole app and uses the dark hourglass on Today.")
                .font(.caption.weight(.semibold))
                .foregroundStyle(ClarityColor.secondaryText)
        }
        .padding(18)
        .clarityCard(radius: 20)
    }

    private var authCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionHeader(title: "Account", systemImage: "person.crop.circle.fill")

            if let authSession = store.authSession {
                HStack(spacing: 12) {
                    IconBadge(symbolName: "checkmark.seal.fill")

                    VStack(alignment: .leading, spacing: 3) {
                        Text("Signed in")
                            .font(.subheadline.weight(.bold))
                            .foregroundStyle(ClarityColor.primaryText)

                        Text(authSession.displayName)
                            .font(.caption)
                            .foregroundStyle(ClarityColor.secondaryText)
                            .lineLimit(1)
                    }

                    Spacer(minLength: 0)
                }

                HStack(spacing: 10) {
                    Button {
                        Task { await store.verifyCurrentAuthSessionWithBackend() }
                    } label: {
                        Label("Check backend", systemImage: "lock.shield.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(SecondaryClarityButtonStyle())
                    .disabled(store.isAuthActionRunning)

                    Button(role: .destructive) {
                        store.signOut()
                    } label: {
                        Label("Sign out", systemImage: "rectangle.portrait.and.arrow.right")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(SecondaryClarityButtonStyle())
                    .disabled(store.isAuthActionRunning)
                }
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Save your Clarity data to your account.")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(ClarityColor.primaryText)

                    Text(store.supabaseConfigurationStatus)
                        .font(.caption)
                        .foregroundStyle(ClarityColor.secondaryText)
                }

                SignInWithAppleButton(.signIn) { request in
                    let nonce = SupabaseAuthService.randomNonceString()
                    appleSignInNonce = nonce
                    request.requestedScopes = [.email, .fullName]
                    request.nonce = SupabaseAuthService.sha256(nonce)
                    store.recordDiagnostic("Sign in with Apple request prepared for Supabase.")
                } onCompletion: { result in
                    switch result {
                    case .success(let authorization):
                        guard
                            let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
                            let identityTokenData = credential.identityToken,
                            let identityToken = String(data: identityTokenData, encoding: .utf8)
                        else {
                            store.authErrorMessage = SupabaseAuthError.missingAppleIdentityToken.localizedDescription
                            store.recordDiagnostic("Sign in with Apple completed without an identity token.")
                            return
                        }

                        Task {
                            await store.signInWithApple(identityToken: identityToken, nonce: appleSignInNonce)
                        }
                    case .failure(let error):
                        store.authErrorMessage = error.localizedDescription
                        store.recordDiagnostic("Sign in with Apple failed before Supabase exchange: \(error.localizedDescription)")
                    }
                }
                .signInWithAppleButtonStyle(.black)
                .frame(height: 48)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .disabled(store.isAuthActionRunning || SupabaseAuthConfiguration.load() == nil)
            }

            if store.isAuthActionRunning {
                HStack(spacing: 10) {
                    ProgressView()
                    Text("Working...")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(ClarityColor.secondaryText)
                }
            }

            if let authStatusMessage = store.authStatusMessage {
                StatusBanner(message: authStatusMessage, isError: false)
            }

            if let authErrorMessage = store.authErrorMessage {
                StatusBanner(message: authErrorMessage, isError: true)
            }
        }
        .padding(18)
        .clarityCard(radius: 20)
    }

    private var addAccountCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "Add account", systemImage: "link.badge.plus")

            Button {
                store.recordDiagnostic("Connect Real Bank button tapped in Settings.")
                Task {
                    await store.connectRealBank()
                    if let hostedLinkURL = store.hostedLinkSession?.hostedLinkURL {
                        store.recordDiagnostic("Presenting Plaid Hosted Link in app web sheet.")
                        plaidWebSession = PlaidWebSession(url: hostedLinkURL)
                    } else {
                        store.recordDiagnostic("No Hosted Link URL available after connectRealBank().")
                    }
                }
            } label: {
                Label("Connect real bank", systemImage: "building.columns.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(PrimaryClarityButtonStyle())
            .disabled(store.isSyncing)

            if let hostedLinkSession = store.hostedLinkSession {
                Button {
                    plaidWebSession = PlaidWebSession(url: hostedLinkSession.hostedLinkURL)
                } label: {
                    Label("Open pending Plaid link", systemImage: "rectangle.portrait.and.arrow.right")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(SecondaryClarityButtonStyle())

                Button {
                    Task { await store.finishRealBankConnection() }
                } label: {
                    Label("Done - Import Accounts", systemImage: "square.and.arrow.down.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(PrimaryClarityButtonStyle())
                .disabled(store.isSyncing)
            }

            #if DEBUG
            HStack(spacing: 10) {
                Button {
                    Task { await store.connectSandboxInstitution() }
                } label: {
                    Label("Sandbox", systemImage: "testtube.2")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(SecondaryClarityButtonStyle())
                .disabled(store.isSyncing)

                Button {
                    isImportingStatement = true
                } label: {
                    Label("Apple Card PDFs", systemImage: "doc.badge.plus")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(SecondaryClarityButtonStyle())
            }
            #else
            Button {
                isImportingStatement = true
            } label: {
                Label("Apple Card PDFs", systemImage: "doc.badge.plus")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(SecondaryClarityButtonStyle())
            #endif
        }
        .padding(18)
        .clarityCard(radius: 20)
    }

    private var notificationsCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionHeader(title: "Viral notifications", systemImage: "bell.badge.fill")

            #if os(iOS)
            Toggle(isOn: Binding(
                get: { store.viralNotificationPreferences.isEnabled },
                set: { store.setViralNotificationsEnabled($0) }
            )) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Notify when Plaid finds spending")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(ClarityColor.primaryText)
                    Text("Max 1/day. Merchant and amount are shown by default.")
                        .font(.caption)
                        .foregroundStyle(ClarityColor.secondaryText)
                }
            }

            Picker("Tone", selection: Binding(
                get: { store.viralNotificationPreferences.tone },
                set: { store.updateViralNotificationTone($0) }
            )) {
                ForEach(ViralNotificationTone.allCases) { tone in
                    Text(tone.title).tag(tone)
                }
            }
            .pickerStyle(.segmented)

            Picker("Privacy", selection: Binding(
                get: { store.viralNotificationPreferences.privacy },
                set: { store.updateViralNotificationPrivacy($0) }
            )) {
                ForEach(ViralNotificationPrivacy.allCases) { privacy in
                    Text(privacy.title).tag(privacy)
                }
            }
            .pickerStyle(.segmented)

            #if DEBUG
            HStack(spacing: 10) {
                Button {
                    Task { await store.registerPlaidItemsWithNotificationBackend() }
                } label: {
                    if store.isNotificationActionRunning {
                        ProgressView()
                            .frame(maxWidth: .infinity)
                    } else {
                        Label("Register Plaid", systemImage: "link.badge.plus")
                            .frame(maxWidth: .infinity)
                    }
                }
                .buttonStyle(SecondaryClarityButtonStyle())
                .disabled(!store.viralNotificationPreferences.isEnabled || store.isNotificationActionRunning)

                Button {
                    Task { await store.sendTestViralNotification() }
                } label: {
                    Label("Test", systemImage: "paperplane.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(SecondaryClarityButtonStyle())
                .disabled(!store.viralNotificationPreferences.isEnabled || store.isNotificationActionRunning)
            }
            #endif

            Text(store.apnsDeviceToken == nil ? "APNs token: waiting until notifications are allowed." : "APNs token: ready.")
                .font(.caption.weight(.semibold))
                .foregroundStyle(ClarityColor.secondaryText)

            Text("Permission: \(store.notificationPermissionStatus)")
                .font(.caption.weight(.semibold))
                .foregroundStyle(ClarityColor.secondaryText)

            if store.data.connections.isEmpty {
                Text("No Plaid bank is connected yet. Test can still register this iPhone, but real transaction alerts need a Plaid account.")
                    .font(.caption)
                    .foregroundStyle(ClarityColor.secondaryText)
            }

            if let notificationStatusMessage = store.notificationStatusMessage {
                StatusBanner(message: notificationStatusMessage, isError: false)
            }

            if let notificationErrorMessage = store.notificationErrorMessage {
                StatusBanner(message: notificationErrorMessage, isError: true)
            }
            #else
            Text("Viral push notifications are configured from the iPhone app.")
                .font(.subheadline)
                .foregroundStyle(ClarityColor.secondaryText)
            #endif
        }
        .padding(18)
        .clarityCard(radius: 20)
    }

    private var connectedAccountsCard: some View {
        let accounts = store.filteredAccounts

        return VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "Accounts", systemImage: "wallet.pass.fill")

            if !store.data.accounts.isEmpty {
                AccountFilterBar(accounts: store.data.accounts, selectedAccountIDs: $store.selectedAccountIDs)
            }

            if store.data.accounts.isEmpty {
                EmptyStateView(
                    title: "No accounts connected",
                    message: "Connect a bank or import Apple Card PDFs.",
                    symbolName: "wallet.pass"
                )
            } else {
                ForEach(accounts) { account in
                    AccountRow(account: account) {
                        accountPendingRemoval = account
                    }

                    if account.id != accounts.last?.id {
                        Divider()
                    }
                }
            }
        }
        .padding(18)
        .clarityCard(radius: 20)
    }

    private var toolsCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "Tools", systemImage: "slider.horizontal.3")

            Button {
                Task { await store.syncAllConnections() }
            } label: {
                Label("Refresh accounts and transactions", systemImage: "arrow.triangle.2.circlepath")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(SecondaryClarityButtonStyle())
            .disabled(store.isSyncing || store.data.connections.isEmpty)

            Button {
                Task { await store.analyzeSpendingWithAI() }
            } label: {
                Label(store.isAnalyzingSpending ? "Scanning spending" : "Run AI spending scan", systemImage: "sparkles")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(SecondaryClarityButtonStyle())
            .disabled(store.isAnalyzingSpending || store.data.transactions.isEmpty)

            Button(role: .destructive) {
                store.clearLocalData()
            } label: {
                Label("Clear local data", systemImage: "trash")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(SecondaryClarityButtonStyle())
        }
        .padding(18)
        .clarityCard(radius: 20)
    }

    @ViewBuilder
    private var statusArea: some View {
        if let statusMessage = store.statusMessage {
            StatusBanner(message: statusMessage, isError: false)
        }

        if let lastErrorMessage = store.lastErrorMessage {
            StatusBanner(message: lastErrorMessage, isError: true)
        }

        #if DEBUG
        diagnosticsDisclosure
        #endif
    }

    private var diagnosticsDisclosure: some View {
        DisclosureGroup("Diagnostics", isExpanded: $showsDiagnostics) {
            PlaidDiagnosticsCard(
                logText: store.diagnosticsText,
                copy: {
                    copyDiagnostics(store.diagnosticsText)
                    store.recordDiagnostic("Diagnostics copied to clipboard.")
                },
                clear: store.clearDiagnostics
            )
            .padding(.top, 8)
        }
        .font(.subheadline.weight(.semibold))
        .foregroundStyle(ClarityColor.primaryText)
        .padding(16)
        .clarityCard(radius: 18)
    }

    private func copyDiagnostics(_ text: String) {
        #if os(iOS)
        UIPasteboard.general.string = text
        #elseif os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #endif
    }
}

private struct ScreenScroll<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                content
            }
            .padding(22)
            .frame(maxWidth: 780, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clarityTabContentPadding()
        .clarityBackground()
    }
}

private struct HeaderView<Trailing: View>: View {
    var title: String
    var subtitle: String
    @ViewBuilder var trailing: Trailing

    init(title: String, subtitle: String, @ViewBuilder trailing: () -> Trailing = { EmptyView() }) {
        self.title = title
        self.subtitle = subtitle
        self.trailing = trailing()
    }

    var body: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 36, weight: .bold))
                    .foregroundStyle(ClarityColor.primaryText)

                Text(subtitle)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(ClarityColor.secondaryText)
            }

            Spacer()
            trailing
        }
    }
}

struct SpendingStatCard: View {
    var title: String
    var amount: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(ClarityColor.secondaryText)

            Text(MoneyFormat.compact(amount))
                .font(.headline.weight(.bold))
                .foregroundStyle(ClarityColor.primaryText)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .padding(13)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(ClarityColor.panelElevated))
    }
}

private struct InsightRow: View {
    var symbolName: String
    var title: String
    var value: String
    var note: String?

    var body: some View {
        HStack(spacing: 12) {
            IconBadge(symbolName: symbolName)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(ClarityColor.secondaryText)

                Text(value)
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(ClarityColor.primaryText)
                    .lineLimit(2)

                if let note, !note.isEmpty {
                    Text(note)
                        .font(.caption)
                        .foregroundStyle(ClarityColor.mutedText)
                        .lineLimit(2)
                }
            }

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct TrendBadge: View {
    var title: String
    var caption: String
    var isIncrease: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: isIncrease ? "arrow.up.right" : "arrow.down.right")
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(isIncrease ? ClarityColor.red : ClarityColor.green)
                .frame(width: 30, height: 30)
                .background(Circle().fill(ClarityColor.panelElevated))

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.headline.weight(.bold))
                    .foregroundStyle(ClarityColor.primaryText)

                Text(caption)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(ClarityColor.secondaryText)
            }

            Spacer(minLength: 0)
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(ClarityColor.panelElevated))
    }
}

struct TrendInsightRow: View {
    var symbolName: String
    var title: String
    var value: String

    var body: some View {
        HStack(spacing: 12) {
            IconBadge(symbolName: symbolName)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(ClarityColor.secondaryText)

                Text(value)
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(ClarityColor.primaryText)
                    .lineLimit(3)
            }

            Spacer(minLength: 0)
        }
    }
}

private struct SimpleTransactionRow: View {
    var transaction: FinanceTransaction
    var classification: AIMerchantClassification?
    var account: FinancialAccount?

    var body: some View {
        HStack(spacing: 12) {
            IconBadge(symbolName: classification?.kind.symbolName ?? transaction.category.symbolName)

            VStack(alignment: .leading, spacing: 3) {
                Text(classification?.displayName ?? transaction.merchantName)
                    .font(.subheadline.weight(.bold))
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
                .foregroundStyle(transaction.isIncome ? ClarityColor.green : ClarityColor.primaryText)
                .lineLimit(1)
                .minimumScaleFactor(0.78)
        }
        .padding(.vertical, 10)
    }

    private var subtitle: String {
        let date = transaction.date.formatted(.dateTime.month(.abbreviated).day().year())
        let label = classification?.kind.title ?? transaction.category.title
        if let account {
            return "\(label) - \(account.name) - \(date)"
        }
        return "\(label) - \(date)"
    }
}

struct SpendingTrends {
    struct Comparison {
        var current: Double
        var previous: Double
        var delta: Double

        var isIncrease: Bool {
            delta >= 0
        }

        var title: String {
            if previous <= 0 {
                return current > 0 ? "New spending" : "No change"
            }

            let percent = abs(delta / previous * 100)
            let direction = isIncrease ? "up" : "down"
            return "\(direction.capitalized) \(percent.formatted(.number.precision(.fractionLength(0))))%"
        }

        var caption: String {
            if previous <= 0 {
                return current > 0 ? "No comparable history yet." : "Same as before."
            }

            let direction = isIncrease ? "more" : "less"
            return "\(MoneyFormat.currency(abs(delta))) \(direction) than the comparison period."
        }

        var summary: String {
            if previous <= 0 {
                return current > 0 ? "You have spending here, but no matching older period to compare yet." : "No spending in either period."
            }

            let direction = isIncrease ? "more" : "less"
            return "You spent \(MoneyFormat.currency(abs(delta))) \(direction) than the comparison period."
        }
    }

    struct MerchantRise {
        var name: String
        var delta: Double
    }

    struct DayTotal {
        var label: String
        var total: Double
    }

    var thisMonthTotal: Double
    var lastMonthTotal: Double
    var samePointLastMonthTotal: Double
    var lastSevenDaysTotal: Double
    var previousSevenDaysTotal: Double
    var lastSevenDailyTotals: [Double]
    var lastSevenLabels: [String]
    var topRisingMerchant: MerchantRise?
    var mostExpensiveRecentDay: DayTotal?

    var hasSpending: Bool {
        thisMonthTotal > 0 || lastMonthTotal > 0 || lastSevenDaysTotal > 0 || previousSevenDaysTotal > 0
    }

    var monthToDateComparison: Comparison {
        Comparison(current: thisMonthTotal, previous: samePointLastMonthTotal, delta: thisMonthTotal - samePointLastMonthTotal)
    }

    var sevenDayComparison: Comparison {
        Comparison(current: lastSevenDaysTotal, previous: previousSevenDaysTotal, delta: lastSevenDaysTotal - previousSevenDaysTotal)
    }

    init(transactions: [FinanceTransaction], now: Date = Date()) {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: now)
        let expenseTransactions = transactions.filter { !$0.isIncome }

        let currentMonth = calendar.dateInterval(of: .month, for: now)
        let lastMonthAnchor = calendar.date(byAdding: .month, value: -1, to: now) ?? now
        let lastMonth = calendar.dateInterval(of: .month, for: lastMonthAnchor)

        thisMonthTotal = Self.total(expenseTransactions, in: currentMonth)
        lastMonthTotal = Self.total(expenseTransactions, in: lastMonth)

        if let lastMonthStart = lastMonth?.start,
           let dayOffset = calendar.dateComponents([.day], from: currentMonth?.start ?? today, to: today).day,
           let samePointEnd = calendar.date(byAdding: .day, value: dayOffset + 1, to: lastMonthStart) {
            let cappedEnd = min(samePointEnd, lastMonth?.end ?? samePointEnd)
            samePointLastMonthTotal = Self.total(expenseTransactions, start: lastMonthStart, end: cappedEnd)
        } else {
            samePointLastMonthTotal = 0
        }

        let lastSevenStart = calendar.date(byAdding: .day, value: -6, to: today) ?? today
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: today) ?? now
        let previousSevenStart = calendar.date(byAdding: .day, value: -13, to: today) ?? today
        lastSevenDaysTotal = Self.total(expenseTransactions, start: lastSevenStart, end: tomorrow)
        previousSevenDaysTotal = Self.total(expenseTransactions, start: previousSevenStart, end: lastSevenStart)

        let lastSevenDates = (0..<7).compactMap { offset in
            calendar.date(byAdding: .day, value: offset - 6, to: today)
        }
        lastSevenDailyTotals = lastSevenDates.map { date in
            let next = calendar.date(byAdding: .day, value: 1, to: date) ?? date
            return Self.total(expenseTransactions, start: date, end: next)
        }
        lastSevenLabels = lastSevenDates.map {
            $0.formatted(.dateTime.weekday(.abbreviated))
        }

        topRisingMerchant = Self.topRisingMerchant(expenseTransactions, currentMonth: currentMonth, lastMonth: lastMonth)
        mostExpensiveRecentDay = Self.mostExpensiveDay(expenseTransactions, start: previousSevenStart, end: tomorrow)
    }

    private static func total(_ transactions: [FinanceTransaction], in interval: DateInterval?) -> Double {
        guard let interval else { return 0 }
        return total(transactions, start: interval.start, end: interval.end)
    }

    private static func total(_ transactions: [FinanceTransaction], start: Date, end: Date) -> Double {
        transactions
            .filter { $0.date >= start && $0.date < end }
            .reduce(0) { $0 + abs($1.amount) }
    }

    private static func topRisingMerchant(
        _ transactions: [FinanceTransaction],
        currentMonth: DateInterval?,
        lastMonth: DateInterval?
    ) -> MerchantRise? {
        guard let currentMonth, let lastMonth else { return nil }
        let current = groupedMerchantTotals(transactions, in: currentMonth)
        let previous = groupedMerchantTotals(transactions, in: lastMonth)

        return current.compactMap { key, total -> MerchantRise? in
            let delta = total - (previous[key] ?? 0)
            guard delta > 0 else { return nil }
            return MerchantRise(name: key, delta: delta)
        }
        .max { $0.delta < $1.delta }
    }

    private static func groupedMerchantTotals(_ transactions: [FinanceTransaction], in interval: DateInterval) -> [String: Double] {
        Dictionary(grouping: transactions.filter { interval.contains($0.date) }) { transaction in
            MerchantNameCleaner.canonicalDisplayName(for: transaction.merchantName)
        }
        .mapValues { transactions in
            transactions.reduce(0) { $0 + abs($1.amount) }
        }
    }

    private static func mostExpensiveDay(_ transactions: [FinanceTransaction], start: Date, end: Date) -> DayTotal? {
        let calendar = Calendar.current
        let grouped = Dictionary(grouping: transactions.filter { $0.date >= start && $0.date < end }) { transaction in
            calendar.startOfDay(for: transaction.date)
        }

        guard let top = grouped
            .map({ date, transactions in
                DayTotal(
                    label: date.formatted(.dateTime.weekday(.wide).month(.abbreviated).day()),
                    total: transactions.reduce(0) { $0 + abs($1.amount) }
                )
            })
            .max(by: { $0.total < $1.total }) else {
            return nil
        }

        return top.total > 0 ? top : nil
    }
}

#Preview {
    ContentView(store: FinanceStore())
}
