import SwiftUI

struct ContentView: View {
    @Environment(\.scenePhase) private var scenePhase

    @Bindable var store: FinanceStore
    @State private var selectedSection: AppSection = .overview

    var body: some View {
        Group {
#if os(macOS)
            MacRootView(store: store, selectedSection: $selectedSection)
#else
            MobileRootView(store: store, selectedSection: $selectedSection)
#endif
        }
        .clarityBackground()
        .onChange(of: scenePhase) { _, newPhase in
            guard newPhase == .active else { return }
            Task { await store.importCompletedHostedLinkWhenAppReturns() }
        }
    }
}

private struct MobileRootView: View {
    @Bindable var store: FinanceStore
    @Binding var selectedSection: AppSection

    var body: some View {
        ZStack(alignment: .bottom) {
            screen
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            MobileTabBar(selectedSection: $selectedSection)
        }
    }

    @ViewBuilder
    private var screen: some View {
        switch selectedSection {
        case .overview:
            OverviewView(store: store) { selectedSection = $0 }
        case .accounts:
            AccountsView(store: store)
        case .transactions:
            TransactionsView(store: store)
        case .budget:
            BudgetView(store: store)
        case .subscriptions:
            SubscriptionsView(store: store)
        case .netWorth:
            NetWorthView(store: store)
        case .settings:
            SettingsView(store: store)
        }
    }
}

#if os(macOS)
private struct MacRootView: View {
    @Bindable var store: FinanceStore
    @Binding var selectedSection: AppSection

    var body: some View {
        NavigationSplitView {
            List(AppSection.allCases, selection: $selectedSection) { section in
                Label(section.title, systemImage: section.symbolName)
                    .tag(section)
            }
            .listStyle(.sidebar)
            .navigationTitle("Clarity")
        } detail: {
            screen
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(ClarityColor.page)
        }
        .toolbar {
            ToolbarItem {
                Button {
                    Task { await store.syncAllConnections() }
                } label: {
                    Label("Sync", systemImage: "arrow.triangle.2.circlepath")
                }
                .disabled(store.isSyncing)
            }
        }
    }

    @ViewBuilder
    private var screen: some View {
        switch selectedSection {
        case .overview:
            OverviewView(store: store) { selectedSection = $0 }
        case .accounts:
            AccountsView(store: store)
        case .transactions:
            TransactionsView(store: store)
        case .budget:
            BudgetView(store: store)
        case .subscriptions:
            SubscriptionsView(store: store)
        case .netWorth:
            NetWorthView(store: store)
        case .settings:
            SettingsView(store: store)
        }
    }
}
#endif

private struct MobileTabBar: View {
    @Binding var selectedSection: AppSection

    private let tabs: [AppSection] = [.overview, .transactions, .accounts, .subscriptions, .netWorth, .settings]

    var body: some View {
        HStack {
            ForEach(tabs) { tab in
                Spacer()

                Button {
                    selectedSection = tab
                } label: {
                    Image(systemName: tab.symbolName)
                        .font(.system(size: 19, weight: .semibold))
                        .foregroundStyle(selectedSection == tab ? ClarityColor.primaryText : ClarityColor.mutedText)
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.plain)

                Spacer()
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 12)
        .background(
            Rectangle()
                .fill(ClarityColor.page.opacity(0.94))
                .overlay(alignment: .top) {
                    Rectangle()
                        .fill(ClarityColor.stroke)
                        .frame(height: 1)
                }
                .ignoresSafeArea(edges: .bottom)
        )
    }
}

#Preview {
    ContentView(store: FinanceStore())
}
