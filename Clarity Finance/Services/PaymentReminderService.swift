import Foundation
#if os(iOS)
import UserNotifications
#endif

struct PaymentReminderPreferences: Codable, Equatable {
    var isEnabled: Bool
    var reminderOffsetsDays: [Int]
    var hour: Int
    var minute: Int
    var paidDueDateKeysByAccountID: [String: String]

    static let defaults = PaymentReminderPreferences(
        isEnabled: false,
        reminderOffsetsDays: [3, 1, 0],
        hour: 9,
        minute: 0,
        paidDueDateKeysByAccountID: [:]
    )
}

struct PaymentReminderScheduleResult: Equatable {
    var scheduledCount: Int
    var skippedPaidCount: Int
    var missingDueDateCount: Int
}

enum PaymentReminderError: LocalizedError {
    case permissionDenied

    var errorDescription: String? {
        switch self {
        case .permissionDenied:
            "Notifications are not allowed for Clarity. Turn them on in iPhone Settings."
        }
    }
}

enum PaymentReminderService {
    static let notificationIDPrefix = "payment-reminder:"

    static func dueDateKey(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = Calendar.current.timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    static func cardLabel(for account: FinancialAccount) -> String {
        if let mask = account.mask?.trimmingCharacters(in: .whitespacesAndNewlines), !mask.isEmpty {
            return "\(account.name) •••• \(mask)"
        }

        return account.name
    }

    #if os(iOS)
    static func requestAuthorizationIfNeeded() async throws -> Bool {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()

        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            return true
        case .denied:
            return false
        case .notDetermined:
            return try await center.requestAuthorization(options: [.alert, .badge, .sound])
        @unknown default:
            return false
        }
    }

    static func cancelAllPendingPaymentReminders() async {
        let center = UNUserNotificationCenter.current()
        let pendingRequests = await center.pendingNotificationRequests()
        let identifiers = pendingRequests
            .map(\.identifier)
            .filter { $0.hasPrefix(notificationIDPrefix) }

        if !identifiers.isEmpty {
            center.removePendingNotificationRequests(withIdentifiers: identifiers)
        }
    }

    static func cancelPendingPaymentReminders(accountID: String) async {
        let center = UNUserNotificationCenter.current()
        let prefix = notificationIDPrefix + accountID + ":"
        let pendingRequests = await center.pendingNotificationRequests()
        let identifiers = pendingRequests
            .map(\.identifier)
            .filter { $0.hasPrefix(prefix) }

        if !identifiers.isEmpty {
            center.removePendingNotificationRequests(withIdentifiers: identifiers)
        }
    }

    static func syncPaymentReminders(
        accounts: [FinancialAccount],
        liabilities: [CreditCardLiability],
        preferences: PaymentReminderPreferences
    ) async throws -> PaymentReminderScheduleResult {
        await cancelAllPendingPaymentReminders()

        guard preferences.isEnabled else {
            return PaymentReminderScheduleResult(scheduledCount: 0, skippedPaidCount: 0, missingDueDateCount: 0)
        }

        guard try await requestAuthorizationIfNeeded() else {
            throw PaymentReminderError.permissionDenied
        }

        let accountsByID = Dictionary(uniqueKeysWithValues: accounts.map { ($0.id, $0) })
        let sortedOffsets = Array(Set(preferences.reminderOffsetsDays)).sorted(by: >)
        var scheduledCount = 0
        var skippedPaidCount = 0
        var missingDueDateCount = 0

        for liability in liabilities {
            guard let account = accountsByID[liability.accountID] else { continue }
            guard let dueDate = liability.nextPaymentDueDate else {
                missingDueDateCount += 1
                continue
            }

            let dueKey = dueDateKey(dueDate)
            if preferences.paidDueDateKeysByAccountID[liability.accountID] == dueKey {
                skippedPaidCount += 1
                continue
            }

            for offset in sortedOffsets {
                guard let fireDate = Calendar.current.date(byAdding: .day, value: -offset, to: Calendar.current.startOfDay(for: dueDate)) else {
                    continue
                }

                var components = Calendar.current.dateComponents([.year, .month, .day], from: fireDate)
                components.hour = preferences.hour
                components.minute = preferences.minute

                guard let resolvedFireDate = Calendar.current.date(from: components), resolvedFireDate > Date() else {
                    continue
                }

                let identifier = "\(notificationIDPrefix)\(liability.accountID):\(dueKey):\(offset)"
                let content = UNMutableNotificationContent()
                content.title = title(for: offset)
                content.body = body(for: offset, account: account, liability: liability, dueDate: dueDate)
                content.sound = .default
                content.userInfo = [
                    "type": "payment_reminder",
                    "account_id": liability.accountID,
                    "due_date": dueKey,
                    "offset_days": offset
                ]

                let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
                let request = UNNotificationRequest(identifier: identifier, content: content, trigger: trigger)
                try await UNUserNotificationCenter.current().add(request)
                scheduledCount += 1
            }
        }

        return PaymentReminderScheduleResult(
            scheduledCount: scheduledCount,
            skippedPaidCount: skippedPaidCount,
            missingDueDateCount: missingDueDateCount
        )
    }

