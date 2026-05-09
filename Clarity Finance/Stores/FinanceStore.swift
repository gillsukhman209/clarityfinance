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
            productionSecret: (try? KeychainStore.read(account: "plaid-production-secret")) ?? PlaidCredentials.bundledSandbox.productionSecret
        )

        removeLegacySampleDataIfNeeded()
        rebuildBudgets()
        rebuildSubscriptions()
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
        filteredTransactions.monthlyExpenseTotal
    }

    var hasFinancialData: Bool {
        !filteredAccounts.isEmpty || !filteredTransactions.isEmpty || !data.connections.isEmpty
    }

    var incomeThisMonth: Double {
        let calendar = Calendar.current
        return filteredTransactions
            .filter { $0.isIncome && calendar.isDate($0.date, equalTo: Date(), toGranularity: .month) }
            .reduce(0) { $0 + abs($1.amount) }
    }

    var monthlyChartValues: [Double] {
        let calendar = Calendar.current
        let now = Date()
        let currentMonthTransactions = filteredTransactions.filter {
            !$0.isIncome && calendar.isDate($0.date, equalTo: now, toGranularity: .month)
        }

        return stride(from: 0, through: 5, by: 1).map { index in
            let upperDay = max(1, Int(Double(index + 1) * 31.0 / 6.0))
            return currentMonthTransactions
                .filter { calendar.component(.day, from: $0.date) <= upperDay }
                .reduce(0) { $0 + abs($1.amount) }
        }
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
        guard !selectedAccountIDs.isEmpty else { return data.subscriptions }
        return data.subscriptions.filter { subscription in
            guard let accountID = subscription.accountID else { return false }
            return selectedAccountIDs.contains(accountID)
        }
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

    func saveCredentials(clientID: String, sandboxSecret: String, productionSecret: String) {
        recordDiagnostic("Saving Plaid credentials. clientID set=\(!clientID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty), sandbox secret set=\(!sandboxSecret.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty), production secret set=\(!productionSecret.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty).")

        credentials = PlaidCredentials(
            clientID: clientID,
            sandboxSecret: sandboxSecret,
            productionSecret: productionSecret
        )

        do {
            try KeychainStore.save(clientID, account: "plaid-client-id")
            try KeychainStore.save(sandboxSecret, account: "plaid-sandbox-secret")
            try KeychainStore.save(productionSecret, account: "plaid-production-secret")
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
            let sync = try await plaidClient.syncTransactions(credentials: credentials, connection: connection, environment: .sandbox)
            connection.cursor = sync.nextCursor
            connection.lastSyncedAt = Date()

            data.connections.append(connection)
            upsert(accounts: accounts)
            upsert(transactions: sync.transactions)
            removeTransactions(ids: sync.removedTransactionIDs)
            rebuildDerivedData()
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
        statusMessage = "Syncing Plaid data..."
        lastErrorMessage = nil

        do {
            for index in data.connections.indices {
                var connection = data.connections[index]
                let environment = environment(for: connection)
                try? await plaidClient.refreshTransactions(credentials: credentials, connection: connection, environment: environment)
                let accounts = try await plaidClient.fetchAccounts(credentials: credentials, connection: connection, environment: environment)
                let sync = try await plaidClient.syncTransactions(credentials: credentials, connection: connection, environment: environment)
                connection.cursor = sync.nextCursor
                connection.lastSyncedAt = Date()
                data.connections[index] = connection
                upsert(accounts: accounts)
                upsert(transactions: sync.transactions)
                removeTransactions(ids: sync.removedTransactionIDs)
            }

            rebuildDerivedData()
            save()
            statusMessage = "Plaid data is up to date."
        } catch {
            lastErrorMessage = error.localizedDescription
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
        statusMessage = "Creating a Plaid bank link..."
        lastErrorMessage = nil
        hostedLinkSession = nil
        recordDiagnostic("Calling Plaid /link/token/create in Production.")

        do {
            let hostedSession = try await plaidClient.createHostedLinkSession(
                credentials: credentials,
                environment: .production
            )

            hostedLinkSession = hostedSession
            statusMessage = "Plaid link is ready. Open it below, finish bank login, then return here to import."
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
            lastErrorMessage = "Create a Plaid link first, then finish the bank login in your browser."
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
            recordDiagnostic("Public token exchanged. institution=\(connection.institutionName), itemIDLength=\(connection.itemID.count). Fetching accounts.")
            let accounts = try await plaidClient.fetchAccounts(credentials: credentials, connection: connection, environment: .production)
            recordDiagnostic("Fetched \(accounts.count) account(s). Syncing transactions.")
            let sync = try await plaidClient.syncTransactions(credentials: credentials, connection: connection, environment: .production)
            recordDiagnostic("Synced transactions. addedOrModified=\(sync.transactions.count), removed=\(sync.removedTransactionIDs.count).")
            connection.cursor = sync.nextCursor
            connection.lastSyncedAt = Date()

            data.connections.append(connection)
            upsert(accounts: accounts)
            upsert(transactions: sync.transactions)
            removeTransactions(ids: sync.removedTransactionIDs)
            rebuildDerivedData()
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
            statusMessage = "Imported \(result.transactions.count) Apple Card PDF transactions."
            lastErrorMessage = nil
        } catch {
            lastErrorMessage = error.localizedDescription
        }
    }

    func clearLocalData() {
        data = .empty
        selectedAccountIDs = []
        save()
        statusMessage = "Cleared local financial data."
        lastErrorMessage = nil
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
            if let index = data.transactions.firstIndex(where: { $0.id == transaction.id }) {
                data.transactions[index] = transaction
            } else {
                data.transactions.append(transaction)
            }
        }
    }

    private func removeTransactions(ids: [String]) {
        guard !ids.isEmpty else { return }
        let removed = Set(ids)
        data.transactions.removeAll { removed.contains($0.id) }
    }

    private func rebuildDerivedData() {
        rebuildBudgets()
        rebuildSubscriptions()
        appendNetWorthSnapshot()
        recordDiagnostic("Derived data rebuilt. budgets=\(data.budgets.count), subscriptions=\(data.subscriptions.count), netWorthSnapshots=\(data.netWorthSnapshots.count).")
    }

    private func environment(for connection: PlaidConnection) -> PlaidEnvironment {
        connection.accessToken.contains("access-production") ? .production : .sandbox
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

    private func rebuildSubscriptions() {
        let candidates = data.transactions.filter { !$0.isIncome }
        let grouped = Dictionary(grouping: candidates) { transaction in
            "\(transaction.accountID)|\(Self.normalizedMerchantName(transaction.merchantName))"
        }

        let inferred = grouped.compactMap { _, transactions -> SubscriptionItem? in
            let sorted = transactions.sorted { $0.date < $1.date }
            guard let last = sorted.last else { return nil }
            let hasSubscriptionSignal = sorted.contains { transaction in
                transaction.category == .subscriptions || Self.looksLikeSubscriptionMerchant(transaction.merchantName)
            }
            let cadenceDays = Self.recurringCadenceDays(from: sorted)
            let hasRecurringPattern = cadenceDays != nil
            guard hasRecurringPattern || hasSubscriptionSignal else { return nil }

            let averageCharge = sorted.reduce(0) { $0 + abs($1.amount) } / Double(sorted.count)
            guard averageCharge <= 500 || hasRecurringPattern else { return nil }
            let monthlyAmount = Self.monthlyEquivalentAmount(averageCharge: averageCharge, cadenceDays: cadenceDays)

            let nextDate = Self.nextExpectedDate(from: sorted)
            let merchantKey = Self.normalizedMerchantName(last.merchantName)
            return SubscriptionItem(
                id: "sub-\(last.accountID)-\(merchantKey)",
                merchantName: last.merchantName,
                category: last.category == .other ? .subscriptions : last.category,
                monthlyAmount: monthlyAmount,
                nextExpectedDate: nextDate,
                accountID: last.accountID
            )
        }

        data.subscriptions = inferred.sorted { $0.monthlyAmount > $1.monthlyAmount }
    }

    private static func hasRecurringPattern(_ transactions: [FinanceTransaction]) -> Bool {
        recurringCadenceDays(from: transactions) != nil
    }

    private static func recurringCadenceDays(from transactions: [FinanceTransaction]) -> Int? {
        guard transactions.count >= 2 else { return nil }
        guard amountsAreSimilar(transactions) else { return nil }

        let sorted = transactions.sorted { $0.date < $1.date }
        let intervals = zip(sorted, sorted.dropFirst()).map {
            Calendar.current.dateComponents([.day], from: $0.date, to: $1.date).day ?? 0
        }
        guard !intervals.isEmpty else { return nil }

        return intervals.reversed().first { interval in
            (6...8).contains(interval) ||
                (13...16).contains(interval) ||
                (26...35).contains(interval) ||
                (80...100).contains(interval) ||
                (350...380).contains(interval)
        }
    }

    private static func amountsAreSimilar(_ transactions: [FinanceTransaction]) -> Bool {
        let amounts = transactions.map { abs($0.amount) }
        guard let minimumAmount = amounts.min(), let maximumAmount = amounts.max(), maximumAmount > 0 else { return false }
        let tolerance = Swift.max(2.0, maximumAmount * 0.18)
        return maximumAmount - minimumAmount <= tolerance
    }

    private static func nextExpectedDate(from transactions: [FinanceTransaction]) -> Date {
        let sorted = transactions.sorted { $0.date < $1.date }
        guard let last = sorted.last else { return .daysFromNow(30) }

        let cadenceDays = recurringCadenceDays(from: sorted) ?? 30
        return Calendar.current.date(byAdding: .day, value: cadenceDays, to: last.date) ?? .daysFromNow(30)
    }

    private static func monthlyEquivalentAmount(averageCharge: Double, cadenceDays: Int?) -> Double {
        guard let cadenceDays, cadenceDays > 0 else { return averageCharge }
        return averageCharge * (30.4375 / Double(cadenceDays))
    }

    private static func normalizedMerchantName(_ merchantName: String) -> String {
        merchantName
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: "-")
    }

    private static func looksLikeSubscriptionMerchant(_ merchantName: String) -> Bool {
        let lowercased = merchantName.lowercased()
        let keywords = [
            "apple", "netflix", "spotify", "hulu", "disney", "max", "peacock",
            "youtube", "google", "amazon prime", "icloud", "dropbox", "adobe",
            "microsoft", "notion", "openai", "chatgpt", "github", "patreon",
            "substack", "nyt", "new york times", "wsj", "wall street journal",
            "paramount", "sirius", "audible", "kindle", "canva", "figma",
            "grammarly", "superhuman", "setapp", "zoom", "slack", "discord",
            "recurring", "subscription", "membership", "monthly", "annual"
        ]
        return keywords.contains { lowercased.contains($0) }
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
