import AppKit
import SwiftUI

/*
 * Text messages (draft sms_draft1): the Messages window, Pushbullet style. Conversations on the
 * left, the open conversation on the right with delivery status, MMS images (read only), Copy code
 * on messages that hold one, and a composer with the SIM to send from on dual-SIM phones. New
 * message starts a conversation with a contact or a number. Direction B "Stream" (BrandTheme).
 *
 * Managing conversations, the usual set: pinned first, then unread, then the rest, each newest
 * first; All / Unread and an Archived list; pin, mute, archive, Mark as read or unread and Delete
 * from a right-click menu, swipe actions, the header's buttons and the keyboard (Command-Delete,
 * Shift-Command-U, Command-F); several at once with Command-click, Shift-click or Select; search
 * across every cached message. All of it stays on this Mac except Mark as read, which the phone
 * runs through the messaging app's own notification action (TextMessages, SmsManagement).
 * MessagesView is pure (a model and actions), so the screenshots render it from sample state.
 */

@MainActor
final class MessagesSelection: ObservableObject {
    @Published var phoneID: String?
    @Published var target: MessagesTarget?
    @Published var filter: SmsListFilter = .all
    @Published var query = ""
    /// Conversations chosen for a bulk action (Command-click, Shift-click, Select).
    @Published var selected: Set<Int> = []
    @Published var selecting = false
    /// Where a Shift-click range starts.
    @Published var rangeStart: Int?
    /// A message to scroll to and mark (a search result).
    @Published var focusMessage: String?
    /// The open conversation's first unread message, fixed when it opened.
    @Published var unread: MessagesUnreadAnchor?
    /// Forward: the text the next conversation's composer starts with.
    @Published var forwardText: String?
    /// Command-F: the search field takes the focus each time this changes.
    @Published var searchFocus = 0
}

/// What the unread divider sits above: worked out once per opening, so marking read does not move it.
struct MessagesUnreadAnchor: Equatable {
    let thread: Int
    /// This Mac's read point before the conversation opened.
    let readThrough: Int?
    /// The phone's unread count then.
    let count: Int
    var messageID: String?
    var resolved = false
}

/// What the right side shows.
enum MessagesTarget: Equatable, Hashable {
    case thread(Int)
    /// A new message to this number, before the phone has a conversation for it.
    case address(String)
    /// New message: picking who to write to.
    case compose
}

@MainActor
enum MessagesWindowController {
    private static var window: NSWindow?
    static let selection = MessagesSelection()

    /// Opens the window, on `phoneID`'s conversations and `threadID` when given.
    static func show(pairing: PairingCoordinator, phoneID: String? = nil, threadID: Int? = nil) {
        if let phoneID { selection.phoneID = phoneID }
        if let threadID { selection.target = .thread(threadID) }
        if window == nil {
            let root = MessagesLiveView(pairing: pairing, messages: pairing.textMessages, settings: pairing.observedSettings, selection: selection)
            let created = NSWindow(contentViewController: NSHostingController(rootView: root))
            created.title = L10n.text("sms.window", fallback: "Messages")
            created.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
            created.titlebarAppearsTransparent = true
            created.titleVisibility = .hidden
            created.isReleasedWhenClosed = false
            created.setContentSize(MessagesView.size)
            created.minSize = NSSize(width: 720, height: 460)
            created.setFrameAutosaveName("BridgeyMessagesWindow")
            created.center()
            window = created
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        // SwiftUI hands the search field the keyboard when the window becomes key; the list keeps it
        // instead, so Command-Delete and the other shortcuts work at once (Command-F goes to search).
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            if let window, window.firstResponder is NSText { window.makeFirstResponder(nil) }
        }
    }

    /// The Messages window's own key events (its shortcuts) and alerts.
    static func owns(_ candidate: NSWindow?) -> Bool { candidate != nil && candidate === window }
    static var current: NSWindow? { window }
}

// MARK: - Model

struct MessagesPhone: Identifiable, Equatable {
    let id: String
    let name: String
}

/// Why the window cannot show conversations, or that it can.
enum MessagesAvailability: Equatable {
    case ready
    case macOff
    case noPhone
    case phoneOff(String)
    case needsPermission(String)
    case loading(String)
}

/// A line the window shows for a moment after an action that reached the phone (or did not).
struct MessagesNoticeText: Equatable {
    let id: String
    let text: String
    let symbol: String
    let good: Bool
}

struct MessagesModel {
    var phones: [MessagesPhone] = []
    var phoneID: String?
    var phoneName = ""
    var availability: MessagesAvailability = .noPhone
    /// Every conversation the cache holds (for looking one up).
    var threads: [SmsThread] = []
    /// The list as shown: the filter applied, pinned then unread then the rest.
    var rows: [SmsThreadRow] = []
    /// Every conversation not deleted on this Mac, archived ones included, by thread ID.
    var states: [Int: SmsThreadRow] = [:]
    var filter: SmsListFilter = .all
    var unreadConversations = 0
    var archivedCount = 0
    var threadsMore = false
    var loadingThreads = false
    var target: MessagesTarget?
    /// Newest first, without the ones deleted on this Mac.
    var messages: [SmsMessage] = []
    var messagesMore = false
    var loadingMessages = false
    /// This Mac's sends to the open conversation that the phone has not listed yet.
    var outgoing: [SmsOutgoing] = []
    var sims: [SmsSim] = []
    var canSend = true
    var codesEnabled = false
    /// Decoded MMS images by part ID; failed ones by part ID.
    var images: [String: NSImage] = [:]
    var failedImages: Set<String> = []
    var contacts: [SmsContact] = []
    var searchingContacts = false
    var now = Date()
    /// The composer's text: a forward's, or (screenshots) text already typed. And the To field's.
    var draft = ""
    var typedRecipient = ""
    var query = ""
    var search = SmsSearchResults()
    var selected: Set<Int> = []
    var selecting = false
    var focusMessage: String?
    /// The unread divider sits above this message.
    var unreadFrom: String?
    var notice: MessagesNoticeText?
    var searchFocus = 0

    var thread: SmsThread? {
        if case let .thread(id)? = target { return threads.first { $0.threadId == id } }
        return nil
    }

    var openRow: SmsThreadRow? {
        if case let .thread(id)? = target { return states[id] }
        return nil
    }

    var dualSim: Bool { sims.count > 1 }

    /// Bulk mode: several chosen, or Select is on.
    var bulk: Bool { selected.count > 1 || (selecting && !selected.isEmpty) }

    func sim(_ subId: Int?) -> SmsSim? { subId.flatMap { id in sims.first { $0.subId == id } } }
}

struct MessagesActions {
    var selectPhone: (String) -> Void = { _ in }
    var select: (MessagesTarget?) -> Void = { _ in }
    /// A click on a conversation: plain opens it; Command toggles it in the selection; Shift extends it.
    var click: (_ thread: Int, _ command: Bool, _ shift: Bool) -> Void = { _, _, _ in }
    var setFilter: (SmsListFilter) -> Void = { _ in }
    var setQuery: (String) -> Void = { _ in }
    var setSelecting: (Bool) -> Void = { _ in }
    var clearSelection: () -> Void = {}
    var loadOlderThreads: () -> Void = {}
    var loadOlderMessages: () -> Void = {}
    /// Sends to the open conversation or number; false when it cannot go.
    var send: (_ body: String, _ subId: Int?) -> Bool = { _, _ in false }
    var retry: (String) -> Void = { _ in }
    var discard: (String) -> Void = { _ in }
    var requestImage: (String) -> Void = { _ in }
    var copyCode: (SmsMessage) -> Void = { _ in }
    var searchContacts: (String) -> Void = { _ in }
    var turnOn: () -> Void = {}
    // Managing conversations: each takes the conversations it applies to.
    var markRead: ([Int]) -> Void = { _ in }
    var markUnread: ([Int]) -> Void = { _ in }
    var pin: ([Int], Bool) -> Void = { _, _ in }
    var mute: ([Int], Bool) -> Void = { _, _ in }
    var archive: ([Int]) -> Void = { _ in }
    var unarchive: ([Int]) -> Void = { _ in }
    /// Asks first.
    var delete: ([Int]) -> Void = { _ in }
    var blockOnPhone: (Int) -> Void = { _ in }
    // One message.
    var copyText: (SmsMessage) -> Void = { _ in }
    var forward: (SmsMessage) -> Void = { _ in }
    var deleteMessage: (SmsMessage) -> Void = { _ in }
    var openHit: (SmsSearchHit) -> Void = { _ in }
    var dismissNotice: () -> Void = {}
}

// MARK: - Live

private struct MessagesLiveView: View {
    @ObservedObject var pairing: PairingCoordinator
    @ObservedObject var messages: TextMessages
    @ObservedObject var settings: BridgeySettings
    @ObservedObject var selection: MessagesSelection
    @AppStorage("settings.reduceMotion") private var reduceMotion = false
    @Environment(\.controlActiveState) private var activeState
    @State private var copiedMessage: String?
    @State private var keyMonitor: Any?
    @State private var search = SmsSearchResults()

