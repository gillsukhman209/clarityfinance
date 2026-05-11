import Foundation
#if os(iOS)
import UIKit
import UserNotifications
#endif

enum ViralNotificationTone: String, CaseIterable, Codable, Identifiable {
    case funny
    case brutal
    case clean

    var id: String { rawValue }

    var title: String {
        switch self {
        case .funny: "Funny"
        case .brutal: "Brutal"
        case .clean: "Clean"
        }
    }
}

enum ViralNotificationPrivacy: String, CaseIterable, Codable, Identifiable {
    case merchantAmount = "merchant_amount"
    case privatePreview = "private"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .merchantAmount: "Merchant + amount"
        case .privatePreview: "Private preview"
        }
    }
}

struct ViralNotificationPreferences: Codable, Equatable {
    var isEnabled: Bool
    var tone: ViralNotificationTone
    var privacy: ViralNotificationPrivacy

    static let defaults = ViralNotificationPreferences(
        isEnabled: false,
        tone: .funny,
        privacy: .merchantAmount
    )
}

extension Notification.Name {
    static let clarityAPNSTokenDidUpdate = Notification.Name("clarityAPNSTokenDidUpdate")
    static let clarityAPNSTokenDidFail = Notification.Name("clarityAPNSTokenDidFail")
}

#if os(iOS)
final class ClarityAppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        print("[Clarity Push] AppDelegate didFinishLaunching. Setting UNUserNotificationCenter delegate.")
        UNUserNotificationCenter.current().delegate = self
        return true
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        let token = deviceToken.map { String(format: "%02x", $0) }.joined()
        print("[Clarity Push] APNs didRegisterForRemoteNotifications tokenLength=\(token.count).")
        NotificationCenter.default.post(name: .clarityAPNSTokenDidUpdate, object: token)
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        print("[Clarity Push] APNs didFailToRegisterForRemoteNotifications error=\(error.localizedDescription).")
        NotificationCenter.default.post(name: .clarityAPNSTokenDidFail, object: error.localizedDescription)
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }
}

enum PushPermissionService {
    static func authorizationStatusLabel() async -> String {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        return label(for: settings.authorizationStatus)
    }

    static func requestAuthorizationAndRegister() async throws -> Bool {
        let center = UNUserNotificationCenter.current()
        let beforeSettings = await center.notificationSettings()
        print("[Clarity Push] Authorization before request: \(label(for: beforeSettings.authorizationStatus)).")
        let granted = try await center.requestAuthorization(options: [.alert, .badge, .sound])
        let afterSettings = await center.notificationSettings()
        print("[Clarity Push] Authorization request completed. granted=\(granted), status=\(label(for: afterSettings.authorizationStatus)), alertSetting=\(afterSettings.alertSetting.rawValue), soundSetting=\(afterSettings.soundSetting.rawValue), badgeSetting=\(afterSettings.badgeSetting.rawValue).")
        guard granted else { return false }

        await MainActor.run {
            print("[Clarity Push] Calling UIApplication.registerForRemoteNotifications(). isRegisteredBefore=\(UIApplication.shared.isRegisteredForRemoteNotifications).")
            UIApplication.shared.registerForRemoteNotifications()
        }
        return true
    }

    private static func label(for status: UNAuthorizationStatus) -> String {
        switch status {
        case .notDetermined:
            return "notDetermined"
        case .denied:
            return "denied"
        case .authorized:
            return "authorized"
        case .provisional:
            return "provisional"
        case .ephemeral:
            return "ephemeral"
        @unknown default:
            return "unknown(\(status.rawValue))"
        }
    }
}
#endif

struct NotificationBackendClient {
    enum BackendError: LocalizedError {
        case invalidBackendURL
        case badResponse(String)

        var errorDescription: String? {
            switch self {
            case .invalidBackendURL:
                "The notification backend URL is not valid."
            case .badResponse(let message):
                message
            }
        }
    }

    var preferences: ViralNotificationPreferences
    var authSession: SupabaseAuthSession?
    var session: URLSession = .shared
    private let backendBaseURL = "https://clarityfinance-gilt.vercel.app"

    func registerDevice(deviceID: String, apnsToken: String) async throws {
        try await post(
            path: "/api/devices/register",
            body: RegisterDeviceRequest(
                deviceID: deviceID,
                apnsToken: apnsToken,
                platform: "ios",
                enabled: preferences.isEnabled,
                tone: preferences.tone.rawValue,
                privacy: preferences.privacy.rawValue
            )
        )
    }

    func registerItem(deviceID: String, connection: PlaidConnection) async throws {
        try await post(
            path: "/api/plaid/items/register",
            body: RegisterPlaidItemRequest(
                deviceID: deviceID,
                itemID: connection.itemID,
                accessToken: connection.accessToken.isEmpty ? nil : connection.accessToken,
                environment: connection.environment.rawValue,
                institutionID: connection.institutionID,
                institutionName: connection.institutionName,
                cursor: connection.cursor
            )
        )
    }

    func sendTestNotification(deviceID: String) async throws {
        try await post(
            path: "/api/notifications/test",
            body: TestNotificationRequest(deviceID: deviceID)
        )
    }

    private func post<T: Encodable>(path: String, body: T) async throws {
        let trimmedBaseURL = backendBaseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let endpointURL = URL(string: trimmedBaseURL + path) else {
            throw BackendError.invalidBackendURL
        }

        var request = URLRequest(url: endpointURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let accessToken = authSession?.accessToken {
            request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = try JSONEncoder.notificationBackend.encode(body)

        print("[Clarity Push] Backend POST \(endpointURL.absoluteString).")
        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw BackendError.badResponse("Notification backend did not return HTTP.")
        }

        let responseBody = String(data: data, encoding: .utf8) ?? "<non-utf8 body>"
        print("[Clarity Push] Backend response \(httpResponse.statusCode) for \(path): \(responseBody).")
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw BackendError.badResponse(responseBody)
        }
    }
}

private struct RegisterDeviceRequest: Encodable {
    var deviceID: String
    var apnsToken: String
    var platform: String
    var enabled: Bool
    var tone: String
    var privacy: String

    enum CodingKeys: String, CodingKey {
        case deviceID = "device_id"
        case apnsToken = "apns_token"
        case platform
        case enabled
        case tone
        case privacy
    }
}

private struct RegisterPlaidItemRequest: Encodable {
    var deviceID: String
    var itemID: String
    var accessToken: String?
    var environment: String
    var institutionID: String
    var institutionName: String
    var cursor: String?

    enum CodingKeys: String, CodingKey {
        case deviceID = "device_id"
        case itemID = "item_id"
        case accessToken = "access_token"
        case environment
        case institutionID = "institution_id"
        case institutionName = "institution_name"
        case cursor
    }
}

private struct TestNotificationRequest: Encodable {
    var deviceID: String

    enum CodingKeys: String, CodingKey {
        case deviceID = "device_id"
    }
}

private extension JSONEncoder {
    static var notificationBackend: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}
