import SwiftUI

struct CoachView: View {
    @Bindable var store: FinanceStore

    @State private var selectedTool: CoachTool = .afford
    @State private var purchasePrice = ""
    @State private var purchaseCategory: TransactionCategory = .shopping
    @State private var purchaseIsMonthly = false
    @State private var decision: AffordabilityDecision?
    @State private var shareShowsAmounts = true
    @State private var shareShowsMerchants = true
    @State private var shareCardURL: URL?

    var body: some View {
        let trends = SpendingTrends(transactions: store.filteredTransactions)
        let insights = Array(store.moneyInsights.prefix(3))
        let wrapped = store.moneyWrapped
        let personality = store.spendingPersonality

        ScrollView {
            LazyVStack(alignment: .leading, spacing: 16) {
                ScreenTitle(title: "Coach", subtitle: "One clear read. One next move.")

                if !store.data.accounts.isEmpty {
                    AccountFilterBar(accounts: store.data.accounts, selectedAccountIDs: $store.selectedAccountIDs)
                }

                CoachHeroCard(
                    personality: personality,
                    primaryInsight: insights.first,
                    monthTotal: trends.thisMonthTotal,
                    comparison: trends.monthToDateComparison
                )

                metricRail(trends: trends, wrapped: wrapped)
                nextMoves(insights: insights)
                toolPicker
                selectedToolPanel(wrapped: wrapped)
            }
            .padding(24)
            .frame(maxWidth: 940, alignment: .leading)
        }
        .clarityTabContentPadding()
    }

    private func metricRail(trends: SpendingTrends, wrapped: MoneyWrapped) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                CoachMetricTile(title: "Month", value: MoneyFormat.compact(trends.thisMonthTotal), caption: trends.monthToDateComparison.title, symbolName: "calendar")
                CoachMetricTile(title: "7 days", value: MoneyFormat.compact(trends.lastSevenDaysTotal), caption: trends.sevenDayComparison.title, symbolName: "flame.fill")
                CoachMetricTile(title: "Top", value: wrapped.topMerchant ?? "None", caption: MoneyFormat.compact(wrapped.topMerchantAmount), symbolName: "crown.fill")
                CoachMetricTile(title: "Recurring", value: MoneyFormat.compact(wrapped.subscriptionsTotal), caption: "monthly", symbolName: "calendar.badge.clock")
            }
        }
    }

    private func nextMoves(insights: [MoneyInsight]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "Next moves", systemImage: "sparkles")

            if insights.isEmpty {
                EmptyStateView(title: "No coaching yet", message: "Connect accounts or import statements to get a useful read.", symbolName: "sparkles")
                    .padding(18)
                    .clarityCard(radius: 20)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(insights.enumerated()), id: \.element.id) { index, insight in
                        CompactInsightRow(insight: insight)
                        if index < insights.count - 1 {
                            Divider().padding(.leading, 52)
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .clarityCard(radius: 20)
            }
        }
    }

    private var toolPicker: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "Tools", systemImage: "slider.horizontal.3")

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                ForEach(CoachTool.allCases) { tool in
                    CoachToolButton(tool: tool, isSelected: selectedTool == tool) {
                        withAnimation(.snappy(duration: 0.18)) {
                            selectedTool = tool
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func selectedToolPanel(wrapped: MoneyWrapped) -> some View {
        switch selectedTool {
        case .afford:
            affordabilityPanel
        case .budget:
            budgetPanel
        case .wrapped:
            wrappedPanel(wrapped: wrapped)
        case .review:
            subscriptionReviewPanel
        }
    }

    private var budgetPanel: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                SpendingStatCard(title: "Spent", amount: store.monthlySpend)
                SpendingStatCard(title: "Income", amount: store.incomeThisMonth)
                SpendingStatCard(title: "Left", amount: max(0, store.incomeThisMonth - store.monthlySpend))
            }

            if store.filteredBudgets.isEmpty {
                EmptyStateView(
                    title: "No budgets yet",
                    message: "Sync or import transactions first.",
                    symbolName: "chart.pie"
                )
            } else {
                VStack(spacing: 10) {
                    ForEach(store.filteredBudgets) { budget in
                        BudgetControlRow(budget: budget) { newLimit in
                            store.setBudgetLimit(for: budget.category, limit: newLimit)
                        }
                    }
                }
            }
        }
        .padding(18)
        .clarityCard(radius: 20)
    }

    private var affordabilityPanel: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionHeader(title: "Can I afford this?", systemImage: "questionmark.circle.fill")

            VStack(alignment: .leading, spacing: 14) {
                TextField("Price", text: $purchasePrice)
#if os(iOS)
                    .keyboardType(.decimalPad)
#endif
                    .textFieldStyle(.plain)
                    .padding(14)
                    .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(ClarityColor.panelElevated))

                Picker("Category", selection: $purchaseCategory) {
                    ForEach(TransactionCategory.allCases.filter { $0 != .income && $0 != .transfer }) { category in
                        Label(category.title, systemImage: category.symbolName)
                            .tag(category)
                    }
                }
                .pickerStyle(.menu)

                Toggle("This is monthly", isOn: $purchaseIsMonthly)

                Button {
                    runAffordabilityCheck()
                } label: {
                    Label("Ask Clarity", systemImage: "sparkles")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(PrimaryClarityButtonStyle())

                if let decision {
                    AffordabilityResultCard(decision: decision)
                }
            }
        }
        .padding(18)
        .clarityCard(radius: 20)
    }

    private func wrappedPanel(wrapped: MoneyWrapped) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            MoneyWrappedCard(wrapped: wrapped)

            HStack(spacing: 10) {
                Toggle("Amounts", isOn: $shareShowsAmounts)
                    .font(.caption.weight(.semibold))
                Toggle("Names", isOn: $shareShowsMerchants)
                    .font(.caption.weight(.semibold))
            }

            HStack(spacing: 12) {
                Button {
                    createShareCard()
                } label: {
                    Label("Create card", systemImage: "photo")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(PrimaryClarityButtonStyle())

                if let shareCardURL {
                    ShareLink(item: shareCardURL) {
                        Label("Share", systemImage: "square.and.arrow.up")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(SecondaryClarityButtonStyle())
                }
            }
        }
        .padding(18)
        .clarityCard(radius: 20)
    }

    private var subscriptionReviewPanel: some View {
        let items = Array(store.subscriptionIntelligence.prefix(5))

        return VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "Review recurring", systemImage: "calendar.badge.clock")

            if items.isEmpty {
                EmptyStateView(title: "No recurring charges yet", message: "Sync more history to find subscriptions.", symbolName: "calendar")
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                        SubscriptionIntelligenceRow(item: item) {
                            store.setRecurringCharge(item.subscription, correction: item.isIgnored ? nil : .ignored)
                        }

                        if index < items.count - 1 {
                            Divider().padding(.leading, 52)
                        }
                    }
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 8)
                .clarityCard(radius: 20)
            }
        }
    }

    private func runAffordabilityCheck() {
        let cleaned = purchasePrice
            .replacingOccurrences(of: "$", with: "")
            .replacingOccurrences(of: ",", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let price = Double(cleaned), price > 0 else {
            store.lastErrorMessage = "Enter a price first."
            return
        }

        decision = FinanceCoachEngine.affordabilityDecision(
            price: price,
            category: purchaseCategory,
            isMonthly: purchaseIsMonthly,
            transactions: store.filteredTransactions,
            accounts: store.filteredAccounts,
            anchor: store.reportingMonthAnchor
        )
    }

    private func createShareCard() {
        do {
            shareCardURL = try ShareCardExporter.exportWrappedCard(
                wrapped: store.moneyWrapped,
                showAmounts: shareShowsAmounts,
                showMerchants: shareShowsMerchants
            )
            store.statusMessage = "Share card created."
        } catch {
            store.lastErrorMessage = error.localizedDescription
        }
    }
}

