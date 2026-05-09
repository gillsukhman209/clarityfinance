import Foundation

enum AppSection: String, CaseIterable, Identifiable {
    case overview
    case accounts
    case transactions
    case budget
    case subscriptions
    case netWorth
    case settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .overview: "Overview"
        case .accounts: "Accounts"
        case .transactions: "Transactions"
        case .budget: "Budget"
        case .subscriptions: "Subscriptions"
        case .netWorth: "Net Worth"
        case .settings: "Settings"
        }
    }

    var symbolName: String {
        switch self {
        case .overview: "house.fill"
        case .accounts: "wallet.pass.fill"
        case .transactions: "list.bullet.rectangle.portrait.fill"
        case .budget: "chart.pie.fill"
        case .subscriptions: "calendar.badge.clock"
        case .netWorth: "chart.line.uptrend.xyaxis"
        case .settings: "gearshape.fill"
        }
    }
}

enum AccountKind: String, Codable, CaseIterable {
    case checking
    case savings
    case creditCard
    case investment
    case loan
    case manual

    var title: String {
        switch self {
        case .checking: "Checking"
        case .savings: "Savings"
        case .creditCard: "Credit Card"
        case .investment: "Investment"
        case .loan: "Loan"
        case .manual: "Manual"
        }
    }

    var isLiability: Bool {
        switch self {
        case .creditCard, .loan: true
        case .checking, .savings, .investment, .manual: false
        }
    }

    var symbolName: String {
        switch self {
        case .checking: "building.columns.fill"
        case .savings: "banknote.fill"
        case .creditCard: "creditcard.fill"
        case .investment: "chart.xyaxis.line"
        case .loan: "doc.text.fill"
        case .manual: "doc.richtext.fill"
        }
    }
}

enum TransactionCategory: String, Codable, CaseIterable, Identifiable {
    case food
    case shopping
    case transport
    case housing
    case entertainment
    case health
    case utilities
    case income
    case transfer
    case subscriptions
    case other

    var id: String { rawValue }

    var title: String {
        switch self {
        case .food: "Food"
        case .shopping: "Shopping"
        case .transport: "Transport"
        case .housing: "Housing"
        case .entertainment: "Entertainment"
        case .health: "Health"
        case .utilities: "Utilities"
        case .income: "Income"
        case .transfer: "Transfer"
        case .subscriptions: "Subscriptions"
        case .other: "Other"
        }
    }

    var symbolName: String {
        switch self {
        case .food: "fork.knife"
        case .shopping: "bag.fill"
        case .transport: "car.fill"
        case .housing: "house.fill"
        case .entertainment: "play.tv.fill"
        case .health: "heart.fill"
        case .utilities: "bolt.fill"
        case .income: "arrow.down.circle.fill"
        case .transfer: "arrow.left.arrow.right"
        case .subscriptions: "calendar.badge.clock"
        case .other: "circle.grid.2x2.fill"
        }
    }
}

struct FinancialAccount: Identifiable, Codable, Hashable {
    var id: String
    var institutionName: String
    var name: String
    var mask: String?
    var kind: AccountKind
    var currentBalance: Double
    var availableBalance: Double?
    var currencyCode: String
    var isManual: Bool

    var displayName: String {
        if let mask, !mask.isEmpty {
            "\(name) • \(mask)"
        } else {
            name
        }
    }
}

struct FinanceTransaction: Identifiable, Codable, Hashable {
    var id: String
    var accountID: String
    var merchantName: String
    var originalName: String
    var amount: Double
    var date: Date
    var category: TransactionCategory
    var pending: Bool
    var source: String

    var isIncome: Bool {
        category == .income || amount < 0
    }

    var signedDisplayAmount: Double {
        isIncome ? abs(amount) : -abs(amount)
    }
}

struct SubscriptionItem: Identifiable, Codable, Hashable {
    var id: String
    var merchantName: String
    var category: TransactionCategory
    var monthlyAmount: Double
    var nextExpectedDate: Date
    var accountID: String?
}

struct BudgetCategory: Identifiable, Codable, Hashable {
    var id: String
    var category: TransactionCategory
    var limit: Double
    var spent: Double

    var progress: Double {
        guard limit > 0 else { return 0 }
        return min(spent / limit, 1)
    }
}

struct NetWorthSnapshot: Identifiable, Codable, Hashable {
    var id: String
    var date: Date
    var assets: Double
    var liabilities: Double

    var netWorth: Double {
        assets - liabilities
    }
}

struct PlaidConnection: Identifiable, Codable, Hashable {
    var id: String
    var itemID: String
    var institutionID: String
    var institutionName: String
    var accessToken: String
    var cursor: String?
    var connectedAt: Date
    var lastSyncedAt: Date?

    enum CodingKeys: String, CodingKey {
        case id
        case itemID
        case institutionID
        case institutionName
        case accessToken
        case cursor
        case connectedAt
        case lastSyncedAt
    }

    init(
        id: String,
        itemID: String,
        institutionID: String,
        institutionName: String,
        accessToken: String,
        cursor: String?,
        connectedAt: Date,
        lastSyncedAt: Date?
    ) {
        self.id = id
        self.itemID = itemID
        self.institutionID = institutionID
        self.institutionName = institutionName
        self.accessToken = accessToken
        self.cursor = cursor
        self.connectedAt = connectedAt
        self.lastSyncedAt = lastSyncedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        itemID = try container.decode(String.self, forKey: .itemID)
        institutionID = try container.decodeIfPresent(String.self, forKey: .institutionID) ?? "ins_109508"
        institutionName = try container.decode(String.self, forKey: .institutionName)
        accessToken = try container.decode(String.self, forKey: .accessToken)
        cursor = try container.decodeIfPresent(String.self, forKey: .cursor)
        connectedAt = try container.decode(Date.self, forKey: .connectedAt)
        lastSyncedAt = try container.decodeIfPresent(Date.self, forKey: .lastSyncedAt)
    }
}

struct FinanceDataSet: Codable {
    var accounts: [FinancialAccount]
    var transactions: [FinanceTransaction]
    var subscriptions: [SubscriptionItem]
    var budgets: [BudgetCategory]
    var netWorthSnapshots: [NetWorthSnapshot]
    var connections: [PlaidConnection]

    static let empty = FinanceDataSet(
        accounts: [],
        transactions: [],
        subscriptions: [],
        budgets: [],
        netWorthSnapshots: [],
        connections: []
    )
}

struct PlaidSandboxInstitution: Identifiable, Hashable {
    var id: String
    var name: String

    static let firstPlatypus = PlaidSandboxInstitution(
        id: "ins_109508",
        name: "First Platypus Bank"
    )
}

enum PlaidSandboxProfile: String, CaseIterable, Identifiable {
    case transactionsDynamic
    case good

    var id: String { rawValue }

    var title: String {
        switch self {
        case .transactionsDynamic: "Transactions history"
        case .good: "Standard sandbox"
        }
    }

    var username: String {
        switch self {
        case .transactionsDynamic: "user_transactions_dynamic"
        case .good: "user_good"
        }
    }

    var password: String {
        "pass_good"
    }
}
