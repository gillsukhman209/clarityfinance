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
    @State private var selectedTab: ClarityTab = .today
    @State private var plaidWebSession: PlaidWebSession?
    @State private var isImportingStatement = false
    @State private var showsDiagnostics = false

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

            TrendsTab(store: store)
                .tabItem { Label("Trends", systemImage: "chart.line.uptrend.xyaxis") }
                .tag(ClarityTab.trends)

            SettingsTab(
                store: store,
                plaidWebSession: $plaidWebSession,
                isImportingStatement: $isImportingStatement,
                showsDiagnostics: $showsDiagnostics
            )
            .tabItem { Label("Settings", systemImage: "gearshape.fill") }
            .tag(ClarityTab.settings)
        }
        .clarityBackground()
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
    case trends
    case settings
}

private struct TodayTab: View {
    @Bindable var store: FinanceStore
    @State private var selectedTransaction: FinanceTransaction?

    var body: some View {
        ScreenScroll {
            HeaderView(title: "Clarity", subtitle: store.accountFilterCaption) {
                if !store.data.accounts.isEmpty {
                    AccountFilterBar(accounts: store.data.accounts, selectedAccountIDs: $store.selectedAccountIDs)
                }
            }

            spendingCard
            quickReadCard
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

    private var spendingCard: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Total spent")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(ClarityColor.secondaryText)

                Text(MoneyFormat.currency(store.spendingThisMonth))
                    .font(.system(size: 42, weight: .bold))
                    .foregroundStyle(ClarityColor.primaryText)
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)

                Text("This month")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(ClarityColor.mutedText)
            }

            HStack(spacing: 10) {
                SpendingStatCard(title: "Today", amount: store.spendingToday)
                SpendingStatCard(title: "7 days", amount: store.spendingThisWeek)
                SpendingStatCard(title: "Month", amount: store.spendingThisMonth)
            }

            Text(store.data.connections.isEmpty ? "Connect a bank in Settings." : "Pull down to refresh.")
                .font(.caption.weight(.semibold))
                .foregroundStyle(ClarityColor.secondaryText)
        }
        .padding(18)
        .clarityCard(radius: 20)
    }

    private var quickReadCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionHeader(title: "Quick read", systemImage: "sparkles")

            VStack(spacing: 10) {
                if let topMerchant = store.topMerchantThisMonth {
                    InsightRow(
                        symbolName: "crown.fill",
                        title: "Top merchant",
                        value: "\(topMerchant.merchantName) - \(MoneyFormat.currency(topMerchant.total))",
                        note: topMerchant.classification?.plainEnglish
                    )
                } else {
                    InsightRow(
                        symbolName: "tray.fill",
                        title: "No spending yet",
                        value: "Connect accounts from Settings.",
                        note: nil
                    )
                }

                if let biggest = store.biggestSpendThisMonth {
                    InsightRow(
                        symbolName: "bolt.fill",
                        title: "Biggest swipe",
                        value: "\(biggest.merchantName) - \(MoneyFormat.currency(abs(biggest.amount)))",
                        note: store.classification(for: biggest)?.kind.title
                    )
                }

                InsightRow(
                    symbolName: "brain.head.profile",
                    title: "AI scan",
                    value: store.aiSummaryText,
                    note: nil
                )
            }
        }
        .padding(18)
        .clarityCard(radius: 20)
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
    @State private var accountPendingRemoval: FinancialAccount?

    var body: some View {
        ScreenScroll {
            HeaderView(title: "Settings", subtitle: "Connect, import, refresh.")

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

private struct SpendingStatCard: View {
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

private struct TrendBadge: View {
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

private struct TrendInsightRow: View {
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

private struct SpendingTrends {
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
