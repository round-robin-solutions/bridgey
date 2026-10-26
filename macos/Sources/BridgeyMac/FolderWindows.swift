import AppKit
import SwiftUI

// The send sheet (3.1, mode a), the conflict question (3.3) and the expanded folder details shared by the
// File Transfer window and the Stream panel. Views draw from plain state, so screenshots render them.

// MARK: - Send sheet

struct FolderSheetState: Equatable {
    var phoneName = ""
    var folderName = ""
    var rootName = ""
    var places: [PlaceInfo] = []
    var placeID: String?
    var path: [String] = []
    var folders: [String] = []
    var hasMore = false
    var loading = false
    var error: String?
    var creating = false
    var newFolderOpen = false
    var newFolderName = ""
    var scanning = true
    var fileCount = 0
    var folderCount = 0
    var totalSize: Int64 = 0
    var skipped = SkippedCounts()
    var packages: [String] = []
    var renamed = 0
    var problem: String?
    var hashing: Double?
    var options = FolderScanOptions()

    var selectedPlace: PlaceInfo? { places.first { $0.placeId == placeID } }

    var canSend: Bool {
        // Send stays enabled while files are read; the offer goes out when reading ends.
        guard problem == nil, !scanning, let place = selectedPlace else { return false }
        return place.available
    }

    var title: String {
        String(format: L10n.text("folders.sheet.title", fallback: "Send \u{201C}%1$@\u{201D} to %2$@"), folderName, phoneName)
    }
}

struct FolderSheetActions {
    var selectPlace: (String) -> Void = { _ in }
    var open: (String) -> Void = { _ in }
    /// Go up to `depth` components (0 is the place itself).
    var goTo: (Int) -> Void = { _ in }
    var loadMore: () -> Void = {}
    var showNewFolder: (Bool) -> Void = { _ in }
    var setNewFolderName: (String) -> Void = { _ in }
    var createFolder: () -> Void = {}
    var setIncludeHidden: (Bool) -> Void = { _ in }
    var setIncludeSystem: (Bool) -> Void = { _ in }
    var send: () -> Void = {}
    var cancel: () -> Void = {}
}