private enum CoachTool: String, CaseIterable, Identifiable {
    case afford = "Afford?"
    case budget = "Budget"
    case wrapped = "Wrapped"
    case review = "Review"

    var id: String { rawValue }

    var symbolName: String {
        switch self {
        case .afford: "questionmark.circle.fill"
        case .budget: "chart.pie.fill"
        case .wrapped: "square.and.arrow.up"
        case .review: "calendar.badge.clock"
        }
    }
}

private struct CoachHeroCard: View {
    var personality: SpendingPersonality
    var primaryInsight: MoneyInsight?
    var monthTotal: Double
    var comparison: SpendingTrends.Comparison

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 14) {
                IconBadge(symbolName: personality.symbolName)

                VStack(alignment: .leading, spacing: 5) {
                    Text(primaryInsight?.title ?? personality.title)
                        .font(.title2.weight(.bold))
                        .foregroundStyle(ClarityColor.primaryText)
                        .lineLimit(2)
                        .minimumScaleFactor(0.78)

                    Text(primaryInsight?.action ?? personality.subtitle)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(ClarityColor.secondaryText)
                        .lineLimit(2)
                }

                Spacer(minLength: 0)
            }

            HStack(alignment: .bottom) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("This month")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(ClarityColor.secondaryText)
                    Text(MoneyFormat.currency(monthTotal))
                        .font(.system(size: 34, weight: .bold))
                        .foregroundStyle(ClarityColor.primaryText)
                        .lineLimit(1)
                        .minimumScaleFactor(0.65)
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 4) {
                    Label(comparison.title, systemImage: comparison.isIncrease ? "arrow.up.right" : "arrow.down.right")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(comparison.isIncrease ? ClarityColor.red : ClarityColor.green)
                    Text(comparison.caption)
                        .font(.caption)
                        .foregroundStyle(ClarityColor.mutedText)
                        .multilineTextAlignment(.trailing)
                        .lineLimit(2)
                }
                .frame(maxWidth: 150, alignment: .trailing)
            }
        }
        .padding(18)
        .clarityCard(radius: 22)
    }
}

