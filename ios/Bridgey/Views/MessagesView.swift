import SwiftUI

/// The phone's conversations, unread first. Pushed from the Messages action on iPhone; in the detail column on iPad.
struct MessagesView: View {
    let deviceID: String
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var messages: MessagesModel
    @Environment(\.brand) private var c
    @Environment(\.brandReduceMotion) private var reduce
    @State private var composing = false

    private var device: DeviceItem? { model.device(deviceID) }

    var body: some View {
        Group {
            if let device, !device.messagesOn {
                TurnOnCard(name: device.name) { messages.turnOn() }
            } else {
                list
            }
        }
        .background(c.bg.ignoresSafeArea())
        .navigationTitle("Messages")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .toolbar {
            if device?.messagesOn == true {
                ToolbarItemGroup(placement: .primaryAction) {
                    Button { messages.unreadOnly.toggle() } label: {
                        Image(systemName: messages.unreadOnly ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
                    }
                    .accessibilityLabel(messages.unreadOnly ? "Show all conversations" : "Show unread only")
                    .accessibilityIdentifier("messages.filter")
                    Button { composing = true } label: { Image(systemName: "square.and.pencil") }
                        .disabled(!messages.status.canSend)
                        .accessibilityLabel("New message")
                        .accessibilityIdentifier("messages.new")
                }
            }
        }
        .sheet(isPresented: $composing) { NewMessageView(deviceID: deviceID) }
        .overlay(alignment: .top) { FeatureNotice(text: $messages.notice) }
        .onAppear { messages.show(deviceID) }
        .onChange(of: device?.messagesOn) { if device?.messagesOn == true { messages.show(deviceID) } }
        .onChange(of: device?.connected) { if device?.connected == true { messages.show(deviceID) } }
    }

    private var list: some View {
        List {
            if let text = messages.statusText {
                Text(text)
                    .font(.subheadline)
                    .foregroundStyle(c.on2)
                    .listRowBackground(Color.clear)
                    .accessibilityIdentifier("messages.status")
            }
            ForEach(messages.conversations) { conversation in
                NavigationLink {
                    ConversationView(deviceID: deviceID, threadID: conversation.threadID)
                } label: {
                    ConversationRow(conversation: conversation)
                }
                .listRowBackground(c.s1)
                .swipeActions(edge: .leading) {
                    if conversation.unread > 0 {
                        Button { messages.markRead(conversation) } label: { Label("Mark as read", systemImage: "envelope.open") }.tint(.blue)
                    } else {
                        Button { messages.markUnread(conversation) } label: { Label("Mark as unread", systemImage: "envelope.badge") }.tint(.blue)
                    }
                }
                .contextMenu {
                    if conversation.unread > 0 {
                        Button { messages.markRead(conversation) } label: { Label("Mark as read", systemImage: "envelope.open") }
                    } else {
                        Button { messages.markUnread(conversation) } label: { Label("Mark as unread", systemImage: "envelope.badge") }
                    }
                    if !conversation.group, !conversation.address.isEmpty {
                        Button { messages.blockOnPhone(conversation) } label: { Label("Block on phone", systemImage: "hand.raised") }
                    }
                }
                .accessibilityIdentifier("messages.conversation")
            }
            if messages.moreConversations {
                Button("Show older conversations") { messages.loadOlder() }
                    .listRowBackground(c.s1)
            }
            if messages.conversations.isEmpty, messages.statusText == nil {
                HStack(spacing: 12) {
                    if messages.loadingConversations || messages.status.syncing { ProgressView() }
                    Text(messages.loadingConversations || messages.status.syncing
                         ? String(localized: "Getting conversations…")
                         : (messages.unreadOnly ? String(localized: "No unread conversations.") : String(localized: "No conversations yet.")))
                        .font(.subheadline)
                        .foregroundStyle(c.on2)
                }
                .listRowBackground(Color.clear)
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .refreshable { await messages.refresh() }
        .animation(BrandMotion.animation(BrandMotion.effects, reduce: reduce), value: messages.conversations.map(\.id))
    }
}

/// Text messages is off for this phone here: one line and the switch.
private struct TurnOnCard: View {
    let name: String
    let turnOn: () -> Void
    @Environment(\.brand) private var c

    var body: some View {
        ScrollView {
            CardShell {
                HStack(alignment: .top, spacing: 12) {
                    IconTile(symbol: "message", tint: .blue)
                    Text("See and answer \(name)’s texts here while Bridgey is open.")
                        .font(.subheadline)
                        .foregroundStyle(c.on)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Button("Turn on Text messages", action: turnOn)
                    .buttonStyle(PillButtonStyle(kind: .gradient, fill: true))
                    .accessibilityIdentifier("messages.turnOn")
            }
            .padding(16)
            .frame(maxWidth: 720)
            .frame(maxWidth: .infinity)
        }
    }
}

private struct ConversationRow: View {
    let conversation: MessagesModel.Conversation
    @Environment(\.brand) private var c

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Initial(title: conversation.title, group: conversation.group)
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline) {
                    Text(conversation.title)
                        .font(.body.weight(conversation.unread > 0 ? .bold : .semibold))
                        .foregroundStyle(c.on)
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    Text(MessagesModel.when(conversation.date))
                        .font(.caption)
                        .foregroundStyle(conversation.unread > 0 ? c.tbi : c.on2)
                }
                HStack(alignment: .top) {
                    Text(conversation.snippet.isEmpty ? String(localized: "Picture") : conversation.snippet)
                        .font(.subheadline)
                        .foregroundStyle(conversation.unread > 0 ? c.on : c.on2)
                        .lineLimit(2)
                    Spacer(minLength: 8)
                    if conversation.unread > 0 {
                        Circle().fill(c.pri).frame(width: 10, height: 10).padding(.top, 5).accessibilityHidden(true)
                    }
                }
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(label)
    }

    private var label: String {
        var parts = [conversation.title]
        if conversation.unread > 0 { parts.append(String(localized: "Unread")) }
        parts.append(conversation.snippet.isEmpty ? String(localized: "Picture") : conversation.snippet)
        parts.append(MessagesModel.when(conversation.date))
        return parts.joined(separator: ", ")
    }
}

/// A round initial for a contact, or people for a group.
private struct Initial: View {
    let title: String
    let group: Bool
    @Environment(\.brand) private var c

    var body: some View {
        ZStack {
            Circle().fill(c.tp)
            if group {
                Image(systemName: "person.2.fill").font(.system(size: 15, weight: .semibold)).foregroundStyle(c.tpi)
            } else if let letter = title.first(where: \.isLetter) {
                Text(String(letter).uppercased()).font(.headline).foregroundStyle(c.tpi)
            } else {
                Image(systemName: "person.fill").font(.system(size: 15, weight: .semibold)).foregroundStyle(c.tpi)
            }
        }
        .frame(width: 40, height: 40)
        .accessibilityHidden(true)
    }
}

/// One conversation: its messages, oldest at the top, and a reply.
struct ConversationView: View {
    let deviceID: String
    let threadID: Int64
    @EnvironmentObject private var messages: MessagesModel
    @Environment(\.brand) private var c
    @Environment(\.brandReduceMotion) private var reduce
    @State private var draft = ""
    @State private var sim: Int64?
    @FocusState private var focused: Bool

    private var conversation: MessagesModel.Conversation? { messages.conversations.first { $0.threadID == threadID } }

    var body: some View {
        ScrollViewReader { scroller in
            ScrollView {
                LazyVStack(spacing: 8) {
                    if messages.olderMessages {
                        Button("Show older messages") { messages.loadOlderMessages() }
                            .buttonStyle(PillButtonStyle(kind: .neutral))
                            .padding(.bottom, 4)
                    }
                    ForEach(messages.messages) { row in
                        MessageBubble(row: row)
                            .id(row.id)
                            .transition(BrandMotion.arrival(reduce: reduce))
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .frame(maxWidth: 720)
                .frame(maxWidth: .infinity)
                .animation(BrandMotion.animation(BrandMotion.pop, reduce: reduce), value: messages.messages.map(\.id))
            }
            .defaultScrollAnchor(.bottom)
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: messages.messages.last?.id) {
                if let last = messages.messages.last?.id {
                    withAnimation(BrandMotion.animation(BrandMotion.page, reduce: reduce)) { scroller.scrollTo(last, anchor: .bottom) }
                }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { composer }
        .background(c.bg.ignoresSafeArea())
        .navigationTitle(conversation?.title ?? "")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .overlay(alignment: .top) { FeatureNotice(text: $messages.notice) }
        .onAppear { messages.open(threadID) }
        .onDisappear { messages.close(threadID) }
    }

    @ViewBuilder private var composer: some View {
        VStack(alignment: .leading, spacing: 8) {
            if conversation?.group == true {
                Text("Group conversations are answered on the phone.")
                    .font(.footnote)
                    .foregroundStyle(c.on2)
            } else {
                if messages.sims.count > 1 {
                    SimMenu(sims: messages.sims, selection: $sim)
                }
                ComposerField(draft: $draft, placeholder: "Text message", enabled: messages.canSend, focused: $focused) {
                    if messages.send(draft, thread: threadID, sim: sim) { draft = "" }
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 8)
        .frame(maxWidth: 720)
        .frame(maxWidth: .infinity)
        .background(c.bg.ignoresSafeArea(edges: .bottom))
        .overlay(alignment: .top) { Rectangle().fill(c.olv).frame(height: 1) }
    }
}

/// The SIM a text goes from, when the phone has more than one.
private struct SimMenu: View {
    let sims: [MessagesModel.Sim]
    @Binding var selection: Int64?
    @Environment(\.brand) private var c

    var body: some View {
        Menu {
            ForEach(sims) { sim in
                Button(sim.label) { selection = sim.subID }
            }
        } label: {
            HStack(spacing: 4) {
                Text("From \((sims.first { $0.subID == selection } ?? sims[0]).label)")
                Image(systemName: "chevron.up.chevron.down").font(.caption2)
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(c.on2)
        }
        .onAppear { if selection == nil { selection = sims.first?.subID } }
    }
}

/// The text field and the send button, as in the home's send bar.
private struct ComposerField: View {
    @Binding var draft: String
    let placeholder: LocalizedStringKey
    let enabled: Bool
    var focused: FocusState<Bool>.Binding
    let send: () -> Void
    @Environment(\.brand) private var c

    private var empty: Bool { draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField(placeholder, text: $draft, axis: .vertical)
                .lineLimit(1...5)
                .focused(focused)
                .padding(.horizontal, 14)
                .padding(.vertical, 11)
                .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(c.s2))
                .foregroundStyle(c.on)
                .disabled(!enabled)
                .accessibilityIdentifier("messages.field")
            Button(action: send) {
                Image(systemName: "arrow.up").font(.body.weight(.bold)).foregroundStyle(BrandPalette.midnight).frame(width: 44, height: 44)
                    .background(Circle().fill(BrandPalette.aurora))
            }
            .buttonStyle(PressScaleStyle())
            .disabled(empty || !enabled || draft.count > 2_000)
            .opacity(empty ? 0.5 : 1)
            .accessibilityLabel("Send")
            .accessibilityIdentifier("messages.send")
        }
    }
}

private struct MessageBubble: View {
    let row: MessagesModel.MessageRow
    @EnvironmentObject private var messages: MessagesModel
    @Environment(\.brand) private var c

    var body: some View {
        HStack {
            if !row.incoming { Spacer(minLength: 48) }
            VStack(alignment: row.incoming ? .leading : .trailing, spacing: 4) {
                VStack(alignment: .leading, spacing: 6) {
                    if let part = row.partID { picture(part) }
                    if !row.body.isEmpty {
                        Text(row.body)
                            .font(.body)
                            .foregroundStyle(c.on)
                            .textSelection(.enabled)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(row.incoming ? c.s2 : c.tb))
                Text(meta)
                    .font(.caption2)
                    .foregroundStyle(row.state == .failed ? c.warn : c.on2)
                if row.canRetry {
                    HStack(spacing: 8) {
                        Button("Try again") { messages.retry(row) }.buttonStyle(PillButtonStyle(kind: .tonal))
                        Button("Discard") { messages.discard(row) }.buttonStyle(PillButtonStyle(kind: .outline))
                    }
                }
            }
            if row.incoming { Spacer(minLength: 48) }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(label)
        .accessibilityIdentifier("messages.bubble")
    }

    @ViewBuilder private func picture(_ part: String) -> some View {
        if let image = messages.images[part] {
            Image(uiImage: image)
                .resizable()
                .scaledToFit()
                .frame(maxWidth: 240, maxHeight: 240)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .accessibilityLabel("Picture")
        } else {
            HStack(spacing: 8) {
                Image(systemName: messages.failedImages.contains(part) ? "photo.badge.exclamationmark" : "photo")
                Text(messages.failedImages.contains(part) ? "Picture not available" : "Picture")
            }
            .font(.subheadline)
            .foregroundStyle(c.on2)
        }
    }

    private var stateText: String? {
        switch row.state {
        case .none: nil
        case .sending: String(localized: "Sending…")
        case .sent: String(localized: "Sent")
        case .delivered: String(localized: "Delivered")
        case .failed: String(localized: "Not sent")
        }
    }

    private var meta: String {
        let time = MessagesModel.when(row.date)
        guard let stateText else { return time }
        return time.isEmpty ? stateText : "\(time) · \(stateText)"
    }

    private var label: String {
        let who = row.incoming ? String(localized: "Received") : String(localized: "Sent")
        let picture = row.partID != nil ? String(localized: "Picture.") + " " : ""
        return "\(who), \(meta). \(picture)\(row.body)"
    }
}

/// A new message to a number, or to a contact the phone finds by name.
struct NewMessageView: View {
    let deviceID: String
    @EnvironmentObject private var messages: MessagesModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.brand) private var c
    @State private var to = ""
    @State private var draft = ""
    @State private var sim: Int64?
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            List {
                Section {
                    TextField("Name or number", text: $to)
                        .textContentType(.telephoneNumber)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.words)
                        .accessibilityIdentifier("messages.to")
                        .onChange(of: to) { messages.searchContacts(to) }
                    ForEach(messages.contacts) { contact in
                        Button {
                            to = contact.address
                            messages.clearContacts()
                            focused = true
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(contact.name).font(.body.weight(.semibold)).foregroundStyle(c.on)
                                Text(contact.label.map { "\($0) · \(contact.address)" } ?? contact.address)
                                    .font(.caption).foregroundStyle(c.on2)
                            }
                        }
                        .accessibilityIdentifier("messages.contact")
                    }
                }
                .listRowBackground(c.s1)
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                VStack(alignment: .leading, spacing: 8) {
                    if messages.sims.count > 1 { SimMenu(sims: messages.sims, selection: $sim) }
                    ComposerField(draft: $draft, placeholder: "Text message",
                                  enabled: messages.status.canSend && !to.trimmingCharacters(in: .whitespaces).isEmpty, focused: $focused) {
                        if messages.send(draft, address: to, sim: sim) { dismiss() }
                    }
                }
                .padding(16)
                .background(c.bg.ignoresSafeArea(edges: .bottom))
            }
            .background(c.bg.ignoresSafeArea())
            .navigationTitle("New message")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
            .overlay(alignment: .top) { FeatureNotice(text: $messages.notice) }
            .onDisappear { messages.clearContacts() }
        }
    }
}

/// A short message about what just happened, at the top, gone after a few seconds (as the home's notice).
struct FeatureNotice: View {
    @Binding var text: String?
    @Environment(\.brand) private var c
    @Environment(\.brandReduceMotion) private var reduce

    var body: some View {
        ZStack {
            if let notice = text {
                Text(notice)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(c.on)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .background(Capsule().fill(c.s3).shadow(color: .black.opacity(c.isDark ? 0.4 : 0.12), radius: 12, y: 4))
                    .padding(.horizontal, 24)
                    .padding(.top, 8)
                    .onTapGesture { text = nil }
                    .transition(reduce ? .opacity : .move(edge: .top).combined(with: .opacity))
                    .task(id: notice) {
                        try? await Task.sleep(for: .seconds(5))
                        if text == notice { text = nil }
                    }
                    .onAppear { UIAccessibility.post(notification: .announcement, argument: notice) }
                    .accessibilityIdentifier("feature.notice")
            }
        }
        .animation(BrandMotion.animation(BrandMotion.pop, reduce: reduce), value: text)
    }
}
