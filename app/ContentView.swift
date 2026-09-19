//
//  ContentView.swift
//  hophacks_prep
//
//  Created by Abir Modak on 9/6/26.
//

import SwiftUI

struct ContentView: View {
    @StateObject private var arController = ARSessionController()
    @StateObject private var detector = ObjectDetector()

    var body: some View {
        GeometryReader { geo in
            ZStack {
                ARCameraPreview(session: arController.session)
                    .ignoresSafeArea()

                BoundingBoxOverlay(
                    detections: detector.detections,
                    handPoint: detector.handPoint,
                    leftHandJointPoints: detector.leftHandJointPoints,
                    rightHandJointPoints: detector.rightHandJointPoints,
                    leftHandHoldingObject: detector.leftHandHoldingObject,
                    rightHandHoldingObject: detector.rightHandHoldingObject,
                    viewSize: geo.size,
                    distance: detector.distance
                )
            }
            .onAppear {
                arController.onFrame = { frame in
                    detector.process(frame: frame)
                }
                arController.start()
            }
        }
    }
}

#Preview {
    ContentView()
}
