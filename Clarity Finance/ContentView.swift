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
            total + (creditCardLiability(for: account.id)?.minimumPaymentAmount ?? 0)
        }
    }

    private var cardsWithLiabilityDetails: Int {
        creditAccounts.filter { creditCardLiability(for: $0.id) != nil }.count
    }

    private var cardsWithMinimumPayment: Int {
        creditAccounts.filter { creditCardLiability(for: $0.id)?.minimumPaymentAmount != nil }.count
    }

    private var nextDueDate: Date? {
        creditAccounts
            .compactMap { creditCardLiability(for: $0.id)?.nextPaymentDueDate }
            .min()
    }

    private var cardInsights: [CreditCardInsight] {
        creditAccounts.map { account in
            CreditCardInsight(account: account, liability: creditCardLiability(for: account.id))
        }
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

            if !cardInsights.isEmpty {
                CreditInterestCoachCard(insights: cardInsights)
                CreditPayoffOrderCard(insights: cardInsights)
                CreditMissingDetailsCard(insights: cardInsights)
            }

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
                                liability: creditCardLiability(for: account.id)
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

            Color.clear.frame(height: 56)
        }
        .refreshable {
            guard !store.data.connections.isEmpty else { return }
            await store.syncAllConnections()
        }
        .sheet(item: $selectedCard) { account in
            CreditCardDetailView(
                account: account,
                liability: creditCardLiability(for: account.id)
            )
        }
    }

    private var minimumDueCaption: String {
        if let nextDueDate {
            let days = Calendar.current.dateComponents(
                [.day],
                from: Calendar.current.startOfDay(for: Date()),
                to: Calendar.current.startOfDay(for: nextDueDate)
            ).day ?? 0

            if days < 0 {
                return "Overdue \(nextDueDate.formatted(.dateTime.month(.abbreviated).day()))"
            }

            if days == 0 {
                return "Due today"
            }

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
        let liability = creditCardLiability(for: account.id)

        if liability != nil { score += 100 }
        if liability?.minimumPaymentAmount != nil { score += 40 }
        if liability?.nextPaymentDueDate != nil { score += 30 }
        if account.creditLimit != nil { score += 10 }
        if account.availableBalance != nil { score += 5 }

        return score
    }

    private func creditCardLiability(for accountID: String) -> CreditCardLiability? {
        return store.creditCardLiability(for: accountID)
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

private struct CreditCardInsight: Identifiable {
    var account: FinancialAccount
    var liability: CreditCardLiability?

    var id: String { account.id }

    var balance: Double {
        max(0, account.currentBalance)
    }

    var minimumPayment: Double? {
        liability?.minimumPaymentAmount
    }

    var dueDate: Date? {
        liability?.nextPaymentDueDate
    }

    var statementBalance: Double? {
        liability?.lastStatementBalance
    }

    var apr: Double? {
        liability?.aprPercentage
    }

    var utilization: Double? {
        guard let limit = account.creditLimit, limit > 0 else { return nil }
        return balance / limit
    }

    var estimatedMonthlyInterest: Double? {
        guard let apr, apr > 0, balance > 0 else { return nil }
        return balance * (apr / 100) / 12
    }

    var hasPaymentGuidance: Bool {
        liability != nil
    }

    var needsPaymentDetails: Bool {
        liability == nil || (minimumPayment == nil && dueDate == nil)
    }

    var statementTarget: Double? {
        statementBalance ?? balance.nonZero
    }

    var daysUntilDue: Int? {
        guard let dueDate else { return nil }
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let due = calendar.startOfDay(for: dueDate)
        return calendar.dateComponents([.day], from: today, to: due).day
    }

    var priorityScore: Int {
        var score = Int(min(balance / 100, 120))

        if liability?.isOverdue == true {
            score += 900
        } else if let daysUntilDue {
            if daysUntilDue < 0 {
                score += 850
            } else if daysUntilDue == 0 {
                score += 700
            } else if daysUntilDue <= 3 {
                score += 560
            } else if daysUntilDue <= 7 {
                score += 420
            } else if daysUntilDue <= 14 {
                score += 160
            }
        }

        if let apr {
            if apr >= 25 {
                score += 220
            } else if apr >= 20 {
                score += 160
            } else if apr >= 15 {
                score += 80
            }
        }

        if let utilization {
            if utilization >= 0.80 {
                score += 180
            } else if utilization >= 0.50 {
                score += 120
            } else if utilization >= 0.30 {
                score += 60
            }
        }

        return score
    }

    var primaryBadge: CreditRiskBadge {
        if liability?.isOverdue == true || (daysUntilDue ?? 99) < 0 {
            return CreditRiskBadge(title: "Late", symbolName: "exclamationmark.triangle.fill", tint: ClarityColor.red)
        }

        if let daysUntilDue {
            if daysUntilDue == 0 {
                return CreditRiskBadge(title: "Due today", symbolName: "calendar.badge.exclamationmark", tint: ClarityColor.red)
            }

            if daysUntilDue <= 7 {
                return CreditRiskBadge(title: "Due soon", symbolName: "calendar", tint: ClarityColor.orange)
            }
        }

        if let apr, apr >= 20 {
            return CreditRiskBadge(title: "High APR", symbolName: "percent", tint: ClarityColor.red)
        }

        if let utilization, utilization >= 0.50 {
            return CreditRiskBadge(title: "High usage", symbolName: "gauge.with.dots.needle.67percent", tint: ClarityColor.orange)
        }

        if liability == nil {
            return CreditRiskBadge(title: "Info missing", symbolName: "questionmark.circle.fill", tint: ClarityColor.secondaryText)
        }

        return CreditRiskBadge(title: "Not overdue", symbolName: "checkmark.circle.fill", tint: ClarityColor.green)
    }

    var actionLine: String {
        if liability?.isOverdue == true || (daysUntilDue ?? 99) < 0 {
            if let minimumPayment, let statementTarget {
                return "Late. Pay \(MoneyFormat.currency(minimumPayment)) now to stop late damage. Pay \(MoneyFormat.currency(statementTarget)) to cut interest."
            }

            if let minimumPayment {
                return "Late. Pay \(MoneyFormat.currency(minimumPayment)) now so it does not get worse."
            }

            return "This card looks late. Pay this first so it does not get worse."
        }

        if let daysUntilDue {
            if daysUntilDue == 0 {
                if let minimumPayment, let statementTarget {
                    return "Due today. Pay \(MoneyFormat.currency(minimumPayment)) minimum, or \(MoneyFormat.currency(statementTarget)) to aim for no interest."
                }

                return "Due today. Minimum keeps it current; statement balance is the interest-free target."
            }

            if daysUntilDue <= 7 {
                if let statementTarget {
                    return "Due in \(daysUntilDue) day\(daysUntilDue == 1 ? "" : "s"). Try to pay \(MoneyFormat.currency(statementTarget)) before then."
                }

                return "Due in \(daysUntilDue) day\(daysUntilDue == 1 ? "" : "s"). Try to pay the statement balance before then."
            }
        }

        if let estimatedMonthlyInterest, estimatedMonthlyInterest >= 10 {
            return "If you carry this balance, interest could be about \(MoneyFormat.currency(estimatedMonthlyInterest)) per month."
        }

        if let utilization, utilization >= 0.50 {
            return "This card is using \(utilization.formatted(.percent.precision(.fractionLength(0)))) of its limit. That can hurt your credit score."
        }

        if liability == nil {
            return "Balance is here, but Plaid did not return due date or minimum payment details for this card."
        }

        return "Not overdue. Keep paying the statement balance by the due date."
    }

    var explanationLines: [CreditExplanationLine] {
        var lines: [CreditExplanationLine] = []

        if let minimumPayment {
            lines.append(
                CreditExplanationLine(
                    title: "Minimum = stay current",
                    message: "\(MoneyFormat.currency(minimumPayment)) is the smallest payment Plaid sees. It usually does not stop interest by itself.",
                    symbolName: "dollarsign.circle.fill"
                )
            )
        }

        if let statementBalance {
            let message: String

            if (daysUntilDue ?? 1) < 0 {
                message = "The due date passed. Paying \(MoneyFormat.currency(statementBalance)) still helps reduce interest."
            } else {
                message = "Pay \(MoneyFormat.currency(statementBalance)) by the due date if you want the best chance to avoid interest."
            }

            lines.append(
                CreditExplanationLine(
                    title: "Statement balance = interest-free target",
                    message: message,
                    symbolName: "target"
                )
            )
        }

        if let apr, let estimatedMonthlyInterest {
            lines.append(
                CreditExplanationLine(
                    title: "APR = price of borrowing",
                    message: "At \(apr.formatted(.number.precision(.fractionLength(2))))% APR, carrying this balance can cost about \(MoneyFormat.currency(estimatedMonthlyInterest)) per month.",
                    symbolName: "percent"
                )
            )
        }

        if let utilization {
            lines.append(
                CreditExplanationLine(
                    title: "Usage = \(utilizationTier.title.lowercased())",
                    message: "You are using \(utilization.formatted(.percent.precision(.fractionLength(0)))) of this card. \(utilizationTier.message)",
                    symbolName: "gauge.with.dots.needle.67percent"
                )
            )
        }

        if lines.isEmpty {
            lines.append(
                CreditExplanationLine(
                    title: "Only balance came through",
                    message: "Plaid did not return APR, due date, minimum payment, or statement balance for this card yet.",
                    symbolName: "info.circle.fill"
                )
            )
        }

        return lines
    }

    var payoffReason: String {
        if liability?.isOverdue == true || (daysUntilDue ?? 99) < 0 {
            return "late"
        }

        if let daysUntilDue {
            if daysUntilDue == 0 { return "due today" }
            if daysUntilDue <= 14 { return "due in \(daysUntilDue)d" }
        }

        if let estimatedMonthlyInterest, estimatedMonthlyInterest >= 1 {
            return "~\(MoneyFormat.currency(estimatedMonthlyInterest))/mo interest"
        }

        if let utilization {
            return "\(utilization.formatted(.percent.precision(.fractionLength(0)))) used"
        }

        return "highest balance"
    }

    var utilizationTier: CreditUtilizationTier {
        guard let utilization else { return .unknown }

        if utilization >= 0.80 { return .danger }
        if utilization >= 0.50 { return .high }
        if utilization >= 0.30 { return .watch }
        return .good
    }
}

private extension Double {
    var nonZero: Double? {
        self > 0 ? self : nil
    }
}

private struct CreditRiskBadge: Identifiable {
    var id: String { title }
    var title: String
    var symbolName: String
    var tint: Color
}

private struct CreditExplanationLine: Identifiable {
    var id: String { title }
    var title: String
    var message: String
    var symbolName: String
}

private enum CreditUtilizationTier {
    case good
    case watch
    case high
    case danger
    case unknown

    var title: String {
        switch self {
        case .good: "Healthy"
        case .watch: "Watch"
        case .high: "High"
        case .danger: "Danger zone"
        case .unknown: "Usage unknown"
        }
    }

    var message: String {
        switch self {
        case .good:
            return "That is a healthy credit-score zone."
        case .watch:
            return "This is okay, but lower is better for your score."
        case .high:
            return "This can start pressuring your credit score."
        case .danger:
            return "This is high enough to seriously pressure your credit score."
        case .unknown:
            return "Plaid did not return enough limit data to judge this card."
        }
    }

    var tint: Color {
        switch self {
        case .good: ClarityColor.green
        case .watch: ClarityColor.orange
        case .high: ClarityColor.orange
        case .danger: ClarityColor.red
        case .unknown: ClarityColor.secondaryText
        }
    }
}

private struct CreditInterestCoachCard: View {
    var insights: [CreditCardInsight]

    private var topInsight: CreditCardInsight? {
        insights
            .filter(\.hasPaymentGuidance)
            .max { $0.priorityScore < $1.priorityScore }
    }

    private var minimumTotal: Double {
        insights.reduce(0) { $0 + ($1.minimumPayment ?? 0) }
    }

    private var estimatedInterestTotal: Double {
        insights.reduce(0) { $0 + ($1.estimatedMonthlyInterest ?? 0) }
    }

    private var nextDueDate: Date? {
        insights.compactMap(\.dueDate).min()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SectionHeader(title: "Avoid interest", systemImage: "shield.lefthalf.filled")

            VStack(alignment: .leading, spacing: 8) {
                Text(headline)
                    .font(.title2.weight(.bold))
                    .foregroundStyle(ClarityColor.primaryText)
                    .fixedSize(horizontal: false, vertical: true)

                Text("Minimum payments keep cards current. The statement balance by the due date is the number that usually keeps interest away.")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(ClarityColor.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 10) {
                CreditCardQuickStat(
                    title: nextDueIsOverdue ? "Overdue" : "Next due",
                    value: nextDueText,
                    symbolName: "calendar"
                )
                CreditCardQuickStat(
                    title: "Minimums",
                    value: MoneyFormat.currency(minimumTotal),
                    symbolName: "dollarsign.circle.fill"
                )
                if estimatedInterestTotal > 0 {
                    CreditCardQuickStat(
                        title: "Interest",
                        value: "~\(MoneyFormat.currency(estimatedInterestTotal))/mo",
                        symbolName: "percent"
                    )
                }
            }
        }
        .padding(18)
        .clarityCard(radius: 20)
    }

    private var headline: String {
        guard let topInsight else { return "No cards to check yet." }

        if topInsight.liability?.isOverdue == true || (topInsight.daysUntilDue ?? 99) < 0 {
            return "Pay \(shortCardName(topInsight.account)) now. It is late."
        }

        if let daysUntilDue = topInsight.daysUntilDue, daysUntilDue <= 7 {
            return "Pay \(shortCardName(topInsight.account)) next. Due in \(daysUntilDue)d."
        }

        if topInsight.priorityScore >= 220 {
            return "Pay \(shortCardName(topInsight.account)) first. It is costing the most."
        }

        return "No obvious interest emergency right now."
    }

    private var nextDueText: String {
        guard let nextDueDate else { return "Missing" }
        if nextDueIsOverdue {
            let daysLate = abs(Calendar.current.dateComponents(
                [.day],
                from: Calendar.current.startOfDay(for: Date()),
                to: Calendar.current.startOfDay(for: nextDueDate)
            ).day ?? 0)

            return "\(daysLate)d late"
        }

        return nextDueDate.formatted(.dateTime.month(.abbreviated).day())
    }

    private var nextDueIsOverdue: Bool {
        guard let nextDueDate else { return false }
        let days = Calendar.current.dateComponents(
            [.day],
            from: Calendar.current.startOfDay(for: Date()),
            to: Calendar.current.startOfDay(for: nextDueDate)
        ).day ?? 0
        return days < 0
    }

    private func shortCardName(_ account: FinancialAccount) -> String {
        if let mask = account.mask, !mask.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "•••• \(mask)"
        }

        return account.name
    }
}

private struct CreditPayoffOrderCard: View {
    var insights: [CreditCardInsight]

    private var priorityInsights: [CreditCardInsight] {
        Array(insights.filter { $0.balance > 0 && $0.hasPaymentGuidance }.sorted { $0.priorityScore > $1.priorityScore }.prefix(3))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionHeader(title: "Pay first", systemImage: "list.number")

            if priorityInsights.isEmpty {
                Text("No card balances to rank right now.")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(ClarityColor.secondaryText)
            } else {
                ForEach(Array(priorityInsights.enumerated()), id: \.element.id) { index, insight in
                    HStack(spacing: 12) {
                        Text("\(index + 1)")
                            .font(.headline.weight(.bold))
                            .foregroundStyle(ClarityColor.primaryText)
                            .frame(width: 34, height: 34)
                            .background(Circle().fill(ClarityColor.panelElevated))

                        VStack(alignment: .leading, spacing: 3) {
                            Text(insight.account.name)
                                .font(.subheadline.weight(.bold))
                                .foregroundStyle(ClarityColor.primaryText)
                                .lineLimit(1)

                            Text(payoffSubtitle(for: insight))
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(ClarityColor.secondaryText)
                                .lineLimit(1)
                        }

                        Spacer()

                        Text(MoneyFormat.currency(insight.balance))
                            .font(.subheadline.weight(.bold))
                            .foregroundStyle(ClarityColor.primaryText)
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .padding(18)
        .clarityCard(radius: 20)
    }

    private func payoffSubtitle(for insight: CreditCardInsight) -> String {
        var parts: [String] = []

        if let mask = insight.account.mask?.trimmingCharacters(in: .whitespacesAndNewlines), !mask.isEmpty {
            parts.append("•••• \(mask)")
        }

        parts.append(insight.payoffReason)
        return parts.joined(separator: " • ")
    }
}

private struct CreditMissingDetailsCard: View {
    var insights: [CreditCardInsight]

    private var missingInsights: [CreditCardInsight] {
        insights.filter(\.needsPaymentDetails)
    }

    var body: some View {
        if !missingInsights.isEmpty {
            VStack(alignment: .leading, spacing: 14) {
                SectionHeader(title: "Needs info", systemImage: "questionmark.circle.fill")

                Text("These cards have balances, but Plaid did not return enough payment details. Do not rank them as pay-first until minimums and due dates come through.")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(ClarityColor.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)

                ForEach(missingInsights) { insight in
                    HStack(spacing: 12) {
                        IconBadge(symbolName: "creditcard.fill", tint: ClarityColor.secondaryText)

                        VStack(alignment: .leading, spacing: 3) {
                            Text(insight.account.name)
                                .font(.subheadline.weight(.bold))
                                .foregroundStyle(ClarityColor.primaryText)
                                .lineLimit(1)

                            Text(missingSubtitle(for: insight.account))
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(ClarityColor.secondaryText)
                                .lineLimit(1)
                        }

                        Spacer()

                        Text(MoneyFormat.currency(insight.balance))
                            .font(.subheadline.weight(.bold))
                            .foregroundStyle(ClarityColor.primaryText)
                    }
                }
            }
            .padding(18)
            .clarityCard(radius: 20)
        }
    }

    private func missingSubtitle(for account: FinancialAccount) -> String {
        var parts = [account.institutionName]

        if let mask = account.mask?.trimmingCharacters(in: .whitespacesAndNewlines), !mask.isEmpty {
            parts.append("•••• \(mask)")
        }

        parts.append("missing due date")
        return parts.joined(separator: " • ")
    }
}

private struct CreditCardLiabilityRow: View {
    var account: FinancialAccount
    var liability: CreditCardLiability?

    private var insight: CreditCardInsight {
        CreditCardInsight(account: account, liability: liability)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                IconBadge(symbolName: "creditcard.fill", tint: insight.primaryBadge.tint)

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

            CreditRiskBadgeView(badge: insight.primaryBadge)

            if hasPrimaryPaymentDetails {
                HStack(spacing: 10) {
                    if let minimumPaymentAmount = liability?.minimumPaymentAmount {
                        CreditCardQuickStat(
                            title: "Minimum",
                            value: MoneyFormat.currency(minimumPaymentAmount),
                            symbolName: "dollarsign.circle.fill"
                        )
                    }

                    if let nextPaymentDueDate = liability?.nextPaymentDueDate {
                        CreditCardQuickStat(
                            title: insight.daysUntilDue.map { $0 < 0 ? "Late" : "Due" } ?? "Due",
                            value: nextPaymentDueDate.formatted(.dateTime.month(.abbreviated).day()),
                            symbolName: "calendar"
                        )
                    }

                    if let estimatedMonthlyInterest = insight.estimatedMonthlyInterest, estimatedMonthlyInterest >= 1 {
                        CreditCardQuickStat(
                            title: "Interest/mo",
                            value: "~\(MoneyFormat.currency(estimatedMonthlyInterest))",
                            symbolName: "percent"
                        )
                    }
                }
            }

            if let utilization = insight.utilization {
                CreditUtilizationBar(utilization: utilization, tier: insight.utilizationTier)
            }

            Text(insight.actionLine)
                .font(.caption.weight(.semibold))
                .foregroundStyle(ClarityColor.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 12)
    }

    private var rowSubtitle: String {
        var parts = [account.institutionName]
        if let cardIdentifier {
            parts.append(cardIdentifier)
        }
        return parts.joined(separator: " • ")
    }

    private var cardIdentifier: String? {
        guard let mask = account.mask?.trimmingCharacters(in: .whitespacesAndNewlines), !mask.isEmpty else {
            return nil
        }
        return "•••• \(mask)"
    }

    private var hasPrimaryPaymentDetails: Bool {
        liability?.minimumPaymentAmount != nil || liability?.nextPaymentDueDate != nil || insight.estimatedMonthlyInterest != nil
    }
}

private struct CreditRiskBadgeView: View {
    var badge: CreditRiskBadge

    var body: some View {
        Label(badge.title, systemImage: badge.symbolName)
            .font(.caption.weight(.bold))
            .foregroundStyle(badge.tint)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                Capsule(style: .continuous)
                    .fill(badge.tint.opacity(0.12))
            )
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct CreditCardQuickStat: View {
    var title: String
    var value: String
    var symbolName: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: symbolName)
                .font(.caption.weight(.bold))
                .foregroundStyle(ClarityColor.secondaryText)
                .frame(width: 14)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(ClarityColor.mutedText)
                    .textCase(.uppercase)
                    .lineLimit(1)
                    .minimumScaleFactor(0.55)
                    .allowsTightening(true)

                Text(value)
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(ClarityColor.primaryText)
                    .lineLimit(1)
                    .minimumScaleFactor(0.68)
                    .allowsTightening(true)
            }
            .layoutPriority(1)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(ClarityColor.panelElevated)
        )
    }
}

private struct CreditUtilizationBar: View {
    var utilization: Double
    var tier: CreditUtilizationTier

    private var clampedUtilization: Double {
        min(max(utilization, 0), 1)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text(tier.title)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(ClarityColor.primaryText)

                Spacer()

                Text(utilization.formatted(.percent.precision(.fractionLength(0))))
                    .font(.caption.weight(.bold))
                    .foregroundStyle(tier.tint)
            }

            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(ClarityColor.panelElevated)

                    Capsule()
                        .fill(tier.tint)
                        .frame(width: max(8, proxy.size.width * clampedUtilization))
                }
            }
            .frame(height: 8)
        }
        .padding(.top, 2)
    }
}

