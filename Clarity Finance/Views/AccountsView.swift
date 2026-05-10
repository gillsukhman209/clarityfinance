import SwiftUI
import UniformTypeIdentifiers
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

struct AccountsView: View {
    @Bindable var store: FinanceStore

    var body: some View {
        ScrollView {
            AccountsContent(store: store, showsTitle: true)
                .padding(24)
                .frame(maxWidth: 900, alignment: .leading)
        }
        .clarityTabContentPadding()
    }
}

struct AccountsContent: View {
    @Bindable var store: FinanceStore
    var showsTitle = true
    var showsStatusAndDiagnostics = true
    @State private var isImportingStatement = false
    @State private var plaidWebSession: PlaidWebSession?
    @State private var accountPendingRemoval: FinancialAccount?
    @State private var institutionID = PlaidSandboxInstitution.firstPlatypus.id
    @State private var institutionName = PlaidSandboxInstitution.firstPlatypus.name
    @State private var profile: PlaidSandboxProfile = .transactionsDynamic

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            if showsTitle {
                ScreenTitle(title: "Accounts", subtitle: "All connected banks, cards, and manual statements.")
            }

            HStack(spacing: 12) {
                MetricCard(title: "Assets", value: MoneyFormat.currency(store.assetsTotal), caption: "Cash and investments", symbolName: "banknote.fill", tint: ClarityColor.green)
                MetricCard(title: "Liabilities", value: MoneyFormat.currency(store.liabilitiesTotal), caption: "Credit and loans", symbolName: "creditcard.fill", tint: ClarityColor.red)
            }

            if !store.data.accounts.isEmpty {
                AccountFilterBar(accounts: store.data.accounts, selectedAccountIDs: $store.selectedAccountIDs)
            }

            VStack(alignment: .leading, spacing: 8) {
                SectionHeader(title: "Connected accounts")

                    if store.filteredAccounts.isEmpty {
                        EmptyStateView(
                            title: "No accounts connected",
                            message: "Use Connect Real Bank for your own accounts, or import an Apple Card statement.",
                            symbolName: "wallet.pass"
                        )
                    } else {
                        ForEach(store.filteredAccounts) { account in
                            AccountRow(account: account) {
                                accountPendingRemoval = account
                            }
                        }
                    }
                }
                .padding(18)
                .clarityCard(radius: 20)

                VStack(alignment: .leading, spacing: 14) {
                    SectionHeader(title: "Connect real bank")

                    Text("This opens Plaid in Production so you can sign in to your actual bank and pull real accounts and transactions.")
                        .font(.subheadline)
                        .foregroundStyle(ClarityColor.secondaryText)

	                    Button {
	                        store.recordDiagnostic("Connect Real Bank button tapped in AccountsView.")
	                        Task {
	                            await store.connectRealBank()
                            if let hostedLinkURL = store.hostedLinkSession?.hostedLinkURL {
                                store.recordDiagnostic("Presenting Plaid Hosted Link in app web sheet from AccountsView.")
                                plaidWebSession = PlaidWebSession(url: hostedLinkURL)
                            } else {
                                store.recordDiagnostic("No Hosted Link URL available after connectRealBank().")
                            }
                        }
                    } label: {
                        Label("Connect Real Bank", systemImage: "building.columns.fill")
                            .frame(maxWidth: .infinity)
	                    }
	                    .buttonStyle(PrimaryClarityButtonStyle())
	                    .disabled(store.isSyncing)

	                    Button {
	                        Task { await store.backfillTransactionHistory() }
	                    } label: {
	                        Label("Backfill 24 Months", systemImage: "clock.arrow.circlepath")
	                            .frame(maxWidth: .infinity)
	                    }
	                    .buttonStyle(SecondaryClarityButtonStyle())
	                    .disabled(store.isSyncing || store.data.connections.isEmpty)

	                    if let hostedLinkSession = store.hostedLinkSession {
                        PlaidHostedLinkCard(
                            session: hostedLinkSession,
                            isSyncing: store.isSyncing,
                            open: {
                                store.recordDiagnostic("Open Plaid button tapped. urlHost=\($0.host ?? "unknown").")
                                plaidWebSession = PlaidWebSession(url: $0)
                            },
                            finish: {
                                store.recordDiagnostic("I Finished Plaid - Import Accounts button tapped.")
                                Task { await store.finishRealBankConnection() }
                            }
                        )
                    }

                    Text("If Plaid says access is not enabled, your Plaid dashboard needs Production or Trial access for Transactions.")
                        .font(.caption)
                        .foregroundStyle(ClarityColor.secondaryText)
                }
                .padding(18)
                .clarityCard(radius: 20)

