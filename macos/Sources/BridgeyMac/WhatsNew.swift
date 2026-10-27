import AppKit
import Combine
import SwiftUI

/*
 * What's new: shown once after an update, from the release notes the Updates card already
 * parses (kept when Sparkle offered the update), or the notes bundled with the app when the
 * offer was never seen. Never after a fresh install, never twice for one build.
 */

enum WhatsNewDecision: Equatable {
    /// Show it; `reviewSetup` adds the Review setup button (an update from before v0.10 setup).
    case show(reviewSetup: Bool)
    /// Do not show; `record` stores this build as seen so it is never considered again.
    case skip(record: Bool)
}

enum WhatsNewLogic {
    /// - Parameters:
    ///   - currentBuild: CFBundleVersion, which only grows from release to release.
    ///   - lastBuild: the build that last showed (or skipped) What's new; nil before this existed.
    ///   - freshInstall: setup runs for the first time on this Mac.
    ///   - hasNotes: release notes for this version were found.
    ///   - reviewSetup: the user came from a version before this setup.
    static func decide(currentBuild: Int, lastBuild: Int?, freshInstall: Bool, hasNotes: Bool, reviewSetup: Bool) -> WhatsNewDecision {
        if freshInstall { return .skip(record: true) }
        if let lastBuild {
            if lastBuild == currentBuild { return .skip(record: false) }
            // A downgrade: the newer build's notes were seen already; going back up shows nothing again.
            if lastBuild > currentBuild { return .skip(record: false) }
        }
        if !hasNotes && !reviewSetup { return .skip(record: true) }
        return .show(reviewSetup: reviewSetup)
    }
}

/// What's new's own UserDefaults keys (`whatsNew.`).
struct WhatsNewStore {
    let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    static let lastBuildKey = "whatsNew.lastBuild"
    static let lastVersionKey = "whatsNew.lastVersion"
    static let offeredNotesKey = "whatsNew.offeredNotes"
    static let maximumOffered = 4

    var lastBuild: Int? { defaults.object(forKey: Self.lastBuildKey) as? Int }

    func record(build: Int, version: String) {
        defaults.set(build, forKey: Self.lastBuildKey)
        defaults.set(version, forKey: Self.lastVersionKey)
    }

    /// The notes Sparkle offered with an update, by version, so the new build can show them.
    func rememberOffered(version: String, notes: String) {
        var offered = defaults.dictionary(forKey: Self.offeredNotesKey) as? [String: String] ?? [:]
        offered[version] = String(notes.prefix(16_384))
        // Keep the newest few versions only (versions sort well enough for this bound).
        if offered.count > Self.maximumOffered {
            for key in offered.keys.sorted().prefix(offered.count - Self.maximumOffered) { offered.removeValue(forKey: key) }
        }
        defaults.set(offered, forKey: Self.offeredNotesKey)
    }

    func offeredNotes(version: String) -> String? {
        (defaults.dictionary(forKey: Self.offeredNotesKey) as? [String: String])?[version]
    }

    /// The feed's notes for `version`, else the notes bundled in the app (build-app.sh copies
    /// BRIDGEY_RELEASE_NOTES_FILE to Resources/release-notes.md).
    func notes(version: String, bundled: String?) -> String? {
        let text = offeredNotes(version: version) ?? bundled
        guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return text
    }

    static func bundledNotes(_ bundle: Bundle = .main) -> String? {
        guard let url = bundle.url(forResource: "release-notes", withExtension: "md") else { return nil }
        return try? String(contentsOf: url, encoding: .utf8)
    }
}

/// What the What's new window shows.
struct WhatsNewContent: Equatable {
    var version: String
    var blocks: [ReleaseNoteBlock]
    var reviewSetup: Bool
    var notesURL: URL = SettingsLinks.releases

    static func make(version: String, notes: String?, reviewSetup: Bool) -> WhatsNewContent {
        WhatsNewContent(version: version, blocks: notes.map { ReleaseNotes.blocks($0, version: version) } ?? [], reviewSetup: reviewSetup)
    }
}

// MARK: - View

struct WhatsNewView: View {
    let content: WhatsNewContent
    var onReviewSetup: () -> Void = {}
    var onOpenNotes: () -> Void = {}
    var onDone: () -> Void = {}
    @Environment(\.brand) private var c

