import CoreBluetooth
import Foundation

/*
 * Companion link (edition): Android 15 and later hide the text of notifications that contain a code
 * from notification readers it does not trust. An app with a Companion Device Manager association is
 * trusted. To create one, the phone asks this Mac to advertise a one-off Bluetooth LE service UUID for
 * a minute; the phone's system dialog finds it, the user taps Allow, and the association exists.
 * Nothing ever connects over Bluetooth; the advertisement only lets the phone's dialog find this Mac.
 */

/// Why advertising could not start, as sent back to the phone.
enum CompanionAdvertiseFailure: String, Error, Equatable {
    case bluetoothOff = "bluetooth_off"
    case unauthorized
    case unsupported
    case failed
}

/// Maps Core Bluetooth's state to "can advertise now", "wait" or a failure to report.
func companionAdvertiseReadiness(_ state: CBManagerState) -> Result<Bool, CompanionAdvertiseFailure> {
    switch state {
    case .poweredOn: .success(true)
    case .unknown, .resetting: .success(false)
    case .poweredOff: .failure(.bluetoothOff)
    case .unauthorized: .failure(.unauthorized)
    case .unsupported: .failure(.unsupported)
    @unknown default: .failure(.unsupported)
    }
}

@MainActor
final class CompanionLinkAdvertiser: NSObject {
    static let duration: TimeInterval = 60

    /// Called once per start: nil when advertising began, else why not.
    typealias Completion = (CompanionAdvertiseFailure?) -> Void

    private var manager: CBPeripheralManager?
    private var serviceUUID: CBUUID?
    private var completion: Completion?
    private var stopWork: DispatchWorkItem?
    private(set) var isAdvertising = false

    /// Advertises `uuid` for `duration` seconds (a new start replaces the previous one).
    func start(uuid: UUID, localName: String, completion: @escaping Completion) {
        stop()
        serviceUUID = CBUUID(nsuuid: uuid)
        self.completion = completion
        pendingName = String(localName.prefix(8))
        // Creating the manager shows the macOS Bluetooth permission prompt the first time.
        if let manager {
            stateChanged(manager.state)
        } else {
            manager = CBPeripheralManager(delegate: self, queue: .main)
        }
        let work = DispatchWorkItem { [weak self] in self?.stop() }
        stopWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.duration, execute: work)
    }

    func stop(uuid: UUID? = nil) {
        if let uuid, serviceUUID != CBUUID(nsuuid: uuid) { return }
        stopWork?.cancel()
        stopWork = nil
        if isAdvertising { manager?.stopAdvertising() }
        isAdvertising = false
        serviceUUID = nil
        finish(.failed)
    }

    private var pendingName = "Bridgey"

    private func stateChanged(_ state: CBManagerState) {
        guard let uuid = serviceUUID, completion != nil else { return }
        switch companionAdvertiseReadiness(state) {
        case .success(true):
            guard !isAdvertising else { return }
            manager?.startAdvertising([
                CBAdvertisementDataServiceUUIDsKey: [uuid],
                CBAdvertisementDataLocalNameKey: pendingName,
            ])
        case .success(false):
            break
        case let .failure(reason):
            finish(reason)
            stopWork?.cancel()
            stopWork = nil
            serviceUUID = nil
        }
    }

    private func finish(_ failure: CompanionAdvertiseFailure?) {
        guard let completion else { return }
        self.completion = nil
        completion(failure)
    }

    fileprivate func didStartAdvertising(error: Error?) {
        if error == nil {
            isAdvertising = true
            finish(nil)
        } else {
            BridgeyLog.pairing.error("companion advertising failed")
            finish(.failed)
            stop()
        }
    }
}

extension CompanionLinkAdvertiser: CBPeripheralManagerDelegate {
    nonisolated func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        let state = peripheral.state
        MainActor.assumeIsolated { stateChanged(state) }
    }

    nonisolated func peripheralManagerDidStartAdvertising(_ peripheral: CBPeripheralManager, error: Error?) {
        MainActor.assumeIsolated { didStartAdvertising(error: error) }
    }
}
