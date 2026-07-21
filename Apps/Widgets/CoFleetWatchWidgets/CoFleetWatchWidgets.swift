import CoFleetCore
import CoFleetUI
import Foundation
import SwiftUI
import WidgetKit

private struct WatchEntry: TimelineEntry {
    var date: Date
    var snapshot: CoFleetWatchSnapshot
    var presentationMode: CoFleetWidgetMode
}

private struct WatchProvider: TimelineProvider {
    let configurationMode: CoFleetWidgetMode

    func placeholder(in context: Context) -> WatchEntry { entry(snapshot: .empty, at: .now) }

    func getSnapshot(in context: Context, completion: @escaping (WatchEntry) -> Void) {
        completion(entry(snapshot: snapshot(), at: .now))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<WatchEntry>) -> Void) {
        let now = Date()
        let current = entry(snapshot: snapshot(), at: now)
        guard configurationMode == .automatic else {
            completion(Timeline(entries: [current], policy: .never))
            return
        }
        let duration: TimeInterval = 30 * 60
        let boundary = Date(
            timeIntervalSince1970: (floor(now.timeIntervalSince1970 / duration) + 1) * duration
        )
        completion(Timeline(entries: [current], policy: .after(boundary)))
    }

    private func entry(snapshot: CoFleetWatchSnapshot, at date: Date) -> WatchEntry {
        WatchEntry(
            date: date,
            snapshot: snapshot,
            presentationMode: configurationMode.resolved(at: date)
        )
    }

    private func snapshot() -> CoFleetWatchSnapshot {
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

private struct WatchComplicationView: View {
    var entry: WatchEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        Group {
            switch family {
            case .accessoryCircular:
                circular
            case .accessoryInline:
                Text(inlineLabel)
            default:
                entry.presentationMode == .threePets ? AnyView(petTrio) : AnyView(focusedMessage)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var circular: some View {
        ZStack {
            AccessoryWidgetBackground()
            CoFleetPetPreviewView(
                name: focused?.name ?? "CoFleet",
                preview: focused?.petPreview,
                size: 39
            )
            Circle()
                .fill(focused?.hostReachability == .online ? .green : .gray)
                .frame(width: 7, height: 7)
                .offset(x: 15, y: 15)
        }
    }

    private var focusedMessage: some View {
        HStack(alignment: .center, spacing: 5) {
            CoFleetPetPreviewView(
                name: focused?.name ?? "CoFleet",
                preview: focused?.petPreview,
                size: 38
            )
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 3) {
                    Text(focused?.name ?? "CoFleet")
                        .font(.system(size: 11, weight: .bold, design: .rounded))
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                    Circle()
                        .fill(focused?.hostReachability == .online ? .green : .gray)
                        .frame(width: 6, height: 6)
                    actionDot
                }
                Text(focused?.latestMessage ?? focused?.action.rawValue ?? "Open CoFleet")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .minimumScaleFactor(0.75)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 2)
        .padding(.vertical, 1)
    }

    private var petTrio: some View {
        HStack(alignment: .center, spacing: 1) {
            ForEach(trioProjects) { project in
                VStack(spacing: 0) {
                    CoFleetPetPreviewView(name: project.name, preview: project.petPreview, size: 31)
                    Text(project.name)
                        .font(.system(size: 7, weight: .bold, design: .rounded))
                        .lineLimit(1)
                        .minimumScaleFactor(0.55)
                }
                .frame(maxWidth: .infinity)
                .overlay(alignment: .topTrailing) {
                    Circle()
                        .fill(project.hostReachability == .online ? .green : .gray)
                        .frame(width: 5, height: 5)
                        .padding(.trailing, 2)
                }
            }
        }
        .padding(.horizontal, 1)
    }

    private var actionDot: some View {
        Circle()
            .fill(actionColor)
            .frame(width: 6, height: 6)
    }

    private var actionColor: Color {
        switch focused?.action {
        case .approvalNeeded, .questionAsked: .orange
        case .replied: .green
        case .thinking, .runningCommand, .reasoning, .working: .blue
        default: .gray
        }
    }

    private var inlineLabel: String {
        guard let focused else { return "CoFleet" }
        return "\(focused.name): \(focused.latestMessage ?? focused.action.rawValue)"
    }

    private var focused: CoFleetWatchProjectSnapshot? {
        entry.snapshot.projects.first { $0.id == entry.snapshot.focusedProjectID }
            ?? entry.snapshot.projects.first
    }

    private var trioProjects: [CoFleetWatchProjectSnapshot] {
        let withPets = entry.snapshot.projects.filter { $0.selectedPetID != nil }
        return Array((withPets.isEmpty ? entry.snapshot.projects : withPets).prefix(3))
    }
}

private struct CoFleetFocusedComplication: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(
            kind: "CoFleetFocusedMessageComplication",
            provider: WatchProvider(configurationMode: .focusedMessage)
        ) { entry in
            WatchComplicationView(entry: entry)
                .containerBackground(.black, for: .widget)
        }
        .configurationDisplayName("Focused Codex Reply")
        .description("The focused project's latest Codex reply and pet.")
        .supportedFamilies([.accessoryCircular, .accessoryRectangular, .accessoryInline])
        .contentMarginsDisabled()
    }
}

private struct CoFleetPetTrioComplication: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(
            kind: "CoFleetPetTrioComplication",
            provider: WatchProvider(configurationMode: .threePets)
        ) { entry in
            WatchComplicationView(entry: entry)
                .containerBackground(.black, for: .widget)
        }
        .configurationDisplayName("Codex Pet Trio")
        .description("Three selected project pets in a wide complication.")
        .supportedFamilies([.accessoryRectangular])
        .contentMarginsDisabled()
    }
}

private struct CoFleetAutomaticComplication: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(
            kind: "CoFleetAutomaticComplication",
            provider: WatchProvider(configurationMode: .automatic)
        ) { entry in
            WatchComplicationView(entry: entry)
                .containerBackground(.black, for: .widget)
        }
        .configurationDisplayName("CoFleet Switcher")
        .description("Alternates between the focused reply and pet trio.")
        .supportedFamilies([.accessoryRectangular])
        .contentMarginsDisabled()
    }
}

@main
struct CoFleetWatchWidgetsBundle: WidgetBundle {
    var body: some Widget {
        CoFleetFocusedComplication()
        CoFleetPetTrioComplication()
        CoFleetAutomaticComplication()
    }
}
