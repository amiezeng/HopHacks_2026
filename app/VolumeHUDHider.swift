import MediaPlayer
import SwiftUI

/// iOS shows its volume slider whenever the audio session changes mode, which happens each time the agent
/// conversation starts or ends. An MPVolumeView anywhere in the view hierarchy tells iOS to hold it back.
/// Side effect: the physical volume buttons also show no on-screen slider while the app is in front.
struct VolumeHUDHider: UIViewRepresentable {
    func makeUIView(context: Context) -> MPVolumeView {
        let view = MPVolumeView(frame: CGRect(x: 0, y: 0, width: 1, height: 1))
        view.alpha = 0.01
        view.isUserInteractionEnabled = false
        return view
    }

    func updateUIView(_ uiView: MPVolumeView, context: Context) {}
}
