import SwiftUI

/// Shown while `Preloader` builds the artwork and the vision models.
///
/// It draws just the home screen's "PROBE" (one small layer, cheap to draw before the rest of the art
/// is built) with a spinner under it. Once the home screen is mounted and drawn, `handedOver` goes true:
/// the background, title, spinner and text all drop out at once, and the home screen's own copy of
/// the title, sitting in exactly the same place (`HomeScreen.loadingTitleDrop`), rises to its spot
/// while the monster slides up from below.
struct LoadingScreen: View {
    /// What the preloader is doing, shown under the title.
    var step = "Getting ready"
    /// The home screen has taken over: nothing here is drawn any more.
    var handedOver = false

    /// Under the title, in artboard points.
    private static let statusBounds = CGRect(
        x: HomeArt.artboard.minX,
        y: HomeScreen.loadingTitleCenter + HomeArt.title.bounds.height / 2 + 70,
        width: HomeArt.artboard.width,
        height: 200
    )

    @State private var spinning = false

    var body: some View {
        ZStack {
            // The same color as the home screen's, so it can be cut rather than faded: the home screen
            // is already there underneath in the same place.
            HomeArt.background.color
                .opacity(handedOver ? 0 : 1)
            Artboard(rect: HomeArt.artboard) {
                Artboard(rect: HomeArt.artboard) {
                    HomeArt.title
                }
                .artboardShift(HomeScreen.loadingTitleDrop)
                .artFrame(HomeArt.artboard)
                .opacity(handedOver ? 0 : 1)

                status
                    .artFrame(Self.statusBounds)
                    .opacity(handedOver ? 0 : 1)
                    .animation(.easeOut(duration: 0.25), value: handedOver)
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(!handedOver)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Probe is loading")
        .onAppear {
            withAnimation(.linear(duration: 1).repeatForever(autoreverses: false)) { spinning = true }
        }
    }

    private var status: some View {
        VStack(spacing: 26) {
            ring
            Text(step)
                .font(.system(size: 18, weight: .bold, design: .rounded))
                .foregroundStyle(.white.opacity(0.85))
                .animation(.easeInOut, value: step)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var ring: some View {
        Circle()
            .trim(from: 0, to: 0.22)
            .stroke(.white, style: StrokeStyle(lineWidth: 6, lineCap: .round))
            .frame(width: 44, height: 44)
            .rotationEffect(.degrees(spinning ? 360 : 0))
    }
}

#Preview {
    LoadingScreen()
}
