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
    var isAnalyzingSpending = false
    var openAIAPIKey: String

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
        let savedOpenAIAPIKey = (try? KeychainStore.read(account: "openai-api-key")) ?? ""
        let bundledOpenAIAPIKey = Self.bundledOpenAIAPIKey()
        openAIAPIKey = savedOpenAIAPIKey.isEmpty ? bundledOpenAIAPIKey ?? "" : savedOpenAIAPIKey
        if savedOpenAIAPIKey.isEmpty, let bundledOpenAIAPIKey {
            try? KeychainStore.save(bundledOpenAIAPIKey, account: "openai-api-key")
        }

        removeLegacySampleDataIfNeeded()
        normalizeStoredTransactionMerchantNames()
        sortTransactionsNewestFirst()
        clearDerivedDataForFreshCore()
        if hasFinancialData {
            rebuildDerivedData()
        }
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
        filteredTransactions
    }

    var spendingToday: Double {
        expenseTotal(matching: { Calendar.current.isDateInToday($0.date) })
    }

    var spendingThisWeek: Double {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let start = calendar.date(byAdding: .day, value: -6, to: today) ?? today
        return expenseTotal(matching: { $0.date >= start && $0.date <= Date() })
    }

    var spendingThisMonth: Double {
        expenseTotal(inMonthOf: Date())
    }

    var topMerchantThisMonth: MerchantSpend? {
        merchantSpending(inMonthOf: Date()).first
    }

    var biggestSpendThisMonth: FinanceTransaction? {
        let calendar = Calendar.current
        return filteredTransactions
            .filter { !$0.isIncome && calendar.isDate($0.date, equalTo: Date(), toGranularity: .month) }
            .max { abs($0.amount) < abs($1.amount) }
    }

    var aiSummaryText: String {
        let classifications = data.merchantClassifications.values
        guard !classifications.isEmpty else {
            if data.transactions.isEmpty {
                return "Connect a bank first."
            }
            return "Run AI scan in Settings to label merchants."
        }

        let subscriptions = classifications.filter { $0.kind == .subscription }.count
        let bills = classifications.filter { $0.kind == .bill }.count
        return "\(classifications.count) merchants labeled: \(subscriptions) subscriptions, \(bills) bills."
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
        return activeSubscriptions.filter(matchesSelectedAccounts)
    }

    var filteredRecurringBills: [SubscriptionItem] {
        let activeBills = correctedRecurringCharges.filter {
            let key = FinanceCoachEngine.subscriptionKey($0)
            return $0.recurringKind == .bill &&
                data.recurringChargeCorrections[key] != .ignored &&
                !data.ignoredSubscriptionKeys.contains(key)
        }
        guard !selectedAccountIDs.isEmpty else { return activeBills }
        return activeBills.filter(matchesSelectedAccounts)
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
            return matchesSelectedAccounts(subscription)
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

    func removeAccount(_ account: FinancialAccount) {
        removeAccount(id: account.id, displayName: account.displayName)
    }

    func expenseTotal(inMonthOf anchor: Date) -> Double {
        let calendar = Calendar.current
        return filteredTransactions
            .filter { !$0.isIncome && calendar.isDate($0.date, equalTo: anchor, toGranularity: .month) }
            .reduce(0) { $0 + abs($1.amount) }
    }

    func expenseTotal(matching predicate: (FinanceTransaction) -> Bool) -> Double {
        filteredTransactions
            .filter { !$0.isIncome && predicate($0) }
            .reduce(0) { $0 + abs($1.amount) }
    }

    func incomeTotal(inMonthOf anchor: Date) -> Double {
        let calendar = Calendar.current
        return filteredTransactions
            .filter { $0.isIncome && calendar.isDate($0.date, equalTo: anchor, toGranularity: .month) }
            .reduce(0) { $0 + abs($1.amount) }
    }

    func classification(for transaction: FinanceTransaction) -> AIMerchantClassification? {
        data.merchantClassifications[Self.merchantKey(for: transaction.merchantName)]
    }

    func merchantHistory(for transaction: FinanceTransaction) -> [FinanceTransaction] {
        let merchantKey = Self.merchantKey(for: transaction.merchantName)
        return filteredTransactions.filter {
            $0.id != transaction.id &&
                Self.merchantKey(for: $0.merchantName) == merchantKey
        }
    }

    func merchantSpending(inMonthOf anchor: Date) -> [MerchantSpend] {
        let calendar = Calendar.current
        let grouped = Dictionary(grouping: filteredTransactions.filter {
            !$0.isIncome && calendar.isDate($0.date, equalTo: anchor, toGranularity: .month)
        }) { transaction in
            Self.merchantKey(for: transaction.merchantName)
        }

        return grouped.compactMap { key, transactions -> MerchantSpend? in
            guard let first = transactions.first else { return nil }
            return MerchantSpend(
                merchantKey: key,
                merchantName: MerchantNameCleaner.canonicalDisplayName(for: first.merchantName),
                total: transactions.reduce(0) { $0 + abs($1.amount) },
                transactionCount: transactions.count,
                classification: data.merchantClassifications[key]
            )
        }
        .sorted { $0.total > $1.total }
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

    func saveCredentials(clientID: String, sandboxSecret: String, productionSecret: String, linkCustomizationName: String, openAIAPIKey: String) {
        recordDiagnostic("Saving credentials. clientID set=\(!clientID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty), sandbox secret set=\(!sandboxSecret.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty), production secret set=\(!productionSecret.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty), link customization set=\(!linkCustomizationName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty), OpenAI key set=\(!openAIAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty).")

        credentials = PlaidCredentials(
            clientID: clientID,
            sandboxSecret: sandboxSecret,
            productionSecret: productionSecret,
            linkCustomizationName: linkCustomizationName
        )
        self.openAIAPIKey = openAIAPIKey

        do {
            try KeychainStore.save(clientID, account: "plaid-client-id")
            try KeychainStore.save(sandboxSecret, account: "plaid-sandbox-secret")
            try KeychainStore.save(productionSecret, account: "plaid-production-secret")
            try KeychainStore.save(linkCustomizationName, account: "plaid-link-customization-name")
            try KeychainStore.save(openAIAPIKey, account: "openai-api-key")
            statusMessage = "Credentials saved."
            lastErrorMessage = nil
            recordDiagnostic("Credentials saved to Keychain.")
        } catch {
            lastErrorMessage = error.localizedDescription
            recordDiagnostic("Failed to save credentials: \(error.localizedDescription)")
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
            let sync = try await syncTransactionsWithInitialPolling(
                connection: &connection,
                environment: .sandbox,
                shouldPollForInitialData: true
            )
            connection.lastSyncedAt = Date()

            data.connections.append(connection)
            upsert(accounts: accounts)
            upsert(transactions: sync.transactions)
            removeTransactions(ids: sync.removedTransactionIDs)
            rebuildDerivedData()
            save()
            recordTransactionCoverage(context: "sandbox import", accounts: accounts)
            await analyzeSpendingWithAI(onlyMissing: true)
            statusMessage = "Connected \(connection.institutionName): \(accounts.count) accounts, \(sync.transactions.count) transactions."
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
        statusMessage = "Refreshing accounts and transactions..."
        lastErrorMessage = nil

        do {
            for index in data.connections.indices {
                var connection = data.connections[index]
                let environment = environment(for: connection)
                try? await plaidClient.refreshTransactions(credentials: credentials, connection: connection, environment: environment)
                let accounts = try await plaidClient.fetchAccounts(credentials: credentials, connection: connection, environment: environment)
                let sync = try await syncTransactionsWithInitialPolling(
                    connection: &connection,
                    environment: environment,
                    shouldPollForInitialData: connection.cursor == nil
                )
                connection.lastSyncedAt = Date()
                data.connections[index] = connection
                upsert(accounts: accounts)
                upsert(transactions: sync.transactions)
                removeTransactions(ids: sync.removedTransactionIDs)
                recordDiagnostic("Refreshed \(accounts.count) account(s) and \(sync.transactions.count) transaction update(s) for \(connection.institutionName).")
                recordTransactionCoverage(context: "sync", accounts: accounts)
            }

            rebuildDerivedData()
            save()
            await analyzeSpendingWithAI(onlyMissing: true)
            statusMessage = "Spending is up to date."
        } catch {
            lastErrorMessage = error.localizedDescription
        }

        isSyncing = false
    }

    func refreshRecurringCharges() async {
        guard !data.transactions.isEmpty else {
            lastErrorMessage = "Connect a bank or import transactions before refreshing recurring charges."
            return
        }

        isSyncing = true
        statusMessage = "Refreshing recurring charges..."
        lastErrorMessage = nil

        await analyzeSpendingWithAI(onlyMissing: false)
        rebuildDerivedData()
        save()

        statusMessage = "Recurring refresh complete: \(data.subscriptions.count) charge(s)."

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
            recordDiagnostic("Public token exchanged. institution=\(connection.institutionName), itemIDLength=\(connection.itemID.count). Fetching accounts and transactions.")
            let accounts = try await plaidClient.fetchAccounts(credentials: credentials, connection: connection, environment: .production)
            let sync = try await syncTransactionsWithInitialPolling(
                connection: &connection,
                environment: .production,
                shouldPollForInitialData: true
            )
            recordDiagnostic("Fetched \(accounts.count) account(s) and \(sync.transactions.count) transaction update(s).")
            connection.lastSyncedAt = Date()

            data.connections.append(connection)
            upsert(accounts: accounts)
            upsert(transactions: sync.transactions)
            removeTransactions(ids: sync.removedTransactionIDs)
            rebuildDerivedData()
            save()
            self.hostedLinkSession = nil
            recordTransactionCoverage(context: "real bank import", accounts: accounts)
            await analyzeSpendingWithAI(onlyMissing: true)
            statusMessage = "Connected \(connection.institutionName): \(accounts.count) accounts, \(sync.transactions.count) transactions."
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
            Task { await analyzeSpendingWithAI(onlyMissing: true) }
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

            rebuildDerivedData()
            save()
            await analyzeSpendingWithAI(onlyMissing: true)
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

    func analyzeSpendingWithAI(onlyMissing: Bool = false) async {
        migrateClassificationsToCanonicalMerchantKeys()
        let inputs = aiClassificationInputs(onlyMissing: onlyMissing)

        guard !inputs.isEmpty else {
            if data.transactions.isEmpty {
                statusMessage = "Connect an account or import transactions before using AI."
            } else if onlyMissing {
                recordDiagnostic("AI scan skipped: all current merchants already have classifications.")
            }
            return
        }

        isAnalyzingSpending = true
        statusMessage = "AI is labeling your spending..."
        lastErrorMessage = nil

        do {
            let classifications = try await OpenAIClassificationClient(apiKey: openAIAPIKey).classify(merchants: inputs)
            for classification in classifications {
                data.merchantClassifications[classification.merchantKey] = classification
            }
            rebuildDerivedData()
            save()
            statusMessage = "AI labeled \(classifications.count) merchant(s)."
            recordDiagnostic("AI classification completed. merchants=\(classifications.count).")
        } catch {
            lastErrorMessage = error.localizedDescription
            recordDiagnostic("AI classification failed: \(error.localizedDescription)")
        }

        isAnalyzingSpending = false
    }

    private func clearDerivedDataForFreshCore() {
        let removedSubscriptions = data.subscriptions.count
        let removedBudgets = data.budgets.count
        let removedSnapshots = data.netWorthSnapshots.count

        data.budgets = []
        data.netWorthSnapshots = []
        data.subscriptions.removeAll { $0.source != .ai }
        let validSubscriptionKeys = Set(data.subscriptions.map(FinanceCoachEngine.subscriptionKey))
        data.ignoredSubscriptionKeys = data.ignoredSubscriptionKeys.intersection(validSubscriptionKeys)
        data.recurringChargeCorrections = data.recurringChargeCorrections.filter { validSubscriptionKeys.contains($0.key) }
        let validAccountIDs = Set(data.accounts.map(\.id))
        selectedAccountIDs = selectedAccountIDs.filter { validAccountIDs.contains($0) }
        recurringDiagnostics = []

        let removedOldSubscriptions = removedSubscriptions - data.subscriptions.count
        guard removedOldSubscriptions > 0 || removedBudgets > 0 || removedSnapshots > 0 else {
            return
        }

        print("[Clarity Diagnostics] Fresh-core cleanup removed oldSubscriptions=\(removedOldSubscriptions), budgets=\(removedBudgets), snapshots=\(removedSnapshots).")
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
            statusMessage = "\(subscription.displayName) restored to AI classification."
        }

        data.ignoredSubscriptionKeys.remove(key)
        save()
    }

    private func upsert(accounts: [FinancialAccount]) {
        for account in accounts {
            guard !data.removedAccountIDs.contains(account.id) else {
                continue
            }

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
        var didChangeTransactions = false

        for transaction in transactions {
            var transaction = transaction
            guard !data.removedAccountIDs.contains(transaction.accountID) else {
                continue
            }

            transaction.merchantName = MerchantNameCleaner.clean(transaction.merchantName)

            if let index = data.transactions.firstIndex(where: { $0.id == transaction.id }) {
                data.transactions[index] = transaction
            } else {
                data.transactions.append(transaction)
            }
            didChangeTransactions = true
        }

        if didChangeTransactions {
            sortTransactionsNewestFirst()
        }
    }

    private func removeAccount(id accountID: String, displayName: String) {
        let accountsBefore = data.accounts.count
        let transactionsBefore = data.transactions.count

        data.removedAccountIDs.insert(accountID)
        data.accounts.removeAll { $0.id == accountID }
        data.transactions.removeAll { $0.accountID == accountID }
        data.netWorthSnapshots = []
        selectedAccountIDs.remove(accountID)

        rebuildDerivedData()
        save()

        let removedAccounts = accountsBefore - data.accounts.count
        let removedTransactions = transactionsBefore - data.transactions.count
        statusMessage = "Removed \(displayName) and \(removedTransactions) linked transaction(s)."
        lastErrorMessage = nil
        recordDiagnostic("Removed account id=\(accountID), accountsRemoved=\(removedAccounts), transactionsRemoved=\(removedTransactions).")
    }

    private func aiClassificationInputs(onlyMissing: Bool) -> [AIClassificationInput] {
        let calendar = Calendar.current
        let cutoff = calendar.date(byAdding: .day, value: -180, to: Date()) ?? .daysAgo(180)
        let transactions = data.transactions.filter { transaction in
            !transaction.isIncome && transaction.date >= cutoff
        }

        let grouped = Dictionary(grouping: transactions) { transaction in
            Self.merchantKey(for: transaction.merchantName)
        }

        return grouped.compactMap { key, transactions -> AIClassificationInput? in
            guard !transactions.isEmpty else { return nil }
            guard !onlyMissing || data.merchantClassifications[key] == nil else { return nil }

            let sorted = transactions.sorted { $0.date > $1.date }
            let total = sorted.reduce(0) { $0 + abs($1.amount) }
            let originalNames = Array(Set(sorted.flatMap { transaction in
                [
                    transaction.originalName,
                    transaction.merchantName,
                    MerchantNameCleaner.clean(transaction.originalName)
                ]
            })).prefix(8)
            let categories = Array(Set(sorted.map { $0.category.title })).prefix(4)

            return AIClassificationInput(
                key: key,
                merchantName: MerchantNameCleaner.canonicalDisplayName(for: sorted[0].merchantName),
                originalNames: Array(originalNames),
                plaidCategories: Array(categories),
                transactionCount: sorted.count,
                totalSpent: total,
                averageAmount: total / Double(sorted.count),
                latestDate: sorted[0].date,
                transactions: sorted.prefix(12).map {
                    AITransactionSample(
                        date: $0.date,
                        amount: $0.amount,
                        name: $0.originalName.isEmpty ? $0.merchantName : $0.originalName
                    )
                }
            )
        }
        .sorted { $0.totalSpent > $1.totalSpent }
        .prefix(60)
        .map { $0 }
    }

    private static func merchantKey(for merchantName: String) -> String {
        MerchantNameCleaner.canonicalKey(for: merchantName)
    }

    private func matchesSelectedAccounts(_ subscription: SubscriptionItem) -> Bool {
        guard !selectedAccountIDs.isEmpty else { return true }
        if let accountID = subscription.accountID {
            return selectedAccountIDs.contains(accountID)
        }

        return !FinanceCoachEngine
            .matchingTransactions(for: subscription, in: filteredTransactions)
            .isEmpty
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

    private func sortTransactionsNewestFirst() {
        data.transactions.sort { lhs, rhs in
            if lhs.date != rhs.date {
                return lhs.date > rhs.date
            }
            return lhs.id < rhs.id
        }
    }

    private func migrateClassificationsToCanonicalMerchantKeys() {
        var migrated: [String: AIMerchantClassification] = [:]
        var changedCount = 0

        for classification in data.merchantClassifications.values {
            let canonicalKey = Self.merchantKey(for: classification.displayName)
            var updated = classification
            if updated.merchantKey != canonicalKey {
                updated.merchantKey = canonicalKey
                updated.displayName = MerchantNameCleaner.canonicalDisplayName(for: classification.displayName)
                changedCount += 1
            }

            if let existing = migrated[canonicalKey] {
                migrated[canonicalKey] = existing.updatedAt >= updated.updatedAt ? existing : updated
            } else {
                migrated[canonicalKey] = updated
            }
        }

        guard changedCount > 0 || migrated.count != data.merchantClassifications.count else {
            return
        }

        data.merchantClassifications = migrated
        recordDiagnostic("Migrated AI classifications to canonical merchant keys. changed=\(changedCount), total=\(migrated.count).")
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

    private func rebuildDerivedData() {
        rebuildBudgets()
        replaceRecurringCharges(with: aiRecurringCharges())
        appendNetWorthSnapshot()
        recordDiagnostic("Derived data rebuilt. budgets=\(data.budgets.count), subscriptions=\(data.subscriptions.count), netWorthSnapshots=\(data.netWorthSnapshots.count).")
    }

    private func aiRecurringCharges() -> [SubscriptionItem] {
        let candidateTransactions = data.transactions.filter { !$0.isIncome }
        guard !candidateTransactions.isEmpty else { return [] }

        let grouped = Dictionary(grouping: candidateTransactions) { transaction in
            Self.merchantKey(for: transaction.merchantName)
        }

        return grouped.flatMap { _, transactions -> [SubscriptionItem] in
            guard let latest = transactions.max(by: { $0.date < $1.date }) else { return [] }
            let merchantKey = Self.merchantKey(for: latest.merchantName)
            let classification = data.merchantClassifications[merchantKey]
            let classifiedRecurringKind = recurringKind(from: classification?.kind)

            let sorted = transactions.sorted { $0.date < $1.date }
            let streams = recurringStreams(
                from: sorted,
                classification: classification,
                fallbackDisplayName: MerchantNameCleaner.canonicalDisplayName(for: latest.merchantName),
                classifiedRecurringKind: classifiedRecurringKind
            )

            return streams.map { stream in
                let streamLatest = stream.transactions.last ?? latest
                let lastDate = streamLatest.date
                let nextDate = Calendar.current.date(byAdding: .day, value: stream.estimate.cadenceDays, to: lastDate) ?? .daysFromNow(stream.estimate.cadenceDays)
                let activeCutoff = Calendar.current.date(byAdding: .day, value: -max(stream.estimate.cadenceDays * 2, 45), to: Date()) ?? .daysAgo(75)
                let accountIDs = Set(stream.transactions.map(\.accountID))
                let displayName = stream.displayName ?? MerchantNameCleaner.canonicalDisplayName(for: latest.merchantName)

                return SubscriptionItem(
                    id: stream.idSuffix.map { "ai-recurring-\(merchantKey)--\($0)" } ?? "ai-recurring-\(merchantKey)",
                    merchantName: displayName,
                    category: stream.category,
                    monthlyAmount: stream.estimate.monthlyAmount,
                    nextExpectedDate: nextDate,
                    accountID: accountIDs.count == 1 ? streamLatest.accountID : nil,
                    recurringKind: stream.recurringKind,
                    source: .ai,
                    frequency: stream.estimate.frequency,
                    status: stream.confidenceLabel,
                    lastAmount: stream.estimate.lastAmount,
                    averageAmount: stream.estimate.averageAmount,
                    lastDate: lastDate,
                    streamDescription: stream.note ?? classification?.plainEnglish ?? "Repeated charge pattern found in transaction history.",
                    isActive: lastDate >= activeCutoff
                )
            }
        }
        .sorted { lhs, rhs in
            if lhs.recurringKind != rhs.recurringKind {
                return lhs.recurringKind == .subscription
            }
            return lhs.monthlyAmount > rhs.monthlyAmount
        }
    }

    private func recurringStreams(
        from sortedTransactions: [FinanceTransaction],
        classification: AIMerchantClassification?,
        fallbackDisplayName: String,
        classifiedRecurringKind: RecurringChargeKind?
    ) -> [RecurringTransactionStream] {
        guard !sortedTransactions.isEmpty else { return [] }

        let recurringKind = classifiedRecurringKind ?? .subscription
        let category = classification?.category ?? (recurringKind == .subscription ? .subscriptions : .utilities)
        let displayName = classification
            .map { MerchantNameCleaner.canonicalDisplayName(for: $0.displayName) } ?? fallbackDisplayName

        let amountGroups = Dictionary(grouping: sortedTransactions) { amountCents(for: $0) }
        let repeatedAmountStreams = amountGroups
            .compactMap { amountCents, transactions -> RecurringTransactionStream? in
                let sorted = transactions.sorted { $0.date < $1.date }
                guard isStrongRecurringAmountStream(sorted) else { return nil }

                var estimate = recurringEstimate(from: sorted)
                estimate.monthlyAmount = roundedMoney(sorted.last.map { abs($0.amount) } ?? estimate.monthlyAmount)

                return RecurringTransactionStream(
                    idSuffix: "amount-\(amountCents)",
                    transactions: sorted,
                    estimate: estimate,
                    confidenceLabel: "High confidence",
                    displayName: displayName,
                    recurringKind: recurringKind,
                    category: category,
                    note: "Only the repeated \(MoneyFormat.currency(estimate.lastAmount)) charge is counted as recurring. Other \(displayName) purchases stay in transaction history."
                )
            }
            .sorted { lhs, rhs in
                if lhs.transactions.count != rhs.transactions.count {
                    return lhs.transactions.count > rhs.transactions.count
                }
                return lhs.estimate.monthlyAmount > rhs.estimate.monthlyAmount
            }

        if !repeatedAmountStreams.isEmpty {
            return repeatedAmountStreams
        }

        let inferredKnownStreams = knownSubscriptionStreams(
            from: sortedTransactions,
            fallbackDisplayName: fallbackDisplayName
        )
        if !inferredKnownStreams.isEmpty {
            return inferredKnownStreams
        }

        guard let classification, let classifiedRecurringKind else {
            return []
        }

        let distinctAmounts = Set(sortedTransactions.map(amountCents(for:)))
        let estimate = recurringEstimate(from: sortedTransactions)

        if sortedTransactions.count <= 2,
           classifiedRecurringKind == .subscription,
           classification.confidence >= 0.8,
           !looksLikeOneTimePayment(sortedTransactions, classification: classification) {
            return [
                RecurringTransactionStream(
                    idSuffix: nil,
                    transactions: sortedTransactions,
                    estimate: estimate,
                    confidenceLabel: "Needs review",
                    displayName: displayName,
                    recurringKind: classifiedRecurringKind,
                    category: classification.category,
                    note: classification.plainEnglish
                )
            ]
        }

        if classifiedRecurringKind == .bill,
           sortedTransactions.count >= 2,
           distinctAmounts.count <= 2,
           estimate.cadenceDays >= 21,
           estimate.cadenceDays <= 45,
           !looksLikeOneTimePayment(sortedTransactions, classification: classification) {
            return [
                RecurringTransactionStream(
                    idSuffix: nil,
                    transactions: sortedTransactions,
                    estimate: estimate,
                    confidenceLabel: classification.confidence >= 0.75 ? "High confidence" : "Needs review",
                    displayName: displayName,
                    recurringKind: classifiedRecurringKind,
                    category: classification.category,
                    note: classification.plainEnglish
                )
            ]
        }

        return []
    }

    private func looksLikeOneTimePayment(
        _ transactions: [FinanceTransaction],
        classification: AIMerchantClassification
    ) -> Bool {
        let text = (
            [
                classification.displayName,
                classification.plainEnglish,
                classification.category.title
            ] +
            transactions.flatMap { transaction in
                [
                    transaction.merchantName,
                    transaction.originalName,
                    transaction.category.title
                ]
            }
        )
        .joined(separator: " ")
        .lowercased()

        let oneTimeSignals = [
            "irs",
            "internal revenue",
            "treasury",
            "franchise tax",
            "tax payment",
            "estimated tax",
            "state tax",
            "income tax",
            "property tax",
            "tax board",
            "department of revenue",
            "comptroller",
            "one-time",
            "one time",
            "single payment",
            "filing fee",
            "permit fee"
        ]

        return oneTimeSignals.contains { text.contains($0) }
    }

    private func knownSubscriptionStreams(
        from sortedTransactions: [FinanceTransaction],
        fallbackDisplayName: String
    ) -> [RecurringTransactionStream] {
        let candidates = sortedTransactions.filter(isKnownSubscriptionCharge)
        guard !candidates.isEmpty else { return [] }

        return Dictionary(grouping: candidates) { amountCents(for: $0) }
            .compactMap { amountCents, transactions -> RecurringTransactionStream? in
                guard let latest = transactions.max(by: { $0.date < $1.date }) else { return nil }
                let sorted = transactions.sorted { $0.date < $1.date }
                let displayName = knownSubscriptionDisplayName(for: latest, fallback: fallbackDisplayName)
                var estimate = recurringEstimate(from: sorted)
                estimate.monthlyAmount = roundedMoney(abs(latest.amount))
                estimate.averageAmount = estimate.monthlyAmount
                estimate.lastAmount = estimate.monthlyAmount
                estimate.cadenceDays = max(estimate.cadenceDays, 30)
                estimate.frequency = "Monthly"

                return RecurringTransactionStream(
                    idSuffix: "known-\(amountCents)",
                    transactions: sorted,
                    estimate: estimate,
                    confidenceLabel: sorted.count >= 2 ? "High confidence" : "Needs review",
                    displayName: displayName,
                    recurringKind: .subscription,
                    category: .subscriptions,
                    note: sorted.count >= 2
                        ? "\(displayName) has a repeated subscription-looking charge."
                        : "\(displayName) looks like a subscription charge, but only one matching charge is imported so far."
                )
            }
            .sorted { lhs, rhs in
                if lhs.transactions.count != rhs.transactions.count {
                    return lhs.transactions.count > rhs.transactions.count
                }
                return lhs.estimate.monthlyAmount > rhs.estimate.monthlyAmount
            }
    }

    private func isKnownSubscriptionCharge(_ transaction: FinanceTransaction) -> Bool {
        let merchantKey = Self.merchantKey(for: transaction.merchantName)
        let rawText = "\(transaction.merchantName) \(transaction.originalName)".lowercased()
        let amountCents = amountCents(for: transaction)

        if merchantKey.contains("netflix") ||
            merchantKey.contains("spotify") ||
            merchantKey.contains("sling") ||
            merchantKey.contains("google-one") ||
            merchantKey.contains("openai") ||
            merchantKey.contains("chatgpt") ||
            merchantKey.contains("claude") ||
            merchantKey.contains("anthropic") {
            return true
        }

        guard merchantKey.contains("apple") else { return false }
        if rawText.contains("ad") || rawText.contains("advertising") || rawText.contains("search ads") {
            return false
        }

        return Self.commonAppleSubscriptionAmounts.contains(amountCents)
    }

    private func knownSubscriptionDisplayName(for transaction: FinanceTransaction, fallback: String) -> String {
        let merchantKey = Self.merchantKey(for: transaction.merchantName)
        let rawText = "\(transaction.merchantName) \(transaction.originalName)".lowercased()

        if merchantKey.contains("apple") {
            return "Apple Subscriptions"
        }
        if merchantKey.contains("google-one") {
            return "Google One"
        }
        if merchantKey.contains("openai") || rawText.contains("chatgpt") {
            return "OpenAI ChatGPT"
        }
        if merchantKey.contains("claude") || merchantKey.contains("anthropic") {
            return "Claude AI"
        }

        return fallback
    }

    private static let commonAppleSubscriptionAmounts: Set<Int> = [
        99, 199, 299, 399, 499, 599, 699, 799, 899, 999, 1299, 1499, 1699, 1999, 2499, 2999
    ]

    private func recurringKind(from transactionKind: AITransactionKind?) -> RecurringChargeKind? {
        switch transactionKind {
        case .subscription:
            return .subscription
        case .bill:
            return .bill
        default:
            return nil
        }
    }

    private func isStrongRecurringAmountStream(_ sortedTransactions: [FinanceTransaction]) -> Bool {
        guard sortedTransactions.count >= 3 else { return false }
        let cadence = estimatedCadenceDays(from: sortedTransactions.map(\.date))
        guard cadence >= 21, cadence <= 45 else { return false }

        let dates = sortedTransactions.map(\.date)
        let gaps = zip(dates.dropLast(), dates.dropFirst()).compactMap { start, end in
            Calendar.current.dateComponents(
                [.day],
                from: Calendar.current.startOfDay(for: start),
                to: Calendar.current.startOfDay(for: end)
            ).day
        }

        let monthlyLikeGaps = gaps.filter { $0 >= 21 && $0 <= 45 }.count
        return monthlyLikeGaps >= max(2, gaps.count / 2)
    }

    private func amountCents(for transaction: FinanceTransaction) -> Int {
        Int((abs(transaction.amount) * 100).rounded())
    }

    private func recurringEstimate(from sortedTransactions: [FinanceTransaction]) -> RecurringEstimate {
        let amounts = sortedTransactions.map { abs($0.amount) }
        guard let lastAmount = amounts.last else {
            return RecurringEstimate(monthlyAmount: 0, averageAmount: 0, lastAmount: 0, cadenceDays: 30, frequency: "Monthly")
        }

        guard sortedTransactions.count > 1 else {
            return RecurringEstimate(
                monthlyAmount: roundedMoney(lastAmount),
                averageAmount: roundedMoney(lastAmount),
                lastAmount: roundedMoney(lastAmount),
                cadenceDays: 30,
                frequency: "Monthly"
            )
        }

        let cadence = estimatedCadenceDays(from: sortedTransactions.map(\.date))
        let recentTotal = recentRecurringTotal(from: sortedTransactions)
        let averageAmount = amounts.suffix(3).reduce(0, +) / Double(min(amounts.count, 3))
        let isVariable = hasVariableRecurringAmounts(amounts)

        if cadence <= 10 || isVariable {
            return RecurringEstimate(
                monthlyAmount: roundedMoney(max(recentTotal, lastAmount)),
                averageAmount: roundedMoney(averageAmount),
                lastAmount: roundedMoney(lastAmount),
                cadenceDays: max(cadence, 30),
                frequency: "Monthly total"
            )
        }

        return RecurringEstimate(
            monthlyAmount: estimatedMonthlyAmount(averageAmount: averageAmount, cadenceDays: cadence),
            averageAmount: roundedMoney(averageAmount),
            lastAmount: roundedMoney(lastAmount),
            cadenceDays: cadence,
            frequency: cadenceLabel(for: cadence)
        )
    }

    private func recentRecurringTotal(from sortedTransactions: [FinanceTransaction]) -> Double {
        guard let latestDate = sortedTransactions.last?.date else { return 0 }
        let cutoff = Calendar.current.date(byAdding: .day, value: -35, to: latestDate) ?? latestDate
        let total = sortedTransactions
            .filter { $0.date >= cutoff }
            .reduce(0) { $0 + abs($1.amount) }
        return roundedMoney(total)
    }

    private func hasVariableRecurringAmounts(_ amounts: [Double]) -> Bool {
        guard amounts.count >= 2, let minAmount = amounts.min(), let maxAmount = amounts.max(), minAmount > 0 else {
            return false
        }

        let roundedAmounts = Set(amounts.map { roundedMoney($0) })
        return roundedAmounts.count >= 3 || maxAmount / minAmount >= 1.35
    }

    private func roundedMoney(_ value: Double) -> Double {
        (value * 100).rounded() / 100
    }

    private func estimatedCadenceDays(from dates: [Date]) -> Int {
        guard dates.count >= 2 else { return 30 }
        let calendar = Calendar.current
        let gaps = zip(dates.dropLast(), dates.dropFirst())
            .compactMap { start, end in
                calendar.dateComponents([.day], from: calendar.startOfDay(for: start), to: calendar.startOfDay(for: end)).day
            }
            .filter { $0 > 0 }
        guard !gaps.isEmpty else { return 30 }
        let sortedGaps = gaps.sorted()
        return sortedGaps[sortedGaps.count / 2]
    }

    private func estimatedMonthlyAmount(averageAmount: Double, cadenceDays: Int) -> Double {
        let multiplier: Double
        switch cadenceDays {
        case 1...10:
            multiplier = 30.0 / Double(cadenceDays)
        case 11...20:
            multiplier = 2.17
        case 21...45:
            multiplier = 1
        case 46...75:
            multiplier = 0.5
        default:
            multiplier = 1
        }
        return (averageAmount * multiplier * 100).rounded() / 100
    }

    private func cadenceLabel(for days: Int) -> String {
        switch days {
        case 1...10:
            return "Every \(days) days"
        case 11...20:
            return "Biweekly"
        case 21...45:
            return "Monthly"
        case 46...75:
            return "Every 2 months"
        default:
            return "Recurring"
        }
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

    private func replaceRecurringCharges(with aiSubscriptions: [SubscriptionItem]) {
        data.subscriptions = aiSubscriptions
            .filter { $0.source == .ai }
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
        data.subscriptions.removeAll { $0.source != .ai }

        if before != data.subscriptions.count {
            recordDiagnostic("Removed \(before - data.subscriptions.count) legacy local recurring guess(es).")
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

    private static func bundledOpenAIAPIKey() -> String? {
        #if HAS_LOCAL_SECRETS
        let trimmed = LocalSecrets.openAIAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
        #else
        return nil
        #endif
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
                clearDerivedDataForFreshCore()
            }
            save()
        }
    }
}

private struct RecurringEstimate {
    var monthlyAmount: Double
    var averageAmount: Double
    var lastAmount: Double
    var cadenceDays: Int
    var frequency: String
}

private struct RecurringTransactionStream {
    var idSuffix: String?
    var transactions: [FinanceTransaction]
    var estimate: RecurringEstimate
    var confidenceLabel: String
    var displayName: String?
    var recurringKind: RecurringChargeKind
    var category: TransactionCategory
    var note: String?
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
