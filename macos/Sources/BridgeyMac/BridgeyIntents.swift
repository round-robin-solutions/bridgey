import AppIntents
import AppKit
import Foundation

/*
 * Shortcuts and Siri on the Mac (App Intents, macOS 13+). Every action can name a phone or use
 * the one selected in the panel. They call the same coordinator methods as the panel, so the
 * phone's own switches still decide. build-app.sh runs Apple's metadata processor on the
 * SwiftPM build so Shortcuts can see these (docs/automation.md, "Shortcuts and Siri").
 */

/// The running coordinator, set at launch. Intents run inside the app.
@MainActor
enum IntentHost {
    static weak var pairing: PairingCoordinator?

    /// The coordinator, after waiting up to `timeout` for the phone (or any phone) to connect: the
    /// system may have just launched Bridgey to run the intent.
    static func connected(_ phone: PhoneEntity?, timeout: TimeInterval = 10) async throws -> (PairingCoordinator, String) {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            if let pairing, let id = pairing.intentTarget(phone?.id) { return (pairing, id) }
            if Date() >= deadline { throw IntentFailure.notConnected(phone?.name) }
            try await Task.sleep(nanoseconds: 250_000_000)
        }
    }
}

enum IntentFailure: Error, CustomLocalizedStringResourceConvertible {
    case notConnected(String?)
    case featureOff(String)
    case nothingToSend
    case failed

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case let .notConnected(name):
            if let name { return LocalizedStringResource("intent.error.notConnectedNamed", defaultValue: "\(name) is not connected to this Mac.") }
            return LocalizedStringResource("intent.error.notConnected", defaultValue: "No phone is connected to this Mac.")
        case let .featureOff(feature):
            return LocalizedStringResource("intent.error.featureOff", defaultValue: "\(feature) is turned off on this Mac or the phone.")
        case .nothingToSend:
            return LocalizedStringResource("intent.error.nothing", defaultValue: "There is nothing to send.")
        case .failed:
            return LocalizedStringResource("intent.error.failed", defaultValue: "Bridgey could not do that.")
        }
    }
}

// MARK: - Phone

struct PhoneEntity: AppEntity {
    static var typeDisplayRepresentation = TypeDisplayRepresentation(name: LocalizedStringResource("intent.phone", defaultValue: "Phone"))
    static var defaultQuery = PhoneQuery()

    let id: String
    let name: String

    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(name)") }
}

struct PhoneQuery: EntityQuery {
    func entities(for identifiers: [String]) async throws -> [PhoneEntity] {
        await MainActor.run { IntentHost.pairing?.intentPhones().filter { identifiers.contains($0.id) } ?? [] }
    }

    func suggestedEntities() async throws -> [PhoneEntity] {
        await MainActor.run { IntentHost.pairing?.intentPhones() ?? [] }
    }
}

struct PhoneBatteryEntity: AppEntity {
    static var typeDisplayRepresentation = TypeDisplayRepresentation(name: LocalizedStringResource("intent.battery.type", defaultValue: "Phone battery"))
    static var defaultQuery = PhoneBatteryQuery()

    let id: String
    @Property(title: LocalizedStringResource("intent.battery.phone", defaultValue: "Phone"))
    var phone: String
    @Property(title: LocalizedStringResource("intent.battery.level", defaultValue: "Level"))
    var level: Int
    @Property(title: LocalizedStringResource("intent.battery.charging", defaultValue: "Charging"))
    var charging: Bool

    init(id: String, phone: String, level: Int, charging: Bool) {
        self.id = id
        self.phone = phone
        self.level = level
        self.charging = charging
    }

    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(phone): \(level)%") }
}

struct PhoneBatteryQuery: EntityQuery {
    func entities(for identifiers: [String]) async throws -> [PhoneBatteryEntity] {
        await MainActor.run { identifiers.compactMap { IntentHost.pairing?.intentBattery(for: $0) } }
    }
}

// MARK: - Actions