    var body: some View {
        BrandRoot(reduceMotion: reduceMotion) {
            MessagesView(model: model, actions: actions, copiedMessage: copiedMessage)
        }
        .ignoresSafeArea()
        .onAppear {
            appeared()
            installKeys()
        }
        .onDisappear {
            messages.close()
            if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
            keyMonitor = nil
        }
        .onChange(of: selection.phoneID) { _ in appeared() }
        .onChange(of: selection.target) { target in open(target) }
        .onChange(of: selection.filter) { filter in if filter != .archived, let phoneID { messages.fillThreads(phoneID) } }
        .onChange(of: selection.query) { _ in refreshSearch() }
        .onChange(of: messages.revision) { _ in
            if !selection.query.isEmpty { refreshSearch() }
            resolveUnreadAnchor()
        }
        .onChange(of: messages.management) { _ in if !selection.query.isEmpty { refreshSearch() } }
        .onChange(of: newestIncoming) { _ in readWhileOpen() }
        .onChange(of: messages.notice) { notice in
            guard let notice else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 7) { messages.clearNotice(notice.id) }
        }
        .onChange(of: model.threads) { threads in
            // A new number gets its conversation once the phone lists the sent message.
            if case let .address(address)? = selection.target,
               let match = threads.first(where: { $0.participants.count == 1 && smsSameNumber($0.participants[0].address, address) }) {
                selection.target = .thread(match.threadId)
            }
        }
    }

    private var phones: [MessagesPhone] {
        pairing.textMessagePhones.map { MessagesPhone(id: $0.id, name: $0.name) }
    }

    private var phoneID: String? {
        let list = phones
        if let chosen = selection.phoneID, list.contains(where: { $0.id == chosen }) { return chosen }
        return list.first?.id
    }

    private func appeared() {
        guard let phoneID, pairing.textMessagesAvailable(for: phoneID) else { return }
        messages.refreshThreads(phoneID)
        messages.fillThreads(phoneID)
        open(selection.target)
    }

    private func open(_ target: MessagesTarget?) {
        guard let phoneID else { return }
        selection.focusMessage = selection.focusMessage.flatMap { id in
            // A search result keeps its message; anything else starts at the unread divider or the end.
            if case let .thread(thread)? = target, messages.visibleMessages(phoneID, thread: thread).contains(where: { $0.id == id }) { return id }
            return nil
        }
        if case let .thread(id)? = target {
            let unread = messages.isUnread(phoneID, thread: id)
            selection.unread = unread ? MessagesUnreadAnchor(thread: id, readThrough: messages.manage(phoneID).readThrough[String(id)],
                                                             count: messages.data(phoneID).cache.thread(id)?.unread ?? 0) : nil
            resolveUnreadAnchor()
            messages.open(phoneID, thread: id)
            // Opening a conversation reads it here, and on the phone through its notification.
            if unread { messages.markRead([id], phoneID: phoneID) }
        } else {
            selection.unread = nil
            messages.close()
        }
        if target != .compose { messages.clearContacts() }
    }

    /// The divider's message, fixed once the conversation's messages are here.
    private func resolveUnreadAnchor() {
        guard let phoneID, var anchor = selection.unread, !anchor.resolved else { return }
        let list = messages.visibleMessages(phoneID, thread: anchor.thread)
        guard !list.isEmpty else { return }
        anchor.messageID = smsFirstUnread(list, readThrough: anchor.readThrough, count: anchor.count)?.id
        anchor.resolved = true
        selection.unread = anchor
    }

    /// The newest incoming message of the open conversation.
    private var newestIncoming: String? {
        guard let phoneID, case let .thread(id)? = selection.target else { return nil }
        return messages.data(phoneID).cache.messages(in: id).first { $0.direction == .incoming }?.id
    }

    /// A message arriving in the conversation on screen is read (quietly) while the window is in front.
    private func readWhileOpen() {
        guard let phoneID, case let .thread(id)? = selection.target, activeState == .key, NSApp.isActive,
              messages.isUnread(phoneID, thread: id) else { return }
        messages.markRead([id], phoneID: phoneID, report: false)
    }

    private func refreshSearch() {
        guard let phoneID, !selection.query.trimmingCharacters(in: .whitespaces).isEmpty else {
            search = SmsSearchResults()
            return
        }
        search = messages.search(selection.query, phoneID: phoneID)
    }

    private var model: MessagesModel {
        var model = MessagesModel()
        model.phones = phones
        model.codesEnabled = pairing.codesEnabledForMessages
        guard pairing.textMessagesSettingOn else {
            model.availability = .macOff
            return model
        }
        guard let phoneID else {
            // A connected phone that has Text messages off says so; otherwise there is no phone.
            if let off = pairing.connectedPhones.first { model.availability = .phoneOff(off.name) } else { model.availability = .noPhone }
            return model
        }
        let name = phones.first { $0.id == phoneID }?.name ?? ""
        let data = messages.data(phoneID)
        model.phoneID = phoneID
        model.phoneName = name
        model.threads = data.cache.threads
        model.filter = selection.filter
        // The conversation opened while unread keeps its place until another one opens.
        let holding = selection.unread.flatMap { anchor in selection.target == .thread(anchor.thread) ? anchor.thread : nil }
        model.rows = messages.rows(phoneID, filter: selection.filter, holding: holding)
        let all = selection.filter == .all ? model.rows : messages.rows(phoneID, filter: .all)
        let archived = selection.filter == .archived ? model.rows : messages.rows(phoneID, filter: .archived)
        model.states = Dictionary((all + archived).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        model.unreadConversations = all.filter { $0.unread > 0 }.count
        model.archivedCount = archived.count
        model.threadsMore = data.cache.threadsMore
        model.loadingThreads = data.loadingThreads
        model.sims = data.status?.sims ?? []
        model.canSend = data.status?.send ?? false
        if let status = data.status {
            model.availability = status.read ? .ready : .needsPermission(name)
        } else {
            model.availability = data.cache.threads.isEmpty ? .loading(name) : .ready
        }
        model.target = selection.target
        switch selection.target {
        case let .thread(id)?:
            model.messages = messages.visibleMessages(phoneID, thread: id)
            model.messagesMore = data.cache.hasOlder(in: id)
            model.loadingMessages = data.loadingMessages.contains(id)
            model.outgoing = messages.outgoing.filter { $0.phoneID == phoneID && $0.target == .thread(id) }
            if let anchor = selection.unread, anchor.thread == id {
                model.unreadFrom = anchor.resolved ? anchor.messageID : smsFirstUnread(model.messages, readThrough: anchor.readThrough, count: anchor.count)?.id
            }
        case let .address(address)?:
            model.outgoing = messages.outgoing.filter {
                if case let .address(sent) = $0.target { return $0.phoneID == phoneID && smsSameNumber(sent, address) }
                return false
            }
        default:
            break
        }
        model.draft = selection.forwardText ?? ""
        for message in model.messages {
            for part in message.parts {
                if let image = messages.image(phoneID, partID: part.partId) { model.images[part.partId] = image }
                if messages.imageFailed(phoneID, partID: part.partId) { model.failedImages.insert(part.partId) }
            }
        }
        model.contacts = messages.contactResults
        model.searchingContacts = messages.contactsSearching
        model.query = selection.query
        model.search = search
        model.selected = selection.selected
        model.selecting = selection.selecting
        model.focusMessage = selection.focusMessage
        model.searchFocus = selection.searchFocus
        if let notice = messages.notice, notice.phoneID == phoneID { model.notice = messagesNoticeText(notice, phone: name) }
        model.now = Date()
        return model
    }

    /// The conversations an action from the keyboard or the header applies to: the chosen ones, else the open one.
    private var targets: [Int] {
        if !selection.selected.isEmpty { return Array(selection.selected) }
        if case let .thread(id)? = selection.target { return [id] }
        return []
    }

    private var actions: MessagesActions {
        var actions = MessagesActions()
        actions.selectPhone = { id in
            selection.phoneID = id
            selection.target = nil
            selection.selected = []
            selection.query = ""
        }
        actions.select = { target in
            if target != selection.target { selection.forwardText = target == .compose || isFromCompose(target) ? selection.forwardText : nil }
            selection.selected = []
            selection.target = target
        }
        actions.click = { thread, command, shift in click(thread, command: command, shift: shift) }
        actions.setFilter = { filter in
            selection.filter = filter
            selection.selected = []
        }
        actions.setQuery = { selection.query = $0 }
        actions.setSelecting = { on in
            selection.selecting = on
            if !on { selection.selected = [] }
        }
        actions.clearSelection = {
            selection.selected = []
            selection.selecting = false
        }
        actions.loadOlderThreads = { if let phoneID { messages.loadOlderThreads(phoneID) } }
        actions.loadOlderMessages = {
            if let phoneID, case let .thread(id)? = selection.target { messages.loadOlderMessages(phoneID, thread: id) }
        }
        actions.send = { body, subId in
            guard let phoneID else { return false }
            let sent: Bool
            switch selection.target {
            case let .thread(id)?:
                sent = messages.send(body, to: .thread(id), subId: subId, phoneID: phoneID) != nil
                // Answering is reading.
                if sent, messages.isUnread(phoneID, thread: id) { messages.markRead([id], phoneID: phoneID, report: false) }
            case let .address(address)?: sent = messages.send(body, to: .address(address), subId: subId, phoneID: phoneID) != nil
            default: sent = false
            }
            if sent { selection.forwardText = nil }
            return sent
        }
        actions.retry = { messages.retry($0) }
        actions.discard = { messages.discard($0) }
        actions.requestImage = { part in if let phoneID { messages.requestImage(phoneID, partID: part) } }
        actions.copyCode = { message in
            let sender = model.thread?.title ?? message.address
            Task { @MainActor in
                if await pairing.copyCodeFromMessage(message.body, sender: sender) {
                    copiedMessage = message.id
                    DispatchQueue.main.asyncAfter(deadline: .now() + 3) { if copiedMessage == message.id { copiedMessage = nil } }
                }
            }
        }
        actions.searchContacts = { query in if let phoneID { messages.searchContacts(query, phoneID: phoneID) } }
        actions.turnOn = { pairing.setTextMessagesEnabled(true) }
        actions.markRead = { ids in if let phoneID { messages.markRead(ids, phoneID: phoneID) } }
        actions.markUnread = { ids in if let phoneID { messages.markUnread(ids, phoneID: phoneID) } }
        actions.pin = { ids, on in if let phoneID { messages.setPinned(ids, on, phoneID: phoneID) } }
        actions.mute = { ids, on in if let phoneID { messages.setMuted(ids, on, phoneID: phoneID) } }
        actions.archive = { ids in
            guard let phoneID else { return }
            messages.archive(ids, phoneID: phoneID)
            finishBulk(ids)
        }
        actions.unarchive = { ids in
            guard let phoneID else { return }
            messages.unarchive(ids, phoneID: phoneID)
            finishBulk(ids)
        }
        actions.delete = { ids in confirmDelete(ids) }
        actions.blockOnPhone = { id in
            guard let phoneID, let thread = messages.data(phoneID).cache.thread(id), thread.participants.count == 1 else { return }
            messages.blockOnPhone(thread.participants[0].address, phoneID: phoneID)
        }
        actions.copyText = { message in
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(message.body, forType: .string)
        }
        actions.forward = { message in
            selection.forwardText = message.body
            selection.selected = []
            selection.target = .compose
        }
        actions.deleteMessage = { message in confirmDeleteMessage(message) }
        actions.openHit = { hit in
            if MessagesWindowController.current?.firstResponder is NSText { MessagesWindowController.current?.makeFirstResponder(nil) }
            selection.focusMessage = hit.message.id
            selection.selected = []
            if selection.target == .thread(hit.threadId) {
                // Already open: only the scroll moves.
                selection.focusMessage = nil
                DispatchQueue.main.async { selection.focusMessage = hit.message.id }
            } else {
                selection.target = .thread(hit.threadId)
            }
        }
        actions.dismissNotice = { if let id = messages.notice?.id { messages.clearNotice(id) } }
        return actions
    }

    private func isFromCompose(_ target: MessagesTarget?) -> Bool {
        guard selection.target == .compose, let target else { return false }
        if case .compose = target { return false }
        return true
    }

    private func click(_ thread: Int, command: Bool, shift: Bool) {
        // A click in the list takes the keyboard from a text field, as in Mail, so the list's shortcuts work.
        if MessagesWindowController.current?.firstResponder is NSText { MessagesWindowController.current?.makeFirstResponder(nil) }
        if shift, let start = selection.rangeStart ?? openThread {
            let order = (selection.query.isEmpty ? model.rows : model.search.threads).map(\.id)
            if let from = order.firstIndex(of: start), let to = order.firstIndex(of: thread) {
                selection.selected = Set(order[min(from, to)...max(from, to)])
                return
            }
        }
        if command || selection.selecting {
            var chosen = selection.selected
            if chosen.isEmpty, !selection.selecting, let open = openThread { chosen.insert(open) }
            if chosen.contains(thread) { chosen.remove(thread) } else { chosen.insert(thread) }
            selection.selected = chosen
            selection.rangeStart = thread
            return
        }
        selection.selected = []
        selection.rangeStart = thread
        if selection.target != .thread(thread) { selection.forwardText = nil }
        selection.target = .thread(thread)
    }

    private var openThread: Int? {
        if case let .thread(id)? = selection.target { return id }
        return nil
    }

    private func finishBulk(_ ids: [Int]) {
        selection.selected.subtract(ids)
        if selection.selected.isEmpty { selection.selecting = false }
    }

    private func confirmDelete(_ ids: [Int]) {
        guard let phoneID, !ids.isEmpty else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = ids.count == 1
            ? L10n.text("sms.delete.one", fallback: "Delete this conversation?")
            : String(format: L10n.text("sms.delete.many", fallback: "Delete %d conversations?"), ids.count)
        alert.informativeText = ids.count == 1
            ? L10n.text("sms.delete.one.detail", fallback: "Removes it from this Mac. It stays on your phone.")
            : L10n.text("sms.delete.many.detail", fallback: "Removes them from this Mac. They stay on your phone.")
        alert.addButton(withTitle: L10n.text("sms.action.delete", fallback: "Delete")).hasDestructiveAction = true
        alert.addButton(withTitle: L10n.text("action.cancel", fallback: "Cancel"))
        let finish: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .alertFirstButtonReturn else { return }
            messages.deleteThreads(ids, phoneID: phoneID)
            if case let .thread(open)? = selection.target, ids.contains(open) { selection.target = nil }
            finishBulk(ids)
        }
        if let window = MessagesWindowController.current { alert.beginSheetModal(for: window, completionHandler: finish) } else { finish(alert.runModal()) }
    }

    private func confirmDeleteMessage(_ message: SmsMessage) {
        guard let phoneID else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = L10n.text("sms.delete.message", fallback: "Delete this message?")
        alert.informativeText = L10n.text("sms.delete.one.detail", fallback: "Removes it from this Mac. It stays on your phone.")
        alert.addButton(withTitle: L10n.text("sms.action.delete", fallback: "Delete")).hasDestructiveAction = true
        alert.addButton(withTitle: L10n.text("action.cancel", fallback: "Cancel"))
        let finish: (NSApplication.ModalResponse) -> Void = { response in
            if response == .alertFirstButtonReturn { messages.deleteMessage(message.id, thread: message.threadId, phoneID: phoneID) }
        }
        if let window = MessagesWindowController.current { alert.beginSheetModal(for: window, completionHandler: finish) } else { finish(alert.runModal()) }
    }

    // MARK: Keyboard

    /// Command-Delete, Shift-Command-U, Command-F and Escape, the usual Mac way. Command-Delete is left
    /// to a text field that is being edited.
    private func installKeys() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let handled = MainActor.assumeIsolated { handleKey(event) }
            return handled ? nil : event
        }
    }

    private func handleKey(_ event: NSEvent) -> Bool {
        guard MessagesWindowController.owns(event.window), model.availability == .ready else { return false }
        let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
        let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
        let editing = event.window?.firstResponder is NSText
        if flags == .command && key == "f" {
            selection.searchFocus += 1
            return true
        }
        if flags == [.command, .shift] && key == "u" {
            let ids = targets
            guard let phoneID, !ids.isEmpty else { return false }
            if ids.contains(where: { messages.isUnread(phoneID, thread: $0) }) { actions.markRead(ids) } else { actions.markUnread(ids) }
            return true
        }
        if flags == .command && event.keyCode == 51 && !editing {
            let ids = targets
            guard !ids.isEmpty else { return false }
            confirmDelete(ids)
            return true
        }
        if flags.isEmpty && event.keyCode == 53 && (!selection.selected.isEmpty || selection.selecting) {
            actions.clearSelection()
            return true
        }
        return false
    }
}

