import AVKit
import AppKit
import SwiftUI
import UniformTypeIdentifiers

// Files 2.0: the Phone files window. A sidebar of sections like Telegram's attach sheet (Photos and Videos,
// Files, Folders with the phone's granted places, Recent from phone), a toolbar, the content, and a status
// strip for downloads and uploads. Pure SwiftUI on Stream tokens so it renders in screenshots; the AppKit
// interaction layer (clicks, hover, file promises, menus) sits over each cell only in the live window.

struct PhoneFilesWindowView: View {
    @ObservedObject var model: PhoneFilesModel
    let promises: PhoneFilePromises
    var quickLook: ([PhoneFileEntry]) -> Void = { _ in }
    var showInFinder: (URL) -> Void = { NSWorkspace.shared.activateFileViewerSelecting([$0]) }
    @Environment(\.brand) private var c

    static let size = CGSize(width: 1000, height: 660)

    var body: some View {
        HStack(spacing: 0) {
            PhoneFilesSidebar(model: model)
                .frame(width: 220)
            Rectangle().fill(c.ol).frame(width: 1)
            VStack(spacing: 0) {
                PhoneFilesToolbar(model: model, quickLook: quickLook, showInFinder: showInFinder)
                Rectangle().fill(c.olv).frame(height: 1)
                PhoneFilesContent(model: model, promises: promises, quickLook: quickLook, showInFinder: showInFinder)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                PhoneFilesStatusStrip(model: model)
            }
            .background(c.bg)
        }
        .overlay {
            if model.preview != nil {
                PhonePreviewOverlay(model: model, quickLook: quickLook, showInFinder: showInFinder)
                    .transition(.opacity)
            }
        }
        .frame(minWidth: 760, minHeight: 480)
    }
}

// MARK: - Sidebar

private struct PhoneFilesSidebar: View {
    @ObservedObject var model: PhoneFilesModel
    @Environment(\.brand) private var c

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            PopUpMenuButton(items: phoneItems) {
                HStack(spacing: 10) {
                    DeviceRingView(state: model.phone == nil ? .offline : .connected, platform: "android", size: 32)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(model.phone?.name ?? L10n.text("phonefiles.noPhone", fallback: "No phone connected"))
                            .font(BrandFont.body(13, .semibold))
                            .foregroundStyle(c.on)
                            .lineLimit(1)
                        Text(phoneDetail)
                            .font(BrandFont.body(11))
                            .foregroundStyle(c.on2)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    if model.phones.count > 1 {
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(c.on2)
                    }
                }
                .padding(.horizontal, 10)
                .frame(height: 52)
                .contentShape(Rectangle())
            }
            .padding(.top, 34)
            .padding(.bottom, 8)
            ForEach(PhoneFilesSection.allCases) { section in
                SidebarRow(symbol: PhoneFilesText.sectionSymbol(section), title: PhoneFilesText.sectionTitle(section),
                           selected: model.section == section && (section != .folders || model.placeID == nil)) {
                    if section == .folders { model.open(place: nil) } else { model.section = section }
                }
                .disabled(model.phone?.browsable != true)
                if section == .folders, let places = model.info?.places, !places.isEmpty {
                    ForEach(places) { place in
                        SidebarRow(symbol: place.available ? "folder" : "folder.badge.questionmark", title: place.label,
                                   selected: model.section == .folders && model.placeID == place.id, indent: true, dimmed: !place.available) {
                            model.open(place: place.id)
                        }
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(c.s1)
    }

    private var phoneDetail: String {
        guard let phone = model.phone else { return L10n.text("phonefiles.connectHint", fallback: "Connect a phone to browse it") }
        if !phone.browsable { return L10n.text("phonefiles.browseOff", fallback: "Browsing is off") }
        switch phone.route {
        case .lan: return L10n.text("phonefiles.route.lan", fallback: "Same network")
        case .relay: return L10n.text("phonefiles.route.relay", fallback: "Through the relay")
        case .unknown: return L10n.text("phonefiles.route.connected", fallback: "Connected")
        }
    }

    private func phoneItems() -> [PopUpMenuItem] {
        model.phones.map { phone in
            PopUpMenuItem(title: phone.name, checked: phone.id == model.phoneID) { model.select(phone: phone.id) }
        }
    }
}

private struct SidebarRow: View {
    let symbol: String
    let title: String
    let selected: Bool
    var indent = false
    var dimmed = false
    let action: () -> Void
    @Environment(\.brand) private var c
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: symbol)
                    .font(.system(size: indent ? 12 : 14, weight: .medium))
                    .foregroundStyle(selected ? c.tbi : c.on2)
                    .frame(width: 20)
                Text(title)
                    .font(BrandFont.body(indent ? 12 : 13, selected ? .semibold : .medium))
                    .foregroundStyle(selected ? c.on : (dimmed ? c.on2 : c.on))
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.leading, indent ? 28 : 10)
            .padding(.trailing, 10)
            .frame(height: indent ? 28 : 34)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(selected ? c.tb : Color.clear))
            .contentShape(Rectangle())
            .opacity(enabled ? 1 : 0.45)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Toolbar

