import CoFleetCore
import Foundation
import SwiftUI

#if canImport(ImageIO)
import ImageIO
#endif

public struct CoFleetPetSpriteView: View {
    private let name: String
    private let manifest: CoFleetPetManifest?
    private let action: CoFleetActionIndicator
    private let size: CGFloat
    private let atlas: CGImage?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(
        name: String,
        manifest: CoFleetPetManifest?,
        asset: CoFleetPetAsset?,
        action: CoFleetActionIndicator,
        size: CGFloat = 58
    ) {
        self.name = name
        self.manifest = manifest
        self.action = action
        self.size = size
        atlas = Self.decodeAtlas(manifest: manifest, asset: asset)
    }

    public var body: some View {
        if let manifest, let atlas {
            TimelineView(.animation(minimumInterval: 0.12, paused: reduceMotion)) { context in
                atlasFrame(
                    atlas,
                    manifest: manifest,
                    column: reduceMotion ? 0 : frameIndex(at: context.date),
                    row: animationRow
                )
            }
            .frame(width: size, height: size)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(manifest.displayName), pet for \(name)")
        } else {
            CoFleetPetPlaceholder(name: name, size: size)
        }
    }

    private func atlasFrame(
        _ image: CGImage,
        manifest: CoFleetPetManifest,
        column: Int,
        row: Int
    ) -> some View {
        let cellHeight = size
        let cellWidth = cellHeight * CGFloat(manifest.frameWidth) / CGFloat(manifest.frameHeight)
        let atlasWidth = cellWidth * CGFloat(manifest.columns)
        let atlasHeight = cellHeight * CGFloat(manifest.rows)
        return GeometryReader { proxy in
            Image(decorative: image, scale: 1)
                .resizable()
                .interpolation(.none)
                .antialiased(false)
                .frame(width: atlasWidth, height: atlasHeight)
                .offset(
                    x: ((proxy.size.width - cellWidth) / 2) - (CGFloat(column) * cellWidth),
                    y: -(CGFloat(row) * cellHeight)
                )
        }
        .clipped()
    }

    private func frameIndex(at date: Date) -> Int {
        Int(date.timeIntervalSinceReferenceDate / 0.12) % 8
    }

    private var animationRow: Int {
        switch action {
        case .idle: 0
        case .replied: 3
        case .approvalNeeded, .questionAsked: 6
        case .thinking, .runningCommand, .reasoning, .working: 7
        }
    }

    private static func decodeAtlas(
        manifest: CoFleetPetManifest?,
        asset: CoFleetPetAsset?
    ) -> CGImage? {
        guard let manifest, let asset,
              manifest.hostID == asset.hostID,
              manifest.id == asset.petID,
              manifest.spritesheetPath == asset.assetName,
              (try? CoFleetPetManifestValidator.validate(manifest)) != nil else { return nil }
        #if canImport(ImageIO)
        guard let source = CGImageSourceCreateWithData(asset.data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, [
                  kCGImageSourceShouldCache: true,
                  kCGImageSourceShouldAllowFloat: false,
              ] as CFDictionary),
              image.width == manifest.pixelWidth,
              image.height == manifest.pixelHeight else { return nil }
        return image
        #else
        return nil
        #endif
    }
}
