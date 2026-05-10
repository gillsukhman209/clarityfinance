import Foundation
import Observation

@MainActor
@Observable
final class FinanceStore {
    var data: FinanceDataSet
    var credentials: PlaidCredentials
    var isSyncing = false
    var statusMessage: String?
    var lastErrorMessage: String?
    var hostedLinkSession: PlaidHostedLinkSession?
    var diagnosticLog: [String] = []
    var selectedAccountIDs: Set<String> = []
    var recurringDiagnostics: [String] = []

    private let plaidClient = PlaidSandboxClient()
    private let fileURL: URL

    init() {
        fileURL = Self.makeStoreURL()

        if let savedData = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder.store.decode(FinanceDataSet.self, from: savedData) {
            data = decoded
        } else {
            data = .empty
        }

        credentials = PlaidCredentials(
            clientID: (try? KeychainStore.read(account: "plaid-client-id")) ?? PlaidCredentials.bundledSandbox.clientID,
            sandboxSecret: (try? KeychainStore.read(account: "plaid-sandbox-secret")) ?? PlaidCredentials.bundledSandbox.sandboxSecret,
            productionSecret: (try? KeychainStore.read(account: "plaid-production-secret")) ?? PlaidCredentials.bundledSandbox.productionSecret,
            linkCustomizationName: (try? KeychainStore.read(account: "plaid-link-customization-name")) ?? PlaidCredentials.bundledSandbox.linkCustomizationName
        )

        removeLegacySampleDataIfNeeded()
        resetToConnectionOnlyData()
        save()
        recordDiagnostic("FinanceStore initialized. Diagnostics build active.")
    }

    var totalBalance: Double {
        filteredAccounts.reduce(0) { total, account in
            if account.kind.isLiability {
                total - account.currentBalance
            } else {
                total + account.currentBalance
            }
        }
    }

    var assetsTotal: Double {
        filteredAccounts.filter { !$0.kind.isLiability }.reduce(0) { $0 + $1.currentBalance }
    }

    var liabilitiesTotal: Double {
        filteredAccounts.filter(\.kind.isLiability).reduce(0) { $0 + $1.currentBalance }
    }

    var recentTransactions: [FinanceTransaction] {
        filteredTransactions.sorted { $0.date > $1.date }
    }

    var monthlySpend: Double {
        expenseTotal(inMonthOf: reportingMonthAnchor)
    }

    var hasFinancialData: Bool {
        !filteredAccounts.isEmpty || !filteredTransactions.isEmpty || !data.connections.isEmpty
    }

    var incomeThisMonth: Double {
        incomeTotal(inMonthOf: reportingMonthAnchor)
    }

    var monthlyChartValues: [Double] {
        let calendar = Calendar.current
        let anchor = reportingMonthAnchor
        let currentMonthTransactions = filteredTransactions.filter {
            !$0.isIncome && calendar.isDate($0.date, equalTo: anchor, toGranularity: .month)
        }

        return stride(from: 0, through: 5, by: 1).map { index in
            let upperDay = max(1, Int(Double(index + 1) * 31.0 / 6.0))
            return currentMonthTransactions
                .filter { calendar.component(.day, from: $0.date) <= upperDay }
                .reduce(0) { $0 + abs($1.amount) }
        }
    }

    var reportingMonthAnchor: Date {
        let calendar = Calendar.current
        let now = Date()
        let hasCurrentMonthSpending = filteredTransactions.contains {
            !$0.isIncome && calendar.isDate($0.date, equalTo: now, toGranularity: .month)
        }

        if hasCurrentMonthSpending {
            return now
        }

        return filteredTransactions
            .filter { !$0.isIncome }
            .map(\.date)
            .max() ?? now
    }

    var reportingMonthTitle: String {
        reportingMonthAnchor.formatted(.dateTime.month(.wide).year())
    }

    var diagnosticsText: String {
        diagnosticLog.joined(separator: "\n")
    }

    var selectedAccount: FinancialAccount? {
        guard selectedAccountIDs.count == 1, let selectedAccountID = selectedAccountIDs.first else { return nil }
        return data.accounts.first { $0.id == selectedAccountID }
    }

