# HopHacks 2026

## Overview

HopHacks 2026 is an iOS accessibility app that helps users locate and identify objects using the device camera, ARKit, hand tracking, object segmentation, spatial guidance, speech, and haptic feedback.

The app guides a user's hand toward an object like a bottle, confirms when the object is found, and helps the user bring it close enough to read.

## Features

- Home screen with swipe-up and voice navigation to the main screen.
- Voice-controlled object search and target parsing.
- AR camera preview with hand-joint and object overlays.
- LiDAR depth measurements for hand-to-object and camera-to-object distances.
- Core ML object detection and segmentation.
- Spoken guidance through ElevenLabs text-to-speech.
- Smooth proximity tone that becomes louder as the hand gets closer.
- Haptic feedback for directional guidance and readable distance.
- Text reading and object interaction announcements.

## Project Structure

```text
HopHacks_2026/
├── README.md
├── models/
└── app/
	 ├── App.swift                 # Application entry point
	 ├── HomeScreen.swift          # Home screen and swipe navigation
	 ├── MainScreen.swift          # Main controls and navigation
	 ├── ContentView.swift         # AR detection and guidance workflow
	 ├── CameraController.swift    # AR session and depth configuration
	 ├── CameraView.swift          # AR camera view wrapper
	 ├── ObjectDetection.swift     # Vision hand tracking and distance logic
	 ├── Segmentation.swift        # Core ML segmentation and target mask
	 ├── BoundingBox.swift         # Detection and distance overlays
	 ├── Speaker.swift              # ElevenLabs speech playback
	 ├── VoiceListener.swift        # Voice command recognition
	 ├── TargetParser.swift         # Extracts object names from commands
	 ├── TextReader.swift           # Text reading workflow
	 ├── InteractionAnnouncer.swift # Object interaction announcements
	 ├── Assets.xcassets/           # App images and image sets
	 ├── Probe.xcodeproj/            # Xcode project
	 └── project.yml                # XcodeGen project configuration
```

## Tech Stack

- Swift and SwiftUI
- ARKit for camera tracking and LiDAR scene depth
- Vision for hand-pose detection
- Core ML for object detection and segmentation
- AVFoundation for audio playback and speech audio sessions
- Speech framework for voice recognition
- UIKit haptic feedback
- ElevenLabs API for text-to-speech
- XcodeGen for generating the Xcode project

## Prerequisites

- macOS with Xcode installed.
- An iPhone or with a camera; a LiDAR-equipped device is required for depth measurements.
- iOS 17 or later.
- XcodeGen, if regenerating the project:

  ```bash
  brew install xcodegen
  ```

- An ElevenLabs API key for cloud text-to-speech.
- The required Core ML model files in the repository's model locations.

AR camera and LiDAR functionality cannot be fully tested in the iOS Simulator.

## Setup

1. Clone the repository and open a terminal in the repository root.
2. Enter the app directory:

   ```bash
   cd app
   ```

3. Create the local secrets file:

   ```bash
   cp Secrets.swift.example Secrets.swift
   ```

4. Add your ElevenLabs API key to `Secrets.swift`. This file is git-ignored and must not be committed.
5. Generate the Xcode project when needed:

   ```bash
   xcodegen generate
   ```

6. Open the project:

   ```bash
   open Probe.xcodeproj
   ```

7. Select a physical iPhone as the run destination, grant camera, microphone, and speech-recognition permissions, then build and run.

For production, route ElevenLabs requests through a server instead of embedding an API key in the app bundle.

## Workflow

1. The app opens on `HomeScreen`.
2. The user swipes up to navigate to `MainScreen`.
3. The user selects the Find workflow.
4. `ContentView` starts the AR session, hand tracking, segmentation, and distance processing.
5. The app identifies the largest detected bottle as the guidance target.
6. Audio guidance tells the user to move their hand forward; the tone becomes louder as the hand approaches.
7. When the hand reaches the bottle's depth plane, the app provides left/right spoken and haptic guidance.
8. When the object is obtained, the app confirms it with sound and then instructs the user to bring it closer for reading.
9. Once the object reaches the configured reading distance, the app announces that it is close enough to read and provides success feedback.

## Build Verification

From the `app` directory, build for the simulator to check compilation:

```bash
xcodebuild -project Probe.xcodeproj -scheme Probe -sdk iphonesimulator -configuration Debug CODE_SIGNING_ALLOWED=NO build
```

Use a physical device for ARKit, LiDAR, camera, microphone, speech recognition, and haptic testing.
