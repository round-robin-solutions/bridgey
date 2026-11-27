import AppKit
import SwiftUI

/*
 * Calls window (draft dialer_draft1): a keypad, the phone's contacts and recent calls, and the SIM to
 * call from. Calls go through the phone, and WhatsApp calls through the phone's WhatsApp; call audio
 * stays on the phone or its earbuds, as the window says. Keyboard first: type digits or a name, the
 * arrows move through the list, Return calls, Option-Return is a WhatsApp call (Shift for video),
 * Command-1 and Command-2 pick the SIM, Escape clears and then closes. Direction B "Stream"
 * (BrandTheme). CallsView is pure (a model and actions), so the screenshots render it from sample state.
 */

// MARK: - Model

struct CallsPhoneItem: Identifiable, Equatable {
    let id: String
    let name: String
}

/// Why the window cannot call yet, or that it can.
enum CallsAvailability: Equatable {
    case ready
    /// This Mac has not turned the window on for this phone.
    case macOff(String)
    /// The phone does not allow this Mac (or has the window off).
    case phoneOff(String)
    /// The phone runs a Bridgey without protocol 2.
    case phoneTooOld(String)
    case noPhone
    case loading(String)
}

struct CallsModel {
    static let size = NSSize(width: 780, height: 540)

    var phones: [CallsPhoneItem] = []
    var phoneID: String?
    var phoneName = ""
    var availability: CallsAvailability = .noPhone
    var status: DialerPhoneStatus?
    var query = ""
    var rows: [CallsRow] = []
    var selection: String?
    var simPreference: CallsSimPreference = .ask
    /// The SIM picked in the window for the next call.
    var pickedSim: Int?
    /// Two SIMs and none picked: the window asks which one before calling.
    var askingSim: CallsTarget?
    var showWhatsApp = true
    var whatsAppOnMac = false
    var calling: CallsTarget?
    var notice: (text: String, good: Bool, id: String)?
    var searching = false
    var contactsError: String?
    var recentsLoading = false
    var recentsError: String?
    var now = Date()

    var sims: [SmsSim] { status?.sims ?? [] }
    var showsSims: Bool { sims.count >= 2 }
    var selectedRow: CallsRow? { rows.first { $0.id == selection } ?? rows.first }
    /// What Return calls: the selected row's number.
    var primaryNumber: String? { selectedRow?.number }
    var whatsAppAvailable: Bool { showWhatsApp && status?.whatsApp == true }
}

struct CallsActions {
    var setQuery: (String) -> Void = { _ in }
    var key: (String) -> Void = { _ in }
    var backspace: () -> Void = {}
    var select: (String) -> Void = { _ in }
    /// Call a number through the phone (the SIM is worked out from the pick and the setting).
    var callNumber: (String) -> Void = { _ in }
    var whatsApp: (_ dataID: Int, _ video: Bool) -> Void = { _, _ in }
    var openWhatsAppOnMac: (String) -> Void = { _ in }
    var copyNumber: (String) -> Void = { _ in }
    var pickSim: (Int?) -> Void = { _ in }
    /// The answer to "Call from which SIM?".
    var callWithSim: (Int) -> Void = { _ in }
    var cancelSim: () -> Void = {}
    var selectPhone: (String) -> Void = { _ in }
    var turnOn: () -> Void = {}
    var openSettings: () -> Void = {}
    var dismissNotice: () -> Void = {}
}

// MARK: - Window

@MainActor
final class CallsSelection: ObservableObject {
    @Published var phoneID: String?
    @Published var query = ""
    @Published var selection: String?
    @Published var pickedSim: Int?
    @Published var askingSim: CallsTarget?
    /// Changes each time the window is shown: the field takes the keyboard.
    @Published var focusToken = 0

    func selectPhone(_ id: String?) {
        guard phoneID != id else { return }
        phoneID = id
        query = ""
        selection = nil
        pickedSim = nil
        askingSim = nil
    }
}

@MainActor
enum CallsWindowController {
    private static var window: NSWindow?
    private static let delegate = CallsWindowDelegate()
    static let selection = CallsSelection()

    /// Opens the window, on `phoneID` when given; it fades in and its content settles into place.
    static func show(pairing: PairingCoordinator, phoneID: String? = nil) {
        if let phoneID { selection.selectPhone(phoneID) }
        if window == nil {
            let root = CallsLiveView(pairing: pairing, calls: pairing.phoneCalls, settings: pairing.observedSettings, selection: selection)
            let created = NSWindow(contentViewController: NSHostingController(rootView: root))
            created.title = L10n.text("calls.window", fallback: "Calls")
            created.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
            created.titlebarAppearsTransparent = true
            created.titleVisibility = .hidden
            created.isReleasedWhenClosed = false
            created.setContentSize(CallsModel.size)
            created.minSize = NSSize(width: 680, height: 460)
            created.setFrameAutosaveName("BridgeyCallsWindow")
            created.delegate = delegate
            created.center()
            window = created
        }
        guard let window else { return }
        NSApp.activate(ignoringOtherApps: true)
        if !window.isVisible { window.alphaValue = 0 }
        window.makeKeyAndOrderFront(nil)
        BridgeyWindows.fadeIn(window, duration: 0.18)
        selection.focusToken += 1
    }