    var isAccountFilterActive: Bool {
        !selectedAccountIDs.isEmpty
    }

    var filteredAccounts: [FinancialAccount] {
        guard !selectedAccountIDs.isEmpty else { return data.accounts }
        return data.accounts.filter { selectedAccountIDs.contains($0.id) }
    }

    var filteredTransactions: [FinanceTransaction] {
        guard !selectedAccountIDs.isEmpty else { return data.transactions }
        return data.transactions.filter { selectedAccountIDs.contains($0.accountID) }
    }

    var filteredSubscriptions: [SubscriptionItem] {
        let activeSubscriptions = correctedRecurringCharges.filter {
            let key = FinanceCoachEngine.subscriptionKey($0)
            return $0.recurringKind == .subscription &&
                data.recurringChargeCorrections[key] != .ignored &&
                !data.ignoredSubscriptionKeys.contains(key)
        }
        guard !selectedAccountIDs.isEmpty else { return activeSubscriptions }
        return activeSubscriptions.filter { subscription in
            guard let accountID = subscription.accountID else { return false }
            return selectedAccountIDs.contains(accountID)
        }
    }

    var filteredRecurringBills: [SubscriptionItem] {
        let activeBills = correctedRecurringCharges.filter {
            let key = FinanceCoachEngine.subscriptionKey($0)
            return $0.recurringKind == .bill &&
                data.recurringChargeCorrections[key] != .ignored &&
                !data.ignoredSubscriptionKeys.contains(key)
        }
        guard !selectedAccountIDs.isEmpty else { return activeBills }
        return activeBills.filter { bill in
            guard let accountID = bill.accountID else { return false }
            return selectedAccountIDs.contains(accountID)
        }
    }

    var correctedRecurringCharges: [SubscriptionItem] {
        data.subscriptions.map { subscription in
            var corrected = subscription
            switch data.recurringChargeCorrections[FinanceCoachEngine.subscriptionKey(subscription)] {
            case .subscription:
                corrected.recurringKind = .subscription
            case .bill:
                corrected.recurringKind = .bill
            case .ignored, .none:
                break
            }
            return corrected
        }
    }

    var moneyInsights: [MoneyInsight] {
        FinanceCoachEngine.insights(
            transactions: filteredTransactions,
            subscriptions: filteredSubscriptions,
            accounts: filteredAccounts,
            anchor: reportingMonthAnchor
        )
    }

    var moneyWrapped: MoneyWrapped {
        FinanceCoachEngine.wrapped(
            transactions: filteredTransactions,
            subscriptions: filteredSubscriptions,
            anchor: reportingMonthAnchor
        )
    }

    var spendingPersonality: SpendingPersonality {
        FinanceCoachEngine.personality(
            for: filteredTransactions,
            subscriptions: filteredSubscriptions,
            anchor: reportingMonthAnchor
        )
    }

    var subscriptionIntelligence: [SubscriptionIntelligence] {
        let subscriptions = correctedRecurringCharges.filter { subscription in
            guard !selectedAccountIDs.isEmpty else { return true }
            guard let accountID = subscription.accountID else { return false }
            return selectedAccountIDs.contains(accountID)
        }

        return FinanceCoachEngine.subscriptionIntelligence(
            subscriptions: subscriptions,
            transactions: filteredTransactions,
            accounts: data.accounts,
            corrections: data.recurringChargeCorrections
        )
    }

    var filteredBudgets: [BudgetCategory] {
        budgets(for: filteredTransactions)
    }

    var accountFilterCaption: String {
        if let selectedAccount {
            return selectedAccount.displayName
        }

        if selectedAccountIDs.isEmpty {
            return "All accounts"
        }

        return "\(selectedAccountIDs.count) accounts"
    }

    func account(for accountID: String) -> FinancialAccount? {
        data.accounts.first { $0.id == accountID }
    }

    func expenseTotal(inMonthOf anchor: Date) -> Double {
        let calendar = Calendar.current
        return filteredTransactions
            .filter { !$0.isIncome && calendar.isDate($0.date, equalTo: anchor, toGranularity: .month) }
            .reduce(0) { $0 + abs($1.amount) }
    }

