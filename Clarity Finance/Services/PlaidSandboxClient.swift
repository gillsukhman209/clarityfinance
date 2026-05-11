import Foundation

struct PlaidCredentials: Equatable {
    var clientID: String
    var sandboxSecret: String
    var productionSecret: String
    var linkCustomizationName: String

    static let bundledSandbox = PlaidCredentials(
        clientID: "",
        sandboxSecret: "",
        productionSecret: "",
        linkCustomizationName: ""
    )

    var isSandboxComplete: Bool {
        !clientID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !sandboxSecret.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var isProductionComplete: Bool {
        !clientID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !productionSecret.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var normalizedLinkCustomizationName: String? {
        let trimmed = linkCustomizationName.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

enum PlaidEnvironment: String, Codable {
    case sandbox
    case production

    var baseURL: URL {
        switch self {
        case .sandbox:
            URL(string: "https://sandbox.plaid.com")!
        case .production:
            URL(string: "https://production.plaid.com")!
        }
    }

    var displayName: String {
        switch self {
        case .sandbox: "Plaid Sandbox"
        case .production: "Plaid Production"
        }
    }

    var transactionSource: String {
        switch self {
        case .sandbox: "Plaid Sandbox"
        case .production: "Plaid"
        }
    }

    func secret(from credentials: PlaidCredentials) -> String {
        switch self {
        case .sandbox:
            credentials.sandboxSecret
        case .production:
            credentials.productionSecret
        }
    }
}

struct PlaidSandboxClient {
    static let requestedTransactionHistoryDays = 730

    private let session: URLSession

    init(session: URLSession = PlaidSandboxClient.makeSession()) {
        self.session = session
    }

    private static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 45
        return URLSession(configuration: configuration)
    }

    func createSandboxConnection(
        credentials: PlaidCredentials,
        institution: PlaidSandboxInstitution,
        profile: PlaidSandboxProfile
    ) async throws -> PlaidConnection {
        let publicToken = try await post(
            path: "/sandbox/public_token/create",
            body: SandboxPublicTokenRequest(
                clientID: credentials.clientID,
                secret: PlaidEnvironment.sandbox.secret(from: credentials),
                institutionID: institution.id,
                initialProducts: ["transactions"],
                options: SandboxPublicTokenOptions(
                    overrideUsername: profile.username,
                    overridePassword: profile.password,
                    transactions: SandboxPublicTokenTransactionsOptions(daysRequested: Self.requestedTransactionHistoryDays)
                )
            ),
            response: SandboxPublicTokenResponse.self,
            environment: .sandbox
        ).publicToken

        let exchange = try await post(
            path: "/item/public_token/exchange",
            body: PublicTokenExchangeRequest(
                clientID: credentials.clientID,
                secret: PlaidEnvironment.sandbox.secret(from: credentials),
                publicToken: publicToken
            ),
            response: PublicTokenExchangeResponse.self,
            environment: .sandbox
        )

        return PlaidConnection(
            id: UUID().uuidString,
            itemID: exchange.itemID,
            institutionID: institution.id,
            institutionName: institution.name,
            accessToken: exchange.accessToken,
            environment: .sandbox,
            cursor: nil,
            connectedAt: Date(),
            lastSyncedAt: nil
        )
    }

    func fetchAccounts(
        credentials: PlaidCredentials,
        connection: PlaidConnection,
        environment: PlaidEnvironment
    ) async throws -> [FinancialAccount] {
        let response = try await post(
            path: "/accounts/get",
            body: TokenRequest(
                clientID: credentials.clientID,
                secret: environment.secret(from: credentials),
                accessToken: connection.accessToken
            ),
            response: AccountsResponse.self,
            environment: environment
        )

        return response.accounts.map { account in
            FinancialAccount(
                id: account.accountID,
                institutionName: connection.institutionName,
                name: account.name,
                mask: account.mask,
                kind: account.accountKind,
                currentBalance: account.balances.current ?? 0,
                availableBalance: account.balances.available,
                currencyCode: account.balances.isoCurrencyCode ?? "USD",
                isManual: false
            )
        }
    }

    func syncTransactions(
        credentials: PlaidCredentials,
        connection: PlaidConnection,
        environment: PlaidEnvironment
    ) async throws -> PlaidSyncResult {
        var cursor = connection.cursor
        var allTransactions: [FinanceTransaction] = []
        var allRemovedTransactionIDs: [String] = []
        var hasMore = true

        while hasMore {
            let response = try await post(
                path: "/transactions/sync",
                body: TransactionsSyncRequest(
                    clientID: credentials.clientID,
                    secret: environment.secret(from: credentials),
                    accessToken: connection.accessToken,
                    cursor: cursor,
                    count: 500,
                    options: TransactionsSyncOptions(daysRequested: Self.requestedTransactionHistoryDays)
                ),
                response: TransactionsSyncResponse.self,
                environment: environment
            )

            allTransactions.append(contentsOf: response.added.map { $0.financeTransaction(source: environment.transactionSource) })
            allTransactions.append(contentsOf: response.modified.map { $0.financeTransaction(source: environment.transactionSource) })
            allRemovedTransactionIDs.append(contentsOf: response.removed.map(\.transactionID))
            cursor = response.nextCursor
            hasMore = response.hasMore
        }

        return PlaidSyncResult(
            transactions: allTransactions,
            removedTransactionIDs: allRemovedTransactionIDs,
            nextCursor: cursor
        )
    }

    func refreshTransactions(
        credentials: PlaidCredentials,
        connection: PlaidConnection,
        environment: PlaidEnvironment
    ) async throws {
        _ = try await post(
            path: "/transactions/refresh",
            body: TokenRequest(
                clientID: credentials.clientID,
                secret: environment.secret(from: credentials),
                accessToken: connection.accessToken
            ),
            response: EmptyPlaidResponse.self,
            environment: environment
        )
    }

    func fetchRecurringSubscriptions(
        credentials: PlaidCredentials,
        connection: PlaidConnection,
        environment: PlaidEnvironment
    ) async throws -> PlaidRecurringFetchResult {
        let response = try await post(
            path: "/transactions/recurring/get",
            body: RecurringTransactionsRequest(
                clientID: credentials.clientID,
                secret: environment.secret(from: credentials),
                accessToken: connection.accessToken,
                options: RecurringTransactionsOptions(personalFinanceCategoryVersion: "v2")
            ),
            response: RecurringTransactionsResponse.self,
            environment: environment
        )

        let mapped = response.outflowStreams.compactMap(\.subscriptionItem)
        let dropped = response.outflowStreams.compactMap(\.dropReason)

        return PlaidRecurringFetchResult(
            items: mapped,
            rawOutflowCount: response.outflowStreams.count,
            mappedCount: mapped.count,
            droppedSummaries: dropped,
            streamSummaries: response.outflowStreams.map(\.diagnosticSummary)
        )
    }

    func createHostedLinkSession(
        credentials: PlaidCredentials,
        environment: PlaidEnvironment
    ) async throws -> PlaidHostedLinkSession {
        let response = try await post(
            path: "/link/token/create",
            body: LinkTokenCreateRequest(
                clientID: credentials.clientID,
                secret: environment.secret(from: credentials),
                clientName: "Clarity Finance",
                products: ["transactions"],
                countryCodes: ["US"],
                language: "en",
                user: LinkTokenUser(clientUserID: "local-owner"),
                linkCustomizationName: credentials.normalizedLinkCustomizationName,
                transactions: LinkTokenTransactionsOptions(daysRequested: Self.requestedTransactionHistoryDays),
                redirectURI: nil,
                hostedLink: HostedLinkCreateOptions(
                    completionRedirectURI: nil,
                    isMobileApp: false,
                    urlLifetimeSeconds: 1800
                )
            ),
            response: LinkTokenCreateResponse.self,
            environment: environment
        )

        return PlaidHostedLinkSession(
            linkToken: response.linkToken,
            hostedLinkURL: response.hostedLinkURL
        )
    }

    func createHostedLinkSession(
        authSession: SupabaseAuthSession,
        linkCustomizationName: String?,
        environment: PlaidEnvironment
    ) async throws -> PlaidHostedLinkSession {
        let response = try await postBackend(
            path: "/api/plaid/link/token/create",
            body: BackendLinkTokenCreateRequest(
                environment: environment.rawValue,
                linkCustomizationName: linkCustomizationName
            ),
            response: LinkTokenCreateResponse.self,
            authSession: authSession
        )

        return PlaidHostedLinkSession(
            linkToken: response.linkToken,
            hostedLinkURL: response.hostedLinkURL
        )
    }

    func fetchHostedLinkPublicTokens(
        credentials: PlaidCredentials,
        linkToken: String,
        environment: PlaidEnvironment
    ) async throws -> [PlaidHostedPublicToken] {
        let response = try await post(
            path: "/link/token/get",
            body: LinkTokenGetRequest(
                clientID: credentials.clientID,
                secret: environment.secret(from: credentials),
                linkToken: linkToken
            ),
            response: LinkTokenGetResponse.self,
            environment: environment
        )

        return response.publicTokens
    }

    func fetchHostedLinkPublicTokens(
        authSession: SupabaseAuthSession,
        linkToken: String,
        environment: PlaidEnvironment
    ) async throws -> [PlaidHostedPublicToken] {
        let response = try await postBackend(
            path: "/api/plaid/link/token/get",
            body: BackendLinkTokenGetRequest(
                environment: environment.rawValue,
                linkToken: linkToken
            ),
            response: LinkTokenGetResponse.self,
            authSession: authSession
        )

        return response.publicTokens
    }

    func exchangePublicToken(
        credentials: PlaidCredentials,
        publicToken: PlaidHostedPublicToken,
        environment: PlaidEnvironment
    ) async throws -> PlaidConnection {
        let exchange = try await post(
            path: "/item/public_token/exchange",
            body: PublicTokenExchangeRequest(
                clientID: credentials.clientID,
                secret: environment.secret(from: credentials),
                publicToken: publicToken.publicToken
            ),
            response: PublicTokenExchangeResponse.self,
            environment: environment
        )

        return PlaidConnection(
            id: UUID().uuidString,
            itemID: exchange.itemID,
            institutionID: publicToken.institutionID ?? "linked-institution",
            institutionName: publicToken.institutionName ?? "Linked Bank",
            accessToken: exchange.accessToken,
            environment: environment,
            cursor: nil,
            connectedAt: Date(),
            lastSyncedAt: nil
        )
    }

    func exchangePublicToken(
        authSession: SupabaseAuthSession,
        publicToken: PlaidHostedPublicToken,
        environment: PlaidEnvironment
    ) async throws -> PlaidConnection {
        let exchange = try await postBackend(
            path: "/api/plaid/item/public_token/exchange",
            body: BackendPublicTokenExchangeRequest(
                environment: environment.rawValue,
                publicToken: publicToken.publicToken,
                institutionID: publicToken.institutionID,
                institutionName: publicToken.institutionName
            ),
            response: PublicTokenExchangeResponse.self,
            authSession: authSession
        )

        return PlaidConnection(
            id: UUID().uuidString,
            itemID: exchange.itemID,
            institutionID: publicToken.institutionID ?? "linked-institution",
            institutionName: publicToken.institutionName ?? "Linked Bank",
            accessToken: exchange.accessToken,
            environment: environment,
            cursor: nil,
            connectedAt: Date(),
            lastSyncedAt: nil
        )
    }

    func fetchAccounts(
        authSession: SupabaseAuthSession,
        connection: PlaidConnection
    ) async throws -> [FinancialAccount] {
        let response = try await postBackend(
            path: "/api/plaid/accounts/get",
            body: BackendItemRequest(itemID: connection.itemID, cursor: nil),
            response: AccountsResponse.self,
            authSession: authSession
        )

        return response.accounts.map { account in
            FinancialAccount(
                id: account.accountID,
                institutionName: connection.institutionName,
                name: account.name,
                mask: account.mask,
                kind: account.accountKind,
                currentBalance: account.balances.current ?? 0,
                availableBalance: account.balances.available,
                currencyCode: account.balances.isoCurrencyCode ?? "USD",
                isManual: false
            )
        }
    }

    func syncTransactions(
        authSession: SupabaseAuthSession,
        connection: PlaidConnection
    ) async throws -> PlaidSyncResult {
        let response = try await postBackend(
            path: "/api/plaid/transactions/sync",
            body: BackendItemRequest(itemID: connection.itemID, cursor: connection.cursor),
            response: TransactionsSyncResponse.self,
            authSession: authSession
        )

        let source = connection.environment.transactionSource
        return PlaidSyncResult(
            transactions: (response.added + response.modified).map { $0.financeTransaction(source: source) },
            removedTransactionIDs: response.removed.map(\.transactionID),
            nextCursor: response.nextCursor
        )
    }

    func refreshTransactions(
        authSession: SupabaseAuthSession,
        connection: PlaidConnection
    ) async throws {
        _ = try await postBackend(
            path: "/api/plaid/transactions/refresh",
            body: BackendItemRequest(itemID: connection.itemID, cursor: nil),
            response: EmptyPlaidResponse.self,
            authSession: authSession
        )
    }

    func restoreBackendSnapshot(authSession: SupabaseAuthSession) async throws -> BackendFinanceSnapshot {
        let response = try await postBackend(
            path: "/api/plaid/data/snapshot",
            body: EmptyBackendRequest(),
            response: BackendSnapshotResponse.self,
            authSession: authSession
        )

        return response.snapshot
    }

    func removeBackendAccount(authSession: SupabaseAuthSession, accountID: String) async throws {
        _ = try await postBackend(
            path: "/api/plaid/accounts/remove",
            body: BackendAccountRemoveRequest(accountID: accountID),
            response: EmptyBackendResponse.self,
            authSession: authSession
        )
    }

    private func post<RequestBody: Encodable, ResponseBody: Decodable>(
        path: String,
        body: RequestBody,
        response: ResponseBody.Type,
        environment: PlaidEnvironment
    ) async throws -> ResponseBody {
        var request = URLRequest(url: environment.baseURL.appending(path: path))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder.plaid.encode(body)

        let (data, urlResponse) = try await session.data(for: request)
        guard let httpResponse = urlResponse as? HTTPURLResponse else {
            throw PlaidError.invalidResponse
        }

        guard (200..<300).contains(httpResponse.statusCode) else {
            let error = try? JSONDecoder.plaid.decode(PlaidAPIError.self, from: data)
            throw PlaidError.api(error?.errorMessage ?? "Plaid returned HTTP \(httpResponse.statusCode).")
        }

        do {
            return try JSONDecoder.plaid.decode(ResponseBody.self, from: data)
        } catch {
            let keys = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?.keys.sorted().joined(separator: ", ") ?? "unknown"
            throw PlaidError.api("Plaid response could not be decoded for \(path). Top-level keys: \(keys). Decode error: \(error.localizedDescription)")
        }
    }

    private func postBackend<RequestBody: Encodable, ResponseBody: Decodable>(
        path: String,
        body: RequestBody,
        response: ResponseBody.Type,
        authSession: SupabaseAuthSession
    ) async throws -> ResponseBody {
        guard let url = URL(string: "https://clarityfinance-gilt.vercel.app" + path) else {
            throw PlaidError.invalidResponse
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(authSession.accessToken)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONEncoder.plaid.encode(body)

        let (data, urlResponse) = try await session.data(for: request)
        guard let httpResponse = urlResponse as? HTTPURLResponse else {
            throw PlaidError.invalidResponse
        }

        guard (200..<300).contains(httpResponse.statusCode) else {
            let message = (try? JSONDecoder().decode(BackendPlaidError.self, from: data).message)
                ?? (String(data: data, encoding: .utf8) ?? "Backend returned HTTP \(httpResponse.statusCode).")
            throw PlaidError.api(message)
        }

        do {
            return try JSONDecoder.plaid.decode(ResponseBody.self, from: data)
        } catch {
            let keys = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?.keys.sorted().joined(separator: ", ") ?? "unknown"
            throw PlaidError.api("Backend Plaid response could not be decoded for \(path). Top-level keys: \(keys). Decode error: \(error.localizedDescription)")
        }
    }
}

struct PlaidRecurringFetchResult {
    var items: [SubscriptionItem]
    var rawOutflowCount: Int
    var mappedCount: Int
    var droppedSummaries: [String]
    var streamSummaries: [String]
}

struct PlaidSyncResult {
    var transactions: [FinanceTransaction]
    var removedTransactionIDs: [String]
    var nextCursor: String?
}

struct PlaidHostedLinkSession {
    var linkToken: String
    var hostedLinkURL: URL
}

struct PlaidHostedPublicToken {
    var publicToken: String
    var institutionID: String?
    var institutionName: String?
}

private extension JSONEncoder {
    static var plaid: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        return encoder
    }
}

private extension JSONDecoder {
    static var plaid: JSONDecoder {
        JSONDecoder()
    }
}

private extension String {
    var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

enum PlaidError: LocalizedError {
    case invalidResponse
    case api(String)

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            "Plaid returned an invalid response."
        case .api(let message):
            message
        }
    }
}

private struct PlaidAPIError: Decodable {
    var errorMessage: String

    enum CodingKeys: String, CodingKey {
        case errorMessage = "error_message"
    }
}

private struct BackendPlaidError: Decodable {
    var error: String?
    var message: String {
        error ?? "Backend Plaid request failed."
    }
}

private struct EmptyPlaidResponse: Decodable {}

private struct EmptyBackendRequest: Encodable {}

private struct EmptyBackendResponse: Decodable {}

struct BackendFinanceSnapshot {
    var connections: [PlaidConnection]
    var accounts: [FinancialAccount]
    var transactions: [FinanceTransaction]
    var removedAccountIDs: Set<String>
}

private struct BackendSnapshotResponse: Decodable {
    var connections: [BackendConnection]
    var accounts: [BackendAccount]
    var transactions: [BackendTransaction]
    var removedAccountIDs: [String]

    enum CodingKeys: String, CodingKey {
        case connections
        case accounts
        case transactions
        case removedAccountIDs = "removed_account_ids"
    }

    var snapshot: BackendFinanceSnapshot {
        BackendFinanceSnapshot(
            connections: connections.map(\.connection),
            accounts: accounts.map(\.account),
            transactions: transactions.map(\.transaction),
            removedAccountIDs: Set(removedAccountIDs)
        )
    }
}

private struct BackendConnection: Decodable {
    var id: String
    var itemID: String
    var institutionID: String
    var institutionName: String
    var accessToken: String
    var environment: PlaidEnvironment
    var cursor: String?
    var connectedAt: String?
    var lastSyncedAt: String?

    var connection: PlaidConnection {
        PlaidConnection(
            id: id,
            itemID: itemID,
            institutionID: institutionID,
            institutionName: institutionName,
            accessToken: accessToken,
            environment: environment,
            cursor: cursor,
            connectedAt: Self.parseDate(connectedAt) ?? Date(),
            lastSyncedAt: Self.parseDate(lastSyncedAt)
        )
    }

    private static func parseDate(_ value: String?) -> Date? {
        guard let value else { return nil }
        if let date = ISO8601DateFormatter().date(from: value) {
            return date
        }
        return BackendTransaction.dateFormatter.date(from: value)
    }
}

private struct BackendAccount: Decodable {
    var id: String
    var institutionName: String
    var name: String
    var mask: String?
    var kind: AccountKind
    var currentBalance: Double
    var availableBalance: Double?
    var currencyCode: String
    var isManual: Bool

    var account: FinancialAccount {
        FinancialAccount(
            id: id,
            institutionName: institutionName,
            name: name,
            mask: mask,
            kind: kind,
            currentBalance: currentBalance,
            availableBalance: availableBalance,
            currencyCode: currencyCode,
            isManual: isManual
        )
    }
}

private struct BackendTransaction: Decodable {
    var id: String
    var accountID: String
    var merchantName: String
    var originalName: String
    var amount: Double
    var date: String
    var category: String
    var pending: Bool
    var source: String

    var transaction: FinanceTransaction {
        FinanceTransaction(
            id: id,
            accountID: accountID,
            merchantName: MerchantNameCleaner.clean(merchantName),
            originalName: originalName,
            amount: amount,
            date: Self.dateFormatter.date(from: date) ?? Date(),
            category: resolvedCategory,
            pending: pending,
            source: source
        )
    }

    private var resolvedCategory: TransactionCategory {
        TransactionCategory(rawValue: category) ?? PlaidTransactionCategoryMapper.resolve(category)
    }

    static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter
    }()
}

private enum PlaidTransactionCategoryMapper {
    static func resolve(_ value: String) -> TransactionCategory {
        let text = value.lowercased()
        if text.contains("income") { return .income }
        if text.contains("subscription") || text.contains("digital") || text.contains("software") { return .subscriptions }
        if text.contains("food") || text.contains("restaurant") { return .food }
        if text.contains("transport") || text.contains("travel") || text.contains("gas") { return .transport }
        if text.contains("rent") || text.contains("home") { return .housing }
        if text.contains("entertainment") { return .entertainment }
        if text.contains("medical") || text.contains("health") { return .health }
        if text.contains("utility") { return .utilities }
        if text.contains("transfer") || text.contains("loan") { return .transfer }
        if text.contains("shop") || text.contains("merchandise") { return .shopping }
        return .other
    }
}

private struct BackendAccountRemoveRequest: Encodable {
    var accountID: String

