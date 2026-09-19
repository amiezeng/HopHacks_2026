## Apps

### Setup

The app speaks with ElevenLabs text-to-speech, which needs an API key that is not committed to the repo.

1. Copy `app/Secrets.swift.example` to `app/Secrets.swift` (it is git-ignored).
2. Paste your ElevenLabs API key into `Secrets.swift`.
3. Build and run on a real iPhone (the camera/AR features don't work in the Simulator).
