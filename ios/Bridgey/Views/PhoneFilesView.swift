import SwiftUI
import UniformTypeIdentifiers

/// The phone's files: its places, then folders pushed one at a time, its photos and recent documents. Downloads land
/// in this device's received files (the Files app shows them); uploads go into the folder being browsed.
struct PhoneFilesView: View {
    let deviceID: String
    @EnvironmentObject private var files: PhoneFilesModel
    @Environment(\.brand) private var c

    var body: some View {
        Group {
            if let text = files.statusText {
                ScrollView {
                    CardShell {
                        HStack(alignment: .top, spacing: 12) {
                            IconTile(symbol: "folder.badge.questionmark", tint: .purple)
                            Text(text).font(.subheadline).foregroundStyle(c.on).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(16)
                    .frame(maxWidth: 720)
                    .frame(maxWidth: .infinity)
                    .accessibilityIdentifier("files.status")
                }
                .background(c.bg.ignoresSafeArea())
                .navigationTitle("Files")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar(.visible, for: .navigationBar)
            } else {
                PhoneLocationView(location: .places)
            }
        }
        .onAppear { files.show(deviceID) }
    }
}

/// One listing: the places, a folder, or a media list.
struct PhoneLocationView: View {
    let location: PhoneFilesModel.Location
    @EnvironmentObject private var files: PhoneFilesModel
    @Environment(\.brand) private var c
    @Environment(\.brandReduceMotion) private var reduce
    @State private var picking = false
    @State private var confirm: PhoneFilesModel.Item?

    private var listing: PhoneFilesModel.Listing? { files.listings[location] }

    var body: some View {
        content
            .background(c.bg.ignoresSafeArea())
            .navigationTitle(location.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar(.visible, for: .navigationBar)
            .toolbar { toolbar }
            .fileImporter(isPresented: $picking, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
                if case let .success(urls) = result { files.upload(urls, to: location) }
            }
            .confirmationDialog(confirm?.name ?? "", isPresented: Binding(get: { confirm != nil }, set: { if !$0 { confirm = nil } }), titleVisibility: .visible) {
                if let item = confirm {
                    Button("Download") { files.download([item]) }
                        .accessibilityIdentifier("files.confirmDownload")
                }
            } message: {
                Text("It goes to On My \(UIDevice.current.localizedModel) › Bridgey in the Files app.")
            }
            .overlay(alignment: .top) { FeatureNotice(text: $files.notice) }
            .refreshable { await files.load(location) }
            .onAppear { if listing == nil || listing?.error != nil { files.load(location) } }
            .animation(BrandMotion.animation(BrandMotion.effects, reduce: reduce), value: files.transfers)
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        if case .folder = location {
            ToolbarItemGroup(placement: .primaryAction) {
                Menu {
                    Picker("Sort by", selection: Binding(get: { files.sort }, set: { files.sort = $0; files.resort() })) {
                        ForEach(PhoneFilesModel.Sort.allCases) { Text($0.title).tag($0) }
                    }
                } label: { Image(systemName: "arrow.up.arrow.down") }
                    .accessibilityLabel("Sort")
                if listing?.writable == true {
                    Button { picking = true } label: { Image(systemName: "plus") }
                        .accessibilityLabel("Add files here")
                        .accessibilityIdentifier("files.upload")
                }
            }
        }
    }

    @ViewBuilder private var content: some View {
        if location == .photos {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    TransferCards()
                    state
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 104), spacing: 4)], spacing: 4) {
                        ForEach(listing?.items ?? []) { item in
                            PhotoCell(item: item) { confirm = item }
                                .onAppear { if item.id == listing?.items.last?.id { files.loadMore(location) } }
                        }
                    }
                }
                .padding(16)
                .frame(maxWidth: 900)
                .frame(maxWidth: .infinity)
            }
        } else {
            List {
                TransferCards()
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
                state.listRowBackground(Color.clear)
                if location == .places, let listing {
                    placesRows(listing)
                } else {
                    ForEach(listing?.items ?? []) { item in
                        row(item)
                            .listRowBackground(c.s1)
                            .onAppear { if item.id == listing?.items.last?.id { files.loadMore(location) } }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
        }
    }

    /// Loading, an error, or an empty folder: one line.
    @ViewBuilder private var state: some View {
        if let error = listing?.error {
            Text(error).font(.subheadline).foregroundStyle(c.warn).accessibilityIdentifier("files.error")
        } else if listing?.loading ?? true, listing?.items.isEmpty ?? true {
            HStack(spacing: 12) {
                ProgressView()
                Text("Asking the phone…").font(.subheadline).foregroundStyle(c.on2)
            }
        } else if listing?.items.isEmpty == true, location != .places {
            Text(emptyText).font(.subheadline).foregroundStyle(c.on2)
        }
    }

    private var emptyText: LocalizedStringKey {
        switch location {
        case .photos: "No photos or videos."
        case .documents: "No documents."
        case .recent: "Nothing recent."
        default: "This folder is empty."
        }
    }

    @ViewBuilder private func placesRows(_ listing: PhoneFilesModel.Listing) -> some View {
        Section {
            ForEach(listing.items) { place in
                NavigationLink {
                    PhoneLocationView(location: .folder(placeID: place.placeID ?? "", path: "", title: place.name))
                } label: {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(place.name).font(.body.weight(.semibold)).foregroundStyle(c.on)
                            if !place.placeAvailable {
                                Text("Not available").font(.caption).foregroundStyle(c.on2)
                            } else if let free = place.freeBytes, free > 0 {
                                Text("\(ByteCountFormatter.file(UInt64(free))) free").font(.caption).foregroundStyle(c.on2)
                            }
                        }
                    } icon: { IconTile(symbol: "folder.fill", tint: .blue) }
                }
                .disabled(!place.placeAvailable)
                .accessibilityIdentifier("files.place")
            }
        }
        .listRowBackground(c.s1)
        if listing.media || listing.documents {
            Section {
                if listing.media {
                    NavigationLink { PhoneLocationView(location: .photos) } label: {
                        Label { Text("Photos and videos").font(.body.weight(.semibold)) } icon: { IconTile(symbol: "photo.on.rectangle", tint: .green) }
                    }
                    .accessibilityIdentifier("files.photos")
                }
                if listing.documents {
                    NavigationLink { PhoneLocationView(location: .documents) } label: {
                        Label { Text("Documents").font(.body.weight(.semibold)) } icon: { IconTile(symbol: "doc.text", tint: .purple) }
                    }
                }
                NavigationLink { PhoneLocationView(location: .recent) } label: {
                    Label { Text("Recent").font(.body.weight(.semibold)) } icon: { IconTile(symbol: "clock", tint: .neutral) }
                }
            }
            .listRowBackground(c.s1)
        }
    }

    @ViewBuilder private func row(_ item: PhoneFilesModel.Item) -> some View {
        if item.kind == .folder, case let .folder(place, path, title) = location {
            NavigationLink {
                PhoneLocationView(location: .folder(placeID: place, path: path.isEmpty ? item.name : "\(path)/\(item.name)", title: title))
            } label: {
                FileRow(item: item)
            }
            .contextMenu {
                Button { files.download([item]) } label: { Label("Download folder", systemImage: "arrow.down.circle") }
            }
            .accessibilityIdentifier("files.folder")
        } else {
            Button { confirm = item } label: {
                HStack(spacing: 8) {
                    FileRow(item: item)
                    Spacer(minLength: 0)
                    Image(systemName: "arrow.down.circle").font(.title3).foregroundStyle(c.tbi).accessibilityHidden(true)
                }
            }
            .buttonStyle(.plain)
            .contextMenu {
                Button { files.download([item]) } label: { Label("Download", systemImage: "arrow.down.circle") }
            }
            .accessibilityHint("Downloads it to this \(UIDevice.current.localizedModel).")
            .accessibilityIdentifier("files.file")
        }
    }
}

