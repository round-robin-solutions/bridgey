import SwiftUI

/// A phone's or a Mac's screen, full screen, with control when allowed.
struct ScreenView: View {
    let deviceID: String
    @EnvironmentObject private var screen: ScreenModel

    var body: some View {
        Button("Stop") { screen.close() }
    }
}
