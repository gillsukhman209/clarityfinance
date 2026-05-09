import SwiftUI

struct SettingsView: View {
    @Bindable var store: FinanceStore
    @State private var clientID = ""
    @State private var sandboxSecret = ""
    @State private var productionSecret = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                ScreenTitle(title: "Settings", subtitle: "Local Plaid setup for Sandbox and personal bank linking.")

                VStack(alignment: .leading, spacing: 14) {
                    SectionHeader(title: "Plaid credentials")

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

                    Button {
                        store.saveCredentials(
                            clientID: clientID,
                            sandboxSecret: sandboxSecret,
                            productionSecret: productionSecret
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

                VStack(alignment: .leading, spacing: 14) {
                    SectionHeader(title: "Actions")

                    Button {
                        Task { await store.syncAllConnections() }
                    } label: {
                        Label(store.data.connections.isEmpty ? "Connect Sandbox data" : "Sync Sandbox data", systemImage: "arrow.triangle.2.circlepath")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(PrimaryClarityButtonStyle())
                    .disabled(store.isSyncing)

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
            }
            .padding(24)
            .frame(maxWidth: 760, alignment: .leading)
        }
        .onAppear {
            clientID = store.credentials.clientID
            sandboxSecret = store.credentials.sandboxSecret
            productionSecret = store.credentials.productionSecret
        }
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
