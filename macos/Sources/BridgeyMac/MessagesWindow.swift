import AppKit
import SwiftUI

/*
 * Text messages (draft sms_draft1): the Messages window, Pushbullet style. Conversations on the
 * left, the open conversation on the right with delivery status, MMS images (read only), Copy code
 * on messages that hold one, and a composer with the SIM to send from on dual-SIM phones. New
 * message starts a conversation with a contact or a number. Direction B "Stream" (BrandTheme).
 * MessagesView is pure (a model and actions), so the screenshots render it from sample state.
 */

@MainActor
final class MessagesSelection: ObservableObject {
    @Published var phoneID: String?
    @Published var target: MessagesTarget?
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
    }
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

struct MessagesModel {
    var phones: [MessagesPhone] = []
    var phoneID: String?
    var phoneName = ""
    var availability: MessagesAvailability = .noPhone
    var threads: [SmsThread] = []
    var threadsMore = false
    var loadingThreads = false
    var target: MessagesTarget?
    /// Newest first.
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
    /// Screenshots only: text already typed in the composer and the To field.
    var draft = ""
    var typedRecipient = ""

    var thread: SmsThread? {
        if case let .thread(id)? = target { return threads.first { $0.threadId == id } }
        return nil
    }

    var dualSim: Bool { sims.count > 1 }

    func sim(_ subId: Int?) -> SmsSim? { subId.flatMap { id in sims.first { $0.subId == id } } }
}

struct MessagesActions {
    var selectPhone: (String) -> Void = { _ in }
    var select: (MessagesTarget?) -> Void = { _ in }
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
}

// MARK: - Live

private struct MessagesLiveView: View {
    @ObservedObject var pairing: PairingCoordinator
    @ObservedObject var messages: TextMessages
    @ObservedObject var settings: BridgeySettings
    @ObservedObject var selection: MessagesSelection
    @AppStorage("settings.reduceMotion") private var reduceMotion = false
    @State private var copiedMessage: String?

    var body: some View {
        BrandRoot(reduceMotion: reduceMotion) {
            MessagesView(model: model, actions: actions, copiedMessage: copiedMessage)
        }
        .ignoresSafeArea()
        .onAppear(perform: appeared)
        .onDisappear { messages.close() }
        .onChange(of: selection.phoneID) { _ in appeared() }
        .onChange(of: selection.target) { target in open(target) }
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
        open(selection.target)
    }

    private func open(_ target: MessagesTarget?) {
        guard let phoneID else { return }
        if case let .thread(id)? = target { messages.open(phoneID, thread: id) } else { messages.close() }
        if target != .compose { messages.clearContacts() }
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
            model.messages = data.cache.messages(in: id)
            model.messagesMore = data.cache.hasOlder(in: id)
            model.loadingMessages = data.loadingMessages.contains(id)
            model.outgoing = messages.outgoing.filter { $0.phoneID == phoneID && $0.target == .thread(id) }
        case let .address(address)?:
            model.outgoing = messages.outgoing.filter {
                if case let .address(sent) = $0.target { return $0.phoneID == phoneID && smsSameNumber(sent, address) }
                return false
            }
        default:
            break
        }
        for message in model.messages {
            for part in message.parts {
                if let image = messages.image(phoneID, partID: part.partId) { model.images[part.partId] = image }
                if messages.imageFailed(phoneID, partID: part.partId) { model.failedImages.insert(part.partId) }
            }
        }
        model.contacts = messages.contactResults
        model.searchingContacts = messages.contactsSearching
        model.now = Date()
        return model
    }

    private var actions: MessagesActions {
        var actions = MessagesActions()
        actions.selectPhone = { id in
            selection.phoneID = id
            selection.target = nil
        }
        actions.select = { selection.target = $0 }
        actions.loadOlderThreads = { if let phoneID { messages.loadOlderThreads(phoneID) } }
        actions.loadOlderMessages = {
            if let phoneID, case let .thread(id)? = selection.target { messages.loadOlderMessages(phoneID, thread: id) }
        }
        actions.send = { body, subId in
            guard let phoneID else { return false }
            switch selection.target {
            case let .thread(id)?: return messages.send(body, to: .thread(id), subId: subId, phoneID: phoneID) != nil
            case let .address(address)?: return messages.send(body, to: .address(address), subId: subId, phoneID: phoneID) != nil
            default: return false
            }
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
        return actions
    }
}

// MARK: - View

struct MessagesView: View {
    let model: MessagesModel
    let actions: MessagesActions
    var copiedMessage: String?
    @Environment(\.brand) private var c
    @State private var query = ""