    enum CodingKeys: String, CodingKey {
        case accountID = "account_id"
    }
}

private struct BackendLinkTokenCreateRequest: Encodable {
    var environment: String
    var linkCustomizationName: String?

    enum CodingKeys: String, CodingKey {
        case environment
        case linkCustomizationName = "link_customization_name"
    }
}

private struct BackendLinkTokenGetRequest: Encodable {
    var environment: String
    var linkToken: String

    enum CodingKeys: String, CodingKey {
        case environment
        case linkToken = "link_token"
    }
}

private struct BackendPublicTokenExchangeRequest: Encodable {
    var environment: String
    var publicToken: String
    var institutionID: String?
    var institutionName: String?

    enum CodingKeys: String, CodingKey {
        case environment
        case publicToken = "public_token"
        case institutionID = "institution_id"
        case institutionName = "institution_name"
    }
}

private struct BackendItemRequest: Encodable {
    var itemID: String
    var cursor: String?

    enum CodingKeys: String, CodingKey {
        case itemID = "item_id"
        case cursor
    }
}

private struct LinkTokenCreateRequest: Encodable {
    var clientID: String
    var secret: String
    var clientName: String
    var products: [String]
    var countryCodes: [String]
    var language: String
    var user: LinkTokenUser
    var linkCustomizationName: String?
    var transactions: LinkTokenTransactionsOptions
    var redirectURI: String?
    var hostedLink: HostedLinkCreateOptions

