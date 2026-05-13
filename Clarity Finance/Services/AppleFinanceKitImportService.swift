import Foundation

struct AppleFinanceKitImportResult {
    var accounts: [FinancialAccount]
    var creditCardLiabilities: [CreditCardLiability]
    var transactions: [FinanceTransaction]
}

enum AppleFinanceKitImportError: LocalizedError {
    case unavailable
    case missingEntitlement
    case notAuthorized
    case noAppleCardAccounts

    var errorDescription: String? {
        switch self {
        case .unavailable:
            "Apple Card direct access needs FinanceKit on an iPhone with iOS 17.4 or later. Apple must also approve the FinanceKit entitlement for this app."
        case .missingEntitlement:
            "Apple Card direct access is not enabled yet. Apple has to approve the FinanceKit entitlement before Clarity can connect Apple Card directly. Use Apple Card PDFs for now."
        case .notAuthorized:
            "Apple Card access was not allowed. Open the prompt again and choose the Wallet accounts Clarity can read."
        case .noAppleCardAccounts:
            "FinanceKit did not return an Apple Card account. If your Apple Card is not available yet, use Apple Card PDFs for now."
        }
    }
}

#if canImport(FinanceKit) && os(iOS)
import FinanceKit

enum AppleFinanceKitImportService {
    static func importAppleCardData() async throws -> AppleFinanceKitImportResult {
        guard #available(iOS 17.4, *) else {
            throw AppleFinanceKitImportError.unavailable
        }

        guard hasFinanceKitEntitlement() else {
            throw AppleFinanceKitImportError.missingEntitlement
        }

        guard FinanceKit.FinanceStore.isDataAvailable(.financialData) else {
            throw AppleFinanceKitImportError.unavailable
        }

        let store = FinanceKit.FinanceStore.shared
        let status = try await store.authorizationStatus()
        let finalStatus = status == .notDetermined ? try await store.requestAuthorization() : status

        guard finalStatus == .authorized else {
            throw AppleFinanceKitImportError.notAuthorized
        }

        let walletAccounts = try await store.accounts(query: AccountQuery())
        let accountBalances = try await store.accountBalances(query: AccountBalanceQuery())
        let walletTransactions = try await store.transactions(query: TransactionQuery())

        let liabilityAccounts = walletAccounts.compactMap { account -> LiabilityAccount? in
            guard case .liability(let liability) = account else { return nil }
            return liability
        }

        let appleCardAccounts = liabilityAccounts.filter { liability in
            let searchableText = [
                liability.displayName,
                liability.accountDescription ?? "",
                liability.institutionName
            ].joined(separator: " ").lowercased()

            return searchableText.contains("apple") || searchableText.contains("card")
        }

        guard !appleCardAccounts.isEmpty else {
            throw AppleFinanceKitImportError.noAppleCardAccounts
        }

        let balancesByAccountID = Dictionary(uniqueKeysWithValues: accountBalances.map { ($0.accountID, $0) })
        let importedAccountIDs = Set(appleCardAccounts.map(\.id))

        let accounts = appleCardAccounts.map { liability -> FinancialAccount in
            let balance = balancesByAccountID[liability.id]
            return FinancialAccount(
                id: appAccountID(for: liability.id),
                institutionName: liability.institutionName,
                name: liability.displayName,
                mask: nil,
                kind: .creditCard,
                currentBalance: abs(balance?.bookedAmount ?? balance?.availableAmount ?? 0),
                availableBalance: balance?.availableAmount.map(abs),
                creditLimit: liability.creditInformation.creditLimit?.doubleValue,
                currencyCode: liability.currencyCode,
                isManual: false
            )
        }

        let liabilities = appleCardAccounts.map { liability in
            CreditCardLiability(
                accountID: appAccountID(for: liability.id),
                minimumPaymentAmount: liability.creditInformation.minimumNextPaymentAmount?.doubleValue,
                nextPaymentDueDate: liability.creditInformation.nextPaymentDueDate,
                lastPaymentAmount: nil,
                lastPaymentDate: nil,
                lastStatementBalance: balancesByAccountID[liability.id]?.bookedAmount.map(abs),
                lastStatementIssueDate: nil,
                isOverdue: (liability.creditInformation.overduePaymentAmount?.doubleValue ?? 0) > 0,
                aprPercentage: nil,
                updatedAt: Date()
            )
        }

