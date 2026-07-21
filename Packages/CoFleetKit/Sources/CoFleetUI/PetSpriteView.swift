import CoFleetCore
import CoreGraphics
import Foundation
import SwiftUI

#if canImport(ImageIO)
import ImageIO
#endif

enum CoFleetPetFramePolicy {
    struct Sequence: Equatable, Sendable {
        let row: Int
        let columns: [Int]
    }

    /// Returns only atlas columns that contain at least one visible pixel. If an
    /// action row is empty, fall back to the idle row so changing state never
    /// makes an otherwise valid pet disappear.
    nonisolated static func visibleColumns(
        in atlas: CGImage,
        manifest: CoFleetPetManifest,
        row: Int
    ) -> [Int] {
        sequence(in: atlas, manifest: manifest, row: row).columns
    }

    nonisolated static func sequence(
        in atlas: CGImage,
        manifest: CoFleetPetManifest,
        row: Int
    ) -> Sequence {
        let boundedRow = max(0, min(manifest.rows - 1, row))
        let requested = visibleColumnsOnly(in: atlas, manifest: manifest, row: boundedRow)
        if !requested.isEmpty { return Sequence(row: boundedRow, columns: requested) }
        if boundedRow != 0 {
            let idle = visibleColumnsOnly(in: atlas, manifest: manifest, row: 0)
            if !idle.isEmpty { return Sequence(row: 0, columns: idle) }
        }
        return Sequence(row: boundedRow, columns: [0])
    }

    nonisolated private static func visibleColumnsOnly(
        in atlas: CGImage,
        manifest: CoFleetPetManifest,
        row: Int
    ) -> [Int] {
        (0..<manifest.columns).filter { column in
            let crop = CGRect(
                x: column * manifest.frameWidth,
                y: row * manifest.frameHeight,
                width: manifest.frameWidth,
                height: manifest.frameHeight
            )
            guard let frame = atlas.cropping(to: crop) else { return false }
            return containsVisiblePixel(frame)
        }
    }

    nonisolated private static func containsVisiblePixel(_ image: CGImage) -> Bool {
        let width = image.width
        let height = image.height
        guard width > 0, height > 0 else { return false }
        let bytesPerRow = width * 4
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ), let data = context.data else { return false }
        context.clear(CGRect(x: 0, y: 0, width: width, height: height))
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        let bytes = data.bindMemory(to: UInt8.self, capacity: bytesPerRow * height)
        for pixel in 0..<(width * height) where bytes[pixel * 4 + 3] > 1 {
            return true
        }
        return false
    }
}

