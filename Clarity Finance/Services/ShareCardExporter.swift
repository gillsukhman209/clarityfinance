import SwiftUI

#if os(macOS)
import AppKit
#else
import UIKit
#endif

@MainActor
enum ShareCardExporter {
    static func exportWrappedCard(
        wrapped: MoneyWrapped,
        showAmounts: Bool,
        showMerchants: Bool
    ) throws -> URL {
        let content = MoneyWrappedShareCard(
            wrapped: wrapped,
            showAmounts: showAmounts,
            showMerchants: showMerchants
        )
        .frame(width: 1080, height: 1920)

        let renderer = ImageRenderer(content: content)
        renderer.scale = 1

#if os(macOS)
        guard let image = renderer.nsImage,
              let tiffData = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData),
              let data = bitmap.representation(using: .png, properties: [:])
        else {
            throw ShareCardExportError.renderFailed
        }
#else
        guard let image = renderer.uiImage,
              let data = image.pngData()
        else {
            throw ShareCardExportError.renderFailed
        }
#endif

        let url = FileManager.default.temporaryDirectory
            .appending(path: "clarity-money-wrapped-\(UUID().uuidString).png")
        try data.write(to: url, options: .atomic)
        return url
    }
}

enum ShareCardExportError: LocalizedError {
    case renderFailed

    var errorDescription: String? {
        "Could not create the share card image."
    }
}