private struct PhoneFilesToolbar: View {
    @ObservedObject var model: PhoneFilesModel
    let quickLook: ([PhoneFileEntry]) -> Void
    let showInFinder: (URL) -> Void
    @Environment(\.brand) private var c

    var body: some View {
        HStack(spacing: 8) {
            title
            Spacer(minLength: 8)
            if model.section == .folders, model.placeID != nil {
                PopUpMenuButton(items: sortItems) {
                    HStack(spacing: 5) {
                        Image(systemName: model.descending ? "arrow.down" : "arrow.up")
                            .font(.system(size: 10, weight: .bold))
                        Text(PhoneFilesText.sortTitle(model.sort))
                            .font(BrandFont.body(12, .medium))
                    }
                    .foregroundStyle(c.on)
                    .padding(.horizontal, 10)
                    .frame(height: 28)
                    .background(Capsule().fill(c.s3))
                }
                .help(L10n.text("phonefiles.sort.help", fallback: "Sort"))
            }
            Button {
                quickLook(model.selectedEntries.filter(PhoneFilesText.quickLookable))
            } label: { Image(systemName: "eye") }
                .buttonStyle(PillButtonStyle(kind: .neutral, height: 28))
                .disabled(!model.selectedEntries.contains(where: PhoneFilesText.quickLookable))
                .help(L10n.text("phonefiles.quickLook", fallback: "Quick Look (Space)"))
            if let url = model.selectedEntries.count == 1 ? model.savedURL(model.selectedEntries[0]) : nil {
                Button(L10n.text("phonefiles.showInFinder", fallback: "Show in Finder")) { showInFinder(url) }
                    .buttonStyle(PillButtonStyle(kind: .neutral, height: 28))
            }
            Button(L10n.text("phonefiles.download", fallback: "Download")) { model.downloadSelection() }
                .buttonStyle(PillButtonStyle(kind: .tonal, height: 28))
                .disabled(model.selection.isEmpty)
                .help(L10n.text("phonefiles.download.help", fallback: "Save to Received files"))
            Button { model.refresh() } label: { Image(systemName: "arrow.clockwise") }
                .buttonStyle(PillButtonStyle(kind: .neutral, height: 28))
                .disabled(model.phone?.browsable != true)
                .help(L10n.text("phonefiles.refresh", fallback: "Refresh"))
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .frame(height: 62)
    }

    @ViewBuilder private var title: some View {
        if model.section == .folders, let place = model.place {
            HStack(spacing: 4) {
                crumb(place.label, depth: -1, last: model.path.isEmpty)
                ForEach(Array(model.path.enumerated()), id: \.offset) { index, name in
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(c.on2)
                    crumb(name, depth: index, last: index == model.path.count - 1)
                }
            }
            .lineLimit(1)
        } else {
            Text(PhoneFilesText.sectionTitle(model.section))
                .font(BrandFont.heading(18))
                .foregroundStyle(c.on)
        }
    }

    private func crumb(_ title: String, depth: Int, last: Bool) -> some View {
        Button { model.goTo(depth: depth) } label: {
            Text(title)
                .font(last ? BrandFont.heading(18) : BrandFont.body(14, .medium))
                .foregroundStyle(last ? c.on : c.on2)
                .truncationMode(.middle)
        }
        .buttonStyle(.plain)
        .disabled(last)
    }

    private func sortItems() -> [PopUpMenuItem] {
        PhoneFileSort.allCases.map { sort in
            PopUpMenuItem(title: PhoneFilesText.sortTitle(sort), checked: sort == model.sort) { model.setSort(sort) }
        }
    }
}

// MARK: - Content

private struct PhoneFilesContent: View {
    @ObservedObject var model: PhoneFilesModel
    let promises: PhoneFilePromises
    let quickLook: ([PhoneFileEntry]) -> Void
    let showInFinder: (URL) -> Void
    @Environment(\.brand) private var c

    var body: some View {
        if model.phone == nil {
            PhoneFilesMessage(symbol: "smartphone", title: L10n.text("phonefiles.noPhone", fallback: "No phone connected"),
                              detail: L10n.text("phonefiles.noPhone.detail", fallback: "Connect your phone to see its photos, documents and folders here."))
        } else if model.phone?.browsable != true {
            PhoneFilesMessage(symbol: "lock", title: L10n.text("phonefiles.browseOff.title", fallback: "Browsing is off on this phone"),
                              detail: PhoneFilesText.notBrowsable(model.phoneName))
        } else {
            VStack(spacing: 0) {
                banners
                main
            }
        }
    }

