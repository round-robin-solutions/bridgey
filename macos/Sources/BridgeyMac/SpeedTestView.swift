import AppKit
import SwiftUI

/// A connected phone that can run the speed test.
struct SpeedPhone: Identifiable, Equatable {
    let id: String
    let name: String
}

/// Settings > Privacy > Transfer speed (SpeedTest.swift): pick a phone, run the test, read the result in plain
/// words, copy it without names or addresses.
struct SpeedTestCard: View {
    let phones: [SpeedPhone]
    @ObservedObject private var test = SpeedTest.shared
    @State private var chosen: String?
    @Environment(\.brand) private var c

    private var target: SpeedPhone? {
        phones.first { $0.id == chosen } ?? phones.first
    }

    private var running: Bool {
        switch test.phase {
        case .connecting, .roundTrips, .sending, .receiving: true
        default: false
        }
    }

    var body: some View {
        SettingsCard(title: L10n.text("speed.title", fallback: "Transfer speed"),
                     footnote: L10n.text("speed.note", fallback: "About 7 seconds of test data each way over your real connection, encrypted like your files. Nothing is saved on either device.")) {
            SettingsRow(title: L10n.text("speed.run", fallback: "Test transfer speed"), subtitle: subtitle, divider: false) {
                if phones.count > 1, !running {
                    ChoiceButton(value: target?.name ?? "") {
                        phones.map { phone in PopUpMenuItem(title: phone.name, checked: phone.id == target?.id) { chosen = phone.id } }
                    }
                }
                if running {
                    Button(L10n.text("speed.stop", fallback: "Stop")) { test.cancel() }
                        .buttonStyle(PillButtonStyle(kind: .outline, height: 28))
                } else {
                    Button(L10n.text("speed.start", fallback: "Test")) { if let id = target?.id { test.start(with: id) } }
                        .buttonStyle(PillButtonStyle(kind: .tonal, height: 28))
                        .disabled(target == nil)
                }
            }
            if running {
                VStack(alignment: .leading, spacing: 6) {
                    ProgressView(value: test.progress)
                        .progressViewStyle(.linear)
                        .tint(c.pri)
                    Text(liveText)
                        .font(BrandFont.body(12))
                        .foregroundStyle(c.on2)
                        .monospacedDigit()
                }
                .padding(.bottom, 10)
            }
            if case let .failed(reason) = test.phase {
                Text(failureText(reason))
                    .font(BrandFont.body(12))
                    .foregroundStyle(c.warn)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.bottom, 10)
            }
            if test.phase == .finished, let report = test.report {
                SpeedReportView(report: report)
            }
        }
    }

    private var subtitle: String {
        if phones.isEmpty {
            return L10n.text("speed.noPhone", fallback: "Connect a phone with Bridgey 0.10 or later to test.")
        }
        return String(format: L10n.text("speed.with", fallback: "With %@, over the connection you use for files"), target?.name ?? "")
    }

    private var liveText: String {
        let rate = SpeedFormat.megabytes(test.liveBytesPerSecond)
        switch test.phase {
        case .connecting: return L10n.text("speed.phase.connecting", fallback: "Asking the phone\u{2026}")
        case .roundTrips: return L10n.text("speed.phase.roundTrips", fallback: "Measuring the round trip\u{2026}")
        case .sending: return String(format: L10n.text("speed.phase.sending", fallback: "Mac to phone: %@"), rate)
        case .receiving: return L10n.text("speed.phase.receiving", fallback: "Phone to Mac\u{2026}")
        default: return ""
        }
    }

    private func failureText(_ reason: String) -> String {
        switch reason {
        case "cancelled": return L10n.text("speed.failed.cancelled", fallback: "Stopped.")
        case "busy": return L10n.text("speed.failed.busy", fallback: "The phone is already running a speed test.")
        case "disconnected": return L10n.text("speed.failed.disconnected", fallback: "The phone disconnected during the test.")
        case "noAnswer": return L10n.text("speed.failed.noAnswer", fallback: "The phone did not answer. Open Bridgey on the phone and try again.")
        case "unavailable": return L10n.text("speed.failed.unavailable", fallback: "Could not reach the phone. Check that it is connected and try again.")
        default: return L10n.text("speed.failed", fallback: "The test stopped because data stopped arriving. Try again; on Wi-Fi, move closer to the router.")
        }
    }
}

enum SpeedFormat {
    static func megabytes(_ bytesPerSecond: Double) -> String {
        String(format: L10n.text("speed.mbps", fallback: "%.1f MB/s"), bytesPerSecond / 1_000_000)
    }

    static func link(_ link: SpeedLink?) -> String {
        guard let link else { return L10n.text("speed.link.unknown", fallback: "Not readable") }
        switch link.network {
        case "ethernet": return L10n.text("speed.link.ethernet", fallback: "Ethernet")
        case "other": return L10n.text("speed.link.other", fallback: "Not Wi-Fi or Ethernet")
        default: break
        }
        var parts: [String] = []
        if link.network == "hotspot" { parts.append(L10n.text("speed.link.hotspot", fallback: "Sharing its hotspot")) }
        if let standard = link.standard { parts.append("Wi-Fi \(standard)") } else if link.network == "wifi" { parts.append("Wi-Fi") }
        if let band = link.band { parts.append(String(format: L10n.text("speed.link.band", fallback: "%@ GHz"), band)) }
        if let width = link.widthMhz { parts.append(String(format: L10n.text("speed.link.width", fallback: "%d MHz"), width)) }
        if let mbps = link.linkMbps { parts.append(String(format: L10n.text("speed.link.rate", fallback: "%d Mbit/s"), mbps)) }
        return parts.joined(separator: ", ")
    }