private struct CoachMetricTile: View {
    var title: String
    var value: String
    var caption: String
    var symbolName: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: symbolName)
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(ClarityColor.primaryText)
                .frame(width: 30, height: 30)
                .background(Circle().fill(ClarityColor.panelElevated))

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(ClarityColor.secondaryText)

                Text(value)
                    .font(.headline.weight(.bold))
                    .foregroundStyle(ClarityColor.primaryText)
                    .lineLimit(1)
                    .minimumScaleFactor(0.65)

                Text(caption)
                    .font(.caption)
                    .foregroundStyle(ClarityColor.mutedText)
                    .lineLimit(1)
            }
        }
        .padding(14)
        .frame(width: 148, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(ClarityColor.panel))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(ClarityColor.stroke))
    }
}

private struct CompactInsightRow: View {
    var insight: MoneyInsight

    var body: some View {
        HStack(spacing: 12) {
            IconBadge(symbolName: insight.symbolName, tint: toneColor)

            VStack(alignment: .leading, spacing: 4) {
                Text(insight.title)
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(ClarityColor.primaryText)
                    .lineLimit(1)

                Text(insight.action)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(ClarityColor.secondaryText)
                    .lineLimit(2)
            }

            Spacer(minLength: 0)

            if let amount = insight.amount {
                Text(MoneyFormat.compact(amount))
                    .font(.caption.weight(.bold))
                    .foregroundStyle(ClarityColor.primaryText)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(Capsule().fill(ClarityColor.panelElevated))
            }
        }
        .padding(.vertical, 10)
    }

    private var toneColor: Color {
        switch insight.tone {
        case .good: ClarityColor.green
        case .warning: ClarityColor.purple
        case .urgent: ClarityColor.red
        case .neutral: ClarityColor.blue
        }
    }
}

private struct CoachToolButton: View {
    var tool: CoachTool
    var isSelected: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: tool.symbolName)
                    .font(.system(size: 15, weight: .bold))
                Text(tool.rawValue)
                    .font(.subheadline.weight(.bold))
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .foregroundStyle(isSelected ? ClarityColor.primaryButtonText : ClarityColor.primaryText)
            .padding(.horizontal, 14)
            .padding(.vertical, 14)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(isSelected ? ClarityColor.primaryButtonBackground : ClarityColor.panelElevated)
            )
        }
        .buttonStyle(.plain)
    }
}

private struct PersonalityCard: View {
    var personality: SpendingPersonality

    var body: some View {
        HStack(spacing: 14) {
            IconBadge(symbolName: personality.symbolName)

            VStack(alignment: .leading, spacing: 4) {
                Text(personality.title)
                    .font(.title3.weight(.bold))
                    .foregroundStyle(ClarityColor.primaryText)

                Text(personality.subtitle)
                    .font(.subheadline)
                    .foregroundStyle(ClarityColor.secondaryText)
            }

            Spacer()
        }
        .padding(18)
        .clarityCard(radius: 22)
    }
}

private struct InsightCard: View {
    var insight: MoneyInsight

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                IconBadge(symbolName: insight.symbolName, tint: toneColor)

                VStack(alignment: .leading, spacing: 5) {
                    Text(insight.title)
                        .font(.headline.weight(.bold))
                        .foregroundStyle(ClarityColor.primaryText)

                    Text(insight.message)
                        .font(.subheadline)
                        .foregroundStyle(ClarityColor.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer()
            }

            Text(insight.action)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(ClarityColor.primaryText)
                .padding(.leading, 52)

            ShareLink(item: insight.shareLine) {
                Label("Share insight", systemImage: "square.and.arrow.up")
                    .font(.caption.weight(.bold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(ClarityColor.secondaryText)
            .padding(.leading, 52)
        }
        .padding(18)
        .clarityCard(radius: 20)
    }

    private var toneColor: Color {
        switch insight.tone {
        case .good: ClarityColor.green
        case .warning: ClarityColor.purple
        case .urgent: ClarityColor.red
        case .neutral: ClarityColor.blue
        }
    }
}

private struct MoneyWrappedCard: View {
    var wrapped: MoneyWrapped

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(wrapped.monthTitle)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(ClarityColor.secondaryText)

                    Text("Your month, translated")
                        .font(.title2.weight(.bold))
                        .foregroundStyle(ClarityColor.primaryText)
                }

                Spacer()

                IconBadge(symbolName: "sparkles")
            }

