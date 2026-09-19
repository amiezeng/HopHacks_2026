import AVFoundation

@MainActor
final class Speaker {
    static let shared = Speaker()

    private let voiceID = "vChnJZ1Cu89g2XXumPfT"
    private let modelID = "eleven_flash_v2_5"
    private var player: AVAudioPlayer?

    func speak(_ text: String) {
        Task {
            do {
                let audio = try await fetchAudio(for: text)
                try play(audio)
            } catch {
                print("Speaker error: \(error)")
            }
        }
    }

    private func fetchAudio(for text: String) async throws -> Data {
        let url = URL(string: "https://api.elevenlabs.io/v1/text-to-speech/\(voiceID)")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(Secrets.elevenLabsAPIKey, forHTTPHeaderField: "xi-api-key")
        request.httpBody = try JSONEncoder().encode(["text": text, "model_id": modelID])

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            print("ElevenLabs error: \(String(data: data, encoding: .utf8) ?? "")")
            throw URLError(.badServerResponse)
        }
        return data
    }

    private func play(_ data: Data) throws {
        try AVAudioSession.sharedInstance().setCategory(.playback)
        try AVAudioSession.sharedInstance().setActive(true)
        player = try AVAudioPlayer(data: data)
        player?.play()
    }
}
