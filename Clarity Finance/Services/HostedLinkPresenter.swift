import Foundation

#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

enum HostedLinkPresenter {
    static func open(hostedLinkURL: URL) async throws {
#if os(iOS)
        await UIApplication.shared.open(hostedLinkURL)
#elseif os(macOS)
        NSWorkspace.shared.open(hostedLinkURL)
#endif
    }
}
