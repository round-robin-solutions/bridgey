import CoreBluetooth
import Foundation

/// Codes from messages: Android shows Bridgey the text of code messages only from a companion device it has linked,
/// and it finds that device by a Bluetooth LE advertisement of a service the phone names. This advertises it for the
/// time asked (60 s) while Bridgey is open. iOS advertises service UUIDs only from the foreground, so linking needs
/// the app on screen. iOS asks for Bluetooth the first time, which is only after the person asked to link.
final class BluetoothAdvertiser: NSObject, CompanionAdvertiser, CBPeripheralManagerDelegate {
    private var manager: CBPeripheralManager?
    private var pending: (service: String, seconds: TimeInterval, done: @MainActor (Bool, String?) -> Void)?
    private var current: String?
    private var stopTimer: Timer?
    private var answerTimer: Timer?

    func start(service: String, seconds: TimeInterval, done: @escaping @MainActor (Bool, String?) -> Void) {
        guard UUID(uuidString: service) != nil else {
            MainActor.assumeIsolated { done(false, "failed") }
            return
        }
        if let pending { MainActor.assumeIsolated { pending.done(false, "failed") } }
        pending = (service, seconds, done)
        if manager == nil {
            manager = CBPeripheralManager(delegate: self, queue: .main)
        } else {
            peripheralManagerDidUpdateState(manager!)
        }
        // A Bluetooth stack that never settles still gets an answer.
        answerTimer?.invalidate()
        answerTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: false) { [weak self] _ in self?.answer(false, "failed") }
    }

    func stop(service: String) {
        guard current?.lowercased() == service.lowercased() || pending?.service.lowercased() == service.lowercased() else { return }
        finish()
    }

    func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        guard let pending else { return }
        switch peripheral.state {
        case .poweredOn:
            current = pending.service
            peripheral.stopAdvertising()
            peripheral.startAdvertising([CBAdvertisementDataServiceUUIDsKey: [CBUUID(string: pending.service)]])
        case .poweredOff:
            answer(false, "bluetooth_off")
        case .unauthorized:
            answer(false, "unauthorized")
        case .unsupported:
            answer(false, "unsupported")
        case .resetting, .unknown:
            // Wait for the next state (iOS asks for Bluetooth now, the first time).
            break
        @unknown default:
            answer(false, "failed")
        }
    }

    func peripheralManagerDidStartAdvertising(_ peripheral: CBPeripheralManager, error: Error?) {
        guard let pending else { return }
        if error != nil {
            answer(false, "failed")
            return
        }
        let seconds = pending.seconds
        answer(true, nil)
        stopTimer?.invalidate()
        stopTimer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { [weak self] _ in self?.finish() }
    }

    private func answer(_ ok: Bool, _ reason: String?) {
        answerTimer?.invalidate()
        answerTimer = nil
        guard let pending else { return }
        self.pending = nil
        if !ok { finish() }
        MainActor.assumeIsolated { pending.done(ok, reason) }
    }

    private func finish() {
        stopTimer?.invalidate()
        stopTimer = nil
        manager?.stopAdvertising()
        current = nil
    }
}