    /// Fades out, then orders out; the window is kept for the next show.
    static func close() { BridgeyWindows.fadeOut(window, duration: 0.15) }

    static func owns(_ candidate: NSWindow?) -> Bool { candidate != nil && candidate === window }
}

private final class CallsWindowDelegate: NSObject, NSWindowDelegate {
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        MainActor.assumeIsolated { CallsWindowController.close() }
        return false
    }
}

// MARK: - Live

private struct CallsLiveView: View {
    @ObservedObject var pairing: PairingCoordinator
    @ObservedObject var calls: PhoneCalls
    @ObservedObject var settings: BridgeySettings
    @ObservedObject var selection: CallsSelection
    @AppStorage("settings.reduceMotion") private var reduceMotion = false
    @State private var keyMonitor: Any?

    var body: some View {
        BrandRoot(reduceMotion: reduceMotion) {
            CallsView(model: model, actions: actions, focusToken: selection.focusToken)
        }
        .ignoresSafeArea()
        .onAppear {
            reconcile()
            installKeys()
        }
        .onDisappear {
            if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
            keyMonitor = nil
        }
        .onChange(of: pairing.callsPhones.map(\.id)) { _ in reconcile() }
        .onChange(of: selection.focusToken) { _ in reconcile() }
        .onChange(of: calls.notice) { notice in
            guard let notice, notice.kind != .sent else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 8) { if calls.notice?.id == notice.id { calls.dismissNotice() } }
        }
    }

    private var phoneID: String? { selection.phoneID }

    private func reconcile() {
        let phones = pairing.callsPhones
        if phones.first(where: { $0.id == selection.phoneID }) == nil { selection.selectPhone(phones.first?.id) }
        if let phoneID, pairing.callsAvailable(for: phoneID) { calls.loadRecents(phoneID) }
    }

    private var model: CallsModel {
        var model = CallsModel()
        model.phones = pairing.callsPhones.map { CallsPhoneItem(id: $0.id, name: $0.name) }
        model.phoneID = phoneID
        model.phoneName = model.phones.first { $0.id == phoneID }?.name ?? ""
        model.availability = phoneID.map(pairing.callsAvailability(for:)) ?? .noPhone
        let data = phoneID.map(calls.data) ?? CallsPhoneData()
        model.status = data.status
        model.query = selection.query
        let contacts = calls.contactsQuery == selection.query.trimmingCharacters(in: .whitespacesAndNewlines) ? calls.contacts : []
        model.rows = callsRows(query: selection.query, contacts: contacts, recents: data.recents, limit: settings.callsRecentCount)
        model.selection = selection.selection
        model.simPreference = settings.callsSim
        model.pickedSim = selection.pickedSim ?? callsInitialSim(preference: settings.callsSim, sims: model.sims)
        model.askingSim = selection.askingSim
        model.showWhatsApp = settings.callsShowWhatsApp
        model.whatsAppOnMac = settings.callsShowWhatsApp && WhatsAppOnMac.isInstalled
        model.calling = calls.calling
        if let notice = calls.notice, notice.phoneID == phoneID {
            model.notice = (callsNoticeText(notice, phone: model.phoneName), notice.good, notice.id)
        }
        model.searching = calls.searching
        model.contactsError = calls.contactsError
        model.recentsLoading = data.loadingRecents
        model.recentsError = data.recentsError
        model.now = Date()
        return model
    }

    private var actions: CallsActions {
        var actions = CallsActions()
        actions.setQuery = setQuery
        actions.key = { setQuery(selection.query + $0) }
        actions.backspace = { if !selection.query.isEmpty { setQuery(String(selection.query.dropLast())) } }
        actions.select = { selection.selection = $0 }
        actions.callNumber = callNumber
        actions.whatsApp = { dataID, video in
            guard let phoneID else { return }
            calls.call(.whatsApp(dataID: dataID, video: video), phoneID: phoneID)
        }
        actions.openWhatsAppOnMac = { WhatsAppOnMac.open($0) }
        actions.copyNumber = { number in
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(number, forType: .string)
        }
        actions.pickSim = { selection.pickedSim = $0 }
        actions.callWithSim = { subId in
            selection.pickedSim = subId
            guard case let .number(number, _)? = selection.askingSim else { return }
            selection.askingSim = nil
            send(number, subId: subId)
        }
        actions.cancelSim = { selection.askingSim = nil }
        actions.selectPhone = { selection.selectPhone($0); reconcile() }
        actions.turnOn = {
            guard let phoneID else { return }
            pairing.setCallsWindow(enabled: true, for: phoneID)
        }
        actions.openSettings = { pairing.openSettingsPane?(.calls) }
        actions.dismissNotice = { calls.dismissNotice() }
        return actions
    }

    private func setQuery(_ query: String) {
        selection.query = query
        selection.selection = nil
        if let phoneID { calls.search(query, phoneID: phoneID) }
    }

    private func callNumber(_ number: String) {
        let sims = phoneID.map(calls.data)?.status?.sims ?? []
        switch callsSimDecision(preference: settings.callsSim, sims: sims, picked: selection.pickedSim) {
        case .phoneDefault: send(number, subId: nil)
        case let .use(subId): send(number, subId: subId)
        case .ask: selection.askingSim = .number(number, subId: nil)
        }
    }

    private func send(_ number: String, subId: Int?) {
        guard let phoneID else { return }
        calls.call(.number(number, subId: subId), phoneID: phoneID)
    }

    // MARK: Keyboard

    private func installKeys() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let handled = MainActor.assumeIsolated { handleKey(event) }
            return handled ? nil : event
        }
    }

    private func handleKey(_ event: NSEvent) -> Bool {
        guard CallsWindowController.owns(event.window) else { return false }
        let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
        let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
        let current = model
        if event.keyCode == 53 {
            if selection.askingSim != nil { selection.askingSim = nil } else if !selection.query.isEmpty { setQuery("") } else { CallsWindowController.close() }
            return true
        }
        guard current.availability == .ready else { return false }
        if selection.askingSim != nil, flags.isEmpty, let index = Int(key), (1...current.sims.count).contains(index) {
            actions.callWithSim(current.sims[index - 1].subId)
            return true
        }
        if flags == .command, let index = Int(key), (1...2).contains(index), current.sims.count >= index {
            selection.pickedSim = current.sims[index - 1].subId
            return true
        }
        let rows = current.rows
        if flags.isEmpty, event.keyCode == 125 || event.keyCode == 126, !rows.isEmpty {
            let index = rows.firstIndex { $0.id == current.selectedRow?.id } ?? 0
            let next = event.keyCode == 125 ? min(rows.count - 1, index + 1) : max(0, index - 1)
            selection.selection = rows[next].id
            return true
        }
        if event.keyCode == 36 || event.keyCode == 76 {
            if flags.contains(.option), case let .contact(contact)? = current.selectedRow, current.whatsAppAvailable {
                let video = flags.contains(.shift)
                if let row = contact.whatsApp.first(where: { (video ? $0.video : $0.voice) != nil }), let id = video ? row.video : row.voice {
                    actions.whatsApp(id, video)
                }
                return true
            }
            if flags.isEmpty, let number = current.primaryNumber, current.calling == nil {
                callNumber(number)
                return true
            }
            return flags.isEmpty
        }
        return false
    }
}