    static let size = CGSize(width: 520, height: 560)

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 14) {
                AuroraMark(size: 44)
                VStack(alignment: .leading, spacing: 2) {
                    Text(L10n.setup("whatsNew.title", fallback: "What\u{2019}s new"))
                        .font(BrandFont.heading(24))
                        .foregroundStyle(c.on)
                        .accessibilityAddTraits(.isHeader)
                    Text(String(format: L10n.setup("whatsNew.version", fallback: "Bridgey %@"), content.version))
                        .font(BrandFont.body(13))
                        .foregroundStyle(c.on2)
                }
            }
            .padding(.top, 40)
            .padding(.bottom, 20)
            BoundedScroll {
                VStack(alignment: .leading, spacing: 14) {
                    if content.reviewSetup {
                        ReviewSetupCard(onReview: onReviewSetup)
                    }
                    if content.blocks.isEmpty {
                        Text(L10n.setup("whatsNew.noNotes", fallback: "The notes for this version are on the releases page."))
                            .font(BrandFont.body(13))
                            .foregroundStyle(c.on2)
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        ReleaseNoteBlocks(blocks: content.blocks)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.bottom, 8)
            }
            HStack(spacing: 10) {
                Button(L10n.setup("whatsNew.fullNotes", fallback: "Full release notes"), action: onOpenNotes)
                    .buttonStyle(PillButtonStyle(kind: .outline, height: 32))
                Spacer()
                Button(L10n.setup("whatsNew.gotIt", fallback: "Got it"), action: onDone)
                    .buttonStyle(PillButtonStyle(kind: content.reviewSetup ? .tonal : .gradient, height: 32))
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.vertical, 20)
        }
        .padding(.horizontal, 32)
        .frame(width: Self.size.width, height: Self.size.height)
        .background(c.bg)
    }
}

/// "Bridgey has a new setup" with Review setup: for people who updated from before v0.10.
private struct ReviewSetupCard: View {
    let onReview: () -> Void
    @Environment(\.brand) private var c

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            IconTile(symbol: "checklist", tint: .purple, size: 32, corner: 10)
            VStack(alignment: .leading, spacing: 4) {
                Text(L10n.setup("whatsNew.review.title", fallback: "Review your setup"))
                    .font(BrandFont.body(14, .semibold))
                    .foregroundStyle(c.on)
                Text(L10n.setup("whatsNew.review.detail", fallback: "Go through each feature with its current value. Nothing changes unless you change it."))
                    .font(BrandFont.body(12))
                    .foregroundStyle(c.on2)
                    .fixedSize(horizontal: false, vertical: true)
                Button(L10n.setup("whatsNew.review.action", fallback: "Review setup"), action: onReview)
                    .buttonStyle(PillButtonStyle(kind: .gradient, height: 30))
                    .padding(.top, 6)
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(c.s1))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(c.olv, lineWidth: 1))
    }
}

/// Release notes in full: headings, bullets and paragraphs, as the Updates card draws them.
struct ReleaseNoteBlocks: View {
    let blocks: [ReleaseNoteBlock]
    @Environment(\.brand) private var c

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                switch block {
                case let .heading(text):
                    Text(inline(text))
                        .font(BrandFont.body(12, .semibold))
                        .foregroundStyle(c.on2)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 6)
                case let .bullet(text):
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Circle().fill(c.pri).frame(width: 5, height: 5).alignmentGuide(.firstTextBaseline) { $0[.bottom] + 2 }
                        Text(inline(text))
                            .font(BrandFont.body(13))
                            .foregroundStyle(c.on)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                case let .paragraph(text):
                    Text(inline(text))
                        .font(BrandFont.body(13))
                        .foregroundStyle(c.on)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .textSelection(.enabled)
    }

    private func inline(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text)
    }
}

/// The once-only panel banner for people who updated from before v0.10 setup.
struct SetupReviewBanner: View {
    let onOpen: () -> Void
    let onDismiss: () -> Void
    @Environment(\.brand) private var c

    var body: some View {
        HStack(spacing: 10) {
            IconTile(symbol: "sparkles", tint: .purple, size: 28, corner: 8)
            Button(action: onOpen) {
                Text(L10n.setup("panel.review", fallback: "See what\u{2019}s new and review your setup"))
                    .font(BrandFont.body(12, .semibold))
                    .foregroundStyle(c.on)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(c.on2)
                    .frame(width: 22, height: 22)
                    .background(Circle().fill(c.s3))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(L10n.setup("action.dismiss", fallback: "Dismiss"))
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(c.tp))
    }
}