public struct CoFleetPetSpriteView: View {
    private let name: String
    private let manifest: CoFleetPetManifest?
    private let asset: CoFleetPetAsset?
    private let action: CoFleetActionIndicator
    private let size: CGFloat
    @State private var loadedAtlas: CoFleetLoadedPetAtlas?

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
        self.asset = asset
        self.action = action
        self.size = size
        let identity = Self.atlasIdentity(manifest: manifest, asset: asset)
        #if canImport(ImageIO)
        if let identity, let cached = CoFleetPetAtlasCache.shared.atlas(forKey: identity) {
            _loadedAtlas = State(initialValue: cached)
        } else {
            _loadedAtlas = State(initialValue: nil)
        }
        #else
        _loadedAtlas = State(initialValue: nil)
        #endif
    }

    public var body: some View {
        Group {
            if let manifest,
               let identity = atlasIdentity,
               let loadedAtlas,
               loadedAtlas.identity == identity {
                TimelineView(.animation(minimumInterval: 0.12, paused: reduceMotion)) { context in
                    let sequence = loadedAtlas.sequence(for: animationRow)
                    atlasFrame(
                        loadedAtlas.image,
                        manifest: manifest,
                        column: loadedAtlas.column(
                            at: context.date,
                            sequence: sequence,
                            paused: reduceMotion
                        ),
                        row: sequence.row
                    )
                }
                .frame(width: size, height: size)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(manifest.displayName), pet for \(name)")
            } else {
                CoFleetPetPlaceholder(name: name, size: size)
            }
        }
        .task(id: atlasIdentity) {
            await loadAtlas()
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

    private var animationRow: Int {
        switch action {
        case .idle: 0
        case .replied: 3
        case .approvalNeeded, .questionAsked: 6
        case .thinking, .runningCommand, .reasoning, .working: 7
        }
    }

    private var atlasIdentity: String? {
        Self.atlasIdentity(manifest: manifest, asset: asset)
    }

    @MainActor
    private func loadAtlas() async {
        guard let manifest, let asset, let identity = atlasIdentity else {
            loadedAtlas = nil
            return
        }

        #if canImport(ImageIO)
        if let cached = CoFleetPetAtlasCache.shared.atlas(forKey: identity) {
            loadedAtlas = cached
            return
        }

        // Atlas validation and ImageIO decompression can be large enough to hitch a
        // scrolling card grid. The first decode runs at utility priority; cached
        // frames remain synchronous and cheap on subsequent renders.
        let decoded = await Task.detached(priority: .utility) {
            Self.decodeAtlas(manifest: manifest, asset: asset, cacheKey: identity)
        }.value

        // SwiftUI can reuse this view state for a different project while decoding.
        // Never publish the old pet into the new identity, and let `.task(id:)`
        // cancel/restart naturally when selection changes.
        guard !Task.isCancelled, atlasIdentity == identity else { return }
        loadedAtlas = decoded
        #else
        loadedAtlas = nil
        #endif
    }

    nonisolated static func atlasIdentity(
        manifest: CoFleetPetManifest?,
        asset: CoFleetPetAsset?
    ) -> String? {
        guard let manifest, let asset,
              manifest.hostID == asset.hostID,
              manifest.id == asset.petID,
              manifest.spritesheetPath == asset.assetName else { return nil }
        return "\(manifest.canonicalIdentity):\(manifest.digest):\(asset.data.count)"
    }

    nonisolated private static func decodeAtlas(
        manifest: CoFleetPetManifest,
        asset: CoFleetPetAsset,
        cacheKey: String
    ) -> CoFleetLoadedPetAtlas? {
        guard manifest.hostID == asset.hostID,
              manifest.id == asset.petID,
              manifest.spritesheetPath == asset.assetName,
              (try? CoFleetPetManifestValidator.validate(manifest)) != nil else { return nil }
        #if canImport(ImageIO)
        if let cached = CoFleetPetAtlasCache.shared.atlas(forKey: cacheKey) {
            return cached
        }
        guard let source = CGImageSourceCreateWithData(asset.data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, [
                  kCGImageSourceShouldCache: true,
                  kCGImageSourceShouldCacheImmediately: true,
                  kCGImageSourceShouldAllowFloat: false,
              ] as CFDictionary),
              image.width == manifest.pixelWidth,
              image.height == manifest.pixelHeight else { return nil }
        let sequencesByRequestedRow = (0..<manifest.rows).map { row in
            CoFleetPetFramePolicy.sequence(in: image, manifest: manifest, row: row)
        }
        let atlas = CoFleetLoadedPetAtlas(
            identity: cacheKey,
            image: image,
            sequencesByRequestedRow: sequencesByRequestedRow
        )
        CoFleetPetAtlasCache.shared.insert(atlas, forKey: cacheKey)
        return atlas
        #else
        return nil
        #endif
    }
}

private struct CoFleetLoadedPetAtlas: @unchecked Sendable {
    let identity: String
    let image: CGImage
    let sequencesByRequestedRow: [CoFleetPetFramePolicy.Sequence]

    func sequence(for row: Int) -> CoFleetPetFramePolicy.Sequence {
        let boundedRow = max(0, min(sequencesByRequestedRow.count - 1, row))
        return sequencesByRequestedRow[boundedRow]
    }

    func column(
        at date: Date,
        sequence: CoFleetPetFramePolicy.Sequence,
        paused: Bool
    ) -> Int {
        let columns = sequence.columns
        guard !columns.isEmpty else { return 0 }
        if paused { return columns[0] }
        let index = Int(date.timeIntervalSinceReferenceDate / 0.12) % columns.count
        return columns[index]
    }
}

#if canImport(ImageIO)
private final class CoFleetPetAtlasCache: @unchecked Sendable {
    static let shared = CoFleetPetAtlasCache()

    private final class AtlasBox: NSObject {
        let atlas: CoFleetLoadedPetAtlas

        init(_ atlas: CoFleetLoadedPetAtlas) {
            self.atlas = atlas
        }
    }

    private let atlases = NSCache<NSString, AtlasBox>()

    private init() {
        atlases.totalCostLimit = 64 * 1_024 * 1_024
        atlases.countLimit = 8
    }

    func atlas(forKey key: String) -> CoFleetLoadedPetAtlas? {
        atlases.object(forKey: key as NSString)?.atlas
    }

    func insert(_ atlas: CoFleetLoadedPetAtlas, forKey key: String) {
        let cost = atlas.image.bytesPerRow * atlas.image.height
        atlases.setObject(AtlasBox(atlas), forKey: key as NSString, cost: cost)
    }
}
#endif