    func incomeTotal(inMonthOf anchor: Date) -> Double {
        let calendar = Calendar.current
        return filteredTransactions
            .filter { $0.isIncome && calendar.isDate($0.date, equalTo: anchor, toGranularity: .month) }
            .reduce(0) { $0 + abs($1.amount) }
    }

    func recordDiagnostic(_ message: String) {
        let timestamp = Date().formatted(.dateTime.hour().minute().second())
        let line = "[\(timestamp)] \(message)"
        diagnosticLog.append(line)
        if diagnosticLog.count > 300 {
            diagnosticLog.removeFirst(diagnosticLog.count - 300)
        }
        print("[Clarity Diagnostics] \(line)")
    }

    func clearDiagnostics() {
        diagnosticLog.removeAll()
        recordDiagnostic("Diagnostics cleared.")
    }

    func saveCredentials(clientID: String, sandboxSecret: String, productionSecret: String, linkCustomizationName: String) {
        recordDiagnostic("Saving Plaid credentials. clientID set=\(!clientID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty), sandbox secret set=\(!sandboxSecret.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty), production secret set=\(!productionSecret.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty), link customization set=\(!linkCustomizationName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty).")

        credentials = PlaidCredentials(
            clientID: clientID,
            sandboxSecret: sandboxSecret,
            productionSecret: productionSecret,
            linkCustomizationName: linkCustomizationName
        )

        do {
            try KeychainStore.save(clientID, account: "plaid-client-id")
            try KeychainStore.save(sandboxSecret, account: "plaid-sandbox-secret")
            try KeychainStore.save(productionSecret, account: "plaid-production-secret")
            try KeychainStore.save(linkCustomizationName, account: "plaid-link-customization-name")
            statusMessage = "Plaid credentials saved."
            lastErrorMessage = nil
            recordDiagnostic("Plaid credentials saved to Keychain.")
        } catch {
            lastErrorMessage = error.localizedDescription
            recordDiagnostic("Failed to save Plaid credentials: \(error.localizedDescription)")
        }
    }

    func connectSandboxInstitution(
        institutionID: String = "ins_109508",
        institutionName: String = "First Platypus Bank",
        profile: PlaidSandboxProfile = .transactionsDynamic
    ) async {
        guard credentials.isSandboxComplete else {
            lastErrorMessage = "Add your Plaid client ID and Sandbox secret in Settings first."
            return
        }

        let institution = PlaidSandboxInstitution(
            id: institutionID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? PlaidSandboxInstitution.firstPlatypus.id : institutionID.trimmingCharacters(in: .whitespacesAndNewlines),
            name: institutionName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? PlaidSandboxInstitution.firstPlatypus.name : institutionName.trimmingCharacters(in: .whitespacesAndNewlines)
        )

        isSyncing = true
        statusMessage = "Connecting \(institution.name)..."
        lastErrorMessage = nil

        do {
            var connection = try await plaidClient.createSandboxConnection(
                credentials: credentials,
                institution: institution,
                profile: profile
            )
            let accounts = try await plaidClient.fetchAccounts(credentials: credentials, connection: connection, environment: .sandbox)
            connection.lastSyncedAt = Date()

            data.connections.append(connection)
            upsert(accounts: accounts)
            save()
            statusMessage = "Connected \(connection.institutionName) with \(accounts.count) accounts."
        } catch {
            lastErrorMessage = error.localizedDescription
        }

        isSyncing = false
    }

    func syncAllConnections() async {
        guard credentials.isSandboxComplete || credentials.isProductionComplete else {
            lastErrorMessage = "Add your Plaid credentials in Settings first."
            return
        }

        guard !data.connections.isEmpty else {
            await connectSandboxInstitution()
            return
        }

        isSyncing = true
        statusMessage = "Refreshing Plaid accounts..."
        lastErrorMessage = nil

        do {
            for index in data.connections.indices {
                var connection = data.connections[index]
                let environment = environment(for: connection)
                let accounts = try await plaidClient.fetchAccounts(credentials: credentials, connection: connection, environment: environment)
                connection.lastSyncedAt = Date()
                data.connections[index] = connection
                upsert(accounts: accounts)
                recordDiagnostic("Refreshed \(accounts.count) account(s) for \(connection.institutionName).")
            }

            save()
            statusMessage = "Plaid accounts are up to date."
        } catch {
            lastErrorMessage = error.localizedDescription
        }

        isSyncing = false
    }