// MARK: - View

struct CallsView: View {
    let model: CallsModel
    let actions: CallsActions
    var focusToken = 0
    @Environment(\.brand) private var c
    @Environment(\.brandReduceMotion) private var reduce
    @Environment(\.snapshotRendering) private var snapshot
    @State private var appeared = false

    var body: some View {
        let shown = appeared || snapshot
        return ZStack {
            c.bg
            switch model.availability {
            case .ready:
                HStack(spacing: 0) {
                    DialPad(model: model, actions: actions, focusToken: focusToken)
                        .frame(width: 300)
                        .background(c.s1)
                    Rectangle().fill(c.ol).frame(width: 1)
                    CallsList(model: model, actions: actions)
                }
                .transition(.opacity)
            default:
                CallsStateCard(model: model, actions: actions)
                    .transition(.opacity)
            }
        }
        .frame(minWidth: 680, minHeight: 460)
        .opacity(shown ? 1 : 0)
        .scaleEffect(shown || reduce ? 1 : 0.98)
        .animation(BrandMotion.animation(BrandMotion.page, reduce: reduce), value: model.availability)
        .onAppear {
            withAnimation(BrandMotion.animation(BrandMotion.page, reduce: reduce)) { appeared = true }
        }
    }
}

/// The left side: phone, the field, the keypad, the SIM and the call button.
private struct DialPad: View {
    let model: CallsModel
    let actions: CallsActions
    let focusToken: Int
    @Environment(\.brand) private var c
    @Environment(\.brandReduceMotion) private var reduce
    @Environment(\.snapshotRendering) private var snapshot
    @FocusState private var fieldFocused: Bool

    private static let keys: [(String, String)] = [
        ("1", ""), ("2", "ABC"), ("3", "DEF"), ("4", "GHI"), ("5", "JKL"), ("6", "MNO"),
        ("7", "PQRS"), ("8", "TUV"), ("9", "WXYZ"), ("+", ""), ("0", ""), ("\u{232B}", ""),
    ]