    @ViewBuilder private var banners: some View {
        let listing = model.currentListing
        if model.section == .folders, model.placeID != nil, listing.loaded, !listing.writable {
            PhoneFilesBanner(symbol: "lock", text: String(format: L10n.text("phonefiles.readOnly", fallback: "Turn on Allow other devices to change files here on %@ to add files."), model.phoneName))
        }
        if model.section == .media || model.section == .recent, listing.loaded, listing.access == .partial {
            PhoneFilesBanner(symbol: "photo.badge.checkmark", text: String(format: L10n.text("phonefiles.media.partial", fallback: "Showing the photos you chose on %@. Allow all photos there to see everything."), model.phoneName))
        }
        if model.section == .files || model.section == .recent, listing.indexing {
            PhoneFilesBanner(symbol: "arrow.triangle.2.circlepath", text: String(format: L10n.text("phonefiles.indexing", fallback: "%@ is updating its list of documents."), model.phoneName))
        }
    }

    @ViewBuilder private var main: some View {
        let listing = model.currentListing
        if model.section == .folders, model.placeID == nil {
            PlacesGrid(model: model)
        } else if let error = listing.error, listing.entries.isEmpty {
            PhoneFilesMessage(symbol: "exclamationmark.triangle", title: L10n.text("phonefiles.error.title", fallback: "Couldn't load this"),
                              detail: PhoneFilesText.error(error, phone: model.phoneName),
                              button: L10n.text("action.retry", fallback: "Retry"), action: model.refresh)
        } else if listing.entries.isEmpty, !listing.loaded {
            ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if listing.entries.isEmpty {
            emptyState
        } else {
            switch model.section {
            case .media:
                PhoneMediaGrid(model: model, promises: promises, quickLook: quickLook, showInFinder: showInFinder, now: model.displayNow ?? Date())
            case .files, .recent, .folders:
                PhoneFileList(model: model, promises: promises, quickLook: quickLook, showInFinder: showInFinder, now: model.displayNow ?? Date())
            }
        }
    }

    @ViewBuilder private var emptyState: some View {
        switch model.section {
        case .media:
            if model.currentListing.access == .none {
                PhoneFilesMessage(symbol: "photo.on.rectangle", title: L10n.text("phonefiles.media.none.title", fallback: "Photos are not shared yet"),
                                  detail: String(format: L10n.text("phonefiles.media.none", fallback: "Open Bridgey on %@ and allow Photos and videos to see them here."), model.phoneName))
            } else {
                PhoneFilesMessage(symbol: "photo.on.rectangle", title: L10n.text("phonefiles.media.empty", fallback: "No photos or videos"), detail: nil)
            }
        case .files:
            if model.info?.documents == false {
                PhoneFilesMessage(symbol: "doc.text", title: L10n.text("phonefiles.files.none.title", fallback: "No document folders yet"),
                                  detail: String(format: L10n.text("phonefiles.files.none", fallback: "On %@, open Bridgey and let it see your documents (Settings, Files, Places)."), model.phoneName))
            } else {
                PhoneFilesMessage(symbol: "doc.text", title: L10n.text("phonefiles.files.empty", fallback: "No recent documents"), detail: nil)
            }
        case .folders:
            PhoneFilesMessage(symbol: "folder", title: L10n.text("phonefiles.folder.empty", fallback: "This folder is empty"),
                              detail: model.writable ? L10n.text("phonefiles.folder.empty.drop", fallback: "Drop files here to add them.") : nil)
        case .recent:
            PhoneFilesMessage(symbol: "clock", title: L10n.text("phonefiles.recent.empty", fallback: "Nothing recent"), detail: nil)
        }
    }
}

private struct PhoneFilesBanner: View {
    let symbol: String
    let text: String
    @Environment(\.brand) private var c

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(c.tbi)
            Text(text)
                .font(BrandFont.body(12))
                .foregroundStyle(c.on)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(c.tb))
        .padding(.horizontal, 16)
        .padding(.top, 10)
    }
}

struct PhoneFilesMessage: View {
    let symbol: String
    let title: String
    let detail: String?
    var button: String?
    var action: () -> Void = {}
    @Environment(\.brand) private var c