    func refreshRecurringCharges() async {
        guard !data.connections.isEmpty else {
            lastErrorMessage = "Connect a Plaid account before refreshing recurring charges."
            return
        }

        isSyncing = true
        statusMessage = "Refreshing Plaid recurring charges..."
        lastErrorMessage = nil

        let plaidSubscriptions = await fetchPlaidRecurringSubscriptionsForAllConnections()
        rebuildDerivedData(plaidSubscriptions: plaidSubscriptions)
        save()

        if let plaidSubscriptions {
            statusMessage = "Plaid recurring refresh complete: \(plaidSubscriptions.count) stream(s)."
        } else {
            statusMessage = "Plaid recurring refresh failed. Existing recurring data was kept."
        }

        isSyncing = false
    }

    func connectRealBank() async {
        recordDiagnostic("connectRealBank() entered. isSyncing=\(isSyncing), production credentials complete=\(credentials.isProductionComplete).")

        guard credentials.isProductionComplete else {
            lastErrorMessage = "Add your Plaid client ID and Production secret in Settings first."
            recordDiagnostic("connectRealBank() stopped: missing production credentials.")
            return
        }

        isSyncing = true
        statusMessage = "Creating an in-app Plaid bank link..."
        lastErrorMessage = nil
        hostedLinkSession = nil
        recordDiagnostic("Calling Plaid /link/token/create in Production. linkCustomization=\(credentials.normalizedLinkCustomizationName ?? "default"), daysRequested=\(PlaidSandboxClient.requestedTransactionHistoryDays).")

        do {
            let hostedSession = try await plaidClient.createHostedLinkSession(
                credentials: credentials,
                environment: .production
            )

            hostedLinkSession = hostedSession
            statusMessage = "Plaid link is ready. Finish bank login inside Clarity, then import accounts."
            recordDiagnostic("Plaid Hosted Link created. urlHost=\(hostedSession.hostedLinkURL.host ?? "unknown"), linkTokenLength=\(hostedSession.linkToken.count).")
        } catch {
            lastErrorMessage = error.localizedDescription
            recordDiagnostic("Plaid Hosted Link creation failed: \(error.localizedDescription)")
        }

        isSyncing = false
        recordDiagnostic("connectRealBank() finished. isSyncing=\(isSyncing), hostedLinkReady=\(hostedLinkSession != nil).")
    }

    func finishRealBankConnection() async {
        recordDiagnostic("finishRealBankConnection() entered. hostedLinkReady=\(hostedLinkSession != nil).")

        guard let hostedLinkSession else {
            lastErrorMessage = "Create a Plaid link first, then finish the bank login inside Clarity."
            recordDiagnostic("finishRealBankConnection() stopped: no Hosted Link session in memory.")
            return
        }

        guard credentials.isProductionComplete else {
            lastErrorMessage = "Add your Plaid client ID and Production secret in Settings first."
            recordDiagnostic("finishRealBankConnection() stopped: missing production credentials.")
            return
        }

        isSyncing = true
        statusMessage = "Checking Plaid for your completed bank login..."
        lastErrorMessage = nil
        recordDiagnostic("Polling Plaid /link/token/get for completed Hosted Link session.")

        do {
            let publicTokens = try await waitForHostedPublicTokens(linkToken: hostedLinkSession.linkToken)
            recordDiagnostic("Plaid returned \(publicTokens.count) public token(s).")

            guard let publicToken = publicTokens.first else {
                throw PlaidError.api("Plaid has not returned a bank connection yet. Finish the browser login, then tap import again.")
            }

            recordDiagnostic("Exchanging public token for access token.")
            var connection = try await plaidClient.exchangePublicToken(
                credentials: credentials,
                publicToken: publicToken,
                environment: .production
            )
            recordDiagnostic("Public token exchanged. institution=\(connection.institutionName), itemIDLength=\(connection.itemID.count). Fetching accounts only.")
            let accounts = try await plaidClient.fetchAccounts(credentials: credentials, connection: connection, environment: .production)
            recordDiagnostic("Fetched \(accounts.count) account(s). Transactions and recurring import are disabled for the fresh rebuild.")
            connection.lastSyncedAt = Date()

            data.connections.append(connection)
            upsert(accounts: accounts)
            save()
            self.hostedLinkSession = nil
            statusMessage = "Connected \(connection.institutionName) with \(accounts.count) accounts."
            recordDiagnostic("Real bank import completed successfully.")
        } catch {
            lastErrorMessage = error.localizedDescription
            recordDiagnostic("Real bank import failed: \(error.localizedDescription)")
        }

        isSyncing = false
        recordDiagnostic("finishRealBankConnection() finished. isSyncing=\(isSyncing).")
    }

