#!/usr/bin/env swift

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

private struct IconOutput {
    let relativePath: String
    let pixels: Int
}

private let outputs: [IconOutput] = [
    // iPhone and App Store
    .init(relativePath: "Assets/iOS.xcassets/AppIcon.appiconset/icon-20@2x.png", pixels: 40),
    .init(relativePath: "Assets/iOS.xcassets/AppIcon.appiconset/icon-20@3x.png", pixels: 60),
    .init(relativePath: "Assets/iOS.xcassets/AppIcon.appiconset/icon-29@2x.png", pixels: 58),
    .init(relativePath: "Assets/iOS.xcassets/AppIcon.appiconset/icon-29@3x.png", pixels: 87),
    .init(relativePath: "Assets/iOS.xcassets/AppIcon.appiconset/icon-40@2x.png", pixels: 80),
    .init(relativePath: "Assets/iOS.xcassets/AppIcon.appiconset/icon-40@3x.png", pixels: 120),
    .init(relativePath: "Assets/iOS.xcassets/AppIcon.appiconset/icon-60@2x.png", pixels: 120),
    .init(relativePath: "Assets/iOS.xcassets/AppIcon.appiconset/icon-60@3x.png", pixels: 180),
    .init(relativePath: "Assets/iOS.xcassets/AppIcon.appiconset/icon-marketing.png", pixels: 1_024),

    // macOS
    .init(relativePath: "Assets/macOS.xcassets/AppIcon.appiconset/icon-16.png", pixels: 16),
    .init(relativePath: "Assets/macOS.xcassets/AppIcon.appiconset/icon-16@2x.png", pixels: 32),
    .init(relativePath: "Assets/macOS.xcassets/AppIcon.appiconset/icon-32.png", pixels: 32),
    .init(relativePath: "Assets/macOS.xcassets/AppIcon.appiconset/icon-32@2x.png", pixels: 64),
    .init(relativePath: "Assets/macOS.xcassets/AppIcon.appiconset/icon-128.png", pixels: 128),
    .init(relativePath: "Assets/macOS.xcassets/AppIcon.appiconset/icon-128@2x.png", pixels: 256),
    .init(relativePath: "Assets/macOS.xcassets/AppIcon.appiconset/icon-256.png", pixels: 256),
    .init(relativePath: "Assets/macOS.xcassets/AppIcon.appiconset/icon-256@2x.png", pixels: 512),
    .init(relativePath: "Assets/macOS.xcassets/AppIcon.appiconset/icon-512.png", pixels: 512),
    .init(relativePath: "Assets/macOS.xcassets/AppIcon.appiconset/icon-512@2x.png", pixels: 1_024),

    // Apple Watch
    .init(relativePath: "Assets/watchOS.xcassets/AppIcon.appiconset/icon-notification-38.png", pixels: 48),
    .init(relativePath: "Assets/watchOS.xcassets/AppIcon.appiconset/icon-notification-42.png", pixels: 55),
    .init(relativePath: "Assets/watchOS.xcassets/AppIcon.appiconset/icon-notification-45.png", pixels: 58),
    .init(relativePath: "Assets/watchOS.xcassets/AppIcon.appiconset/icon-notification-49.png", pixels: 64),
    .init(relativePath: "Assets/watchOS.xcassets/AppIcon.appiconset/icon-settings@2x.png", pixels: 58),
    .init(relativePath: "Assets/watchOS.xcassets/AppIcon.appiconset/icon-settings@3x.png", pixels: 87),
    .init(relativePath: "Assets/watchOS.xcassets/AppIcon.appiconset/icon-launcher-38.png", pixels: 80),
    .init(relativePath: "Assets/watchOS.xcassets/AppIcon.appiconset/icon-launcher-40.png", pixels: 88),
    .init(relativePath: "Assets/watchOS.xcassets/AppIcon.appiconset/icon-launcher-41.png", pixels: 92),
    .init(relativePath: "Assets/watchOS.xcassets/AppIcon.appiconset/icon-launcher-44.png", pixels: 100),
    .init(relativePath: "Assets/watchOS.xcassets/AppIcon.appiconset/icon-launcher-45.png", pixels: 102),
    .init(relativePath: "Assets/watchOS.xcassets/AppIcon.appiconset/icon-launcher-49.png", pixels: 108),
    .init(relativePath: "Assets/watchOS.xcassets/AppIcon.appiconset/icon-quicklook-38.png", pixels: 172),
    .init(relativePath: "Assets/watchOS.xcassets/AppIcon.appiconset/icon-quicklook-42.png", pixels: 196),
    .init(relativePath: "Assets/watchOS.xcassets/AppIcon.appiconset/icon-quicklook-44.png", pixels: 216),
    .init(relativePath: "Assets/watchOS.xcassets/AppIcon.appiconset/icon-quicklook-45.png", pixels: 234),
    .init(relativePath: "Assets/watchOS.xcassets/AppIcon.appiconset/icon-quicklook-49.png", pixels: 258),
    .init(relativePath: "Assets/watchOS.xcassets/AppIcon.appiconset/icon-marketing.png", pixels: 1_024),
]