    enum CodingKeys: String, CodingKey {
        case clientID = "client_id"
        case secret
        case clientName = "client_name"
        case products
        case countryCodes = "country_codes"
        case language
        case user
        case linkCustomizationName = "link_customization_name"
        case transactions
        case redirectURI = "redirect_uri"
        case hostedLink = "hosted_link"
    }
}

private struct LinkTokenUser: Encodable {
    var clientUserID: String

    enum CodingKeys: String, CodingKey {
        case clientUserID = "client_user_id"
    }
}

private struct LinkTokenTransactionsOptions: Encodable {
    var daysRequested: Int

    enum CodingKeys: String, CodingKey {
        case daysRequested = "days_requested"
    }
}

private struct HostedLinkCreateOptions: Encodable {
    var completionRedirectURI: String?
    var isMobileApp: Bool
    var urlLifetimeSeconds: Int

    enum CodingKeys: String, CodingKey {
        case completionRedirectURI = "completion_redirect_uri"
        case isMobileApp = "is_mobile_app"
        case urlLifetimeSeconds = "url_lifetime_seconds"
    }
}

private struct LinkTokenCreateResponse: Decodable {
    var linkToken: String
    var hostedLinkURL: URL

    enum CodingKeys: String, CodingKey {
        case linkToken = "link_token"
        case hostedLinkURL = "hosted_link_url"
    }
}

private struct LinkTokenGetRequest: Encodable {
    var clientID: String
    var secret: String
    var linkToken: String

