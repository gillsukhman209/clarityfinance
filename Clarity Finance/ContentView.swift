import SwiftUI
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

struct ContentView: View {
    @Environment(\.scenePhase) private var scenePhase

    @Bindable var store: FinanceStore
    @State private var plaidWebSession: PlaidWebSession?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                connectCard
                accountsCard
                statusArea
            }
            .padding(24)
            .frame(maxWidth: 760, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clarityBackground()
        .sheet(item: $plaidWebSession) { session in
            PlaidLinkSheet(store: store, session: session)
        }
        .onChange(of: scenePhase) { _, newPhase in
            guard newPhase == .active else { return }
            Task { await store.importCompletedHostedLinkWhenAppReturns() }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Clarity")
                .font(.system(size: 38, weight: .bold))
                .foregroundStyle(ClarityColor.primaryText)

            Text("Connect your accounts first. Everything else is being rebuilt from a clean base.")
                .font(.subheadline)
                .foregroundStyle(ClarityColor.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var connectCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionHeader(title: "Bank connection", systemImage: "building.columns.fill")

            Text("Plaid opens inside Clarity now. Finish your bank login, then tap Done - Import Accounts.")
                .font(.subheadline)
                .foregroundStyle(ClarityColor.secondaryText)

            Button {
                store.recordDiagnostic("Connect Real Bank button tapped on clean connection screen.")
                Task {
                    await store.connectRealBank()
                    if let hostedLinkURL = store.hostedLinkSession?.hostedLinkURL {
                        store.recordDiagnostic("Presenting Plaid Hosted Link in app web sheet.")
                        plaidWebSession = PlaidWebSession(url: hostedLinkURL)
                    } else {
                        store.recordDiagnostic("No Hosted Link URL available after connectRealBank().")
                    }
                }
            } label: {
                Label("Connect real bank", systemImage: "link.badge.plus")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(PrimaryClarityButtonStyle())
            .disabled(store.isSyncing)

            if let hostedLinkSession = store.hostedLinkSession {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Plaid link ready")
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(ClarityColor.primaryText)

                    Button {
                        store.recordDiagnostic("Reopening pending Plaid Hosted Link in app web sheet.")
                        plaidWebSession = PlaidWebSession(url: hostedLinkSession.hostedLinkURL)
                    } label: {
                        Label("Open Plaid in app", systemImage: "rectangle.portrait.and.arrow.right")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(SecondaryClarityButtonStyle())

                    Button {
                        Task { await store.finishRealBankConnection() }
                    } label: {
                        Label("Done - Import Accounts", systemImage: "square.and.arrow.down.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(PrimaryClarityButtonStyle())
                    .disabled(store.isSyncing)
                }
                .padding(14)
                .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(ClarityColor.panelElevated))
            }

            Divider()

            Button {
                Task { await store.connectSandboxInstitution() }
            } label: {
                Label("Connect Plaid sandbox", systemImage: "testtube.2")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(SecondaryClarityButtonStyle())
            .disabled(store.isSyncing)
        }
        .padding(18)
        .clarityCard(radius: 20)
    }

    private var accountsCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                SectionHeader(title: "Connected accounts", systemImage: "wallet.pass.fill")

                Button {
                    Task { await store.syncAllConnections() }
                } label: {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .font(.system(size: 16, weight: .semibold))
                        .frame(width: 36, height: 36)
                }
                .buttonStyle(.plain)
                .disabled(store.isSyncing || store.data.connections.isEmpty)
                .accessibilityLabel("Refresh accounts")
            }

            if store.data.accounts.isEmpty {
                EmptyStateView(
                    title: "No accounts yet",
                    message: "Connect a real bank to verify the Plaid flow before we rebuild spending features.",
                    symbolName: "wallet.pass"
                )
            } else {
                ForEach(store.data.accounts) { account in
                    AccountRow(account: account)

                    if account.id != store.data.accounts.last?.id {
                        Divider()
                    }
                }
            }

            Button(role: .destructive) {
                store.clearLocalData()
            } label: {
                Label("Clear local data", systemImage: "trash")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(SecondaryClarityButtonStyle())
        }
        .padding(18)
        .clarityCard(radius: 20)
    }

    @ViewBuilder
    private var statusArea: some View {
        if let statusMessage = store.statusMessage {
            StatusBanner(message: statusMessage, isError: false)
        }

        if let lastErrorMessage = store.lastErrorMessage {
            StatusBanner(message: lastErrorMessage, isError: true)
        }

        PlaidDiagnosticsCard(
            logText: store.diagnosticsText,
            copy: {
                copyDiagnostics(store.diagnosticsText)
                store.recordDiagnostic("Diagnostics copied to clipboard.")
            },
            clear: store.clearDiagnostics
        )
    }

    private func copyDiagnostics(_ text: String) {
        #if os(iOS)
        UIPasteboard.general.string = text
        #elseif os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #endif
    }
}

#Preview {
    ContentView(store: FinanceStore())
}
