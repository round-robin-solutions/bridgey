import SwiftUI

/*
 * Settings > Notifications > Codes from messages, the model download sheet, the licences, and the
 * shared words for the menu-bar card. Views draw from plain state so screenshots render them.
 * Motion is transform and opacity only; Reduce motion stills the progress bar.
 */

/// What Settings shows about the on-device model.
struct CodeModelDisplay: Equatable {
    /// This build has a manifest and this macOS can run llama.cpp.
    var available = true
    var manifest: CodeModelManifest?
    var installed: InstalledCodeModel?
    var download: CodeModelDownload?
    var update: CodeModelManifest?
    var availableSpace: Int64?
    var testResult: CodeModelTestResult?
    var testing = false
    /// The newest acceptance on record, and whether it covers the current manifest's terms.
    var acceptance: CodeModelAcceptance?
    var acceptanceCovers = false

    var size: Int64 { download?.manifest.size ?? manifest?.size ?? installed?.size ?? 0 }
}

extension CodeModelDownload {
    /// A bar only when there is something to show: running, checking, or part of the file kept.
    var showsBar: Bool {
        switch state {
        case .running, .verifying: true
        case .paused, .failed: received > 0
        }
    }
}

// MARK: - Words

enum CodeModelText {
    /// "253 MB" (decimal megabytes, as Finder shows them).
    static func megabytes(_ bytes: Int64) -> String {
        let value = Int((Double(max(0, bytes)) / 1_000_000).rounded())
        return String(format: L10n.text("codes.model.mb", fallback: "%@ MB"), FolderText.number(value))
    }

    static func gigabytes(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: max(0, bytes), countStyle: .file)
    }

    static func speed(_ bytesPerSecond: Double) -> String {
        String(format: L10n.text("codes.model.speed", fallback: "%@ MB/s"), decimal(bytesPerSecond / 1_000_000))
    }

    static func timeLeft(_ seconds: Double?) -> String {
        guard let seconds else { return L10n.text("codes.model.left.estimating", fallback: "estimating time left") }
        if seconds < 60 {
            return String(format: L10n.text("codes.model.left.seconds", fallback: "about %d s left"), max(1, Int(seconds.rounded(.up))))
        }
        return String(format: L10n.text("codes.model.left.minutes", fallback: "about %d min left"), Int((seconds / 60).rounded(.up)))
    }

    static func decimal(_ value: Double) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = 1
        formatter.maximumFractionDigits = 1
        return formatter.string(from: NSNumber(value: value)) ?? String(format: "%.1f", value)
    }

    /// "112 of 253 MB".
    static func amount(_ received: Int64, of total: Int64) -> String {
        let done = Int((Double(max(0, received)) / 1_000_000).rounded(.down))
        return String(format: L10n.text("codes.model.amount", fallback: "%1$@ of %2$@"), FolderText.number(done), megabytes(total))
    }

    static func title(_ model: CodeModelDisplay) -> String {
        if let download = model.download {
            return switch download.state {
            case .running: L10n.text("codes.model.downloading", fallback: "Downloading the code model")
            case .paused: L10n.text("codes.model.paused", fallback: "Download paused")
            case .verifying: L10n.text("codes.model.verifying", fallback: "Checking the download")
            case .failed: L10n.text("codes.model.failed", fallback: "Download stopped")
            }
        }
        if model.installed != nil { return L10n.text("codes.model.ready", fallback: "Code model ready") }
        return L10n.text("codes.model.title", fallback: "Code model")
    }

    /// The line under the title.
    static func detail(_ model: CodeModelDisplay) -> String {
        if !model.available { return L10n.text("codes.model.unavailable", fallback: "Not available in this build or on this version of macOS") }
        if let download = model.download {
            switch download.state {
            case .running:
                var parts = [amount(download.received, of: download.manifest.size)]
                if let speed = download.bytesPerSecond, speed > 0 { parts.append(Self.speed(speed)) }
                parts.append(timeLeft(download.secondsLeft))
                return parts.joined(separator: " \u{00B7} ")
            case .paused:
                return String(format: L10n.text("codes.model.paused.detail", fallback: "Stopped at %@. Resume carries on from there."),
                              amount(download.received, of: download.manifest.size))
            case .verifying:
                return L10n.text("codes.model.verifying.detail", fallback: "Making sure the file arrived complete and unchanged")
            case let .failed(error):
                return failure(error)
            }
        }
        if let installed = model.installed {
            var line = String(format: L10n.text("codes.model.ready.detail", fallback: "Version %1$d \u{00B7} %2$@ \u{00B7} runs on this Mac"),
                              installed.version, megabytes(installed.size))
            if let update = model.update {
                line += "\n" + String(format: L10n.text("codes.model.update", fallback: "Version %1$d is available (%2$@)"), update.version, megabytes(update.size))
            }
            return line
        }
        return String(format: L10n.text("codes.model.notDownloaded", fallback: "%@, one time. Not downloaded yet."), megabytes(model.size))
    }

    static func failure(_ error: CodeModelDownloadError) -> String {
        switch error {
        case let .noSpace(needed, available):
            String(format: L10n.text("codes.model.error.space", fallback: "Not enough space: it needs %1$@ and %2$@ is free. Free up some space, then try again."),
                   megabytes(needed), gigabytes(available))
        case .offline:
            L10n.text("codes.model.error.offline", fallback: "No internet connection. The download carries on by itself when you are back online.")
        case .checksum:
            L10n.text("codes.model.error.checksum", fallback: "The file arrived damaged twice, so Bridgey deleted it. Try again later.")
        case let .server(status):
            status > 0
                ? String(format: L10n.text("codes.model.error.server", fallback: "The download server did not answer properly (error %d). Try again later."), status)
                : L10n.text("codes.model.error.serverUnknown", fallback: "The download server could not be reached. Try again later.")
        case .disk:
            L10n.text("codes.model.error.disk", fallback: "Bridgey could not save the file on this Mac. Check your disk, then try again.")
        }
    }

    static func test(_ result: CodeModelTestResult) -> String {
        if result.failed { return L10n.text("codes.model.test.failed", fallback: "The model could not run. Remove it and download it again.") }
        let time = String(format: L10n.text("codes.model.test.seconds", fallback: "%@ s"), String(format: "%.2f", result.seconds))
        guard let code = result.code else {
            return String(format: L10n.text("codes.model.test.none", fallback: "No code found in the sample (%@)."), time)
        }
        let line = String(format: L10n.text("codes.model.test.found", fallback: "Found %1$@ in the sample message in %2$@."), code, time)
        return result.loaded ? line + " " + L10n.text("codes.model.test.loaded", fallback: "That includes loading the model; the next one is faster.") : line
    }

    static var localTitle: String { L10n.text("codes.engine.local", fallback: "On this Mac (private)") }
    static var cloudTitle: String { L10n.text("codes.engine.cloud", fallback: "Cloud (Cloudflare)") }
}