    enum CodingKeys: String, CodingKey {
        case clientID = "client_id"
        case secret
        case linkToken = "link_token"
    }
}

private struct LinkTokenGetResponse: Decodable {
    var linkSessions: [HostedLinkSessionStatus]

    enum CodingKeys: String, CodingKey {
        case linkSessions = "link_sessions"
    }

    var publicTokens: [PlaidHostedPublicToken] {
        linkSessions.flatMap(\.publicTokens)
    }
}

private struct HostedLinkSessionStatus: Decodable {
    var onSuccess: HostedLinkSuccess?
    var results: HostedLinkResults?

    enum CodingKeys: String, CodingKey {
        case onSuccess = "on_success"
        case results
    }

    var publicTokens: [PlaidHostedPublicToken] {
        let resultTokens = results?.itemAddResults.compactMap(\.publicTokenResult) ?? []
        if !resultTokens.isEmpty {
            return resultTokens
        }

        guard let success = onSuccess else {
            return []
        }

        return [
            PlaidHostedPublicToken(
                publicToken: success.publicToken,
                institutionID: success.metadata.institution.institutionID,
                institutionName: success.metadata.institution.name
            )
        ]
    }
}

private struct HostedLinkSuccess: Decodable {
    var publicToken: String
    var metadata: HostedLinkMetadata

