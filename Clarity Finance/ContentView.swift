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

            AccountsTab(store: store)
                .tabItem { Label("Accounts", systemImage: "wallet.pass.fill") }
                .tag(ClarityTab.accounts)

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
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                guard let url = urls.first else { return }
                store.importAppleCardStatement(from: url)
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
    case accounts
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
                classification: store.classification(for: transaction)
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
                classification: store.classification(for: transaction)
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
                        AccountRow(account: account)

                        if account.id != filteredAccounts.last?.id {
                            Divider()
                        }
                    }
                }
            }
            .padding(18)
            .clarityCard(radius: 20)
        }
    }
}

private struct SettingsTab: View {
    @Bindable var store: FinanceStore
    @Binding var plaidWebSession: PlaidWebSession?
    @Binding var isImportingStatement: Bool
    @Binding var showsDiagnostics: Bool

    var body: some View {
        ScreenScroll {
            HeaderView(title: "Settings", subtitle: "Connect, import, refresh.")

            addAccountCard
            toolsCard
            statusArea
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
                    Label("Apple Card PDF", systemImage: "doc.badge.plus")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(SecondaryClarityButtonStyle())
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

#Preview {
    ContentView(store: FinanceStore())
}