    var body: some View {
        VStack(spacing: 10) {
            IconTile(symbol: symbol, tint: .blue, size: 44, corner: 12)
            Text(title)
                .font(BrandFont.heading(16))
                .foregroundStyle(c.on)
            if let detail {
                Text(detail)
                    .font(BrandFont.body(13))
                    .foregroundStyle(c.on2)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 380)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let button {
                Button(button, action: action).buttonStyle(PillButtonStyle(kind: .tonal, height: 30))
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// A vertical scroller that becomes a clipped stack in screenshots (ImageRenderer cannot draw scroll views).
private struct PhoneScroll<Content: View>: View {
    @ViewBuilder let content: Content
    @Environment(\.snapshotRendering) private var snapshot

    var body: some View {
        if snapshot {
            VStack(spacing: 0) { content }
                .fixedSize(horizontal: false, vertical: true)
                .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity, alignment: .top)
                .clipped()
        } else {
            ScrollView(.vertical) { content }
        }
    }
}

// MARK: - Places

private struct PlacesGrid: View {
    @ObservedObject var model: PhoneFilesModel
    @Environment(\.brand) private var c

    var body: some View {
        if let places = model.info?.places, !places.isEmpty {
            PhoneScroll {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 200, maximum: 260), spacing: 12)], spacing: 12) {
                    ForEach(places) { place in
                        Button { model.open(place: place.id) } label: { PlaceCard(place: place) }
                            .buttonStyle(.plain)
                            .disabled(!place.available)
                    }
                }
                .padding(16)
            }
        } else if model.infoError != nil {
            PhoneFilesMessage(symbol: "exclamationmark.triangle", title: L10n.text("phonefiles.error.title", fallback: "Couldn't load this"),
                              detail: model.infoError.map { PhoneFilesText.error($0, phone: model.phoneName) },
                              button: L10n.text("action.retry", fallback: "Retry"), action: model.refresh)
        } else {
            ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

private struct PlaceCard: View {
    let place: PhonePlace
    @Environment(\.brand) private var c

    var body: some View {
        HStack(spacing: 12) {
            IconTile(symbol: place.available ? "folder.fill" : "folder.badge.questionmark", tint: place.available ? .blue : .neutral, size: 40, corner: 11)
            VStack(alignment: .leading, spacing: 2) {
                Text(place.label)
                    .font(BrandFont.body(13, .semibold))
                    .foregroundStyle(c.on)
                    .lineLimit(1)
                Text(detail)
                    .font(BrandFont.body(11))
                    .foregroundStyle(place.available ? c.on2 : c.warn)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(c.s2))
        .opacity(place.available ? 1 : 0.6)
    }

    private var detail: String {
        guard place.available else { return L10n.text("phonefiles.place.unavailable", fallback: "Not available") }
        guard let free = place.freeBytes else { return L10n.text("phonefiles.place.available", fallback: "On the phone") }
        return String(format: L10n.text("phonefiles.place.free", fallback: "%@ free"), PhoneFilesText.size(free))
    }
}

// MARK: - Media grid

struct PhoneMediaGrid: View {
    @ObservedObject var model: PhoneFilesModel
    let promises: PhoneFilePromises
    let quickLook: ([PhoneFileEntry]) -> Void
    let showInFinder: (URL) -> Void
    var now = Date()
    static let cell: CGFloat = 118

    var body: some View {
        let entries = model.currentEntries
        let groups = Self.groups(entries, now: now)
        PhoneScroll {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: Self.cell, maximum: Self.cell + 24), spacing: 4)], spacing: 4, pinnedViews: []) {
                ForEach(groups, id: \.title) { group in
                    Section {
                        ForEach(group.entries) { entry in
                            MediaCell(entry: entry, model: model, promises: promises, quickLook: quickLook, showInFinder: showInFinder,
                                      isLast: entry.id == entries.last?.id)
                        }
                    } header: {
                        DayHeader(title: group.title)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 16)
        }
    }

    struct Group {
        let title: String
        let entries: [PhoneFileEntry]
    }

    /// Consecutive entries of the same day share a header (entries arrive newest first).
    static func groups(_ entries: [PhoneFileEntry], now: Date) -> [Group] {
        var groups: [Group] = []
        var current: [PhoneFileEntry] = []
        var title: String?
        var seen = Set<String>()
        for entry in entries {
            let day = entry.modified.map { PhoneFilesText.day($0, now: now) } ?? L10n.text("phonefiles.day.unknown", fallback: "Earlier")
            if day != title, let title, !current.isEmpty {
                groups.append(Group(title: seen.contains(title) ? title + " " : title, entries: current))
                seen.insert(title)
                current = []
            }
            title = day
            current.append(entry)
        }
        if let title, !current.isEmpty { groups.append(Group(title: seen.contains(title) ? title + " " : title, entries: current)) }
        return groups
    }
}

private struct DayHeader: View {
    let title: String
    @Environment(\.brand) private var c

    var body: some View {
        Text(title.trimmingCharacters(in: .whitespaces))
            .font(BrandFont.body(13, .semibold))
            .foregroundStyle(c.on)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 14)
            .padding(.bottom, 6)
    }
}

private struct MediaCell: View {
    let entry: PhoneFileEntry
    @ObservedObject var model: PhoneFilesModel
    let promises: PhoneFilePromises
    let quickLook: ([PhoneFileEntry]) -> Void
    let showInFinder: (URL) -> Void
    let isLast: Bool
    @State private var hovering = false
    @Environment(\.brand) private var c
    @Environment(\.snapshotRendering) private var snapshot