    enum CodingKeys: String, CodingKey {
        case publicToken = "public_token"
        case metadata
    }
}

private struct HostedLinkResults: Decodable {
    var itemAddResults: [HostedLinkItemAddResult]

    enum CodingKeys: String, CodingKey {
        case itemAddResults = "item_add_results"
    }
}

private struct HostedLinkItemAddResult: Decodable {
    var publicToken: String?
    var institution: HostedLinkInstitution?

    enum CodingKeys: String, CodingKey {
        case publicToken = "public_token"
        case institution
    }

    var publicTokenResult: PlaidHostedPublicToken? {
        guard let publicToken else { return nil }
        return PlaidHostedPublicToken(
            publicToken: publicToken,
            institutionID: institution?.institutionID,
            institutionName: institution?.name
        )
    }
}

private struct HostedLinkMetadata: Decodable {
    var institution: HostedLinkInstitution
}

private struct HostedLinkInstitution: Decodable {
    var institutionID: String?
    var name: String?

    enum CodingKeys: String, CodingKey {
        case institutionID = "institution_id"
        case name
    }
}

private struct SandboxPublicTokenRequest: Encodable {
    var clientID: String
    var secret: String
    var institutionID: String
    var initialProducts: [String]
    var options: SandboxPublicTokenOptions