        let transactions = walletTransactions.compactMap { transaction -> FinanceTransaction? in
            guard importedAccountIDs.contains(transaction.accountID) else { return nil }
            guard transaction.status != .rejected else { return nil }

            let merchant = bestMerchantName(for: transaction)
            let absoluteAmount = abs(transaction.transactionAmount.doubleValue)
            let amount = transaction.creditDebitIndicator == .debit ? absoluteAmount : -absoluteAmount

            return FinanceTransaction(
                id: "financekit-\(transaction.id.uuidString)",
                accountID: appAccountID(for: transaction.accountID),
                merchantName: merchant,
                originalName: transaction.originalTransactionDescription,
                amount: amount,
                date: transaction.postedDate ?? transaction.transactionDate,
                category: category(for: merchant, originalName: transaction.originalTransactionDescription, isIncome: transaction.creditDebitIndicator == .credit),
                pending: transaction.status != .booked,
                source: "Apple FinanceKit"
            )
        }

        return AppleFinanceKitImportResult(
            accounts: accounts,
            creditCardLiabilities: liabilities,
            transactions: transactions
        )
    }

    private static func appAccountID(for id: UUID) -> String {
        "financekit-\(id.uuidString)"
    }

    private static func hasFinanceKitEntitlement() -> Bool {
        // FinanceKit will fail before normal authorization if Apple has not approved
        // the private entitlement for this bundle. Flip this only after
        // com.apple.developer.financekit is present in the app's entitlements.
        false
    }

    @available(iOS 17.4, *)
    private static func bestMerchantName(for transaction: Transaction) -> String {
        if let merchantName = transaction.merchantName?.trimmingCharacters(in: .whitespacesAndNewlines),
           !merchantName.isEmpty {
            return merchantName
        }

        let description = transaction.transactionDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        if !description.isEmpty {
            return description
        }

        return transaction.originalTransactionDescription
    }

    private static func category(for merchant: String, originalName: String, isIncome: Bool) -> TransactionCategory {
        if isIncome {
            return .income
        }

        let text = "\(merchant) \(originalName)".lowercased()
        if text.contains("netflix") || text.contains("spotify") || text.contains("hulu") || text.contains("apple.com/bill") || text.contains("google") || text.contains("openai") {
            return .subscriptions
        }
        if text.contains("restaurant") || text.contains("coffee") || text.contains("starbucks") || text.contains("doordash") || text.contains("uber eats") || text.contains("mcdonald") {
            return .food
        }
        if text.contains("gas") || text.contains("uber") || text.contains("lyft") || text.contains("shell") || text.contains("chevron") || text.contains("arco") {
            return .transport
        }
        if text.contains("target") || text.contains("amazon") || text.contains("walmart") || text.contains("shop") {
            return .shopping
        }
        if text.contains("pg&e") || text.contains("utility") || text.contains("electric") || text.contains("water") || text.contains("internet") {
            return .utilities
        }
        if text.contains("rent") || text.contains("mortgage") {
            return .housing
        }
        if text.contains("pharmacy") || text.contains("medical") || text.contains("doctor") || text.contains("health") {
            return .health
        }
        if text.contains("transfer") || text.contains("payment") {
            return .transfer
        }
        return .other
    }
}

@available(iOS 17.4, *)
private extension AccountBalance {
    var availableAmount: Double? {
        available?.amount.doubleValue
    }

    var bookedAmount: Double? {
        booked?.amount.doubleValue
    }
}

@available(iOS 17.4, *)
private extension CurrencyAmount {
    var doubleValue: Double {
        NSDecimalNumber(decimal: amount).doubleValue
    }
}
#else
enum AppleFinanceKitImportService {
    static func importAppleCardData() async throws -> AppleFinanceKitImportResult {
        throw AppleFinanceKitImportError.unavailable
    }
}
#endif
