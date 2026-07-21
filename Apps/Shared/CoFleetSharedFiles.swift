import Foundation

public enum CoFleetSharedFiles {
    public static var appGroupIdentifier: String? {
        Bundle.main.object(forInfoDictionaryKey: "CoFleetAppGroupIdentifier") as? String
    }

    public static func containerURL(fileManager: FileManager = .default) -> URL {
        if let appGroupIdentifier,
           let appGroupURL = fileManager.containerURL(forSecurityApplicationGroupIdentifier: appGroupIdentifier) {
            return appGroupURL
        }
        return fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("CoFleet", isDirectory: true)
    }

    public static var watchSnapshotURL: URL {
        containerURL().appendingPathComponent("Watch/snapshot.json")
    }

    public static var watchDeliveryURL: URL {
        containerURL().appendingPathComponent("Watch/deliveries.json")
    }
}