    enum CodingKeys: String, CodingKey {
        case clientID = "client_id"
        case secret
        case institutionID = "institution_id"
        case initialProducts = "initial_products"
        case options
    }
}

private struct SandboxPublicTokenOptions: Encodable {
    var overrideUsername: String
    var overridePassword: String
    var transactions: SandboxPublicTokenTransactionsOptions
}

private struct SandboxPublicTokenTransactionsOptions: Encodable {
    var daysRequested: Int

    enum CodingKeys: String, CodingKey {
        case daysRequested = "days_requested"
    }
}

private struct SandboxPublicTokenResponse: Decodable {
    var publicToken: String

    enum CodingKeys: String, CodingKey {
        case publicToken = "public_token"
    }
}

private struct PublicTokenExchangeRequest: Encodable {
    var clientID: String
    var secret: String
    var publicToken: String

    enum CodingKeys: String, CodingKey {
        case clientID = "client_id"
        case secret
        case publicToken = "public_token"
    }
}

private struct PublicTokenExchangeResponse: Decodable {
    var accessToken: String
    var itemID: String

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case itemID = "item_id"
    }
}

private struct TokenRequest: Encodable {
    var clientID: String
    var secret: String
    var accessToken: String

    enum CodingKeys: String, CodingKey {
        case clientID = "client_id"
        case secret
        case accessToken = "access_token"
    }
}

private struct AccountsResponse: Decodable {
    var accounts: [PlaidAccount]
}

private struct PlaidAccount: Decodable {
    var accountID: String
    var balances: PlaidBalances
    var mask: String?
    var name: String
    var type: String
    var subtype: String?

    enum CodingKeys: String, CodingKey {
        case accountID = "account_id"
        case balances
        case mask
        case name
        case type
        case subtype
    }

    var accountKind: AccountKind {
        switch (type, subtype) {
        case ("depository", "checking"):
            .checking
        case ("depository", "savings"):
            .savings
        case ("credit", _):
            .creditCard
        case ("investment", _), ("brokerage", _):
            .investment
        case ("loan", _):
            .loan
        default:
            .manual
        }
    }
}

private struct PlaidBalances: Decodable {
    var available: Double?
    var current: Double?
    var isoCurrencyCode: String?

    enum CodingKeys: String, CodingKey {
        case available
        case current
        case isoCurrencyCode = "iso_currency_code"
    }
}

private struct TransactionsSyncRequest: Encodable {
    var clientID: String
    var secret: String
    var accessToken: String
    var cursor: String?
    var count: Int
    var options: TransactionsSyncOptions

    enum CodingKeys: String, CodingKey {
        case clientID = "client_id"
        case secret
        case accessToken = "access_token"
        case cursor
        case count
        case options
    }
}

private struct TransactionsSyncOptions: Encodable {
    var daysRequested: Int
}

private struct TransactionsSyncResponse: Decodable {
    var added: [PlaidTransaction]
    var modified: [PlaidTransaction]
    var removed: [RemovedPlaidTransaction]
    var nextCursor: String
    var hasMore: Bool

    enum CodingKeys: String, CodingKey {
        case added
        case modified
        case removed
        case nextCursor = "next_cursor"
        case hasMore = "has_more"
    }
}

private struct RemovedPlaidTransaction: Decodable {
    var transactionID: String

    enum CodingKeys: String, CodingKey {
        case transactionID = "transaction_id"
    }
}

private struct RecurringTransactionsRequest: Encodable {
    var clientID: String
    var secret: String
    var accessToken: String
    var options: RecurringTransactionsOptions