    func importCompletedHostedLinkWhenAppReturns() async {
        guard hostedLinkSession != nil else {
            return
        }

        guard !isSyncing else {
            recordDiagnostic("Skipped return import check because another Plaid operation is already running.")
            return
        }

        recordDiagnostic("App became active with a pending Hosted Link. Checking whether Plaid has a completed bank connection.")
        await finishRealBankConnection()
    }

    func importAppleCardStatement(from url: URL) {
        do {
            let isScoped = url.startAccessingSecurityScopedResource()
            defer {
                if isScoped {
                    url.stopAccessingSecurityScopedResource()
                }
            }

            let result = try StatementImportService.importAppleCardStatement(from: url)
            upsert(accounts: [result.account])
            upsert(transactions: result.transactions)
            rebuildDerivedData()
            save()
            let importedExpenseTotal = result.transactions
                .filter { !$0.isIncome }
                .reduce(0) { $0 + abs($1.amount) }
            statusMessage = "Imported \(result.transactions.count) Apple Card PDF transactions."
            lastErrorMessage = nil
            recordDiagnostic("Apple Card PDF imported. transactions=\(result.transactions.count), expenseTotal=\(MoneyFormat.currency(importedExpenseTotal)), reportingMonth=\(reportingMonthTitle), monthlySpend=\(MoneyFormat.currency(monthlySpend)).")
        } catch {
            lastErrorMessage = error.localizedDescription
        }
    }

    func backfillTransactionHistory() async {
        guard !data.connections.isEmpty else {
            lastErrorMessage = "Connect a Plaid account before backfilling transaction history."
            return
        }

        isSyncing = true
        statusMessage = "Backfilling up to \(PlaidSandboxClient.requestedTransactionHistoryDays) days of transaction history..."
        lastErrorMessage = nil
        recordDiagnostic("Backfill started. Resetting local Plaid transaction cursors and syncing available history.")

        do {
            for index in data.connections.indices {
                var connection = data.connections[index]
                let environment = environment(for: connection)
                connection.cursor = nil

                let accounts = try await plaidClient.fetchAccounts(credentials: credentials, connection: connection, environment: environment)
                let sync = try await syncTransactionsWithInitialPolling(
                    connection: &connection,
                    environment: environment,
                    shouldPollForInitialData: true
                )

                connection.lastSyncedAt = Date()
                data.connections[index] = connection
                upsert(accounts: accounts)
                upsert(transactions: sync.transactions)
                removeTransactions(ids: sync.removedTransactionIDs)
                recordDiagnostic("Backfill synced \(sync.transactions.count) transaction update(s) for \(connection.institutionName).")
                recordTransactionCoverage(context: "history backfill", accounts: accounts)
            }

            let plaidSubscriptions = await fetchPlaidRecurringSubscriptionsForAllConnections()
            rebuildDerivedData(plaidSubscriptions: plaidSubscriptions)
            save()
            statusMessage = "Backfill complete. If a bank still starts around Apr 15, reconnect it so Plaid can create a new Item with \(PlaidSandboxClient.requestedTransactionHistoryDays) days requested."
        } catch {
            lastErrorMessage = error.localizedDescription
            recordDiagnostic("Backfill failed: \(error.localizedDescription)")
        }

        isSyncing = false
    }