    var body: some View {
        VStack(spacing: 14) {
            HStack {
                Text(L10n.text("calls.window", fallback: "Calls")).font(BrandFont.heading(20)).foregroundStyle(c.on)
                Spacer()
                PhoneChip(model: model, actions: actions)
            }
            .padding(.top, 34)
            field
            Spacer(minLength: 0)
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(64), spacing: 18), count: 3), spacing: 12) {
                ForEach(Self.keys, id: \.0) { key in
                    Button {
                        if key.0 == "\u{232B}" { actions.backspace() } else { actions.key(key.0) }
                    } label: {
                        KeyFace(digit: key.0, letters: key.1)
                    }
                    .buttonStyle(PressScaleStyle())
                    .accessibilityLabel(key.0 == "\u{232B}" ? L10n.text("calls.delete", fallback: "Delete") : key.0)
                }
            }
            if model.showsSims { SimPicker(model: model, actions: actions) }
            CallButton(model: model, actions: actions)
                .padding(.top, 6)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 22)
        .onAppear { fieldFocused = true }
        .onChange(of: focusToken) { _ in fieldFocused = true }
    }

    @ViewBuilder private var field: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(c.on2).font(.system(size: 13, weight: .medium))
            Group {
                if snapshot {
                    Text(model.query.isEmpty ? L10n.text("calls.field", fallback: "Name or number") : model.query)
                        .foregroundStyle(model.query.isEmpty ? c.on2 : c.on)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    TextField(L10n.text("calls.field", fallback: "Name or number"), text: Binding(get: { model.query }, set: actions.setQuery))
                        .textFieldStyle(.plain)
                        .focused($fieldFocused)
                }
            }
            .font(BrandFont.heading(callsQueryIsNumber(model.query) ? 20 : 16))
            .lineLimit(1)
            if !model.query.isEmpty {
                Button { actions.setQuery("") } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(c.on2)
                }
                .buttonStyle(.plain)
                .help(L10n.text("calls.clear", fallback: "Clear (Esc)"))
                .accessibilityLabel(L10n.text("action.clear", fallback: "Clear"))
                .transition(.opacity.combined(with: .scale(scale: 0.8)))
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 44)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(c.s2))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(fieldFocused ? c.pri.opacity(0.6) : Color.clear, lineWidth: 1.5))
        .animation(BrandMotion.animation(BrandMotion.small, reduce: reduce), value: model.query.isEmpty)
    }
}

private struct KeyFace: View {
    let digit: String
    let letters: String
    @Environment(\.brand) private var c

    var body: some View {
        VStack(spacing: 0) {
            if digit == "\u{232B}" {
                Image(systemName: "delete.left").font(.system(size: 18, weight: .regular))
            } else {
                Text(digit).font(BrandFont.heading(digit == "+" ? 22 : 24))
                Text(letters.isEmpty ? " " : letters).font(BrandFont.body(9, .semibold)).kerning(1.2).foregroundStyle(c.on2)
            }
        }
        .foregroundStyle(c.on)
        .frame(width: 64, height: 52)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(digit == "\u{232B}" || digit == "+" ? Color.clear : c.s2))
        .contentShape(Rectangle())
    }
}

/// The phone the window calls through; a menu when there are several.
private struct PhoneChip: View {
    let model: CallsModel
    let actions: CallsActions
    @Environment(\.brand) private var c

    var body: some View {
        let label = HStack(spacing: 5) {
            Image(systemName: "iphone").font(.system(size: 11, weight: .semibold))
            Text(model.phoneName).font(BrandFont.body(12, .medium)).lineLimit(1)
            if model.phones.count > 1 { Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold)) }
        }
        .foregroundStyle(c.tbi)
        .padding(.horizontal, 10)
        .frame(height: 26)
        .background(Capsule().fill(c.tb))
        if model.phones.count > 1 {
            Menu {
                ForEach(model.phones) { phone in Button(phone.name) { actions.selectPhone(phone.id) } }
            } label: { label }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
        } else {
            label
        }
    }
}

private struct SimPicker: View {
    let model: CallsModel
    let actions: CallsActions
    @Environment(\.brand) private var c
    @Environment(\.brandReduceMotion) private var reduce

    var body: some View {
        HStack(spacing: 6) {
            ForEach(Array(model.sims.enumerated()), id: \.element.subId) { index, sim in
                let on = model.pickedSim == sim.subId
                Button { actions.pickSim(on ? nil : sim.subId) } label: {
                    HStack(spacing: 6) {
                        Text("\(index + 1)")
                            .font(BrandFont.body(10, .semibold))
                            .foregroundStyle(on ? c.onpri : c.on2)
                            .frame(width: 16, height: 16)
                            .background(Circle().fill(on ? c.pri : c.s3))
                        Text(sim.label.isEmpty ? String(format: L10n.text("calls.sim", fallback: "SIM %d"), sim.slot + 1) : sim.label)
                            .font(BrandFont.body(12, .medium)).lineLimit(1)
                    }
                    .foregroundStyle(on ? c.on : c.on2)
                    .padding(.horizontal, 10)
                    .frame(maxWidth: .infinity)
                    .frame(height: 30)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous).fill(c.tb).opacity(on ? 1 : 0)
                    )
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(c.ol, lineWidth: on ? 0 : 1))
                    .contentShape(Rectangle())
                }
                .buttonStyle(PressScaleStyle())
                .help(String(format: L10n.text("calls.sim.help", fallback: "Call from this SIM (Command-%d)"), index + 1))
            }
        }
        .animation(BrandMotion.animation(BrandMotion.small, reduce: reduce), value: model.pickedSim)
    }
}

