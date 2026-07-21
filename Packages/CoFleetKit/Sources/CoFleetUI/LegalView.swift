import SwiftUI

#if !os(watchOS)

public struct CoFleetLegalView: View {
    private let sourceURL: URL?
    private let sourceRevision: String
    private let licenseText: String

    public init(
        sourceURL: URL? = CoFleetLegalView.bundledSourceURL,
        sourceRevision: String = CoFleetLegalView.bundledSourceRevision,
        licenseText: String = CoFleetLegalView.bundledLicenseText
    ) {
        self.sourceURL = sourceURL
        self.sourceRevision = sourceRevision
        self.licenseText = licenseText
    }

    public static var bundledSourceURL: URL? {
        guard let value = Bundle.main.object(forInfoDictionaryKey: "CoFleetSourceURL") as? String else {
            return nil
        }
        return URL(string: value)
    }

    public static var bundledSourceRevision: String {
        Bundle.main.object(forInfoDictionaryKey: "CoFleetSourceRevision") as? String ?? "development"
    }

    public static var bundledLicenseText: String {
        guard let url = Bundle.main.url(forResource: "LICENSE", withExtension: nil),
              let text = try? String(contentsOf: url, encoding: .utf8),
              !text.isEmpty else {
            return defaultLicenseNotice
        }
        return text
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Label("CoFleet for Codex", systemImage: "shippingbox.fill")
                    .font(.system(.title, design: .rounded, weight: .bold))
                Text("Copyright © 2026 Jean Diaz")
                    .font(.headline)

                GroupBox("License") {
                    Text(licenseText)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                GroupBox("No Warranty") {
                    Text("This program is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                GroupBox("Source") {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Revision: \(sourceRevision)")
                        if let sourceURL { Link(sourceURL.absoluteString, destination: sourceURL) }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                GroupBox("Trademarks and Affiliation") {
                    Text("CoFleet is an independent open-source project. It is not affiliated with, endorsed by, or sponsored by OpenAI. OpenAI, ChatGPT, Codex, and related marks belong to their respective owners.")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(20)
        }
        .navigationTitle("Legal")
    }

    public static let defaultLicenseNotice = """
    CoFleet is free software licensed under the GNU General Public License, version 3 only (GPL-3.0-only).

    Additional permission under GNU GPL version 3 section 7:

    The copyright holders grant permission to convey covered works through Apple App Store and Google Play distribution channels, even if those stores' terms impose restrictions that would otherwise conflict with the GNU GPL version 3. This permission is limited to conflicts created by distribution, installation, and use through those store channels, and does not otherwise waive or alter any requirement of the GNU GPL version 3.

    See the repository LICENSE file for the complete GNU GPL version 3 terms.
    """
}
#endif