    func clearLocalData() {
        data = .empty
        selectedAccountIDs = []
        hostedLinkSession = nil
        save()
        statusMessage = "Cleared local financial data."
        lastErrorMessage = nil
    }

    private func resetToConnectionOnlyData() {
        let removedTransactions = data.transactions.count
        let removedSubscriptions = data.subscriptions.count
        let removedBudgets = data.budgets.count
        let removedSnapshots = data.netWorthSnapshots.count

        data.transactions = []
        data.subscriptions = []
        data.budgets = []
        data.netWorthSnapshots = []
        data.ignoredSubscriptionKeys = []
        data.recurringChargeCorrections = [:]
        selectedAccountIDs = []
        recurringDiagnostics = []

        guard removedTransactions > 0 || removedSubscriptions > 0 || removedBudgets > 0 || removedSnapshots > 0 else {
            return
        }

        print("[Clarity Diagnostics] Connection-only reset removed transactions=\(removedTransactions), subscriptions=\(removedSubscriptions), budgets=\(removedBudgets), snapshots=\(removedSnapshots).")
    }

    func setRecurringCharge(_ subscription: SubscriptionItem, correction: RecurringChargeCorrection?) {
        let key = FinanceCoachEngine.subscriptionKey(subscription)

        if let correction {
            data.recurringChargeCorrections[key] = correction
            switch correction {
            case .subscription:
                statusMessage = "\(subscription.displayName) marked as a subscription."
            case .bill:
                statusMessage = "\(subscription.displayName) marked as a bill."
            case .ignored:
                statusMessage = "\(subscription.displayName) hidden from recurring charges."
            }
        } else {
            data.recurringChargeCorrections.removeValue(forKey: key)
            statusMessage = "\(subscription.displayName) restored to Plaid's classification."
        }

        data.ignoredSubscriptionKeys.remove(key)
        save()
    }

    private func upsert(accounts: [FinancialAccount]) {
        for account in accounts {
            if let index = data.accounts.firstIndex(where: { $0.id == account.id }) {
                data.accounts[index] = account
            } else {
                data.accounts.append(account)
            }
        }

        let validAccountIDs = Set(data.accounts.map(\.id))
        selectedAccountIDs = selectedAccountIDs.intersection(validAccountIDs)
    }

    private func upsert(transactions: [FinanceTransaction]) {
        for transaction in transactions {
            var transaction = transaction
            transaction.merchantName = MerchantNameCleaner.clean(transaction.merchantName)

            if let index = data.transactions.firstIndex(where: { $0.id == transaction.id }) {
                data.transactions[index] = transaction
            } else {
                data.transactions.append(transaction)
            }
        }
    }

    private func normalizeStoredTransactionMerchantNames() {
        var changedCount = 0
        data.transactions = data.transactions.map { transaction in
            var cleaned = transaction
            let cleanName = MerchantNameCleaner.clean(transaction.merchantName)
            if cleanName != transaction.merchantName {
                cleaned.merchantName = cleanName
                changedCount += 1
            }
            return cleaned
        }

        if changedCount > 0 {
            recordDiagnostic("Cleaned \(changedCount) stored transaction merchant name(s).")
        }
    }

    private func normalizeStoredRecurringNames() {
        var changedCount = 0
        data.subscriptions = data.subscriptions.map { subscription in
            var cleaned = subscription
            let displayName = subscription.displayName
            if displayName != subscription.merchantName {
                cleaned.merchantName = displayName
                changedCount += 1
            }
            return cleaned
        }

        if changedCount > 0 {
            recordDiagnostic("Cleaned \(changedCount) stored recurring charge name(s).")
        }
    }