    var body: some View {
        let selected = model.selection.contains(entry.id)
        PhoneThumbnailView(box: model.thumbnails.box(for: entry), symbol: PhoneFilesText.symbol(entry), corner: 6)
            .aspectRatio(1, contentMode: .fill)
            .frame(minWidth: 0, maxWidth: .infinity)
            .overlay(alignment: .bottomTrailing) {
                if let duration = PhoneFilesText.duration(entry.durationMs) {
                    HStack(spacing: 3) {
                        Image(systemName: "play.fill").font(.system(size: 8, weight: .bold))
                        Text(duration).font(BrandFont.body(11, .semibold).monospacedDigit())
                    }
                    .foregroundStyle(Color.white)
                    .padding(.horizontal, 6)
                    .frame(height: 18)
                    .background(Capsule().fill(Color.black.opacity(0.55)))
                    .padding(5)
                }
            }
            .overlay(alignment: .topTrailing) {
                if selected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(c.onpri, c.pri)
                        .padding(5)
                }
            }
            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(selected ? c.pri : (hovering ? c.ol : Color.clear), lineWidth: selected ? 3 : 1))
            .overlay { if !snapshot { interaction } }
            .onAppear {
                model.thumbnails.appeared(entry)
                if isLast { model.loadMore() }
            }
            .onDisappear { model.thumbnails.disappeared(entry) }
            .accessibilityElement()
            .accessibilityLabel(entry.name)
            .accessibilityAddTraits(selected ? [.isSelected, .isImage] : .isImage)
    }

    private var interaction: some View {
        PhoneItemInteraction(actions: PhoneItemActions(
            click: { command, shift in model.click(entry, command: command, shift: shift) },
            activate: { model.activate(entry) },
            hover: { inside in
                hovering = inside
                if inside { model.prefetch.hoverBegan(entry) } else { model.prefetch.hoverEnded(entry) }
            },
            dragEntries: { model.targets(for: entry) },
            menu: { PhoneItemMenus.menu(for: entry, model: model, quickLook: quickLook, showInFinder: showInFinder) }
        ), promises: promises)
    }
}

/// A thumbnail: the tint (or a neutral surface) first, then the image fading in by opacity.
struct PhoneThumbnailView: View {
    @ObservedObject var box: ThumbnailBox
    let symbol: String
    var corner: CGFloat = 6
    @Environment(\.brand) private var c
    @Environment(\.brandReduceMotion) private var reduce

    var body: some View {
        ZStack {
            placeholder
            if let image = box.image {
                Image(decorative: image.image, scale: 1)
                    .resizable()
                    .interpolation(.medium)
                    .scaledToFill()
                    .transition(.opacity)
            }
        }
        .animation(box.arrived && !reduce ? BrandMotion.effects : nil, value: box.image != nil)
        .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
        .contentShape(Rectangle())
    }

    @ViewBuilder private var placeholder: some View {
        if let tint = box.tint {
            Color(hex: tint)
        } else {
            ZStack {
                c.s3
                Image(systemName: symbol)
                    .font(.system(size: 18, weight: .regular))
                    .foregroundStyle(c.on2.opacity(0.6))
            }
        }
    }
}

// MARK: - File list

struct PhoneFileList: View {
    @ObservedObject var model: PhoneFilesModel
    let promises: PhoneFilePromises
    let quickLook: ([PhoneFileEntry]) -> Void
    let showInFinder: (URL) -> Void
    var now = Date()
    @Environment(\.brand) private var c

    var body: some View {
        let entries = model.currentEntries
        VStack(spacing: 0) {
            ListHeader(model: model)
            PhoneScroll {
                LazyVStack(spacing: 0) {
                    ForEach(entries) { entry in
                        FileRow(entry: entry, model: model, promises: promises, quickLook: quickLook, showInFinder: showInFinder,
                                showsLocation: model.section != .folders, now: now, isLast: entry.id == entries.last?.id)
                    }
                    if model.currentListing.loading, model.currentListing.loaded {
                        ProgressView().controlSize(.small).padding(10)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 12)
            }
        }
        .modifier(UploadDrop(model: model))
    }
}

private struct ListHeader: View {
    @ObservedObject var model: PhoneFilesModel
    @Environment(\.brand) private var c

    var body: some View {
        HStack(spacing: 12) {
            column(.name, title: PhoneFilesText.sortTitle(.name)).frame(maxWidth: .infinity, alignment: .leading)
            column(.modified, title: PhoneFilesText.sortTitle(.modified)).frame(width: 150, alignment: .leading)
            column(.size, title: PhoneFilesText.sortTitle(.size)).frame(width: 80, alignment: .trailing)
            column(.kind, title: PhoneFilesText.sortTitle(.kind)).frame(width: 120, alignment: .leading)
        }
        .padding(.leading, 60)
        .padding(.trailing, 20)
        .frame(height: 30)
        .overlay(alignment: .bottom) { Rectangle().fill(c.olv).frame(height: 1) }
    }