    static func lock(_ link: SpeedLink?) -> String? {
        guard let held = link?.lockHeld else { return nil }
        if !held { return L10n.text("speed.lock.notHeld", fallback: "Wi-Fi power saving was not held off") }
        if link?.screenOn == false { return L10n.text("speed.lock.screenOff", fallback: "Wi-Fi power saving held off, but the screen was off, so Android may still save power") }
        return L10n.text("speed.lock.held", fallback: "Wi-Fi power saving held off for the test")
    }

    /// The verdict in plain words.
    static func verdict(_ verdict: SpeedVerdict) -> String {
        let low = Int(verdict.expected.lowerBound)
        let high = Int(verdict.expected.upperBound)
        var lines: [String] = []
        switch verdict.route {
        case .sameRouter:
            lines.append(L10n.text("speed.route.sameRouter", fallback: "Route: both on the same router, so every byte crosses the air twice."))
        case .macWired:
            lines.append(L10n.text("speed.route.macWired", fallback: "Route: Mac on Ethernet, phone on Wi-Fi."))
        case .hotspot:
            lines.append(L10n.text("speed.route.hotspot", fallback: "Route: Mac on the phone\u{2019}s hotspot, one Wi-Fi hop."))
        case .unknown:
            lines.append(L10n.text("speed.route.unknown", fallback: "Route: not Wi-Fi or Ethernet on both sides (for example a cable, a VPN or an emulator), so there is no estimate to compare with."))
        }
        switch verdict.basis {
        case .linkRates:
            lines.append(String(format: L10n.text("speed.estimate.linkRates", fallback: "Estimate: %d to %d MB/s, from the Wi-Fi link rates (Wi-Fi usually carries half to three quarters of its link rate)."), low, high))
        case .typical:
            lines.append(String(format: L10n.text("speed.estimate.typical", fallback: "Estimate: %d to %d MB/s, typical for Wi-Fi 6 (the link rate was not readable)."), low, high))
        case .none:
            break
        }
        if verdict.basis != .none {
            lines.append(verdict.asExpected
                ? L10n.text("speed.verdict.ok", fallback: "The test reached the estimate.")
                : L10n.text("speed.verdict.slow", fallback: "The test was slower than the estimate."))
        }
        for advice in verdict.advice {
            switch advice {
            case .phone24: lines.append(L10n.text("speed.advice.phone24", fallback: "The phone is on 2.4 GHz. Join the router\u{2019}s 5 GHz network or move closer."))
            case .mac24: lines.append(L10n.text("speed.advice.mac24", fallback: "This Mac is on 2.4 GHz. Join the router\u{2019}s 5 GHz network or move closer."))
            case .screenOff: lines.append(L10n.text("speed.advice.screenOff", fallback: "Keep the phone\u{2019}s screen on during big transfers: Android saves Wi-Fi power when it is off."))
            case .weakLink: lines.append(L10n.text("speed.advice.weak", fallback: "The signal may be weak or the network busy. Move closer to the router."))
            case .tryHotspot: lines.append(L10n.text("speed.advice.hotspot", fallback: "For more, connect the Mac to the phone\u{2019}s hotspot: one Wi-Fi hop instead of two."))
            }
        }
        return lines.joined(separator: " ")
    }
}

struct SpeedReportView: View {
    let report: SpeedReport
    @Environment(\.brand) private var c
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                figure(L10n.text("speed.macToPhone", fallback: "Mac to phone"), report.macToPhone)
                figure(L10n.text("speed.phoneToMac", fallback: "Phone to Mac"), report.phoneToMac)
            }
            .padding(.bottom, 10)
            SettingsRow(title: L10n.text("speed.roundTrip", fallback: "Round trip"), subtitle: roundTrip) { EmptyView() }
            SettingsRow(title: L10n.text("speed.thisMac", fallback: "This Mac"), subtitle: SpeedFormat.link(report.mac)) { EmptyView() }
            SettingsRow(title: L10n.text("speed.phone", fallback: "Phone"),
                        subtitle: [SpeedFormat.link(report.phone), SpeedFormat.lock(report.phone)].compactMap { $0 }.joined(separator: ". ")) { EmptyView() }
            Text(SpeedFormat.verdict(report.verdict))
                .font(BrandFont.body(13))
                .foregroundStyle(c.on)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.vertical, 10)
                .overlay(alignment: .top) { Rectangle().fill(c.olv).frame(height: 1) }
            Button(copied ? L10n.text("speed.copied", fallback: "Copied") : L10n.text("speed.copy", fallback: "Copy results")) {
                let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(report.plainText(version: version), forType: .string)
                copied = true
            }
            .buttonStyle(PillButtonStyle(kind: .outline, height: 28))
            .padding(.bottom, 10)
        }
    }

    private var roundTrip: String {
        switch (report.roundTripMs, report.loadedRoundTripMs) {
        case let (idle?, loaded?):
            return String(format: L10n.text("speed.roundTrip.both", fallback: "%.0f ms idle, %.0f ms during the test"), idle, loaded)
        case let (idle?, nil):
            return String(format: L10n.text("speed.roundTrip.idle", fallback: "%.0f ms"), idle)
        case let (nil, loaded?):
            return String(format: L10n.text("speed.roundTrip.loaded", fallback: "%.0f ms during the test"), loaded)
        default:
            return L10n.text("speed.link.unknown", fallback: "Not readable")
        }
    }

    private func figure(_ title: String, _ value: Double?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(BrandFont.body(12))
                .foregroundStyle(c.on2)
            Text(value.map(SpeedFormat.megabytes) ?? L10n.text("speed.none", fallback: "Not measured"))
                .font(BrandFont.heading(22))
                .foregroundStyle(c.on)
                .monospacedDigit()
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(c.s2))
    }
}