            VStack(spacing: 0) {
                DetailStatRow(title: "Total spent", value: MoneyFormat.currency(wrapped.totalSpent))
                Divider().overlay(ClarityColor.stroke)
                DetailStatRow(title: "Top category", value: wrapped.topCategory?.title ?? "Still learning")
                Divider().overlay(ClarityColor.stroke)
                DetailStatRow(title: "Top merchant", value: wrapped.topMerchant ?? "Still learning")
                Divider().overlay(ClarityColor.stroke)
                DetailStatRow(title: "Subscriptions", value: "\(MoneyFormat.currency(wrapped.subscriptionsTotal))/mo")
                Divider().overlay(ClarityColor.stroke)
                DetailStatRow(title: "Expensive day", value: wrapped.expensiveDay)
            }
        }
        .padding(18)
        .clarityCard(radius: 22)
    }
}

private struct AffordabilityResultCard: View {
    var decision: AffordabilityDecision

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                IconBadge(symbolName: decision.verdict.symbolName)

                VStack(alignment: .leading, spacing: 4) {
                    Text(decision.verdict.title)
                        .font(.headline.weight(.bold))
                        .foregroundStyle(ClarityColor.primaryText)

                    Text(decision.message)
                        .font(.subheadline)
                        .foregroundStyle(ClarityColor.secondaryText)
                }
            }

            Text(decision.impact)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(ClarityColor.primaryText)

            Text(decision.suggestion)
                .font(.subheadline)
                .foregroundStyle(ClarityColor.secondaryText)
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(ClarityColor.panelElevated))
    }
}

private struct BudgetControlRow: View {
    var budget: BudgetCategory
    var setLimit: (Double) -> Void

    private var remaining: Double {
        budget.limit - budget.spent
    }

    private var progressColor: Color {
        if budget.spent > budget.limit { return ClarityColor.red }
        if budget.progress > 0.82 { return ClarityColor.purple }
        return ClarityColor.primaryText
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Label(budget.category.title, systemImage: budget.category.symbolName)
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(ClarityColor.primaryText)

                Spacer()

                Text("\(MoneyFormat.currency(budget.spent)) / \(MoneyFormat.currency(budget.limit))")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(ClarityColor.secondaryText)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }

            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(ClarityColor.panelElevated)

                    Capsule()
                        .fill(progressColor)
                        .frame(width: geometry.size.width * budget.progress)
                }
            }
            .frame(height: 8)

            HStack(spacing: 10) {
                Text(remaining >= 0 ? "\(MoneyFormat.currency(remaining)) left" : "\(MoneyFormat.currency(abs(remaining))) over")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(remaining >= 0 ? ClarityColor.secondaryText : ClarityColor.red)

                Spacer()

                Button {
                    setLimit(max(0, budget.limit - 25))
                } label: {
                    Image(systemName: "minus")
                        .frame(width: 30, height: 30)
                }
                .buttonStyle(.plain)
                .background(Circle().fill(ClarityColor.panelElevated))

                Button {
                    setLimit(budget.limit + 25)
                } label: {
                    Image(systemName: "plus")
                        .frame(width: 30, height: 30)
                }
                .buttonStyle(.plain)
                .background(Circle().fill(ClarityColor.panelElevated))
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(ClarityColor.panelElevated.opacity(0.6)))
    }
}

private struct SubscriptionIntelligenceRow: View {
    var item: SubscriptionIntelligence
    var toggleCorrection: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            IconBadge(symbolName: item.subscription.recurringKind.symbolName)

            VStack(alignment: .leading, spacing: 4) {
                Text(item.subscription.displayName)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(ClarityColor.primaryText)
                    .strikethrough(item.isIgnored)

                Text("\(item.statusLine) • \(MoneyFormat.currency(item.totalPaidThisYear)) this year")
                    .font(.caption)
                    .foregroundStyle(ClarityColor.secondaryText)
                    .lineLimit(1)
            }

            Spacer()

            Button(item.isIgnored ? "Restore" : "Hide") {
                toggleCorrection()
            }
            .font(.caption.weight(.bold))
            .buttonStyle(.plain)
            .foregroundStyle(ClarityColor.primaryText)
        }
        .padding(.vertical, 10)
    }
}

private struct DetailStatRow: View {
    var title: String
    var value: String

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(.subheadline)
                .foregroundStyle(ClarityColor.secondaryText)

            Spacer()

            Text(value)
                .font(.subheadline.weight(.bold))
                .foregroundStyle(ClarityColor.primaryText)
                .multilineTextAlignment(.trailing)
        }
        .padding(.vertical, 10)
    }
}