    enum CodingKeys: String, CodingKey {
        case clientID = "client_id"
        case secret
        case accessToken = "access_token"
        case options
    }
}

private struct RecurringTransactionsOptions: Encodable {
    var personalFinanceCategoryVersion: String

    enum CodingKeys: String, CodingKey {
        case personalFinanceCategoryVersion = "personal_finance_category_version"
    }
}

private struct RecurringTransactionsResponse: Decodable {
    var outflowStreams: [PlaidRecurringStream]
    var inflowStreams: [PlaidRecurringStream]

    enum CodingKeys: String, CodingKey {
        case outflowStreams = "outflow_streams"
        case inflowStreams = "inflow_streams"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        outflowStreams = try container.decodeIfPresent([PlaidRecurringStream].self, forKey: .outflowStreams) ?? []
        inflowStreams = try container.decodeIfPresent([PlaidRecurringStream].self, forKey: .inflowStreams) ?? []
    }
}

private struct PlaidRecurringStream: Decodable {
    var accountID: String
    var streamID: String
    var description: String
    var merchantName: String?
    var lastDate: String
    var predictedNextDate: String?
    var frequency: String
    var averageAmount: PlaidRecurringAmount
    var lastAmount: PlaidRecurringAmount
    var isActive: Bool
    var status: String
    var personalFinanceCategory: PlaidPersonalFinanceCategory?

    enum CodingKeys: String, CodingKey {
        case accountID = "account_id"
        case streamID = "stream_id"
        case description
        case merchantName = "merchant_name"
        case lastDate = "last_date"
        case predictedNextDate = "predicted_next_date"
        case frequency
        case averageAmount = "average_amount"
        case lastAmount = "last_amount"
        case isActive = "is_active"
        case status
        case personalFinanceCategory = "personal_finance_category"
    }

    var subscriptionItem: SubscriptionItem? {
        guard status != "TOMBSTONED" else { return nil }
        let average = abs(averageAmount.amount)
        guard average > 0 else { return nil }

        let nextDate = predictedNextDate.flatMap(Self.dateFormatter.date(from:))
            ?? nextExpectedDateFromLastCharge

        return SubscriptionItem(
            id: "plaid-recurring-\(streamID)",
            merchantName: resolvedMerchantName,
            category: resolvedCategory,
            monthlyAmount: Self.monthlyEquivalentAmount(averageAmount: average, frequency: frequency),
            nextExpectedDate: nextDate,
            accountID: accountID,
            recurringKind: resolvedRecurringKind,
            source: .plaid,
            frequency: frequency,
            status: status,
            lastAmount: abs(lastAmount.amount),
            averageAmount: average,
            lastDate: Self.dateFormatter.date(from: lastDate),
            streamDescription: description,
            isActive: isActive
        )
    }

    var dropReason: String? {
        if status == "TOMBSTONED" {
            return "\(resolvedMerchantName): dropped because Plaid status is TOMBSTONED"
        }

        if abs(averageAmount.amount) <= 0 {
            return "\(resolvedMerchantName): dropped because average amount is 0"
        }

        return nil
    }

    var diagnosticSummary: String {
        let amount = MoneyFormat.currency(abs(averageAmount.amount))
        let plaidCategory = [
            personalFinanceCategory?.primary,
            personalFinanceCategory?.detailed
        ]
        .compactMap { $0?.nilIfBlank }
        .joined(separator: "/")
        return "\(resolvedMerchantName) | type=\(resolvedRecurringKind.title) | active=\(isActive) | status=\(status) | frequency=\(frequency) | avg=\(amount) | pfc=\(plaidCategory.isEmpty ? "none" : plaidCategory) | account=\(accountID)"
    }

    private var resolvedMerchantName: String {
        let rawName = merchantName?.nilIfBlank ?? description.nilIfBlank ?? "Unknown Merchant"
        return MerchantNameCleaner.clean(rawName)
    }

    private var nextExpectedDateFromLastCharge: Date {
        let lastChargeDate = Self.dateFormatter.date(from: lastDate) ?? Date()
        let cadenceDays = switch frequency {
        case "WEEKLY": 7
        case "BIWEEKLY": 14
        case "SEMI_MONTHLY": 15
        case "MONTHLY": 30
        case "ANNUALLY": 365
        default: 30
        }
        return Calendar.current.date(byAdding: .day, value: cadenceDays, to: lastChargeDate) ?? .daysFromNow(cadenceDays)
    }

    private var resolvedCategory: TransactionCategory {
        let categoryText = recurringSignalText

        if categoryText.contains("transfer") || categoryText.contains("payment") { return .transfer }
        if categoryText.contains("food") || categoryText.contains("restaurant") { return .food }
        if categoryText.contains("transport") || categoryText.contains("travel") { return .transport }
        if categoryText.contains("rent") || categoryText.contains("home") || categoryText.contains("mortgage") { return .housing }
        if categoryText.contains("entertainment") { return .entertainment }
        if categoryText.contains("medical") || categoryText.contains("health") { return .health }
        if categoryText.contains("utility") || categoryText.contains("utilities") { return .utilities }
        if categoryText.contains("shop") || categoryText.contains("merchandise") { return .shopping }
        return .subscriptions
    }

