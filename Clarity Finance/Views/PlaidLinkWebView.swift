import SwiftUI
import WebKit

struct PlaidWebSession: Identifiable {
    let id = UUID()
    let url: URL
}

struct PlaidLinkSheet: View {
    @Environment(\.dismiss) private var dismiss

    @Bindable var store: FinanceStore
    var session: PlaidWebSession

    var body: some View {
        NavigationStack {
            PlaidLinkWebView(url: session.url)
                .ignoresSafeArea(edges: .bottom)
                .navigationTitle("Plaid")
                #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
                #endif
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Close") {
                            store.recordDiagnostic("Plaid in-app web sheet closed without import.")
                            dismiss()
                        }
                    }

                    ToolbarItem(placement: .confirmationAction) {
                        Button {
                            Task {
                                store.recordDiagnostic("Done - Import Accounts tapped from Plaid in-app web sheet.")
                                await store.finishRealBankConnection()
                                if store.hostedLinkSession == nil {
                                    dismiss()
                                }
                            }
                        } label: {
                            Text("Done")
                                .fontWeight(.semibold)
                        }
                        .disabled(store.isSyncing)
                    }
                }
        }
        #if os(macOS)
        .frame(minWidth: 720, minHeight: 720)
        #endif
    }
}

#if os(iOS)
struct PlaidLinkWebView: UIViewRepresentable {
    let url: URL

    func makeUIView(context: Context) -> WKWebView {
        let webView = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        webView.allowsBackForwardNavigationGestures = true
        webView.load(URLRequest(url: url))
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        guard webView.url != url else { return }
        webView.load(URLRequest(url: url))
    }
}
#elseif os(macOS)
struct PlaidLinkWebView: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> WKWebView {
        let webView = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        webView.allowsBackForwardNavigationGestures = true
        webView.load(URLRequest(url: url))
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        guard webView.url != url else { return }
        webView.load(URLRequest(url: url))
    }
}
#endif