private struct CreditCardMeaningCard: View {
    var insight: CreditCardInsight

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SectionHeader(title: "What this means", systemImage: "sparkles")

            Text(insight.actionLine)
                .font(.headline.weight(.bold))
                .foregroundStyle(ClarityColor.primaryText)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 14) {
                ForEach(insight.explanationLines) { line in
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: line.symbolName)
                            .font(.headline.weight(.bold))
                            .foregroundStyle(ClarityColor.primaryText)
                            .frame(width: 30, height: 30)
                            .background(
                                RoundedRectangle(cornerRadius: 9, style: .continuous)
                                    .fill(ClarityColor.panelElevated)
                            )

                        VStack(alignment: .leading, spacing: 3) {
                            Text(line.title)
                                .font(.subheadline.weight(.bold))
                                .foregroundStyle(ClarityColor.primaryText)

                            Text(line.message)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(ClarityColor.secondaryText)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .clarityCard(radius: 20)
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

                            if !headerSubtitle.isEmpty {
                                Text(headerSubtitle)
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(ClarityColor.secondaryText)
                            }
                        }

                        VStack(alignment: .leading, spacing: 4) {
                            Text(detailHeroLabel)
                                .font(.caption.weight(.bold))
                                .foregroundStyle(ClarityColor.secondaryText)
                                .textCase(.uppercase)

                            Text(detailHeroAmount)
                                .font(.system(size: 44, weight: .bold))
                                .foregroundStyle(ClarityColor.primaryText)
                                .lineLimit(1)
                                .minimumScaleFactor(0.65)

                            Text(detailHeroCaption)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(ClarityColor.secondaryText)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(18)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .clarityCard(radius: 20)

                    CreditCardMeaningCard(insight: insight)

                    if let utilization = insight.utilization {
                        VStack(alignment: .leading, spacing: 12) {
                            SectionHeader(title: "Credit usage", systemImage: "gauge.with.dots.needle.67percent")
                            CreditUtilizationBar(utilization: utilization, tier: insight.utilizationTier)
                            Text(insight.utilizationTier.message)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(ClarityColor.secondaryText)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(18)
                        .clarityCard(radius: 20)
                    }

                    CreditDetailList(rows: accountDetailRows)

                    if !paymentDetailRows.isEmpty {
                        CreditDetailList(rows: paymentDetailRows)
                    } else if liability == nil {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Payment details unavailable")
                                .font(.headline.weight(.bold))
                                .foregroundStyle(ClarityColor.primaryText)

                            Text("Plaid returned the card balance, but not payment details for this card yet. Try Refresh card details, or reconnect the bank and make sure credit card permissions are selected.")
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

    private var headerSubtitle: String {
        [account.institutionName, cardIdentifier ?? ""]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " • ")
    }

    private var cardIdentifier: String? {
        guard let mask = account.mask?.trimmingCharacters(in: .whitespacesAndNewlines), !mask.isEmpty else {
            return nil
        }
        return "•••• \(mask)"
    }

    private var insight: CreditCardInsight {
        CreditCardInsight(account: account, liability: liability)
    }

    private var detailHeroLabel: String {
        if liability?.isOverdue == true || (insight.daysUntilDue ?? 99) < 0 {
            return "Pay now"
        }

        if insight.daysUntilDue != nil {
            return "Pay target"
        }

        return "Balance"
    }

    private var detailHeroAmount: String {
        if liability?.isOverdue == true || (insight.daysUntilDue ?? 99) < 0 {
            if let minimumPayment = liability?.minimumPaymentAmount {
                return MoneyFormat.currency(minimumPayment)
            }
        }

        if let statementBalance = liability?.lastStatementBalance {
            return MoneyFormat.currency(statementBalance)
        }

        if let minimumPayment = liability?.minimumPaymentAmount {
            return MoneyFormat.currency(minimumPayment)
        }

        return MoneyFormat.currency(account.currentBalance)
    }

    private var detailHeroCaption: String {
        if liability?.isOverdue == true || (insight.daysUntilDue ?? 99) < 0 {
            if let dueDate = liability?.nextPaymentDueDate {
                return "This card is overdue from \(dateText(dueDate)). Balance: \(MoneyFormat.currency(account.currentBalance))."
            }

            return "This card looks overdue. Balance: \(MoneyFormat.currency(account.currentBalance))."
        }

        if let dueDate = liability?.nextPaymentDueDate {
            if let statementBalance = liability?.lastStatementBalance {
                return "Pay \(MoneyFormat.currency(statementBalance)) by \(dateText(dueDate)) to aim for no interest."
            }

            if let minimumPayment = liability?.minimumPaymentAmount {
                return "Pay at least \(MoneyFormat.currency(minimumPayment)) by \(dateText(dueDate)) to stay current."
            }
        }

        if liability == nil {
            return "Plaid did not return minimum payment or due date for this card."
        }

        return "Current balance. Payment target is unavailable."
    }

    private var accountDetailRows: [(title: String, value: String)] {
        var rows: [(title: String, value: String)] = [
            ("Institution", account.institutionName),
            ("Card name", account.name),
            ("Balance", MoneyFormat.currency(account.currentBalance))
        ]

        if let mask = account.mask?.trimmingCharacters(in: .whitespacesAndNewlines), !mask.isEmpty {
            rows.append(("Last 4", mask))
        }

        if let availableBalance = account.availableBalance {
            rows.append(("Available credit", MoneyFormat.currency(availableBalance)))
        }

        if let creditLimit = account.creditLimit {
            rows.append(("Credit limit", MoneyFormat.currency(creditLimit)))
        }

        if let utilizationText {
            rows.append(("Utilization", utilizationText))
        }

        rows.append(("Source", account.isManual ? "PDF import" : "Plaid"))
        return rows
    }

    private var paymentDetailRows: [(title: String, value: String)] {
        guard let liability else { return [] }
        var rows: [(title: String, value: String)] = []

        if let minimumPaymentAmount = liability.minimumPaymentAmount {
            rows.append(("Minimum payment", MoneyFormat.currency(minimumPaymentAmount)))
        }

        if let nextPaymentDueDate = liability.nextPaymentDueDate {
            rows.append(("Due date", dateText(nextPaymentDueDate)))
        }

        if let lastPaymentAmount = liability.lastPaymentAmount {
            rows.append(("Last payment", MoneyFormat.currency(lastPaymentAmount)))
        }

        if let lastPaymentDate = liability.lastPaymentDate {
            rows.append(("Last paid", dateText(lastPaymentDate)))
        }

        if let lastStatementBalance = liability.lastStatementBalance {
            rows.append(("Last statement", MoneyFormat.currency(lastStatementBalance)))
        }

        if let lastStatementIssueDate = liability.lastStatementIssueDate {
            rows.append(("Statement date", dateText(lastStatementIssueDate)))
        }

        if let aprPercentage = liability.aprPercentage {
            rows.append(("APR", "\(aprPercentage.formatted(.number.precision(.fractionLength(2))))%"))
        }

        if let isOverdue = liability.isOverdue {
            rows.append(("Status", isOverdue ? "Overdue" : "Not overdue"))
        }

        if let updatedAt = liability.updatedAt {
            rows.append(("Updated", dateTimeText(updatedAt)))
        }

        return rows
    }

    private var utilizationText: String? {
        guard let limit = account.creditLimit, limit > 0 else { return nil }
        let utilization = max(0, account.currentBalance) / limit
        return utilization.formatted(.percent.precision(.fractionLength(1)))
    }

    private func dateText(_ date: Date) -> String {
        return date.formatted(.dateTime.month(.abbreviated).day().year())
    }

    private func dateTimeText(_ date: Date) -> String {
        return date.formatted(.dateTime.month(.abbreviated).day().year().hour().minute())
    }
}

private struct CreditDetailList: View {
    var rows: [(title: String, value: String)]

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                CreditDetailLine(title: row.title, value: row.value)

                if index < rows.count - 1 {
                    Divider()
                        .overlay(ClarityColor.stroke)
                        .padding(.vertical, 10)
                }
            }
        }
        .padding(18)
        .clarityCard(radius: 20)
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
            appleCardAccessCard
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

    private var appleCardAccessCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "Apple Card", systemImage: "apple.logo")

            Text("Connect Apple Card directly from Wallet using Apple FinanceKit. This is separate from Plaid and can import balances, transactions, due dates, and minimum payments when Apple allows access.")
                .font(.subheadline)
                .foregroundStyle(ClarityColor.secondaryText)

            #if os(iOS)
            Button {
                Task { await store.importAppleCardFromWallet() }
            } label: {
                Label("Connect Apple Card", systemImage: "wallet.pass.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(SecondaryClarityButtonStyle())
            .disabled(store.isSyncing)

            Text("Requires iOS 17.4+, Wallet data availability, user permission, and Apple approval for the FinanceKit entitlement.")
                .font(.caption.weight(.semibold))
                .foregroundStyle(ClarityColor.secondaryText)
            #else
            Text("Direct Apple Card access is only available in the iPhone app. On Mac, import Apple Card PDFs instead.")
                .font(.caption.weight(.semibold))
                .foregroundStyle(ClarityColor.secondaryText)
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
