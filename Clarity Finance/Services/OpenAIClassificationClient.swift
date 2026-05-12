import Foundation

struct OpenAIClassificationClient {
    private let authSession: SupabaseAuthSession
    private let session: URLSession
    private let backendBaseURL = URL(string: "https://clarityfinance-gilt.vercel.app")!

    init(
        authSession: SupabaseAuthSession,
        session: URLSession = OpenAIClassificationClient.makeSession()
    ) {
        self.authSession = authSession
        self.session = session
    }

    func classify(merchants: [AIClassificationInput]) async throws -> [AIMerchantClassification] {
        guard !merchants.isEmpty else {
            return []
        }

        var request = URLRequest(url: backendBaseURL.appending(path: "/api/ai/classify"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(authSession.accessToken)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "merchants": merchants.map(\.promptDictionary)
        ])

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw OpenAIClassificationError.invalidResponse
        }

        guard (200..<300).contains(httpResponse.statusCode) else {
            let apiError = try? JSONDecoder().decode(BackendAIErrorResponse.self, from: data)
            throw OpenAIClassificationError.api(apiError?.error ?? "AI backend returned HTTP \(httpResponse.statusCode).")
        }

        let result = try JSONDecoder().decode(AIClassificationResult.self, from: data)
        let now = Date()

        return result.merchants.map { item in
            AIMerchantClassification(
                merchantKey: item.key,
                displayName: item.displayName,
                kind: item.kind,
                category: item.category,
                confidence: min(max(item.confidence, 0), 1),
                plainEnglish: item.plainEnglish,
                updatedAt: now
            )
        }
    }

    private static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 60
        return URLSession(configuration: configuration)
    }
}

struct AIClassificationInput {
    var key: String
    var merchantName: String
    var originalNames: [String]
    var plaidCategories: [String]
    var transactionCount: Int
    var totalSpent: Double
    var averageAmount: Double
    var latestDate: Date
    var transactions: [AITransactionSample]

    var promptDictionary: [String: Any] {
        [
            "key": key,
            "merchant_name": merchantName,
            "original_names": originalNames,
            "plaid_categories": plaidCategories,
            "transaction_count": transactionCount,
            "total_spent": round(totalSpent * 100) / 100,
            "average_amount": round(averageAmount * 100) / 100,
            "latest_date": Self.dateFormatter.string(from: latestDate),
            "transactions": transactions.map(\.promptDictionary)
        ]
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()
}

struct AITransactionSample {
    var date: Date
    var amount: Double
    var name: String

    var promptDictionary: [String: Any] {
        [
            "date": Self.dateFormatter.string(from: date),
            "amount": round(abs(amount) * 100) / 100,
            "name": name
        ]
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()
}

enum OpenAIClassificationError: LocalizedError {
    case invalidResponse
    case api(String)

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            "AI backend returned an invalid response."
        case .api(let message):
            message
        }
    }
}

private struct BackendAIErrorResponse: Decodable {
    var error: String?
}

private struct AIClassificationResult: Decodable {
    var merchants: [AIClassificationResultItem]
}

private struct AIClassificationResultItem: Decodable {
    var key: String
    var displayName: String
    var kind: AITransactionKind
    var category: TransactionCategory
    var confidence: Double
    var plainEnglish: String

    enum CodingKeys: String, CodingKey {
        case key
        case displayName = "display_name"
        case kind
        case category
        case confidence
        case plainEnglish = "plain_english"
    }
}
