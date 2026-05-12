import SwiftUI
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

struct SettingsView: View {
    @Bindable var store: FinanceStore
    @State private var clientID = ""
    @State private var sandboxSecret = ""
    @State private var productionSecret = ""
    @State private var linkCustomizationName = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                ScreenTitle(title: "Settings", subtitle: "Account linking, notifications, and cloud restore.")

                #if DEBUG
                VStack(alignment: .leading, spacing: 14) {
                    SectionHeader(title: "Developer credentials")

                    VStack(alignment: .leading, spacing: 6) {
                        Text("Client ID")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(ClarityColor.secondaryText)

                        TextField("Plaid client ID", text: $clientID)
                            .textFieldStyle(.plain)
                            .padding(13)
                            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(ClarityColor.panelElevated))
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        Text("Sandbox secret")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(ClarityColor.secondaryText)

                        SecureField("Plaid Sandbox secret", text: $sandboxSecret)
                            .textFieldStyle(.plain)
                            .padding(13)
                            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(ClarityColor.panelElevated))
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        Text("Production secret")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(ClarityColor.secondaryText)

                        SecureField("Plaid Production secret", text: $productionSecret)
                            .textFieldStyle(.plain)
                            .padding(13)
                            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(ClarityColor.panelElevated))
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        Text("Plaid Link customization")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(ClarityColor.secondaryText)

                        TextField("Dashboard customization name", text: $linkCustomizationName)
                            .textFieldStyle(.plain)
                            .padding(13)
                            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(ClarityColor.panelElevated))

                        Text("In Plaid Dashboard, use a Link Customization where Account Select is \"Enabled for multiple accounts\", not \"Enabled for all accounts\". Then enter the exact customization name here.")
                            .font(.caption)
                            .foregroundStyle(ClarityColor.secondaryText)
                    }

                    Button {
                        store.saveCredentials(
                            clientID: clientID,
                            sandboxSecret: sandboxSecret,
                            productionSecret: productionSecret,
                            linkCustomizationName: linkCustomizationName
                        )
                    } label: {
                        Label("Save credentials", systemImage: "key.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(PrimaryClarityButtonStyle())

                    Text("Secrets are stored in this device's Keychain. Production should use a backend instead of calling Plaid directly from the app.")
                        .font(.caption)
                        .foregroundStyle(ClarityColor.secondaryText)
                }
                .padding(18)
                .clarityCard(radius: 20)
                #endif

                VStack(alignment: .leading, spacing: 14) {
                    SectionHeader(title: "Accounts")
                    AccountsContent(store: store, showsTitle: false, showsStatusAndDiagnostics: false)
                }

                VStack(alignment: .leading, spacing: 14) {
                    SectionHeader(title: "Actions")

                    Button {
                        Task { await store.syncAllConnections() }
                    } label: {
                        Label("Sync linked banks", systemImage: "arrow.triangle.2.circlepath")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(PrimaryClarityButtonStyle())
                    .disabled(store.isSyncing)

                    Button {
                        Task { await store.restoreCloudData() }
                    } label: {
                        Label("Restore cloud data", systemImage: "icloud.and.arrow.down.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(SecondaryClarityButtonStyle())
                    .disabled(store.isSyncing || !store.isSignedIn)

                    Button {
                        store.clearLocalData()
                    } label: {
                        Label("Clear local data", systemImage: "trash")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(SecondaryClarityButtonStyle())

                    Text("Clearing local data removes saved accounts, transactions, Plaid cursors, budgets, subscriptions, and net worth snapshots from this app. It does not delete your Plaid credentials from Keychain.")
                        .font(.caption)
                        .foregroundStyle(ClarityColor.secondaryText)
                }
                .padding(18)
                .clarityCard(radius: 20)

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
            .padding(24)
            .frame(maxWidth: 900, alignment: .leading)
        }
        .clarityTabContentPadding()
        .onAppear {
            clientID = store.credentials.clientID
            sandboxSecret = store.credentials.sandboxSecret
            productionSecret = store.credentials.productionSecret
            linkCustomizationName = store.credentials.linkCustomizationName
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

struct StatusBanner: View {
    var message: String
    var isError: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .foregroundStyle(isError ? ClarityColor.red : ClarityColor.green)
            Text(message)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(ClarityColor.primaryText)
            Spacer()
        }
        .padding(14)
        .clarityCard(radius: 16)
    }
}