private struct FileRow: View {
    let item: PhoneFilesModel.Item
    @EnvironmentObject private var files: PhoneFilesModel
    @Environment(\.brand) private var c

    var body: some View {
        HStack(spacing: 12) {
            Thumb(item: item, size: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.name).font(.body.weight(.semibold)).foregroundStyle(c.on).lineLimit(2).truncationMode(.middle)
                if let detail = PhoneFileText.detail(item) {
                    Text(detail).font(.caption).foregroundStyle(c.on2).lineLimit(1)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// A thumbnail when the phone sent one, else a symbol for the kind of file.
private struct Thumb: View {
    let item: PhoneFilesModel.Item
    var size: CGFloat
    @EnvironmentObject private var files: PhoneFilesModel

    var body: some View {
        if let image = files.thumbnails[item.id] {
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
                .frame(width: size, height: size)
                .clipShape(RoundedRectangle(cornerRadius: size * 0.22, style: .continuous))
                .accessibilityHidden(true)
        } else {
            IconTile(symbol: PhoneFileText.symbol(item), tint: item.kind == .folder ? .blue : item.isImageOrVideo ? .green : .neutral, size: size)
        }
    }
}

private struct PhotoCell: View {
    let item: PhoneFilesModel.Item
    let tap: () -> Void
    @EnvironmentObject private var files: PhoneFilesModel
    @Environment(\.brand) private var c

    var body: some View {
        Button(action: tap) {
            Color.clear
                .aspectRatio(1, contentMode: .fit)
                .overlay {
                    if let image = files.thumbnails[item.id] {
                        Image(uiImage: image).resizable().scaledToFill()
                    } else {
                        ZStack {
                            c.s2
                            Image(systemName: PhoneFileText.symbol(item)).font(.title2).foregroundStyle(c.on2)
                        }
                    }
                }
                .overlay(alignment: .bottomTrailing) {
                    if let ms = item.durationMs, ms > 0 {
                        Text(Duration.milliseconds(ms).formatted(.time(pattern: .minuteSecond)))
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.white)
                            .padding(4)
                            .shadow(radius: 2)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(PressScaleStyle())
        .contextMenu {
            Button { files.download([item]) } label: { Label("Download", systemImage: "arrow.down.circle") }
        }
        .accessibilityLabel(item.name)
        .accessibilityHint("Downloads it to this \(UIDevice.current.localizedModel).")
        .accessibilityIdentifier("files.photo")
    }
}

/// Downloads and uploads under way or just finished.
private struct TransferCards: View {
    @EnvironmentObject private var files: PhoneFilesModel
    @Environment(\.brand) private var c

    var body: some View {
        if !files.transfers.isEmpty {
            VStack(spacing: 8) {
                ForEach(files.transfers) { t in
                    CardShell {
                        HStack(spacing: 12) {
                            IconTile(symbol: t.download ? "arrow.down.doc" : "arrow.up.doc", tint: t.failed ? .purple : t.download ? .green : .blue)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(heading(t))
                                    .font(.subheadline.weight(.semibold)).foregroundStyle(c.on).lineLimit(1).truncationMode(.middle)
                                if !t.detail.isEmpty {
                                    Text(t.detail).font(.caption).foregroundStyle(t.failed ? c.warn : c.on2).monospacedDigit()
                                }
                            }
                            Spacer(minLength: 0)
                            Button { t.running ? files.cancel(t) : files.clear(t) } label: {
                                Image(systemName: t.running ? "xmark.circle.fill" : "xmark").font(t.running ? .title3 : .footnote.weight(.semibold))
                                    .foregroundStyle(c.on2).frame(width: 32, height: 32)
                            }
                            .accessibilityLabel(t.running ? "Cancel" : "Dismiss")
                        }
                        if t.running {
                            ProgressView(value: t.progress).tint(c.pri)
                        } else if t.download, !t.failed {
                            Button("Show in Files") {
                                if let url = URL(string: "shareddocuments://\(SharedStorage.receivedFiles.path)") { UIApplication.shared.open(url) }
                            }
                            .buttonStyle(PillButtonStyle(kind: .tonal))
                        }
                    }
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("files.transfer")
                }
            }
        }
    }
}

extension TransferCards {
    func heading(_ t: PhoneFilesModel.Transfer) -> String {
        guard t.running else { return t.title }
        return t.download ? String(localized: "Downloading \(t.title)") : String(localized: "Adding \(t.title)")
    }
}

enum PhoneFileText {
    /// "2.1 MB · 3 Nov" for a file, the date for a folder.
    static func detail(_ item: PhoneFilesModel.Item) -> String? {
        var parts: [String] = []
        if item.kind == .file, let size = item.size { parts.append(ByteCountFormatter.file(UInt64(max(0, size)))) }
        if let modified = item.modified, modified > 0 { parts.append(MessagesModel.when(modified)) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    static func symbol(_ item: PhoneFilesModel.Item) -> String {
        if item.kind == .folder { return "folder.fill" }
        let mime = item.mimeType ?? ""
        if mime.hasPrefix("image/") { return "photo" }
        if mime.hasPrefix("video/") { return "film" }
        if mime.hasPrefix("audio/") { return "waveform" }
        if mime == "application/pdf" { return "doc.richtext" }
        if mime.hasPrefix("text/") { return "doc.text" }
        if mime.contains("zip") || mime.contains("compressed") { return "doc.zipper" }
        return "doc"
    }
}
