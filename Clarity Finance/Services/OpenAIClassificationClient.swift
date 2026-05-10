import Foundation

struct OpenAIClassificationClient {
    private let apiKey: String
    private let session: URLSession
    private let model = "gpt-4.1-mini"

    init(
        apiKey: String = "",
        session: URLSession = OpenAIClassificationClient.makeSession()
    ) {
        self.apiKey = apiKey
        self.session = session
    }

    func classify(merchants: [AIClassificationInput]) async throws -> [AIMerchantClassification] {
        guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw OpenAIClassificationError.missingAPIKey
        }

        guard !merchants.isEmpty else {
            return []
        }

        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/responses")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: requestBody(for: merchants))

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw OpenAIClassificationError.invalidResponse
        }

        guard (200..<300).contains(httpResponse.statusCode) else {
            let apiError = try? JSONDecoder().decode(OpenAIErrorResponse.self, from: data)
            throw OpenAIClassificationError.api(apiError?.error.message ?? "OpenAI returned HTTP \(httpResponse.statusCode).")
        }

        let decoded = try JSONDecoder().decode(OpenAIResponse.self, from: data)
        guard let outputText = decoded.outputText else {
            throw OpenAIClassificationError.missingOutput
        }

        let resultData = Data(outputText.utf8)
        let result = try JSONDecoder().decode(AIClassificationResult.self, from: resultData)
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

    private func requestBody(for merchants: [AIClassificationInput]) -> [String: Any] {
        let merchantPayload = (try? JSONSerialization.data(
            withJSONObject: merchants.map(\.promptDictionary),
            options: [.sortedKeys]
        ))
        .flatMap { String(data: $0, encoding: .utf8) } ?? "[]"

        let inputContent: [[String: Any]] = [
            [
                "type": "input_text",
                "text": "Classify these merchant spending groups. Return JSON that matches the schema exactly.\n\(merchantPayload)"
            ]
        ]
        let inputMessages: [[String: Any]] = [
            [
                "role": "user",
                "content": inputContent
            ]
        ]
        let body: [String: Any] = [
            "model": model,
            "instructions": """
            You classify personal finance transaction merchants for a Gen Z spending app.
            Be practical and conservative. Do not call one-off purchases subscriptions just because the merchant is famous.
            Look at the individual transaction dates and amounts. Merchants like Apple, Google, Amazon, Meta, TikTok, and ad platforms can contain both real subscriptions and one-time purchases. A merchant should only be subscription/bill when the actual charge pattern is recurring, not just because the company sells subscriptions.
            Tax payments, IRS, treasury, franchise tax, government fees, permit fees, filing fees, and estimated taxes are one-time payments unless the transaction dates show a monthly recurring payment plan.
            A subscription means an ongoing paid service or membership. A bill means a recurring necessary payment like rent, utilities, insurance, loans, phone, internet, taxes, or credit card payments. Transfers and debt payments should not be counted as spending subscriptions.
            Return short names and plain English that a normal person instantly understands.
            """,
            "input": inputMessages,
            "text": [
                "format": [
                    "type": "json_schema",
                    "name": "clarity_merchant_classifications",
                    "strict": true,
                    "schema": responseSchema
                ]
            ]
        ]
        return body
    }

    private var responseSchema: [String: Any] {
        [
            "type": "object",
            "additionalProperties": false,
            "properties": [
                "merchants": [
                    "type": "array",
                    "items": [
                        "type": "object",
                        "additionalProperties": false,
                        "properties": [
                            "key": ["type": "string"],
                            "display_name": ["type": "string"],
                            "kind": [
                                "type": "string",
                                "enum": AITransactionKind.allCases.map(\.rawValue)
                            ],
                            "category": [
                                "type": "string",
                                "enum": TransactionCategory.allCases.map(\.rawValue)
                            ],
                            "confidence": [
                                "type": "number",
                                "minimum": 0,
                                "maximum": 1
                            ],
                            "plain_english": ["type": "string"]
                        ],
                        "required": ["key", "display_name", "kind", "category", "confidence", "plain_english"]
                    ]
                ]
            ],
            "required": ["merchants"]
        ]
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
    case missingAPIKey
    case invalidResponse
    case missingOutput
    case api(String)

    var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            "OpenAI API key is missing."
        case .invalidResponse:
            "OpenAI returned an invalid response."
        case .missingOutput:
            "OpenAI did not return classification text."
        case .api(let message):
            message
        }
    }
}

private struct OpenAIErrorResponse: Decodable {
    var error: OpenAIError
}

private struct OpenAIError: Decodable {
    var message: String
}

private struct OpenAIResponse: Decodable {
    var output: [OpenAIOutputItem]

    var outputText: String? {
        output
            .flatMap { $0.content ?? [] }
            .compactMap(\.text)
            .first
    }
}

private struct OpenAIOutputItem: Decodable {
    var content: [OpenAIContentItem]?
}

private struct OpenAIContentItem: Decodable {
    var text: String?
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