private struct CallButton: View {
    let model: CallsModel
    let actions: CallsActions
    @Environment(\.brand) private var c
    @Environment(\.brandReduceMotion) private var reduce

    var body: some View {
        ZStack {
            if let asking = model.askingSim, case .number = asking {
                SimQuestion(model: model, actions: actions)
                    .transition(reduce ? .opacity : .opacity.combined(with: .scale(scale: 0.92)))
            } else {
                Button { if let number = model.primaryNumber { actions.callNumber(number) } } label: {
                    ZStack {
                        Circle().fill(Color(hex: 0x1FB86A))
                        if model.calling != nil {
                            ProgressView().controlSize(.small).tint(.white)
                        } else {
                            Image(systemName: "phone.fill").font(.system(size: 22, weight: .semibold)).foregroundStyle(.white)
                        }
                    }
                    .frame(width: 60, height: 60)
                    .opacity(model.primaryNumber == nil ? 0.4 : 1)
                }
                .buttonStyle(PressScaleStyle())
                .disabled(model.primaryNumber == nil || model.calling != nil)
                .help(L10n.text("calls.call.help", fallback: "Call (Return)"))
                .accessibilityLabel(L10n.text("calls.call", fallback: "Call"))
                .transition(.opacity)
            }
        }
        .frame(height: 64)
        .animation(BrandMotion.animation(BrandMotion.pop, reduce: reduce), value: model.askingSim != nil)
    }
}

/// "Call from which SIM?" with one button per SIM; 1 and 2 on the keyboard answer it.
private struct SimQuestion: View {
    let model: CallsModel
    let actions: CallsActions
    @Environment(\.brand) private var c

    var body: some View {
        VStack(spacing: 8) {
            Text(L10n.text("calls.sim.question", fallback: "Call from which SIM?"))
                .font(BrandFont.body(12, .semibold)).foregroundStyle(c.on2)
            HStack(spacing: 8) { buttons }
        }
    }

    @ViewBuilder private var buttons: some View {
        ForEach(Array(model.sims.enumerated()), id: \.element.subId) { index, sim in
            Button { actions.callWithSim(sim.subId) } label: {
                HStack(spacing: 6) {
                    Image(systemName: "phone.fill").font(.system(size: 11, weight: .semibold))
                    Text(sim.label.isEmpty ? String(format: L10n.text("calls.sim", fallback: "SIM %d"), sim.slot + 1) : sim.label).lineLimit(1)
                }
            }
            .buttonStyle(PillButtonStyle(kind: .good, height: 40))
            .help(String(format: L10n.text("calls.sim.key", fallback: "Press %d"), index + 1))
        }
        Button(action: actions.cancelSim) { Image(systemName: "xmark") }
            .buttonStyle(PillButtonStyle(kind: .neutral, height: 40))
            .accessibilityLabel(L10n.text("action.cancel", fallback: "Cancel"))
            .help(L10n.text("action.cancel", fallback: "Cancel"))
    }
}

