import Foundation
import Combine
import ARKit

class ARSessionController: NSObject, ObservableObject, ARSessionDelegate {
    let session = ARSession()
    var onFrame: ((ARFrame) -> Void)?

    func start() {
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

    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        onFrame?(frame)
    }
}