    private func syncTransactionsWithInitialPolling(
        connection: inout PlaidConnection,
        environment: PlaidEnvironment,
        shouldPollForInitialData: Bool
    ) async throws -> PlaidSyncResult {
        var combinedTransactions: [FinanceTransaction] = []
        var combinedRemovedTransactionIDs: [String] = []

        for attempt in 1...6 {
            let sync = try await plaidClient.syncTransactions(
                credentials: credentials,
                connection: connection,
                environment: environment
            )

            combinedTransactions.append(contentsOf: sync.transactions)
            combinedRemovedTransactionIDs.append(contentsOf: sync.removedTransactionIDs)
            connection.cursor = sync.nextCursor

            if !shouldPollForInitialData || !combinedTransactions.isEmpty {
                return PlaidSyncResult(
                    transactions: combinedTransactions,
                    removedTransactionIDs: combinedRemovedTransactionIDs,
                    nextCursor: connection.cursor
                )
            }

            guard attempt < 6 else { break }
            recordDiagnostic("Plaid returned 0 transactions on initial sync attempt \(attempt)/6. Waiting for initial transaction data.")
            try await Task.sleep(for: .seconds(5))
        }

        return PlaidSyncResult(
            transactions: combinedTransactions,
            removedTransactionIDs: combinedRemovedTransactionIDs,
            nextCursor: connection.cursor
        )
    }

    private func recordTransactionCoverage(context: String, accounts: [FinancialAccount]) {
        let counts = Dictionary(grouping: data.transactions, by: \.accountID).mapValues(\.count)
        let summary = accounts
            .map { account in
                "\(account.kind.title) \(account.displayName): \(counts[account.id, default: 0])"
            }
            .joined(separator: " | ")

        recordDiagnostic("Transaction coverage after \(context): \(summary.isEmpty ? "no accounts" : summary).")
    }

    private func removeTransactions(ids: [String]) {
        guard !ids.isEmpty else { return }
        let removed = Set(ids)
        data.transactions.removeAll { removed.contains($0.id) }
    }

    private func rebuildDerivedData(plaidSubscriptions: [SubscriptionItem]? = nil) {
        rebuildBudgets()
        if let plaidSubscriptions {
            replaceRecurringCharges(with: plaidSubscriptions)
        }
        appendNetWorthSnapshot()
        recordDiagnostic("Derived data rebuilt. budgets=\(data.budgets.count), subscriptions=\(data.subscriptions.count), netWorthSnapshots=\(data.netWorthSnapshots.count).")
    }

    private func fetchPlaidRecurringSubscriptionsForAllConnections() async -> [SubscriptionItem]? {
        guard !data.connections.isEmpty else { return [] }

        var subscriptions: [SubscriptionItem] = []
        var diagnostics: [String] = []
        var successfulFetches = 0

        for connection in data.connections {
            let environment = environment(for: connection)

            do {
                let result = try await plaidClient.fetchRecurringSubscriptions(
                    credentials: credentials,
                    connection: connection,
                    environment: environment
                )
                successfulFetches += 1
                subscriptions.append(contentsOf: result.items)
                diagnostics.append("\(connection.institutionName): raw outflow streams=\(result.rawOutflowCount), mapped=\(result.mappedCount)")
                if result.rawOutflowCount == 0 {
                    diagnostics.append("  Plaid returned 0 recurring outflow streams for this Item.")
                }
                diagnostics.append(contentsOf: result.streamSummaries.map { "  \($0)" })
                diagnostics.append(contentsOf: result.droppedSummaries.map { "  DROP: \($0)" })
                recordDiagnostic("Plaid recurring streams fetched for \(connection.institutionName): rawOutflows=\(result.rawOutflowCount), mapped=\(result.mappedCount).")
            } catch {
                let line = "\(connection.institutionName): recurring unavailable: \(error.localizedDescription)"
                diagnostics.append(line)
                recordDiagnostic("Plaid recurring streams unavailable for \(connection.institutionName): \(error.localizedDescription). No local fallback will be used.")
            }
        }

        recurringDiagnostics = diagnostics
        return successfulFetches > 0 ? subscriptions : nil
    }

    private func environment(for connection: PlaidConnection) -> PlaidEnvironment {
        connection.environment
    }

    private func waitForHostedPublicTokens(linkToken: String) async throws -> [PlaidHostedPublicToken] {
        for attempt in 1...8 {
            recordDiagnostic("Hosted Link poll attempt \(attempt)/8.")
            let tokens = try await plaidClient.fetchHostedLinkPublicTokens(
                credentials: credentials,
                linkToken: linkToken,
                environment: .production
            )
            if !tokens.isEmpty {
                recordDiagnostic("Hosted Link poll found token(s) on attempt \(attempt).")
                return tokens
            }

            try await Task.sleep(for: .seconds(2))
        }

        recordDiagnostic("Hosted Link polling timed out without public tokens.")
        throw PlaidError.api("Plaid has not returned a completed bank connection yet. Finish the browser login first, then tap import again.")
    }