/// The notice's words: what reached the phone, and what stays as it was there.
func messagesNoticeText(_ notice: SmsNotice, phone: String) -> MessagesNoticeText {
    switch notice.kind {
    case let .markRead(summary):
        let many = summary.total > 1
        if summary.disabled {
            return MessagesNoticeText(id: notice.id, text: String(format: L10n.text("sms.notice.disabled", fallback: "Read on this Mac. Text messages is off for this Mac on %@."), phone), symbol: "iphone.slash", good: false)
        }
        if summary.noAnswer {
            let text = many
                ? String(format: L10n.text("sms.notice.noAnswer.many", fallback: "Read on this Mac. %@ didn\u{2019}t answer, so they may still show as unread there."), phone)
                : String(format: L10n.text("sms.notice.noAnswer", fallback: "Read on this Mac. %@ didn\u{2019}t answer, so it may still show as unread there."), phone)
            return MessagesNoticeText(id: notice.id, text: text, symbol: "iphone.slash", good: false)
        }
        if summary.marked == summary.total {
            return MessagesNoticeText(id: notice.id, text: String(format: L10n.text("sms.notice.marked", fallback: "Also marked read on %@."), phone), symbol: "checkmark.circle", good: true)
        }
        if many && summary.marked > 0 {
            let text = String(format: L10n.text("sms.notice.markedSome", fallback: "Read on this Mac. Also marked read on %1$@: %2$d of %3$d. The rest stay unread there, with no notification to clear."),
                              phone, summary.marked, summary.total)
            return MessagesNoticeText(id: notice.id, text: text, symbol: "checkmark.circle", good: true)
        }
        let text: String
        if many {
            text = String(format: L10n.text("sms.notice.stay.many", fallback: "Read on this Mac. They stay unread on %@: only a conversation with a notification there can be marked."), phone)
        } else if summary.noAction > 0 {
            text = String(format: L10n.text("sms.notice.noAction", fallback: "Read on this Mac. It stays unread on %@: the messaging app offers no Mark as read."), phone)
        } else if summary.failed > 0 {
            text = String(format: L10n.text("sms.notice.failed", fallback: "Read on this Mac. %@ couldn\u{2019}t mark it read."), phone)
        } else {
            text = String(format: L10n.text("sms.notice.notShown", fallback: "Read on this Mac. It stays unread on %@: its notification was already gone."), phone)
        }
        return MessagesNoticeText(id: notice.id, text: text, symbol: "info.circle", good: false)
    case let .blocked(outcome, address):
        let number = address ?? ""
        switch outcome {
        case .opened?:
            let text = number.isEmpty
                ? String(format: L10n.text("sms.notice.blockOpened.plain", fallback: "Blocked numbers is open on %@."), phone)
                : String(format: L10n.text("sms.notice.blockOpened", fallback: "Blocked numbers is open on %1$@. Add %2$@ there."), phone, number)
            return MessagesNoticeText(id: notice.id, text: text, symbol: "hand.raised", good: true)
        case .notified?:
            let text = number.isEmpty
                ? String(format: L10n.text("sms.notice.blockNotified.plain", fallback: "Tap Bridgey\u{2019}s notification on %@ to open Blocked numbers."), phone)
                : String(format: L10n.text("sms.notice.blockNotified", fallback: "Tap Bridgey\u{2019}s notification on %1$@ to open Blocked numbers, then add %2$@."), phone, number)
            return MessagesNoticeText(id: notice.id, text: text, symbol: "bell.badge", good: true)
        case .unavailable?:
            return MessagesNoticeText(id: notice.id, text: String(format: L10n.text("sms.notice.blockUnavailable", fallback: "%@ can\u{2019}t open Blocked numbers."), phone), symbol: "hand.raised.slash", good: false)
        case nil:
            return MessagesNoticeText(id: notice.id, text: String(format: L10n.text("sms.notice.blockNoAnswer", fallback: "%@ didn\u{2019}t answer. Update Bridgey there and try again."), phone), symbol: "iphone.slash", good: false)
        }
    }
}

// MARK: - View

struct MessagesView: View {
    let model: MessagesModel
    let actions: MessagesActions
    var copiedMessage: String?
    @Environment(\.brand) private var c

    static let size = CGSize(width: 960, height: 640)
    static let sidebarWidth: CGFloat = 320

    var body: some View {
        Group {
            switch model.availability {
            case .ready:
                HStack(spacing: 0) {
                    MessagesSidebar(model: model, actions: actions)
                        .frame(width: Self.sidebarWidth)
                    Rectangle().fill(c.olv).frame(width: 1)
                    conversation
                        .frame(maxWidth: .infinity)
                        .overlay(alignment: .bottom) { noticeView }
                }
            default:
                VStack(spacing: 0) {
                    Color.clear.frame(height: 28)
                    unavailable
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(c.bg)
    }

    @ViewBuilder private var conversation: some View {
        if model.bulk {
            BulkPane(model: model, actions: actions)
        } else {
            switch model.target {
            case let .thread(id)?:
                if let thread = model.thread {
                    ConversationPane(model: model, actions: actions, thread: thread, address: nil, copiedMessage: copiedMessage)
                        .id(id)
                } else {
                    PhoneFilesMessage(symbol: "bubble.left.and.bubble.right", title: L10n.text("sms.loading", fallback: "Loading\u{2026}"), detail: nil)
                }
            case let .address(address)?:
                ConversationPane(model: model, actions: actions, thread: nil, address: address, copiedMessage: copiedMessage)
                    .id(address)
            case .compose?:
                NewMessagePane(model: model, actions: actions, typed: model.typedRecipient)
            case nil:
                PhoneFilesMessage(symbol: "bubble.left.and.bubble.right",
                                  title: L10n.text("sms.pick", fallback: "Pick a conversation"),
                                  detail: L10n.text("sms.pick.detail", fallback: "Or start a new message to a contact or a number."),
                                  button: L10n.text("sms.new", fallback: "New message")) { actions.select(.compose) }
            }
        }
    }

    @ViewBuilder private var noticeView: some View {
        if let notice = model.notice {
            Button(action: actions.dismissNotice) {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: notice.symbol).font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(notice.good ? c.tgi : c.tbi)
                    Text(notice.text).font(BrandFont.body(12)).foregroundStyle(c.on)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .frame(maxWidth: 440, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(c.s1))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(c.ol, lineWidth: 1))
                .shadow(color: .black.opacity(c.isDark ? 0.35 : 0.08), radius: 10, y: 3)
            }
            .buttonStyle(.plain)
            .padding(.bottom, 84)
            .transition(.opacity)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isStaticText)
        }
    }