                VStack(alignment: .leading, spacing: 14) {
                    SectionHeader(title: "Test with Sandbox")

                    VStack(alignment: .leading, spacing: 6) {
                        Text("Institution name")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(ClarityColor.secondaryText)
                        TextField("First Platypus Bank", text: $institutionName)
                            .textFieldStyle(.plain)
                            .padding(13)
                            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(ClarityColor.panelElevated))
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        Text("Institution ID")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(ClarityColor.secondaryText)
                        TextField("ins_109508", text: $institutionID)
                            .textFieldStyle(.plain)
                            .padding(13)
                            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(ClarityColor.panelElevated))
                    }

                    Picker("Sandbox profile", selection: $profile) {
                        ForEach(PlaidSandboxProfile.allCases) { profile in
                            Text(profile.title).tag(profile)
                        }
                    }
                    .pickerStyle(.segmented)

                    Button {
                        Task {
                            await store.connectSandboxInstitution(
                                institutionID: institutionID,
                                institutionName: institutionName,
                                profile: profile
                            )
                        }
                    } label: {
                        Label(store.data.connections.isEmpty ? "Connect Sandbox Test Bank" : "Add another test bank", systemImage: "link.badge.plus")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(PrimaryClarityButtonStyle())
                    .disabled(store.isSyncing)

                    Text("Sandbox is test-only. It does not connect to your real bank or show your real balances.")
                        .font(.caption)
                        .foregroundStyle(ClarityColor.secondaryText)
                }
                .padding(18)
                .clarityCard(radius: 20)

                VStack(alignment: .leading, spacing: 14) {
                    SectionHeader(title: "Manual statements")

                    Button {
                        isImportingStatement = true
                    } label: {
                        Label("Import Apple Card PDF", systemImage: "doc.badge.plus")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(SecondaryClarityButtonStyle())
                }
                .padding(18)
                .clarityCard(radius: 20)

            if showsStatusAndDiagnostics {
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
                    clear: {
                        store.clearDiagnostics()
                    }
                )
            }
        }
        .fileImporter(
            isPresented: $isImportingStatement,
            allowedContentTypes: [.pdf],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                guard let url = urls.first else { return }
                store.importAppleCardStatement(from: url)
            case .failure(let error):
                store.lastErrorMessage = error.localizedDescription
            }
        }
        .sheet(item: $plaidWebSession) { session in
            PlaidLinkSheet(store: store, session: session)
        }
        .alert(item: $accountPendingRemoval) { account in
            Alert(
                title: Text("Remove \(account.displayName)?"),
                message: Text("This removes the account and every transaction, subscription, bill, budget number, and total linked to it from Clarity."),
                primaryButton: .destructive(Text("Remove")) {
                    store.removeAccount(account)
                },
                secondaryButton: .cancel()
            )
        }
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

private struct PlaidHostedLinkCard: View {
    var session: PlaidHostedLinkSession
    var isSyncing: Bool
    var open: (URL) -> Void
    var finish: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "checkmark.seal.fill")
                    .foregroundStyle(ClarityColor.green)
                Text("Plaid link ready")
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(ClarityColor.primaryText)
                Spacer()
            }

            Text("Open Plaid and sign in to your bank inside Clarity. When your bank says you connected, tap Done to import accounts.")
                .font(.caption)
                .foregroundStyle(ClarityColor.secondaryText)

            Button {
                open(session.hostedLinkURL)
            } label: {
                Label("Open Plaid in app", systemImage: "rectangle.portrait.and.arrow.right")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(SecondaryClarityButtonStyle())
            .disabled(isSyncing)

            Button {
                finish()
            } label: {
                Label("I Finished Plaid - Import Accounts", systemImage: "square.and.arrow.down.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(PrimaryClarityButtonStyle())
            .disabled(isSyncing)

            Text("Clarity also checks automatically when you return to the app.")
                .font(.caption2)
                .foregroundStyle(ClarityColor.secondaryText)

            Text(session.hostedLinkURL.absoluteString)
                .font(.caption2)
                .foregroundStyle(ClarityColor.secondaryText)
                .lineLimit(3)
                .textSelection(.enabled)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(ClarityColor.panelElevated))
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(ClarityColor.panel.opacity(0.8)))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(ClarityColor.stroke)
        )
    }
}

struct PlaidDiagnosticsCard: View {
    var logText: String
    var copy: () -> Void
    var clear: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "stethoscope")
                    .foregroundStyle(ClarityColor.purple)
                Text("Connection diagnostics")
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(ClarityColor.primaryText)
                Spacer()
                Button("Copy Logs", action: copy)
                    .font(.caption.weight(.bold))
                    .buttonStyle(.plain)
                    .foregroundStyle(ClarityColor.purple)
                Button("Clear", action: clear)
                    .font(.caption.weight(.bold))
                    .buttonStyle(.plain)
                    .foregroundStyle(ClarityColor.secondaryText)
            }

            Text(logText.isEmpty ? "No diagnostics yet. Tap Connect Real Bank, then copy this box if nothing changes." : logText)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(ClarityColor.secondaryText)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(ClarityColor.panelElevated))
        }
        .padding(18)
        .clarityCard(radius: 20)
    }
}

struct ScreenTitle: View {
    var title: String
    var subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.title.weight(.bold))
                .foregroundStyle(ClarityColor.primaryText)
            Text(subtitle)
                .font(.footnote)
                .foregroundStyle(ClarityColor.secondaryText)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct PrimaryClarityButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.bold))
            .foregroundStyle(.white)
            .padding(.vertical, 13)
            .padding(.horizontal, 16)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color.black.opacity(configuration.isPressed ? 0.72 : 1))
            )
    }
}

struct SecondaryClarityButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.bold))
            .foregroundStyle(ClarityColor.primaryText)
            .padding(.vertical, 13)
            .padding(.horizontal, 16)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(ClarityColor.panelElevated.opacity(configuration.isPressed ? 0.72 : 1))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(ClarityColor.stroke)
            )
    }
}