// MARK: - Progress

/// A thin track whose fill grows by a horizontal scale (transform only). Nil draws the whole track
/// dimmed, for a step of unknown length; it never loops.
struct CodeModelProgressBar: View {
    let fraction: Double?
    @Environment(\.brand) private var c
    @Environment(\.brandReduceMotion) private var reduce
    @Environment(\.snapshotRendering) private var snapshot

    var body: some View {
        ZStack(alignment: .leading) {
            Capsule().fill(c.s3)
            Capsule()
                .fill(LinearGradient(colors: [BrandPalette.auroraPurple, BrandPalette.auroraBlue, BrandPalette.auroraGreen], startPoint: .leading, endPoint: .trailing))
                .scaleEffect(x: CGFloat(max(0.02, min(1, fraction ?? 1))), y: 1, anchor: .leading)
                .opacity(fraction == nil ? 0.45 : 1)
                .animation(reduce || snapshot ? nil : .linear(duration: 0.22), value: fraction)
        }
        .frame(height: 6)
        .accessibilityElement()
        .accessibilityLabel(L10n.text("codes.model.progress", fallback: "Download progress"))
        .accessibilityValue(fraction.map { "\(Int(($0 * 100).rounded())) %" } ?? "")
    }
}

// MARK: - Settings card

/// Notifications > Codes from messages.
struct CodesCard: View {
    let model: SettingsModel
    let actions: SettingsActions
    @State private var confirmCloud: CloudConfirmation?
    @State private var showsDownload = false
    @State private var enableAfterDownload = false
    @State private var confirmRemove = false

    private enum CloudConfirmation: Identifiable {
        case turnOn, switchEngine
        var id: Self { self }
    }

    private var local: Bool { model.codesEngine == .local }
    private var display: CodeModelDisplay { model.codeModel }