    private var resolvedRecurringKind: RecurringChargeKind {
        let text = recurringSignalText

        let billSignals = [
            "transfer", "remittance", "investment", "brokerage", "fidelity", "venmo",
            "zelle", "cash app", "paypal", "loan payments", "rent", "mortgage",
            "utility", "utilities", "electric", "gas", "water", "solar", "solarcity",
            "internet", "phone", "wireless", "insurance", "loan", "student loan",
            "auto loan", "credit card", "payment", "tuition", "property tax",
            "tax", "hoa", "medical", "healthcare", "provider"
        ]

        if billSignals.contains(where: { text.contains($0) }) {
            return .bill
        }

        let subscriptionSignals = [
            "subscription", "streaming", "digital", "software", "music", "video",
            "cloud", "membership", "gym", "fitness", "news", "gaming"
        ]

        if subscriptionSignals.contains(where: { text.contains($0) }) {
            return .subscription
        }

        return .subscription
    }

    private var recurringSignalText: String {
        [
            merchantName,
            description,
            personalFinanceCategory?.primary,
            personalFinanceCategory?.detailed
        ]
        .compactMap { $0?.nilIfBlank }
        .joined(separator: " ")
        .lowercased()
    }

    private static func monthlyEquivalentAmount(averageAmount: Double, frequency: String) -> Double {
        switch frequency {
        case "WEEKLY":
            averageAmount * (30.4375 / 7.0)
        case "BIWEEKLY":
            averageAmount * (30.4375 / 14.0)
        case "SEMI_MONTHLY":
            averageAmount * 2.0
        case "MONTHLY":
            averageAmount
        case "ANNUALLY":
            averageAmount / 12.0
        default:
            averageAmount
        }
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter
    }()
}

private struct PlaidRecurringAmount: Decodable {
    var amount: Double
}

private struct PlaidTransaction: Decodable {
    var transactionID: String
    var accountID: String
    var amount: Double
    var isoCurrencyCode: String?
    var date: String
    var name: String
    var merchantName: String?
    var pending: Bool
    var personalFinanceCategory: PlaidPersonalFinanceCategory?
    var category: [String]?

    enum CodingKeys: String, CodingKey {
        case transactionID = "transaction_id"
        case accountID = "account_id"
        case amount
        case isoCurrencyCode = "iso_currency_code"
        case date
        case name
        case merchantName = "merchant_name"
        case pending
        case personalFinanceCategory = "personal_finance_category"
        case category
    }

    func financeTransaction(source: String) -> FinanceTransaction {
        let displayName = MerchantNameCleaner.clean(merchantName ?? name)

        return FinanceTransaction(
            id: transactionID,
            accountID: accountID,
            merchantName: displayName,
            originalName: name,
            amount: amount,
            date: Self.dateFormatter.date(from: date) ?? Date(),
            category: resolvedCategory,
            pending: pending,
            source: source
        )
    }

    private var resolvedCategory: TransactionCategory {
        let plaidCategoryText = [
            personalFinanceCategory?.primary,
            personalFinanceCategory?.detailed,
            category?.joined(separator: " ")
        ]
        .compactMap { $0 }
        .joined(separator: " ")
        .lowercased()

        let merchantText = "\(merchantName ?? "") \(name)".lowercased()

        if plaidCategoryText.contains("income") { return .income }
        if plaidCategoryText.contains("subscription") || plaidCategoryText.contains("streaming") || plaidCategoryText.contains("digital") || plaidCategoryText.contains("software") {
            return .subscriptions
        }
        if Self.looksLikeSubscriptionMerchant(merchantText) { return .subscriptions }
        if plaidCategoryText.contains("food") || plaidCategoryText.contains("restaurant") { return .food }
        if plaidCategoryText.contains("transport") || plaidCategoryText.contains("travel") { return .transport }
        if plaidCategoryText.contains("rent") || plaidCategoryText.contains("home") { return .housing }
        if plaidCategoryText.contains("entertainment") { return .entertainment }
        if plaidCategoryText.contains("medical") || plaidCategoryText.contains("health") { return .health }
        if plaidCategoryText.contains("utility") { return .utilities }
        if plaidCategoryText.contains("transfer") || plaidCategoryText.contains("loan") { return .transfer }
        if plaidCategoryText.contains("shops") || plaidCategoryText.contains("merchandise") { return .shopping }
        return .other
    }

    private static func looksLikeSubscriptionMerchant(_ text: String) -> Bool {
        let keywords = [
            "apple", "netflix", "spotify", "hulu", "disney", "max", "peacock",
            "youtube", "google", "amazon prime", "icloud", "dropbox", "adobe",
            "microsoft", "notion", "openai", "chatgpt", "github", "patreon",
            "substack", "nyt", "new york times", "wsj", "wall street journal",
            "paramount", "sirius", "audible", "kindle", "canva", "figma",
            "grammarly", "superhuman", "setapp", "zoom", "slack", "discord"
        ]
        return keywords.contains { text.contains($0) }
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()
}

private struct PlaidPersonalFinanceCategory: Decodable {
    var primary: String
    var detailed: String
}