/// The right side: recent calls, or what matches the typing; then a line about call audio.
private struct CallsList: View {
    let model: CallsModel
    let actions: CallsActions
    @Environment(\.brand) private var c
    @Environment(\.brandReduceMotion) private var reduce
    @Environment(\.snapshotRendering) private var snapshot

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(model.query.trimmingCharacters(in: .whitespaces).isEmpty
                     ? L10n.text("calls.recents", fallback: "Recent calls")
                     : L10n.text("calls.results", fallback: "Results"))
                    .font(BrandFont.body(13, .semibold)).foregroundStyle(c.on)
                if model.searching || model.recentsLoading { ProgressView().controlSize(.mini).padding(.leading, 4) }
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.top, 38)
            .padding(.bottom, 8)
            if model.rows.isEmpty {
                empty.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if snapshot {
                VStack(spacing: 2) { rows }.padding(.horizontal, 10).frame(maxHeight: .infinity, alignment: .top).clipped()
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 2) { rows }.padding(.horizontal, 10).padding(.bottom, 8)
                    }
                    .onChange(of: model.selection) { id in
                        guard let id else { return }
                        withAnimation(BrandMotion.animation(BrandMotion.small, reduce: reduce)) { proxy.scrollTo(id) }
                    }
                }
            }
            footer
        }
    }

    @ViewBuilder private var rows: some View {
        ForEach(model.rows) { row in
            CallsRowView(row: row, model: model, actions: actions, selected: model.selectedRow?.id == row.id)
                .id(row.id)
                .transition(reduce ? .opacity : .asymmetric(insertion: .opacity.combined(with: .offset(y: 6)), removal: .opacity))
        }
    }

    private var emptyText: String {
        let phone = model.phoneName
        if !model.query.trimmingCharacters(in: .whitespaces).isEmpty {
            if model.status?.contacts == .off || model.contactsError == "permission" {
                return String(format: L10n.text("calls.empty.contactsOff", fallback: "Allow Contacts in Bridgey on %@ to search names. Numbers work now."), phone)
            }
            if model.status?.contacts == .unavailable { return L10n.text("calls.empty.contactsUnavailable", fallback: "Type a number to call it.") }
            return model.searching ? "" : L10n.text("calls.empty.noMatch", fallback: "No contacts match.")
        }
        switch model.status?.recents {
        case .off?: return String(format: L10n.text("calls.empty.recentsOff", fallback: "Allow Call history in Bridgey on %@ to see recent calls here."), phone)
        case .unavailable?: return String(format: L10n.text("calls.empty.recentsUnavailable", fallback: "%@ doesn\u{2019}t share recent calls. Type a number or a name."), phone)
        default: return model.recentsLoading ? "" : L10n.text("calls.empty.noRecents", fallback: "No recent calls.")
        }
    }

    private var empty: some View {
        Text(emptyText)
            .font(BrandFont.body(13))
            .foregroundStyle(c.on2)
            .multilineTextAlignment(.center)
            .frame(maxWidth: 300)
            .transition(.opacity)
    }

    private var footer: some View {
        ZStack {
            if let notice = model.notice {
                HStack(spacing: 8) {
                    Image(systemName: notice.good ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                        .foregroundStyle(notice.good ? c.good : c.warn)
                    Text(notice.text).font(BrandFont.body(12, .medium)).foregroundStyle(c.on).lineLimit(2)
                    Spacer(minLength: 0)
                    Button(action: actions.dismissNotice) { Image(systemName: "xmark").font(.system(size: 10, weight: .bold)) }
                        .buttonStyle(.plain).foregroundStyle(c.on2)
                        .accessibilityLabel(L10n.text("action.dismiss", fallback: "Dismiss"))
                }
                .id(notice.id)
                .transition(reduce ? .opacity : .asymmetric(insertion: .opacity.combined(with: .offset(y: 8)), removal: .opacity))
            } else {
                HStack(spacing: 8) {
                    Image(systemName: "speaker.wave.2").foregroundStyle(c.on2)
                    Text(String(format: L10n.text("calls.audio", fallback: "Call audio stays on %@ or its earbuds."), model.phoneName))
                        .font(BrandFont.body(12)).foregroundStyle(c.on2).lineLimit(2)
                    Spacer(minLength: 0)
                }
                .transition(.opacity)
            }
        }
        .padding(.horizontal, 20)
        .frame(height: 46)
        .background(c.s1.opacity(0.6))
        .overlay(Rectangle().fill(c.ol).frame(height: 1), alignment: .top)
        .animation(BrandMotion.animation(BrandMotion.small, reduce: reduce), value: model.notice?.id)
    }
}