    @ViewBuilder private var unavailable: some View {
        switch model.availability {
        case .macOff:
            PhoneFilesMessage(symbol: "message",
                              title: L10n.text("sms.off.title", fallback: "Text messages is off on this Mac"),
                              detail: L10n.text("sms.off.detail", fallback: "Turn it on to read and answer your phone\u{2019}s texts here. Messages travel only between your phone and this Mac, encrypted."),
                              button: L10n.text("sms.off.button", fallback: "Turn on"), action: actions.turnOn)
        case .noPhone:
            PhoneFilesMessage(symbol: "iphone.slash",
                              title: L10n.text("sms.noPhone.title", fallback: "Connect your phone"),
                              detail: L10n.text("sms.noPhone.detail", fallback: "Your conversations show here while your phone is connected."))
        case let .phoneOff(name):
            PhoneFilesMessage(symbol: "message.badge",
                              title: String(format: L10n.text("sms.phoneOff.title", fallback: "Turn on Text messages on %@"), name),
                              detail: L10n.text("sms.phoneOff.detail", fallback: "On the phone, open Bridgey, then Settings, then Text messages."))
        case let .needsPermission(name):
            PhoneFilesMessage(symbol: "lock.shield",
                              title: String(format: L10n.text("sms.permission.title", fallback: "Allow SMS on %@"), name),
                              detail: L10n.text("sms.permission.detail", fallback: "Open Bridgey on the phone and allow SMS on its Permissions page. Bridgey never becomes your default SMS app."))
        case let .loading(name):
            VStack(spacing: 12) {
                ProgressView().controlSize(.small)
                Text(String(format: L10n.text("sms.loadingFrom", fallback: "Loading conversations from %@\u{2026}"), name))
                    .font(BrandFont.body(13)).foregroundStyle(c.on2)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .ready:
            EmptyView()
        }
    }
}

// MARK: - Menus

/// The same actions in the right-click menu, the header's More menu and the bulk pane.
private struct ConversationMenu {
    let model: MessagesModel
    let actions: MessagesActions
    /// The conversations it applies to.
    let ids: [Int]

    private var rows: [SmsThreadRow] { ids.compactMap { model.states[$0] } }
    var anyUnread: Bool { rows.contains { $0.unread > 0 } }
    var allPinned: Bool { !rows.isEmpty && rows.allSatisfy(\.pinned) }
    var allMuted: Bool { !rows.isEmpty && rows.allSatisfy(\.muted) }
    var allArchived: Bool { !rows.isEmpty && rows.allSatisfy(\.archived) }

    /// A single conversation with one person whose address is a phone number.
    var blockable: Int? {
        guard ids.count == 1, let row = rows.first, row.thread.participants.count == 1,
              normalizedSmsAddress(row.thread.participants[0].address) != nil else { return nil }
        return row.id
    }

    @ViewBuilder var items: some View {
        if anyUnread {
            Button(L10n.text("sms.action.read", fallback: "Mark as read")) { actions.markRead(ids) }
                .keyboardShortcut("u", modifiers: [.command, .shift])
        } else {
            Button(L10n.text("sms.action.unread", fallback: "Mark as unread")) { actions.markUnread(ids) }
                .keyboardShortcut("u", modifiers: [.command, .shift])
        }
        Button(allPinned ? L10n.text("sms.action.unpin", fallback: "Unpin") : L10n.text("sms.action.pin", fallback: "Pin")) { actions.pin(ids, !allPinned) }
        Button(allMuted ? L10n.text("sms.action.unmute", fallback: "Unmute") : L10n.text("sms.action.mute", fallback: "Mute")) { actions.mute(ids, !allMuted) }
        if allArchived {
            Button(L10n.text("sms.action.unarchive", fallback: "Unarchive")) { actions.unarchive(ids) }
        } else {
            Button(L10n.text("sms.action.archive", fallback: "Archive")) { actions.archive(ids) }
        }
        if let blockable {
            Divider()
            Button(L10n.text("sms.action.block", fallback: "Block on phone\u{2026}")) { actions.blockOnPhone(blockable) }
        }
        Divider()
        Button(L10n.text("sms.action.deleteMenu", fallback: "Delete\u{2026}"), role: .destructive) { actions.delete(ids) }
            .keyboardShortcut(.delete, modifiers: [.command])
    }
}

// MARK: - Sidebar

private struct MessagesSidebar: View {
    let model: MessagesModel
    let actions: MessagesActions
    @Environment(\.brand) private var c
    @Environment(\.snapshotRendering) private var snapshot
    @FocusState private var searchFocused: Bool