    var body: some View {
        SettingsCard(title: L10n.text("codes.title", fallback: "Codes from messages"), footnote: footnote) {
            SettingsToggle(title: L10n.text("codes.toggle", fallback: "Show codes from text messages"),
                           subtitle: toggleAvailable
                               ? L10n.text("codes.toggle.detail", fallback: "\u{201C}Code 482913 from HDFC Bank\u{201D} with a Copy button. Off by default.")
                               : L10n.text("codes.toggle.unavailable", fallback: "Not available in this build"),
                           subtitleIsWarning: !toggleAvailable,
                           divider: false,
                           synced: model.syncs(.codesEnabled),
                           isOn: model.codesEnabled || model.codesPendingSync,
                           set: setEnabled)
                .disabled(!toggleAvailable && !model.codesEnabled)
            // Turned on from another device: Allow runs this card's own consent step (cloud question or model download).
            SyncStatusLine(key: .codesEnabled, model: model, actions: actions, allow: { setEnabled(true) })
            // Mail previews are always read by the model here, whichever engine reads text messages.
            SettingsToggle(title: L10n.text("codes.email", fallback: "Also read codes in email"),
                           subtitle: L10n.text("codes.email.detail", fallback: "Gmail, Outlook, Proton Mail and Spark on your phone. Read on this Mac only, even when Cloud reads texts."),
                           synced: model.syncs(.codesEmail), isOn: model.codesEmail, set: actions.setCodesEmail)
                .disabled(!model.codesEnabled)
            SyncStatusLine(key: .codesEmail, model: model, actions: actions)
            CodeEngineChoice(selected: model.codesEngine, cloudAvailable: model.codesAvailable, localAvailable: display.available,
                             size: display.size, select: selectEngine)
            // Email codes need the model on this Mac even when Cloud reads text messages.
            if local || (model.codesEnabled && model.codesEmail) {
                CodeModelRow(model: display, actions: actions,
                             download: { showsDownload = true }, update: update, remove: { confirmRemove = true })
            }
            SettingsToggle(title: L10n.text("codes.autoCopy", fallback: "Copy automatically"),
                           subtitle: L10n.text("codes.autoCopy.detail", fallback: "Only while you are using this Mac. Any app can read the clipboard, so this is off by default."),
                           isOn: model.codesAutoCopy, set: actions.setCodesAutoCopy)
                .disabled(!model.codesEnabled)
            SettingsRow(title: L10n.text("codes.access", fallback: "Code access"),
                        subtitle: model.codeLinkStatus ?? model.codeAccess.text,
                        subtitleIsWarning: model.codeLinkStatus == nil && model.codeAccess.isWarning) {
                if model.codeAccess.offersLink {
                    Button(L10n.text("codes.link", fallback: "Link this phone to the Mac"), action: actions.linkPhone)
                        .buttonStyle(PillButtonStyle(kind: .tonal, height: 28))
                }
            }
        }
        .onAppear(perform: actions.refreshCodeModel)
        .sheet(isPresented: $showsDownload) {
            CodeModelDownloadSheet(model: display, openURL: actions.openURL,
                                   cancel: {
                                       showsDownload = false
                                       enableAfterDownload = false
                                   },
                                   download: {
                                       showsDownload = false
                                       actions.acceptAndDownloadCodeModel()
                                       if enableAfterDownload { actions.setCodesEnabled(true) }
                                       enableAfterDownload = false
                                   })
        }
        .confirmationDialog(L10n.text("codes.confirm.title", fallback: "Send code messages to Cloudflare?"), isPresented: Binding(
            get: { confirmCloud != nil }, set: { if !$0 { confirmCloud = nil } }
        )) {
            Button(confirmCloud == .switchEngine ? L10n.text("codes.confirm.useCloud", fallback: "Use Cloud") : L10n.text("codes.confirm.turnOn", fallback: "Turn On")) {
                if confirmCloud == .switchEngine { actions.setCodesEngine(.cloud) } else { actions.setCodesEnabled(true) }
                confirmCloud = nil
            }
            Button(L10n.text("action.cancel", fallback: "Cancel"), role: .cancel) { confirmCloud = nil }
        } message: {
            Text(L10n.text("codes.confirm.body", fallback: "To find the code, Bridgey sends the text of each message that looks like it has one, code included, to Cloudflare Workers AI through Round Robin\u{2019}s relay. Nothing is stored there. You can turn this off at any time. Email previews are always read on this Mac."))
        }
        .confirmationDialog(L10n.text("codes.model.remove.title", fallback: "Remove the code model?"), isPresented: $confirmRemove) {
            Button(L10n.text("codes.model.remove", fallback: "Remove"), role: .destructive) { actions.removeCodeModel() }
        } message: {
            Text(String(format: L10n.text("codes.model.remove.body", fallback: "This frees %@. Codes from messages turns off until you download the model again."),
                        CodeModelText.megabytes(display.installed?.size ?? display.size)))
        }
    }

    private var toggleAvailable: Bool { local ? display.available : model.codesAvailable }