private func color(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(red: red, green: green, blue: blue, alpha: alpha)
}

private func makeIcon(pixels: Int) throws -> CGImage {
    guard
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
        let context = CGContext(
            data: nil,
            width: pixels,
            height: pixels,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        )
    else {
        throw IconError.contextCreationFailed
    }

    let side = CGFloat(pixels)
    context.setAllowsAntialiasing(true)
    context.setShouldAntialias(true)
    context.setFillColor(color(0.035, 0.055, 0.12))
    context.fill(CGRect(x: 0, y: 0, width: side, height: side))

    guard let background = CGGradient(
        colorsSpace: colorSpace,
        colors: [color(0.035, 0.055, 0.12), color(0.08, 0.10, 0.25), color(0.05, 0.18, 0.24)] as CFArray,
        locations: [0, 0.58, 1]
    ) else {
        throw IconError.gradientCreationFailed
    }
    context.drawLinearGradient(
        background,
        start: CGPoint(x: side * 0.08, y: side * 0.94),
        end: CGPoint(x: side * 0.92, y: side * 0.04),
        options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
    )

    // Subtle navigation grid, kept away from the edge so the platform mask
    // remains clean at every size.
    context.setStrokeColor(color(0.30, 0.75, 0.88, 0.085))
    context.setLineWidth(max(1, side * 0.003))
    for fraction in stride(from: CGFloat(0.18), through: 0.82, by: 0.16) {
        context.move(to: CGPoint(x: side * fraction, y: side * 0.14))
        context.addLine(to: CGPoint(x: side * fraction, y: side * 0.86))
        context.move(to: CGPoint(x: side * 0.14, y: side * fraction))
        context.addLine(to: CGPoint(x: side * 0.86, y: side * fraction))
    }
    context.strokePath()

    // Two luminous routes suggest a coordinated fleet without borrowing any
    // provider logo geometry.
    let route = CGMutablePath()
    route.move(to: CGPoint(x: side * 0.25, y: side * 0.31))
    route.addCurve(
        to: CGPoint(x: side * 0.72, y: side * 0.70),
        control1: CGPoint(x: side * 0.34, y: side * 0.68),
        control2: CGPoint(x: side * 0.57, y: side * 0.31)
    )
    context.addPath(route)
    context.setStrokeColor(color(0.08, 0.92, 0.86, 0.28))
    context.setLineWidth(side * 0.07)
    context.setLineCap(.round)
    context.strokePath()
    context.addPath(route)
    context.setStrokeColor(color(0.35, 0.98, 0.92, 0.96))
    context.setLineWidth(side * 0.022)
    context.strokePath()

    let secondaryRoute = CGMutablePath()
    secondaryRoute.move(to: CGPoint(x: side * 0.25, y: side * 0.31))
    secondaryRoute.addCurve(
        to: CGPoint(x: side * 0.75, y: side * 0.34),
        control1: CGPoint(x: side * 0.42, y: side * 0.14),
        control2: CGPoint(x: side * 0.61, y: side * 0.18)
    )
    context.addPath(secondaryRoute)
    context.setStrokeColor(color(0.28, 0.60, 1.0, 0.82))
    context.setLineWidth(side * 0.016)
    context.strokePath()

    func drawNode(center: CGPoint, radius: CGFloat, accent: CGColor) {
        context.saveGState()
        context.setShadow(offset: .zero, blur: radius * 0.9, color: accent.copy(alpha: 0.55))
        context.setFillColor(color(0.04, 0.07, 0.15, 0.98))
        context.fillEllipse(in: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
        context.restoreGState()

        context.setStrokeColor(accent)
        context.setLineWidth(max(1, radius * 0.19))
        context.strokeEllipse(in: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
        context.setFillColor(color(0.93, 1.0, 1.0))
        let core = radius * 0.34
        context.fillEllipse(in: CGRect(x: center.x - core, y: center.y - core, width: core * 2, height: core * 2))
    }

    drawNode(center: CGPoint(x: side * 0.25, y: side * 0.31), radius: side * 0.085, accent: color(0.19, 0.88, 0.98))
    drawNode(center: CGPoint(x: side * 0.72, y: side * 0.70), radius: side * 0.095, accent: color(0.31, 0.98, 0.73))
    drawNode(center: CGPoint(x: side * 0.75, y: side * 0.34), radius: side * 0.070, accent: color(0.50, 0.61, 1.0))

    // Central command diamond.
    let center = CGPoint(x: side * 0.49, y: side * 0.48)
    let diamondSide = side * 0.22
    context.saveGState()
    context.translateBy(x: center.x, y: center.y)
    context.rotate(by: .pi / 4)
    let diamond = CGRect(x: -diamondSide / 2, y: -diamondSide / 2, width: diamondSide, height: diamondSide)
    context.setShadow(offset: .zero, blur: side * 0.04, color: color(0.15, 0.90, 0.92, 0.55))
    context.setFillColor(color(0.075, 0.11, 0.23, 1))
    context.addPath(CGPath(roundedRect: diamond, cornerWidth: side * 0.035, cornerHeight: side * 0.035, transform: nil))
    context.fillPath()
    context.restoreGState()

    context.saveGState()
    context.translateBy(x: center.x, y: center.y)
    context.rotate(by: .pi / 4)
    context.setStrokeColor(color(0.76, 1.0, 0.97, 0.96))
    context.setLineWidth(side * 0.018)
    context.addPath(CGPath(roundedRect: diamond, cornerWidth: side * 0.035, cornerHeight: side * 0.035, transform: nil))
    context.strokePath()
    context.restoreGState()

    let centerCore = side * 0.031
    context.setFillColor(color(0.96, 1.0, 1.0))
    context.fillEllipse(in: CGRect(x: center.x - centerCore, y: center.y - centerCore, width: centerCore * 2, height: centerCore * 2))

    guard let image = context.makeImage() else {
        throw IconError.imageCreationFailed
    }
    return image
}

private func writePNG(_ image: CGImage, to url: URL) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    guard let destination = CGImageDestinationCreateWithURL(
        url as CFURL,
        UTType.png.identifier as CFString,
        1,
        nil
    ) else {
        throw IconError.destinationCreationFailed(url.path)
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else {
        throw IconError.writeFailed(url.path)
    }
}

private enum IconError: Error, CustomStringConvertible {
    case contextCreationFailed
    case gradientCreationFailed
    case imageCreationFailed
    case destinationCreationFailed(String)
    case writeFailed(String)

    var description: String {
        switch self {
        case .contextCreationFailed: return "could not create drawing context"
        case .gradientCreationFailed: return "could not create background gradient"
        case .imageCreationFailed: return "could not create icon image"
        case let .destinationCreationFailed(path): return "could not create PNG destination at \(path)"
        case let .writeFailed(path): return "could not write PNG at \(path)"
        }
    }
}

let scriptURL = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
let repositoryRoot = scriptURL.deletingLastPathComponent().deletingLastPathComponent()

do {
    for output in outputs {
        let image = try makeIcon(pixels: output.pixels)
        try writePNG(image, to: repositoryRoot.appendingPathComponent(output.relativePath))
    }
    print("Generated \(outputs.count) original CoFleet app icon files.")
} catch {
    fputs("generate-app-icons: \(error)\n", stderr)
    exit(1)
}