    private var searching: Bool { !model.query.trimmingCharacters(in: .whitespaces).isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.top, 36)
                .padding(.horizontal, 16)
            if model.phones.count > 1 && model.filter != .archived { phonePicker }
            searchField
            if !searching { filterBar }
            list
        }
        .onChange(of: model.searchFocus) { _ in searchFocused = true }
    }

    @ViewBuilder private var header: some View {
        HStack(spacing: 8) {
            if model.filter == .archived {
                Button { actions.setFilter(.all) } label: {
                    Image(systemName: "chevron.left").font(.system(size: 13, weight: .semibold)).foregroundStyle(c.on)
                        .frame(width: 28, height: 28)
                        .background(Circle().fill(c.s2))
                }
                .buttonStyle(PressScaleStyle())
                .help(L10n.text("sms.back", fallback: "Back to all conversations"))
                .accessibilityLabel(L10n.text("sms.back", fallback: "Back to all conversations"))
                Text(L10n.text("sms.archived", fallback: "Archived")).font(BrandFont.heading(20)).foregroundStyle(c.on).lineLimit(1)
            } else {
                Text(L10n.text("sms.window", fallback: "Messages")).font(BrandFont.heading(20)).foregroundStyle(c.on).lineLimit(1)
            }
            Spacer(minLength: 4)
            Button { actions.setSelecting(!model.selecting) } label: {
                Text(model.selecting ? L10n.text("sms.select.done", fallback: "Done") : L10n.text("sms.select", fallback: "Select"))
                    .font(BrandFont.body(12, .semibold))
                    .foregroundStyle(model.selecting ? c.tbi : c.on)
                    .padding(.horizontal, 10)
                    .frame(height: 28)
                    .background(Capsule().fill(model.selecting ? c.tb : c.s2))
            }
            .buttonStyle(PressScaleStyle())
            .help(L10n.text("sms.select.help", fallback: "Choose several conversations, or \u{2318}-click them."))
            if model.filter != .archived {
                Button { actions.select(.compose) } label: {
                    Image(systemName: "square.and.pencil").font(.system(size: 14, weight: .medium)).foregroundStyle(c.on)
                        .frame(width: 30, height: 30)
                        .background(Circle().fill(model.target == .compose ? c.tb : c.s2))
                }
                .buttonStyle(PressScaleStyle())
                .help(L10n.text("sms.new", fallback: "New message"))
                .accessibilityLabel(L10n.text("sms.new", fallback: "New message"))
            }
        }
    }

    private var phonePicker: some View {
        Button {
            DropMenu.show(model.phones.map { phone in
                PopUpMenuItem(title: phone.name, checked: phone.id == model.phoneID) { actions.selectPhone(phone.id) }
            })
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "iphone").font(.system(size: 11))
                Text(model.phoneName).font(BrandFont.body(12, .medium)).lineLimit(1)
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold))
            }
            .foregroundStyle(c.on)
            .padding(.horizontal, 10)
            .frame(height: 26)
            .background(Capsule().fill(c.s2))
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 16)
        .padding(.top, 8)
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(c.on2)
            if snapshot {
                Text(model.query.isEmpty ? L10n.text("sms.search", fallback: "Search messages") : model.query)
                    .foregroundStyle(model.query.isEmpty ? c.on2 : c.on)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                TextField(L10n.text("sms.search", fallback: "Search messages"), text: Binding(get: { model.query }, set: actions.setQuery))
                    .textFieldStyle(.plain)
                    .focused($searchFocused)
                    .onExitCommand { actions.setQuery("") }
            }
            if !model.query.isEmpty {
                Button { actions.setQuery("") } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(c.on2)
                }
                .buttonStyle(.plain)
                .help(L10n.text("sms.search.clear", fallback: "Clear the search"))
                .accessibilityLabel(L10n.text("sms.search.clear", fallback: "Clear the search"))
            }
        }
        .font(BrandFont.body(13))
        .padding(.horizontal, 12)
        .frame(height: 30)
        .background(Capsule().fill(c.s2))
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 8)
        .help(L10n.text("sms.search.help", fallback: "Search every message kept on this Mac (\u{2318}F)"))
    }

    @ViewBuilder private var filterBar: some View {
        if model.filter != .archived {
            HStack(spacing: 6) {
                chip(L10n.text("sms.filter.all", fallback: "All"), on: model.filter == .all) { actions.setFilter(.all) }
                chip(L10n.text("sms.filter.unread", fallback: "Unread"), count: model.unreadConversations, on: model.filter == .unread) { actions.setFilter(.unread) }
                Spacer(minLength: 4)
                Button { actions.setFilter(.archived) } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "archivebox").font(.system(size: 12, weight: .medium))
                        if model.archivedCount > 0 { Text("\(model.archivedCount)").font(BrandFont.body(11, .semibold)) }
                    }
                    .foregroundStyle(c.on2)
                    .padding(.horizontal, 10)
                    .frame(height: 26)
                    .background(Capsule().fill(c.s2))
                }
                .buttonStyle(PressScaleStyle())
                .help(L10n.text("sms.archived.help", fallback: "Archived conversations"))
                .accessibilityLabel(L10n.text("sms.archived", fallback: "Archived"))
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 8)
        }
    }

    private func chip(_ title: String, count: Int = 0, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Text(title).font(BrandFont.body(12, .semibold))
                if count > 0 {
                    Text("\(count)").font(BrandFont.body(11, .semibold))
                        .foregroundStyle(on ? c.onpri : c.tbi)
                        .padding(.horizontal, 5)
                        .frame(minWidth: 16, minHeight: 16)
                        .background(Capsule().fill(on ? c.pri : c.tb))
                }
            }
            .foregroundStyle(on ? c.tbi : c.on2)
            .padding(.horizontal, 12)
            .frame(height: 26)
            .background(Capsule().fill(on ? c.tb : Color.clear))
            .overlay(Capsule().strokeBorder(on ? Color.clear : c.ol, lineWidth: 1))
            .contentShape(Capsule())
        }
        .buttonStyle(PressScaleStyle())
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    // MARK: List

    @ViewBuilder private var list: some View {
        if searching {
            searchResults
        } else if model.rows.isEmpty {
            Text(emptyText)
                .font(BrandFont.body(13)).foregroundStyle(c.on2)
                .multilineTextAlignment(.center)
                .padding(24)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if snapshot {
            VStack(spacing: 2) {
                ForEach(model.rows) { row in rowView(row) }
            }
            .padding(.horizontal, 8)
            .frame(maxHeight: .infinity, alignment: .top)
            .clipped()
        } else {
            List {
                ForEach(model.rows) { row in
                    rowView(row)
                        .listRowInsets(EdgeInsets(top: 1, leading: 8, bottom: 1, trailing: 8))
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                        .swipeActions(edge: .leading, allowsFullSwipe: true) {
                            if row.unread > 0 {
                                Button { actions.markRead([row.id]) } label: { Label(L10n.text("sms.action.read", fallback: "Mark as read"), systemImage: "envelope.open") }
                                    .tint(.blue)
                            } else {
                                Button { actions.markUnread([row.id]) } label: { Label(L10n.text("sms.action.unread", fallback: "Mark as unread"), systemImage: "envelope.badge") }
                                    .tint(.blue)
                            }
                            Button { actions.pin([row.id], !row.pinned) } label: {
                                Label(row.pinned ? L10n.text("sms.action.unpin", fallback: "Unpin") : L10n.text("sms.action.pin", fallback: "Pin"),
                                      systemImage: row.pinned ? "pin.slash" : "pin")
                            }
                            .tint(.orange)
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button(role: .destructive) { actions.delete([row.id]) } label: { Label(L10n.text("sms.action.delete", fallback: "Delete"), systemImage: "trash") }
                            if row.archived {
                                Button { actions.unarchive([row.id]) } label: { Label(L10n.text("sms.action.unarchive", fallback: "Unarchive"), systemImage: "tray.and.arrow.up") }
                                    .tint(.indigo)
                            } else {
                                Button { actions.archive([row.id]) } label: { Label(L10n.text("sms.action.archive", fallback: "Archive"), systemImage: "archivebox") }
                                    .tint(.indigo)
                            }
                            Button { actions.mute([row.id], !row.muted) } label: {
                                Label(row.muted ? L10n.text("sms.action.unmute", fallback: "Unmute") : L10n.text("sms.action.mute", fallback: "Mute"),
                                      systemImage: row.muted ? "bell" : "bell.slash")
                            }
                            .tint(.gray)
                        }
                }
                if model.threadsMore && model.filter == .all {
                    HStack { Spacer(); ProgressView().controlSize(.small); Spacer() }
                        .frame(height: 36)
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                        .onAppear(perform: actions.loadOlderThreads)
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .environment(\.defaultMinListRowHeight, 1)
        }
    }

    private var emptyText: String {
        switch model.filter {
        case .all: model.loadingThreads ? L10n.text("sms.loading", fallback: "Loading\u{2026}") : L10n.text("sms.noThreads", fallback: "No conversations yet.")
        case .unread: L10n.text("sms.unread.empty", fallback: "No unread conversations.")
        case .archived: L10n.text("sms.archived.empty", fallback: "No archived conversations. Archive one to hide it until a new message arrives.")
        }
    }

    private func rowView(_ row: SmsThreadRow) -> some View {
        let ids = model.selected.contains(row.id) && model.selected.count > 1 ? Array(model.selected) : [row.id]
        return ThreadRow(row: row, selected: model.target == .thread(row.id) && !model.bulk,
                         chosen: model.selected.contains(row.id), selecting: model.selecting,
                         sim: model.dualSim ? model.sim(row.thread.subId) : nil, now: model.now)
            .onTapGesture {
                let flags = NSEvent.modifierFlags
                actions.click(row.id, flags.contains(.command), flags.contains(.shift))
            }
            .contextMenu { ConversationMenu(model: model, actions: actions, ids: ids).items }
    }

    // MARK: Search

    @ViewBuilder private var searchResults: some View {
        if model.search.isEmpty {
            Text(String(format: L10n.text("sms.search.none", fallback: "Nothing on this Mac matches \u{201C}%@\u{201D}."), model.query))
                .font(BrandFont.body(13)).foregroundStyle(c.on2)
                .multilineTextAlignment(.center)
                .padding(24)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        } else {
            let content = VStack(alignment: .leading, spacing: 2) {
                if !model.search.threads.isEmpty {
                    sectionTitle(L10n.text("sms.search.conversations", fallback: "Conversations"))
                    ForEach(model.search.threads) { row in rowView(row) }
                }
                if !model.search.messages.isEmpty {
                    sectionTitle(L10n.text("sms.search.messages", fallback: "Messages"))
                    ForEach(model.search.messages) { hit in
                        SearchHitRow(hit: hit, thread: model.states[hit.threadId]?.thread, now: model.now,
                                     selected: model.focusMessage == hit.message.id)
                            .onTapGesture { actions.openHit(hit) }
                    }
                }
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 8)
            if snapshot {
                content.frame(maxHeight: .infinity, alignment: .top).clipped()
            } else {
                ScrollView { content }
            }
        }
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title.uppercased())
            .font(BrandFont.body(11, .semibold)).foregroundStyle(c.on2)
            .tracking(0.6)
            .padding(.horizontal, 10)
            .padding(.top, 10)
            .padding(.bottom, 4)
    }
}

private struct ThreadRow: View {
    let row: SmsThreadRow
    let selected: Bool
    /// In the bulk selection.
    let chosen: Bool
    let selecting: Bool
    let sim: SmsSim?
    let now: Date
    @Environment(\.brand) private var c

    private var thread: SmsThread { row.thread }
    private var unread: Bool { row.unread > 0 }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            if selecting {
                Image(systemName: chosen ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 17, weight: .regular))
                    .foregroundStyle(chosen ? c.pri : c.on2)
                    .frame(height: 38)
            }
            SmsAvatar(thread: thread, size: 38)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    Text(thread.title).font(BrandFont.body(13, unread ? .semibold : .medium)).foregroundStyle(c.on).lineLimit(1)
                    if row.muted {
                        Image(systemName: "bell.slash.fill").font(.system(size: 10)).foregroundStyle(c.on2)
                            .accessibilityLabel(L10n.text("sms.muted", fallback: "Muted"))
                    }
                    Spacer(minLength: 4)
                    if row.pinned {
                        Image(systemName: "pin.fill").font(.system(size: 10)).foregroundStyle(c.on2).rotationEffect(.degrees(45))
                            .accessibilityLabel(L10n.text("sms.pinned", fallback: "Pinned"))
                    }
                    Text(smsListTime(thread.lastAt, now: now)).font(BrandFont.body(11, unread ? .semibold : .regular))
                        .foregroundStyle(unread ? c.pri : c.on2).lineLimit(1).fixedSize()
                }
                HStack(spacing: 6) {
                    Text(thread.snippet).font(BrandFont.body(12)).foregroundStyle(unread ? c.on : c.on2).lineLimit(1)
                    Spacer(minLength: 4)
                    if let sim { SimBadge(sim: sim) }
                    if unread {
                        Text(row.unread > 99 ? "99+" : "\(row.unread)")
                            .font(BrandFont.body(10, .semibold))
                            .foregroundStyle(c.onpri)
                            .padding(.horizontal, 5)
                            .frame(minWidth: 16, minHeight: 16)
                            .background(Capsule().fill(row.muted ? c.on2 : c.pri))
                            .accessibilityLabel(String(format: L10n.text("sms.unreadCount", fallback: "%d unread"), row.unread))
                    }
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(chosen ? c.tb : selected ? c.s2 : Color.clear))
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityAddTraits(selected || chosen ? .isSelected : [])
    }
}

private struct SearchHitRow: View {
    let hit: SmsSearchHit
    let thread: SmsThread?
    let now: Date
    let selected: Bool
    @Environment(\.brand) private var c

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            SmsAvatar(thread: thread, address: hit.message.address, size: 30)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(thread?.title ?? hit.message.address).font(BrandFont.body(12, .semibold)).foregroundStyle(c.on).lineLimit(1)
                    Spacer(minLength: 4)
                    Text(smsListTime(hit.message.sentAt, now: now)).font(BrandFont.body(11)).foregroundStyle(c.on2).fixedSize()
                }
                Text(smsHighlighted(hit.excerpt, ranges: hit.matches, palette: c))
                    .font(BrandFont.body(12)).foregroundStyle(c.on2)
                    .lineLimit(2)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(selected ? c.s2 : Color.clear))
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }
}

/// `text` with `ranges` marked the way search results show matches.
func smsHighlighted(_ text: String, ranges: [Range<String.Index>], palette c: BrandPalette, onBubble: Bool = false) -> AttributedString {
    var attributed = AttributedString(text)
    for range in ranges {
        guard let mark = Range(range, in: attributed) else { continue }
        attributed[mark].backgroundColor = onBubble ? c.onpri.opacity(0.28) : c.tb
        attributed[mark].foregroundColor = onBubble ? c.onpri : c.on
        attributed[mark].font = BrandFont.body(onBubble ? 13 : 12, .semibold)
    }
    return attributed
}

/// Initials (or a group mark) on a tint picked from the conversation, so it stays the same.
struct SmsAvatar: View {
    let thread: SmsThread?
    var address: String? = nil
    let size: CGFloat
    @Environment(\.brand) private var c

