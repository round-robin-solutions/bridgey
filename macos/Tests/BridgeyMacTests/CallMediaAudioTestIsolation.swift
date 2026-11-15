import Foundation
import XCTest

/// Private Core Audio graphs still share the host's audio server. Owner: Bridgey native acceptance.
func requireIsolatedCallAudioHost() throws {
    guard ProcessInfo.processInfo.environment["BRIDGEY_CALL_AUDIO_ISOLATED"] == "1" else {
        throw XCTSkip("Quarantined after Work Mac audio disruption; requires a dedicated isolated audio host (BRIDGEY_CALL_AUDIO_ISOLATED=1)")
    }
}
