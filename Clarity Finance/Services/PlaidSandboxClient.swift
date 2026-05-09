import Foundation

struct PlaidCredentials: Equatable {
    var clientID: String
    var sandboxSecret: String
    var productionSecret: String

    static let bundledSandbox = PlaidCredentials(
        clientID: "6924ab26d99796001d9a0831",
        sandboxSecret: "d304ada4984f45d8d9ddbadfb694b7",
        productionSecret: "c7114af7920b8905773318448475ba"
    )

    var isSandboxComplete: Bool {
        !clientID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !sandboxSecret.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var isProductionComplete: Bool {
        !clientID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !productionSecret.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

enum PlaidEnvironment {
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
                    overridePassword: profile.password
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
                    options: TransactionsSyncOptions(daysRequested: 730)
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
            cursor: nil,
            connectedAt: Date(),
            lastSyncedAt: nil
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

private struct EmptyPlaidResponse: Decodable {}

private struct LinkTokenCreateRequest: Encodable {
    var clientID: String
    var secret: String
    var clientName: String
    var products: [String]
    var countryCodes: [String]
    var language: String
    var user: LinkTokenUser
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
        FinanceTransaction(
            id: transactionID,
            accountID: accountID,
            merchantName: merchantName ?? name,
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