    @ViewBuilder private func column(_ sort: PhoneFileSort, title: String) -> some View {
        let sortable = model.section == .folders
        Button { if sortable { model.setSort(sort) } } label: {
            HStack(spacing: 4) {
                Text(title)
                if sortable, model.sort == sort {
                    Image(systemName: model.descending ? "chevron.down" : "chevron.up").font(.system(size: 8, weight: .bold))
                }
            }
            .font(BrandFont.body(11, .semibold))
            .foregroundStyle(sortable && model.sort == sort ? c.on : c.on2)
        }
        .buttonStyle(.plain)
        .disabled(!sortable)
    }
}

private struct FileRow: View {
    let entry: PhoneFileEntry
    @ObservedObject var model: PhoneFilesModel
    let promises: PhoneFilePromises
    let quickLook: ([PhoneFileEntry]) -> Void
    let showInFinder: (URL) -> Void
    let showsLocation: Bool
    let now: Date
    let isLast: Bool
    @State private var hovering = false
    @Environment(\.brand) private var c
    @Environment(\.snapshotRendering) private var snapshot

    var body: some View {
        let selected = model.selection.contains(entry.id)
        HStack(spacing: 12) {
            Group {
                if entry.hasThumbnail {
                    PhoneThumbnailView(box: model.thumbnails.box(for: entry), symbol: PhoneFilesText.symbol(entry), corner: 6)
                } else {
                    IconTile(symbol: PhoneFilesText.symbol(entry), tint: entry.isDirectory ? .blue : .neutral, size: 36, corner: 8)
                }
            }
            .frame(width: 36, height: 36)
            VStack(alignment: .leading, spacing: 1) {
                Text(entry.name)
                    .font(BrandFont.body(13, .medium))
                    .foregroundStyle(c.on)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if showsLocation, let location = entry.location, !location.isEmpty {
                    Text(location)
                        .font(BrandFont.body(11))
                        .foregroundStyle(c.on2)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text(PhoneFilesText.date(entry.modified, now: now))
                .frame(width: 150, alignment: .leading)
            Text(entry.isDirectory ? "" : PhoneFilesText.size(entry.size))
                .monospacedDigit()
                .frame(width: 80, alignment: .trailing)
            Text(PhoneFilesText.kind(entry))
                .frame(width: 120, alignment: .leading)
        }
        .font(BrandFont.body(12))
        .foregroundStyle(c.on2)
        .lineLimit(1)
        .padding(.horizontal, 12)
        .frame(height: 48)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(selected ? c.tb : (hovering ? c.s2 : Color.clear)))
        .overlay { if !snapshot { interaction } }
        .onAppear {
            model.thumbnails.appeared(entry)
            if isLast { model.loadMore() }
        }
        .onDisappear { model.thumbnails.disappeared(entry) }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var interaction: some View {
        PhoneItemInteraction(actions: PhoneItemActions(
            click: { command, shift in model.click(entry, command: command, shift: shift) },
            activate: { model.activate(entry) },
            hover: { inside in
                hovering = inside
                if inside { model.prefetch.hoverBegan(entry) } else { model.prefetch.hoverEnded(entry) }
            },
            dragEntries: { model.targets(for: entry) },
            menu: { PhoneItemMenus.menu(for: entry, model: model, quickLook: quickLook, showInFinder: showInFinder) }
        ), promises: promises)
    }
}

/// Files dropped from Finder on the open folder go to the phone (only while it allows changes).
private struct UploadDrop: ViewModifier {
    @ObservedObject var model: PhoneFilesModel
    @Environment(\.brand) private var c
    @Environment(\.snapshotRendering) private var snapshot

    func body(content: Content) -> some View {
        let enabled = model.section == .folders && model.placeID != nil
        content
            .overlay {
                if model.dropTargeted {
                    PhoneDropHighlight(model: model)
                        .allowsHitTesting(false)
                }
            }
            .modifier(OptionalDrop(enabled: enabled && !snapshot, targeted: $model.dropTargeted) { urls in model.upload(urls) })
    }
}

struct PhoneDropHighlight: View {
    @ObservedObject var model: PhoneFilesModel
    @Environment(\.brand) private var c

    var body: some View {
        let folder = model.path.last ?? model.place?.label ?? ""
        ZStack {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(c.tb.opacity(0.6))
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(model.writable ? c.pri : c.warn, style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
            VStack(spacing: 8) {
                Image(systemName: model.writable ? "square.and.arrow.down.on.square" : "lock")
                    .font(.system(size: 28, weight: .medium))
                    .foregroundStyle(model.writable ? c.tbi : c.warn)
                Text(model.writable
                     ? String(format: L10n.text("phonefiles.drop.add", fallback: "Drop to add to %1$@ on %2$@"), folder, model.phoneName)
                     : String(format: L10n.text("phonefiles.readOnly", fallback: "Turn on Allow other devices to change files here on %@ to add files."), model.phoneName))
                    .font(BrandFont.body(14, .semibold))
                    .foregroundStyle(c.on)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 360)
            }
        }
        .padding(10)
    }
}

private struct OptionalDrop: ViewModifier {
    let enabled: Bool
    @Binding var targeted: Bool
    let perform: ([URL]) -> Bool

    func body(content: Content) -> some View {
        if enabled {
            content.onDrop(of: [.fileURL], isTargeted: $targeted) { providers in
                let group = DispatchGroup()
                var urls: [URL] = []
                let lock = NSLock()
                for provider in providers {
                    group.enter()
                    _ = provider.loadObject(ofClass: URL.self) { url, _ in
                        if let url, url.isFileURL {
                            lock.lock(); urls.append(url); lock.unlock()
                        }
                        group.leave()
                    }
                }
                group.notify(queue: .main) { _ = perform(urls) }
                return true
            }
        } else {
            content
        }
    }
}

// MARK: - Menus

@MainActor
enum PhoneItemMenus {
    static func menu(for entry: PhoneFileEntry, model: PhoneFilesModel, quickLook: @escaping ([PhoneFileEntry]) -> Void,
                     showInFinder: @escaping (URL) -> Void) -> NSMenu {
        let targets = model.targets(for: entry)
        var items: [(String, Bool, () -> Void)] = []
        if entry.isDirectory {
            items.append((L10n.text("phonefiles.open", fallback: "Open"), true, { model.enter(entry) }))
        } else {
            items.append((L10n.text("phonefiles.preview", fallback: "Preview"), true, { model.openPreview(entry) }))
            items.append((L10n.text("phonefiles.quickLook.short", fallback: "Quick Look"), targets.contains(where: PhoneFilesText.quickLookable),
                          { quickLook(targets.filter(PhoneFilesText.quickLookable)) }))
        }
        items.append((L10n.text("phonefiles.download", fallback: "Download"), true, {
            model.selection = Set(targets.map(\.id))
            model.downloadSelection()
        }))
        if let url = model.savedURL(entry) {
            items.append((L10n.text("phonefiles.showInFinder", fallback: "Show in Finder"), true, { showInFinder(url) }))
        }
        return PhoneItemMenu.make(items)
    }
}

// MARK: - Status strip

private struct PhoneFilesStatusStrip: View {
    @ObservedObject var model: PhoneFilesModel
    @Environment(\.brand) private var c

    var body: some View {
        HStack(spacing: 12) {
            if let activity = model.activities.last {
                Image(systemName: activity.kind == .upload ? "arrow.up.circle" : "arrow.down.circle")
                    .foregroundStyle(c.tbi)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(PhoneFilesText.activityTitle(activity))
                            .font(BrandFont.body(12, .medium))
                            .foregroundStyle(c.on)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Text(PhoneFilesText.progress(activity.progress))
                            .font(BrandFont.body(11).monospacedDigit())
                            .foregroundStyle(c.on2)
                            .lineLimit(1)
                        if model.activities.count > 1 {
                            Text(String(format: L10n.text("phonefiles.activity.more", fallback: "+%d more"), model.activities.count - 1))
                                .font(BrandFont.body(11))
                                .foregroundStyle(c.on2)
                        }
                    }
                    UpdateProgressBar(progress: activity.progress.phase == .transferring ? activity.progress.fraction : nil)
                        .frame(maxWidth: 320)
                }
                Spacer(minLength: 0)
                Button(L10n.text("action.cancel", fallback: "Cancel")) { model.cancel(activity: activity.id) }
                    .buttonStyle(PillButtonStyle(kind: .neutral, height: 24))
            } else if let notice = model.notice {
                Text(notice)
                    .font(BrandFont.body(12))
                    .foregroundStyle(c.on)
                    .lineLimit(2)
                Spacer(minLength: 0)
            } else {
                Text(summary)
                    .font(BrandFont.body(12))
                    .foregroundStyle(c.on2)
                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, 16)
        .frame(height: 44)
        .background(c.s1)
        .overlay(alignment: .top) { Rectangle().fill(c.olv).frame(height: 1) }
    }

    private var summary: String {
        let listing = model.currentListing
        if !model.selection.isEmpty {
            let bytes = model.selectedEntries.reduce(Int64(0)) { $0 + ($1.size ?? 0) }
            return String(format: L10n.text("phonefiles.selected", fallback: "%1$d selected, %2$@"), model.selection.count, PhoneFilesText.size(bytes))
        }
        if model.section == .folders, model.placeID != nil, listing.loaded {
            return String(format: L10n.text("phonefiles.counts", fallback: "%1$d folders, %2$d files"), listing.folderCount, listing.fileCount)
        }
        if listing.loaded, !listing.entries.isEmpty {
            return String(format: L10n.text("phonefiles.shown", fallback: "%d items"), listing.entries.count)
        }
        return ""
    }
}

// MARK: - Preview

struct PhonePreviewOverlay: View {
    @ObservedObject var model: PhoneFilesModel
    let quickLook: ([PhoneFileEntry]) -> Void
    let showInFinder: (URL) -> Void
    @State private var player: AVPlayer?
    @Environment(\.brand) private var c
    @Environment(\.snapshotRendering) private var snapshot