    var body: some View {
        let seed = thread.map { $0.threadId } ?? (address ?? "").unicodeScalars.reduce(0) { $0 &+ Int($1.value) }
        let tints: [(Color, Color)] = [(c.tp, c.tpi), (c.tb, c.tbi), (c.tg, c.tgi)]
        let tint = tints[abs(seed) % tints.count]
        ZStack {
            Circle().fill(tint.0)
            if thread?.isGroup == true {
                Image(systemName: "person.2.fill").font(.system(size: size * 0.36)).foregroundStyle(tint.1)
            } else if let initials = initials {
                Text(initials).font(BrandFont.body(size * 0.36, .semibold)).foregroundStyle(tint.1)
            } else {
                Image(systemName: "person.fill").font(.system(size: size * 0.4)).foregroundStyle(tint.1)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    private var initials: String? {
        guard let name = thread?.participants.first?.name, !name.isEmpty else { return nil }
        let letters = name.split(separator: " ").prefix(2).compactMap { $0.first.map(String.init) }
        return letters.isEmpty ? nil : letters.joined().uppercased()
    }
}

private struct SimBadge: View {
    let sim: SmsSim
    @Environment(\.brand) private var c

    var body: some View {
        Text(String(format: L10n.text("sms.sim.short", fallback: "SIM %d"), sim.slot + 1))
            .font(BrandFont.body(10, .semibold))
            .foregroundStyle(c.tbi)
            .padding(.horizontal, 6)
            .frame(height: 16)
            .background(Capsule().fill(c.tb))
            .fixedSize()
            .help(sim.label)
    }
}

// MARK: - Several conversations

private struct BulkPane: View {
    let model: MessagesModel
    let actions: MessagesActions
    @Environment(\.brand) private var c

    private var ids: [Int] { model.selected.sorted() }
    private var menu: ConversationMenu { ConversationMenu(model: model, actions: actions, ids: ids) }

    var body: some View {
        VStack(spacing: 14) {
            IconTile(symbol: "checklist", tint: .blue, size: 44, corner: 12)
            Text(String(format: L10n.text("sms.selected", fallback: "%d selected"), ids.count))
                .font(BrandFont.heading(18)).foregroundStyle(c.on)
            Text(L10n.text("sms.selected.detail", fallback: "Changes here stay on this Mac. Mark as read also clears their notifications on your phone."))
                .font(BrandFont.body(13)).foregroundStyle(c.on2)
                .multilineTextAlignment(.center)
                // No fixedSize: the window takes this pane's smallest size as its own minimum, and a
                // text fixed to its height at no width is a letter per line (it grew the window, seen live).
                .frame(maxWidth: 360)
            HStack(spacing: 8) {
                if menu.anyUnread {
                    Button(L10n.text("sms.action.read", fallback: "Mark as read")) { actions.markRead(ids) }
                        .buttonStyle(PillButtonStyle(kind: .tonal, height: 30))
                } else {
                    Button(L10n.text("sms.action.unread", fallback: "Mark as unread")) { actions.markUnread(ids) }
                        .buttonStyle(PillButtonStyle(kind: .tonal, height: 30))
                }
                Button(menu.allMuted ? L10n.text("sms.action.unmute", fallback: "Unmute") : L10n.text("sms.action.mute", fallback: "Mute")) { actions.mute(ids, !menu.allMuted) }
                    .buttonStyle(PillButtonStyle(kind: .outline, height: 30))
                if menu.allArchived {
                    Button(L10n.text("sms.action.unarchive", fallback: "Unarchive")) { actions.unarchive(ids) }
                        .buttonStyle(PillButtonStyle(kind: .outline, height: 30))
                } else {
                    Button(L10n.text("sms.action.archive", fallback: "Archive")) { actions.archive(ids) }
                        .buttonStyle(PillButtonStyle(kind: .outline, height: 30))
                }
                Button(L10n.text("sms.action.deleteMenu", fallback: "Delete\u{2026}")) { actions.delete(ids) }
                    .buttonStyle(PillButtonStyle(kind: .danger, height: 30))
            }
            Button(L10n.text("sms.select.clear", fallback: "Clear selection"), action: actions.clearSelection)
                .buttonStyle(.plain)
                .font(BrandFont.body(12, .semibold))
                .foregroundStyle(c.on2)
                .padding(.top, 2)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Conversation

private struct ConversationPane: View {
    let model: MessagesModel
    let actions: MessagesActions
    let thread: SmsThread?
    let address: String?
    let copiedMessage: String?
    @Environment(\.brand) private var c
    @Environment(\.snapshotRendering) private var snapshot
    @State private var placed = false
    @State private var flash: String?

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(c.olv).frame(height: 1)
            messages
            Rectangle().fill(c.olv).frame(height: 1)
            ComposerBar(model: model, actions: actions, defaultSubId: thread?.subId,
                        group: thread?.isGroup == true, draft: model.draft)
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            SmsAvatar(thread: thread, address: address, size: 34)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(thread?.title ?? address ?? "").font(BrandFont.heading(16)).foregroundStyle(c.on).lineLimit(1)
                    if model.openRow?.muted == true {
                        Image(systemName: "bell.slash.fill").font(.system(size: 11)).foregroundStyle(c.on2)
                    }
                }
                if !subtitle.isEmpty {
                    Text(subtitle).font(BrandFont.body(12)).foregroundStyle(c.on2).lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            if let row = model.openRow { tools(row) }
        }
        .padding(.horizontal, 20)
        .padding(.top, 34)
        .padding(.bottom, 12)
    }

    /// The open conversation's buttons; the rest are in More and the right-click menu.
    private func tools(_ row: SmsThreadRow) -> some View {
        let ids = [row.id]
        let menu = ConversationMenu(model: model, actions: actions, ids: ids)
        return HStack(spacing: 6) {
            tool(row.unread > 0 ? "envelope.open" : "envelope.badge",
                 help: row.unread > 0 ? L10n.text("sms.action.read.help", fallback: "Mark as read (\u{21E7}\u{2318}U)") : L10n.text("sms.action.unread.help", fallback: "Mark as unread on this Mac (\u{21E7}\u{2318}U)")) {
                if row.unread > 0 { actions.markRead(ids) } else { actions.markUnread(ids) }
            }
            tool(row.pinned ? "pin.slash" : "pin", help: row.pinned ? L10n.text("sms.action.unpin", fallback: "Unpin") : L10n.text("sms.action.pin.help", fallback: "Pin to the top")) {
                actions.pin(ids, !row.pinned)
            }
            tool(row.archived ? "tray.and.arrow.up" : "archivebox",
                 help: row.archived ? L10n.text("sms.action.unarchive", fallback: "Unarchive") : L10n.text("sms.action.archive.help", fallback: "Archive: hide it until a new message arrives")) {
                if row.archived { actions.unarchive(ids) } else { actions.archive(ids) }
            }
            tool("trash", help: L10n.text("sms.action.delete.help", fallback: "Delete from this Mac (\u{2318}\u{232B})")) { actions.delete(ids) }
            tool("ellipsis", help: L10n.text("sms.action.more", fallback: "More")) {
                ConversationMenuPresenter.show(menu: menu, row: row)
            }
        }
    }

    private func tool(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 13, weight: .medium)).foregroundStyle(c.on)
                .frame(width: 30, height: 30)
                .background(Circle().fill(c.s2))
        }
        .buttonStyle(PressScaleStyle())
        .help(help)
        .accessibilityLabel(help)
    }

    private var subtitle: String {
        var parts: [String] = []
        if let thread {
            let numbers = thread.participants.filter { $0.name != nil }.map(\.address)
            if !numbers.isEmpty { parts.append(numbers.joined(separator: ", ")) }
            if model.dualSim, let sim = model.sim(thread.subId) { parts.append(simTitle(sim)) }
            if model.openRow?.archived == true { parts.append(L10n.text("sms.archived", fallback: "Archived")) }
        } else {
            parts.append(L10n.text("sms.newConversation", fallback: "New conversation"))
        }
        return parts.joined(separator: " \u{00B7} ")
    }

    /// Oldest first for display, with the unread divider and this Mac's unconfirmed sends after them.
    private var items: [ConversationItem] {
        var list: [ConversationItem] = []
        let ordered = model.messages.reversed()
        var lastDay: Date?
        let calendar = Calendar.current
        let newestOutgoing = model.messages.first { $0.direction == .outgoing }?.id
        for message in ordered {
            let day = calendar.startOfDay(for: message.sentAt)
            if day != lastDay {
                list.append(.day(day))
                lastDay = day
            }
            if message.id == model.unreadFrom { list.append(.unread) }
            list.append(.message(message, showsStatus: message.id == newestOutgoing && model.outgoing.isEmpty))
        }
        for item in model.outgoing { list.append(.outgoing(item)) }
        return list
    }

    @ViewBuilder private var messages: some View {
        if snapshot {
            VStack(spacing: 6) { content }
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: model.unreadFrom == nil ? .bottom : .top)
                .clipped()
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 6) {
                        if model.messagesMore && !model.messages.isEmpty && placed {
                            HStack { Spacer(); ProgressView().controlSize(.small); Spacer() }
                                .frame(height: 30)
                                .onAppear(perform: actions.loadOlderMessages)
                        }
                        content
                        Color.clear.frame(height: 1).id("bottom")
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 12)
                }
                .onAppear { place(proxy) }
                .onChange(of: model.messages.first?.id) { _ in
                    if placed { proxy.scrollTo("bottom", anchor: .bottom) } else { place(proxy) }
                }
                .onChange(of: model.outgoing.count) { _ in proxy.scrollTo("bottom", anchor: .bottom) }
                .onChange(of: model.focusMessage) { id in
                    guard let id else { return }
                    reveal(id, proxy)
                }
            }
        }
    }

    /// Where an opened conversation starts: a search result's message, else the unread divider, else the end.
    private func place(_ proxy: ScrollViewProxy) {
        guard !model.messages.isEmpty else { return }
        placed = true
        DispatchQueue.main.async {
            if let focus = model.focusMessage, model.messages.contains(where: { $0.id == focus }) {
                reveal(focus, proxy)
            } else if model.unreadFrom != nil {
                proxy.scrollTo("unread", anchor: .top)
            } else {
                proxy.scrollTo("bottom", anchor: .bottom)
            }
        }
    }

    private func reveal(_ id: String, _ proxy: ScrollViewProxy) {
        proxy.scrollTo(id, anchor: .center)
        flash = id
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.2) { if flash == id { flash = nil } }
    }

    @ViewBuilder private var content: some View {
        if model.messages.isEmpty && model.outgoing.isEmpty {
            Text(model.loadingMessages ? L10n.text("sms.loading", fallback: "Loading\u{2026}") : L10n.text("sms.noMessages", fallback: "No messages yet."))
                .font(BrandFont.body(13)).foregroundStyle(c.on2)
                .frame(maxWidth: .infinity, minHeight: 120)
        }
        ForEach(items) { item in
            switch item {
            case let .day(day):
                Text(smsDayTitle(day, now: model.now))
                    .font(BrandFont.body(11, .semibold)).foregroundStyle(c.on2)
                    .padding(.vertical, 6)
                    .frame(maxWidth: .infinity)
            case .unread:
                UnreadDivider().id("unread")
            case let .message(message, showsStatus):
                MessageBubble(message: message, model: model, actions: actions, showsStatus: showsStatus,
                              copied: copiedMessage == message.id, marked: flash == message.id || (snapshot && model.focusMessage == message.id),
                              sender: thread?.isGroup == true ? thread?.participants.first { $0.address == message.address }?.display : nil)
                    .id(message.id)
            case let .outgoing(item):
                OutgoingBubble(item: item, actions: actions)
            }
        }
    }
}

/// The More button's menu: the same items as the right-click menu.
@MainActor
private enum ConversationMenuPresenter {
    private final class Target: NSObject {
        let action: () -> Void
        init(_ action: @escaping () -> Void) { self.action = action }
        @objc func run() { action() }
    }

