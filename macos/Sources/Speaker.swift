import AVFoundation

/// Reads a transcript back aloud, so you can catch dictation errors by ear —
/// listening surfaces mistakes the eye skips over.
///
/// Uses AVSpeechSynthesizer: on-device, no network, no dependency, and the
/// voices are the same high-quality ones the system uses. Nothing here touches
/// the Zig core — text-to-speech is a pure frontend concern, the opposite
/// direction from whisper.
enum Speaker {
    // The synthesizer must outlive the call — a local one would deallocate and
    // cut the speech off — so it's held here.
    private static let synth = AVSpeechSynthesizer()

    static var isSpeaking: Bool { synth.isSpeaking }

    /// Speak `text`, or stop if that same text is already being spoken — so the
    /// button that starts read-back also stops it.
    static func toggle(_ text: String) {
        if synth.isSpeaking {
            stop()
            return
        }
        let utterance = AVSpeechUtterance(string: text)
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        utterance.prefersAssistiveTechnologySettings = false
        synth.speak(utterance)
    }

    static func stop() {
        synth.stopSpeaking(at: .immediate)
    }
}
