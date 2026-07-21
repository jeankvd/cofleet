import CoFleetCore
import CoFleetTransport
import Foundation
import ImageIO
import SwiftUI
import WidgetKit

/// Renders the small, static pet frame carried in widget/Watch snapshots.
/// Invalid or corrupt previews fall back to CoFleet's neutral placeholder.
public struct CoFleetPetPreviewView: View {
    private let name: String
    private let size: CGFloat
    private let image: CGImage?

    public init(name: String, preview: CoFleetPetPreview?, size: CGFloat) {
        self.name = name
        self.size = size
        image = Self.decode(preview)
    }

    public var body: some View {
        if let image {
            fullColorImage(image)
                .frame(width: size, height: size)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Pet for \(name)")
        } else {
            CoFleetPetPlaceholder(name: name, size: size)
        }
    }

    @ViewBuilder
    private func fullColorImage(_ image: CGImage) -> some View {
        if #available(iOS 18.0, macOS 15.0, watchOS 11.0, *) {
            Image(decorative: image, scale: 1, orientation: .up)
                .resizable()
                .interpolation(.none)
                .antialiased(false)
                .widgetAccentedRenderingMode(.fullColor)
                .aspectRatio(contentMode: .fit)
        } else {
            pixelImage(image)
        }
    }

    private func pixelImage(_ image: CGImage) -> some View {
        Image(decorative: image, scale: 1, orientation: .up)
            .resizable()
            .interpolation(.none)
            .antialiased(false)
            .aspectRatio(contentMode: .fit)
    }

    private static func decode(_ preview: CoFleetPetPreview?) -> CGImage? {
        guard let preview,
              (try? CoFleetWatchRelayCodec.validate(preview)) != nil,
              let source = CGImageSourceCreateWithData(preview.data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, [
                  kCGImageSourceShouldCache: true,
                  kCGImageSourceShouldAllowFloat: false,
              ] as CFDictionary),
              image.width == preview.pixelWidth,
              image.height == preview.pixelHeight else { return nil }
        return image
    }
}