    private var footnote: String {
        local
            ? L10n.text("codes.privacy.local", fallback: "On this Mac, a small model finds the code here, so message text and codes never leave this Mac. Bridgey never saves or logs codes, and clears a copied code from the clipboard after 60 seconds. The model is Gemma 3 270M by Google, fine-tuned by Round Robin, under the Gemma Terms of Use (About > Licences).")
            : L10n.text("codes.privacy", fallback: "When on, a text message that looks like it has a code goes from this Mac, through Round Robin\u{2019}s relay, to Cloudflare Workers AI, which finds the code. So that message text, code included, leaves your devices. Cloudflare does not use it to train models, and the relay keeps no copy and logs nothing. Bridgey never saves or logs codes, and clears a copied code from the clipboard after 60 seconds. Email previews are always read on this Mac.")
    }

    private func setEnabled(_ on: Bool) {
        if !on {
            actions.setCodesEnabled(false)
        } else if !local {
            confirmCloud = .turnOn
        } else if display.installed != nil || display.download != nil {
            actions.setCodesEnabled(true)
        } else {
            enableAfterDownload = true
            showsDownload = true
        }
    }

    private func selectEngine(_ engine: CodeEngine) {
        guard engine != model.codesEngine else { return }
        switch engine {
        case .cloud:
            if model.codesEnabled { confirmCloud = .switchEngine } else { actions.setCodesEngine(.cloud) }
        case .local:
            actions.setCodesEngine(.local)
            if model.codesEnabled, display.installed == nil, display.download == nil, display.available { showsDownload = true }
        }
    }

    private func update() {
        if display.acceptanceCovers { actions.downloadCodeModel() } else { showsDownload = true }
    }
}

/// Read codes: On this Mac (private) or Cloud (Cloudflare), as two radio rows with a line each.
struct CodeEngineChoice: View {
    let selected: CodeEngine
    let cloudAvailable: Bool
    let localAvailable: Bool
    let size: Int64
    let select: (CodeEngine) -> Void
    @Environment(\.brand) private var c

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L10n.text("codes.engine", fallback: "Read codes"))
                .font(BrandFont.body(13, .medium))
                .foregroundStyle(c.on)
            HStack(spacing: 8) {
                option(.local, title: CodeModelText.localTitle,
                       detail: String(format: L10n.text("codes.engine.local.detail", fallback: "Runs here; message text never leaves this Mac. One download of %@."), CodeModelText.megabytes(size)),
                       symbol: "lock.laptopcomputer", enabled: localAvailable)
                option(.cloud, title: CodeModelText.cloudTitle,
                       detail: L10n.text("codes.engine.cloud.detail", fallback: "Sends message text to Cloudflare Workers AI through Round Robin\u{2019}s relay. No download. Email previews are always read on this Mac."),
                       symbol: "cloud", enabled: cloudAvailable)
            }
            // Both cards as tall as the taller one.
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 10)
        .overlay(alignment: .top) { Rectangle().fill(c.olv).frame(height: 1) }
    }

    private func option(_ engine: CodeEngine, title: String, detail: String, symbol: String, enabled: Bool) -> some View {
        let on = selected == engine
        return Button { select(engine) } label: {
            HStack(alignment: .top, spacing: 10) {
                ZStack {
                    Circle().strokeBorder(on ? c.pri : c.ol, lineWidth: 1.5)
                    Circle().fill(c.pri).padding(4).opacity(on ? 1 : 0)
                }
                .frame(width: 16, height: 16)
                .padding(.top, 1)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 5) {
                        Image(systemName: symbol).font(.system(size: 11, weight: .semibold)).foregroundStyle(on ? c.tbi : c.on2)
                        Text(title).font(BrandFont.body(13, .semibold)).foregroundStyle(c.on)
                    }
                    Text(detail)
                        .font(BrandFont.body(12))
                        .foregroundStyle(c.on2)
                        .fixedSize(horizontal: false, vertical: true)
                        .multilineTextAlignment(.leading)
                }
                Spacer(minLength: 0)
            }
            .padding(10)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(on ? c.tb : c.s2))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(on ? c.pri.opacity(0.55) : c.olv, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.5)
        .accessibilityAddTraits(on ? [.isSelected] : [])
    }
}

