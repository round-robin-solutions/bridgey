import AVFoundation
import CoreMedia
import UIKit

/// The hardware surface a stream is shown on: an AVSampleBufferDisplayLayer that takes the decoder's pictures from the
/// frame pump's thread. The model keeps one per stream; the screen view hosts its layer.
final class ScreenDisplay: NSObject, ScreenFrameSink, @unchecked Sendable {
    let layer = AVSampleBufferDisplayLayer()

    override init() {
        super.init()
        layer.videoGravity = .resizeAspect
        layer.backgroundColor = UIColor.black.cgColor
    }

    func show(_ sample: CMSampleBuffer) {
        let renderer = layer.sampleBufferRenderer
        if renderer.status == .failed { renderer.flush() }
        renderer.enqueue(sample)
    }

    func clear() {
        layer.sampleBufferRenderer.flush(removingDisplayedImage: true, completionHandler: nil)
    }
}