    static let size = CGSize(width: 960, height: 640)
    static let sidebarWidth: CGFloat = 310

    var body: some View {
        Group {
            switch model.availability {
            case .ready:
                HStack(spacing: 0) {
                    MessagesSidebar(model: model, actions: actions, query: $query)
                        .frame(width: Self.sidebarWidth)
                    Rectangle().fill(c.olv).frame(width: 1)
                    conversation.frame(maxWidth: .infinity)
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
        switch model.target {
        case .thread?:
            if let thread = model.thread {
                ConversationPane(model: model, actions: actions, thread: thread, address: nil, copiedMessage: copiedMessage)
            } else {
                PhoneFilesMessage(symbol: "bubble.left.and.bubble.right", title: L10n.text("sms.loading", fallback: "Loading\u{2026}"), detail: nil)
            }
        case let .address(address)?:
            ConversationPane(model: model, actions: actions, thread: nil, address: address, copiedMessage: copiedMessage)
        case .compose?:
            NewMessagePane(model: model, actions: actions, typed: model.typedRecipient)
        case nil:
            PhoneFilesMessage(symbol: "bubble.left.and.bubble.right",
                              title: L10n.text("sms.pick", fallback: "Pick a conversation"),
                              detail: L10n.text("sms.pick.detail", fallback: "Or start a new message to a contact or a number."),
                              button: L10n.text("sms.new", fallback: "New message")) { actions.select(.compose) }
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

// MARK: - Sidebar

private struct MessagesSidebar: View {
    let model: MessagesModel
    let actions: MessagesActions
    @Binding var query: String
    @Environment(\.brand) private var c
    @Environment(\.snapshotRendering) private var snapshot

    private var shown: [SmsThread] {
        let text = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !text.isEmpty else { return model.threads }
        return model.threads.filter { thread in
            thread.title.lowercased().contains(text) || thread.snippet.lowercased().contains(text)
                || thread.participants.contains { $0.address.contains(text) }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text(L10n.text("sms.window", fallback: "Messages")).font(BrandFont.heading(20)).foregroundStyle(c.on)
                Spacer(minLength: 4)
                Button { actions.select(.compose) } label: {
                    Image(systemName: "square.and.pencil").font(.system(size: 14, weight: .medium)).foregroundStyle(c.on)
                        .frame(width: 30, height: 30)
                        .background(Circle().fill(model.target == .compose ? c.tb : c.s2))
                }
                .buttonStyle(PressScaleStyle())
                .help(L10n.text("sms.new", fallback: "New message"))
                .accessibilityLabel(L10n.text("sms.new", fallback: "New message"))
            }
            .padding(.top, 36)
            .padding(.horizontal, 16)
            if model.phones.count > 1 {
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
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(c.on2)
                if snapshot {
                    Text(query.isEmpty ? L10n.text("sms.search", fallback: "Search conversations") : query)
                        .foregroundStyle(query.isEmpty ? c.on2 : c.on)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    TextField(L10n.text("sms.search", fallback: "Search conversations"), text: $query).textFieldStyle(.plain)
                }
            }
            .font(BrandFont.body(13))
            .padding(.horizontal, 12)
            .frame(height: 30)
            .background(Capsule().fill(c.s2))
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            list
        }
    }

    @ViewBuilder private var list: some View {
        if model.threads.isEmpty {
            Text(model.loadingThreads ? L10n.text("sms.loading", fallback: "Loading\u{2026}") : L10n.text("sms.noThreads", fallback: "No conversations yet."))
                .font(BrandFont.body(13)).foregroundStyle(c.on2)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if snapshot {
            VStack(spacing: 2) { rows }
                .padding(.horizontal, 8)
                .frame(maxHeight: .infinity, alignment: .top)
                .clipped()
        } else {
            ScrollView {
                LazyVStack(spacing: 2) {
                    rows
                    if model.threadsMore && query.isEmpty {
                        HStack { Spacer(); ProgressView().controlSize(.small); Spacer() }
                            .frame(height: 36)
                            .onAppear(perform: actions.loadOlderThreads)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 8)
            }
        }
    }

    @ViewBuilder private var rows: some View {
        ForEach(shown) { thread in
            ThreadRow(thread: thread, selected: model.target == .thread(thread.threadId),
                      sim: model.dualSim ? model.sim(thread.subId) : nil, now: model.now)
                .onTapGesture { actions.select(.thread(thread.threadId)) }
        }
    }
}

private struct ThreadRow: View {
    let thread: SmsThread
    let selected: Bool
    let sim: SmsSim?
    let now: Date
    @Environment(\.brand) private var c

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            SmsAvatar(thread: thread, size: 38)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(thread.title).font(BrandFont.body(13, thread.unread > 0 ? .semibold : .medium)).foregroundStyle(c.on).lineLimit(1)
                    Spacer(minLength: 4)
                    Text(smsListTime(thread.lastAt, now: now)).font(BrandFont.body(11)).foregroundStyle(c.on2).lineLimit(1).fixedSize()
                }
                HStack(spacing: 6) {
                    Text(thread.snippet).font(BrandFont.body(12)).foregroundStyle(thread.unread > 0 ? c.on : c.on2).lineLimit(1)
                    Spacer(minLength: 4)
                    if let sim { SimBadge(sim: sim) }
                    if thread.unread > 0 {
                        Circle().fill(c.pri).frame(width: 8, height: 8)
                            .accessibilityLabel(L10n.text("sms.unread", fallback: "Unread"))
                    }
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(selected ? c.s2 : Color.clear))
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }
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

// MARK: - Conversation

private struct ConversationPane: View {
    let model: MessagesModel
    let actions: MessagesActions
    let thread: SmsThread?
    let address: String?
    let copiedMessage: String?
    @Environment(\.brand) private var c
    @Environment(\.snapshotRendering) private var snapshot

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
                Text(thread?.title ?? address ?? "").font(BrandFont.heading(16)).foregroundStyle(c.on).lineLimit(1)
                Text(subtitle).font(BrandFont.body(12)).foregroundStyle(c.on2).lineLimit(1)
            }
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.top, 34)
        .padding(.bottom, 12)
    }

    private var subtitle: String {
        var parts: [String] = []
        if let thread {
            let numbers = thread.participants.filter { $0.name != nil }.map(\.address)
            if !numbers.isEmpty { parts.append(numbers.joined(separator: ", ")) }
            if model.dualSim, let sim = model.sim(thread.subId) { parts.append(simTitle(sim)) }
        } else {
            parts.append(L10n.text("sms.newConversation", fallback: "New conversation"))
        }
        return parts.joined(separator: " \u{00B7} ")
    }

    /// Oldest first for display, with this Mac's unconfirmed sends after them.
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
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                .clipped()
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 6) {
                        if model.messagesMore && !model.messages.isEmpty {
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
                .onAppear { proxy.scrollTo("bottom", anchor: .bottom) }
                .onChange(of: model.messages.first?.id) { _ in proxy.scrollTo("bottom", anchor: .bottom) }
                .onChange(of: model.outgoing.count) { _ in proxy.scrollTo("bottom", anchor: .bottom) }
            }
        }
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
            case let .message(message, showsStatus):
                MessageBubble(message: message, model: model, actions: actions, showsStatus: showsStatus,
                              copied: copiedMessage == message.id,
                              sender: thread?.isGroup == true ? thread?.participants.first { $0.address == message.address }?.display : nil)
            case let .outgoing(item):
                OutgoingBubble(item: item, actions: actions)
            }
        }
    }
}