/// The model's state, one row: not downloaded, downloading, paused, checking, stopped, ready.
struct CodeModelRow: View {
    let model: CodeModelDisplay
    let actions: SettingsActions
    let download: () -> Void
    let update: () -> Void
    let remove: () -> Void
    @Environment(\.brand) private var c

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 12) {
                IconTile(symbol: symbol.name, tint: symbol.tint, size: 32, corner: 9)
                RowText(title: CodeModelText.title(model), subtitle: CodeModelText.detail(model), warning: isWarning)
                buttons
            }
            if let progress = model.download, progress.showsBar {
                CodeModelProgressBar(fraction: progress.state == .verifying ? nil : progress.fraction)
                    .padding(.leading, 44)
            }
            if model.installed != nil, model.download == nil, let result = model.testResult {
                HStack(spacing: 6) {
                    Image(systemName: result.code != nil ? "checkmark.circle.fill" : "exclamationmark.circle")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(result.code != nil ? c.tgi : c.tpi)
                    Text(CodeModelText.test(result))
                        .font(BrandFont.body(12))
                        .foregroundStyle(c.on)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.leading, 44)
                .transition(.opacity)
            }
        }
        .padding(.vertical, 10)
        .overlay(alignment: .top) { Rectangle().fill(c.olv).frame(height: 1) }
    }

    private var isWarning: Bool {
        if !model.available { return true }
        if case .failed = model.download?.state { return true }
        return false
    }

    private var symbol: (name: String, tint: TileTint) {
        if let download = model.download {
            return switch download.state {
            case .running: ("arrow.down", .purple)
            case .paused: ("pause", .neutral)
            case .verifying: ("checkmark.shield", .purple)
            case .failed: ("exclamationmark.triangle", .neutral)
            }
        }
        return model.installed != nil ? ("cpu", .green) : ("arrow.down.circle", .blue)
    }

    @ViewBuilder private var buttons: some View {
        if let current = model.download {
            switch current.state {
            case .running:
                Button(L10n.text("codes.model.pause", fallback: "Pause"), action: actions.pauseCodeModel)
                    .buttonStyle(PillButtonStyle(kind: .neutral, height: 28))
                Button(L10n.text("action.cancel", fallback: "Cancel"), action: actions.cancelCodeModel)
                    .buttonStyle(PillButtonStyle(kind: .danger, height: 28))
            case .paused:
                Button(L10n.text("action.cancel", fallback: "Cancel"), action: actions.cancelCodeModel)
                    .buttonStyle(PillButtonStyle(kind: .neutral, height: 28))
                Button(L10n.text("codes.model.resume", fallback: "Resume"), action: actions.resumeCodeModel)
                    .buttonStyle(PillButtonStyle(kind: .tonal, height: 28))
            case .verifying:
                EmptyView()
            case .failed:
                Button(L10n.text("action.cancel", fallback: "Cancel"), action: actions.cancelCodeModel)
                    .buttonStyle(PillButtonStyle(kind: .neutral, height: 28))
                Button(L10n.text("action.retry", fallback: "Retry"), action: actions.retryCodeModel)
                    .buttonStyle(PillButtonStyle(kind: .tonal, height: 28))
            }
        } else if model.installed != nil {
            if model.update != nil {
                Button(L10n.text("codes.model.updateAction", fallback: "Update"), action: update)
                    .buttonStyle(PillButtonStyle(kind: .tonal, height: 28))
            }
            Button(model.testing ? L10n.text("codes.model.testing", fallback: "Testing") : L10n.text("codes.model.test", fallback: "Test"), action: actions.testCodeModel)
                .buttonStyle(PillButtonStyle(kind: .outline, height: 28))
                .disabled(model.testing)
            Button(L10n.text("codes.model.remove", fallback: "Remove"), action: remove)
                .buttonStyle(PillButtonStyle(kind: .danger, height: 28))
        } else if model.available {
            Button(L10n.text("codes.model.download", fallback: "Download\u{2026}"), action: download)
                .buttonStyle(PillButtonStyle(kind: .tonal, height: 28))
        }
    }
}

// MARK: - Download sheet

/// Before the first download: what it is, that it stays on this Mac, the exact size and free space,
/// Wi-Fi, and the terms to accept. The Download button needs the tick and enough space.
struct CodeModelDownloadSheet: View {
    let model: CodeModelDisplay
    let openURL: (URL) -> Void
    let cancel: () -> Void
    let download: () -> Void
    /// Screenshots start ticked.
    var initiallyAccepted = false
    @State private var accepted = false
    @State private var document: LicenceDocument?
    @Environment(\.brand) private var c

    static let width: CGFloat = 520

