import Foundation
import Combine
import ARKit

class ARSessionController: NSObject, ObservableObject, ARSessionDelegate {
    let session = ARSession()
    var onFrame: ((ARFrame) -> Void)?
    private var running = false

    func start() {
        guard !running else { return }
        running = true
        let config = ARWorldTrackingConfiguration()
        let supportsDepth = type(of: config).supportsFrameSemantics(.sceneDepth)
        print("Device supports sceneDepth:", supportsDepth)
        // LiDAR depth drives the distance readouts; without it they show "—".
        let depthEnabled = true
        if depthEnabled && supportsDepth {
            config.frameSemantics.insert(.sceneDepth)
        }
        session.delegate = self
        session.run(config)
    }

    /// Leaving the screen stops the camera: the frames would otherwise keep arriving and keep both
    /// detectors running behind whatever is on screen instead.
    func pause() {
        guard running else { return }
        running = false
        session.pause()
    }

    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        onFrame?(frame)
    }
}