private struct CallsRowView: View {
    let row: CallsRow
    let model: CallsModel
    let actions: CallsActions
    let selected: Bool
    @Environment(\.brand) private var c
    @Environment(\.brandReduceMotion) private var reduce
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 12) {
            avatar
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(BrandFont.body(13, .semibold)).foregroundStyle(c.on).lineLimit(1)
                detail
            }
            Spacer(minLength: 8)
            trailing
        }
        .padding(.horizontal, 10)
        .frame(height: 52)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous).fill(selected ? c.tb : c.s2).opacity(selected || hovering ? 1 : 0)
        )
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { if let number = row.number { actions.callNumber(number) } }
        .onTapGesture { actions.select(row.id) }
        .onHover { hovering = $0 }
        .animation(BrandMotion.animation(BrandMotion.small, reduce: reduce), value: selected)
        .animation(BrandMotion.animation(BrandMotion.effects, reduce: reduce), value: hovering)
        .contextMenu { menu }
    }

    private var title: String {
        switch row {
        case let .number(number): String(format: L10n.text("calls.row.callNumber", fallback: "Call %@"), number)
        case let .contact(contact): contact.name
        case let .recent(call): call.title
        }
    }

    @ViewBuilder private var avatar: some View {
        ZStack {
            Circle().fill(row.isMissed ? c.warn.opacity(0.14) : c.tb)
            switch row {
            case .number: Image(systemName: "phone.fill").font(.system(size: 14, weight: .semibold)).foregroundStyle(c.tbi)
            case let .contact(contact): Text(callsInitials(contact.name)).font(BrandFont.body(13, .semibold)).foregroundStyle(c.tbi)
            case let .recent(call):
                if let name = call.name { Text(callsInitials(name)).font(BrandFont.body(13, .semibold)).foregroundStyle(row.isMissed ? c.warn : c.tbi) } else {
                    Image(systemName: "person.fill").font(.system(size: 14)).foregroundStyle(row.isMissed ? c.warn : c.tbi)
                }
            }
        }
        .frame(width: 34, height: 34)
    }

    @ViewBuilder private var detail: some View {
        switch row {
        case .number:
            Text(L10n.text("calls.row.typed", fallback: "Through the phone")).font(BrandFont.body(11)).foregroundStyle(c.on2)
        case let .contact(contact):
            let first = contact.numbers.first
            HStack(spacing: 4) {
                if contact.starred { Image(systemName: "star.fill").font(.system(size: 9)).foregroundStyle(c.tpi) }
                Text([first?.label, first?.address].compactMap { $0 }.joined(separator: " \u{00B7} ").ifEmpty(L10n.text("calls.row.whatsAppOnly", fallback: "WhatsApp")))
                    .font(BrandFont.body(11)).foregroundStyle(c.on2).lineLimit(1)
                if contact.numbers.count > 1 {
                    Text("+\(contact.numbers.count - 1)").font(BrandFont.body(11, .medium)).foregroundStyle(c.on2)
                }
            }
        case let .recent(call):
            HStack(spacing: 5) {
                Image(systemName: call.type.symbol).font(.system(size: 9, weight: .bold)).foregroundStyle(row.isMissed ? c.warn : c.on2)
                Text(([call.name != nil ? call.address : nil, callsRelativeTime(call.at, now: model.now), callsDuration(call.duration)] as [String?])
                    .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " \u{00B7} "))
                    .font(BrandFont.body(11)).foregroundStyle(row.isMissed ? c.warn : c.on2).lineLimit(1)
                if model.showsSims, let sub = call.subId, let slot = model.sims.first(where: { $0.subId == sub })?.slot {
                    Text("\(slot + 1)").font(BrandFont.body(9, .semibold)).foregroundStyle(c.on2)
                        .frame(width: 14, height: 14).background(Circle().fill(c.s3))
                        .help(String(format: L10n.text("calls.sim", fallback: "SIM %d"), slot + 1))
                }
            }
        }
    }

    @ViewBuilder private var trailing: some View {
        HStack(spacing: 6) {
            if case let .contact(contact) = row, model.whatsAppAvailable, let entry = contact.whatsApp.first {
                if let voice = entry.voice {
                    RowAction(symbol: "phone.bubble", help: L10n.text("calls.whatsApp.voice", fallback: "WhatsApp call (Option-Return)"), tint: .whatsApp) {
                        actions.whatsApp(voice, false)
                    }
                }
                if let video = entry.video {
                    RowAction(symbol: "video", help: L10n.text("calls.whatsApp.video", fallback: "WhatsApp video call (Shift-Option-Return)"), tint: .whatsApp) {
                        actions.whatsApp(video, true)
                    }
                }
            }
            if let number = row.number {
                RowAction(symbol: "phone.fill", help: L10n.text("calls.call.help", fallback: "Call (Return)"), tint: .call) { actions.callNumber(number) }
            }
        }
        .opacity(selected || hovering ? 1 : 0.55)
    }

    @ViewBuilder private var menu: some View {
        if let number = row.number {
            Button(String(format: L10n.text("calls.menu.call", fallback: "Call %@"), number)) { actions.callNumber(number) }
        }
        if case let .contact(contact) = row {
            ForEach(contact.numbers.dropFirst(), id: \.self) { number in
                Button(String(format: L10n.text("calls.menu.call", fallback: "Call %@"), [number.label, number.address].compactMap { $0 }.joined(separator: " "))) {
                    actions.callNumber(number.address)
                }
            }
            if model.whatsAppAvailable {
                ForEach(contact.whatsApp, id: \.self) { entry in
                    if let voice = entry.voice { Button(L10n.text("calls.menu.whatsApp", fallback: "WhatsApp Call")) { actions.whatsApp(voice, false) } }
                    if let video = entry.video { Button(L10n.text("calls.menu.whatsAppVideo", fallback: "WhatsApp Video Call")) { actions.whatsApp(video, true) } }
                }
            }
        }
        if model.whatsAppOnMac, let number = row.whatsAppNumber {
            Divider()
            Button(L10n.text("calls.menu.whatsAppMac", fallback: "Open in WhatsApp on This Mac")) { actions.openWhatsAppOnMac(number) }
        }
        if let number = row.number {
            Divider()
            Button(L10n.text("calls.menu.copy", fallback: "Copy Number")) { actions.copyNumber(number) }
        }
    }
}