    private var size: Int64 { model.manifest?.size ?? model.size }
    private var spaceShort: Bool {
        guard let free = model.availableSpace else { return false }
        return free < size + CodeModelStore.spaceMargin
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 14) {
                IconTile(symbol: "lock.laptopcomputer", tint: .blue, size: 44, corner: 12)
                VStack(alignment: .leading, spacing: 4) {
                    Text(L10n.text("codes.sheet.title", fallback: "Read codes on this Mac"))
                        .font(BrandFont.heading(20))
                        .foregroundStyle(c.on)
                    Text(L10n.text("codes.sheet.subtitle", fallback: "A small AI model finds the one-time code in each text message from your phone and shows it with a Copy button."))
                        .font(BrandFont.body(13))
                        .foregroundStyle(c.on2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            VStack(alignment: .leading, spacing: 12) {
                fact("lock.fill", .green,
                     L10n.text("codes.sheet.private", fallback: "Private"),
                     L10n.text("codes.sheet.private.detail", fallback: "It runs on this Mac. Message text and codes never leave it."))
                fact("arrow.down.circle.fill", .blue,
                     String(format: L10n.text("codes.sheet.size", fallback: "%@, one time"), CodeModelText.megabytes(size)),
                     L10n.text("codes.sheet.size.detail", fallback: "This is the expected size for a model that runs on your own device. It stays here until you remove it in Settings."))
                fact("internaldrive.fill", spaceShort ? .neutral : .purple,
                     spaceLine,
                     spaceShort
                        ? L10n.text("codes.sheet.space.short", fallback: "Free up some space first; Bridgey keeps 100 MB spare so your disk never fills up.")
                        : L10n.text("codes.sheet.space.detail", fallback: "Saved in Bridgey\u{2019}s Application Support folder and left out of backups."),
                     warning: spaceShort)
                fact("wifi", .neutral,
                     L10n.text("codes.sheet.wifi", fallback: "Wi-Fi recommended"),
                     L10n.text("codes.sheet.wifi.detail", fallback: "You can pause at any time. It picks up where it stopped, even after a restart."))
            }
            .padding(16)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(c.s1))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(c.olv, lineWidth: 1))
            VStack(alignment: .leading, spacing: 10) {
                Toggle(isOn: $accepted) {
                    Text(L10n.text("codes.sheet.accept", fallback: "I accept the Gemma Terms of Use, the Gemma Prohibited Use Policy and Bridgey\u{2019}s model terms."))
                        .font(BrandFont.body(13, .medium))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .toggleStyle(BrandCheckboxStyle())
                HStack(spacing: 14) {
                    link(L10n.text("codes.sheet.gemmaTerms", fallback: "Gemma Terms of Use"), url: model.manifest?.licenceURL ?? LicenceDocument.gemmaTermsURL)
                    link(L10n.text("codes.sheet.prohibited", fallback: "Prohibited Use Policy"), url: model.manifest?.prohibitedUseURL ?? LicenceDocument.prohibitedUseURL)
                    Button { document = .bridgeyModelTerms } label: { linkLabel(L10n.text("codes.sheet.bridgeyTerms", fallback: "Bridgey model terms"), external: false) }
                        .buttonStyle(.plain)
                }
                .padding(.leading, 21)
                Text(acceptanceNote)
                    .font(BrandFont.body(12))
                    .foregroundStyle(c.on2)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 21)
            }
            HStack(spacing: 10) {
                Spacer(minLength: 0)
                Button(L10n.text("action.cancel", fallback: "Cancel"), action: cancel)
                    .buttonStyle(PillButtonStyle(kind: .neutral, height: 32))
                    .keyboardShortcut(.cancelAction)
                Button(String(format: L10n.text("codes.sheet.download", fallback: "Download %@"), CodeModelText.megabytes(size)), action: download)
                    .buttonStyle(PillButtonStyle(kind: .gradient, height: 32))
                    .keyboardShortcut(.defaultAction)
                    .disabled(!accepted || spaceShort)
            }
        }
        .padding(24)
        .frame(width: Self.width)
        .background(c.isDark ? Color(hex: 0x0A101D) : c.bg)
        .onAppear { accepted = initiallyAccepted }
        .sheet(item: $document) { document in
            LicenceSheet(document: document) { self.document = nil }
        }
    }

    private var spaceLine: String {
        guard let free = model.availableSpace else { return L10n.text("codes.sheet.space.unknown", fallback: "Free space unknown") }
        return spaceShort
            ? String(format: L10n.text("codes.sheet.space.needs", fallback: "Not enough space: %1$@ free, %2$@ needed"), CodeModelText.gigabytes(free), CodeModelText.megabytes(size))
            : String(format: L10n.text("codes.sheet.space", fallback: "%@ free on this Mac"), CodeModelText.gigabytes(free))
    }

    private var acceptanceNote: String {
        var note = L10n.text("codes.sheet.note", fallback: "The model is Gemma 3 270M by Google, fine-tuned by Round Robin. Bridgey keeps a record on this Mac of the date you accept and the model version.")
        if let acceptance = model.acceptance {
            let date = acceptance.acceptedAt.formatted(date: .abbreviated, time: .omitted)
            note += " " + String(format: L10n.text("codes.sheet.accepted", fallback: "Last accepted on %1$@ for version %2$d."), date, acceptance.modelVersion)
        }
        return note
    }

    private func fact(_ symbol: String, _ tint: TileTint, _ title: String, _ detail: String, warning: Bool = false) -> some View {
        HStack(alignment: .top, spacing: 12) {
            IconTile(symbol: symbol, tint: tint, size: 28, corner: 8)
            RowText(title: title, subtitle: detail, warning: warning)
        }
    }

    private func link(_ title: String, url: String) -> some View {
        Button {
            if let target = URL(string: url) { openURL(target) }
        } label: { linkLabel(title, external: true) }
        .buttonStyle(.plain)
    }

    private func linkLabel(_ title: String, external: Bool) -> some View {
        HStack(spacing: 3) {
            Text(title)
            Image(systemName: external ? "arrow.up.right" : "doc.text").font(.system(size: 10, weight: .bold))
        }
        .font(BrandFont.body(12, .semibold))
        .foregroundStyle(c.pri)
        .contentShape(Rectangle())
    }
}