struct FolderSendSheetView: View {
    let state: FolderSheetState
    let actions: FolderSheetActions
    @Environment(\.brand) private var c
    @Environment(\.snapshotRendering) private var snapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(state.title)
                .font(BrandFont.heading(18))
                .foregroundStyle(c.on)
                .lineLimit(1)
            HStack(alignment: .top, spacing: 12) {
                placesList
                    .frame(width: 200)
                browser
            }
            .frame(height: 240)
            summary
            HStack(spacing: 10) {
                if let place = state.selectedPlace {
                    Text(FolderText.savesTo(placeLabel: place.label, path: state.path.joined(separator: "/"), rootName: state.rootName))
                        .font(BrandFont.body(12))
                        .foregroundStyle(c.on2)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 8)
                Button(L10n.text("action.cancel", fallback: "Cancel"), action: actions.cancel)
                    .buttonStyle(PillButtonStyle(kind: .neutral))
                    .keyboardShortcut(.cancelAction)
                Button(L10n.text("folders.sheet.send", fallback: "Send"), action: actions.send)
                    .buttonStyle(PillButtonStyle(kind: .gradient))
                    .keyboardShortcut(.defaultAction)
                    .disabled(!state.canSend)
            }
        }
        .padding(20)
        .frame(width: 640)
        .background(c.bg)
    }

    private var placesList: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(String(format: L10n.text("folders.sheet.places", fallback: "On %@"), state.phoneName))
                .font(BrandFont.body(11, .semibold))
                .foregroundStyle(c.on2)
                .padding(.horizontal, 8)
                .padding(.bottom, 4)
            ForEach(state.places) { place in
                Button { actions.selectPlace(place.placeId) } label: {
                    HStack(spacing: 8) {
                        Image(systemName: place.placeId == defaultPlaceID ? "arrow.down.circle" : "folder")
                            .font(.system(size: 13))
                            .frame(width: 18)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(place.label)
                                .font(BrandFont.body(13, place.placeId == state.placeID ? .semibold : .regular))
                                .lineLimit(1)
                            if !place.available {
                                Text(L10n.text("folders.sheet.unavailable", fallback: "Not available"))
                                    .font(BrandFont.body(11))
                            } else if let free = place.freeBytes {
                                Text(String(format: L10n.text("folders.sheet.free", fallback: "%@ free"), FolderText.bytes(free)))
                                    .font(BrandFont.body(11))
                                    .foregroundStyle(c.on2)
                            }
                        }
                        Spacer(minLength: 0)
                    }
                    .foregroundStyle(place.available ? c.on : c.on2.opacity(0.7))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(place.placeId == state.placeID ? c.tb : Color.clear))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!place.available)
            }
            Spacer(minLength: 0)
        }
        .padding(8)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(c.s1))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(c.olv, lineWidth: 1))
    }

    private var browser: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 4) {
                if let place = state.selectedPlace {
                    pathButton(place.label, depth: 0)
                    ForEach(Array(state.path.enumerated()), id: \.offset) { index, name in
                        Text("\u{203A}").foregroundStyle(c.on2)
                        pathButton(name, depth: index + 1)
                    }
                }
                Spacer(minLength: 8)
                Button {
                    actions.showNewFolder(!state.newFolderOpen)
                } label: {
                    Label(L10n.text("folders.sheet.newFolder", fallback: "New Folder"), systemImage: "folder.badge.plus")
                }
                .buttonStyle(PillButtonStyle(kind: .tonal, height: 26))
                .disabled(state.selectedPlace?.available != true || state.creating)
            }
            if state.newFolderOpen {
                HStack(spacing: 8) {
                    Group {
                        if snapshot {
                            // ImageRenderer cannot draw AppKit text fields.
                            Text(state.newFolderName.isEmpty ? L10n.text("folders.sheet.newFolderName", fallback: "Folder name") : state.newFolderName)
                                .foregroundStyle(state.newFolderName.isEmpty ? c.on2 : c.on)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        } else {
                            TextField(L10n.text("folders.sheet.newFolderName", fallback: "Folder name"),
                                      text: Binding(get: { state.newFolderName }, set: actions.setNewFolderName))
                                .textFieldStyle(.plain)
                                .onSubmit { if !state.creating { actions.createFolder() } }
                        }
                    }
                    .font(BrandFont.body(13))
                    .padding(.horizontal, 8)
                    .frame(height: 26)
                    .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(c.bg))
                    .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(c.pri, lineWidth: 1.5))
                    Button(L10n.text("folders.sheet.create", fallback: "Create"), action: actions.createFolder)
                        .buttonStyle(PillButtonStyle(kind: .tonal, height: 26))
                        .disabled(state.creating || state.newFolderName.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            folderList
        }
        .padding(10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(c.s1))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(c.olv, lineWidth: 1))
    }

    private func pathButton(_ title: String, depth: Int) -> some View {
        Button { actions.goTo(depth) } label: {
            Text(title)
                .font(BrandFont.body(13, depth == state.path.count ? .semibold : .regular))
                .foregroundStyle(depth == state.path.count ? c.on : c.pri)
                .lineLimit(1)
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder private var folderList: some View {
        if let error = state.error {
            Text(error)
                .font(BrandFont.body(12))
                .foregroundStyle(c.warn)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if state.loading && state.folders.isEmpty {
            Text(L10n.text("folders.sheet.loading", fallback: "Loading\u{2026}"))
                .font(BrandFont.body(12))
                .foregroundStyle(c.on2)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if state.folders.isEmpty {
            Text(L10n.text("folders.sheet.noSubfolders", fallback: "No folders here. It is saved here, or make a new folder."))
                .font(BrandFont.body(12))
                .foregroundStyle(c.on2)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            BoundedScroll {
                ForEach(state.folders, id: \.self) { name in
                    Button { actions.open(name) } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "folder.fill").foregroundStyle(c.tbi)
                            Text(name).foregroundStyle(c.on).lineLimit(1)
                            Spacer(minLength: 0)
                            Image(systemName: "chevron.right").font(.system(size: 10)).foregroundStyle(c.on2)
                        }
                        .font(BrandFont.body(13))
                        .padding(.vertical, 5)
                        .padding(.horizontal, 4)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                if state.hasMore {
                    Button(L10n.text("folders.sheet.more", fallback: "Show more"), action: actions.loadMore)
                        .buttonStyle(PillButtonStyle(kind: .neutral, height: 24))
                        .padding(.top, 4)
                }
            }
        }
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: 6) {
            if state.scanning {
                HStack(spacing: 8) {
                    Text(L10n.text("folders.status.scanning", fallback: "Preparing: counting files\u{2026}"))
                        .font(BrandFont.body(12))
                        .foregroundStyle(c.on2)
                }
            } else {
                Text(([FolderText.counts(files: state.fileCount, folders: state.folderCount, bytes: state.totalSize)]
                      + [FolderText.skippedOther(state.skipped), FolderText.renamed(state.renamed)].compactMap { $0 })
                    .joined(separator: " \u{00B7} "))
                    .font(BrandFont.body(13, .medium))
                    .foregroundStyle(c.on)
            }
            HStack(spacing: 14) {
                if let skipped = FolderText.skippedHiddenSystem(state.skipped) {
                    Text(skipped).font(BrandFont.body(12)).foregroundStyle(c.on2)
                }
                Spacer(minLength: 0)
                Toggle(L10n.text("folders.sheet.includeHidden", fallback: "Include hidden files"),
                       isOn: Binding(get: { state.options.includeHidden }, set: actions.setIncludeHidden))
                Toggle(L10n.text("folders.sheet.includeSystem", fallback: "Include system files"),
                       isOn: Binding(get: { state.options.includeSystem }, set: actions.setIncludeSystem))
            }
            .toggleStyle(BrandCheckboxStyle())
            .font(BrandFont.body(12))
            if let notice = FolderText.packageNotice(state.packages) {
                Text(notice).font(BrandFont.body(12)).foregroundStyle(c.on2)
            }
            if let problem = state.problem {
                Text(problem).font(BrandFont.body(12, .medium)).foregroundStyle(c.warn)
            } else if let hashing = state.hashing {
                HStack(spacing: 8) {
                    UpdateProgressBar(progress: hashing).frame(width: 160)
                    Text(String(format: L10n.text("folders.sheet.hashing", fallback: "Reading files: %@%%. You can press Send now."), FolderText.number(Int(hashing * 100))))
                        .font(BrandFont.body(12))
                        .foregroundStyle(c.on2)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(c.s2))
    }
}

@MainActor
final class FolderSheetModel: ObservableObject {
    @Published var state: FolderSheetState
    var actions = FolderSheetActions()

    init(state: FolderSheetState) { self.state = state }
}

private struct FolderSheetHost: View {
    @ObservedObject var model: FolderSheetModel
    let reduceMotion: Bool

    var body: some View {
        BrandRoot(reduceMotion: reduceMotion) {
            FolderSendSheetView(state: model.state, actions: model.actions)
        }
    }
}

@MainActor
final class FolderSheetWindowController: NSWindowController, NSWindowDelegate {
    let model: FolderSheetModel
    var onClose: (() -> Void)?

    init(model: FolderSheetModel, reduceMotion: Bool) {
        self.model = model
        let panel = NSPanel(contentViewController: NSHostingController(rootView: FolderSheetHost(model: model, reduceMotion: reduceMotion)))
        panel.title = model.state.title
        panel.styleMask = [.titled, .closable]
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior.insert(.canJoinAllSpaces)
        super.init(window: panel)
        panel.delegate = self
        panel.center()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func show() {
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        let close = onClose
        onClose = nil
        close?()
    }

    func dismiss() {
        onClose = nil
        window?.close()
    }
}

// MARK: - Conflict question

struct FolderConflictState: Equatable {
    var name: String
    var destination: String
    var message: String
    var choices: [ConflictChoice]
    var newFolderName: String
    var deadline: Date
}

struct FolderConflictView: View {
    let state: FolderConflictState
    var now: Date?
    let answer: (ConflictChoice) -> Void
    @Environment(\.brand) private var c

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                IconTile(symbol: "folder.badge.questionmark", tint: .purple, size: 40, corner: 10)
                VStack(alignment: .leading, spacing: 6) {
                    Text(L10n.text("folders.conflict.title", fallback: "The folder already exists"))
                        .font(BrandFont.heading(16))
                        .foregroundStyle(c.on)
                    Text(state.message)
                        .font(BrandFont.body(13))
                        .foregroundStyle(c.on)
                        .fixedSize(horizontal: false, vertical: true)
                    countdown
                }
            }
            HStack(spacing: 8) {
                Button(L10n.text("action.cancel", fallback: "Cancel")) { answer(.cancel) }
                    .buttonStyle(PillButtonStyle(kind: .neutral))
                    .keyboardShortcut(.cancelAction)
                Spacer(minLength: 8)
                if state.choices.contains(.newFolder) {
                    Button(FolderText.saveAs(state.newFolderName)) { answer(.newFolder) }
                        .buttonStyle(PillButtonStyle(kind: state.choices.contains(.merge) ? .tonal : .gradient))
                        .modifier(DefaultIf(active: !state.choices.contains(.merge)))
                }
                if state.choices.contains(.replace) {
                    Button(L10n.text("folders.conflict.replace", fallback: "Replace Files")) { answer(.replace) }
                        .buttonStyle(PillButtonStyle(kind: .tonal))
                }
                if state.choices.contains(.merge) {
                    Button(L10n.text("folders.conflict.merge", fallback: "Merge")) { answer(.merge) }
                        .buttonStyle(PillButtonStyle(kind: .gradient))
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(20)
        .frame(width: 520)
        .background(c.bg)
    }

    @ViewBuilder private var countdown: some View {
        if let now {
            countdownText(now)
        } else {
            TimelineView(.periodic(from: .now, by: 1)) { context in countdownText(context.date) }
        }
    }

    private func countdownText(_ date: Date) -> some View {
        Text(String(format: L10n.text("folders.conflict.countdown", fallback: "Cancels by itself in %@ if nobody answers."), FolderText.countdown(until: state.deadline, now: date)))
            .font(BrandFont.body(12).monospacedDigit())
            .foregroundStyle(c.on2)
    }
}

/// Return answers the safe choice: Merge, or Save as new folder when only that is offered. Never Replace.
private struct DefaultIf: ViewModifier {
    let active: Bool
    func body(content: Content) -> some View {
        if active { content.keyboardShortcut(.defaultAction) } else { content }
    }
}

@MainActor
final class FolderConflictWindowController: NSWindowController, NSWindowDelegate {
    private var answered = false
    private let onAnswer: (ConflictChoice) -> Void

    init(state: FolderConflictState, reduceMotion: Bool, onAnswer: @escaping (ConflictChoice) -> Void) {
        self.onAnswer = onAnswer
        var answer: (ConflictChoice) -> Void = { _ in }
        let root = BrandRoot(reduceMotion: reduceMotion) { FolderConflictView(state: state, answer: { answer($0) }) }
        let panel = NSPanel(contentViewController: NSHostingController(rootView: root))
        panel.title = L10n.text("folders.conflict.title", fallback: "The folder already exists")
        panel.styleMask = [.titled, .closable]
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior.insert(.canJoinAllSpaces)
        super.init(window: panel)
        panel.delegate = self
        panel.center()
        answer = { [weak self] choice in self?.answer(choice) }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func show() {
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    private func answer(_ choice: ConflictChoice) {
        guard !answered else { return }
        answered = true
        onAnswer(choice)
        window?.close()
    }

    /// Closing the window is Cancel.
    func windowWillClose(_ notification: Notification) {
        guard !answered else { return }
        answered = true
        onAnswer(.cancel)
    }

    /// The question ended elsewhere (timeout, the phone cancelled): close without answering.
    func dismiss() {
        answered = true
        window?.close()
    }
}

// MARK: - Expanded folder row

/// The current file with its own progress, then failures with their reasons, then the last completed names.
/// Large folders never render every row: completed names are capped at 200 and shown in a bounded scroll.
struct FolderExpandedDetails: View {
    let progress: FolderProgress
    var maxHeight: CGFloat = 150
    @Environment(\.brand) private var c

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let path = progress.currentPath {
                Text(path).font(BrandFont.body(12, .medium)).foregroundStyle(c.on).lineLimit(1).truncationMode(.middle)
                UpdateProgressBar(progress: progress.currentSize > 0 ? Double(progress.currentBytes) / Double(progress.currentSize) : 1)
                Text(String(format: L10n.text("folders.details.current", fallback: "%1$@ of %2$@"), FolderText.bytes(progress.currentBytes), FolderText.bytes(progress.currentSize)))
                    .font(BrandFont.body(11).monospacedDigit())
                    .foregroundStyle(c.on2)
            }
            if !progress.failures.isEmpty {
                Text(FolderText.failedFiles(progress.failedCount))
                    .font(BrandFont.body(11, .semibold))
                    .foregroundStyle(c.warn)
                    .padding(.top, 2)
                ForEach(Array(progress.failures.prefix(5).enumerated()), id: \.offset) { _, failure in
                    HStack(spacing: 6) {
                        Text(failure.path).lineLimit(1).truncationMode(.middle)
                        Spacer(minLength: 4)
                        Text(FolderText.failureReason(failure.code)).foregroundStyle(c.warn)
                    }
                    .font(BrandFont.body(11))
                    .foregroundStyle(c.on)
                }
            }
            if !progress.recent.isEmpty {
                Text(L10n.text("folders.details.recent", fallback: "Recently saved"))
                    .font(BrandFont.body(11, .semibold))
                    .foregroundStyle(c.on2)
                    .padding(.top, 2)
                BoundedScroll {
                    ForEach(Array(progress.recent.suffix(FolderSendSession.recentLimit).reversed().enumerated()), id: \.offset) { _, path in
                        HStack(spacing: 6) {
                            Image(systemName: "checkmark").font(.system(size: 9, weight: .bold)).foregroundStyle(c.tgi)
                            Text(path).lineLimit(1).truncationMode(.middle)
                            Spacer(minLength: 0)
                        }
                        .font(BrandFont.body(11))
                        .foregroundStyle(c.on)
                        .padding(.vertical, 1)
                    }
                }
                .frame(maxHeight: maxHeight)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A checkbox drawn in SwiftUI, so it looks the same in the app and in screenshots.
struct BrandCheckboxStyle: ToggleStyle {
    @Environment(\.brand) private var c

    func makeBody(configuration: Configuration) -> some View {
        Button { configuration.isOn.toggle() } label: {
            HStack(spacing: 6) {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(configuration.isOn ? c.pri : Color.clear)
                    .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous).strokeBorder(configuration.isOn ? c.pri : c.ol, lineWidth: 1.5))
                    .overlay(Image(systemName: "checkmark").font(.system(size: 9, weight: .bold)).foregroundStyle(c.onpri).opacity(configuration.isOn ? 1 : 0))
                    .frame(width: 15, height: 15)
                configuration.label.foregroundStyle(c.on)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityValue(configuration.isOn ? "on" : "off")
    }
}
