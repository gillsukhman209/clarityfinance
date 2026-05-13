import AuthenticationServices
import CryptoKit
import Foundation
import Security

struct SupabaseAuthConfiguration: Equatable {
    var url: URL
    var anonKey: String

    static func load() -> SupabaseAuthConfiguration? {
        guard
            let urlString = Bundle.main.object(forInfoDictionaryKey: "ClaritySupabaseURL") as? String,
            let url = URL(string: urlString.trimmingCharacters(in: .whitespacesAndNewlines)),
            let anonKey = Bundle.main.object(forInfoDictionaryKey: "ClaritySupabaseAnonKey") as? String,
            !anonKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            return nil
        }

        return SupabaseAuthConfiguration(
            url: url,
            anonKey: anonKey.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }
}

struct SupabaseAuthSession: Codable, Equatable {
    var accessToken: String
    var refreshToken: String
    var tokenType: String
    var expiresAt: Date
    var userID: String
    var email: String?

    var displayName: String {
        guard let email, !email.isEmpty else { return userID }
        return email
    }

    var isExpiredSoon: Bool {
        expiresAt.timeIntervalSinceNow < 300
    }
}

struct SupabaseBackendUser: Codable, Equatable {
    var id: String
    var email: String?
}

enum SupabaseAuthError: LocalizedError {
    case missingConfiguration
    case missingAppleIdentityToken
    case missingAppleNonce
    case invalidResponse
    case backendRejected(String)

    var errorDescription: String? {
        switch self {
        case .missingConfiguration:
            "Supabase URL or anon key is missing."
        case .missingAppleIdentityToken:
            "Apple did not return an identity token."
        case .missingAppleNonce:
            "Apple sign-in nonce is missing. Try again."
        case .invalidResponse:
            "Supabase returned an unreadable auth response."
        case .backendRejected(let message):
            message
        }
    }
}

struct SupabaseAuthService {
    private let configuration: SupabaseAuthConfiguration
    private let session: URLSession
    private let backendBaseURL = "https://clarityfinance-gilt.vercel.app"

    init(configuration: SupabaseAuthConfiguration, session: URLSession = .shared) {
        self.configuration = configuration
        self.session = session
    }