struct SendClipboardIntent: AppIntent {
    static var title: LocalizedStringResource = LocalizedStringResource("intent.clipboard.title", defaultValue: "Send Clipboard to Phone")
    static var description = IntentDescription(LocalizedStringResource("intent.clipboard.description", defaultValue: "Sends what is on this Mac\u{2019}s clipboard to a paired phone."))
    @Parameter(title: LocalizedStringResource("intent.phone", defaultValue: "Phone"))
    var phone: PhoneEntity?

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let (pairing, id) = try await IntentHost.connected(phone)
        guard pairing.isFeatureAvailable(.clipboard, for: id) else { throw IntentFailure.featureOff(BridgeyFeature.clipboard.title) }
        pairing.withIntentTarget(id) { pairing.sendClipboard() }
        return .result(dialog: IntentDialog(LocalizedStringResource("intent.sent", defaultValue: "Sent to \(pairing.intentName(id)).")))
    }
}

struct SendTextIntent: AppIntent {
    static var title: LocalizedStringResource = LocalizedStringResource("intent.text.title", defaultValue: "Send Text to Phone")
    static var description = IntentDescription(LocalizedStringResource("intent.text.description", defaultValue: "Puts text on a paired phone\u{2019}s clipboard."))
    @Parameter(title: LocalizedStringResource("intent.text", defaultValue: "Text"))
    var text: String
    @Parameter(title: LocalizedStringResource("intent.phone", defaultValue: "Phone"))
    var phone: PhoneEntity?

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard !text.isEmpty else { throw IntentFailure.nothingToSend }
        let (pairing, id) = try await IntentHost.connected(phone)
        guard pairing.isFeatureAvailable(.clipboard, for: id) else { throw IntentFailure.featureOff(BridgeyFeature.clipboard.title) }
        guard pairing.sendText(text, to: id) else { throw IntentFailure.failed }
        return .result(dialog: IntentDialog(LocalizedStringResource("intent.sent", defaultValue: "Sent to \(pairing.intentName(id)).")))
    }
}

struct SendFilesIntent: AppIntent {
    static var title: LocalizedStringResource = LocalizedStringResource("intent.files.title", defaultValue: "Send Files to Phone")
    static var description = IntentDescription(LocalizedStringResource("intent.files.description", defaultValue: "Sends files to a paired phone, one after another."))
    @Parameter(title: LocalizedStringResource("intent.files", defaultValue: "Files"), supportedTypeIdentifiers: ["public.item"])
    var files: [IntentFile]
    @Parameter(title: LocalizedStringResource("intent.phone", defaultValue: "Phone"))
    var phone: PhoneEntity?

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard !files.isEmpty else { throw IntentFailure.nothingToSend }
        let (pairing, id) = try await IntentHost.connected(phone)
        guard pairing.isFeatureAvailable(.files, for: id) else { throw IntentFailure.featureOff(BridgeyFeature.files.title) }
        let urls = try IntentFileStaging.stage(files)
        guard pairing.withIntentTarget(id, { pairing.sendDroppedFiles(urls) }) else { throw IntentFailure.failed }
        return .result(dialog: IntentDialog(LocalizedStringResource("intent.files.sent", defaultValue: "Sending to \(pairing.intentName(id)).")))
    }
}

struct RingPhoneIntent: AppIntent {
    static var title: LocalizedStringResource = LocalizedStringResource("intent.ring.title", defaultValue: "Ring My Phone")
    static var description = IntentDescription(LocalizedStringResource("intent.ring.description", defaultValue: "Rings a paired phone until you stop it there or in Bridgey."))
    @Parameter(title: LocalizedStringResource("intent.phone", defaultValue: "Phone"))
    var phone: PhoneEntity?

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let (pairing, id) = try await IntentHost.connected(phone)
        guard pairing.isFeatureAvailable(.findDevice, for: id) else { throw IntentFailure.featureOff(BridgeyFeature.findDevice.title) }
        pairing.withIntentTarget(id) { pairing.findAndroid() }
        return .result(dialog: IntentDialog(LocalizedStringResource("intent.ring.done", defaultValue: "Ringing \(pairing.intentName(id)).")))
    }
}

