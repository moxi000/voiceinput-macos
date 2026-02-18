import Foundation

/// Common interface for speech recognition services.
protocol ASRService: AnyObject {
    /// Called with partial transcription text (on main thread).
    var onPartialResult: ((String) -> Void)? { get set }
    /// Called with final transcription text (on main thread).
    var onFinalResult: ((String) -> Void)? { get set }
    /// Called on error (on main thread).
    var onError: ((String) -> Void)? { get set }

    /// Start a streaming session.
    func startStreaming()
    /// Send a chunk of PCM audio data (16kHz, 16-bit, mono).
    func sendAudioChunk(_ pcmData: Data)
    /// End the streaming session (signal end of audio).
    func endStreaming()
    /// Cancel the session immediately.
    func cancel()
}