// MARK: - Licences

/// Licence texts shipped in the app (Resources/Licences, copied from the repository's licences/).
enum LicenceDocument: String, Identifiable, CaseIterable {
    case notice, bridgeyModelTerms, gemmaTerms, gemmaProhibitedUse, llamaCpp, bridgey

    static let gemmaTermsURL = "https://ai.google.dev/gemma/terms"
    static let prohibitedUseURL = "https://ai.google.dev/gemma/prohibited_use_policy"

    var id: String { rawValue }

    var fileName: String {
        switch self {
        case .notice: "NOTICE"
        case .bridgeyModelTerms: "BRIDGEY-MODEL-TERMS"
        case .gemmaTerms: "GEMMA-TERMS-OF-USE"
        case .gemmaProhibitedUse: "GEMMA-PROHIBITED-USE-POLICY"
        case .llamaCpp: "LLAMA-CPP-LICENSE"
        case .bridgey: "LICENSE"
        }
    }

    var title: String {
        switch self {
        case .notice: L10n.text("licences.notice", fallback: "Notice")
        case .bridgeyModelTerms: L10n.text("licences.modelTerms", fallback: "Bridgey model terms")
        case .gemmaTerms: L10n.text("licences.gemmaTerms", fallback: "Gemma Terms of Use")
        case .gemmaProhibitedUse: L10n.text("licences.prohibited", fallback: "Gemma Prohibited Use Policy")
        case .llamaCpp: L10n.text("licences.llama", fallback: "llama.cpp (MIT License)")
        case .bridgey: L10n.text("licences.bridgey", fallback: "Bridgey (MIT License)")
        }
    }

    var text: String {
        if let url = Bundle.main.url(forResource: fileName, withExtension: "txt", subdirectory: "Licences"),
           let text = try? String(contentsOf: url, encoding: .utf8) {
            return text
        }
        return String(format: L10n.text("licences.missing", fallback: "This copy of Bridgey does not include the text. It is in the licences folder of %@."), "github.com/round-robin-solutions/bridgey")
    }
}

/// One licence text, scrollable, with Done.
struct LicenceSheet: View {
    let document: LicenceDocument
    let done: () -> Void
    @Environment(\.brand) private var c

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(document.title).font(BrandFont.heading(18)).foregroundStyle(c.on)
            ScrollView {
                Text(document.text)
                    .font(BrandFont.body(12))
                    .foregroundStyle(c.on)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
            }
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(c.s1))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(c.olv, lineWidth: 1))
            HStack {
                Spacer()
                Button(L10n.text("action.done", fallback: "Done"), action: done)
                    .buttonStyle(PillButtonStyle(kind: .tonal, height: 30))
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .frame(width: 560, height: 520)
        .background(c.isDark ? Color(hex: 0x0A101D) : c.bg)
    }
}

/// About > Licences: the app, llama.cpp, and the on-device model's terms.
struct LicencesCard: View {
    @State private var document: LicenceDocument?

    var body: some View {
        SettingsCard(title: L10n.text("licences.title", fallback: "Licences"),
                     footnote: L10n.text("licences.footnote", fallback: "Bridgey\u{2019}s code is MIT. The optional code model is a separate download under the Gemma Terms of Use, whose use restrictions Bridgey\u{2019}s model terms pass on.")) {
            row(.bridgey, L10n.text("licences.bridgey.detail", fallback: "The app, by Semyon Mikhailov and Round Robin"), divider: false)
            row(.llamaCpp, L10n.text("licences.llama.detail", fallback: "Runs the code model on this Mac"))
            row(.notice, L10n.text("licences.notice.detail", fallback: "Gemma is provided under and subject to the Gemma Terms of Use"))
            row(.gemmaTerms, L10n.text("licences.gemmaTerms.detail", fallback: "Google\u{2019}s terms for Gemma and models made from it"))
            row(.gemmaProhibitedUse, L10n.text("licences.prohibited.detail", fallback: "What Gemma models must not be used for"))
            row(.bridgeyModelTerms, L10n.text("licences.modelTerms.detail", fallback: "How these terms apply to Bridgey\u{2019}s code model"))
        }
        .sheet(item: $document) { document in
            LicenceSheet(document: document) { self.document = nil }
        }
    }