    static func show(menu: ConversationMenu, row: SmsThreadRow) {
        let ids = menu.ids
        let actions = menu.actions
        var items: [(String, String, NSEvent.ModifierFlags, () -> Void)?] = []
        if menu.anyUnread {
            items.append((L10n.text("sms.action.read", fallback: "Mark as read"), "u", [.command, .shift], { actions.markRead(ids) }))
        } else {
            items.append((L10n.text("sms.action.unread", fallback: "Mark as unread"), "u", [.command, .shift], { actions.markUnread(ids) }))
        }
        items.append((menu.allPinned ? L10n.text("sms.action.unpin", fallback: "Unpin") : L10n.text("sms.action.pin", fallback: "Pin"), "", [], { actions.pin(ids, !menu.allPinned) }))
        items.append((menu.allMuted ? L10n.text("sms.action.unmute", fallback: "Unmute") : L10n.text("sms.action.mute", fallback: "Mute"), "", [], { actions.mute(ids, !menu.allMuted) }))
        if menu.allArchived {
            items.append((L10n.text("sms.action.unarchive", fallback: "Unarchive"), "", [], { actions.unarchive(ids) }))
        } else {
            items.append((L10n.text("sms.action.archive", fallback: "Archive"), "", [], { actions.archive(ids) }))
        }
        if let blockable = menu.blockable {
            items.append(nil)
            items.append((L10n.text("sms.action.block", fallback: "Block on phone\u{2026}"), "", [], { actions.blockOnPhone(blockable) }))
        }
        items.append(nil)
        items.append((L10n.text("sms.action.deleteMenu", fallback: "Delete\u{2026}"), "\u{8}", [.command], { actions.delete(ids) }))
        let nsMenu = NSMenu()
        nsMenu.autoenablesItems = false
        for item in items {
            guard let (title, key, modifiers, action) = item else {
                nsMenu.addItem(.separator())
                continue
            }
            let target = Target(action)
            let entry = NSMenuItem(title: title, action: #selector(Target.run), keyEquivalent: key)
            entry.keyEquivalentModifierMask = modifiers
            entry.target = target
            entry.representedObject = target
            nsMenu.addItem(entry)
        }
        nsMenu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }
}

private struct UnreadDivider: View {
    @Environment(\.brand) private var c

    var body: some View {
        HStack(spacing: 10) {
            Rectangle().fill(c.pri.opacity(0.5)).frame(height: 1)
            Text(L10n.text("sms.unread.divider", fallback: "Unread"))
                .font(BrandFont.body(11, .semibold))
                .foregroundStyle(c.tbi)
                .padding(.horizontal, 10)
                .frame(height: 20)
                .background(Capsule().fill(c.tb))
            Rectangle().fill(c.pri.opacity(0.5)).frame(height: 1)
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .combine)
    }
}

private enum ConversationItem: Identifiable {
    case day(Date)
    case unread
    case message(SmsMessage, showsStatus: Bool)
    case outgoing(SmsOutgoing)

    var id: String {
        switch self {
        case let .day(date): "day-\(date.timeIntervalSince1970)"
        case .unread: "unread-divider"
        case let .message(message, _): message.id
        case let .outgoing(item): "out-\(item.id)"
        }
    }
}

private struct MessageBubble: View {
    let message: SmsMessage
    let model: MessagesModel
    let actions: MessagesActions
    let showsStatus: Bool
    let copied: Bool
    /// A search result: outlined for a moment.
    let marked: Bool
    let sender: String?
    @Environment(\.brand) private var c
    @State private var details = false

    private var mine: Bool { message.direction == .outgoing }
    private var hasCode: Bool { !mine && model.codesEnabled && looksLikeOtpTraffic(message.body) }

    var body: some View {
        VStack(alignment: mine ? .trailing : .leading, spacing: 4) {
            if let sender, !mine {
                Text(sender).font(BrandFont.body(11, .semibold)).foregroundStyle(c.on2).padding(.leading, 12)
            }
            ForEach(message.parts, id: \.partId) { part in
                SmsImageView(partID: part.partId, image: model.images[part.partId], failed: model.failedImages.contains(part.partId),
                             request: actions.requestImage)
            }
            if !message.body.isEmpty {
                // Not selectable, as in Messages: selectable text would take the right-click for the
                // system text menu and hide this message's own (Copy text copies it all).
                Text(bodyText)
                    .font(BrandFont.body(13))
                    .foregroundStyle(mine ? c.onpri : c.on)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(mine ? c.pri : c.s2))
                    .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(marked ? c.tbi : Color.clear, lineWidth: 2))
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 6) {
                Text(message.sentAt, format: .dateTime.hour().minute()).font(BrandFont.body(10)).foregroundStyle(c.on2)
                if model.dualSim, let sim = model.sim(message.subId) { SimBadge(sim: sim) }
                if mine && (showsStatus || message.status == .failed) { statusLabel }
                if hasCode {
                    Button { actions.copyCode(message) } label: {
                        Label(copied ? L10n.text("sms.code.copied", fallback: "Copied") : L10n.text("codes.copy", fallback: "Copy code"),
                              systemImage: copied ? "checkmark" : "doc.on.doc")
                            .font(BrandFont.body(11, .semibold))
                            .foregroundStyle(c.tbi)
                            .padding(.horizontal, 8)
                            .frame(height: 20)
                            .background(Capsule().fill(c.tb))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 4)
        }
        .contentShape(Rectangle())
        .popover(isPresented: $details, arrowEdge: mine ? .leading : .trailing) {
            MessageDetails(message: message, model: model)
        }
        .frame(maxWidth: 520, alignment: mine ? .trailing : .leading)
        .frame(maxWidth: .infinity, alignment: mine ? .trailing : .leading)
        .contextMenu { menu }
    }

    private var bodyText: AttributedString {
        let text = message.body + (message.truncated ? "\u{2026}" : "")
        let query = model.query.trimmingCharacters(in: .whitespacesAndNewlines)
        return smsHighlighted(text, ranges: query.isEmpty ? [] : smsMatches(of: query, in: text), palette: c, onBubble: mine)
    }

    @ViewBuilder private var menu: some View {
        if !message.body.isEmpty {
            Button(L10n.text("sms.message.copy", fallback: "Copy text")) { actions.copyText(message) }
        }
        if hasCode {
            Button(L10n.text("codes.copy", fallback: "Copy code")) { actions.copyCode(message) }
        }
        if !message.body.isEmpty {
            Button(L10n.text("sms.message.forward", fallback: "Forward\u{2026}")) { actions.forward(message) }
        }
        Button(L10n.text("sms.message.details", fallback: "Details")) { details = true }
        Divider()
        Button(L10n.text("sms.message.delete", fallback: "Delete from this Mac\u{2026}"), role: .destructive) { actions.deleteMessage(message) }
    }

    @ViewBuilder private var statusLabel: some View {
        switch message.status {
        case .delivered: Text(L10n.text("sms.status.delivered", fallback: "Delivered")).font(BrandFont.body(10, .semibold)).foregroundStyle(c.good)
        case .sent: Text(L10n.text("sms.status.sent", fallback: "Sent")).font(BrandFont.body(10, .semibold)).foregroundStyle(c.on2)
        case .pending: Text(L10n.text("sms.status.sending", fallback: "Sending\u{2026}")).font(BrandFont.body(10, .semibold)).foregroundStyle(c.on2)
        case .failed: Text(L10n.text("sms.status.failed", fallback: "Not sent")).font(BrandFont.body(10, .semibold)).foregroundStyle(c.warn)
        case .received: EmptyView()
        }
    }
}

/// Show details: when, who, which SIM and how it went.
private struct MessageDetails: View {
    let message: SmsMessage
    let model: MessagesModel
    @Environment(\.brand) private var c

    private var mine: Bool { message.direction == .outgoing }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L10n.text("sms.message.details", fallback: "Details")).font(BrandFont.heading(14)).foregroundStyle(c.on)
            line(mine ? L10n.text("sms.details.sent", fallback: "Sent") : L10n.text("sms.details.received", fallback: "Received"),
                 message.sentAt.formatted(.dateTime.weekday(.wide).day().month(.wide).year().hour().minute().second()))
            if !message.address.isEmpty {
                line(mine ? L10n.text("sms.details.to", fallback: "To") : L10n.text("sms.details.from", fallback: "From"), message.address)
            }
            if let sim = model.sim(message.subId) {
                line(L10n.text("sms.details.sim", fallback: "SIM"), simTitle(sim))
            }
            line(L10n.text("sms.details.status", fallback: "Status"), status)
            line(L10n.text("sms.details.type", fallback: "Type"), message.id.hasPrefix("m") ? "MMS" : "SMS")
        }
        .padding(16)
        .frame(width: 300, alignment: .leading)
        .background(c.s1)
    }

    private var status: String {
        switch message.status {
        case .received: message.read ? L10n.text("sms.details.read", fallback: "Received, read on the phone") : L10n.text("sms.details.unreadPhone", fallback: "Received, unread on the phone")
        case .pending: L10n.text("sms.status.sending", fallback: "Sending\u{2026}")
        case .sent: L10n.text("sms.details.sentStatus", fallback: "Sent, no delivery report yet")
        case .delivered: L10n.text("sms.status.delivered", fallback: "Delivered")
        case .failed: L10n.text("sms.status.failed", fallback: "Not sent")
        }
    }

    private func line(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(label).font(BrandFont.body(12, .semibold)).foregroundStyle(c.on2).frame(width: 74, alignment: .leading)
            Text(value).font(BrandFont.body(12)).foregroundStyle(c.on).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct OutgoingBubble: View {
    let item: SmsOutgoing
    let actions: MessagesActions
    @Environment(\.brand) private var c

    var body: some View {
        VStack(alignment: .trailing, spacing: 4) {
            Text(item.body)
                .font(BrandFont.body(13))
                .foregroundStyle(item.failed ? c.on : c.onpri)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(item.failed ? c.s2 : c.pri.opacity(0.75)))
                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(item.failed ? c.warn : Color.clear, lineWidth: 1))
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                switch item.state {
                case .sending:
                    Text(L10n.text("sms.status.sending", fallback: "Sending\u{2026}")).foregroundStyle(c.on2)
                case .sent:
                    Text(L10n.text("sms.status.sent", fallback: "Sent")).foregroundStyle(c.on2)
                case .delivered:
                    Text(L10n.text("sms.status.delivered", fallback: "Delivered")).foregroundStyle(c.good)
                case .failed, .refused:
                    Text(smsFailureText(item.reason)).foregroundStyle(c.warn).lineLimit(2)
                    Button(L10n.text("sms.retry", fallback: "Retry")) { actions.retry(item.id) }
                        .buttonStyle(PillButtonStyle(kind: .tonal, height: 22))
                    Button(L10n.text("sms.discard", fallback: "Delete")) { actions.discard(item.id) }
                        .buttonStyle(PillButtonStyle(kind: .outline, height: 22))
                }
            }
            .font(BrandFont.body(10, .semibold))
            .padding(.horizontal, 4)
        }
        .frame(maxWidth: 520, alignment: .trailing)
        .frame(maxWidth: .infinity, alignment: .trailing)
    }
}