    func signInWithApple(identityToken: String, nonce: String) async throws -> SupabaseAuthSession {
        let endpoint = configuration.url
            .appending(path: "auth/v1/token")
            .appending(queryItems: [URLQueryItem(name: "grant_type", value: "id_token")])

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue(configuration.anonKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(configuration.anonKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(
            AppleIDTokenRequest(
                provider: "apple",
                idToken: identityToken,
                nonce: nonce
            )
        )

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw SupabaseAuthError.invalidResponse
        }

        guard (200..<300).contains(httpResponse.statusCode) else {
            let message = SupabaseAuthService.errorMessage(from: data)
            throw SupabaseAuthError.backendRejected(message)
        }

        let decoded = try JSONDecoder().decode(SupabaseTokenResponse.self, from: data)
        return decoded.session
    }

    func refreshSession(_ authSession: SupabaseAuthSession) async throws -> SupabaseAuthSession {
        let endpoint = configuration.url
            .appending(path: "auth/v1/token")
            .appending(queryItems: [URLQueryItem(name: "grant_type", value: "refresh_token")])

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue(configuration.anonKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(configuration.anonKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(
            RefreshTokenRequest(refreshToken: authSession.refreshToken)
        )

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw SupabaseAuthError.invalidResponse
        }

        guard (200..<300).contains(httpResponse.statusCode) else {
            let message = SupabaseAuthService.errorMessage(from: data)
            throw SupabaseAuthError.backendRejected(message)
        }

        let decoded = try JSONDecoder().decode(SupabaseTokenResponse.self, from: data)
        return decoded.session
    }

    func verifyWithBackend(_ authSession: SupabaseAuthSession) async throws -> SupabaseBackendUser {
        guard let endpoint = URL(string: backendBaseURL + "/api/auth/me") else {
            throw SupabaseAuthError.invalidResponse
        }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "GET"
        request.setValue("Bearer \(authSession.accessToken)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw SupabaseAuthError.invalidResponse
        }

        guard (200..<300).contains(httpResponse.statusCode) else {
            let message = SupabaseAuthService.errorMessage(from: data)
            throw SupabaseAuthError.backendRejected(message)
        }

        let decoded = try JSONDecoder().decode(BackendMeResponse.self, from: data)
        return decoded.user
    }

    static func randomNonceString(length: Int = 32) -> String {
        let targetLength = max(1, length)
        let charset = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVXYZabcdefghijklmnopqrstuvwxyz-._")
        var result = ""
        var remainingLength = targetLength

        while remainingLength > 0 {
            var randoms = [UInt8](repeating: 0, count: 16)
            let status = SecRandomCopyBytes(kSecRandomDefault, randoms.count, &randoms)
            if status != errSecSuccess {
                return UUID().uuidString.replacingOccurrences(of: "-", with: "")
            }

            randoms.forEach { random in
                guard remainingLength > 0 else { return }
                if random < charset.count {
                    result.append(charset[Int(random)])
                    remainingLength -= 1
                }
            }
        }

        return result
    }

    static func sha256(_ input: String) -> String {
        let inputData = Data(input.utf8)
        let hashedData = SHA256.hash(data: inputData)
        return hashedData.compactMap { String(format: "%02x", $0) }.joined()
    }

    private static func errorMessage(from data: Data) -> String {
        if let decoded = try? JSONDecoder().decode(SupabaseErrorResponse.self, from: data) {
            return decoded.errorDescription ?? decoded.msg ?? decoded.error ?? "Supabase auth request failed."
        }

        return String(data: data, encoding: .utf8) ?? "Supabase auth request failed."
    }
}

private struct AppleIDTokenRequest: Encodable {
    var provider: String
    var idToken: String
    var nonce: String

    enum CodingKeys: String, CodingKey {
        case provider
        case idToken = "id_token"
        case nonce
    }
}

private struct RefreshTokenRequest: Encodable {
    var refreshToken: String

    enum CodingKeys: String, CodingKey {
        case refreshToken = "refresh_token"
    }
}

private struct SupabaseTokenResponse: Decodable {
    var accessToken: String
    var refreshToken: String
    var tokenType: String
    var expiresIn: TimeInterval
    var expiresAt: TimeInterval?
    var user: SupabaseUserResponse

    var session: SupabaseAuthSession {
        let expiryDate: Date
        if let expiresAt {
            expiryDate = Date(timeIntervalSince1970: expiresAt)
        } else {
            expiryDate = Date().addingTimeInterval(expiresIn)
        }

        return SupabaseAuthSession(
            accessToken: accessToken,
            refreshToken: refreshToken,
            tokenType: tokenType,
            expiresAt: expiryDate,
            userID: user.id,
            email: user.email
        )
    }

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case tokenType = "token_type"
        case expiresIn = "expires_in"
        case expiresAt = "expires_at"
        case user
    }
}

private struct SupabaseUserResponse: Decodable {
    var id: String
    var email: String?
}

private struct BackendMeResponse: Decodable {
    var ok: Bool
    var user: SupabaseBackendUser
}

private struct SupabaseErrorResponse: Decodable {
    var error: String?
    var msg: String?
    var errorDescription: String?

    enum CodingKeys: String, CodingKey {
        case error
        case msg
        case errorDescription = "error_description"
    }
}

private extension URL {
    func appending(queryItems: [URLQueryItem]) -> URL {
        guard var components = URLComponents(url: self, resolvingAgainstBaseURL: false) else {
            return self
        }

        components.queryItems = (components.queryItems ?? []) + queryItems
        return components.url ?? self
    }
}