struct PingPhoneIntent: AppIntent {
    static var title: LocalizedStringResource = LocalizedStringResource("intent.ping.title", defaultValue: "Ping Phone")
    static var description = IntentDescription(LocalizedStringResource("intent.ping.description", defaultValue: "Plays one short alert on a paired phone."))
    @Parameter(title: LocalizedStringResource("intent.phone", defaultValue: "Phone"))
    var phone: PhoneEntity?

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let (pairing, id) = try await IntentHost.connected(phone)
        guard pairing.isFeatureAvailable(.ping, for: id) else { throw IntentFailure.featureOff(BridgeyFeature.ping.title) }
        pairing.withIntentTarget(id) { pairing.sendPing() }
        return .result(dialog: IntentDialog(LocalizedStringResource("intent.ping.done", defaultValue: "Pinged \(pairing.intentName(id)).")))
    }
}

struct GetPhoneBatteryIntent: AppIntent {
    static var title: LocalizedStringResource = LocalizedStringResource("intent.battery.title", defaultValue: "Get Phone Battery")
    static var description = IntentDescription(LocalizedStringResource("intent.battery.description", defaultValue: "Returns a paired phone\u{2019}s battery level and whether it is charging."))
    @Parameter(title: LocalizedStringResource("intent.phone", defaultValue: "Phone"))
    var phone: PhoneEntity?

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<PhoneBatteryEntity> & ProvidesDialog {
        let (pairing, id) = try await IntentHost.connected(phone)
        guard pairing.isFeatureAvailable(.battery, for: id) else { throw IntentFailure.featureOff(BridgeyFeature.battery.title) }
        // The phone reports its battery right after connecting; give it a moment.
        var battery = pairing.intentBattery(for: id)
        for _ in 0..<12 where battery == nil {
            try await Task.sleep(nanoseconds: 250_000_000)
            battery = pairing.intentBattery(for: id)
        }
        guard let battery else { throw IntentFailure.failed }
        let dialog = battery.charging
            ? LocalizedStringResource("intent.battery.dialogCharging", defaultValue: "\(battery.phone) is at \(battery.level)% and charging.")
            : LocalizedStringResource("intent.battery.dialog", defaultValue: "\(battery.phone) is at \(battery.level)%.")
        return .result(value: battery, dialog: IntentDialog(dialog))
    }
}

/// Shows the actions in Shortcuts and Spotlight without setup. Phrases are English only for now.
struct BridgeyShortcuts: AppShortcutsProvider {
    @AppShortcutsBuilder
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: SendClipboardIntent(), phrases: ["Send clipboard to my phone with \(.applicationName)"])
        AppShortcut(intent: RingPhoneIntent(), phrases: ["Ring my phone with \(.applicationName)", "Find my phone with \(.applicationName)"])
        AppShortcut(intent: PingPhoneIntent(), phrases: ["Ping my phone with \(.applicationName)"])
        AppShortcut(intent: GetPhoneBatteryIntent(), phrases: ["Get my phone battery with \(.applicationName)"])
    }
}

/// Files from Shortcuts are copied to a private folder first, because Shortcuts may delete its own
/// copies once the action returns. Folders older than a day are removed on the next run.
enum IntentFileStaging {
    static var root: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("\(Edition.supportFolderName)/intents", isDirectory: true)
    }

    static func stage(_ files: [IntentFile], root: URL = IntentFileStaging.root, now: Date = Date()) throws -> [URL] {
        let manager = FileManager.default
        if let old = try? manager.contentsOfDirectory(at: root, includingPropertiesForKeys: [.creationDateKey]) {
            for folder in old where ((try? folder.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? now) < now.addingTimeInterval(-86_400) {
                try? manager.removeItem(at: folder)
            }
        }
        let folder = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try manager.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return try files.enumerated().map { index, file in
            let name = safeFileName(file.filename, fallback: "file-\(index + 1)")
            let target = folder.appendingPathComponent(name)
            if let source = file.fileURL {
                let scoped = source.startAccessingSecurityScopedResource()
                defer { if scoped { source.stopAccessingSecurityScopedResource() } }
                try manager.copyItem(at: source, to: target)
            } else {
                try file.data.write(to: target)
            }
            return target
        }
    }

    /// A file name without path separators or a leading dot.
    static func safeFileName(_ raw: String, fallback: String) -> String {
        let cleaned = raw.replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: ":", with: "_")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmed = String(cleaned.drop(while: { $0 == "." }).prefix(200))
        return trimmed.isEmpty ? fallback : trimmed
    }
}
