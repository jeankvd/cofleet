import CoFleetCore
import CoFleetUI
import Foundation
import SwiftUI
import WidgetKit

private struct CoFleetWidgetEntry: TimelineEntry {
    var date: Date
    var snapshot: CoFleetWatchSnapshot
    var presentationMode: CoFleetWidgetMode
}

private struct CoFleetWidgetProvider: TimelineProvider {
    let configurationMode: CoFleetWidgetMode

    func placeholder(in context: Context) -> CoFleetWidgetEntry {
        entry(snapshot: .empty, at: .now)
    }

    func getSnapshot(in context: Context, completion: @escaping (CoFleetWidgetEntry) -> Void) {
        completion(entry(snapshot: loadSnapshot(), at: .now))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<CoFleetWidgetEntry>) -> Void) {
        let now = Date()
        let current = entry(snapshot: loadSnapshot(), at: now)
        guard configurationMode == .automatic else {
            completion(Timeline(entries: [current], policy: .never))
            return
        }
        completion(Timeline(entries: [current], policy: .after(nextAutomaticBoundary(after: now))))
    }

    private func entry(snapshot: CoFleetWatchSnapshot, at date: Date) -> CoFleetWidgetEntry {
        CoFleetWidgetEntry(
            date: date,
            snapshot: snapshot,
            presentationMode: configurationMode.resolved(at: date)
        )
    }

    private func nextAutomaticBoundary(after date: Date) -> Date {
        let duration: TimeInterval = 30 * 60
        return Date(timeIntervalSince1970: (floor(date.timeIntervalSince1970 / duration) + 1) * duration)
    }

    private func loadSnapshot() -> CoFleetWatchSnapshot {
        let values = try? sharedSnapshotURL.resourceValues(forKeys: [.fileSizeKey])
        guard (values?.fileSize ?? 0) <= 256 * 1_024,
              let data = try? Data(contentsOf: sharedSnapshotURL) else { return .empty }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode(CoFleetWatchSnapshot.self, from: data)) ?? .empty
    }

    private var sharedSnapshotURL: URL {
        let identifier = Bundle.main.object(forInfoDictionaryKey: "CoFleetAppGroupIdentifier") as? String
        let container = identifier.flatMap { FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: $0) }
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("CoFleet", isDirectory: true)
        return container.appendingPathComponent("Watch/snapshot.json")
    }
}

private struct CoFleetWidgetView: View {
    var entry: CoFleetWidgetEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        Group {
            switch entry.presentationMode {
            case .threePets:
                petTrio
            case .focusedMessage, .automatic:
                focusedMessage
            }
        }
        .padding(family == .systemSmall ? 11 : 12)
        .containerBackground(for: .widget) {
            LinearGradient(
                colors: [Color.black, Color(red: 0.09, green: 0.12, blue: 0.17)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
    }

    @ViewBuilder
    private var focusedMessage: some View {
        if let project = focusedProject {
            if family == .systemSmall {
                VStack(alignment: .leading, spacing: 8) {
                    projectHeader(project, petSize: 40)
                    message(for: project, lineLimit: 4)
                    Spacer(minLength: 0)
                }
            } else {
                HStack(alignment: .top, spacing: 11) {
                    CoFleetPetPreviewView(name: project.name, preview: project.petPreview, size: 54)
                    VStack(alignment: .leading, spacing: 5) {
                        statusHeader(project)
                        message(for: project, lineLimit: 4)
                    }
                    Spacer(minLength: 0)
                }
            }
        } else {
            ContentUnavailableView("No projects", systemImage: "shippingbox")
        }
    }

    private var petTrio: some View {
        HStack(alignment: .top, spacing: family == .accessoryRectangular ? 4 : 10) {
            ForEach(trioProjects) { project in
                VStack(spacing: family == .accessoryRectangular ? 2 : 6) {
                    CoFleetPetPreviewView(
                        name: project.name,
                        preview: project.petPreview,
                        size: family == .accessoryRectangular ? 30 : 58
                    )
                    Text(project.name)
                        .font(family == .accessoryRectangular ? .system(size: 8, weight: .bold) : .caption.bold())
                        .lineLimit(1)
                        .minimumScaleFactor(0.65)
                    Circle()
                        .fill(project.hostReachability == .online ? .green : .gray)
                        .frame(width: 6, height: 6)
                }
                .frame(maxWidth: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func projectHeader(_ project: CoFleetWatchProjectSnapshot, petSize: CGFloat) -> some View {
        HStack(spacing: 8) {
            CoFleetPetPreviewView(name: project.name, preview: project.petPreview, size: petSize)
            statusHeader(project)
        }
    }

    private func statusHeader(_ project: CoFleetWatchProjectSnapshot) -> some View {
        HStack(spacing: 5) {
            Text(project.name)
                .font(.headline)
                .lineLimit(1)
                .minimumScaleFactor(0.72)
            Spacer(minLength: 2)
            Circle()
                .fill(project.hostReachability == .online ? .green : .gray)
                .frame(width: 8, height: 8)
        }
    }

    private func message(for project: CoFleetWatchProjectSnapshot, lineLimit: Int) -> some View {
        Text(project.latestMessage ?? project.action.rawValue)
            .font(family == .systemSmall ? .callout : .body)
            .foregroundStyle(.secondary)
            .lineLimit(lineLimit)
    }

    private var focusedProject: CoFleetWatchProjectSnapshot? {
        entry.snapshot.projects.first { $0.id == entry.snapshot.focusedProjectID }
            ?? entry.snapshot.projects.first
    }

    private var trioProjects: [CoFleetWatchProjectSnapshot] {
        let withPets = entry.snapshot.projects.filter { $0.selectedPetID != nil }
        return Array((withPets.isEmpty ? entry.snapshot.projects : withPets).prefix(3))
    }
}

private struct CoFleetFocusedWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(
            kind: "CoFleetFocusedMessageWidget",
            provider: CoFleetWidgetProvider(configurationMode: .focusedMessage)
        ) { entry in
            CoFleetWidgetView(entry: entry)
        }
        .configurationDisplayName("Focused Codex Reply")
        .description("The latest message and pet for the focused CoFleet project.")
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryRectangular])
        .contentMarginsDisabled()
    }
}

private struct CoFleetPetTrioWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(
            kind: "CoFleetPetTrioWidget",
            provider: CoFleetWidgetProvider(configurationMode: .threePets)
        ) { entry in
            CoFleetWidgetView(entry: entry)
        }
        .configurationDisplayName("Codex Pet Trio")
        .description("Up to three selected project pets with live host status.")
        .supportedFamilies([.systemMedium, .accessoryRectangular])
        .contentMarginsDisabled()
    }
}

private struct CoFleetAutomaticWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(
            kind: "CoFleetAutomaticWidget",
            provider: CoFleetWidgetProvider(configurationMode: .automatic)
        ) { entry in
            CoFleetWidgetView(entry: entry)
        }
        .configurationDisplayName("CoFleet Switcher")
        .description("Alternates between the focused Codex reply and pet trio.")
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryRectangular])
        .contentMarginsDisabled()
    }
}

@main
struct CoFleetWidgetsBundle: WidgetBundle {
    var body: some Widget {
        CoFleetFocusedWidget()
        CoFleetPetTrioWidget()
        CoFleetAutomaticWidget()
    }
}