    private func rebuildBudgets() {
        data.budgets = budgets(for: data.transactions)
    }

    private func budgets(for transactions: [FinanceTransaction]) -> [BudgetCategory] {
        guard transactions.contains(where: { !$0.isIncome }) else {
            return []
        }

        let existingLimits = Dictionary(uniqueKeysWithValues: data.budgets.map { ($0.category, $0.limit) })
        let limits: [TransactionCategory: Double] = [
            .food: existingLimits[.food] ?? 650,
            .shopping: existingLimits[.shopping] ?? 500,
            .transport: existingLimits[.transport] ?? 320,
            .entertainment: existingLimits[.entertainment] ?? 250,
            .utilities: existingLimits[.utilities] ?? 300,
            .subscriptions: existingLimits[.subscriptions] ?? 120
        ]

        return limits.map { category, limit in
            let spent = transactions
                .filter { !$0.isIncome && $0.category == category }
                .reduce(0) { $0 + abs($1.amount) }
            return BudgetCategory(id: category.rawValue, category: category, limit: limit, spent: spent)
        }
        .sorted { $0.category.title < $1.category.title }
    }

    private func replaceRecurringCharges(with plaidSubscriptions: [SubscriptionItem]) {
        data.subscriptions = plaidSubscriptions
            .filter { $0.source == .plaid }
            .map { subscription in
                var cleaned = subscription
                cleaned.merchantName = subscription.displayName
                return cleaned
            }
            .sorted { $0.monthlyAmount > $1.monthlyAmount }

        let validKeys = Set(data.subscriptions.map(FinanceCoachEngine.subscriptionKey))
        data.recurringChargeCorrections = data.recurringChargeCorrections.filter { validKeys.contains($0.key) }
        data.ignoredSubscriptionKeys = data.ignoredSubscriptionKeys.intersection(validKeys)
    }

    private func discardLegacyLocalSubscriptions() {
        let before = data.subscriptions.count
        data.subscriptions.removeAll { $0.source != .plaid }

        if before != data.subscriptions.count {
            recordDiagnostic("Removed \(before - data.subscriptions.count) legacy local recurring guess(es). Plaid recurring streams are now the only detection source.")
        }
    }

    private func appendNetWorthSnapshot() {
        let snapshot = NetWorthSnapshot(
            id: UUID().uuidString,
            date: Date(),
            assets: assetsTotal,
            liabilities: liabilitiesTotal
        )

        data.netWorthSnapshots.append(snapshot)
        data.netWorthSnapshots = Array(data.netWorthSnapshots.sorted { $0.date < $1.date }.suffix(24))
    }

    private func save() {
        do {
            let folder = fileURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let encoded = try JSONEncoder.store.encode(data)
            try encoded.write(to: fileURL, options: .atomic)
        } catch {
            lastErrorMessage = error.localizedDescription
        }
    }

    private static func makeStoreURL() -> URL {
        let baseURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory
        return baseURL.appending(path: "Clarity Finance", directoryHint: .isDirectory).appending(path: "finance-data.json")
    }

    private func removeLegacySampleDataIfNeeded() {
        let sampleAccountIDs: Set<String> = ["checking-main", "savings-main", "credit-main", "apple-card"]
        let beforeAccounts = data.accounts.count
        let beforeTransactions = data.transactions.count

        data.accounts.removeAll { sampleAccountIDs.contains($0.id) }
        data.transactions.removeAll { $0.source == "Sample" || sampleAccountIDs.contains($0.accountID) }

        if data.accounts.count != beforeAccounts || data.transactions.count != beforeTransactions {
            if !hasFinancialData {
                data = .empty
            } else {
                rebuildDerivedData()
            }
            save()
        }
    }
}

private extension JSONEncoder {
    static var store: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}

private extension JSONDecoder {
    static var store: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