private struct RowAction: View {
    enum Tint { case call, whatsApp }
    let symbol: String
    let help: String
    let tint: Tint
    let action: () -> Void
    @Environment(\.brand) private var c

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(tint == .call ? c.tgi : Color(hex: c.isDark ? 0x5EF2B2 : 0x0B7A3E))
                .frame(width: 30, height: 30)
                .background(Circle().fill(tint == .call ? c.tg : c.s3))
        }
        .buttonStyle(PressScaleStyle())
        .help(help)
        .accessibilityLabel(help)
    }
}

/// The whole window when it cannot call yet: what is missing and the one thing to do.
private struct CallsStateCard: View {
    let model: CallsModel
    let actions: CallsActions
    @Environment(\.brand) private var c

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: symbol).font(.system(size: 30, weight: .regular)).foregroundStyle(c.tbi)
                .frame(width: 64, height: 64).background(Circle().fill(c.tb))
            Text(title).font(BrandFont.heading(20)).foregroundStyle(c.on).multilineTextAlignment(.center)
            if let detail { Text(detail).font(BrandFont.body(13)).foregroundStyle(c.on2).multilineTextAlignment(.center).frame(maxWidth: 380) }
            button
        }
        .padding(32)
    }

    private var symbol: String {
        switch model.availability {
        case .macOff: "phone.badge.plus"
        case .phoneOff, .phoneTooOld: "iphone"
        case .noPhone: "iphone.slash"
        case .loading, .ready: "phone"
        }
    }

    private var title: String {
        switch model.availability {
        case let .macOff(name): String(format: L10n.text("calls.state.macOff", fallback: "Call through %@ from this Mac"), name)
        case let .phoneOff(name): String(format: L10n.text("calls.state.phoneOff", fallback: "Allow this Mac on %@"), name)
        case let .phoneTooOld(name): String(format: L10n.text("calls.state.tooOld", fallback: "Update Bridgey on %@"), name)
        case .noPhone: L10n.text("calls.state.noPhone", fallback: "Connect your phone to call from this Mac")
        case let .loading(name): String(format: L10n.text("calls.state.loading", fallback: "Connecting to %@\u{2026}"), name)
        case .ready: ""
        }
    }

    private var detail: String? {
        switch model.availability {
        case .macOff: L10n.text("calls.state.macOff.detail", fallback: "Your phone places each call. Call audio stays on the phone or its earbuds.")
        case .phoneOff: L10n.text("calls.state.phoneOff.detail", fallback: "In Bridgey on the phone: Settings > Calls > Calls window, then turn on this Mac.")
        case .phoneTooOld: L10n.text("calls.state.tooOld.detail", fallback: "The Calls window needs the newest Bridgey on both devices.")
        case .noPhone, .loading, .ready: nil
        }
    }

    @ViewBuilder private var button: some View {
        switch model.availability {
        case let .macOff(name):
            Button(String(format: L10n.text("calls.state.turnOn", fallback: "Turn On for %@"), name), action: actions.turnOn)
                .buttonStyle(PillButtonStyle(kind: .gradient, height: 36))
        case .phoneOff, .phoneTooOld:
            Button(L10n.text("calls.state.settings", fallback: "Calls Settings"), action: actions.openSettings)
                .buttonStyle(PillButtonStyle(kind: .tonal, height: 32))
        case .loading:
            ProgressView().controlSize(.small)
        case .noPhone, .ready:
            EmptyView()
        }
    }
}

private extension RecentCallType {
    var symbol: String {
        switch self {
        case .incoming: "arrow.down.left"
        case .outgoing: "arrow.up.right"
        case .missed: "arrow.down.left"
        case .rejected, .blocked: "nosign"
        case .voicemail: "recordingtape"
        }
    }
}

private extension CallsRow {
    var isMissed: Bool {
        if case let .recent(call) = self { return call.type == .missed }
        return false
    }

    /// The number WhatsApp Desktop can open a chat with.
    var whatsAppNumber: String? {
        switch self {
        case let .contact(contact): contact.whatsApp.first?.address.ifEmpty(nil) ?? contact.numbers.first?.address
        case let .number(number): number
        case let .recent(call): call.address.isEmpty ? nil : call.address
        }
    }
}

private extension String {
    func ifEmpty(_ fallback: String) -> String { isEmpty ? fallback : self }
    func ifEmpty(_ fallback: String?) -> String? { isEmpty ? fallback : self }
}

// MARK: - Panel entry

/// The menu bar panel's way into the Calls window, while it is on for the phone.
struct CallsPanelButton: View {
    let action: () -> Void
    @Environment(\.brand) private var c

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: "phone").font(.system(size: 12, weight: .medium))
                Text(L10n.text("calls.window", fallback: "Calls")).font(BrandFont.body(12, .medium))
            }
            .foregroundStyle(c.on)
            .frame(maxWidth: .infinity)
            .frame(height: 30)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(c.s2))
            .contentShape(Rectangle())
        }
        .buttonStyle(PressScaleStyle())
        .help(L10n.text("calls.entry.help", fallback: "Call through your phone from this Mac"))
    }
}