private struct SmsImageView: View {
    let partID: String
    let image: NSImage?
    let failed: Bool
    let request: (String) -> Void
    @Environment(\.brand) private var c

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: 240, maxHeight: 260)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .accessibilityLabel(L10n.text("sms.image", fallback: "Image"))
            } else {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(c.s2)
                    .frame(width: 200, height: 150)
                    .overlay {
                        if failed {
                            VStack(spacing: 4) {
                                Image(systemName: "photo").font(.system(size: 18))
                                Text(L10n.text("sms.image.failed", fallback: "Image not available")).font(BrandFont.body(11))
                            }
                            .foregroundStyle(c.on2)
                        } else {
                            ProgressView().controlSize(.small)
                        }
                    }
                    .onAppear { request(partID) }
            }
        }
    }
}

// MARK: - Composer

private struct ComposerBar: View {
    let model: MessagesModel
    let actions: MessagesActions
    let defaultSubId: Int?
    let group: Bool
    @State private var text: String
    @State private var chosenSim: Int?
    @Environment(\.brand) private var c
    @Environment(\.snapshotRendering) private var snapshot

    init(model: MessagesModel, actions: MessagesActions, defaultSubId: Int?, group: Bool, draft: String = "") {
        self.model = model
        self.actions = actions
        self.defaultSubId = defaultSubId
        self.group = group
        _text = State(initialValue: draft)
    }

    private var subId: Int? { chosenSim ?? defaultSubId ?? model.sims.first?.subId }
    private var count: Int { text.utf16.count }

    var body: some View {
        Group {
            if group {
                // Group conversations are read only on the Mac in this release (one recipient per SMS; group MMS
                // needs the default SMS app). Said plainly instead of a compose box that cannot send.
                note(L10n.text("sms.group", fallback: "Group conversations are read only on this Mac. Reply from your phone."), symbol: "lock")
            } else if !model.canSend {
                note(L10n.text("sms.cannotSend", fallback: "Allow SMS for Bridgey on your phone to send from here."))
            } else {
                HStack(alignment: .bottom, spacing: 8) {
                    if model.dualSim { simPicker }
                    VStack(alignment: .trailing, spacing: 2) {
                        field
                        if count > 1_500 {
                            Text("\(count) / \(SmsLimits.body)")
                                .font(BrandFont.body(10)).foregroundStyle(count > SmsLimits.body ? c.warn : c.on2)
                        }
                    }
                    Button(action: send) {
                        Image(systemName: "arrow.up")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(c.onpri)
                            .frame(width: 32, height: 32)
                            .background(Circle().fill(c.pri))
                    }
                    .buttonStyle(PressScaleStyle())
                    .disabled(!SmsRequests.isSendableBody(text))
                    .opacity(SmsRequests.isSendableBody(text) || snapshot ? 1 : 0.45)
                    .keyboardShortcut(.return, modifiers: [.command])
                    .help(L10n.text("sms.send", fallback: "Send"))
                    .accessibilityLabel(L10n.text("sms.send", fallback: "Send"))
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
        }
    }

    private func note(_ line: String, symbol: String? = nil) -> some View {
        HStack(spacing: 6) {
            if let symbol { Image(systemName: symbol).font(.system(size: 11, weight: .semibold)) }
            Text(line).font(BrandFont.body(12))
        }
        .foregroundStyle(c.on2)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
        .background(c.s1)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private var field: some View {
        Group {
            if snapshot {
                Text(text.isEmpty ? L10n.text("sms.reply.placeholder", fallback: "Text message") : text)
                    .foregroundStyle(text.isEmpty ? c.on2 : c.on)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                TextField(L10n.text("sms.reply.placeholder", fallback: "Text message"), text: $text, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1...6)
                    .onSubmit(send)
            }
        }
        .font(BrandFont.body(13))
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .frame(minHeight: 34)
        .background(RoundedRectangle(cornerRadius: 17, style: .continuous).fill(c.s2))
    }

    private var simPicker: some View {
        Button {
            DropMenu.show(model.sims.map { sim in PopUpMenuItem(title: simTitle(sim), checked: sim.subId == subId) { chosenSim = sim.subId } })
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "simcard").font(.system(size: 12))
                Text(model.sim(subId).map { String(format: L10n.text("sms.sim.short", fallback: "SIM %d"), $0.slot + 1) } ?? "SIM")
                    .font(BrandFont.body(12, .semibold))
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 8, weight: .semibold))
            }
            .foregroundStyle(c.on)
            .padding(.horizontal, 10)
            .frame(height: 34)
            .background(Capsule().fill(c.s2))
        }
        .buttonStyle(.plain)
        .help(L10n.text("sms.sim.pick", fallback: "The SIM to send from"))
    }

    private func send() {
        guard SmsRequests.isSendableBody(text) else { return }
        if actions.send(text, model.dualSim ? subId : nil) { text = "" }
    }
}

func simTitle(_ sim: SmsSim) -> String {
    let slot = String(format: L10n.text("sms.sim.short", fallback: "SIM %d"), sim.slot + 1)
    return sim.label.isEmpty ? slot : "\(slot) \u{00B7} \(sim.label)"
}

// MARK: - New message

private struct NewMessagePane: View {
    let model: MessagesModel
    let actions: MessagesActions
    @State private var to: String
    @Environment(\.brand) private var c
    @Environment(\.snapshotRendering) private var snapshot

    init(model: MessagesModel, actions: MessagesActions, typed: String = "") {
        self.model = model
        self.actions = actions
        _to = State(initialValue: typed)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(model.draft.isEmpty ? L10n.text("sms.new", fallback: "New message") : L10n.text("sms.forward.title", fallback: "Forward message"))
                .font(BrandFont.heading(16)).foregroundStyle(c.on)
                .padding(.horizontal, 20).padding(.top, 34).padding(.bottom, 12)
            if !model.draft.isEmpty {
                Text(model.draft)
                    .font(BrandFont.body(12)).foregroundStyle(c.on2)
                    .lineLimit(3)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(c.ol, lineWidth: 1))
                    .padding(.horizontal, 20)
                    .padding(.bottom, 10)
            }
            HStack(spacing: 8) {
                Text(L10n.text("sms.to", fallback: "To:")).font(BrandFont.body(13, .semibold)).foregroundStyle(c.on2)
                Group {
                    if snapshot {
                        Text(to.isEmpty ? L10n.text("sms.to.placeholder", fallback: "Name or number") : to)
                            .foregroundStyle(to.isEmpty ? c.on2 : c.on)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        TextField(L10n.text("sms.to.placeholder", fallback: "Name or number"), text: $to)
                            .textFieldStyle(.plain)
                            .onSubmit(useTyped)
                            .onChange(of: to) { value in
                                if normalizedSmsAddress(value) == nil { actions.searchContacts(value) }
                            }
                    }
                }
                .font(BrandFont.body(13))
                if let number = normalizedSmsAddress(to) {
                    Button(String(format: L10n.text("sms.to.number", fallback: "Text %@"), number), action: useTyped)
                        .buttonStyle(PillButtonStyle(kind: .tonal, height: 26))
                }
            }
            .padding(.horizontal, 14)
            .frame(height: 38)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(c.s2))
            .padding(.horizontal, 20)
            results
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder private var results: some View {
        VStack(alignment: .leading, spacing: 2) {
            if model.searchingContacts && model.contacts.isEmpty {
                ProgressView().controlSize(.small).padding(16)
            }
            ForEach(model.contacts) { contact in
                Button { actions.select(.address(contact.address)) } label: {
                    HStack(spacing: 10) {
                        SmsAvatar(thread: SmsThread(threadId: contact.name.count, participants: [SmsParticipant(address: contact.address, name: contact.name)],
                                                    snippet: "", date: 0, unread: 0), size: 30)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(contact.name.isEmpty ? contact.address : contact.name).font(BrandFont.body(13, .medium)).foregroundStyle(c.on)
                            Text([contact.label, contact.address].compactMap { $0 }.joined(separator: " \u{00B7} "))
                                .font(BrandFont.body(12)).foregroundStyle(c.on2)
                        }
                        Spacer()
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            if !model.contacts.isEmpty || model.searchingContacts {
                EmptyView()
            } else {
                Text(L10n.text("sms.to.hint", fallback: "Type a name from your phone\u{2019}s contacts, or a number."))
                    .font(BrandFont.body(12)).foregroundStyle(c.on2)
                    .padding(.horizontal, 24).padding(.top, 12)
            }
        }
        .padding(.horizontal, 8)
        .padding(.top, 8)
    }

    private func useTyped() {
        guard let number = normalizedSmsAddress(to) else { return }
        actions.select(.address(number))
    }
}

// MARK: - Formatting

/// "09:41" today, "Yesterday", the weekday this week, else the date.
func smsListTime(_ date: Date, now: Date) -> String {
    let calendar = Calendar.current
    if calendar.isDate(date, inSameDayAs: now) { return date.formatted(.dateTime.hour().minute()) }
    if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) {
        return L10n.text("sms.yesterday", fallback: "Yesterday")
    }
    if let week = calendar.date(byAdding: .day, value: -6, to: now), date > week { return date.formatted(.dateTime.weekday(.wide)) }
    return date.formatted(.dateTime.day().month(.abbreviated))
}

/// The separator above a day's messages.
func smsDayTitle(_ day: Date, now: Date) -> String {
    let calendar = Calendar.current
    if calendar.isDate(day, inSameDayAs: now) { return L10n.text("sms.today", fallback: "Today") }
    if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(day, inSameDayAs: yesterday) {
        return L10n.text("sms.yesterday", fallback: "Yesterday")
    }
    return day.formatted(.dateTime.weekday(.wide).day().month(.wide))
}

// MARK: - Panel entry

/// The menu bar panel's way into the Messages window, while Text messages is available for the phone.
struct MessagesPanelEntry: View {
    let model: PanelModel
    let actions: PanelActions
    @Environment(\.brand) private var c

    var body: some View {
        if model.onboardingDone, model.isConnected, let unread = model.messagesUnread {
            Button(action: actions.openMessages) {
                HStack(spacing: 6) {
                    Image(systemName: "message").font(.system(size: 12, weight: .medium))
                    Text(L10n.text("sms.window", fallback: "Messages")).font(BrandFont.body(12, .medium))
                    if unread > 0 {
                        Text("\(unread)")
                            .font(BrandFont.body(11, .semibold))
                            .foregroundStyle(c.onpri)
                            .padding(.horizontal, 6)
                            .frame(height: 16)
                            .background(Capsule().fill(c.pri))
                            .accessibilityLabel(String(format: L10n.text("sms.unreadCount", fallback: "%d unread"), unread))
                    }
                }
                .foregroundStyle(c.on)
                .frame(maxWidth: .infinity)
                .frame(height: 30)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(c.s2))
                .contentShape(Rectangle())
            }
            .buttonStyle(PressScaleStyle())
            .help(L10n.text("sms.entry.help", fallback: "Read and answer your phone\u{2019}s texts"))
            .padding(.horizontal, 12)
            .padding(.top, 8)
        }
    }
}