private enum ConversationItem: Identifiable {
    case day(Date)
    case message(SmsMessage, showsStatus: Bool)
    case outgoing(SmsOutgoing)

    var id: String {
        switch self {
        case let .day(date): "day-\(date.timeIntervalSince1970)"
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
    let sender: String?
    @Environment(\.brand) private var c

    private var mine: Bool { message.direction == .outgoing }

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
                Text(message.body + (message.truncated ? "\u{2026}" : ""))
                    .font(BrandFont.body(13))
                    .foregroundStyle(mine ? c.onpri : c.on)
                    .textSelection(.enabled)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(mine ? c.pri : c.s2))
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 6) {
                Text(message.sentAt, format: .dateTime.hour().minute()).font(BrandFont.body(10)).foregroundStyle(c.on2)
                if model.dualSim, let sim = model.sim(message.subId) { SimBadge(sim: sim) }
                if mine && (showsStatus || message.status == .failed) { statusLabel }
                if !mine && model.codesEnabled && looksLikeOtpTraffic(message.body) {
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
        .frame(maxWidth: 520, alignment: mine ? .trailing : .leading)
        .frame(maxWidth: .infinity, alignment: mine ? .trailing : .leading)
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
                note(L10n.text("sms.group", fallback: "Reply to group messages on your phone."))
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

    private func note(_ line: String) -> some View {
        Text(line).font(BrandFont.body(12)).foregroundStyle(c.on2)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
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
            Text(L10n.text("sms.new", fallback: "New message")).font(BrandFont.heading(16)).foregroundStyle(c.on)
                .padding(.horizontal, 20).padding(.top, 34).padding(.bottom, 12)
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