    static func scheduleTestPaymentReminder(accounts: [FinancialAccount], liabilities: [CreditCardLiability]) async throws {
        guard try await requestAuthorizationIfNeeded() else {
            throw PaymentReminderError.permissionDenied
        }

        let accountsByID = Dictionary(uniqueKeysWithValues: accounts.map { ($0.id, $0) })
        let liability = liabilities
            .filter { accountsByID[$0.accountID] != nil }
            .sorted { lhs, rhs in
                (lhs.nextPaymentDueDate ?? .distantFuture) < (rhs.nextPaymentDueDate ?? .distantFuture)
            }
            .first
        let account = liability.flatMap { accountsByID[$0.accountID] } ?? accounts.first { $0.kind == .creditCard }

        let content = UNMutableNotificationContent()
        content.title = "Payment reminder test"

        if let account, let liability {
            let label = cardLabel(for: account)
            if let amount = liability.minimumPaymentAmount {
                content.body = "\(label): test alert. Real reminder would say minimum \(MoneyFormat.currency(amount)) is due soon."
            } else {
                content.body = "\(label): test alert. Real reminder would use the card due date when Plaid returns it."
            }
        } else {
            content.body = "This is what a Clarity card payment reminder will look like."
        }

        content.sound = .default
        content.userInfo = ["type": "payment_reminder_test"]

        let request = UNNotificationRequest(
            identifier: "\(notificationIDPrefix)test:\(UUID().uuidString)",
            content: content,
            trigger: UNTimeIntervalNotificationTrigger(timeInterval: 10, repeats: false)
        )
        try await UNUserNotificationCenter.current().add(request)
    }

    private static func title(for offset: Int) -> String {
        switch offset {
        case 0:
            return "Card payment due today"
        case 1:
            return "Card payment due tomorrow"
        default:
            return "Card payment coming up"
        }
    }

    private static func body(for offset: Int, account: FinancialAccount, liability: CreditCardLiability, dueDate: Date) -> String {
        let label = cardLabel(for: account)
        let amountText = liability.minimumPaymentAmount.map { MoneyFormat.currency($0) }
        let dateText = dueDate.formatted(.dateTime.month(.abbreviated).day())

        switch (offset, amountText) {
        case (0, let amount?):
            return "\(label): pay at least \(amount) today to stay current."
        case (0, nil):
            return "\(label) is due today. Pay it before the day gets expensive."
        case (1, let amount?):
            return "\(label): \(amount) minimum is due tomorrow."
        case (1, nil):
            return "\(label) is due tomorrow. Do not let it sneak up."
        case (_, let amount?):
            return "\(label): \(amount) minimum is due \(dateText)."
        case (_, nil):
            return "\(label) has a payment due \(dateText)."
        }
    }
    #else
    static func requestAuthorizationIfNeeded() async throws -> Bool {
        false
    }

    static func cancelAllPendingPaymentReminders() async {}

    static func cancelPendingPaymentReminders(accountID: String) async {}

    static func syncPaymentReminders(
        accounts: [FinancialAccount],
        liabilities: [CreditCardLiability],
        preferences: PaymentReminderPreferences
    ) async throws -> PaymentReminderScheduleResult {
        PaymentReminderScheduleResult(scheduledCount: 0, skippedPaidCount: 0, missingDueDateCount: 0)
    }

    static func scheduleTestPaymentReminder(accounts: [FinancialAccount], liabilities: [CreditCardLiability]) async throws {}
    #endif
}