    var body: some View {
        if let state = model.preview {
            VStack(spacing: 0) {
                header(state)
                ZStack {
                    if let player, !snapshot {
                        VideoPlayer(player: player)
                    } else if let image = model.previewImage {
                        Image(decorative: image.image, scale: 1)
                            .resizable()
                            .interpolation(.high)
                            .scaledToFit()
                            .padding(24)
                    } else if let error = state.error {
                        PhoneFilesMessage(symbol: "photo", title: L10n.text("phonefiles.preview.none", fallback: "No preview"),
                                          detail: PhoneFilesText.error(error, phone: model.phoneName))
                    } else if !state.entry.hasThumbnail {
                        PhoneFilesMessage(symbol: PhoneFilesText.symbol(state.entry), title: state.entry.name,
                                          detail: PhoneFilesText.kind(state.entry) + ", " + PhoneFilesText.size(state.entry.size))
                    } else {
                        ProgressView().controlSize(.small)
                    }
                    if state.entry.isVideo, player == nil, model.previewImage != nil {
                        Button { play(state.entry) } label: {
                            Image(systemName: "play.fill")
                                .font(.system(size: 26, weight: .bold))
                                .foregroundStyle(BrandPalette.midnight)
                                .frame(width: 64, height: 64)
                                .background(Circle().fill(BrandPalette.aurora))
                        }
                        .buttonStyle(PressScaleStyle())
                        .help(L10n.text("phonefiles.play", fallback: "Play"))
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                if let progress = state.originalProgress {
                    HStack(spacing: 10) {
                        Text(PhoneFilesText.progress(progress))
                            .font(BrandFont.body(11).monospacedDigit())
                            .foregroundStyle(c.on2)
                        UpdateProgressBar(progress: progress.phase == .transferring ? progress.fraction : nil)
                            .frame(width: 220)
                    }
                    .padding(.bottom, 14)
                }
            }
            .background(c.bg.opacity(0.97))
            .onDisappear {
                player?.pause()
                player = nil
            }
        }
    }

    private func header(_ state: PhonePreviewState) -> some View {
        HStack(spacing: 10) {
            Button { model.closePreview() } label: {
                Image(systemName: "xmark").font(.system(size: 12, weight: .bold)).frame(width: 28, height: 28)
            }
            .buttonStyle(PillButtonStyle(kind: .neutral, height: 28))
            .help(L10n.text("action.close", fallback: "Close"))
            VStack(alignment: .leading, spacing: 1) {
                Text(state.entry.name)
                    .font(BrandFont.body(14, .semibold))
                    .foregroundStyle(c.on)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text([PhoneFilesText.size(state.entry.size), PhoneFilesText.date(state.entry.modified, now: model.displayNow ?? Date()), dimensions(state.entry)]
                    .filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(BrandFont.body(11))
                    .foregroundStyle(c.on2)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            if PhoneFilesText.quickLookable(state.entry) {
                Button(L10n.text("phonefiles.quickLook.short", fallback: "Quick Look")) { quickLook([state.entry]) }
                    .buttonStyle(PillButtonStyle(kind: .neutral, height: 28))
            }
            if let url = model.savedURL(state.entry) {
                Button(L10n.text("phonefiles.showInFinder", fallback: "Show in Finder")) { showInFinder(url) }
                    .buttonStyle(PillButtonStyle(kind: .neutral, height: 28))
            }
            Button(L10n.text("phonefiles.download", fallback: "Download")) {
                model.selection = [state.entry.id]
                model.downloadSelection()
            }
            .buttonStyle(PillButtonStyle(kind: .tonal, height: 28))
        }
        .padding(.horizontal, 16)
        .padding(.top, 34)
        .padding(.bottom, 10)
    }

    private func dimensions(_ entry: PhoneFileEntry) -> String {
        var parts: [String] = []
        if let width = entry.width, let height = entry.height { parts.append("\(width) × \(height)") }
        if let duration = PhoneFilesText.duration(entry.durationMs) { parts.append(duration) }
        return parts.joined(separator: " · ")
    }

    private func play(_ entry: PhoneFileEntry) {
        model.fetchOriginal(entry) { url in
            let next = AVPlayer(url: url)
            player = next
            next.play()
        }
    }
}
