import AppKit
import SwiftUI

@MainActor
final class PerfTestModel: ObservableObject {
    enum Phase: Equatable {
        case idle
        case running(mode: BenchMode, index: Int, fraction: Double)
        case done
        case failed(String)
    }

    @Published var phase: Phase = .idle
    @Published var report: BenchReport?
    private let cancelFlag = CancelFlag()

    final class CancelFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
        func set(_ v: Bool) { lock.lock(); value = v; lock.unlock() }
    }

    var isRunning: Bool { if case .running = phase { true } else { false } }

    func start(fileBytes: Int64) {
        guard !isRunning else { return }
        cancelFlag.set(false)
        report = nil
        phase = .running(mode: .writeOnly, index: 0, fraction: 0)
        let flag = cancelFlag
        let update: @Sendable (Double, BenchMode) -> Void = { [weak self] fraction, mode in
            let index = BenchMode.allCases.firstIndex(of: mode) ?? 0
            Task { @MainActor in self?.phase = .running(mode: mode, index: index, fraction: fraction) }
        }
        let done: @Sendable (Result<BenchReport, HashBenchmarkRunner.Failure>) -> Void = { [weak self] result in
            Task { @MainActor in self?.finish(result) }
        }
        Task.detached(priority: .utility) {
            done(HashBenchmarkRunner.run(fileBytes: fileBytes, isCancelled: { flag.isSet }, progress: update))
        }
    }

    func cancel() { cancelFlag.set(true) }

    private func finish(_ result: Result<BenchReport, HashBenchmarkRunner.Failure>) {
        switch result {
        case .success(let r):
            report = r
            phase = .done
        case .failure(.noSpace(let free, let needed)):
            phase = .failed(String(format: L10n.text("perf.fail.space", fallback: "Not enough free space: %lld MB free, %lld MB needed (twice the file size plus 1 GB)."), free / 1_000_000, needed / 1_000_000))
        case .failure(.vectors):
            phase = .failed(L10n.text("perf.fail.vectors", fallback: "BLAKE3 failed its test vectors, so the results would be wrong. Nothing was measured."))
        case .failure(.cancelled):
            phase = .failed(L10n.text("perf.cancelled", fallback: "Stopped. Nothing was kept."))
        case .failure(.io(let message)):
            phase = .failed(L10n.text("perf.fail.io", fallback: "The test file could not be written.") + " " + message)
        }
    }

    func copyResults() {
        guard let report else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(report.text(), forType: .string)
    }
}

/// Settings, About: the integrity cost test, same five modes as the Android app.
struct PerfTestPanel: View {
    @StateObject private var model = PerfTestModel()
    @Environment(\.brand) private var c

    var body: some View {
        SettingsCard(
            title: L10n.text("perf.title", fallback: "Performance test"),
            footnote: L10n.text("perf.footnote", fallback: "Mac power metrics need root, so only processor time is shown. Reads bypass the disk cache.")
        ) {
            SettingsRow(title: L10n.text("perf.intro.title", fallback: "File check cost"),
                        subtitle: L10n.text("perf.intro", fallback: "Writes a test file in 1 MiB blocks under five checking modes and measures time and processor use. The file is kept in the app cache and deleted afterwards.")) {
                HStack(spacing: 8) {
                    Button(L10n.text("perf.run.quick", fallback: "Run quick (256 MB)")) { model.start(fileBytes: benchQuickBytes) }
                        .buttonStyle(PillButtonStyle(kind: .outline, height: 28)).disabled(model.isRunning)
                    Button(L10n.text("perf.run.full", fallback: "Run full (1 GB)")) { model.start(fileBytes: benchFullBytes) }
                        .buttonStyle(PillButtonStyle(kind: .outline, height: 28)).disabled(model.isRunning)
                }
            }
            switch model.phase {
            case .running(let mode, let index, let fraction):
                VStack(alignment: .leading, spacing: 8) {
                    Text(String(format: L10n.text("perf.running", fallback: "Step %d of %d: %@"), index + 1, BenchMode.allCases.count, mode.title))
                        .font(BrandFont.body(13)).foregroundStyle(c.on)
                    ProgressView(value: (Double(index) + fraction) / Double(BenchMode.allCases.count))
                    Button(L10n.text("perf.cancel", fallback: "Stop")) { model.cancel() }
                        .buttonStyle(PillButtonStyle(kind: .outline, height: 28))
                }
                .padding(.vertical, 10)
            case .failed(let message):
                Text(message).font(BrandFont.body(13)).foregroundStyle(c.on2).padding(.vertical, 10)
            case .done:
                if let report = model.report { results(report) }
            case .idle:
                EmptyView()
            }
        }
    }

    @ViewBuilder
    private func results(_ report: BenchReport) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(report.results, id: \.mode) { r in
                let extra = report.extrapolations.first { $0.mode == r.mode }
                VStack(alignment: .leading, spacing: 2) {
                    Text(r.mode.title).font(BrandFont.body(13, .semibold)).foregroundStyle(c.on)
                    Text(String(format: L10n.text("perf.line.time", fallback: "%.2f s, %.0f MB/s, processor %.2f s"), r.wallSeconds, r.mbPerSecond, r.cpuSeconds))
                        .font(BrandFont.body(12)).foregroundStyle(c.on)
                    if r.verifyMismatches > 0 {
                        Text(String(format: L10n.text("perf.line.mismatch", fallback: "Read-back mismatches: %d"), r.verifyMismatches))
                            .font(BrandFont.body(12)).foregroundStyle(c.on)
                    }
                    if let extra {
                        Text(String(format: L10n.text("perf.line.extra", fallback: "Per 10 GB, extra over write only: %+.1f s, %+.1f s of processor"), extra.extraWallSeconds, extra.extraCpuSeconds))
                            .font(BrandFont.body(12)).foregroundStyle(c.on2)
                    }
                }
            }
            HStack(spacing: 8) {
                Button(L10n.text("perf.copy", fallback: "Copy results")) { model.copyResults() }
                    .buttonStyle(PillButtonStyle(kind: .outline, height: 28))
                ShareLink(item: report.jsonString()) { Text(L10n.text("perf.share", fallback: "Share as JSON")) }
                    .buttonStyle(PillButtonStyle(kind: .outline, height: 28))
            }
        }
        .padding(.vertical, 10)
    }
}