    private func row(_ item: LicenceDocument, _ detail: String, divider: Bool = true) -> some View {
        SettingsRow(title: item.title, subtitle: detail, divider: divider) {
            Button(L10n.text("licences.view", fallback: "View")) { document = item }
                .buttonStyle(PillButtonStyle(kind: .outline, height: 28))
        }
    }
}

// MARK: - Menu-bar card

/// The panel's code model card: while the model downloads, and "ready" once after.
struct CodeModelPanelState: Equatable {
    var download: CodeModelDownload?
    var finished = false

    /// Nil when there is nothing to show.
    static func shown(download: CodeModelDownload?, finished: Bool) -> CodeModelPanelState? {
        download != nil || finished ? CodeModelPanelState(download: download, finished: finished) : nil
    }
}

struct CodeModelPanelActions {
    var pause: () -> Void = {}
    var resume: () -> Void = {}
    var cancel: () -> Void = {}
    var retry: () -> Void = {}
    var dismiss: () -> Void = {}
}

enum CodeModelPanelText {
    static func title(_ state: CodeModelPanelState) -> String {
        guard let download = state.download else { return L10n.text("codes.panel.ready", fallback: "Codes are now read on this Mac") }
        return switch download.state {
        case .running: L10n.text("codes.model.downloading", fallback: "Downloading the code model")
        case .paused: L10n.text("codes.panel.paused", fallback: "Code model download paused")
        case .verifying: L10n.text("codes.panel.verifying", fallback: "Checking the code model")
        case .failed: L10n.text("codes.panel.failed", fallback: "Code model download stopped")
        }
    }

    static func detail(_ state: CodeModelPanelState) -> String {
        guard let download = state.download else {
            return L10n.text("codes.panel.ready.detail", fallback: "The model is ready. Message text stays on this Mac.")
        }
        switch download.state {
        case .running:
            return CodeModelText.amount(download.received, of: download.manifest.size) + " \u{00B7} " + CodeModelText.timeLeft(download.secondsLeft)
        case .paused:
            return CodeModelText.amount(download.received, of: download.manifest.size)
        case .verifying:
            return L10n.text("codes.model.verifying.detail", fallback: "Making sure the file arrived complete and unchanged")
        case let .failed(error):
            return CodeModelText.failure(error)
        }
    }

    static func symbol(_ state: CodeModelPanelState) -> (name: String, tint: TileTint) {
        guard let download = state.download else { return ("checkmark.circle", .green) }
        return switch download.state {
        case .running: ("arrow.down", .purple)
        case .paused: ("pause", .neutral)
        case .verifying: ("checkmark.shield", .purple)
        case .failed: ("exclamationmark.triangle", .neutral)
        }
    }
}

struct CodeModelPanelButtons: View {
    let state: CodeModelPanelState
    let actions: CodeModelPanelActions

    var body: some View {
        if let download = state.download {
            switch download.state {
            case .running:
                Button(L10n.text("codes.model.pause", fallback: "Pause"), action: actions.pause)
                    .buttonStyle(PillButtonStyle(kind: .neutral, height: 28))
                Button(L10n.text("action.cancel", fallback: "Cancel"), action: actions.cancel)
                    .buttonStyle(PillButtonStyle(kind: .danger, height: 28))
            case .paused:
                Button(L10n.text("action.cancel", fallback: "Cancel"), action: actions.cancel)
                    .buttonStyle(PillButtonStyle(kind: .neutral, height: 28))
                Button(L10n.text("codes.model.resume", fallback: "Resume"), action: actions.resume)
                    .buttonStyle(PillButtonStyle(kind: .tonal, height: 28))
            case .verifying:
                EmptyView()
            case .failed:
                Button(L10n.text("action.cancel", fallback: "Cancel"), action: actions.cancel)
                    .buttonStyle(PillButtonStyle(kind: .neutral, height: 28))
                Button(L10n.text("action.retry", fallback: "Retry"), action: actions.retry)
                    .buttonStyle(PillButtonStyle(kind: .tonal, height: 28))
            }
        } else {
            Button(L10n.text("action.dismiss", fallback: "Dismiss"), action: actions.dismiss)
                .buttonStyle(PillButtonStyle(kind: .neutral, height: 28))
        }
    }
}
